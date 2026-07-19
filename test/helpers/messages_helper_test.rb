require "test_helper"

class MessagesHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "renders markdown formatting" do
    result = render_message_content("**bold**")

    assert_includes result, "<strong>bold</strong>"
    assert result.html_safe?
  end

  test "replaces a mention token with a chip span" do
    id = SecureRandom.uuid
    result = render_message_content("Check @[Groceries](category:#{id}) please")

    assert_includes result, "<span class=\"inline-flex items-center px-1.5 py-0.5 rounded-md bg-surface-inset text-xs font-medium\">@Groceries</span>"
    assert result.html_safe?
  end

  test "escapes a mention label exactly once" do
    id = SecureRandom.uuid
    result = render_message_content("@[Foo & Bar](tag:#{id})")

    assert_includes result, "@Foo &amp; Bar</span>"
    assert_not_includes result, "&amp;amp;"
  end

  test "neutralizes raw html in surrounding content" do
    result = render_message_content("<script>alert(1)</script>")

    assert_includes result, "&lt;script&gt;"
    assert_not_includes result, "<script>"
  end

  test "keeps line breaks and paragraphs for tokenless multi-line content" do
    result = render_message_content("line one\nline two")

    assert_includes result, "<br>"
    assert_includes result, "line one"
    assert_includes result, "line two"
  end
end
