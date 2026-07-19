# Composer v1 (@ Mentions + Attachments) & Chat Scroll Fix — Design Spec

**Date:** 2026-07-19 · **Branch:** `feat/composer-v1` (off `prod`) · **Ticket:** FI-15 (create on plan approval)
**Status:** Approved design, pre-implementation

## Problem

1. Every page navigation resets the chat pane's scroll position to the top; getting back
   to the latest message requires a full manual scroll. (The container already has
   `data-turbo-permanent` — layouts/application.html.erb:194 — but it is not preserving
   position in practice.)
2. The composer's four "Coming Soon" buttons (`plus`, `command`, `at-sign`,
   `mouse-pointer-click` — messages/_chat_form.html.erb:20-23) are stubs. This batch
   implements two: **@ mentions** (precise entity references) and **+ attachments**
   (files/images the AI can read). The other two stay stubbed.

## Goals

- Chat scroll behaves like a standard messenger: pinned to bottom by default (including
  as new messages stream in); a deliberately scrolled-up position survives page hops.
- `@` inserts typeahead references to accounts/categories/merchants/tags; the LLM
  receives id-level entity context instead of guessing from names.
- `+` attaches images/PDFs to a message; the assistant reads them natively (Anthropic
  document/vision blocks) and they are permanently searchable via the family vector
  store (`search_family_files`).

## Non-goals (this batch)

- `⌘` command palette and `✦` quick actions (icons remain disabled/"Coming soon").
- Mobile app composer changes.
- OCR/parsing beyond what the LLM provider does natively.
- Auto-classification of uploads into `AccountStatement` — the assistant can already
  run `import_bank_statement` when the user asks.

---

## Part 1 — Chat scroll anchoring

**Root cause first (implementation task 1 investigates, spec states the contract):**
whatever the mechanism, the observable behavior must be:

- On chat mount (initial load, Turbo visit, sidebar toggle): if the user had not
  scrolled up in this chat, the pane is scrolled to the newest message; if they had, the
  exact prior position is restored.
- While pinned to bottom, incoming message/card broadcasts keep the pane pinned.
- Scrolling up more than a small threshold (≥64px from bottom) unpins; returning to
  the bottom re-pins.
- Position memory is per-chat, client-side only: `sessionStorage`
  key `chat-scroll:<chat_id>` storing `{pinned: bool, top: int}`; no server state.

**Implementation shape:** a `chat-scroll` Stimulus controller on the messages scroll
container (`#chat-container` or the inner messages element — task 1 determines which
element actually scrolls), handling `connect`, `scroll` (throttled), and Turbo Stream
append events (MutationObserver or `turbo:before-stream-render`). Investigate and fix
the `data-turbo-permanent` gap (likely: pages that don't render the container break
permanence, or navigations are full loads); the controller must produce correct
behavior in BOTH the permanent-element-preserved and fresh-mount cases.

**Acceptance:** hop Dashboard → Transactions → Budgets with the chat open at bottom →
still at bottom; scroll up 500px, hop pages → same position; receive a new assistant
message while pinned → view follows it.

---

## Part 2 — @ Mentions

### UI

- Trigger: typing `@` in the composer textarea, or clicking the (now enabled) `at-sign`
  button (which inserts `@` and focuses).
- A popover anchored above/near the caret lists matching entities grouped by type —
  **Accounts, Categories, Merchants, Tags** — max 5 per group, keyboard navigable
  (↑/↓/Enter/Esc), filtered live as the user types after `@`.
- Selection inserts a token; the token renders as an inline chip in the composer
  (background pill, entity icon) and in the rendered user message.

### Token format (canonical, stored in `Message#content` as plain text)

```
@[<display label>](<type>:<uuid>)     e.g.  @[🧺 Household Goods](category:018f...)
```

`type ∈ {account, category, merchant, tag}`. Unknown types/malformed tokens render as
literal text and are ignored by the parser (never an error).

### Server

- `GET /chats/mentions?q=<term>` (name: `chat_mentions_path`) → JSON
  `{accounts: [{id,label}], categories: [...], merchants: [...], tags: [...]}`,
  family-scoped via `Current.family`, each group `LIMIT 5`, `ILIKE %q%` on name
  (reuse existing per-model search scopes where they exist).
- `Mention::Parser` (`app/models/mention/parser.rb`): extracts tokens from a message's
  content; `resolve(family)` returns only entities that exist AND belong to the family —
  foreign/stale UUIDs are silently dropped (they render as chips client-side but
  contribute no context; the parser result is what matters).
