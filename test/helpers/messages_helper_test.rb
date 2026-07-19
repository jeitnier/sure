require "test_helper"

class MessagesHelperTest < ActionView::TestCase
  test "replaces a mention token with a chip span" do
    id = SecureRandom.uuid
    result = render_mention_chips("Check @[Groceries](category:#{id}) please")

    assert_includes result, "<span class=\"inline-flex items-center px-1.5 py-0.5 rounded-md bg-surface-inset text-xs font-medium\">@Groceries</span>"
    assert result.html_safe?
  end

  test "escapes html in surrounding content" do
    result = render_mention_chips("<script>alert(1)</script>")

    assert_includes result, "&lt;script&gt;"
    assert_not_includes result, "<script>"
  end

  test "leaves tokenless content unchanged aside from escaping" do
    result = render_mention_chips("no mentions here")

    assert_equal "no mentions here", result
  end
end
