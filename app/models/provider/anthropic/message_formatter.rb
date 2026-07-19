class Provider::Anthropic::MessageFormatter
  # Builds the `messages` array Anthropic expects.
  #
  # Inputs:
  # - prompt: text of the current user turn
  # - current_message: the Message record for the current user turn. When
  #   present and it has attachments, the final user turn is built as an
  #   array of content blocks (text + native image/document blocks) instead
  #   of a plain string, so Anthropic can read the files natively.
  # - conversation_history: chronologically-ordered Message records preceding
  #   the current user message (UserMessage / AssistantMessage)
  # - function_results: tool-result entries for the in-flight follow-up call
  #   (the responder feeds these back after executing the tool_use blocks
  #   returned by the previous request)
  # - max_attachment_payload: cap (bytes) on the total base64-encoded size of
  #   native attachment blocks in the current turn. Attachments are processed
  #   in order; once adding the next block's encoded payload would exceed the
  #   cap, that attachment (and — because size only grows — every attachment
  #   after it) degrades to a `[attached: <filename> — omitted, too large for
  #   this request]` marker appended to the text block instead.
  DOCUMENT_MEDIA_TYPE = "application/pdf"

  def initialize(prompt:, current_message: nil, conversation_history: [], function_results: [], max_attachment_payload: 25.megabytes)
    @prompt = prompt
    @current_message = current_message
    @conversation_history = conversation_history
    @function_results = function_results
    @max_attachment_payload = max_attachment_payload
  end

  def build
    messages = []

    @conversation_history.each do |historical|
      case historical
      when UserMessage
        messages << { role: "user", content: history_user_content(historical) } if historical.content.present? || historical_attachment_filenames(historical).present?
      when AssistantMessage
        messages.concat(assistant_history_blocks(historical))
      end
    end

    messages << { role: "user", content: current_turn_content }

    if @function_results.present?
      tool_use_blocks = @function_results.map { |fr| tool_use_block_from_result(fr) }
      tool_result_blocks = @function_results.map { |fr| tool_result_block(fr) }

      messages << { role: "assistant", content: tool_use_blocks }
      messages << { role: "user", content: tool_result_blocks }
    end

    messages
  end

  private
    # History turns never get native blocks (Anthropic caches/replays history
    # verbatim on every request, so re-sending base64 payloads for old turns
    # would blow past the payload cap almost immediately) — attachments
    # degrade to a filename marker appended to the turn's text.
    def history_user_content(historical)
      historical.content.to_s + attachment_marker_suffix(historical_attachment_filenames(historical))
    end

    def historical_attachment_filenames(message)
      return [] unless message.respond_to?(:attachments) && message.attachments.attached?

      message.attachments.map { |att| att.filename.to_s }
    end

    def attachment_marker_suffix(filenames)
      return "" if filenames.blank?

      " [attached: #{filenames.join(', ')}]"
    end

    # The current turn's content. Plain string when there's no current
    # message or it has no attachments (preserves the existing shape for all
    # non-attachment callers); an array of content blocks otherwise.
    def current_turn_content
      return @prompt.to_s unless @current_message&.respond_to?(:attachments) && @current_message.attachments.attached?

      text_block = { type: "text", text: @prompt.to_s }
      blocks = [ text_block ]
      running_bytes = 0
      overflow_filenames = []
      # Latches once true: after the first attachment overflows the cap,
      # every later attachment in the loop degrades to a marker too, even if
      # it would individually fit. Total encoded size only grows as blocks
      # are added, so admitting a later small file after an earlier skip
      # would silently exceed the cap the first overflow was meant to
      # enforce.
      overflowed = false

      @current_message.attachments.each do |attachment|
        if overflowed
          overflow_filenames << attachment.filename.to_s
          next
        end

        encoded = Base64.strict_encode64(attachment.download)

        if running_bytes + encoded.bytesize > @max_attachment_payload
          overflowed = true
          overflow_filenames << attachment.filename.to_s
          next
        end

        block = attachment_block(attachment, encoded)
        next if block.nil?

        blocks << block
        running_bytes += encoded.bytesize
      end

      if overflow_filenames.present?
        text_block[:text] = text_block[:text] +
          overflow_filenames.map { |name| " [attached: #{name} — omitted, too large for this request]" }.join
      end

      blocks
    end

    def attachment_block(attachment, encoded_data)
      content_type = attachment.content_type.to_s

      if content_type.start_with?("image/")
        {
          type: "image",
          source: { type: "base64", media_type: content_type, data: encoded_data }
        }
      elsif content_type == DOCUMENT_MEDIA_TYPE
        {
          type: "document",
          source: { type: "base64", media_type: DOCUMENT_MEDIA_TYPE, data: encoded_data }
        }
      end
    end

    # ToolCall records have no association-level order; enforce
    # chronological order here so message arrays are deterministic across
    # replays and Anthropic sees tool_use blocks in the order the model
    # originally emitted them.
    def ordered_tool_calls(assistant_message)
      assistant_message.tool_calls.sort_by { |tc| [ tc.created_at || Time.zone.at(0), tc.id.to_s ] }
    end

    def assistant_history_blocks(assistant_message)
      tool_calls = ordered_tool_calls(assistant_message).select { |tc| tool_call_id(tc).present? }

      blocks = []
      blocks.concat(tool_calls.map { |tc| tool_use_block_from_record(tc) }) if tool_calls.any?
      blocks << { type: "text", text: assistant_message.content.to_s } if assistant_message.content.present?

      return [] if blocks.empty?

      result = [ { role: "assistant", content: blocks } ]

      # If the assistant turn used tools, Anthropic requires a user turn with
      # matching tool_result blocks before the next assistant turn.
      if tool_calls.any?
        result << {
          role: "user",
          content: tool_calls.map { |tc| tool_result_block_from_record(tc) }
        }
      end

      result
    end

    # tool_use_id is required; skip tool_calls missing both identifiers
    # rather than sending `id: nil` and getting rejected by Anthropic.
    def tool_call_id(tool_call)
      tool_call.provider_call_id.presence || tool_call.provider_id.presence
    end

    def tool_use_block_from_record(tool_call)
      {
        type: "tool_use",
        id: tool_call_id(tool_call),
        name: tool_call.function_name,
        input: parse_arguments(tool_call.function_arguments)
      }
    end

    def tool_result_block_from_record(tool_call)
      {
        type: "tool_result",
        tool_use_id: tool_call_id(tool_call),
        content: serialize_output(tool_call.function_result)
      }
    end

    def tool_use_block_from_result(function_result)
      {
        type: "tool_use",
        id: function_result[:call_id],
        name: function_result[:name],
        input: parse_arguments(function_result[:arguments])
      }
    end

    def tool_result_block(function_result)
      {
        type: "tool_result",
        tool_use_id: function_result[:call_id],
        content: serialize_output(function_result[:output])
      }
    end

    # Anthropic's Messages API requires `tool_use.input` to be a JSON object
    # (map). Normalize any non-Hash result to `{}` so corrupt or legacy
    # ToolCall::Function records can't produce a payload Anthropic rejects.
    def parse_arguments(arguments)
      parsed =
        case arguments
        when nil then {}
        when Hash then arguments
        when String
          return {} if arguments.blank?
          JSON.parse(arguments)
        else arguments
        end

      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def serialize_output(output)
      case output
      when nil then ""
      when String then output
      else output.to_json
      end
    end
end
