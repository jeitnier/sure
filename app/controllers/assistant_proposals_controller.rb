class AssistantProposalsController < ApplicationController
  before_action :set_proposal

  def apply
    transition_and_enqueue("applying", "apply")
  end

  def undo
    transition_and_enqueue("undoing", "undo")
  end

  def discard
    @proposal.transition_to!("discarded")
    respond_with_card
  rescue AssistantProposal::InvalidTransition
    head :unprocessable_entity
  end

  def repreview
    # Verify the transition is legal BEFORE touching preview -- resolving
    # params and overwriting preview is real mutation (Resolver work + a
    # write), and doing it before the legality check meant a wrong-state
    # repreview (e.g. on a "proposed" proposal) still clobbered preview even
    # though the request ultimately 422s.
    unless AssistantProposal::TRANSITIONS.fetch(@proposal.status, []).include?("proposed")
      return head :unprocessable_entity
    end

    resolver = AssistantProposal::Resolver.new(family: Current.family, kind: @proposal.kind, params: @proposal.params)
    @proposal.update!(preview: resolver.build_preview)
    @proposal.transition_to!("proposed")
    respond_with_card
  rescue AssistantProposal::InvalidTransition, AssistantProposal::Resolver::InvalidParams
    head :unprocessable_entity
  end

  private
    def set_proposal
      @proposal = Current.family.assistant_proposals.find(params[:id])
    end

    def transition_and_enqueue(status, action)
      @proposal.transition_to!(status)
      AssistantProposalJob.perform_later(@proposal.id, action)
      # No inline card here: transition_to! already broadcast the intermediate
      # state over the chat's Turbo Stream socket, and the job broadcasts the
      # terminal state on the same ordered channel. An inline card would race
      # that broadcast on a separate connection — when the job wins (observed
      # live: 34ms), the response's stale card overwrites the terminal state
      # and the card sticks at "Working…" until a manual refresh.
      respond_to do |format|
        format.turbo_stream { head :no_content }
        format.html { redirect_back fallback_location: chat_path(@proposal.chat) }
      end
    rescue AssistantProposal::InvalidTransition
      head :unprocessable_entity
    end

    def respond_with_card
      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.replace(@proposal.dom_target, partial: "assistant_proposals/card", locals: { proposal: @proposal }) }
        format.html { redirect_back fallback_location: chat_path(@proposal.chat) }
      end
    end
end
