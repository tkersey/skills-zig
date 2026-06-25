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

Material intake and graph patches must use the canonical `.step/st-plan.jsonl`. A second durable plan file is not a compatibility workaround for legacy graph debt; the CLI should repair or reject the canonical graph instead.

## Workspace Bootstrap

`st workspace` initializes, migrates, and inspects the `.ledger/st` workspace root used by the multi-plan storage model. This workspace surface creates the canonical directory skeleton and an STW-v1 `workspace.jsonl` checkpoint. `st plan` adds the workspace-owned plan registry. `st claim` adds workspace-global claims, leases, resource conflict detection, and fencing tokens. `st session`, `st worktree`, and `st changeset` bind worker execution and output to that workspace authority; `st integrate` serializes target-branch updates.

```bash
st workspace init --workspace .ledger/st
st workspace migrate --from .step/st-plan.jsonl --to .ledger/st --plan-id default --format json
st workspace status --workspace .ledger/st --format json
st workspace audit --workspace .ledger/st --format json
st workspace doctor --workspace .ledger/st --format json
st workspace recover --workspace .ledger/st --format json
st workspace export --workspace .ledger/st --output .ledger/st-export.json
st workspace import --workspace .ledger/st --input .ledger/st-export.json --replace
st plan create --workspace .ledger/st --plan default
st plan list --workspace .ledger/st --format json
st plan show --workspace .ledger/st --plan default --format json
st plan pause --workspace .ledger/st --plan default
st plan resume --workspace .ledger/st --plan default
st plan complete --workspace .ledger/st --plan default
st plan archive --workspace .ledger/st --plan default
st plan link --workspace .ledger/st --from plan://default/st-001 --to plan://other/st-001 --type hard
st plan unlink --workspace .ledger/st --from plan://default/st-001 --to plan://other/st-001 --type hard
st workspace aperture --workspace .ledger/st --format json
ST_WORKSPACE=.ledger/st ST_PLAN=default st show --format json
```

`workspace init` fails closed when `workspace.jsonl` already exists unless `--replace` is explicit. `workspace status` is read-only and returns exit code `2` when the workspace is missing. Workspace metadata mutations publish through `.ledger/st/transactions` prepare/commit receipts, a short `.ledger/st/locks` lock, and workspace-sequence compare-and-swap; an unfinished prepared transaction fails closed with recovery required. `plan create` rejects duplicate or malformed plan IDs and creates `.ledger/st/plans/PLAN_ID/plan.jsonl` through the workspace registry. Plan lifecycle commands append new workspace checkpoints: active plans may be paused or completed, paused plans may be resumed, and only non-active plans may be archived. `plan link` and `plan unlink` mutate workspace-owned `cross_plan_edges` using qualified refs shaped like `plan://PLAN_ID/ITEM_ID`; they validate registered plans and existing local items. Plan-local commands can use `ST_WORKSPACE` and `ST_PLAN` defaults, or infer the plan when workspace mode has exactly one active registered plan; two or more active plans require explicit scope.

`workspace migrate` imports a legacy `.step/st-plan.jsonl` into `.ledger/st/plans/PLAN_ID/plan.jsonl` only after loading the legacy and migrated files through the same graph-state materializer and passing a parity comparison. Migrated checkpoint rows receive immutable `plan_id` and `plan_sequence` fields, the workspace registry records the plan sequence and graph fingerprints, a receipt is written under `.ledger/st/migration/receipt.json`, and source bytes are archived under `.ledger/st/migration/source/`. Re-running the same migration is idempotent when the registered plan still matches the legacy graph.

`workspace audit`, `doctor`, and `recover` emit JSON receipts for registry integrity and prepared transaction recovery state. `workspace export` writes an STW-EXPORT-v1 bundle containing the latest workspace checkpoint plus registered plan JSONL bytes; `workspace import` restores that bundle and refuses to replace an existing workspace unless `--replace` is explicit.

`workspace aperture` emits a WAP-v1 receipt without mutating plan state. It scans active registered plans, gates candidates on plan-local readiness plus hard cross-plan dependencies, ignores nonblocking links for execution readiness, infers write resources from `lock_roots` or `location`, rejects candidates that conflict with held workspace claims or already selected candidates, and selects a deterministic conflict-free set by score, fairness debt, then qualified ID.

The workspace resource grammar accepts `path:PATH`, `symbol:PATH#SYMBOL`, `generated:NAME`, `schema:NAME`, `service:NAME`, `git:index`, `git:branch:BRANCH`, and `repo:all`. Paths are repository-relative with POSIX normalization; absolute paths, traversal, NUL bytes, malformed names, and symlink escapes are rejected. Read/read resources are compatible, read/write and write/write conflict, exclusive conflicts with every mode, path ancestors conflict with descendants, and unknown mutation scope falls back to `repo:all` exclusive authority.

Workspace claims are stored in `workspace.jsonl` checkpoints and published with the same workspace-sequence compare-and-swap as plan registry changes:

```bash
st claim grant --workspace .ledger/st --session s1 --executor teams --resources write:path:src/a.zig
st claim grant --workspace .ledger/st --session s2 --executor teams --resources read:path:docs,write:schema:events
st claim conflicts --workspace .ledger/st --resources write:path:src/a.zig --format json
st claim heartbeat --workspace .ledger/st --claim claim-1 --session s1 --fencing-token 1
st claim amend --workspace .ledger/st --claim claim-1 --session s1 --fencing-token 1 --resources write:path:src/a.zig,write:path:src/b.zig
st claim release --workspace .ledger/st --claim claim-2 --session s2 --fencing-token 2
st claim reclaim-stale --workspace .ledger/st --now 2026-03-12T00:00:00Z
st claim list --workspace .ledger/st --format json
st claim show --workspace .ledger/st --claim claim-1 --format json
```

