class AssistantProposal < ApplicationRecord
  class InvalidTransition < StandardError; end

  KINDS = %w[bulk_recategorize category_merge merchant_merge].freeze
  STATUSES = %w[proposed applying applied undoing undone discarded stale failed].freeze
  TRANSITIONS = {
    "proposed" => %w[applying discarded stale],
    "applying" => %w[applied failed stale],
    "applied"  => %w[undoing],
    "undoing"  => %w[undone failed],
    "stale"    => %w[proposed discarded]
  }.freeze

  belongs_to :family
  belongs_to :chat
  belongs_to :message, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }

  after_create_commit :broadcast_card_append
  after_update_commit :broadcast_card

  def self.max_records
    ENV.fetch("ASSISTANT_PROPOSAL_MAX_RECORDS", 2000).to_i
  end

  def self.compute_digest(ids)
    Digest::SHA256.hexdigest(ids.map(&:to_s).sort.join(","))
  end

  def transition_to!(new_status)
    allowed = TRANSITIONS.fetch(status, [])
    raise InvalidTransition, "#{status} -> #{new_status}" unless allowed.include?(new_status)
    update!(status: new_status)
  end

  # Appends a new proposal card to the chat's message stream. Called once
  # when the proposal is first created. Broadcast failures never raise —
  # they're logged and swallowed so a Turbo hiccup can't break a write.
  def broadcast_card_append
    chat.broadcast_append_to chat, target: chat.messages_target, partial: "assistant_proposals/card", locals: { proposal: self }
  rescue StandardError => e
    Rails.logger.warn("[AssistantProposal] card broadcast failed: #{e.message}")
  end

  # Replaces the existing proposal card in place (status changes, re-preview,
  # etc). Same broadcast-failure-never-raises guarantee as #broadcast_card_append.
  def broadcast_card
    chat.broadcast_replace_to chat, target: dom_target, partial: "assistant_proposals/card", locals: { proposal: self }
  rescue StandardError => e
    Rails.logger.warn("[AssistantProposal] card broadcast failed: #{e.message}")
  end

  def dom_target = "assistant_proposal_#{id}"
end
