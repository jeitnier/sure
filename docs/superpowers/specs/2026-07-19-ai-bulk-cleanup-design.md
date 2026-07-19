# AI Bulk Cleanup with Staged Proposals — Design Spec

**Date:** 2026-07-19 · **Branch:** `feat/ai-bulk-cleanup` (off `prod`) · **Ticket:** FI-13
**Status:** Approved design, pre-implementation

## Problem

The assistant can diagnose data problems (mangled YNAB-imported categories, fragmented
merchants, uncategorized transactions) but cannot fix them — all transaction-level
operations are read-only. The operator wants the AI to do bulk cleanup / organizational
grunt work so they can focus on the actual financial picture.

## Goals

- Assistant can stage bulk changes: **recategorize transactions**, **merge/delete
  categories**, **merge merchants**.
- Safety model: **preview → human confirm → apply, with undo** (chosen over auto-apply,
  tiered, and out-of-chat review).
- The LLM can never write directly; applying is a human click outside the chat text flow.

## Non-goals (v1)

- Composer features (file attach, image paste — the "Coming Soon" UI stubs). Separate spec.
- Bulk tag operations.
- Rule creation from applied proposals ("make permanent") — **v1.1 fast-follow**; v1 only
  reserves UI space for it on the applied card.
- Multi-user/team approval flows. Single-family, single-approver.

## Architecture

New staging layer between the assistant and the existing domain operations:

```
Assistant (propose-only tools)
   └─ creates → AssistantProposal (preview jsonb, status machine)
                   └─ renders → chat proposal card (Turbo broadcast, buttons)
                                   └─ Apply/Undo click → Assistant::ProposalsController
                                                            └─ AssistantProposalJob
                                                                 ├─ drift check
                                                                 ├─ snapshot before-values → changes jsonb
                                                                 └─ existing domain ops in one DB txn:
                                                                      Transaction.update_all + lock_attr!
                                                                      Category#replace_and_destroy!
                                                                      Merchant::Merger#merge!
```

## Data model

`assistant_proposals` (uuid pk, timestamps):

- `family_id` (fk, indexed), `chat_id` (fk), `message_id` (fk, nullable) — scoping + card placement
- `kind` — enum string: `bulk_recategorize` | `category_merge` | `merchant_merge`
- `params` jsonb — proposal inputs (see per-kind params below)
- `preview` jsonb — computed at proposal time: `{count, affected_ids_digest, samples: [≤10 rows], breakdown: {before→after counts}}`
- `changes` jsonb — filled at apply: per-record before-values (undo journal); for merges also full attribute snapshots of destroyed rows
- `status` — `proposed | applying | applied | undoing | undone | discarded | stale | failed`
- `applied_at`, `undone_at`, `error` (text)

Status transitions: `proposed→{applying,discarded,stale}`, `applying→{applied,failed,stale}`,
`applied→undoing→{undone,failed}`. Anything else is invalid and raises.

`affected_ids_digest` = SHA256 of sorted affected record ids at preview time; used for drift check.

## Assistant functions

All follow the existing `Assistant::Function` pattern and are registered in
`Assistant.functions`. Propose tools return the preview summary as their result so the
model can narrate it; they also broadcast the card.

1. `propose_bulk_recategorize`
   - params: `filter` object — any of `merchant_names[]`, `description_contains`,
     `category_ids[]` (special value `"uncategorized"`), `account_ids[]`,
     `date_range {start,end}` — AND-combined; `new_category` (id or exact name;
     name creates the category if missing, flagged in preview)
   - Resolves scope via `Current.family` transactions (entries join for date/account).
2. `propose_category_merge`
   - params: `source_category_ids[]`, `target_category_id` (nullable → sources' transactions
     become uncategorized, i.e. plain delete)
   - Wraps `Category#replace_and_destroy!` per source at apply time. Sources with zero
     transactions are simply destroyed by the same path — no separate flag.
