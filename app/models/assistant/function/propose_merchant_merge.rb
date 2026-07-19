class Assistant::Function::ProposeMerchantMerge < Assistant::Function
  class << self
    def name = "propose_merchant_merge"

    def description
      <<~INSTRUCTIONS
        Stages a merge of duplicate merchants into a single target merchant. This does NOT
        apply anything: it creates a proposal card in the chat that the user must
        explicitly Apply. Never claim the merge has happened — after calling this, tell
        the user a proposal is awaiting their Apply click.

        source_merchant_ids: merchant ids to merge away.
        target_merchant_id: merchant id that survives the merge. A target cannot also
        appear in source_merchant_ids.
      INSTRUCTIONS
    end
  end

  def strict_mode? = false

  def params_schema
    build_schema(
      required: [ "source_merchant_ids", "target_merchant_id" ],
      properties: {
        source_merchant_ids: { type: "array", items: { type: "string" }, description: "Merchant ids to merge away" },
        target_merchant_id: { type: "string", description: "Merchant id that survives the merge" }
      }
    )
  end

  def call(params = {})
    create_proposal(kind: "merchant_merge", params: params)
  end
end
