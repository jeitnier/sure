class Assistant::Function::ProposeBulkRecategorize < Assistant::Function
  class << self
    def name = "propose_bulk_recategorize"

    def description
      <<~INSTRUCTIONS
        Stages a bulk recategorization of transactions matching a filter. This does NOT
        apply anything: it creates a proposal card in the chat that the user must
        explicitly Apply. Never claim the change has been made — after calling this,
        tell the user a proposal is awaiting their Apply click.

        Filter keys (AND-combined, at least one required):
        - merchant_names: exact merchant names (use get_transactions/get_categories to discover)
        - description_contains: substring match on transaction name
        - category_ids: current category ids; include the string "uncategorized" for transactions with no category
        - account_ids: limit to specific accounts
        - date_range: { start: "YYYY-MM-DD", end: "YYYY-MM-DD" }
        - transaction_ids: exact transaction ids from get_transactions results. Use this
          when the user targets specific transactions (rows from an attached file, a
          hand-picked subset, or a single transaction) instead of a broad filter.
          To match a list of known totals, first call get_transactions with its
          `amounts` filter, then pass the returned ids here — never match amounts by eye.

        new_category: target category id or exact name (a new category is created if the name doesn't exist).
      INSTRUCTIONS
    end

    def chat_required? = true
  end

  def strict_mode? = false

  def params_schema
    build_schema(
      required: [ "filter", "new_category" ],
      properties: {
        filter: {
          type: "object",
          properties: {
            merchant_names: { type: "array", items: { type: "string" } },
            description_contains: { type: "string" },
            category_ids: { type: "array", items: { type: "string" } },
            account_ids: { type: "array", items: { type: "string" } },
            date_range: { type: "object", properties: { start: { type: "string" }, end: { type: "string" } } },
            transaction_ids: { type: "array", items: { type: "string" }, description: "Exact transaction ids (from get_transactions)" }
          }
        },
        new_category: { type: "string", description: "Target category id or exact name" }
      }
    )
  end

  def call(params = {})
    create_proposal(kind: "bulk_recategorize", params: params)
  end
end
