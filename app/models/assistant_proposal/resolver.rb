# Resolves an AssistantProposal's params into a concrete ActiveRecord scope of
# affected transactions, and builds the human-facing preview shown on the
# proposal card. Read-only: never writes to the database. Apply/undo happen
# elsewhere via the existing domain ops (Category#replace_and_destroy!,
# Merchant::Merger, Transaction.update_all).
class AssistantProposal::Resolver
  class InvalidParams < StandardError; end

  SAMPLE_LIMIT = 10

  attr_reader :family, :kind, :params

  def initialize(family:, kind:, params:)
    @family = family
    @kind = kind
    @params = params.deep_stringify_keys
  end

  def affected_scope
    @affected_scope ||=
      case kind
      when "bulk_recategorize" then recategorize_scope
      when "category_merge"    then family.transactions.where(category_id: source_categories.map(&:id))
      when "merchant_merge"    then family.transactions.where(merchant_id: source_merchants.map(&:id))
      else raise InvalidParams, "unknown kind #{kind}"
      end
  end

  def affected_ids
    @affected_ids ||= affected_scope.pluck(:id).map(&:to_s)
  end

  def over_cap?
    affected_ids.size > AssistantProposal.max_records
  end

  def build_preview
    {
      "count" => affected_ids.size,
      "affected_ids_digest" => AssistantProposal.compute_digest(affected_ids),
      "samples" => samples,
      "breakdown" => breakdown,
      "notes" => notes
    }
  end

  # -- per-kind helpers ------------------------------------------------------

  def target_category
    return @target_category if defined?(@target_category)
    @target_category =
      case kind
      when "bulk_recategorize"
        name_or_id = params.fetch("new_category")
        family.categories.find_by(id: name_or_id) || family.categories.find_by(name: name_or_id) # nil => will create
      when "category_merge"
        params["target_category_id"].presence && family.categories.find(params["target_category_id"])
      end
  end

  def source_categories
    ids = Array(params["source_category_ids"])
    raise InvalidParams, "source_category_ids required" if ids.empty?
    raise InvalidParams, "target cannot be one of the sources" if ids.include?(params["target_category_id"])
    cats = family.categories.where(id: ids).to_a
    raise InvalidParams, "unknown category id(s): #{(ids - cats.map(&:id)).join(', ')}" if cats.size != ids.size
    cats
  end

  def source_merchants
    ids = Array(params["source_merchant_ids"])
    raise InvalidParams, "source_merchant_ids required" if ids.empty?
    raise InvalidParams, "target cannot be one of the sources" if ids.include?(params["target_merchant_id"])
    merchants = family_merchants.where(id: ids).to_a
    raise InvalidParams, "unknown merchant id(s): #{(ids - merchants.map(&:id)).join(', ')}" if merchants.size != ids.size
    merchants
  end

  def target_merchant
    @target_merchant ||= family_merchants.find(params.fetch("target_merchant_id"))
  end

  private
    # Mirrors Merchant::Merger#family_merchant_ids (app/models/merchant/merger.rb):
    # a merchant "belongs" to the family either as a FamilyMerchant (family.merchants)
    # or as a ProviderMerchant already assigned to one of the family's transactions
    # (family.assigned_merchants). Both associations already return Merchant
    # relations scoped correctly, so union their ids into a single Merchant scope.
    def family_merchants
      Merchant.where(id: family.merchants.select(:id)).or(Merchant.where(id: family.assigned_merchants.select(:id)))
    end

    def recategorize_scope
      filter = params.fetch("filter", {})
      raise InvalidParams, "filter must not be empty" if filter.blank? || filter.values.all?(&:blank?)

      search_filters = {}
      search_filters["merchants"]  = filter["merchant_names"] if filter["merchant_names"].present?
      search_filters["search"]     = filter["description_contains"] if filter["description_contains"].present?
      search_filters["start_date"] = filter.dig("date_range", "start") if filter.dig("date_range", "start").present?
      search_filters["end_date"]   = filter.dig("date_range", "end") if filter.dig("date_range", "end").present?

      # Transaction::Search#transactions_scope is the relation accessor consumed by
      # Assistant::Function::GetTransactions#call (app/models/assistant/function/get_transactions.rb:137-138).
      scope = Transaction::Search.new(family, filters: search_filters).transactions_scope

      if filter["category_ids"].present?
        ids = Array(filter["category_ids"])
        scope = if ids.include?("uncategorized")
          scope.where(category_id: ids - [ "uncategorized" ]).or(scope.where(category_id: nil))
        else
          scope.where(category_id: ids)
        end
      end

      # NOTE: entries/accounts are already joined by Transaction::Search's base
      # query (family.transactions.merge(Entry.excluding_split_parents) goes
      # through accounts -> entries -> transactions), so filtering on
      # entries.account_id needs no additional join — adding one here would
      # create a duplicate/aliased "entries" join.
      scope = scope.where(entries: { account_id: filter["account_ids"] }) if filter["account_ids"].present?
      scope
    end

    def samples
      affected_scope.limit(SAMPLE_LIMIT).includes(:category, :merchant, :entry).map do |txn|
        {
          "id" => txn.id,
          "name" => txn.entry&.name,
          "date" => txn.entry&.date&.to_s,
          "amount" => txn.entry&.amount&.to_s,
          "before" => before_label(txn),
          "after" => after_label
        }
      end
    end

    def breakdown
      case kind
      when "merchant_merge"
        affected_scope.left_joins(:merchant).group("merchants.name").count
          .transform_keys { |k| k || "(none)" }
      else
        affected_scope.left_joins(:category).group("categories.name").count
          .transform_keys { |k| k || "Uncategorized" }
      end
    end

    def before_label(txn)
      case kind
      when "merchant_merge" then txn.merchant&.name || "(none)"
      else txn.category&.name || "Uncategorized"
      end
    end

    def after_label
      case kind
      when "bulk_recategorize" then target_category&.name || params["new_category"].to_s
      when "category_merge"    then target_category&.name || "Uncategorized"
      when "merchant_merge"    then target_merchant.name
      end
    end

    def notes
      n = []
      if kind == "bulk_recategorize" && target_category.nil?
        n << "Category \"#{params['new_category']}\" does not exist — it will be created on apply."
      end
      n
    end
end
