class AssistantProposalJob < ApplicationJob
  queue_as :high_priority

  def perform(proposal_id, action)
    proposal = AssistantProposal.find(proposal_id)
    case action
    when "apply" then AssistantProposal::Applier.new(proposal).apply!
    when "undo"  then AssistantProposal::Applier.new(proposal).undo!
    end
  rescue StandardError => e
    if proposal
      proposal.update!(status: "failed", error: e.message.truncate(500))
    end
    Rails.logger.error("[AssistantProposalJob] #{action} #{proposal_id} failed: #{e.class}: #{e.message}")
  end
end
