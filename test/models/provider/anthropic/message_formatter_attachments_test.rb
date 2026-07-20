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
    assert_includes history_turn[:content].to_s, "[attached: doc.pdf"
    assert_includes history_turn[:content].to_s, "search_family_files"
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

  test "csv current turn emits a text-source document block with contents and title" do
    msg = UserMessage.create!(chat: @chat, content: "what's in this csv?", ai_model: "claude-sonnet-4-5", status: "complete")
    csv_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("name,amount
rent,1200
"), filename: "budget.csv", content_type: "text/csv")
    msg.attachments.attach(csv_blob)

    messages = Provider::Anthropic::MessageFormatter.new(
      prompt: msg.content, current_message: msg, conversation_history: [], function_results: []).build

    block = messages.last[:content].last
    assert_equal "document", block[:type]
    assert_equal "text", block[:source][:type]
    assert_equal "text/plain", block[:source][:media_type]
    assert_equal "name,amount
rent,1200
", block[:source][:data]
    assert_equal "budget.csv", block[:title]
  end

  test "csv over a tiny payload cap degrades to a marker" do
    msg = UserMessage.create!(chat: @chat, content: "what's in this csv?", ai_model: "claude-sonnet-4-5", status: "complete")
    csv_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("name,amount
rent,1200
"), filename: "budget.csv", content_type: "text/csv")
    msg.attachments.attach(csv_blob)

    messages = Provider::Anthropic::MessageFormatter.new(
      prompt: msg.content, current_message: msg, conversation_history: [],
      function_results: [], max_attachment_payload: 5).build

    types = messages.last[:content].map { |b| b[:type] }
    assert_equal [ "text" ], types
    assert_includes messages.last[:content].first[:text], "[attached: budget.csv"
  end

  test "csv raw bytes latch subsequent files even if individually small" do
    msg = UserMessage.create!(chat: @chat, content: "two files", ai_model: "claude-sonnet-4-5", status: "complete")
    csv_content = "name,amount
" + ("x" * 200)
    big_csv_blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(csv_content), filename: "big.csv", content_type: "text/csv")
    small_blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("hi"), filename: "small.png", content_type: "image/png")
    msg.attachments.attach(big_csv_blob)
    msg.attachments.attach(small_blob)

    small_encoded_bytesize = Base64.strict_encode64("hi").bytesize
    messages = Provider::Anthropic::MessageFormatter.new(
      prompt: msg.content, current_message: msg, conversation_history: [],
      function_results: [], max_attachment_payload: small_encoded_bytesize).build

    content = messages.last[:content]
    types = content.map { |b| b[:type] }
    assert_equal [ "text" ], types
    assert_includes content.first[:text], "[attached: big.csv"
    assert_includes content.first[:text], "[attached: small.png"
  end

  test "csv with invalid UTF-8 bytes is scrubbed instead of raising" do
    msg = UserMessage.create!(chat: @chat, content: "what's in this csv?", ai_model: "claude-sonnet-4-5", status: "complete")
    invalid_utf8_csv = "name,price\ncaf\xE9,\x224.50\x22\n".b
    csv_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(invalid_utf8_csv), filename: "bad_encoding.csv", content_type: "text/csv")
    msg.attachments.attach(csv_blob)

    messages = nil
    assert_nothing_raised do
      messages = Provider::Anthropic::MessageFormatter.new(
        prompt: msg.content, current_message: msg, conversation_history: [], function_results: []).build
    end

    block = messages.last[:content].last
    assert_equal "document", block[:type]
    data = block[:source][:data]
    assert data.valid_encoding?
    assert_equal Encoding::UTF_8, data.encoding
    assert_nothing_raised { data.to_json }
  end
end
