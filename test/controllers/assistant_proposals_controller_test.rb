require "test_helper"

class AssistantProposalsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @chat = @user.chats.create!(title: "t")
    @proposal = AssistantProposal.create!(
      family: @user.family, chat: @chat, kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "X" ] }, "new_category" => "Y" },
      preview: { "count" => 1, "affected_ids_digest" => "d" }, status: "proposed")
  end

  test "apply transitions to applying and enqueues job" do
    assert_enqueued_with(job: AssistantProposalJob, args: [ @proposal.id, "apply" ]) do
      post apply_assistant_proposal_path(@proposal)
    end
    assert_equal "applying", @proposal.reload.status
  end

  test "apply and undo turbo_stream responses carry no card markup" do
    # The APPLYING->APPLIED (and UNDOING->UNDONE) card updates arrive over the
    # single ordered Turbo Stream socket. An inline card in the HTTP response
    # travels on a separate connection with no ordering guarantee against the
    # job's terminal broadcast -- observed live 2026-07-20: the job finished
    # 34ms after the response was sent, its APPLIED broadcast reached the
    # browser first, and the response's stale APPLYING card overwrote it,
    # leaving the card stuck at "Working..." until a manual refresh.
    post apply_assistant_proposal_path(@proposal), as: :turbo_stream
    assert_response :no_content
    assert response.body.blank?, "apply response must not carry a card"

    @proposal.update!(status: "applied")
    post undo_assistant_proposal_path(@proposal), as: :turbo_stream
    assert_response :no_content
    assert response.body.blank?, "undo response must not carry a card"
  end

  test "discard turbo_stream response still carries the card inline" do
    # discard/repreview are synchronous -- the rendered state is final, so the
    # inline card is safe and keeps working even without a live socket.
    post discard_assistant_proposal_path(@proposal), as: :turbo_stream
    assert_response :success
    assert_includes response.body, @proposal.dom_target
  end

  test "discard from proposed" do
    post discard_assistant_proposal_path(@proposal)
    assert_equal "discarded", @proposal.reload.status
  end

  test "discard from failed transitions to discarded instead of 422ing" do
    @proposal.update!(status: "failed", error: "boom")
    post discard_assistant_proposal_path(@proposal), as: :turbo_stream
    assert_response :success
    assert_equal "discarded", @proposal.reload.status
  end

  test "apply on already-applied is rejected" do
    @proposal.update!(status: "applied")
    post apply_assistant_proposal_path(@proposal)
    assert_response :unprocessable_entity
    assert_equal "applied", @proposal.reload.status
  end

  test "undo on applied enqueues job" do
    @proposal.update!(status: "applied")
    assert_enqueued_with(job: AssistantProposalJob, args: [ @proposal.id, "undo" ]) do
      post undo_assistant_proposal_path(@proposal)
    end
    assert_equal "undoing", @proposal.reload.status
  end

  test "other family's proposal 404s" do
    other = users(:empty)
    sign_in other
    post apply_assistant_proposal_path(@proposal)
    assert_response :not_found
  end

  test "proposed proposal card renders a sample rows table with name and before/after change" do
    category = categories(:one)
    entry = create_transaction(category: category, name: "Coffee Shop")
    transaction = entry.entryable
    proposal = AssistantProposal.create!(
      family: @user.family, chat: @chat, kind: "bulk_recategorize",
      params: { "filter" => { "category_ids" => [ category.id ] }, "new_category" => categories(:income).id },
      preview: {
        "count" => 1,
        "affected_ids_digest" => "x",
        "samples" => [
          { "id" => transaction.id, "name" => entry.name, "date" => entry.date.to_s,
            "amount" => entry.amount.to_s, "before" => category.name, "after" => categories(:income).name }
        ],
        "breakdown" => {}, "notes" => []
      },
      status: "proposed")

    get chat_url(@chat)

    assert_response :success
    assert_includes response.body, entry.name
    assert_includes response.body, "#{category.name} → #{categories(:income).name}"
  end

  test "repreview refreshes a stale proposal, restores it to proposed, and renders the localized apply button" do
    category = categories(:one)
    stale_proposal = AssistantProposal.create!(
      family: @user.family, chat: @chat, kind: "bulk_recategorize",
      params: { "filter" => { "category_ids" => [ category.id ] }, "new_category" => categories(:income).id },
      preview: { "count" => 0, "affected_ids_digest" => AssistantProposal.compute_digest([]) },
      status: "stale"
    )

    create_transaction(category: category)

    post repreview_assistant_proposal_path(stale_proposal), as: :turbo_stream

    assert_response :success
    stale_proposal.reload
    assert_equal "proposed", stale_proposal.status
    assert_equal 1, stale_proposal.preview["count"]
    # Regression guard for the i18n fix: the re-rendered card (now back in
    # "proposed" status) must use the localized Apply button label, not a
    # hardcoded string.
    assert_includes response.body, I18n.t("assistant_proposals.card.apply")
  end

  test "repreview with params referencing a deleted source returns 422 and keeps the proposal stale" do
    source = Category.create!(name: "ToDelete", family: @user.family)
    target = categories(:income)
    stale_proposal = AssistantProposal.create!(
      family: @user.family, chat: @chat, kind: "category_merge",
      params: { "source_category_ids" => [ source.id ], "target_category_id" => target.id },
      preview: { "count" => 0, "affected_ids_digest" => AssistantProposal.compute_digest([]) },
      status: "stale"
    )
    source.destroy!

    post repreview_assistant_proposal_path(stale_proposal)

    assert_response :unprocessable_entity
    assert_equal "stale", stale_proposal.reload.status
  end

  test "repreview on a proposal that is not stale returns 422 and never mutates preview" do
    original_preview = @proposal.preview

    post repreview_assistant_proposal_path(@proposal)

    assert_response :unprocessable_entity
    @proposal.reload
    assert_equal "proposed", @proposal.status
    # Regression guard: the legality check must happen BEFORE Resolver/preview
    # work runs, so a wrong-state repreview 422s without side effects.
    assert_equal original_preview, @proposal.preview
  end
end
