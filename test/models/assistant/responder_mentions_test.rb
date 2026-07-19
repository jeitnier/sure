require "test_helper"

class Assistant::ResponderMentionsTest < ActiveSupport::TestCase
  test "responder appends mention context to the prompt" do
    user = users(:family_admin)
    cat = user.family.categories.create!(name: "Groceries", color: "#4da568")
    chat = user.chats.create!(title: "t")
    msg = chat.messages.create!(type: "UserMessage", content: "look at @[Groceries](category:#{cat.id})", ai_model: "claude-sonnet-4-5", status: "complete")

    llm = mock("llm")
    captured = nil
    fake_data = OpenStruct.new(function_requests: [], id: "r1", messages: [])
    fake = Provider::Response.new(success?: true, data: fake_data, error: nil)
    llm.expects(:chat_response).with { |prompt, **| captured = prompt; true }.returns(fake)

    responder = Assistant::Responder.new(message: msg, instructions: "i", function_tool_caller: stub(function_definitions: []), llm: llm)
    responder.respond
    assert_includes captured, "[Mentioned entities]"
    assert_includes captured, cat.id
  end
end
