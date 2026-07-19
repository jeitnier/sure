# AI Bulk Cleanup with Staged Proposals — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Sure assistant propose-only bulk-write tools (recategorize transactions, merge categories, merge merchants) with human-click Apply/Undo via chat proposal cards.

**Architecture:** New `AssistantProposal` AR model stages every change with a preview + drift digest; chat renders it as a Turbo-broadcast card; `Assistant::ProposalsController` handles Apply/Discard/Undo/Re-preview clicks; `AssistantProposalJob` executes via existing domain ops (`Transaction.update_all` + attribute locks, `Category#replace_and_destroy!`, `Merchant::Merger`) snapshotting before-values for undo.

**Tech Stack:** Rails 8.1 (fork of we-promise/sure v0.7.2, branch `feat/ai-bulk-cleanup`), Postgres jsonb, Sidekiq, Hotwire/Turbo Streams, Minitest + fixtures.

**Spec:** `docs/superpowers/specs/2026-07-19-ai-bulk-cleanup-design.md` — read it first.

## Global Constraints

- Cap: a proposal may affect at most `ASSISTANT_PROPOSAL_MAX_RECORDS` records (env var, default **2000**).
- Status machine (only legal transitions; anything else raises `AssistantProposal::InvalidTransition`):
  `proposed→applying|discarded|stale`, `applying→applied|failed|stale`, `applied→undoing`, `undoing→undone|failed`, `stale→proposed` (via re-preview).
- The LLM must NEVER write directly: propose tools create rows + broadcast cards only. No assistant function may call apply/undo.
- All record access scoped through `Current.family` / the function's `family` — never unscoped finds.
- Kinds: `bulk_recategorize` | `category_merge` | `merchant_merge` (string enum).
- All writes at apply/undo happen inside a single DB transaction.
- Applied changes set attribute locks (`locked_attributes` jsonb merge) exactly like a manual user edit, so enrichment/rules don't overwrite them.
- Test command: `bin/rails test <path>` from repo root. Run task-scoped tests each task; full `bin/rails test test/models test/controllers test/jobs` in the final task.
- Conventional commits; commit at the end of every task.

## Codebase Cheat Sheet (read once)

