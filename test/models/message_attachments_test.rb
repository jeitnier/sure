require "test_helper"

class MessageAttachmentsTest < ActiveSupport::TestCase
  setup do
    @chat = users(:family_admin).chats.create!(title: "t")
  end

  def build_message_with_blob(content_type:, byte_size: 1.kilobyte, count: 1)
    msg = UserMessage.new(chat: @chat, content: "x", ai_model: "claude-sonnet-4-5")
    count.times do |i|
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("a" * byte_size), filename: "f#{i}.bin", content_type: content_type)
      msg.attachments.attach(blob)
    end
    msg
  end

  test "accepts png under limits" do
    assert build_message_with_blob(content_type: "image/png").valid?
  end

  test "accepts csv under limits" do
    assert build_message_with_blob(content_type: "text/csv").valid?
  end

  test "rejects disallowed content type" do
    msg = build_message_with_blob(content_type: "application/zip")
    assert_not msg.valid?
    assert_match(/type/i, msg.errors.full_messages.to_sentence)
  end

  test "rejects oversize file" do
    blob = ActiveStorage::Blob.new(filename: "big.pdf", content_type: "application/pdf", byte_size: 11.megabytes, checksum: "x", key: SecureRandom.hex, identified: true)
    msg = UserMessage.new(chat: @chat, content: "x", ai_model: "claude-sonnet-4-5")
    msg.attachments.attach(blob)
    assert_not msg.valid?
  end

  test "rejects more than 5 attachments" do
    assert_not build_message_with_blob(content_type: "image/png", count: 6).valid?
  end
end
