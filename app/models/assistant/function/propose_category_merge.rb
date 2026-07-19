class Assistant::Function::ProposeCategoryMerge < Assistant::Function
  class << self
    def name = "propose_category_merge"

    def description
      <<~INSTRUCTIONS
        Stages a merge of one or more source categories into a target category. This does
        NOT apply anything: it creates a proposal card in the chat that the user must
        explicitly Apply. Never claim the merge has happened — after calling this, tell
        the user a proposal is awaiting their Apply click.

        source_category_ids: category ids to merge away (use get_categories to find them).
        target_category_id: category id transactions move to. Omit/null to leave the
        transactions uncategorized instead. Source categories with zero transactions are
        simply deleted. A target cannot also appear in source_category_ids.
      INSTRUCTIONS
    end

    def chat_required? = true
  end

  def strict_mode? = false

  def params_schema
    build_schema(
      required: [ "source_category_ids" ],
      properties: {
        source_category_ids: { type: "array", items: { type: "string" }, description: "Category ids to merge away" },
        target_category_id: { type: "string", description: "Category id transactions move to (optional — omit for Uncategorized)" }
      }
    )
  end

  def call(params = {})
    create_proposal(kind: "category_merge", params: params)
  end
end