3. `propose_merchant_merge`
   - params: `source_merchant_ids[]`, `target_merchant_id`
   - Wraps `Merchant::Merger` at apply time (family-scoped validation is built into it).
4. `get_proposals` — read-only list (id, kind, status, count, created_at), default last 10.

**Cap:** a proposal may affect at most `ASSISTANT_PROPOSAL_MAX_RECORDS` (default 2000).
Over cap → function returns an error string instructing the model to narrow the filter;
no proposal row is created.

**System prompt addendum** (instructions builder): explain the staged workflow; the model
must never state that changes were applied — only that a proposal is awaiting the user's
Apply. `get_proposals` is the source of truth for status questions.

## UI

Partial `assistant_proposals/_card.html.erb`, broadcast to the chat messages target
(same mechanism as `chats/_error`). Card contents by status:

- **proposed:** kind headline, count, before→after breakdown table, ≤10 sample rows,
  buttons **Apply** / **Discard**
- **applying/undoing:** spinner + count
- **applied:** result summary ("123 updated"), **Undo** button, disabled "Make permanent"
  affordance (v1.1), timestamp
- **stale:** "data changed since preview (was N, now M)" + **Re-preview** button
  (re-runs the resolver, resets to proposed)
- **failed:** error message + Discard
- **undone:** summary incl. conflicts ("42 restored, 3 skipped — changed after apply")

`Assistant::ProposalsController` — `POST apply`, `POST discard`, `POST undo`,
`POST repreview`; all scoped `Current.family.assistant_proposals.find(...)`; responds
with Turbo Stream card replacement; enqueues `AssistantProposalJob` for apply/undo.

## Apply/undo semantics

- **Drift check (apply):** re-resolve filter → recompute digest → mismatch ⇒ status
  `stale`, no writes. Guarantees the user approved exactly what gets changed.
- **Apply (single DB transaction):**
  - recategorize: snapshot `{id: old_category_id}` for all affected; `update_all(category_id:)`;
    set attribute locks (`lock_attr!(:category_id)` semantics — bulk-update the enrichable
    lock storage the same way a manual user edit would) so enrichment/rules don't clobber.
  - category_merge: per source category — snapshot txn ids + old category id + full
    category row attrs; `replace_and_destroy!(target)`.
  - merchant_merge: snapshot per-txn old `merchant_id` + full source merchant rows;
    `Merchant::Merger#merge!`.
- **Undo (single DB transaction):** restore from `changes`; per-record conflict rule —
  if current value ≠ value we set at apply, skip the record and count it; recreate
  destroyed categories/merchants first (new rows, original attrs; ids may differ — restore
  mapping handled via the snapshot). Result summary stored on the proposal.

## Error handling

- Job exception → status `failed`, `error` persisted, card re-broadcast. No partial
  writes (transactions).
- Authorization: everything through `Current.family`; foreign proposal ids 404.
- Idempotency: controller rejects apply/undo unless status allows it (double-click safe).
- The LLM cannot apply: no apply-capable function exists — structural guarantee.

## Testing

- Model: status machine (invalid transitions raise), digest/drift, cap enforcement,
  undo conflict counting.
- Functions: filter resolution per kind incl. `"uncategorized"`, name-creates-category
  path, over-cap error path.
- Controller: auth scoping, state-gated actions, turbo responses.
- Job: apply→undo round-trip per kind, incl. destroyed-row recreation and the
  changed-since-apply conflict path.
- Acceptance (manual, on CT 622): the real YNAB emoji-category cleanup end-to-end
  through the chat.

## Rollout

PR `feat/ai-bulk-cleanup` → `prod` on jeitnier/sure → `sure-deploy` on CT 622
(migration runs via existing `db:prepare` ExecStartPre). First production use = the
operator's category cleanup, supervised.

## v1.1 (reserved, not built now)

"Make permanent" on an applied recategorize proposal → pre-filled Sure `Rule`
(merchant/description condition → set category) so future transactions self-categorize.
