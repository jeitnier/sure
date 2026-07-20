# Bulk-edit searchable Category & Merchant pickers — design

**Date:** 2026-07-20 · **Ticket:** FI-19 · **Status:** approved by operator (chat)

## Problem

The bulk-edit drawer (`transactions/bulk_updates/new`) renders Category and
Merchant as plain `collection_select`s. With long lists there is no way to
type-to-filter; the operator has to scroll the native select.

## Decision

Swap both fields to `hotwire_combobox` (gem already in the app; the trades
form uses its async flavor for tickers). Here we use the static-collection
flavor:

```erb
<%= form.combobox :category_id,
      hw_combobox_options(Current.family.categories.alphabetically, display: :name),
      label: ..., placeholder: ..., include_blank: ... %>
```

- Same option sources as today (`Current.family.categories.alphabetically`,
  `Current.family.available_merchants_for(Current.user).alphabetically`).
- Same submitted params (`bulk_update[category_id]`, `bulk_update[merchant_id]`);
  controller/backend unchanged.
- Blank state preserved: empty field = "don't change this attribute", matching
  the current prompt semantics. Free text matching no option submits nothing.
- Tags multi-select and all other fields unchanged.
- Styling: `.form-field.combobox` treatment as in the trades form; verify the
  listbox is not clipped by the DS::Dialog drawer overflow.

## Alternatives considered

- **`list-filter` Stimulus pattern** (row-level category dropdown): it's a
  navigation listbox, not a form control — adapting it means hand-wiring a
  hidden input and selection state. More code for the same UX.
- **New DS combobox component:** over-engineering for two fields; revisit only
  if a third caller appears.

## Testing

System test drives the real drawer: create transactions, select them, open
bulk edit, type into the Category combobox, choose the filtered option, save,
assert categories applied; same interaction for Merchant in the same test.
Backend behavior stays covered by existing bulk-update controller tests.