`--resources` is a comma-separated list of `mode:resource` entries where `mode` is `read`, `write`, or `exclusive`. An omitted resource list is treated as unknown mutation scope and grants `exclusive:repo:all` only after conflict checks. A grant allocates a monotonic fencing token and writes a WCL-v1-style receipt. Heartbeat, release, and amend require the current claim ID, matching session when supplied, and current fencing token. Reclaim marks expired held claims stale without granting new authority; old tokens remain invalid. Amend is release-and-regrant semantics and always allocates a new token.

Workspace sessions write isolated runtime records and SVW-v1 views under `.ledger/st/runtime/sessions` and `.ledger/st/runtime/views`:

```bash
st session bind --workspace .ledger/st --session s1 --executor teams --plan default --ids st-001
st session bind --workspace .ledger/st --session s2 --executor teams --plan other --claim claim-2 --fencing-token 2
st session show --workspace .ledger/st --session s1 --format json
st session switch-plan --workspace .ledger/st --session s1 --plan other
st session release --workspace .ledger/st --session s2
st session list --workspace .ledger/st --format json
```

Session views include executor, plan ID, optional claim and fencing token, workspace sequence, plan sequence, branch epoch, selected item IDs, target, and a projection digest. A claim-bound session cannot switch plans until released. Session files are runtime-local state; they do not rewrite plan-local selected flags.

Workspace-scoped aperture compilation emits legacy GCR-v1 plus a GCR-v2 authority receipt when claim and session scope are supplied:

```bash
st compile aperture --workspace .ledger/st --plan default --session s1 --claim claim-1 --fencing-token 1 --expect-workspace-seq 3 --expect-plan-seq 2 --expect-branch-epoch 0
```

The GCR-v2 receipt binds workspace sequence, plan sequence, graph fingerprints, branch epoch, claim ID, fencing token, claim resources, session view digest, selected item IDs, and `execution_allowed`. Stale workspace or plan sequences, stale graph fingerprints, stale branch epoch, missing or expired claims, stale fencing tokens, and stale or mismatched session views deny execution through machine-readable `gate.denials`; callers cannot override `execution_allowed`.

Claim-bound worker output is sealed through external worktrees and CS-v1 change sets:

```bash
st worktree create --workspace .ledger/st --claim claim-1 --session s1 --fencing-token 1 --output /tmp/st-worker
st changeset seal --workspace .ledger/st --claim claim-1 --session s1 --fencing-token 1 --worktree /tmp/st-worker --id cs-1
st changeset show --workspace .ledger/st --id cs-1
st changeset reject --workspace .ledger/st --id cs-1
st changeset supersede --workspace .ledger/st --id cs-1 --to cs-2
```

`worktree create` uses Git to create a detached worktree at the workspace target head, or current repository `HEAD` when no target head is recorded, and stores WT-v1 metadata under `.ledger/st/worktrees/CLAIM.json`. Nested worktrees inside the primary checkout are rejected, and later sealing verifies the worktree still belongs to the recorded Git common directory. `changeset seal` validates the current claim, session, and fencing token; derives changed paths from Git instead of trusting caller input; rejects changed paths outside write or exclusive claim resources; computes patch and tree digests; and writes CS-v1 receipts under `.ledger/st/changesets/`. Rejected and integrated change sets are immutable terminal states.

Sealed change sets are integrated through a serialized controller lane:

```bash
st integrate enqueue --workspace .ledger/st --id cs-1
st integrate status --workspace .ledger/st
st integrate preview --workspace .ledger/st --id cs-1
st integrate apply --workspace .ledger/st --id cs-1 --source . --expect-branch-epoch 0
st integrate reject --workspace .ledger/st --id cs-1
st integrate recover --workspace .ledger/st
```

`integrate apply` verifies the target branch head and expected branch epoch, checks the CS-v1 patch digest, applies and commits the patch in a detached scratch worktree, and advances the target branch with `git update-ref <new> <old>` compare-and-swap. Text conflicts leave the target branch unchanged and write conflict artifacts under `.ledger/st/integration/scratch/`; successful applies write IGR-v1 receipts under `.ledger/st/integration/receipts/`, mark the change set integrated, publish a workspace checkpoint with the incremented branch epoch, and append PINV-v1 proof invalidation events under `.ledger/st/proof/PLAN_ID/invalidations.jsonl`.

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

`epic` and `decision` are non-executable by default. Active executable items are expected to carry acceptance criteria plus validation or proof obligations before implementation-ready graph audit passes. Completed, deferred, and canceled legacy rows remain subject to global structural validity checks, but their missing implementation-ready capsule fields are historical debt rather than an intake blocker.

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

Workspace-scoped proof recording emits PRF-v3 lineage fields:

```bash
st proof record --workspace .ledger/st --plan default \
  --id st-001 \
  --obligation proof-001 \
  --action proof-action-test \
  --command "zig build test-st" \
  --evidence-ref .ledger/st/proof/default/proof-001.log
```

PRF-v3 receipts include workspace sequence, plan ID and sequence, branch epoch, current tree digest when Git is available, and the item dependency resource cut derived from `lock_roots`, `location`, or `scope`. Historical proof receipts are retained; integration writes invalidation events instead of deleting or rewriting old proof.

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
