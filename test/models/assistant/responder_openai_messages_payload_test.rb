require "test_helper"

class Assistant::ResponderOpenaiMessagesPayloadTest < ActiveSupport::TestCase
  # Task 3 review carry-over: Provider::Openai#build_generic_messages prefers
  # `messages:` over `prompt` for the generic (self-hosted OpenAI-compatible)
  # path, but the CURRENT message's entry in `openai_messages_payload` used
  # raw `content` — so mention context (and attachment markers) never reached
  # self-hosted providers. Assert the augmented prompt lands in `messages:`.
  test "current message entry in messages payload carries mention context for non-Anthropic providers" do
    user = users(:family_admin)
    cat = user.family.categories.create!(name: "Groceries", color: "#4da568")
    chat = user.chats.create!(title: "t")
    msg = chat.messages.create!(type: "UserMessage", content: "look at @[Groceries](category:#{cat.id})", ai_model: "gpt-4o", status: "complete")

    llm = mock("llm")
    llm.stubs(:is_a?).with(Provider::Anthropic).returns(false)

    captured_messages = nil
    fake_data = OpenStruct.new(function_requests: [], id: "r1", messages: [])
    fake = Provider::Response.new(success?: true, data: fake_data, error: nil)
    llm.expects(:chat_response).with { |_prompt, **kwargs| captured_messages = kwargs[:messages]; true }.returns(fake)

    responder = Assistant::Responder.new(message: msg, instructions: "i", function_tool_caller: stub(function_definitions: []), llm: llm)
    responder.respond

    last_user_entry = captured_messages.reverse.find { |m| m[:role] == "user" }
    assert_includes last_user_entry[:content], "[Mentioned entities]"
  end
end
