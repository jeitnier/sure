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
end
