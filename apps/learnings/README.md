# learnings-zig-cli

Zig CLI scaffolding for the dotfiles `learnings` skill scripts.

## Files
- `scripts/learnings.zig`
- `scripts/append_learning.zig`

## Public write surface
- Primary: `learnings append`
- Compatibility: `append_learning`
- Migration: `learnings migrate` copies or moves legacy `.learnings.jsonl`
  rows into `.ledger/learnings/learnings.jsonl`.
- Digest: `learnings memory-digest` writes the disposable cross-repo memory
  consolidation resource, and `learnings append` refreshes it automatically
  after successful append execution. By default it writes
  `$CODEX_HOME/memories/extensions/learnings/resources/latest_learnings_digest.md`
  (falling back to `$HOME/.codex/...` when `CODEX_HOME` is unset).

Default store:

```bash
.ledger/learnings/learnings.jsonl
```

Breaking/default-path change: learnings now stores records under
`.ledger/learnings/learnings.jsonl`. Use `learnings migrate` to copy legacy
`.learnings.jsonl` rows.
