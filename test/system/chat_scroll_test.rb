require "application_system_test_case"

class ChatScrollTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    login_as(@user)
    @chat = @user.chats.create!(title: "scroll test")
    30.times do |i|
      @chat.messages.create!(type: "UserMessage", content: "filler message #{i} #{"x" * 80}", ai_model: "claude-sonnet-4-5", status: "complete")
    end
    # The scroll pane only exists inside the persistent right-sidebar chat
    # widget (#chat-container); visiting the standalone chats/:id page renders
    # in the main content column instead, so route through root_path + the
    # user's last-viewed chat, matching the idiom in test/system/chats_test.rb.
    @user.update!(last_viewed_chat: @chat)
  end

  test "chat opens pinned to the newest message" do
    visit root_path

    within "#chat-container" do
      assert_selector "[data-controller~='chat-scroll']"
    end

    scroll_state = page.evaluate_script(<<~JS)
      (() => { const el = document.querySelector('#chat-container [data-controller~="chat-scroll"]');
               return el ? el.scrollHeight - el.scrollTop - el.clientHeight : -1 })()
    JS
    assert scroll_state >= 0
    assert_operator scroll_state, :<=, 64, "expected pane pinned to bottom, was #{scroll_state}px away"
  end

  test "scrolled-up position survives navigation" do
    visit root_path

    within "#chat-container" do
      assert_selector "[data-controller~='chat-scroll']"
    end

    page.execute_script(<<~JS)
      const el = document.querySelector('#chat-container [data-controller~="chat-scroll"]');
      el.scrollTop = 100; el.dispatchEvent(new Event('scroll'));
    JS
    sleep 0.3 # allow throttled handler to persist

    visit transactions_path
    visit root_path

    within "#chat-container" do
      assert_selector "[data-controller~='chat-scroll']"
    end

    top = page.evaluate_script(%q{document.querySelector('#chat-container [data-controller~="chat-scroll"]').scrollTop})
    assert_in_delta 100, top, 40, "expected restored position near 100, got #{top}"
  end

  test "sending own message always re-pins to bottom even if scrolled up" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      visit root_path

      within "#chat-container" do
        assert_selector "[data-controller~='chat-scroll']"
      end

      # Scroll up (unpin) and wait for the throttled persist handler.
      page.execute_script(<<~JS)
        const el = document.querySelector('#chat-container [data-controller~="chat-scroll"]');
        el.scrollTop = 100; el.dispatchEvent(new Event('scroll'));
      JS
      sleep 0.3

      Chat.any_instance.expects(:ask_assistant_later)

      within "#chat-form" do
        find("[data-chat-target='input']").set("Can you help with my finances?")
        find("[data-chat-target='submit']").click
      end

      assert_text "Can you help with my finances?"

      distance = page.evaluate_script(<<~JS)
        (() => { const el = document.querySelector('#chat-container [data-controller~="chat-scroll"]');
                 return el ? el.scrollHeight - el.scrollTop - el.clientHeight : -1 })()
      JS
      assert_operator distance, :<=, 64, "expected pane re-pinned to bottom after sending own message, was #{distance}px away"
    end
  end
end