- **LLM integration:** when building the prompt for a user message containing mentions,
  append a context block after the message content (in `Assistant::Responder`'s message
  assembly, provider-agnostic):

  ```
  [Mentioned entities]
  - category "🧺 Household Goods" id=018f… (children: …)  ← one line per entity, type-appropriate summary
  ```

  Summaries: account → name/type/balance; category → name/parent/child names;
  merchant → name; tag → name. The propose_* and get_* tools then receive exact ids
  from the model.

### Acceptance

Type `@hous` → popover shows 🧺 Household Goods under Categories → Enter inserts chip →
send "recategorize everything in @[🧺 Household Goods](category:…) to @[Home](category:…)"
→ assistant's proposal uses those exact category ids (no name-resolution tool round).

---

## Part 3 — + Attachments

### Data model

- `Message has_many_attached :attachments` (Active Storage; no migration beyond what
  AS already has).
- Validations (on UserMessage create): content types `image/png image/jpeg image/webp
  application/pdf` (no HEIC — the Anthropic API does not accept it; iPhone clipboard
  pastes arrive as PNG. A HEIC→JPEG transcode is a possible follow-up.); ≤ **10 MB** each; ≤ **5** attachments per message.
  Violations render a form error in the composer, message not created.

### UI

- `plus` button (now enabled) opens the file picker; drag-and-drop onto the composer
  and paste-from-clipboard (images) also attach.
- Pending attachments render as removable chips (thumbnail for images, doc icon + name
  for PDFs) between the textarea and the button row. Direct upload
  (`direct_upload: true`) with per-chip progress.
- Rendered user messages show attachment chips; images get a lightbox-free inline
  thumbnail (max-h constraint), PDFs a download link.

### Assistant pipeline

- `Provider::Anthropic::MessageFormatter`: when the current user turn's message has
  attachments, emit native content blocks alongside the text — `{type: "document",
  source: {type: "base64", media_type: "application/pdf", data: …}}` for PDFs,
  `{type: "image", …}` for images (media resolved via `attachment.download`, base64).
  History turns include attachments only for the current turn (token economy); prior
  turns render `[attached: <filename>]` markers in their text.
- Non-Anthropic providers (OpenAI path): degrade to `[attached: <filename> — provider
  cannot read attachments]` text markers. No crash, clearly communicated.
- Guard: total attachment payload per request ≤ 25 MB post-encoding; beyond that the
  assistant receives markers for the overflow files and the user message renders a
  note. (Anthropic request limits are the binding constraint.)

### Vector-store ingestion (permanence)

- `AttachmentIngestJob` (low_priority queue), enqueued per attachment after message
  create: pushes the file into the family vector store via the existing
  `VectorStore::Registry` adapter (the same path the statement vault uses — task
  investigates the exact adapter API in `app/models/vector_store/`).
- **If the family has no `vector_store_id` / no adapter configured** (possible on
  self-host): the job logs and exits cleanly — attachment remains message-bound and
  AI-readable in that conversation; `search_family_files` simply won't index it until
  a vector store exists. Never an error surfaced to the user.

### Acceptance

Paste a receipt screenshot + attach a statement PDF → send "what's this receipt and
does it appear in this statement?" → assistant answers from both files' contents.
With a vector store configured, `search_family_files` later returns the uploaded doc.

---

## Cross-cutting

- **i18n:** every new user-facing string via locale files (popover group headers,
  attach errors, provider-degradation markers, chip alt text).
- **Buttons:** only `at-sign` and `plus` become enabled; `command` and
  `mouse-pointer-click` keep the disabled/"Coming soon" treatment.
- **Security:** mentions endpoint and parser family-scoped (foreign UUIDs dropped);
  attachment serving through AS signed URLs (default); validations server-side, not
  just client hints. No new LLM write paths — mentions/attachments only add context.
- **Error handling:** malformed tokens inert; upload failures per-chip retryable;
  ingest job failures logged, never user-facing; provider degradation explicit.
- **Testing:** Stimulus behavior via system tests where the suite already does JS
  (check `ci / test_system` patterns), otherwise controller/view assertions; parser
  unit tests (extract/resolve/foreign-drop); mentions endpoint scoping tests;
  attachment validation tests; MessageFormatter block-emission tests (fixture file
  blobs); ingest job no-adapter test.
- **Sequencing:** Task order = scroll fix → mentions → attachments (independent
  deliverables; each PR-able alone if needed, but one branch/PR is fine given
  auto-deploy is CI-gated).

## Rollout

`feat/composer-v1` → PR → merge to `prod` → ci-prod green → sure-autodeploy ships it.
Acceptance runs live: the three acceptance scenarios above, in the real UI.
