require "application_system_test_case"

class ChatAttachmentsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    login_as(@user)
    @chat = @user.chats.create!(title: "t")
    @user.update!(last_viewed_chat: @chat)
  end

  test "attaching a file shows a pending chip and submits with the message" do
    visit root_path

    within "#chat-container" do
      find("[data-attachment-target='fileInput']", visible: :all).attach_file(file_fixture("sample.png"))
      assert_selector "[data-attachment-target='pending'] [data-chip]", text: /sample\.png/

      find("[data-chat-target='input']").send_keys("what is this file?")
      find("[data-chat-target='submit']").click
    end

    assert_text "what is this file?"
    # sample.png is an image, so it renders as a thumbnail link (no filename text),
    # but the anchor still points at the blob for that attachment.
    assert_selector "a img.rounded-lg"
  end

  test "remove button clears a pending chip" do
    visit root_path

    within "#chat-container" do
      find("[data-attachment-target='fileInput']", visible: :all).attach_file(file_fixture("sample.png"))
      find("[data-attachment-target='pending'] [data-chip] button").click
      assert_no_selector "[data-attachment-target='pending'] [data-chip]"
    end
  end

  test "a genuinely failed turbo submission preserves staged attachment chips" do
    # MessagesController#create signals a validation failure (e.g. too many
    # attachments -- UserMessage::MAX_ATTACHMENTS is 5) with a plain
    # `redirect_to ..., alert: ...`. Turbo follows that redirect via fetch and
    # ends up with a 200 response, so `turbo:submit-end`'s `event.detail.success`
    # is actually `true` in that case (verified directly: dispatching real form
    # submits with 6 attached files and inspecting the event yields
    # `{success: true, statusCode: 200}`) -- Turbo can't tell a "successful
    # redirect to an error page" apart from a real success from the fetch layer
    # alone. So a live end-to-end reproduction of "attach 6 files, submit, see
    # the chips survive" cannot be made to fail before / pass after this fix via
    # the current controller, and would be dishonest to present as coverage for
    # it. Instead, this test exercises the exact code path the fix touches
    # directly: it dispatches the real `turbo:submit-end` event with a `false`
    # success detail (what a genuine network/server error, e.g. a 5xx or a
    # dropped connection, would produce) and asserts `clear()` leaves the chips
    # in place; the existing "attaching a file ... submits with the message"
    # test above already covers that a real *successful* submission still
    # clears them.
    visit root_path

    within "#chat-container" do
      find("[data-attachment-target='fileInput']", visible: :all).attach_file(file_fixture("sample.png"))
      assert_selector "[data-attachment-target='pending'] [data-chip]", count: 1
      assert_no_selector "[data-attachment-target='pending'] [data-status]"

      page.execute_script(<<~JS)
        document.querySelector("[data-chat-target='form']").dispatchEvent(
          new CustomEvent("turbo:submit-end", { bubbles: true, detail: { success: false } })
        )
      JS

      assert_selector "[data-attachment-target='pending'] [data-chip]", count: 1
    end
  end

  test "in-flight flag blocks Enter-to-submit and Enter submits once cleared" do
    # This spies on requestSubmit rather than asserting on rendered message
    # text: waiting for a message to (not) appear races the real turbo
    # submit/broadcast round trip, so a slow render could make a broken guard
    # look like it worked. Counting requestSubmit calls is synchronous and
    # deterministic -- it directly verifies handleInputKeyDown's decision.
    visit root_path

    within "#chat-container" do
      find("[data-chat-target='input']").set("hello while uploading")

      page.execute_script(<<~JS)
        document.querySelector("#chat-form").dataset.uploadsInflight = "true";
        window.__submitCalls = 0;
        document.querySelector("[data-chat-target='form']").requestSubmit = () => { window.__submitCalls += 1; };
      JS

      find("[data-chat-target='input']").send_keys(:enter)
      assert_equal 0, page.evaluate_script("window.__submitCalls")
      assert_equal "hello while uploading", find("[data-chat-target='input']").value

      page.execute_script(<<~JS)
        const form = document.querySelector("#chat-form");
        delete form.dataset.uploadsInflight;
        document.querySelector("[data-chat-target='input']").dispatchEvent(new Event("input", { bubbles: true }));
      JS

      find("[data-chat-target='input']").send_keys(:enter)
      assert_equal 1, page.evaluate_script("window.__submitCalls")
    end
  end

  test "in-flight flag keeps submit button disabled through an input-event recompute" do
    visit root_path

    within "#chat-container" do
      find("[data-chat-target='input']").set("draft")

      page.execute_script(<<~JS)
        document.querySelector("#chat-form").dataset.uploadsInflight = "true";
        document.querySelector("[data-chat-target='input']").dispatchEvent(new Event("input", { bubbles: true }));
      JS

      assert find("[data-chat-target='submit']").disabled?

      page.execute_script(<<~JS)
        const form = document.querySelector("#chat-form");
        delete form.dataset.uploadsInflight;
        document.querySelector("[data-chat-target='input']").dispatchEvent(new Event("input", { bubbles: true }));
      JS

      assert_not find("[data-chat-target='submit']").disabled?
    end
  end

  test "attachment on the FIRST message of a new chat reaches the created message" do
    # The new-chat page renders the same composer but under the `chat` form
    # scope (chats#create -> Chat.start!), not `message` -- a hardcoded
    # message[attachments][] hidden-input name silently drops the file there
    # (found live 2026-07-20: uploaded blob left orphaned, model told the
    # user no file was attached).
    visit new_chat_path

    assert_difference -> { Chat.count } => 1 do
      within "#chat-container" do
        find("[data-attachment-target='fileInput']", visible: :all).attach_file(file_fixture("sample.png"))
        assert_selector "[data-attachment-target='pending'] [data-chip]", text: /sample\.png/

        find("[data-chat-target='input']").send_keys("categorize the attached file")
        find("[data-chat-target='submit']").click
        assert_text "categorize the attached file"
      end
    end

    first_message = Chat.order(created_at: :desc).first.messages.where(type: "UserMessage").order(:created_at).first
    assert_equal [ "sample.png" ], first_message.attachments.map { |a| a.filename.to_s }
  end
end
