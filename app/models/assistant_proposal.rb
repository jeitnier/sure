class AssistantProposal < ApplicationRecord
  class InvalidTransition < StandardError; end

  KINDS = %w[bulk_recategorize category_merge merchant_merge].freeze
  STATUSES = %w[proposed applying applied undoing undone discarded stale failed].freeze
  TRANSITIONS = {
    "proposed" => %w[applying discarded stale],
    "applying" => %w[applied failed stale],
    "applied"  => %w[undoing],
    "undoing"  => %w[undone failed],
    "stale"    => %w[proposed discarded],
    "failed"   => %w[discarded]
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

    # Compare-and-swap: only writes if status is still what we just checked,
    # closing the race window between the legality check and the write (two
    # concurrent transition_to! calls on the same row could otherwise both
    # pass the check and one silently clobber the other's transition).
    rows = self.class.where(id: id, status: status).update_all(status: new_status, updated_at: Time.current)
    raise InvalidTransition, "#{status} -> #{new_status}" if rows.zero?
    reload

    # update_all bypasses AR callbacks (after_update_commit :broadcast_card),
    # so re-broadcast explicitly. broadcast_card already rescues its own
    # failures, preserving the never-raises guarantee for broadcasting.
    broadcast_card
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
