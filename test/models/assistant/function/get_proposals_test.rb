require "test_helper"

class Assistant::Function::GetProposalsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @chat = @user.chats.create!(title: "t")
    @fn = Assistant::Function::GetProposals.new(@user, chat: @chat)
  end

  test "lists own family's proposals" do
    other_user = users(:empty)
    other_chat = other_user.chats.create!(title: "t")

    mine = AssistantProposal.create!(family: @family, chat: @chat, kind: "bulk_recategorize", params: {}, preview: { "count" => 1 }, status: "proposed")
    AssistantProposal.create!(family: other_user.family, chat: other_chat, kind: "bulk_recategorize", params: {}, preview: { "count" => 1 }, status: "proposed")

    result = @fn.call({})
    ids = result[:proposals].map { |p| p[:id] }
    assert_includes ids, mine.id
    assert_equal 1, result[:proposals].size
  end

  test "filters by status" do
    proposed = AssistantProposal.create!(family: @family, chat: @chat, kind: "bulk_recategorize", params: {}, preview: { "count" => 1 }, status: "proposed")
    applied = AssistantProposal.create!(family: @family, chat: @chat, kind: "bulk_recategorize", params: {}, preview: { "count" => 1 }, status: "proposed")
    applied.update!(status: "applying")
    applied.update!(status: "applied")

    result = @fn.call({ "status" => "applied" })
    ids = result[:proposals].map { |p| p[:id] }
    assert_equal [ applied.id ], ids
  end
end
