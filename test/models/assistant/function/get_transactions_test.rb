require "test_helper"

class Assistant::Function::GetTransactionsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetTransactions.new(@user)
  end

  test "each returned transaction includes its id so propose tools can target it" do
    account = @family.accounts.first
    entry = create_transaction(account: account, name: "ID check", date: Date.current, amount: 12, currency: "USD")

    result = @fn.call({ "search" => "ID check" })

    txn = result[:transactions].find { |t| t[:name] == "ID check" }
    assert txn.present?, "expected the created transaction in results"
    assert_equal entry.entryable.id, txn[:id]
  end
end
