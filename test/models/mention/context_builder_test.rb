require "test_helper"

class Mention::ContextBuilderTest < ActiveSupport::TestCase
  setup do
    @family = users(:family_admin).family
    @cat = @family.categories.create!(name: "Groceries", color: "#4da568")
    @chat = users(:family_admin).chats.create!(title: "t")
  end

  def message_with(content)
    @chat.messages.create!(type: "UserMessage", content: content, ai_model: "claude-sonnet-4-5", status: "complete")
  end

  test "returns empty string when no mentions" do
    assert_equal "", Mention::ContextBuilder.new(message_with("no tokens here"), @family).context
  end

  test "builds one line per resolved entity with id" do
    msg = message_with("clean @[Groceries](category:#{@cat.id})")
    ctx = Mention::ContextBuilder.new(msg, @family).context
    assert_includes ctx, "[Mentioned entities]"
    assert_includes ctx, %(category "Groceries" id=#{@cat.id})
  end

  test "unresolvable mentions contribute nothing" do
    msg = message_with("x @[Ghost](category:11111111-1111-1111-1111-111111111111)")
    assert_equal "", Mention::ContextBuilder.new(msg, @family).context
  end
end
