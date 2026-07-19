class UserMessage < Message
  ALLOWED_ATTACHMENT_TYPES = %w[image/png image/jpeg image/webp application/pdf].freeze
  MAX_ATTACHMENT_BYTES = 10.megabytes
  MAX_ATTACHMENTS = 5

  validates :ai_model, presence: true
  validate :validate_attachments, if: -> { attachments.attached? }

  after_create_commit :request_response_later

  def role
    "user"
  end

  def request_response_later
    chat.ask_assistant_later(self)
  end

  def request_response(assistant_message: nil)
    chat.ask_assistant(self, assistant_message: assistant_message)
  end

  private
    def validate_attachments
      errors.add(:attachments, :too_many, max: MAX_ATTACHMENTS) if attachments.size > MAX_ATTACHMENTS

      attachments.each do |attachment|
        unless ALLOWED_ATTACHMENT_TYPES.include?(attachment.content_type)
          errors.add(:attachments, :invalid_type, filename: attachment.filename.to_s)
        end

        if attachment.byte_size.to_i > MAX_ATTACHMENT_BYTES
          errors.add(:attachments, :too_large, filename: attachment.filename.to_s, max_mb: MAX_ATTACHMENT_BYTES / 1.megabyte)
        end
      end
    end
end
