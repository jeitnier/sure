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
      begin
        # Only clobber status if the proposal was actually in-flight for this
        # job. Without this guard, a job that loses a race (e.g. Applier
        # raises InvalidTransition because another job already applied it)
        # would stomp a perfectly valid terminal status like "applied" back
        # to "failed". Reload first so we're checking the true DB state, not
        # a stale in-memory one.
        proposal.reload
        proposal.update!(status: "failed", error: e.message.truncate(500)) if proposal.status.in?(%w[applying undoing])
      rescue StandardError => reload_error
        Rails.logger.error("[AssistantProposalJob] #{action} #{proposal_id} failed to record failure: #{reload_error.class}: #{reload_error.message}")
      end
    end
    Rails.logger.error("[AssistantProposalJob] #{action} #{proposal_id} failed: #{e.class}: #{e.message}")
  end
end
