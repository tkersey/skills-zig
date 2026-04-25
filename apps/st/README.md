# st

Native Zig CLI for dependency-aware durable task state in `.step/st-plan.jsonl`.

`st` is the durable source of truth. Codex `update_plan` is only a transient projection of `plan_sync.codex.plan`; the CLI never calls Codex tools directly.

## Build

```bash
zig build test-st
zig build build-st -Doptimize=ReleaseFast
```

## Canonical Codex Loop

1. Run `st prime --file .step/st-plan.jsonl`.
2. Agent publishes only `plan_sync.codex.plan` through Codex `update_plan`, with optional `plan_sync.explanation`.
3. Agent does work.
4. Agent mutates durable state only through `st`.
5. Agent consumes the mutation-emitted `plan_sync:` or reruns `st prime`.
6. Agent republishes the new `plan_sync.codex.plan`.
7. Agent runs `st assert-projection --file .step/st-plan.jsonl` before delivery.

Do not pass the full `plan_sync` object to Codex `update_plan`. Do not emit an empty `update_plan` payload just to satisfy a hook.

## Projection Commands

```bash
st prime --file .step/st-plan.jsonl
st prime --file .step/st-plan.jsonl --mode auto-top-up --limit 7
st prime --file .step/st-plan.jsonl --mode replace-ready --preview
st assert-projection --file .step/st-plan.jsonl
st reconcile-codex --file .step/st-plan.jsonl --input .step/update-plan.json
st reconcile-codex --file .step/st-plan.jsonl --transcript-path /path/to/session.jsonl
st import-proposed-plan --file .step/st-plan.jsonl --input .step/proposed-plan.md --select-ready
```

`prime` emits `plan_sync: {...}` version 3 with:

- `items`: full durable inventory.
- `codex.plan`: Codex-safe rows shaped only as `{ "step": "...", "status": "pending|in_progress|completed" }`.
- `opencode.todos`: OpenCode projection rows.
- `projection.warnings`: projection warnings such as parallel durable active work collapsed to one Codex `in_progress`.

`assert-projection` exits `0` for valid projections, `2` for projection drift or invariant failure, and `1` for usage/system errors.

`reconcile-codex` is projection-only reverse sync. It may update mirrored order, step text, status, and `in_plan`; it preserves deps, notes, comments, claims, runtime, proof, priority, source, scope, location, and validation.

`import-proposed-plan` imports Plan Mode Markdown as durable backlog tasks. Plan Mode output is an import candidate, not an active Codex checklist.

## Durable Mutations

```bash
st init --file .step/st-plan.jsonl
st add --file .step/st-plan.jsonl --id st-001 --step "Reproduce failing test" --priority high
st add --file .step/st-plan.jsonl --id st-002 --step "Patch core logic" --deps "st-001" --backlog-only
st select --file .step/st-plan.jsonl --ids "st-002"
st set-status --file .step/st-plan.jsonl --id st-001 --status completed
st set-priority --file .step/st-plan.jsonl --id st-002 --priority medium
st set-deps --file .step/st-plan.jsonl --id st-002 --deps "st-001:blocks"
st set-notes --file .step/st-plan.jsonl --id st-002 --notes "Need regression proof"
st add-comment --file .step/st-plan.jsonl --id st-002 --text "Pausing until CI clears" --author tk
st remove --file .step/st-plan.jsonl --id st-002
```

Mutation commands emit a canonical `plan_sync:` payload after durable write. Legacy `emit-plan-sync`, `emit-update-plan`, and `import-update-plan` are removed in `st 0.2.0`; use `prime` and `reconcile-codex`.

## Orchestration Metadata

```bash
st import-orchplan --file .step/st-plan.jsonl --input .step/orchplan.yaml --replace
st claim --file .step/st-plan.jsonl --wave w1 --executor codex
st heartbeat --file .step/st-plan.jsonl --id st-001
st set-runtime --file .step/st-plan.jsonl --id st-001 --substrate spawn_agent --thread-id thread-123
st set-proof --file .step/st-plan.jsonl --id st-001 --proof-state pass --command "zig build test-st" --evidence-ref .step/proof.log
st release --file .step/st-plan.jsonl --id st-001 --reason proof_complete
st reclaim-stale --file .step/st-plan.jsonl --now 2026-03-12T00:00:00Z
st import-mesh-results --file .step/st-plan.jsonl --input .step/mesh-output.csv
```

## Operating Rules

- Keep dependencies, notes, comments, claims, runtime metadata, proof, backlog membership, priority, source, scope, location, and validation in `$st`, not in Codex `update_plan`.
- Every Codex-visible step begins with `[st-id] `.
- Codex projection contains at most one `in_progress` row.
- Blocked, waiting-on-deps, stale-claimed, deferred, and canceled tasks are never projected as Codex `in_progress`.
- Terminal statuses (`completed`, `deferred`, `canceled`) demote items out of the active mirror.
- `auto-top-up` adds ready backlog tasks without deselecting existing selected tasks.
- `replace-ready` rewrites selected membership to the ready frontier bounded by `--limit`.
- `--preview` computes projection output without durable selection writes.
- Hooks may inject context or deny unsafe tool use, but hooks are not a replacement for the agent’s actual `update_plan` call.

## Validation

```bash
zig build test-st
zig build build-st -Doptimize=ReleaseFast
./zig-out/bin/st --help
./zig-out/bin/st prime --help
./zig-out/bin/st assert-projection --help
./zig-out/bin/st reconcile-codex --help
./zig-out/bin/st import-proposed-plan --help
```
