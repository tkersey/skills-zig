# Trace Canonicalization Plan

`seq` will add trace-native Codex session support as an additive parser and command layer. Existing datasets and commands remain intact until a later parity-backed migration.

## Current Execution Path

- Command dispatch starts in `src/lib.zig` through `Command`, `command_defs`, and `parseCommand`.
- CLI parsing, option validation, command handlers, dataset metadata, dataset row collection, and query integration live in `src/commands/mod.zig`.
- Existing session JSONL parsing is split across dataset modules such as `src/datasets/messages.zig`, `src/datasets/tool_calls.zig`, and token dataset modules, plus command-local parsing for `session-tooling` and query diagnostics.
- Output rendering is centralized in `src/output/mod.zig` with `table`, `json`, `csv`, and `jsonl`.
- Tests are included from `src/tests.zig`; command and parser fixtures live under `apps/seq/testdata`.

## Canonical Trace Layer

Add `src/canonical_trace.zig` as the shared trace substrate for new trace-native commands and datasets. It will own:

- raw JSONL event normalization across new explicit `type`, mid `payload`, and older root metadata formats;
- session metadata, turn reconstruction, stale ongoing detection, token accounting, compaction flags, and warnings;
- tool lifecycle reconstruction keyed by `call_id`, including typed end events and unresolved calls;
- worker/session graph edges from collaboration spawn events.

The new parser will be used by the new commands and datasets only:

- commands: `sessions`, `turns`, `session-detail`, `tool-lifecycle`, `session-graph`, `tail`;
- datasets: `sessions`, `turns`, `tool_lifecycle`, `session_graph_edges`.

Legacy surfaces stay on their existing collectors:

- `messages`, `tool_calls`, `tool_invocations`, `tool_call_args`;
- token datasets;
- memory and opencode datasets;
- `session-tooling`, `query-diagnose`, and orchestration parsing.

## Integration Notes

- Extend `src/lib.zig` with the six new commands.
- Extend `src/commands/mod.zig` with command handlers, dataset metadata, new dataset collection branches, and query output gating for `markdown` and `dot`.
- Extend `src/output/mod.zig` so `Format.parse` recognizes `markdown` and `dot`, while command/dataset-specific validation prevents unrelated outputs from accepting them.
- Add trace fixtures under `apps/seq/testdata/trace`, including a root tree that uses `sessions/YYYY/MM/DD/rollout-*.jsonl` shape.
- Import `canonical_trace.zig` from `src/tests.zig` so parser tests compile in the main test suite.

## Release/Docs Boundary

The trace-native command surface is release-relevant. The implementation must update `apps/seq/VERSION` to `0.3.0`, keep README/help/schema/golden fixtures synchronized, update the `$seq` skill docs, and close only after release, tap formula, and installed binary proof.
