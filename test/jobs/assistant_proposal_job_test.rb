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
    # Force a SQL-NULL locked_attributes on one transaction ahead of apply --
    # `locked_attributes = locked_attributes || ?::jsonb` silently no-ops
    # against NULL, so this guards the COALESCE fix at lock_category_on!.
    Transaction.where(id: @txns.last.id).update_all("locked_attributes = NULL")
    assert_nil @txns.last.reload.locked_attributes

    p = make_proposal(kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "AMZN" ] }, "new_category" => "CatB" })
    AssistantProposalJob.perform_now(p.id, "apply")
    p.reload
    assert_equal "applied", p.status
    assert p.applied_at.present?
    @txns.each { |t| assert_equal @cat_b.id, t.reload.category_id }
    assert_equal @cat_a.id, p.changes_journal["records"][@txns.first.id]
    assert @txns.first.reload.locked_attributes.key?("category_id"), "category_id should be locked"
    assert @txns.last.reload.locked_attributes.key?("category_id"), "category_id should be locked even when locked_attributes started NULL"
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

  test "apply is atomic: a failure after domain writes rolls back the domain writes too" do
    p = make_proposal(kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "AMZN" ] }, "new_category" => "CatB" })

    # Inject a failure precisely into the applier's success-path proposal
    # update (status: "applied") -- the write that happens *after* the
    # per-kind domain mutation but must still be inside the same DB
    # transaction as that mutation.
    #
    # A plain singleton-method stub on `p` doesn't work here: the job does
    # its own `AssistantProposal.find(proposal_id)`, a fresh instance, so a
    # per-object stub is never seen by the code under test. Instead, prepend
    # a module on the class that only intercepts the exact success-path call
    # signature (status: "applied") -- every other #update! call (notably
    # the job's rescue, which marks status: "failed") falls through to the
    # real ActiveRecord::Base#update! via `super`, so we aren't faking away
    # the job's own error-handling path. `armed` disarms the intercept once
    # this test is done so later tests in the same process aren't affected.
    armed = true
    interceptor = Module.new do
      define_method(:update!) do |*args, **kwargs|
        if armed && kwargs[:status] == "applied"
          raise ActiveRecord::StatementInvalid, "boom"
        else
          super(*args, **kwargs)
        end
      end
    end
    AssistantProposal.prepend(interceptor)

    AssistantProposalJob.perform_now(p.id, "apply")
    armed = false

    # Domain write rolled back: transactions still point at the original category.
    @txns.each { |t| assert_equal @cat_a.id, t.reload.category_id }
    @txns.each { |t| assert_not t.reload.locked_attributes.key?("category_id"), "lock should have rolled back too" }

    # Job's rescue still ran on the SAME record and persisted the failure.
    assert_equal "failed", p.reload.status
    assert_match(/boom/, p.error)
    assert_nil p.applied_at
    assert_equal({}, p.changes_journal)
  end

  test "merchant_merge journals ProviderMerchant sources as not-destroyed and FamilyMerchant sources as destroyed" do
    target = @family.merchants.create!(name: "Amazon.com")
    provider_merchant = ProviderMerchant.create!(name: "AMZN-PROVIDER-\#{SecureRandom.hex(4)}", source: "plaid")
    provider_txn = @account.entries.create!(name: "provider amzn", date: Date.current, amount: 5, currency: "USD",
      entryable: Transaction.new(category: @cat_a, merchant: provider_merchant)).entryable

    p = make_proposal(kind: "merchant_merge",
      params: { "source_merchant_ids" => [ @merchant.id, provider_merchant.id ], "target_merchant_id" => target.id })
    AssistantProposalJob.perform_now(p.id, "apply")
    p.reload

    assert_equal "applied", p.status
    @txns.each { |t| assert_equal target.id, t.reload.merchant_id }
    assert_equal target.id, provider_txn.reload.merchant_id

    # FamilyMerchant source was destroyed by Merchant::Merger; ProviderMerchant was only re-pointed.
    assert_nil Merchant.find_by(id: @merchant.id)
    assert ProviderMerchant.find_by(id: provider_merchant.id).present?

    snapshots_by_id = p.changes_journal["sources"].index_by { |s| s["attrs"]["id"] }
    assert_equal true, snapshots_by_id[@merchant.id]["destroyed"]
    assert_equal false, snapshots_by_id[provider_merchant.id]["destroyed"]
  end

  test "undo recategorize restores old categories and reports conflicts" do
    p = make_proposal(kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "AMZN" ] }, "new_category" => "CatB" })
    AssistantProposalJob.perform_now(p.id, "apply")
    # user manually edits one record after apply -> conflict
    @txns.first.update!(category: @family.categories.create!(name: "Manual", color: "#db5a54"))
    p.reload.transition_to!("undoing")
    AssistantProposalJob.perform_now(p.id, "undo")
    p.reload
    assert_equal "undone", p.status
    assert_equal @cat_a.id, @txns.second.reload.category_id
    assert_equal "Manual", @txns.first.reload.category.name   # conflict left alone
    assert_match(/2 restored/, p.changes_journal["undo_summary"])
    assert_match(/1 skipped/, p.changes_journal["undo_summary"])
  end

  test "undo category_merge recreates the destroyed source category" do
    p = make_proposal(kind: "category_merge",
      params: { "source_category_ids" => [ @cat_a.id ], "target_category_id" => @cat_b.id })
    AssistantProposalJob.perform_now(p.id, "apply")
    p.reload.transition_to!("undoing")
    AssistantProposalJob.perform_now(p.id, "undo")
    p.reload
    assert_equal "undone", p.status
    restored = @family.categories.find_by(name: "CatA")
    assert restored, "source category should be recreated"
    @txns.each { |t| assert_equal restored.id, t.reload.category_id }
  end

  test "undo merchant_merge recreates source merchant and restores assignments" do
    target = @family.merchants.create!(name: "Amazon Official")
    p = make_proposal(kind: "merchant_merge",
      params: { "source_merchant_ids" => [ @merchant.id ], "target_merchant_id" => target.id })
    AssistantProposalJob.perform_now(p.id, "apply")
    p.reload.transition_to!("undoing")
    AssistantProposalJob.perform_now(p.id, "undo")
    p.reload
    assert_equal "undone", p.status
    restored = @family.merchants.find_by(name: "AMZN")
    assert restored
    @txns.each { |t| assert_equal restored.id, t.reload.merchant_id }
  end

  test "undo merchant_merge with a ProviderMerchant source does not duplicate it, only recreates the FamilyMerchant" do
    target = @family.merchants.create!(name: "Amazon.com")
    provider_merchant = ProviderMerchant.create!(name: "AMZN-PROVIDER-#{SecureRandom.hex(4)}", source: "plaid")
    provider_txn = @account.entries.create!(name: "provider amzn", date: Date.current, amount: 5, currency: "USD",
      entryable: Transaction.new(category: @cat_a, merchant: provider_merchant)).entryable

    p = make_proposal(kind: "merchant_merge",
      params: { "source_merchant_ids" => [ @merchant.id, provider_merchant.id ], "target_merchant_id" => target.id })
    AssistantProposalJob.perform_now(p.id, "apply")

    provider_merchant_count_after_apply = ProviderMerchant.count

    p.reload.transition_to!("undoing")
    AssistantProposalJob.perform_now(p.id, "undo")
    p.reload

    assert_equal "undone", p.status

    restored_family_merchant = @family.merchants.find_by(name: "AMZN")
    assert restored_family_merchant, "destroyed FamilyMerchant source should be recreated"
    assert_kind_of FamilyMerchant, restored_family_merchant

    # No duplicate ProviderMerchant: the persisting source was mapped by identity, not recreated.
    assert_equal provider_merchant_count_after_apply, ProviderMerchant.count
    assert ProviderMerchant.find_by(id: provider_merchant.id).present?

    @txns.each { |t| assert_equal restored_family_merchant.id, t.reload.merchant_id }
    assert_equal provider_merchant.id, provider_txn.reload.merchant_id
  end

  test "undo is atomic: a failure after restoring records rolls back the restore too" do
    p = make_proposal(kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "AMZN" ] }, "new_category" => "CatB" })
    AssistantProposalJob.perform_now(p.id, "apply")
    p.reload.transition_to!("undoing")

    # Same interceptor pattern as the apply atomicity test above: intercept only
    # the undo success-path call (status: "undone") so the restore's own
    # rollback behavior is exercised, while the job's rescue (status: "failed")
    # still falls through to the real update!.
    armed = true
    interceptor = Module.new do
      define_method(:update!) do |*args, **kwargs|
        if armed && kwargs[:status] == "undone"
          raise ActiveRecord::StatementInvalid, "boom"
        else
          super(*args, **kwargs)
        end
      end
    end
    AssistantProposal.prepend(interceptor)

    AssistantProposalJob.perform_now(p.id, "undo")
    armed = false

    # Restore rolled back: transactions still point at the post-apply category.
    @txns.each { |t| assert_equal @cat_b.id, t.reload.category_id }

    # Job's rescue still ran on the SAME record and persisted the failure.
    assert_equal "failed", p.reload.status
    assert_match(/boom/, p.error)
    assert_nil p.undone_at
    assert_not p.changes_journal.key?("undo_summary")
  end
end
