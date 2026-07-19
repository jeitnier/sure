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

  test "discard from proposed" do
    post discard_assistant_proposal_path(@proposal)
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

  test "repreview on a proposal that is not stale returns 422" do
    post repreview_assistant_proposal_path(@proposal)

    assert_response :unprocessable_entity
    assert_equal "proposed", @proposal.reload.status
  end
end
