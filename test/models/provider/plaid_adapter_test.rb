require "test_helper"

class Provider::PlaidAdapterTest < ActiveSupport::TestCase
  include ProviderAdapterTestInterface

  setup do
    @plaid_account = plaid_accounts(:one)
    @account = accounts(:depository)
    @adapter = Provider::PlaidAdapter.new(@plaid_account, account: @account)
  end

  def adapter
    @adapter
  end

  # Run shared interface tests
  test_provider_adapter_interface
  test_syncable_interface
  test_institution_metadata_interface

  # Provider-specific tests
  test "returns correct provider name" do
    assert_equal "plaid", @adapter.provider_name
  end

  test "returns correct provider type" do
    assert_equal "PlaidAccount", @adapter.provider_type
  end

  test "returns plaid item" do
    assert_equal @plaid_account.plaid_item, @adapter.item
  end

  test "returns account" do
    assert_equal @account, @adapter.account
  end

  test "can_delete_holdings? returns false" do
    assert_equal false, @adapter.can_delete_holdings?
  end

  # Plaid's Environment map is keyed by lowercase strings ("production",
  # "sandbox"). A value typed as "Sandbox" or "Production" in the settings UI
  # resolved to nil, so reload_configuration built a Plaid::Configuration with
  # server_index = nil — the provider looked configured but could not reach
  # Plaid at all. Observed live 2026-07-25.
  test "environment is normalized case-insensitively" do
    { "Sandbox" => "sandbox", "PRODUCTION" => "production", " production " => "production" }.each do |stored, expected|
      with_plaid_settings(environment: stored) do
        Provider::PlaidAdapter.reload_configuration
        config = Rails.application.config.plaid
        assert_not_nil config, "#{stored.inspect} should produce a usable config"
        assert_equal Plaid::Configuration::Environment[expected], config.server_index,
                     "#{stored.inspect} should resolve to the #{expected} server index"
      end
    end
  end

  test "an unrecognized environment leaves the provider unconfigured instead of silently broken" do
    with_plaid_settings(environment: "staging") do
      Provider::PlaidAdapter.reload_configuration
      assert_nil Rails.application.config.plaid,
                 "an invalid environment must not yield a config with a nil server_index"
    end
  end

  private
    def with_plaid_settings(environment:)
      previous = { client_id: Setting[:plaid_client_id], secret: Setting[:plaid_secret], environment: Setting[:plaid_environment] }
      Setting[:plaid_client_id] = "test-client-id"
      Setting[:plaid_secret] = "test-secret"
      Setting[:plaid_environment] = environment
      yield
    ensure
      Setting[:plaid_client_id] = previous[:client_id]
      Setting[:plaid_secret] = previous[:secret]
      Setting[:plaid_environment] = previous[:environment]
      Rails.application.config.plaid = nil
    end
end
