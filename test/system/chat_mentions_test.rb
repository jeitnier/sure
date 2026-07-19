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

  test "typing a query with no matches shows the localized empty state" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      @user.update!(ai_enabled: true)
      visit root_path

      within "#chat-container" do
        find("[data-chat-target='input']").click
        find("[data-chat-target='input']").send_keys("@zzzz")
        assert_selector "[data-mention-target='menu']", visible: true
        assert_text I18n.t("messages.chat_form.mention_types.empty")
      end
    end
  end

  test "Enter with the popover open selects the highlighted mention instead of submitting" do
    # Regression coverage for the Enter-key collision between mention and chat
    # controllers: handleInputKeyDown listed before mention#onKeydown in the
    # textarea's data-action, so chat_controller used to see Enter first and
    # call requestSubmit() before mention_controller could consume the
    # keystroke to select the highlighted entry. Spies on requestSubmit
    # (same idiom as chat_attachments_test.rb's in-flight-flag Enter test)
    # rather than waiting for a message to (not) appear, since that race
    # could make a broken guard look like it worked.
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      @user.update!(ai_enabled: true)
      visit root_path

      within "#chat-container" do
        find("[data-chat-target='input']").click
        find("[data-chat-target='input']").send_keys("@groc")
        assert_selector "[data-mention-target='menu']", visible: true

        page.execute_script(<<~JS)
          window.__submitCalls = 0;
          document.querySelector("[data-chat-target='form']").requestSubmit = () => { window.__submitCalls += 1; };
        JS

        find("[data-chat-target='input']").send_keys(:enter)

        assert_equal 0, page.evaluate_script("window.__submitCalls")
        input_value = find("[data-chat-target='input']").value
        assert_match(/@\[Groceries\]\(category:[0-9a-f\-]+\)/, input_value)
        assert_no_selector "[data-mention-target='menu']", visible: true

        # Popover is now closed, so a second Enter submits normally.
        find("[data-chat-target='input']").send_keys(:enter)
        assert_equal 1, page.evaluate_script("window.__submitCalls")
      end
    end
  end
end