- Function base: `app/models/assistant/function.rb` — subclasses implement `class << self { name, description }`, instance `params_schema` via `build_schema(required:, properties:)`, `call(params)`; helpers available: `family` (the user's family), `error(code, msg)` (check exact signature in the base class before use — if it differs, match the base), `valid_uuid?`. Copy the shape of `app/models/assistant/function/update_category.rb`.
- Registration list: `Assistant.functions` array in `app/models/assistant.rb:24-40`.
- Filter engine: `Transaction::Search.new(family, filters: {...})` (`app/models/transaction/search.rb`) — accepts `search` (name text), `categories` (array of category NAMES), `merchants` (array of merchant NAMES), `start_date`, `end_date`, `accounts`/`account_ids` (verify exact attribute name in the file), `types`. Returns object exposing the relation (see how `get_transactions.rb:134-140` consumes it — mirror that).
- Uncategorized: check `apply_category_filter` in `transaction/search.rb` for the uncategorized convention (upstream uses a special name/flag). Mirror `get_transactions`' params_schema wording for it.
- Attribute locks: `app/models/concerns/enrichable.rb` — `locked_attributes` jsonb column on `transactions`; `lock_attr!(attr)` merges `{attr => Time.current}`. Bulk version (write it, don't loop `update!`): `scope.update_all(["locked_attributes = locked_attributes || ?::jsonb", { category_id: Time.current.iso8601 }.to_json])`.
- Category merge: `Category#replace_and_destroy!(replacement)` (`app/models/category.rb:238`) — moves transactions via `update_all category_id:` then destroys.
- Merchant merge: `Merchant::Merger.new(family:, target_merchant:, source_merchants:).merge!` (`app/models/merchant/merger.rb`). `FamilyMerchant`/`ProviderMerchant` are STI of `Merchant`.
- Chat broadcast: `chat.broadcast_append target: chat.messages_target, partial: "...", locals: {...}` (see `app/models/chat.rb:103`).
- Chats routes block: `config/routes.rb:191`.
- Migrations: Rails migration class version `[7.2]`, uuid pks (`id: :uuid, default: -> { "gen_random_uuid()" }` — match `create_table "chats"` in `db/schema.rb:399`).
- Tests: Minitest, fixtures — `users(:family_admin)` exists; function tests instantiate `Fn.new(@user)` (see `test/models/assistant/function/get_categories_test.rb`).

---

### Task 1: `assistant_proposals` migration + model with status machine

**Files:**
- Create: `db/migrate/20260719000001_create_assistant_proposals.rb`
- Create: `app/models/assistant_proposal.rb`
- Modify: `app/models/family.rb` (add `has_many :assistant_proposals, dependent: :destroy` next to the other has_many declarations)
- Modify: `app/models/chat.rb` (add `has_many :assistant_proposals, dependent: :destroy`)
- Create: `test/fixtures/assistant_proposals.yml` (empty file with `# created in tests` comment — proposals are created per-test)
- Test: `test/models/assistant_proposal_test.rb`

**Interfaces:**
- Produces: `AssistantProposal` with columns per spec; `STATUSES`, `KINDS` constants; `transition_to!(new_status)` raising `AssistantProposal::InvalidTransition`; `AssistantProposal.max_records` → int from `ENV["ASSISTANT_PROPOSAL_MAX_RECORDS"]` default 2000; `compute_digest(ids)` class method → SHA256 hex of sorted ids joined with ","; scopes `family` (belongs_to), `chat` (belongs_to), `message` (belongs_to optional).

- [ ] **Step 1: Write the failing model test**

```ruby
# test/models/assistant_proposal_test.rb
require "test_helper"

class AssistantProposalTest < ActiveSupport::TestCase
  setup do
    @family = users(:family_admin).family
    @chat = @family.users.first.chats.create!(title: "Test chat")
    @proposal = AssistantProposal.create!(
      family: @family, chat: @chat, kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "Amazon" ] }, "new_category" => "Shopping" },
      preview: { "count" => 3, "affected_ids_digest" => "abc" },
      status: "proposed"
    )
  end

  test "valid kinds and statuses enforced" do
    assert_raises(ActiveRecord::RecordInvalid) do
      AssistantProposal.create!(family: @family, chat: @chat, kind: "nope", status: "proposed", params: {}, preview: {})
    end
  end

  test "legal transition proposed -> applying" do
    @proposal.transition_to!("applying")
    assert_equal "applying", @proposal.reload.status
  end

  test "illegal transition proposed -> undone raises" do
    assert_raises(AssistantProposal::InvalidTransition) { @proposal.transition_to!("undone") }
  end

  test "illegal transition applied -> applying raises" do
    @proposal.update!(status: "applied")
    assert_raises(AssistantProposal::InvalidTransition) { @proposal.transition_to!("applying") }
  end

  test "compute_digest is order independent" do
    assert_equal AssistantProposal.compute_digest([ "b", "a" ]), AssistantProposal.compute_digest([ "a", "b" ])
    assert_not_equal AssistantProposal.compute_digest([ "a" ]), AssistantProposal.compute_digest([ "a", "b" ])
  end

  test "max_records defaults to 2000 and reads env" do
    assert_equal 2000, AssistantProposal.max_records
    ENV["ASSISTANT_PROPOSAL_MAX_RECORDS"] = "50"
    assert_equal 50, AssistantProposal.max_records
  ensure
    ENV.delete("ASSISTANT_PROPOSAL_MAX_RECORDS")
  end
end
```

Note: if `chats.create!` signature differs (check `app/models/chat.rb` for required attrs / `user` association — chats belong to user, so use `users(:family_admin).chats.create!(title: "Test chat")`), adjust setup accordingly and keep the same assertions.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/assistant_proposal_test.rb`
Expected: FAIL — `NameError: uninitialized constant AssistantProposal` (after migration exists) or migration pending error first.

- [ ] **Step 3: Write the migration**

```ruby
# db/migrate/20260719000001_create_assistant_proposals.rb
class CreateAssistantProposals < ActiveRecord::Migration[7.2]
  def change
    create_table :assistant_proposals, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid, index: true
      t.references :chat, null: false, foreign_key: true, type: :uuid
      t.references :message, foreign_key: true, type: :uuid
      t.string :kind, null: false
      t.jsonb :params, null: false, default: {}
      t.jsonb :preview, null: false, default: {}
      t.jsonb :changes_journal, null: false, default: {}
      t.string :status, null: false, default: "proposed"
      t.datetime :applied_at
      t.datetime :undone_at
      t.text :error
      t.timestamps
    end
    add_index :assistant_proposals, [ :family_id, :status ]
  end
end
```

NOTE: column is `changes_journal`, NOT `changes` — `changes` collides with ActiveRecord's dirty-tracking method. This name is used everywhere downstream.

- [ ] **Step 4: Write the model**

```ruby
# app/models/assistant_proposal.rb
class AssistantProposal < ApplicationRecord
  class InvalidTransition < StandardError; end

  KINDS = %w[bulk_recategorize category_merge merchant_merge].freeze
  STATUSES = %w[proposed applying applied undoing undone discarded stale failed].freeze
  TRANSITIONS = {
    "proposed" => %w[applying discarded stale],
    "applying" => %w[applied failed stale],
    "applied"  => %w[undoing],
    "undoing"  => %w[undone failed],
    "stale"    => %w[proposed discarded]
  }.freeze

  belongs_to :family
  belongs_to :chat
  belongs_to :message, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }

  def self.max_records
    ENV.fetch("ASSISTANT_PROPOSAL_MAX_RECORDS", 2000).to_i
  end

  def self.compute_digest(ids)
    Digest::SHA256.hexdigest(ids.map(&:to_s).sort.join(","))
  end

  def transition_to!(new_status)
    allowed = TRANSITIONS.fetch(status, [])
    raise InvalidTransition, "#{status} -> #{new_status}" unless allowed.include?(new_status)
    update!(status: new_status)
  end

  def broadcast_card
    chat.broadcast_replace_to chat, target: dom_target, partial: "assistant_proposals/card", locals: { proposal: self }
  rescue StandardError => e
    Rails.logger.warn("[AssistantProposal] card broadcast failed: #{e.message}")
  end

  def dom_target = "assistant_proposal_#{id}"
end
```

NOTE on `broadcast_card`: look at how `chat.rb:103` broadcasts (`broadcast_append target: messages_target`) — mirror that exact mechanism. Initial render appends; updates replace by `dom_target`. Adjust the method to use the same `broadcast_append`/`broadcast_replace` style the Chat model uses (Task 4 finalizes this; keep the two-method shape: `broadcast_card_append` for create, `broadcast_card` replace for updates, both rescuing errors so broadcast failure never breaks a write).

- [ ] **Step 5: Add associations**

In `app/models/family.rb`, next to the existing `has_many :transactions, through: :accounts` (line ~39), add:

```ruby
  has_many :assistant_proposals, dependent: :destroy
```

In `app/models/chat.rb`, next to its `has_many :messages` declaration, add:

```ruby
  has_many :assistant_proposals, dependent: :destroy
```

- [ ] **Step 6: Migrate + run tests**

Run: `bin/rails db:migrate && bin/rails test test/models/assistant_proposal_test.rb`
Expected: PASS (all 6). If fixtures complain, ensure `test/fixtures/assistant_proposals.yml` exists containing only a comment line.

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/assistant_proposal.rb app/models/family.rb app/models/chat.rb test/models/assistant_proposal_test.rb test/fixtures/assistant_proposals.yml
git commit -m "feat(proposals): AssistantProposal model with status machine and drift digest"
```

---

### Task 2: `AssistantProposal::Resolver` — scope resolution + preview building

**Files:**
- Create: `app/models/assistant_proposal/resolver.rb`
- Test: `test/models/assistant_proposal/resolver_test.rb`

**Interfaces:**
- Consumes: `AssistantProposal.compute_digest`, `Transaction::Search`, `family.categories/merchants/transactions`.
- Produces: `AssistantProposal::Resolver.new(family:, kind:, params:)` with:
  - `#affected_scope` → ActiveRecord::Relation of Transaction (for all three kinds: the transactions whose rows will change; for merges that's transactions of the source categories/merchants)
  - `#affected_ids` → Array<String>
  - `#build_preview` → Hash: `{ "count" => Integer, "affected_ids_digest" => String, "samples" => [≤10 of { "id", "name", "date", "amount", "before", "after" }], "breakdown" => { "<before-label>" => count } , "notes" => [String] }`
  - `#over_cap?` → bool
  - raises `AssistantProposal::Resolver::InvalidParams` (message describes what's wrong) for unknown ids, empty filters, target-in-sources, etc.

- [ ] **Step 1: Write failing tests**

```ruby
# test/models/assistant_proposal/resolver_test.rb
require "test_helper"

class AssistantProposal::ResolverTest < ActiveSupport::TestCase
  setup do
    @family = users(:family_admin).family
    # Build deterministic data — do not rely on fixtures for transactions
    @account = @family.accounts.first || @family.accounts.create!(name: "Test", balance: 0, currency: "USD", accountable: Depository.new)
    @cat_a = @family.categories.create!(name: "CatA", color: "#e99537")
    @cat_b = @family.categories.create!(name: "CatB", color: "#4da568")
    @m1 = @family.merchants.create!(name: "AMZN Mktp")   # FamilyMerchant STI — if merchants association
    @m2 = @family.merchants.create!(name: "Amazon.com")  # is scoped differently, use FamilyMerchant.create!(family: @family, name: ...)
    3.times do |i|
      @account.entries.create!(
        name: "AMZN order #{i}", date: Date.current - i.days, amount: 10 + i, currency: "USD",
        entryable: Transaction.new(category: @cat_a, merchant: @m1)
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
```

Setup note: entry/transaction creation shape varies — open `test/models/assistant/function/get_budget_test.rb` or any test that creates entries and copy its exact factory/fixture idiom (e.g. some Sure tests use `create_transaction` helpers in `test/support`). Match the codebase; keep the assertions.

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/models/assistant_proposal/resolver_test.rb`
Expected: FAIL — uninitialized constant `AssistantProposal::Resolver`.

- [ ] **Step 3: Implement the resolver**

```ruby
# app/models/assistant_proposal/resolver.rb
class AssistantProposal::Resolver
  class InvalidParams < StandardError; end

  SAMPLE_LIMIT = 10

  attr_reader :family, :kind, :params

  def initialize(family:, kind:, params:)
    @family = family
    @kind = kind
    @params = params.deep_stringify_keys
  end

  def affected_scope
    @affected_scope ||=
      case kind
      when "bulk_recategorize" then recategorize_scope
      when "category_merge"    then family.transactions.where(category_id: source_categories.map(&:id))
      when "merchant_merge"    then family.transactions.where(merchant_id: source_merchants.map(&:id))
      else raise InvalidParams, "unknown kind #{kind}"
      end
  end

  def affected_ids
    @affected_ids ||= affected_scope.pluck(:id).map(&:to_s)
  end

  def over_cap?
    affected_ids.size > AssistantProposal.max_records
  end

  def build_preview
    {
      "count" => affected_ids.size,
      "affected_ids_digest" => AssistantProposal.compute_digest(affected_ids),
      "samples" => samples,
      "breakdown" => breakdown,
      "notes" => notes
    }
  end

  # -- per-kind helpers ------------------------------------------------------

  def target_category
    return @target_category if defined?(@target_category)
    @target_category =
      case kind
      when "bulk_recategorize"
        name_or_id = params.fetch("new_category")
        family.categories.find_by(id: name_or_id) || family.categories.find_by(name: name_or_id) # nil => will create
      when "category_merge"
        params["target_category_id"].presence && family.categories.find(params["target_category_id"])
      end
  end

  def source_categories
    ids = Array(params["source_category_ids"])
    raise InvalidParams, "source_category_ids required" if ids.empty?
    raise InvalidParams, "target cannot be one of the sources" if ids.include?(params["target_category_id"])
    cats = family.categories.where(id: ids).to_a
    raise InvalidParams, "unknown category id(s): #{(ids - cats.map(&:id)).join(', ')}" if cats.size != ids.size
    cats
  end

  def source_merchants
    ids = Array(params["source_merchant_ids"])
    raise InvalidParams, "source_merchant_ids required" if ids.empty?
    raise InvalidParams, "target cannot be one of the sources" if ids.include?(params["target_merchant_id"])
    merchants = family_merchants.where(id: ids).to_a
    raise InvalidParams, "unknown merchant id(s): #{(ids - merchants.map(&:id)).join(', ')}" if merchants.size != ids.size
    merchants
  end

  def target_merchant
    @target_merchant ||= family_merchants.find(params.fetch("target_merchant_id"))
  end

  private
    def family_merchants
      # FamilyMerchant is STI of Merchant scoped by family; ProviderMerchants are global.
      # Check merchant/merger.rb's family_merchant_ids for the authoritative scoping and reuse it.
      Merchant.where(id: family.transactions.select(:merchant_id)).or(FamilyMerchant.where(family_id: family.id))
    end

    def recategorize_scope
      filter = params.fetch("filter", {})
      raise InvalidParams, "filter must not be empty" if filter.blank? || filter.values.all?(&:blank?)

      search_filters = {}
      search_filters["merchants"]  = filter["merchant_names"] if filter["merchant_names"].present?
      search_filters["search"]     = filter["description_contains"] if filter["description_contains"].present?
      search_filters["start_date"] = filter.dig("date_range", "start") if filter.dig("date_range", "start").present?
      search_filters["end_date"]   = filter.dig("date_range", "end") if filter.dig("date_range", "end").present?

      scope = Transaction::Search.new(family, filters: search_filters).transactions_scope
      # ^ VERIFY: get_transactions.rb:134-140 shows the accessor for the relation
      #   (it may be `.relation`, `.transactions_scope`, or the search object itself).
      #   Use exactly what get_transactions uses.

      if filter["category_ids"].present?
        ids = Array(filter["category_ids"])
        scope = if ids.include?("uncategorized")
          scope.where(category_id: ids - [ "uncategorized" ]).or(scope.where(category_id: nil))
        else
          scope.where(category_id: ids)
        end
      end
      scope = scope.joins(:entry).where(entries: { account_id: filter["account_ids"] }) if filter["account_ids"].present?
      scope
    end

    def samples
      affected_scope.limit(SAMPLE_LIMIT).includes(:category, :merchant, :entry).map do |txn|
        {
          "id" => txn.id,
          "name" => txn.entry&.name,
          "date" => txn.entry&.date&.to_s,
          "amount" => txn.entry&.amount&.to_s,
          "before" => before_label(txn),
          "after" => after_label
        }
      end
    end

    def breakdown
      affected_scope.left_joins(:category).group("categories.name").count
        .transform_keys { |k| k || "Uncategorized" }
    end

    def before_label(txn)
      case kind
      when "merchant_merge" then txn.merchant&.name || "(none)"
      else txn.category&.name || "Uncategorized"
      end
    end

    def after_label
      case kind
      when "bulk_recategorize" then target_category&.name || params["new_category"].to_s
      when "category_merge"    then target_category&.name || "Uncategorized"
      when "merchant_merge"    then target_merchant.name
      end
    end

    def notes
      n = []
      if kind == "bulk_recategorize" && target_category.nil?
        n << "Category \"#{params['new_category']}\" does not exist — it will be created on apply."
      end
      n
    end
end
```

Two VERIFY points inside (marked in comments): the `Transaction::Search` relation accessor and family-merchant scoping. Resolve both by reading the referenced upstream files and matching them exactly; the tests define the required behavior.

- [ ] **Step 4: Run tests until green**

Run: `bin/rails test test/models/assistant_proposal/resolver_test.rb`
Expected: PASS (7).

- [ ] **Step 5: Commit**

```bash
git add app/models/assistant_proposal/resolver.rb test/models/assistant_proposal/resolver_test.rb
git commit -m "feat(proposals): resolver for scope resolution, cap check, and previews"
```

---

### Task 3: Assistant propose/get functions + registration + prompt addendum

**Files:**
- Create: `app/models/assistant/function/propose_bulk_recategorize.rb`
- Create: `app/models/assistant/function/propose_category_merge.rb`
- Create: `app/models/assistant/function/propose_merchant_merge.rb`
- Create: `app/models/assistant/function/get_proposals.rb`
- Modify: `app/models/assistant.rb:24-40` (append the four classes to `Assistant.functions`)
- Modify: wherever `instructions` is built (`grep -rn "def instructions" app/models/assistant*` — likely `app/models/assistant/configurable.rb` or `assistant.rb`) — append the staged-write section shown below
- Test: `test/models/assistant/function/propose_bulk_recategorize_test.rb` (representative; the merge functions follow identically and get sibling test files with the same three cases adapted)

**Interfaces:**
- Consumes: `AssistantProposal`, `AssistantProposal::Resolver` (Task 2 signatures), `Assistant::Function` base helpers, `chat` — check how functions access the current chat: `Assistant::Function` is initialized with the user; the chat is reachable via the message. `grep -n "def initialize\|chat" app/models/assistant/function.rb` — if the base has no chat accessor, add `attr_reader :chat` plumbing: `FunctionToolCaller` is constructed in `Assistant::Builtin#function_tool_caller` with `functions.map { |fn| fn.new(chat.user) }` — change to pass the chat: `fn.new(chat.user, chat: chat)` and give `Assistant::Function#initialize` an optional `chat:` keyword stored as `@chat`. That plumbing belongs to THIS task and must keep every existing function test passing (the keyword is optional).
- Produces: functions named `propose_bulk_recategorize`, `propose_category_merge`, `propose_merchant_merge`, `get_proposals`; each propose function returns `{ success: true, proposal_id:, count:, breakdown:, notes:, message: "Proposal staged — the user must click Apply on the card to execute." }` or `error(...)`.

- [ ] **Step 1: Write failing test for propose_bulk_recategorize**

```ruby
# test/models/assistant/function/propose_bulk_recategorize_test.rb
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
end
```

(Adapt the `error(...)` result-shape assertions to what `Assistant::Function#error` actually returns — read the base class; existing function tests show the convention.)

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/models/assistant/function/propose_bulk_recategorize_test.rb`
Expected: FAIL — uninitialized constant.

- [ ] **Step 3: Implement chat plumbing + the four functions**

Chat plumbing (see Interfaces above): optional `chat:` kwarg on `Assistant::Function#initialize`, passed from `Assistant::Builtin#function_tool_caller`.

```ruby
# app/models/assistant/function/propose_bulk_recategorize.rb
class Assistant::Function::ProposeBulkRecategorize < Assistant::Function
  class << self
    def name = "propose_bulk_recategorize"

    def description
      <<~INSTRUCTIONS
        Stages a bulk recategorization of transactions matching a filter. This does NOT
        apply anything: it creates a proposal card in the chat that the user must
        explicitly Apply. Never claim the change has been made — after calling this,
        tell the user a proposal is awaiting their Apply click.

        Filter keys (AND-combined, at least one required):
        - merchant_names: exact merchant names (use get_transactions/get_categories to discover)
        - description_contains: substring match on transaction name
        - category_ids: current category ids; include the string "uncategorized" for transactions with no category
        - account_ids: limit to specific accounts
        - date_range: { start: "YYYY-MM-DD", end: "YYYY-MM-DD" }

        new_category: target category id or exact name (a new category is created if the name doesn't exist).
      INSTRUCTIONS
    end
  end

  def strict_mode? = false

  def params_schema
    build_schema(
      required: [ "filter", "new_category" ],
      properties: {
        filter: {
          type: "object",
          properties: {
            merchant_names: { type: "array", items: { type: "string" } },
            description_contains: { type: "string" },
            category_ids: { type: "array", items: { type: "string" } },
            account_ids: { type: "array", items: { type: "string" } },
            date_range: { type: "object", properties: { start: { type: "string" }, end: { type: "string" } } }
          }
        },
        new_category: { type: "string", description: "Target category id or exact name" }
      }
    )
  end

  def call(params = {})
    create_proposal(kind: "bulk_recategorize", params: params)
  end
end
```

Shared creation logic goes in the BASE class (`app/models/assistant/function.rb`), since all three propose functions use it:

```ruby
  # app/models/assistant/function.rb — add:
  private
    def create_proposal(kind:, params:)
      return error("no_chat", "Proposals require an active chat context.") unless chat

      resolver = AssistantProposal::Resolver.new(family: family, kind: kind, params: params)
      if resolver.over_cap?
        return error("over_cap",
          "This would affect #{resolver.affected_ids.size} records (max #{AssistantProposal.max_records}). Narrow the filter and try again.")
      end
      preview = resolver.build_preview
      return error("empty", "No records match — nothing to propose.") if preview["count"].zero?

      proposal = AssistantProposal.create!(
        family: family, chat: chat, kind: kind,
        params: params, preview: preview, status: "proposed"
      )
      proposal.broadcast_card_append

      { success: true, proposal_id: proposal.id, count: preview["count"],
        breakdown: preview["breakdown"], notes: preview["notes"],
        message: "Proposal staged — the user must click Apply on the card to execute." }
    rescue AssistantProposal::Resolver::InvalidParams => e
      error("invalid_params", e.message)
    end
```

`propose_category_merge` (same file pattern; schema `required: ["source_category_ids"]`, properties `source_category_ids` array of strings, `target_category_id` string optional — omit/null means transactions become uncategorized and sources are deleted; description mirrors the recategorize one: staged, user must Apply, sources with zero transactions are simply deleted). `call` → `create_proposal(kind: "category_merge", params: params)`.

`propose_merchant_merge` (schema `required: ["source_merchant_ids", "target_merchant_id"]`, both about merchant ids; description: collapses duplicate merchants into the target, staged, user must Apply). `call` → `create_proposal(kind: "merchant_merge", params: params)`.

```ruby
# app/models/assistant/function/get_proposals.rb
class Assistant::Function::GetProposals < Assistant::Function
  class << self
    def name = "get_proposals"
    def description = "Lists recent bulk-change proposals and their statuses (proposed/applied/undone/etc). Use this to answer questions about pending or past proposals. Read-only."
  end

  def strict_mode? = false

  def params_schema
    build_schema(required: [], properties: {
      status: { type: "string", description: "Optional status filter", enum: AssistantProposal::STATUSES }
    })
  end

  def call(params = {})
    scope = family.assistant_proposals.order(created_at: :desc).limit(10)
    scope = scope.where(status: params["status"]) if params["status"].present?
    { proposals: scope.map { |p|
        { id: p.id, kind: p.kind, status: p.status, count: p.preview["count"],
          created_at: p.created_at.iso8601, applied_at: p.applied_at&.iso8601 } } }
  end
end
```

Register all four at the end of the `Assistant.functions` array in `app/models/assistant.rb`:

```ruby
        Function::ProposeBulkRecategorize,
        Function::ProposeCategoryMerge,
        Function::ProposeMerchantMerge,
        Function::GetProposals
```

Prompt addendum — append to the instructions builder (located via the grep in Files):

```text
## Staged bulk changes

You can stage bulk changes with the propose_* tools (recategorize transactions, merge
categories, merge merchants). Proposals are NOT applied by you — each one renders a card
the user must explicitly Apply. Never state that a bulk change has been made; say the
proposal is awaiting the user's Apply. Applied proposals can be undone by the user from
the same card. Use get_proposals to check statuses.
```

- [ ] **Step 4: Run function tests + existing assistant suite**

Run: `bin/rails test test/models/assistant_proposal_test.rb test/models/assistant_proposal/ test/models/assistant/`
Expected: PASS everywhere — especially the pre-existing function tests (the `chat:` kwarg must be optional/backward-compatible).

- [ ] **Step 5: Write sibling tests for the two merge functions** (same 3 cases as Step 1 adapted: creates proposal, target-in-sources error, unknown-id error) in `test/models/assistant/function/propose_category_merge_test.rb` and `propose_merchant_merge_test.rb`; plus a 2-case `get_proposals_test.rb` (lists mine, filters by status). Run them.

- [ ] **Step 6: Commit**

```bash
git add app/models/assistant* test/models/assistant*
git commit -m "feat(assistant): propose-only bulk-change tools + get_proposals + prompt addendum"
```

---

### Task 4: Proposal card partial + ProposalsController + routes

**Files:**
- Create: `app/views/assistant_proposals/_card.html.erb`
- Create: `app/controllers/assistant_proposals_controller.rb`
- Modify: `config/routes.rb` (top level, near `resources :chats` at line 191)
- Modify: `app/models/assistant_proposal.rb` (finalize `broadcast_card_append` / `broadcast_card` using the Chat mechanism)
- Test: `test/controllers/assistant_proposals_controller_test.rb`

**Interfaces:**
- Consumes: `AssistantProposal` statuses + `dom_target`; `Chat#messages_target`; auth helpers used by other controllers (`Current.user` / `Current.family` — copy the before_actions from `app/controllers/chats_controller.rb`).
- Produces: routes `POST /assistant_proposals/:id/apply|discard|undo|repreview`; controller enqueues `AssistantProposalJob.perform_later(proposal.id, action)` for apply/undo (job exists in Task 5 — for THIS task's tests, assert enqueue with `assert_enqueued_with`).

- [ ] **Step 1: Routes**

Inside `config/routes.rb` (top level, after the `resources :chats` block):

```ruby
  resources :assistant_proposals, only: [] do
    member do
      post :apply
      post :discard
      post :undo
      post :repreview
    end
  end
```

- [ ] **Step 2: Write failing controller tests**

```ruby
# test/controllers/assistant_proposals_controller_test.rb
require "test_helper"

class AssistantProposalsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in @user = users(:family_admin)   # match the sign-in helper used by chats_controller_test.rb
    @chat = @user.chats.create!(title: "t")
    @proposal = AssistantProposal.create!(
      family: @user.family, chat: @chat, kind: "bulk_recategorize",
      params: { "filter" => { "merchant_names" => [ "X" ] }, "new_category" => "Y" },
      preview: { "count" => 1, "affected_ids_digest" => "d" }, status: "proposed")
  end

  test "apply transitions to applying and enqueues job" do
    assert_enqueued_with(job: AssistantProposalJob, args: [ @proposal.id, "apply" ]) do
      post apply_assistant_proposal_path(@proposal)
    end
    assert_equal "applying", @proposal.reload.status
  end

  test "discard from proposed" do
    post discard_assistant_proposal_path(@proposal)
    assert_equal "discarded", @proposal.reload.status
  end

  test "apply on already-applied is rejected" do
    @proposal.update!(status: "applied")
    post apply_assistant_proposal_path(@proposal)
    assert_response :unprocessable_entity
    assert_equal "applied", @proposal.reload.status
  end

  test "undo on applied enqueues job" do
    @proposal.update!(status: "applied")
    assert_enqueued_with(job: AssistantProposalJob, args: [ @proposal.id, "undo" ]) do
      post undo_assistant_proposal_path(@proposal)
    end
    assert_equal "undoing", @proposal.reload.status
  end

  test "other family's proposal 404s" do
    other = users(:empty)   # any fixture user in a different family; check test/fixtures/users.yml
    sign_in other
    post apply_assistant_proposal_path(@proposal)
    assert_response :not_found
  end
end
```

- [ ] **Step 3: Run to verify failure** — `bin/rails test test/controllers/assistant_proposals_controller_test.rb` → FAIL (no routes/controller). (`AssistantProposalJob` must exist as an empty shell for `assert_enqueued_with`: create `app/jobs/assistant_proposal_job.rb` with an empty `perform(proposal_id, action); end` body now; Task 5 fills it.)

- [ ] **Step 4: Implement controller**

```ruby
# app/controllers/assistant_proposals_controller.rb
class AssistantProposalsController < ApplicationController
  before_action :set_proposal

  def apply
    transition_and_enqueue("applying", "apply")
  end

  def undo
    transition_and_enqueue("undoing", "undo")
  end

  def discard
    @proposal.transition_to!("discarded")
    respond_with_card
  rescue AssistantProposal::InvalidTransition
    head :unprocessable_entity
  end

  def repreview
    resolver = AssistantProposal::Resolver.new(family: Current.family, kind: @proposal.kind, params: @proposal.params)
    @proposal.update!(preview: resolver.build_preview)
    @proposal.transition_to!("proposed")
    respond_with_card
  rescue AssistantProposal::InvalidTransition, AssistantProposal::Resolver::InvalidParams
    head :unprocessable_entity
  end

  private
    def set_proposal
      @proposal = Current.family.assistant_proposals.find(params[:id])
    end

    def transition_and_enqueue(status, action)
      @proposal.transition_to!(status)
      AssistantProposalJob.perform_later(@proposal.id, action)
      respond_with_card
    rescue AssistantProposal::InvalidTransition
      head :unprocessable_entity
    end

    def respond_with_card
      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.replace(@proposal.dom_target, partial: "assistant_proposals/card", locals: { proposal: @proposal }) }
        format.html { redirect_back fallback_location: chat_path(@proposal.chat) }
      end
    end
end
```

(Match `ApplicationController` auth conventions — if other controllers use `before_action :authenticate_user!` implicitly via ApplicationController, nothing more is needed; verify by reading `app/controllers/chats_controller.rb` headers.)

- [ ] **Step 5: Implement the card partial**

```erb
<%# app/views/assistant_proposals/_card.html.erb %>
<div id="<%= proposal.dom_target %>" class="my-3 rounded-lg border border-secondary bg-container p-4 shadow-border-xs">
  <div class="flex items-center justify-between mb-2">
    <h4 class="text-sm font-medium text-primary">
      <%= { "bulk_recategorize" => "Bulk recategorize", "category_merge" => "Merge categories", "merchant_merge" => "Merge merchants" }[proposal.kind] %>
      — <%= proposal.preview["count"] %> record<%= "s" unless proposal.preview["count"] == 1 %>
    </h4>
    <span class="text-xs text-secondary uppercase"><%= proposal.status %></span>
  </div>

  <% if proposal.preview["breakdown"].present? %>
    <div class="text-xs text-secondary mb-2">
      <% proposal.preview["breakdown"].each do |label, count| %>
        <div><%= label %> → <%= count %></div>
      <% end %>
    </div>
  <% end %>

  <% Array(proposal.preview["notes"]).each do |note| %>
    <p class="text-xs text-warning mb-1"><%= note %></p>
  <% end %>

  <% case proposal.status %>
  <% when "proposed" %>
    <div class="flex gap-2 mt-2">
      <%= button_to "Apply", apply_assistant_proposal_path(proposal), class: "px-3 py-1.5 bg-inverse text-inverse rounded-lg text-sm font-medium cursor-pointer" %>
      <%= button_to "Discard", discard_assistant_proposal_path(proposal), class: "px-3 py-1.5 text-sm text-secondary cursor-pointer" %>
    </div>
  <% when "applying", "undoing" %>
    <p class="text-xs text-secondary animate-pulse">Working…</p>
  <% when "applied" %>
    <p class="text-xs text-primary">Applied <%= proposal.applied_at&.strftime("%m-%d-%Y %H:%M") %></p>
    <div class="flex gap-2 mt-2 items-center">
      <%= button_to "Undo", undo_assistant_proposal_path(proposal), class: "px-3 py-1.5 text-sm text-secondary border border-secondary rounded-lg cursor-pointer" %>
      <span class="text-xs text-subdued" title="Coming in v1.1">Make permanent →</span>
    </div>
  <% when "stale" %>
    <p class="text-xs text-warning">Data changed since preview.</p>
    <%= button_to "Re-preview", repreview_assistant_proposal_path(proposal), class: "px-3 py-1.5 text-sm border border-secondary rounded-lg cursor-pointer mt-1" %>
  <% when "failed" %>
    <p class="text-xs text-destructive"><%= proposal.error %></p>
    <%= button_to "Discard", discard_assistant_proposal_path(proposal), class: "px-3 py-1.5 text-sm text-secondary cursor-pointer mt-1" %>
  <% when "undone" %>
    <p class="text-xs text-secondary"><%= proposal.changes_journal["undo_summary"] || "Undone." %></p>
  <% when "discarded" %>
    <p class="text-xs text-subdued">Discarded.</p>
  <% end %>
</div>
```

Style note: reuse Sure's design tokens exactly as above (`bg-container`, `text-primary`, `shadow-border-xs` — same classes as `chats/_ai_consent.html.erb`); adjust any class that doesn't exist by copying from that file. Finalize `AssistantProposal#broadcast_card_append` (create → `chat.broadcast_append target: chat.messages_target, partial: "assistant_proposals/card", locals: { proposal: self }`) and `#broadcast_card` (updates → `broadcast_replace target: dom_target, ...`), both mirroring the exact broadcast style of `chat.rb:103` and rescuing errors. Add an `after_update_commit :broadcast_card` to the model so EVERY status change re-renders the card (covers job-side transitions too).

- [ ] **Step 6: Run controller tests** — `bin/rails test test/controllers/assistant_proposals_controller_test.rb` → PASS.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/assistant_proposals_controller.rb app/views/assistant_proposals app/jobs/assistant_proposal_job.rb config/routes.rb app/models/assistant_proposal.rb test/controllers/assistant_proposals_controller_test.rb
git commit -m "feat(proposals): chat card UI + apply/discard/undo/repreview controller"
```

---

### Task 5: `AssistantProposalJob` — apply path with drift check, snapshots, locks

**Files:**
- Modify: `app/jobs/assistant_proposal_job.rb` (fill the Task 4 shell)
- Create: `app/models/assistant_proposal/applier.rb`
- Test: `test/jobs/assistant_proposal_job_test.rb` (apply cases; undo cases arrive in Task 6)

**Interfaces:**
- Consumes: `AssistantProposal` (+`transition_to!`, `changes_journal`), `AssistantProposal::Resolver` (`affected_scope/affected_ids`, `target_category`, `source_categories`, `source_merchants`, `target_merchant`), `Category#replace_and_destroy!`, `Merchant::Merger`.
- Produces: `AssistantProposalJob.perform(proposal_id, "apply")`; `AssistantProposal::Applier.new(proposal).apply!` which (a) drift-checks, (b) snapshots into `changes_journal`, (c) executes, (d) transitions to `applied` (or `stale`/`failed`). `changes_journal` shapes:
  - bulk_recategorize: `{ "op" => "recategorize", "new_category_id" => id, "records" => { txn_id => old_category_id_or_nil } }`
  - category_merge: `{ "op" => "category_merge", "target_category_id" => id_or_nil, "sources" => [ { "attrs" => {full category row}, "transaction_ids" => [...] } ], "records" => { txn_id => old_category_id } }`
  - merchant_merge: `{ "op" => "merchant_merge", "target_merchant_id" => id, "sources" => [ { "attrs" => {full merchant row} } ], "records" => { txn_id => old_merchant_id } }`

- [ ] **Step 1: Write failing job tests (apply)**

```ruby
# test/jobs/assistant_proposal_job_test.rb
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
    target = @family.merchants.create!(name: "Amazon")
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
```

- [ ] **Step 2: Run to verify failure** — `bin/rails test test/jobs/assistant_proposal_job_test.rb` → FAIL (empty job body).

- [ ] **Step 3: Implement job + applier (apply path)**

```ruby
# app/jobs/assistant_proposal_job.rb
class AssistantProposalJob < ApplicationJob
  queue_as :high_priority

  def perform(proposal_id, action)
    proposal = AssistantProposal.find(proposal_id)
    case action
    when "apply" then AssistantProposal::Applier.new(proposal).apply!
    when "undo"  then AssistantProposal::Applier.new(proposal).undo!
    end
  rescue StandardError => e
    if proposal
      proposal.update!(status: "failed", error: e.message.truncate(500))
    end
    Rails.logger.error("[AssistantProposalJob] #{action} #{proposal_id} failed: #{e.class}: #{e.message}")
  end
end
```

```ruby
# app/models/assistant_proposal/applier.rb
class AssistantProposal::Applier
  attr_reader :proposal

  def initialize(proposal)
    @proposal = proposal
  end

  def apply!
    resolver = AssistantProposal::Resolver.new(family: proposal.family, kind: proposal.kind, params: proposal.params)
    current_digest = AssistantProposal.compute_digest(resolver.affected_ids)
    if current_digest != proposal.preview["affected_ids_digest"]
      refreshed = resolver.build_preview
      proposal.update!(preview: refreshed)
      proposal.transition_to!("stale")
      return
    end

    journal =
      case proposal.kind
      when "bulk_recategorize" then apply_recategorize(resolver)
      when "category_merge"    then apply_category_merge(resolver)
      when "merchant_merge"    then apply_merchant_merge(resolver)
      end

    proposal.update!(changes_journal: journal, applied_at: Time.current)
    proposal.transition_to!("applied")
  end

  private
    def lock_category_on!(ids)
      Transaction.where(id: ids).update_all([
        "locked_attributes = locked_attributes || ?::jsonb",
        { "category_id" => Time.current.iso8601 }.to_json
      ])
    end

    def apply_recategorize(resolver)
      family = proposal.family
      target = resolver.target_category ||
               family.categories.create!(name: proposal.params["new_category"].to_s.strip, color: Category::COLORS.sample)
      # ^ VERIFY Category::COLORS exists (grep app/models/category.rb for the color palette
      #   constant / default; use whatever new-category default the categories controller uses)
      records = nil
      ActiveRecord::Base.transaction do
        scope = resolver.affected_scope
        records = scope.pluck(:id, :category_id).to_h
        scope.update_all(category_id: target.id, updated_at: Time.current)
        lock_category_on!(records.keys)
      end
      { "op" => "recategorize", "new_category_id" => target.id, "records" => records }
    end

    def apply_category_merge(resolver)
      target = resolver.target_category  # may be nil => uncategorized
      sources = resolver.source_categories
      records = {}
      source_snapshots = []
      ActiveRecord::Base.transaction do
        sources.each do |source|
          txn_ids = source.transactions.pluck(:id)
          txn_ids.each { |id| records[id] = source.id }
          source_snapshots << { "attrs" => source.attributes, "transaction_ids" => txn_ids }
          source.replace_and_destroy!(target)
        end
        lock_category_on!(records.keys)
      end
      { "op" => "category_merge", "target_category_id" => target&.id,
        "sources" => source_snapshots, "records" => records }
    end

    def apply_merchant_merge(resolver)
      target = resolver.target_merchant
      sources = resolver.source_merchants
      records = {}
      snapshots = sources.map { |m| { "attrs" => m.attributes } }
      ActiveRecord::Base.transaction do
        sources.each do |source|
          Transaction.where(merchant_id: source.id).pluck(:id).each { |id| records[id] = source.id }
        end
        Merchant::Merger.new(family: proposal.family, target_merchant: target, source_merchants: sources).merge!
      end
      { "op" => "merchant_merge", "target_merchant_id" => target.id,
        "sources" => snapshots, "records" => records }
    end
end
```

- [ ] **Step 4: Run job tests** — `bin/rails test test/jobs/assistant_proposal_job_test.rb` → PASS (6). Debug the two VERIFY points (category default color; `Merchant::Merger` behavior on whether it destroys sources — read `merge!` and align the test assertion with reality: if it keeps sources, the applier destroys them after `merge!` inside the transaction and the journal notes it).

- [ ] **Step 5: Commit**

```bash
git add app/jobs/assistant_proposal_job.rb app/models/assistant_proposal/applier.rb test/jobs/assistant_proposal_job_test.rb
git commit -m "feat(proposals): apply path — drift check, snapshots, locks, domain ops"
```

---

### Task 6: Undo path with conflict detection

**Files:**
- Modify: `app/models/assistant_proposal/applier.rb` (add `undo!` + helpers)
- Test: `test/jobs/assistant_proposal_job_test.rb` (append undo cases)

**Interfaces:**
- Consumes: Task 5 `changes_journal` shapes verbatim.
- Produces: `Applier#undo!` — restores before-values per record with conflict rule (current value ≠ value-we-set ⇒ skip + count); recreates destroyed categories/merchants from `sources[].attrs` (fresh ids; a `restored_id_map` translates old→new when restoring records); writes `changes_journal["undo_summary"]` string; transitions `undoing→undone` (or `failed`).

- [ ] **Step 1: Append failing undo tests**

```ruby
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
    target = @family.merchants.create!(name: "Amazon")
    p = make_proposal(kind: "merchant_merge",
      params: { "source_merchant_ids" => [ @merchant.id ], "target_merchant_id" => target.id })
    AssistantProposalJob.perform_now(p.id, "apply")
    p.reload.transition_to!("undoing")
    AssistantProposalJob.perform_now(p.id, "undo")
    restored = @family.merchants.find_by(name: "AMZN")
    assert restored
    @txns.each { |t| assert_equal restored.id, t.reload.merchant_id }
  end
```

- [ ] **Step 2: Run to verify failure** — undo tests FAIL (`undo!` NotImplemented / no method).

- [ ] **Step 3: Implement `undo!`**

```ruby
  # append inside AssistantProposal::Applier (public section)
  def undo!
    journal = proposal.changes_journal
    restored = 0
    skipped = 0
    ActiveRecord::Base.transaction do
      id_map = recreate_sources(journal)   # old_id => restored record id (categories/merchants); {} for recategorize
      attr_name, applied_value_for = undo_target(journal, id_map)
      journal.fetch("records", {}).each do |txn_id, old_value|
        txn = Transaction.find_by(id: txn_id)
        next skipped += 1 if txn.nil?
        if txn.public_send(attr_name) != applied_value_for.call(txn_id)
          skipped += 1
          next
        end
        txn.update_columns(attr_name => id_map.fetch(old_value, old_value), updated_at: Time.current)
        restored += 1
      end
    end
    summary = "#{restored} restored, #{skipped} skipped (changed after apply or missing)"
    proposal.update!(changes_journal: journal.merge("undo_summary" => summary), undone_at: Time.current)
    proposal.transition_to!("undone")
  end

  private
    # Recreate destroyed rows; return old_id => new_id map.
    def recreate_sources(journal)
      case journal["op"]
      when "category_merge"
        journal.fetch("sources", []).each_with_object({}) do |src, map|
          attrs = src["attrs"].except("id", "created_at", "updated_at")
          map[src["attrs"]["id"]] = proposal.family.categories.create!(attrs).id
        end
      when "merchant_merge"
        journal.fetch("sources", []).each_with_object({}) do |src, map|
          attrs = src["attrs"].except("id", "created_at", "updated_at")
          map[src["attrs"]["id"]] = Merchant.create!(attrs).id
          # ^ STI: attrs includes "type" (FamilyMerchant) and family_id — Merchant.create!
          #   with type attr builds the right subclass. VERIFY against merchant.rb validations.
        end
      else
        {}
      end
    end

    # Which attribute we changed at apply, and what value we set (for conflict check).
    def undo_target(journal, _id_map)
      case journal["op"]
      when "recategorize"
        [ :category_id, ->(_) { journal["new_category_id"] } ]
      when "category_merge"
        [ :category_id, ->(_) { journal["target_category_id"] } ]
      when "merchant_merge"
        [ :merchant_id, ->(_) { journal["target_merchant_id"] } ]
      end
    end
```

- [ ] **Step 4: Run all job tests** — `bin/rails test test/jobs/assistant_proposal_job_test.rb` → PASS (9).

- [ ] **Step 5: Commit**

```bash
git add app/models/assistant_proposal/applier.rb test/jobs/assistant_proposal_job_test.rb
git commit -m "feat(proposals): undo path — conflict-aware restore, recreates merged rows"
```

---

### Task 7: Full suite, deploy, acceptance

**Files:**
- No new files. Possibly small fixes across all previous files.

- [ ] **Step 1: Full test run**

Run: `bin/rails test test/models test/controllers test/jobs`
Expected: PASS — zero regressions in pre-existing tests (especially assistant + rules suites). Fix anything that broke; commit fixes with `fix:` messages.

- [ ] **Step 2: Lint** — `bin/rubocop -A app/models/assistant_proposal* app/models/assistant/function/propose* app/models/assistant/function/get_proposals.rb app/controllers/assistant_proposals_controller.rb app/jobs/assistant_proposal_job.rb` (project uses rubocop-rails-omakase); commit if it changed files.

- [ ] **Step 3: Push branch + PR on the fork**

```bash
git push -u origin feat/ai-bulk-cleanup
gh pr create -R jeitnier/sure --base prod --title "feat: AI bulk cleanup with staged proposals" --body "Implements docs/superpowers/specs/2026-07-19-ai-bulk-cleanup-design.md. Propose-only assistant tools + Apply/Undo proposal cards. FI-13."
```

- [ ] **Step 4: Deploy to CT 622** (after PR review/merge to `prod`)

```bash
ssh root@pve06 "pct exec 622 -- sure-deploy"
# migration runs via the service's ExecStartPre db:prepare on restart
```

- [ ] **Step 5: Acceptance (manual, in the Sure UI)**

1. Chat: "Clean up my category names from the YNAB import" → assistant proposes; card appears with counts.
2. Click Apply → card flips to applied; verify transactions moved (Transactions page).
3. Click Undo → verify restoration + conflict summary.
4. Ask "what proposals are pending?" → `get_proposals` answers accurately.
5. Confirm the assistant's own words never claim direct application.

- [ ] **Step 6: Update FI-13 in Plane + `/remember`** — comment with ship status; durable state to memory.
