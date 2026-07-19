require "test_helper"

class AssistantProposalJobTest < ActiveJob::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @chat = @user.chats.create!(title: "t")
    @account = @family.accounts.first
    @cat_a = @family.categories.create!(name: "CatA", color: "#e99537")
    @cat_b = @family.categories.create!(name: "CatB", color: "#4da568")
    @merchant = @family.merchants.create!(name: "AMZN")
    @txns = 3.times.map do |i|
      @account.entries.create!(name: "amzn #{i}", date: Date.current, amount: 5, currency: "USD",
        entryable: Transaction.new(category: @cat_a, merchant: @merchant)).entryable
    end
  end

  def make_proposal(kind:, params:)
    resolver = AssistantProposal::Resolver.new(family: @family, kind: kind, params: params)
    AssistantProposal.create!(family: @family, chat: @chat, kind: kind, params: params,
      preview: resolver.build_preview, status: "applying")
  end

  test "apply recategorize updates records, snapshots, locks, transitions" do
    p = make_proposal(kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "AMZN" ] }, "new_category" => "CatB" })
    AssistantProposalJob.perform_now(p.id, "apply")
    p.reload
    assert_equal "applied", p.status
    assert p.applied_at.present?
    @txns.each { |t| assert_equal @cat_b.id, t.reload.category_id }
    assert_equal @cat_a.id, p.changes_journal["records"][@txns.first.id]
    assert @txns.first.reload.locked_attributes.key?("category_id"), "category_id should be locked"
  end

  test "apply with drift marks stale and writes nothing" do
    p = make_proposal(kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "AMZN" ] }, "new_category" => "CatB" })
    @txns.last.entry.destroy!   # change the affected set after preview
    AssistantProposalJob.perform_now(p.id, "apply")
    assert_equal "stale", p.reload.status
    assert_equal @cat_a.id, @txns.first.reload.category_id
  end

  test "apply recategorize with new category name creates it" do
    p = make_proposal(kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "AMZN" ] }, "new_category" => "Brand New" })
    AssistantProposalJob.perform_now(p.id, "apply")
    created = @family.categories.find_by(name: "Brand New")
    assert created
    assert_equal created.id, @txns.first.reload.category_id
  end

  test "apply category_merge moves transactions and destroys source" do
    p = make_proposal(kind: "category_merge",
      params: { "source_category_ids" => [ @cat_a.id ], "target_category_id" => @cat_b.id })
    AssistantProposalJob.perform_now(p.id, "apply")
    assert_equal "applied", p.reload.status
    assert_nil Category.find_by(id: @cat_a.id)
    @txns.each { |t| assert_equal @cat_b.id, t.reload.category_id }
    assert_equal "CatA", p.changes_journal["sources"].first["attrs"]["name"]
  end

  test "apply merchant_merge reassigns and destroys source merchant" do
    target = @family.merchants.create!(name: "Amazon.com")
    p = make_proposal(kind: "merchant_merge",
      params: { "source_merchant_ids" => [ @merchant.id ], "target_merchant_id" => target.id })
    AssistantProposalJob.perform_now(p.id, "apply")
    assert_equal "applied", p.reload.status
    @txns.each { |t| assert_equal target.id, t.reload.merchant_id }
    assert_nil Merchant.find_by(id: @merchant.id)
  end

  test "domain error marks failed with message" do
    p = make_proposal(kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "AMZN" ] }, "new_category" => "CatB" })
    AssistantProposal::Applier.stubs(:new).raises(StandardError, "boom")  # mocha (in Gemfile)
    AssistantProposalJob.perform_now(p.id, "apply")
    assert_equal "failed", p.reload.status
    assert_match(/boom/, p.error)
  end
end
