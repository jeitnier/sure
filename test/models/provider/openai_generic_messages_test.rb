require "test_helper"

class Provider::OpenaiGenericMessagesTest < ActiveSupport::TestCase
  # The generic OpenAI-compatible path (LiteLLM / Ollama / LM Studio) has no
  # server-side conversation chain, so each follow-up request must replay the
  # turn's earlier tool rounds or the model loses its in-turn memory (the
  # 2026-07-25 runaway pagination loop).
  test "build_generic_messages replays prior rounds ahead of the current round" do
    provider = Provider::Openai.new("test-key")

    prior   = { call_id: "c1", name: "get_transactions", arguments: "{\"page\":1}", output: "page one" }
    current = { call_id: "c2", name: "get_transactions", arguments: "{\"page\":2}", output: "page two" }

    payload = provider.send(:build_generic_messages,
      prompt: "dedup these",
      function_results: [ current ],
      prior_function_results: [ prior ])

    tool_call_ids = payload.select { |m| m[:role] == "assistant" && m[:tool_calls] }
                           .flat_map { |m| m[:tool_calls].map { |tc| tc[:id] } }
    assert_equal [ "c1", "c2" ], tool_call_ids

    tool_msg_ids = payload.select { |m| m[:role] == "tool" }.map { |m| m[:tool_call_id] }
    assert_equal [ "c1", "c2" ], tool_msg_ids
  end
end
