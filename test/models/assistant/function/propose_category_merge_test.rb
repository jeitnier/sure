require "test_helper"

class Assistant::Function::ProposeCategoryMergeTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @chat = @user.chats.create!(title: "t")
    @fn = Assistant::Function::ProposeCategoryMerge.new(@user, chat: @chat)
    @cat_a = @family.categories.create!(name: "CatA", color: "#e99537")
    @cat_b = @family.categories.create!(name: "CatB", color: "#4da568")
    account = @family.accounts.first
    2.times { |i| account.entries.create!(name: "txn #{i}", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new(category: @cat_a)) }
  end

  test "creates a proposed AssistantProposal and returns summary" do
    result = @fn.call({ "source_category_ids" => [ @cat_a.id ], "target_category_id" => @cat_b.id })
    assert result[:success]
    proposal = AssistantProposal.find(result[:proposal_id])
    assert_equal "proposed", proposal.status
    assert_equal "category_merge", proposal.kind
    assert_equal 2, proposal.preview["count"]
    assert_match(/user must click Apply/i, result[:message])
  end

  test "target inside sources surfaces as function error" do
    result = @fn.call({ "source_category_ids" => [ @cat_a.id ], "target_category_id" => @cat_a.id })
    assert_not result[:success]
    assert_equal 0, AssistantProposal.count
  end

  test "unknown target id surfaces as function error" do
    result = @fn.call({ "source_category_ids" => [ @cat_a.id ], "target_category_id" => "not-a-real-id" })
    assert_not result[:success]
    assert_equal 0, AssistantProposal.count
  end
end
