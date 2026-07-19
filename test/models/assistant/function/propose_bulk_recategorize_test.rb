require "test_helper"

class Assistant::Function::ProposeBulkRecategorizeTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @chat = @user.chats.create!(title: "t")
    @fn = Assistant::Function::ProposeBulkRecategorize.new(@user, chat: @chat)
    @cat = @family.categories.create!(name: "Shopping", color: "#e99537")
    account = @family.accounts.first
    merchant = @family.merchants.create!(name: "AMZN")
    2.times { |i| account.entries.create!(name: "amzn #{i}", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new(merchant: merchant)) }
  end

  test "creates a proposed AssistantProposal and returns summary" do
    result = @fn.call({ "filter" => { "merchant_names" => [ "AMZN" ] }, "new_category" => "Shopping" })
    assert result[:success]
    proposal = AssistantProposal.find(result[:proposal_id])
    assert_equal "proposed", proposal.status
    assert_equal 2, proposal.preview["count"]
    assert_match(/user must click Apply/i, result[:message])
  end

  test "over-cap returns error and creates no proposal" do
    ENV["ASSISTANT_PROPOSAL_MAX_RECORDS"] = "1"
    result = @fn.call({ "filter" => { "merchant_names" => [ "AMZN" ] }, "new_category" => "Shopping" })
    assert_not result[:success]
    assert_match(/narrow the filter/i, result.to_s)
    assert_equal 0, AssistantProposal.count
  ensure
    ENV.delete("ASSISTANT_PROPOSAL_MAX_RECORDS")
  end

  test "invalid params surface as error not exception" do
    result = @fn.call({ "filter" => {}, "new_category" => "Shopping" })
    assert_not result[:success]
  end

  test "creates a proposal from explicit transaction_ids" do
    target_id = @family.transactions.first.id
    result = @fn.call({ "filter" => { "transaction_ids" => [ target_id ] }, "new_category" => "Shopping" })
    assert result[:success]
    proposal = AssistantProposal.find(result[:proposal_id])
    assert_equal 1, proposal.preview["count"]
    assert_equal [ target_id ], proposal.preview["samples"].map { |s| s["id"] }
  end

  test "transaction_ids is declared in the params schema" do
    assert @fn.params_schema.dig(:properties, :filter, :properties, :transaction_ids).present?
  end
end
