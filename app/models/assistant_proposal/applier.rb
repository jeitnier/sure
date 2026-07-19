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

    # Domain writes + proposal bookkeeping (status/journal/applied_at) must
    # commit together. Splitting them left a window where a crash after the
    # domain writes but before the proposal update would leave financial rows
    # mutated with no journal ("applied but unjournaled" — breaks undo).
    #
    # Race safety: proposal.lock! takes a row-level SELECT FOR UPDATE inside
    # the transaction, so a second apply! for the same proposal (e.g. two
    # AssistantProposalJob runs racing on the same "applying" row) blocks
    # until the first commits, then observes the true post-commit status
    # instead of a stale in-memory one. The legality re-check happens right
    # after the lock, before any domain mutation, so a loser never writes
    # anything and never clobbers the winner's journal.
    ActiveRecord::Base.transaction do
      proposal.lock!

      unless AssistantProposal::TRANSITIONS.fetch(proposal.status, []).include?("applied")
        raise AssistantProposal::InvalidTransition, "#{proposal.status} -> applied"
      end

      journal =
        case proposal.kind
        when "bulk_recategorize" then apply_recategorize(resolver)
        when "category_merge"    then apply_category_merge(resolver)
        when "merchant_merge"    then apply_merchant_merge(resolver)
        end

      proposal.update!(status: "applied", changes_journal: journal, applied_at: Time.current)
    end
  end

  def undo!
    journal = proposal.changes_journal
    restored = 0
    skipped = 0

    # Mirrors apply!: the restore + the final status/journal write must
    # commit together, ending in a single guarded update! rather than a
    # separate transition_to! call (see apply! for the "applied but
    # unjournaled" rationale this avoids). Also mirrors apply!'s race
    # safety: proposal.lock! + a post-lock legality re-check before any
    # restore work happens.
    ActiveRecord::Base.transaction do
      proposal.lock!

      unless AssistantProposal::TRANSITIONS.fetch(proposal.status, []).include?("undone")
        raise AssistantProposal::InvalidTransition, "#{proposal.status} -> undone"
      end

      id_map = recreate_sources(journal)   # old_id => restored/identity record id (categories/merchants); {} for recategorize
      attr_name, applied_value_for = undo_target(journal, id_map)

      journal.fetch("records", {}).each do |txn_id, old_value|
        txn = proposal.family.transactions.find_by(id: txn_id)
        if txn.nil?
          skipped += 1
          next
        end
        if txn.public_send(attr_name) != applied_value_for.call(txn_id)
          skipped += 1
          next
        end
        txn.update_columns(attr_name => id_map.fetch(old_value, old_value), updated_at: Time.current)
        restored += 1
      end

      summary = "#{restored} restored, #{skipped} skipped (changed after apply or missing)"

      proposal.update!(status: "undone", changes_journal: journal.merge("undo_summary" => summary), undone_at: Time.current)
    end
  end

  private
    def lock_category_on!(ids)
      Transaction.where(id: ids).update_all([
        "locked_attributes = COALESCE(locked_attributes, '{}'::jsonb) || ?::jsonb",
        { "category_id" => Time.current.iso8601 }.to_json
      ])
    end

    def apply_recategorize(resolver)
      family = proposal.family
      target = resolver.target_category ||
               family.categories.create!(name: proposal.params["new_category"].to_s.strip, color: Category::COLORS.sample)
      scope = resolver.affected_scope
      records = scope.pluck(:id, :category_id).to_h
      # Update exactly the journaled ids -- re-running the scope here (instead
      # of reusing the ids already captured above) would leave a window where
      # a row inserted into the scope between the pluck and the update gets
      # mutated but never journaled (breaks undo for that row).
      Transaction.where(id: records.keys).update_all(category_id: target.id, updated_at: Time.current)
      lock_category_on!(records.keys)
      { "op" => "recategorize", "new_category_id" => target.id, "records" => records }
    end

    def apply_category_merge(resolver)
      target = resolver.target_category  # may be nil => uncategorized
      sources = resolver.source_categories
      records = {}
      source_snapshots = []
      sources.each do |source|
        txn_ids = source.transactions.pluck(:id)
        txn_ids.each { |id| records[id] = source.id }
        source_snapshots << { "attrs" => source.attributes, "transaction_ids" => txn_ids }
        source.replace_and_destroy!(target)
      end
      lock_category_on!(records.keys)
      { "op" => "category_merge", "target_category_id" => target&.id,
        "sources" => source_snapshots, "records" => records }
    end

    def apply_merchant_merge(resolver)
      target = resolver.target_merchant
      sources = resolver.source_merchants
      records = {}
      snapshots = sources.map { |m| { "attrs" => m.attributes, "destroyed" => m.is_a?(FamilyMerchant) } }
      sources.each do |source|
        proposal.family.transactions.where(merchant_id: source.id).pluck(:id).each { |id| records[id] = source.id }
      end
      Merchant::Merger.new(family: proposal.family, target_merchant: target, source_merchants: sources).merge!
      { "op" => "merchant_merge", "target_merchant_id" => target.id,
        "sources" => snapshots, "records" => records }
    end

    # Recreate destroyed rows; return old_id => new_id map. Sources that
    # weren't actually destroyed at apply time (ProviderMerchant merge
    # sources, which Merchant::Merger only re-points and never destroys) map
    # old_id => old_id (identity) -- the row still exists, so records restore
    # straight back to it instead of a duplicate.
    def recreate_sources(journal)
      case journal["op"]
      when "category_merge"
        journal.fetch("sources", []).each_with_object({}) do |src, map|
          attrs = src["attrs"].except("id", "created_at", "updated_at")
          map[src["attrs"]["id"]] = proposal.family.categories.create!(attrs).id
        end
      when "merchant_merge"
        journal.fetch("sources", []).each_with_object({}) do |src, map|
          old_id = src["attrs"]["id"]
          if src["destroyed"]
            attrs = src["attrs"].except("id", "created_at", "updated_at")
            map[old_id] = Merchant.create!(attrs).id
            # ^ STI: attrs includes "type" (FamilyMerchant) and family_id -- Merchant.create!
            #   with type attr builds the right subclass (Rails STI `.new`/`.create` switch
            #   on the inheritance column when present in the attributes hash).
          else
            map[old_id] = old_id
          end
        end
      else
        {}
      end
    end

    # Which attribute we changed at apply, and what value we set (for conflict check).
    def undo_target(journal, _id_map)
      case journal["op"]
      when "recategorize"
        [ :category_id, ->(_) { journal["new_category_id"] } ]
      when "category_merge"
        [ :category_id, ->(_) { journal["target_category_id"] } ]
      when "merchant_merge"
        [ :merchant_id, ->(_) { journal["target_merchant_id"] } ]
      end
    end
end
