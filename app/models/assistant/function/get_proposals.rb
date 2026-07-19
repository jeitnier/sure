class Assistant::Function::GetProposals < Assistant::Function
  class << self
    def name = "get_proposals"
    def description = "Lists recent bulk-change proposals and their statuses (proposed/applied/undone/etc). Use this to answer questions about pending or past proposals. Read-only."
  end

  def strict_mode? = false

  def params_schema
    build_schema(required: [], properties: {
      status: { type: "string", description: "Optional status filter", enum: AssistantProposal::STATUSES }
    })
  end

  def call(params = {})
    scope = family.assistant_proposals.order(created_at: :desc).limit(10)
    scope = scope.where(status: params["status"]) if params["status"].present?
    { proposals: scope.map { |p|
        { id: p.id, kind: p.kind, status: p.status, count: p.preview["count"],
          created_at: p.created_at.iso8601, applied_at: p.applied_at&.iso8601 } } }
  end
end
