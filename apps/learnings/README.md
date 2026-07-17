# ledger learning source

Internal learning-source implementation used by `ledger --source learnings`.
This directory is no longer an independently shipped CLI surface.

## Files
- `scripts/learnings.zig`
- `scripts/append_learning.zig`

## Public write surface
- Primary: `ledger capture --source learnings`
- Migration: `ledger migrate --source learnings` copies legacy rows from
  `.ledger/learnings/learnings.jsonl` or `.learnings.jsonl` into
  `.ledger/learnings/events.jsonl`.
- Digest: `ledger memory-digest --source learnings` writes the disposable cross-repo memory
  consolidation resource, and `ledger capture --source learnings` refreshes it automatically
  after successful append execution. By default it writes
  `$CODEX_HOME/memories/extensions/learnings/resources/latest_learnings_digest.md`
  (falling back to `$HOME/.codex/...` when `CODEX_HOME` is unset).

## Authoritative projection surface

```bash
ledger show --source learnings --id lrn-...
ledger export --source learnings --id lrn-... --format full
ledger export --source learnings --id lrn-... --format memory-note
```

`show` is an exact alias for `export --format full`; both emit the canonical
learning record. The `memory-note` form emits
a deterministic transport payload for `memory-note append --extension
learnings --kind learning-admission`; it does not decide admission eligibility.
All forms fail closed when the canonical store is invalid or the selected row
cannot produce the requested projection.

Current persistent-adapter path:

```bash
.ledger/learnings/events.jsonl
```

Breaking/default-path change: ledger now stores learning events under
`.ledger/learnings/events.jsonl`. Use `ledger migrate --source learnings` to
copy legacy rows.

Learning queries and captures use the shared backend-neutral event-store API;
JSONL is the current compatibility adapter, not a caller contract. Legacy
JSONL parsing remains only at the explicit migration and repair boundary.

Preflight before appending in a repo with possible legacy rows:

```bash
ledger doctor --source learnings
ledger migrate --source learnings --dry-run --mode copy
ledger migrate --source learnings --mode copy
```

`doctor` validates the selected store, reports physical line spans for invalid
records, and exits nonzero for `status: "invalid"`. Migration reads logical JSON
objects rather than assuming every physical line is a full record. It reports
multiline recoveries and applies only a bounded, verified repair for a known
legacy defect: a missing opening quote on a recognized continuation key.

If irreparable records remain, migration fails closed by default. To retain all
valid records while preserving the original legacy source as evidence, use:

```bash
ledger migrate --source learnings --dry-run --mode copy --invalid-policy skip
ledger migrate --source learnings --mode copy --invalid-policy skip
```

`--invalid-policy skip` is intentionally incompatible with `--mode move` and
`--remove-legacy`. Its receipt uses a `*_with_skips` status and lists every
skipped physical line span. If
`doctor` reports `legacy-only`, migrate before `ledger capture --source
learnings`.
Append fails closed with `MigrationRequired` instead of splitting writes across
legacy and canonical stores.
