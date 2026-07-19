require "test_helper"

class AssistantProposalTest < ActiveSupport::TestCase
  setup do
    @family = users(:family_admin).family
    @chat = @family.users.first.chats.create!(title: "Test chat")
    @proposal = AssistantProposal.create!(
      family: @family, chat: @chat, kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "Amazon" ] }, "new_category" => "Shopping" },
      preview: { "count" => 3, "affected_ids_digest" => "abc" },
      status: "proposed"
    )
  end

  test "valid kinds and statuses enforced" do
    assert_raises(ActiveRecord::RecordInvalid) do
      AssistantProposal.create!(family: @family, chat: @chat, kind: "nope", status: "proposed", params: {}, preview: {})
    end
  end

  test "legal transition proposed -> applying" do
    @proposal.transition_to!("applying")
    assert_equal "applying", @proposal.reload.status
  end

  test "illegal transition proposed -> undone raises" do
    assert_raises(AssistantProposal::InvalidTransition) { @proposal.transition_to!("undone") }
  end

  test "illegal transition applied -> applying raises" do
    @proposal.update!(status: "applied")
    assert_raises(AssistantProposal::InvalidTransition) { @proposal.transition_to!("applying") }
  end

  test "compute_digest is order independent" do
    assert_equal AssistantProposal.compute_digest([ "b", "a" ]), AssistantProposal.compute_digest([ "a", "b" ])
    assert_not_equal AssistantProposal.compute_digest([ "a" ]), AssistantProposal.compute_digest([ "a", "b" ])
  end

  test "max_records defaults to 2000 and reads env" do
    assert_equal 2000, AssistantProposal.max_records
    ENV["ASSISTANT_PROPOSAL_MAX_RECORDS"] = "50"
    assert_equal 50, AssistantProposal.max_records
  ensure
    ENV.delete("ASSISTANT_PROPOSAL_MAX_RECORDS")
  end
end
