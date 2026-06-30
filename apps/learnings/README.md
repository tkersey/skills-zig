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

Default store:

```bash
.ledger/learnings/events.jsonl
```

Breaking/default-path change: ledger now stores learning events under
`.ledger/learnings/events.jsonl`. Use `ledger migrate --source learnings` to
copy legacy rows.

Preflight before appending in a repo with possible legacy rows:

```bash
ledger doctor --source learnings
ledger migrate --source learnings --dry-run --mode copy
ledger migrate --source learnings --mode copy
```

If `ledger doctor --source learnings` reports `legacy-only`, migrate before
`ledger capture --source learnings`.
Append fails closed with `MigrationRequired` instead of splitting writes across
legacy and canonical stores.
