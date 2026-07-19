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

  test "broadcasts an append to the chat on create and a replace on status update" do
    # Uses a fresh chat (not @chat, which already carries @proposal's own
    # creation broadcast from setup) and a single capture_turbo_stream_broadcasts
    # call around both actions -- mirroring assistant_message_test.rb /
    # user_message_test.rb, the codebase's existing idiom for this. The
    # turbo-rails helper reports every message ever sent to the stream (not
    # just what happens inside its block), so it only gives a clean count
    # when used once per stream, wrapping everything being asserted on.
    fresh_chat = @family.users.first.chats.create!(title: "Broadcast test chat")
    new_proposal = nil

    streams = capture_turbo_stream_broadcasts(fresh_chat) do
      new_proposal = AssistantProposal.create!(
        family: @family, chat: fresh_chat, kind: "bulk_recategorize",
        params: { "filter" => { "merchant_names" => [ "Amazon" ] }, "new_category" => "Shopping" },
        preview: { "count" => 1, "affected_ids_digest" => "xyz" },
        status: "proposed"
      )
      new_proposal.transition_to!("applying")
    end

    assert_equal 2, streams.size
    assert_equal "append", streams.first["action"]
    assert_equal fresh_chat.messages_target, streams.first["target"]
    assert_equal "replace", streams.last["action"]
    assert_equal new_proposal.dom_target, streams.last["target"]
  end

  test "broadcast_card rescues a broadcast failure instead of raising" do
    @proposal.chat.stubs(:broadcast_replace_to).raises(StandardError, "boom")
    assert_nothing_raised { @proposal.broadcast_card }
  end

  test "broadcast_card_append rescues a broadcast failure instead of raising" do
    proposal = AssistantProposal.new(
      family: @family, chat: @chat, kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "Amazon" ] }, "new_category" => "Shopping" },
      preview: { "count" => 1, "affected_ids_digest" => "xyz" },
      status: "proposed"
    )
    proposal.chat.stubs(:broadcast_append_to).raises(StandardError, "boom")
    assert_nothing_raised { proposal.save! }
  end
end
