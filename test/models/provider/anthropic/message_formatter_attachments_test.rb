require "test_helper"

class Provider::Anthropic::MessageFormatterAttachmentsTest < ActiveSupport::TestCase
  setup do
    @chat = users(:family_admin).chats.create!(title: "t")
    @msg = UserMessage.create!(chat: @chat, content: "read this", ai_model: "claude-sonnet-4-5", status: "complete")
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("%PDF-1.4 fake"), filename: "doc.pdf", content_type: "application/pdf")
    @msg.attachments.attach(blob)
  end

  test "current turn emits text + document blocks" do
    messages = Provider::Anthropic::MessageFormatter.new(prompt: @msg.content, current_message: @msg, conversation_history: [], function_results: []).build
    user_turn = messages.last
    types = user_turn[:content].map { |b| b[:type] }
    assert_equal [ "text", "document" ], types
    assert_equal "application/pdf", user_turn[:content].last[:source][:media_type]
  end

  test "history turns degrade to filename markers" do
    later = UserMessage.create!(chat: @chat, content: "and now?", ai_model: "claude-sonnet-4-5", status: "complete")
    messages = Provider::Anthropic::MessageFormatter.new(prompt: later.content, current_message: later, conversation_history: [ @msg ], function_results: []).build
    history_turn = messages.first
    assert_includes history_turn[:content].to_s, "[attached: doc.pdf]"
    assert_not_includes history_turn[:content].to_s, "base64"
  end

  test "payload cap degrades overflow files to markers" do
    messages = Provider::Anthropic::MessageFormatter.new(
      prompt: @msg.content, current_message: @msg, conversation_history: [],
      function_results: [], max_attachment_payload: 10).build
    types = messages.last[:content].map { |b| b[:type] }
    assert_equal [ "text" ], types
    assert_includes messages.last[:content].first[:text], "[attached: doc.pdf"
  end
end
