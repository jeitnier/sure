require "test_helper"

class AssistantConfigurableTest < ActiveSupport::TestCase
  test "returns dashboard configuration by default" do
    chat = chats(:one)

    config = Assistant.config_for(chat)

    assert_not_empty config[:functions]
    assert_includes config[:instructions], "You help users understand their financial data"
  end

  test "dashboard instructions require a scope check before acting" do
    # The assistant advertises open-ended chat but has a fixed toolset, and
    # nothing told the user (or the model) where the edges are. Live 2026-07-25:
    # asked to de-duplicate transactions — a capability no tool provides — it
    # announced it would help, then thrashed until the loop guard killed the
    # turn. It must decline in its first sentence instead.
    instructions = Assistant.config_for(chats(:one))[:instructions]

    assert_includes instructions, "## What you cannot do"
    assert_match(/de-?duplicat/i, instructions, "must name de-duplication as out of scope")
    assert_match(/delet(e|ing)/i, instructions)
    assert_match(/say so (immediately|in your first)/i, instructions,
                 "must instruct the model to decline up front")
    assert_match(/single transaction|one transaction/i, instructions,
                 "must state that editing individual transactions is not supported")
  end

  test "dashboard instructions' capability claims match the real toolset" do
    # A prompt that lies about the toolset is the same bug in a new place, so
    # pin the two directions that actually drift: anything listed as writable
    # must have a tool, and the cannot-list must not name a tool that exists.
    instructions = Assistant.config_for(chats(:one))[:instructions]
    tool_names = Assistant.function_classes.map(&:name)

    %w[propose_bulk_recategorize create_category create_tag create_goal import_bank_statement].each do |claimed|
      assert_includes tool_names, claimed,
                      "instructions claim #{claimed} is available, but no such tool is registered"
    end

    cannot_section = instructions.split("## What you cannot do").last.split("Everything you CAN write").first
    assert_no_match(/import_bank_statement/, cannot_section,
                    "import_bank_statement exists — it must not appear in the cannot-do list")
  end

  test "dashboard instructions do not suppress stating limitations" do
    # Regression guard: the old prompt said "Do NOT apologize or explain
    # limitations", which directly contradicts the scope check above and
    # trained the model to attempt impossible work rather than decline.
    instructions = Assistant.config_for(chats(:one))[:instructions]

    assert_no_match(/Do NOT apologize or explain limitations/, instructions)
  end

  test "returns intro configuration without functions" do
    chat = chats(:intro)

    config = Assistant.config_for(chat)

    assert_equal [], config[:functions]
    assert_includes config[:instructions], "stage of life"
  end
end
