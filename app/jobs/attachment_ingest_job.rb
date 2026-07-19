class AttachmentIngestJob < ApplicationJob
  queue_as :low_priority

  def perform(attachment_id)
    attachment = ActiveStorage::Attachment.find_by(id: attachment_id)
    return unless attachment # message deleted before job ran

    unless VectorStore.configured?
      Rails.logger.info("[AttachmentIngestJob] no vector store configured — skipping #{attachment.filename}")
      return
    end

    message = attachment.record
    family = message.chat.user.family

    attachment.blob.open do |file|
      family.upload_document(
        file_content: file.read,
        filename: attachment.filename.to_s,
        metadata: { source: "chat_attachment", message_id: attachment.record_id }
      )
    end
  rescue StandardError => e
    Rails.logger.error("[AttachmentIngestJob] ingest failed for #{attachment_id}: #{e.class}: #{e.message}")
    # never user-facing; no retry storm — rely on default retry policy
  end
end
