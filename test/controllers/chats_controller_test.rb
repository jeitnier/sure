require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = families(:dylan_family)
    sign_in @user
  end

  test "gets index" do
    get chats_url
    assert_response :success
  end

  test "creates chat" do
    assert_difference("Chat.count") do
      post chats_url, params: { chat: { content: "Hello", ai_model: "gpt-4.1" } }
    end

    assert_redirected_to chat_path(Chat.order(created_at: :desc).first, thinking: true)
  end

  test "creates chat whose first message keeps its attachments" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("Total\n77.64\n97.00\n"), filename: "orders.csv", content_type: "text/csv")

    assert_difference("Chat.count") do
      post chats_url, params: { chat: { content: "Categorize these", ai_model: "gpt-4.1", attachments: [ blob.signed_id ] } }
    end

    first_message = Chat.order(created_at: :desc).first.messages.where(type: "UserMessage").order(:created_at).first
    assert_equal [ "orders.csv" ], first_message.attachments.map { |a| a.filename.to_s }
  end

  test "shows chat" do
    get chat_url(chats(:one))
    assert_response :success
  end

  test "shows persisted proposal cards on reload, surviving after the broadcast-only append is gone" do
    # Proposal cards are otherwise only ever pushed via Turbo Stream broadcast
    # (append on create, replace on status change) -- a plain page load/reload
    # never replayed them, so an applied proposal's only Undo affordance was
    # permanently lost the moment the page refreshed.
    chat = chats(:one)

    proposed = AssistantProposal.create!(
      family: @family, chat: chat, kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "X" ] }, "new_category" => "Y" },
      preview: { "count" => 1, "affected_ids_digest" => "d1" }, status: "proposed")

    get chat_url(chat)

    assert_response :success
    assert_includes response.body, proposed.dom_target
    assert_includes response.body, I18n.t("assistant_proposals.card.apply")

    applied = AssistantProposal.create!(
      family: @family, chat: chat, kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "X" ] }, "new_category" => "Y" },
      preview: { "count" => 1, "affected_ids_digest" => "d2" }, status: "applied", applied_at: Time.current)

    get chat_url(chat)

    assert_response :success
    assert_includes response.body, applied.dom_target
    assert_includes response.body, I18n.t("assistant_proposals.card.undo")
  end

  test "destroys chat" do
    assert_difference("Chat.count", -1) do
      delete chat_url(chats(:one))
    end

    assert_redirected_to chats_url
  end

  test "should not allow access to other user's chats" do
    other_user = users(:family_member)
    other_chat = Chat.create!(user: other_user, title: "Other User's Chat")

    get chat_url(other_chat)
    assert_response :not_found

    delete chat_url(other_chat)
    assert_response :not_found
  end
end
