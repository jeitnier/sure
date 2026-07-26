require "test_helper"
require "ostruct"

class PlaidItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @mock_provider = mock("Provider::Plaid")
    @plaid_item = plaid_items(:one)
    @importer = PlaidItem::Importer.new(@plaid_item, plaid_provider: @mock_provider)
  end

  test "imports item metadata" do
    item_data = OpenStruct.new(
      item_id: "item_1",
      available_products: [ "transactions", "investments", "liabilities" ],
      billed_products: [],
      institution_id: "ins_1",
      institution_name: "First Platypus Bank",
    )

    @mock_provider.expects(:get_item).with(@plaid_item.access_token).returns(
      OpenStruct.new(item: item_data)
    )

    institution_data = OpenStruct.new(
      institution_id: "ins_1",
      institution_name: "First Platypus Bank",
    )

    @mock_provider.expects(:get_institution).with("ins_1").returns(
      OpenStruct.new(institution: institution_data)
    )

    PlaidItem::AccountsSnapshot.any_instance.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "acc_1",
        type: "depository",
      )
    ]).at_least_once

    PlaidItem::AccountsSnapshot.any_instance.expects(:transactions_cursor).returns("test_cursor_1")

    PlaidItem::AccountsSnapshot.any_instance.expects(:get_account_data).with("acc_1").once

    PlaidAccount::Importer.any_instance.expects(:import).once

    @plaid_item.expects(:update!).with(next_cursor: "test_cursor_1")
    @plaid_item.expects(:upsert_plaid_snapshot!).with(item_data)
    @plaid_item.expects(:upsert_plaid_institution_snapshot!).with(institution_data)

    @importer.import
  end

  # Observed live 2026-07-26 on a freshly linked Chase item: Plaid raised an
  # ApiError with no response body (network-layer failure / early abort), and
  # JSON.parse(nil) raised "no implicit conversion of nil into String" from
  # inside the error handler. That TypeError replaced the real Plaid error on
  # the way up to the Sync record, so the actual cause was never recorded.
  test "re-raises the original Plaid error when the response body is nil" do
    plaid_error = Plaid::ApiError.new(code: 500, response_body: nil)
    @mock_provider.expects(:get_item).raises(plaid_error)

    raised = assert_raises(Plaid::ApiError) { @importer.import }
    assert_same plaid_error, raised, "the original Plaid error must survive the handler"
  end

  test "re-raises the original Plaid error when the response body is not JSON" do
    plaid_error = Plaid::ApiError.new(code: 502, response_body: "<html>502 Bad Gateway</html>")
    @mock_provider.expects(:get_item).raises(plaid_error)

    raised = assert_raises(Plaid::ApiError) { @importer.import }
    assert_same plaid_error, raised, "the original Plaid error must survive the handler"
  end

  test "still marks the item as requires_update when the body is parseable" do
    error_response = { "error_code" => "ITEM_LOGIN_REQUIRED", "error_message" => "login required" }.to_json
    @mock_provider.expects(:get_item).raises(Plaid::ApiError.new(code: 400, response_body: error_response))

    @importer.import

    assert_predicate @plaid_item.reload, :requires_update?
  end
end
