class AssistantProposal::Applier
  attr_reader :proposal

  def initialize(proposal)
    @proposal = proposal
  end

  def apply!
    resolver = AssistantProposal::Resolver.new(family: proposal.family, kind: proposal.kind, params: proposal.params)
    current_digest = AssistantProposal.compute_digest(resolver.affected_ids)
    if current_digest != proposal.preview["affected_ids_digest"]
      refreshed = resolver.build_preview
      proposal.update!(preview: refreshed)
      proposal.transition_to!("stale")
      return
    end

    journal =
      case proposal.kind
      when "bulk_recategorize" then apply_recategorize(resolver)
      when "category_merge"    then apply_category_merge(resolver)
      when "merchant_merge"    then apply_merchant_merge(resolver)
      end

    proposal.update!(changes_journal: journal, applied_at: Time.current)
    proposal.transition_to!("applied")
  end

  def undo!
    # Task 6: reverse-apply using changes_journal snapshots.
    raise NotImplementedError, "AssistantProposal::Applier#undo! is implemented in Task 6"
  end

  private
    def lock_category_on!(ids)
      Transaction.where(id: ids).update_all([
        "locked_attributes = locked_attributes || ?::jsonb",
        { "category_id" => Time.current.iso8601 }.to_json
      ])
    end

    def apply_recategorize(resolver)
      family = proposal.family
      target = resolver.target_category ||
               family.categories.create!(name: proposal.params["new_category"].to_s.strip, color: Category::COLORS.sample)
      records = nil
      ActiveRecord::Base.transaction do
        scope = resolver.affected_scope
        records = scope.pluck(:id, :category_id).to_h
        scope.update_all(category_id: target.id, updated_at: Time.current)
        lock_category_on!(records.keys)
      end
      { "op" => "recategorize", "new_category_id" => target.id, "records" => records }
    end

    def apply_category_merge(resolver)
      target = resolver.target_category  # may be nil => uncategorized
      sources = resolver.source_categories
      records = {}
      source_snapshots = []
      ActiveRecord::Base.transaction do
        sources.each do |source|
          txn_ids = source.transactions.pluck(:id)
          txn_ids.each { |id| records[id] = source.id }
          source_snapshots << { "attrs" => source.attributes, "transaction_ids" => txn_ids }
          source.replace_and_destroy!(target)
        end
        lock_category_on!(records.keys)
      end
      { "op" => "category_merge", "target_category_id" => target&.id,
        "sources" => source_snapshots, "records" => records }
    end

    def apply_merchant_merge(resolver)
      target = resolver.target_merchant
      sources = resolver.source_merchants
      records = {}
      snapshots = sources.map { |m| { "attrs" => m.attributes } }
      ActiveRecord::Base.transaction do
        sources.each do |source|
          Transaction.where(merchant_id: source.id).pluck(:id).each { |id| records[id] = source.id }
        end
        Merchant::Merger.new(family: proposal.family, target_merchant: target, source_merchants: sources).merge!
      end
      { "op" => "merchant_merge", "target_merchant_id" => target.id,
        "sources" => snapshots, "records" => records }
    end
end
