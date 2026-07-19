require "test_helper"

class AttachmentIngestJobTest < ActiveJob::TestCase
  setup do
    @chat = users(:family_admin).chats.create!(title: "t")
    @msg = UserMessage.new(chat: @chat, content: "x", ai_model: "claude-sonnet-4-5")
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("data"), filename: "r.pdf", content_type: "application/pdf")
    @msg.attachments.attach(blob)
    @msg.save!
  end

  test "user message create enqueues one ingest job per attachment" do
    assert_enqueued_with(job: AttachmentIngestJob) {
      m = UserMessage.new(chat: @chat, content: "y", ai_model: "claude-sonnet-4-5")
      m.attachments.attach(ActiveStorage::Blob.create_and_upload!(io: StringIO.new("d2"), filename: "s.png", content_type: "image/png"))
      m.save!
    }
  end

  test "no adapter configured is a clean no-op" do
    VectorStore.stubs(:configured?).returns(false)
    assert_nothing_raised { AttachmentIngestJob.perform_now(@msg.attachments.first.id) }
  end

  test "configured adapter receives the file" do
    adapter = mock("adapter")
    adapter.stubs(:create_store).returns(VectorStore::Response.new(success?: true, data: { id: "store_1" }, error: nil))
    adapter.expects(:upload_file).once.returns(VectorStore::Response.new(success?: true, data: { file_id: "file_1" }, error: nil))
    VectorStore.stubs(:configured?).returns(true)
    VectorStore.stubs(:adapter).returns(adapter)
    AttachmentIngestJob.perform_now(@msg.attachments.first.id)
  end
end
