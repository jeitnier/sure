class Assistant::Responder
  # Raised when the LLM keeps requesting tool calls past the per-turn cap.
  # Caught by Assistant::Builtin#respond_to → chat.add_error so the user sees
  # an actionable message instead of a perpetual "Thinking…" indicator (#2241).
  class ToolCallLimitError < StandardError; end

  # Raised when the model requests only tool calls it has already made this
  # turn, for the second round in a row — a runaway loop (observed live
  # 2026-07-25: pages 1-6 re-fetched identically every round until the cap).
  # One full-repeat round is tolerated: a re-read after a write is legitimate.
  # Subclasses ToolCallLimitError so every existing rescue path handles it.
  class ToolCallLoopError < ToolCallLimitError; end

  # Cap on follow-up tool-roundtrips per user turn. The first response (which
  # may itself request tools) is NOT counted — this is the number of
  # additional LLM-tool roundtrips after that. Capped to keep recursive
  # tool-call loops from running up unbounded spend on paid APIs, but
  # overridable via `ASSISTANT_MAX_TOOL_CALL_ITERATIONS` for self-hosted
  # deployments where the model is local and the cost is just latency.
  DEFAULT_MAX_TOOL_CALL_ITERATIONS = 5

  def initialize(message:, instructions:, function_tool_caller:, llm:)
    @message = message
    @instructions = instructions
    @function_tool_caller = function_tool_caller
    @llm = llm
  end

  def on(event_name, &block)
    listeners[event_name.to_sym] << block
  end

  def respond(previous_response_id: nil)
    # Track whether response was handled by streamer
    response_handled = false

    # For the first response
    streamer = proc do |chunk|
      case chunk.type
      when "output_text"
        emit(:output_text, chunk.data)
      when "response"
        response = chunk.data
        response_handled = true

        if response.function_requests.any?
          handle_follow_up_response(response, iteration: 1)
        else
          emit(:response, { id: response.id })
        end
      end
    end

    response = get_llm_response(streamer: streamer, previous_response_id: previous_response_id)

    # For synchronous (non-streaming) responses, handle function requests if not already handled by streamer
    unless response_handled
      if response && response.function_requests.any?
        handle_follow_up_response(response, iteration: 1)
      elsif response
        emit(:response, { id: response.id })
      end
    end
  end

  private
    attr_reader :message, :instructions, :function_tool_caller, :llm

    # Execute the tool requests on `response`, send the results back to the
    # LLM, and iterate if the follow-up itself requests more tools — capped
    # at `max_tool_call_iterations`. The previous implementation silently
    # dropped second-round function requests, leaving the assistant message
    # in "pending" forever (#2241).
    #
    # Each recursive call sends the CURRENT round's function_results plus,
    # separately, the accumulated `prior_function_results` from earlier
    # rounds this turn. Providers without a server-side conversation chain
    # (Anthropic, generic OpenAI-compatible) replay prior + current so the
    # model keeps its in-turn memory — without this, a paginated read lost
    # earlier pages every round and the model re-fetched them in a runaway
    # loop (observed live 2026-07-25). OpenAI's Responses API ignores the
    # prior results: `previous_response_id` already chains server-side, and
    # replaying outputs with stale call_ids there is an error.
    def handle_follow_up_response(response, iteration:, prior_results: [])
      next_response = nil
      next_response_handled = false

      streamer = proc do |chunk|
        case chunk.type
        when "output_text"
          emit(:output_text, chunk.data)
        when "response"
          next_response = chunk.data
          next_response_handled = true
        end
      end

      record_fulfilled_requests(response.function_requests)
      function_tool_calls = function_tool_caller.fulfill_requests(response.function_requests)

      emit(:response, {
        id: response.id,
        function_tool_calls: function_tool_calls
      })

      current_results = function_tool_calls.map(&:to_result)

      sync_response = get_llm_response(
        streamer: streamer,
        function_results: current_results,
        prior_function_results: prior_results,
        previous_response_id: response.id
      )

      next_response ||= sync_response unless next_response_handled

      return unless next_response

      if next_response.function_requests.any?
        guard_against_repeat_loop!(next_response.function_requests)
        if iteration >= max_tool_call_iterations
          raise ToolCallLimitError,
                I18n.t("chat.errors.tool_call_limit_exceeded", max: max_tool_call_iterations)
        end
        handle_follow_up_response(next_response, iteration: iteration + 1, prior_results: prior_results + current_results)
      else
        emit(:response, { id: next_response.id })
      end
    end

    def record_fulfilled_requests(requests)
      requests.each { |request| fulfilled_request_signatures << request_signature(request) }
    end

    # Cuts a runaway loop at the SECOND round whose requests are all exact
    # repeats of calls already fulfilled this turn. A single full-repeat
    # round passes: re-reading the same query after a write is legitimate.
    def guard_against_repeat_loop!(requests)
      return unless requests.all? { |request| fulfilled_request_signatures.include?(request_signature(request)) }

      @full_repeat_rounds = @full_repeat_rounds.to_i + 1
      return if @full_repeat_rounds < 2

      raise ToolCallLoopError, I18n.t("chat.errors.tool_call_loop")
    end

    def request_signature(request)
      "#{request.function_name}:#{request.function_args}"
    end

    def fulfilled_request_signatures
      @fulfilled_request_signatures ||= Set.new
    end

    def max_tool_call_iterations
      @max_tool_call_iterations ||= begin
        raw = ENV["ASSISTANT_MAX_TOOL_CALL_ITERATIONS"]
        parsed = Integer(raw, 10) rescue nil
        # Reject zero/negative so the loop can't be configured into a no-op
        # that silently regresses the original bug.
        parsed && parsed.positive? ? parsed : DEFAULT_MAX_TOOL_CALL_ITERATIONS
      end
    end

    def get_llm_response(streamer:, function_results: [], prior_function_results: [], previous_response_id: nil)
      response = llm.chat_response(
        prompt_with_mentions,
        model: message.ai_model,
        instructions: instructions,
        functions: function_tool_caller.function_definitions,
        function_results: function_results,
        prior_function_results: prior_function_results,
        messages: openai_messages_payload,
        conversation_history: chat_message_records,
        current_message: message,
        streamer: streamer,
        previous_response_id: previous_response_id,
        session_id: chat_session_id,
        user_identifier: chat_user_identifier,
        family: message.chat&.user&.family
      )

      unless response.success?
        raise response.error
      end

      response.data
    end

    def emit(event_name, payload = nil)
      listeners[event_name.to_sym].each { |block| block.call(payload) }
    end

    def listeners
      @listeners ||= Hash.new { |h, k| h[k] = [] }
    end

    def chat_session_id
      chat&.id&.to_s
    end

    def chat_user_identifier
      return unless chat&.user_id

      ::Digest::SHA256.hexdigest(chat.user_id.to_s)
    end

    def chat
      @chat ||= message.chat
    end

    def prompt_with_mentions
      @prompt_with_mentions ||= begin
        text = message.content.to_s + Mention::ContextBuilder.new(message, message.chat.user.family).context
        # Anthropic gets the raw attachments (native image/document blocks
        # built by Provider::Anthropic::MessageFormatter from `current_message`
        # for the current turn) — it doesn't need a text marker. Every other
        # provider (OpenAI, and OpenAI-compatible self-hosted providers) can't
        # read attachments at all, so tell the model they exist via a plain
        # marker instead. LLM-facing text, not user-facing — i18n not required.
        text += attachment_marker unless llm.is_a?(Provider::Anthropic)
        text
      end
    end

    # `message` here is always the current UserMessage — attachments live on
    # the Message base class, but no code path attaches files to an
    # AssistantMessage today. If that ever changes, this branch (and the
    # Anthropic history-marker branch in MessageFormatter) will need to add
    # markers for AssistantMessage attachments too.
    def attachment_marker
      return "" unless message.respond_to?(:attachments) && message.attachments.attached?

      names = message.attachments.map { |att| att.filename.to_s }.join(", ")
      "\n\n[attached: #{names} — this provider cannot read attachments]"
    end

    # Memoized fetch — both `chat_message_records` and `openai_messages_payload`
    # derive their shape from this one in-memory array so a single chat turn
    # fires one history query instead of two.
    def complete_chat_messages
      return @complete_chat_messages if defined?(@complete_chat_messages)

      @complete_chat_messages =
        if chat&.messages
          chat.messages
              .where(type: [ "UserMessage", "AssistantMessage" ], status: "complete")
              .includes(:tool_calls)
              .ordered
              .to_a
        else
          []
        end
    end

    # Raw Message records preceding the current turn — providers that build
    # their own native message shape (Anthropic) consume this directly so they
    # do not have to round-trip through the OpenAI-shaped payload below.
    def chat_message_records
      complete_chat_messages.reject { |m| m.id == message.id }
    end

    # Builds the OpenAI-shaped messages payload (role: "user" | "assistant" |
    # "tool"; tool_call_id pairing) consumed by Provider::Openai's generic
    # chat path. Anthropic uses chat_message_records instead.
    def openai_messages_payload
      messages = []
      complete_chat_messages.each do |chat_message|
        if chat_message.tool_calls.any?
          # content_for_openai_payload's current-message substitution never
          # fires here in practice: the current message is always a freshly
          # created UserMessage with no tool_calls of its own, so this branch
          # only ever sees prior (non-current) chat_message records.
          messages << {
            role: chat_message.role,
            content: content_for_openai_payload(chat_message),
            tool_calls: chat_message.tool_calls.map(&:to_tool_call)
          }

          chat_message.tool_calls.map(&:to_result).each do |fn_result|
            # Handle nil explicitly to avoid serializing to "null"
            output = fn_result[:output]
            content = if output.nil?
              ""
            elsif output.is_a?(String)
              output
            else
              output.to_json
            end

            messages << {
              role: "tool",
              tool_call_id: fn_result[:call_id],
              name: fn_result[:name],
              content: content
            }
          end

        elsif !chat_message.content.blank?
          messages << { role: chat_message.role, content: content_for_openai_payload(chat_message) }
        end
      end
      messages
    end

    # The CURRENT message's raw `content` never reaches this payload — it
    # must carry the augmented prompt (mention context + attachment markers
    # for non-Anthropic providers) built by `prompt_with_mentions`, or that
    # context silently never reaches self-hosted OpenAI-compatible providers,
    # which prefer `messages:` over `prompt` (Task 3 review carry-over).
    def content_for_openai_payload(chat_message)
      return prompt_with_mentions if chat_message.id == message.id

      chat_message.content || ""
    end
end
