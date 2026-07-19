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

  test "once one attachment overflows the cap, every later attachment degrades too even if individually small" do
    msg = UserMessage.create!(chat: @chat, content: "two files", ai_model: "claude-sonnet-4-5", status: "complete")
    big_blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("%PDF-1.4 " + ("x" * 200)), filename: "big.pdf", content_type: "application/pdf")
    small_blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("hi"), filename: "small.png", content_type: "image/png")
    msg.attachments.attach(big_blob)
    msg.attachments.attach(small_blob)

    # Cap is big enough for the small file alone, but not for the big file —
    # once the big file overflows, the latch must keep the small file out too.
    small_encoded_bytesize = Base64.strict_encode64("hi").bytesize
    messages = Provider::Anthropic::MessageFormatter.new(
      prompt: msg.content, current_message: msg, conversation_history: [],
      function_results: [], max_attachment_payload: small_encoded_bytesize).build

    content = messages.last[:content]
    types = content.map { |b| b[:type] }
    assert_equal [ "text" ], types
    assert_includes content.first[:text], "[attached: big.pdf"
    assert_includes content.first[:text], "[attached: small.png"
  end

  test "two under-cap attachments both make it through as native blocks" do
    msg = UserMessage.create!(chat: @chat, content: "two small files", ai_model: "claude-sonnet-4-5", status: "complete")
    blob_a = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("a"), filename: "a.png", content_type: "image/png")
    blob_b = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("b"), filename: "b.png", content_type: "image/png")
    msg.attachments.attach(blob_a)
    msg.attachments.attach(blob_b)

    messages = Provider::Anthropic::MessageFormatter.new(
      prompt: msg.content, current_message: msg, conversation_history: [],
      function_results: [], max_attachment_payload: 25.megabytes).build

    types = messages.last[:content].map { |b| b[:type] }
    assert_equal [ "text", "image", "image" ], types
  end

  test "attachment exactly at the cap boundary is kept (strict greater-than)" do
    exact_cap = Base64.strict_encode64(@msg.attachments.first.download).bytesize

    messages = Provider::Anthropic::MessageFormatter.new(
      prompt: @msg.content, current_message: @msg, conversation_history: [],
      function_results: [], max_attachment_payload: exact_cap).build

    types = messages.last[:content].map { |b| b[:type] }
    assert_equal [ "text", "document" ], types
  end
end
