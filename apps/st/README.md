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

## Mental Model: Graph Compiler + Execution Aperture

`st` can run as a graph planning compiler while preserving the durable checklist workflow.

```text
source intent -> intent atoms -> contracted task capsules -> graph audit
             -> fixed-point polish -> ranked execution aperture -> plan_sync projection
```

The graph is durable state in `.step/st-plan.jsonl`. Codex `update_plan` and OpenCode todos receive only the bounded aperture projection, never the full graph envelope.

## JSONL v4 Graph Envelope

Legacy v3 files remain readable. Non-graph commands may keep writing v3 until graph mode is activated. The first graph mutation writes v4 canonical records with a graph envelope:

```json
{
  "v": 4,
  "lane": "checkpoint",
  "graph": {
    "version": 1,
    "policy": {
      "completion_requires_proof": true,
      "implementation_ready_required": true,
      "default_projection_strategy": "aperture-score",
      "default_gate": "implementation-ready",
      "max_aperture_items": 7
    },
    "intent": [],
    "waivers": [],
    "polish": {"session_id": "", "passes": []},
    "fingerprints": {"structure": "", "contract": "", "coverage": "", "execution": ""}
  },
  "items": []
}
```

The graph envelope is durable-only. `plan_sync.codex.plan` and `plan_sync.opencode.todos` do not include it.

## Contracted Task Capsules

Graph-mode items extend existing tasks with optional capsule fields:

- `item_type`: `epic`, `feature`, `task`, `bug`, `test`, `verification`, `docs`, `chore`, `research`, `spike`, or `decision`.
- `parent_id`: hierarchy only; it does not imply execution order.
- `links`: nonblocking typed links such as `tests`, `validates`, `implements`, `documents`, and `covers-intent`.
- `intent_refs`: coverage claims against graph intent atoms.
- `acceptance`, `validation`, `location`, `scope`, `labels`, `lock_roots`, `uncertainty`, `non_goals`.
- `contract`: structured objective, background, implementation approach, success criteria, proof obligations, and risks.

`epic` and `decision` are non-executable by default. Executable items are expected to carry acceptance criteria plus validation or proof obligations before implementation-ready graph audit passes.

## Intent Coverage

Intent atoms record requirements, constraints, non-goals, risks, compatibility expectations, tests, and user-visible behavior from a source plan. Covered intent must be referenced by at least one item. Deferred, rejected, duplicate, and non-goal intent requires a reason or matching waiver.

## Graph Patch Protocol

Agents should mutate graph state through atomic patches:

```bash
st graph schema
st graph apply --file .step/st-plan.jsonl --input .step/st-graph.patch.json --gate draft
st graph apply --file .step/st-plan.jsonl --input .step/st-graph.patch.json --gate implementation-ready
st compile intent --file .step/st-plan.jsonl --input .step/st-intent.json
st compile graph --file .step/st-plan.jsonl --input .step/st-graph.patch.json --gate draft
```

Patch application validates all operations before writing. Successful graph mutations emit `plan_sync:`, `graph_delta:`, and `audit_summary:`. `--dry-run` validates and prints candidate findings without mutating state.

## Compiler Gates

```bash
st graph audit --file .step/st-plan.jsonl --gate draft --format json
st graph audit --file .step/st-plan.jsonl --gate implementation-ready --format markdown
st graph audit --file .step/st-plan.jsonl --gate execution-ready --format json
st graph audit --file .step/st-plan.jsonl --gate proof-complete --format json
```

Gate exit codes are `0` for pass, `2` for hard failures, and `1` for usage/system errors. Waivers are first-class graph objects and suppress only matching `gate + code + target` findings.

## Fixed-Point Polishing

```bash
st graph polish begin --file .step/st-plan.jsonl --name initial-plan
st graph polish snapshot --file .step/st-plan.jsonl --pass 1
st graph polish status --file .step/st-plan.jsonl --format markdown
st graph polish gate --file .step/st-plan.jsonl --min-stable-passes 2 --gate implementation-ready
```

Polish snapshots store deterministic structure, contract, coverage, and execution fingerprints. The gate requires implementation-ready audit to pass and structure/coverage fingerprints to stay stable for the configured number of passes.

## Aperture Planning

The aperture is the bounded executable frontier projected into native plan tools:

```bash
st aperture next --file .step/st-plan.jsonl --format json
st aperture plan --file .step/st-plan.jsonl --limit 7 --format json
st aperture select --file .step/st-plan.jsonl --limit 7 --strategy aperture-score
st aperture explain --file .step/st-plan.jsonl --format markdown
st compile aperture --file .step/st-plan.jsonl --limit 7
st prime --file .step/st-plan.jsonl --mode aperture --limit 7
```

The default score prioritizes ready executable work by priority, critical path, downstream unlock count, proof readiness, lock-root confidence, intent coverage, uncertainty, stale-claim penalty, and risk. `aperture select` mutates only `in_plan` membership.

## Proof-Aware Completion

In graph mode, required proof obligations gate completion:

```bash
st complete --file .step/st-plan.jsonl --id st-001 \
  --command "zig build test-st" \
  --evidence-ref .step/proof/st-001.log

st proof audit --file .step/st-plan.jsonl --id st-001 --format json
st graph audit --file .step/st-plan.jsonl --gate proof-complete --format json
```

`set-status --status completed` also respects proof requirements in graph mode. Use `--allow-unproven --reason "..."` only when an explicit waiver is the intended durable record.

## Projection Commands

```bash
st prime --file .step/st-plan.jsonl
st prime --file .step/st-plan.jsonl --mode auto-top-up --limit 7
st prime --file .step/st-plan.jsonl --mode replace-ready --preview
st prime --file .step/st-plan.jsonl --mode aperture --limit 7
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

Mutation commands emit a canonical `plan_sync:` payload after durable write. Removed legacy projection/import helpers are not active commands; use `prime` and `reconcile-codex`.

## Graph-Aware Prime

`prime --mode aperture` computes the graph aperture, updates selected membership, and emits the same projection-safe `plan_sync` shape as legacy modes. It does not project the graph envelope into Codex/OpenCode rows.

## Legacy v3 Compatibility

- Existing v3 `.step/st-plan.jsonl` files load without graph state.
- Graph mode activates only through graph/compile/aperture mutations that need graph state.
- v4 keeps `event` and `checkpoint` lanes, atomic in-place rewrite, seq/checkpoint integrity, and the existing `items` inventory.
- v3/v4 projection output remains `plan_sync` version 3.

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
