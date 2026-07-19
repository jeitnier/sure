class AssistantProposalJob < ApplicationJob
  queue_as :default

  def perform(proposal_id, action)
  end
end
