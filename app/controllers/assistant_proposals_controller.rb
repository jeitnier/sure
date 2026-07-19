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
      respond_with_card
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
