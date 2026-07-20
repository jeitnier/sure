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

  test "amounts filter returns only transactions matching the listed totals" do
    account = @family.accounts.first
    hit_a = create_transaction(account: account, name: "hit a", date: Date.current, amount: 77.64, currency: "USD")
    hit_b = create_transaction(account: account, name: "hit b", date: Date.current, amount: 20.88, currency: "USD")
    create_transaction(account: account, name: "miss", date: Date.current, amount: 50.00, currency: "USD")

    result = @fn.call({ "amounts" => [ 77.64, 20.88 ] })

    ids = result[:transactions].map { |t| t[:id] }
    assert_includes ids, hit_a.entryable.id
    assert_includes ids, hit_b.entryable.id
    assert_not_includes ids, result[:transactions].find { |t| t[:name] == "miss" }&.dig(:id)
    assert result[:transactions].none? { |t| t[:name] == "miss" }
  end

  test "amounts is declared in the params schema" do
    assert @fn.params_schema.dig(:properties, :amounts).present?
  end
end
