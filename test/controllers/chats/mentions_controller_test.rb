require "test_helper"

class Chats::MentionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @family.categories.create!(name: "Groceries", color: "#4da568")
    Category.create!(family: families(:empty), name: "Groceries Foreign", color: "#db5a54")
  end

  def sign_out
    @user.sessions.each do |session|
      delete session_path(session)
    end
  end

  test "returns grouped, family-scoped, filtered results" do
    get mentions_chats_path(q: "groc")
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ "Groceries" ], body["categories"].map { |c| c["label"] }
    assert body.key?("accounts") && body.key?("merchants") && body.key?("tags")
  end

  test "caps each group at 5" do
    8.times { |i| @family.categories.create!(name: "Cap #{i}", color: "#4da568") }
    get mentions_chats_path(q: "cap")
    assert_operator JSON.parse(response.body)["categories"].size, :<=, 5
  end

  test "requires auth" do
    sign_out
    get mentions_chats_path(q: "x")
    assert_response :redirect
  end
end
