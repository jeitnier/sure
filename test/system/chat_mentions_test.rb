require "application_system_test_case"

class ChatMentionsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    login_as(@user)
    @user.family.categories.create!(name: "Groceries", color: "#4da568")
    @chat = @user.chats.create!(title: "t")
    @user.update!(last_viewed_chat: @chat)
  end

  test "typing @ opens the popover and selection inserts a token" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      @user.update!(ai_enabled: true)
      visit root_path

      within "#chat-container" do
        find("[data-chat-target='input']").click
        find("[data-chat-target='input']").send_keys("@groc")
        assert_selector "[data-mention-target='menu']", visible: true
        assert_text "Groceries"
        find("[data-mention-target='menu'] li", text: "Groceries").click
        input_value = find("[data-chat-target='input']").value
        assert_match(/@\[Groceries\]\(category:[0-9a-f\-]+\)/, input_value)
      end
    end
  end

  test "escape closes the popover" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      @user.update!(ai_enabled: true)
      visit root_path

      within "#chat-container" do
        find("[data-chat-target='input']").send_keys("@g")
        assert_selector "[data-mention-target='menu']", visible: true
        find("[data-chat-target='input']").send_keys(:escape)
        assert_no_selector "[data-mention-target='menu']", visible: true
      end
    end
  end
end
