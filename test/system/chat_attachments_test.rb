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
end
