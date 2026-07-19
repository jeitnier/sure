require "test_helper"

class Assistant::Function::ProposeMerchantMergeTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @chat = @user.chats.create!(title: "t")
    @fn = Assistant::Function::ProposeMerchantMerge.new(@user, chat: @chat)
    @m1 = @family.merchants.create!(name: "AMZN Mktp")
    @m2 = @family.merchants.create!(name: "Amazon.com")
    account = @family.accounts.first
    2.times { |i| account.entries.create!(name: "txn #{i}", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new(merchant: @m1)) }
  end

  test "creates a proposed AssistantProposal and returns summary" do
    result = @fn.call({ "source_merchant_ids" => [ @m1.id ], "target_merchant_id" => @m2.id })
    assert result[:success]
    proposal = AssistantProposal.find(result[:proposal_id])
    assert_equal "proposed", proposal.status
    assert_equal "merchant_merge", proposal.kind
    assert_equal 2, proposal.preview["count"]
    assert_match(/user must click Apply/i, result[:message])
  end

  test "target inside sources surfaces as function error" do
    result = @fn.call({ "source_merchant_ids" => [ @m1.id ], "target_merchant_id" => @m1.id })
    assert_not result[:success]
    assert_equal 0, AssistantProposal.count
  end

  test "unknown target id surfaces as function error" do
    result = @fn.call({ "source_merchant_ids" => [ @m1.id ], "target_merchant_id" => "not-a-real-id" })
    assert_not result[:success]
    assert_equal 0, AssistantProposal.count
  end
end
