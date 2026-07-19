require "test_helper"

class AssistantProposal::ResolverTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = users(:family_admin).family
    # Build deterministic data — do not rely on fixtures for transactions
    @account = @family.accounts.first || @family.accounts.create!(name: "Test", balance: 0, currency: "USD", accountable: Depository.new)
    @cat_a = @family.categories.create!(name: "CatA", color: "#e99537")
    @cat_b = @family.categories.create!(name: "CatB", color: "#4da568")
    @m1 = @family.merchants.create!(name: "AMZN Mktp")   # FamilyMerchant STI via family.merchants
    @m2 = @family.merchants.create!(name: "Amazon.com")
    3.times do |i|
      create_transaction(
        account: @account,
        name: "AMZN order #{i}",
        date: Date.current - i.days,
        amount: 10 + i,
        currency: "USD",
        category: @cat_a,
        merchant: @m1
      )
    end
  end

  test "bulk_recategorize resolves by merchant name and builds preview" do
    r = AssistantProposal::Resolver.new(family: @family, kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "AMZN Mktp" ] }, "new_category" => "CatB" })
    assert_equal 3, r.affected_ids.size
    preview = r.build_preview
    assert_equal 3, preview["count"]
    assert_equal AssistantProposal.compute_digest(r.affected_ids), preview["affected_ids_digest"]
    assert preview["samples"].size <= 10
    assert_equal({ "CatA" => 3 }, preview["breakdown"])
  end

  test "bulk_recategorize with unknown new_category name notes creation" do
    r = AssistantProposal::Resolver.new(family: @family, kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "AMZN Mktp" ] }, "new_category" => "Brand New Cat" })
    assert_includes r.build_preview["notes"].join, "will be created"
  end

  test "empty filter raises InvalidParams" do
    assert_raises(AssistantProposal::Resolver::InvalidParams) do
      AssistantProposal::Resolver.new(family: @family, kind: "bulk_recategorize",
        params: { "filter" => {}, "new_category" => "CatB" }).affected_scope
    end
  end

  test "category_merge affected scope is source categories transactions" do
    r = AssistantProposal::Resolver.new(family: @family, kind: "category_merge",
      params: { "source_category_ids" => [ @cat_a.id ], "target_category_id" => @cat_b.id })
    assert_equal 3, r.affected_ids.size
  end

  test "category_merge target inside sources raises" do
    assert_raises(AssistantProposal::Resolver::InvalidParams) do
      AssistantProposal::Resolver.new(family: @family, kind: "category_merge",
        params: { "source_category_ids" => [ @cat_a.id ], "target_category_id" => @cat_a.id }).affected_scope
    end
  end

  test "merchant_merge resolves transactions of source merchants" do
    r = AssistantProposal::Resolver.new(family: @family, kind: "merchant_merge",
      params: { "source_merchant_ids" => [ @m1.id ], "target_merchant_id" => @m2.id })
    assert_equal 3, r.affected_ids.size
  end

  test "over_cap? respects max_records" do
    ENV["ASSISTANT_PROPOSAL_MAX_RECORDS"] = "2"
    r = AssistantProposal::Resolver.new(family: @family, kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "AMZN Mktp" ] }, "new_category" => "CatB" })
    assert r.over_cap?
  ensure
    ENV.delete("ASSISTANT_PROPOSAL_MAX_RECORDS")
  end
end
