# ledger

Repo-local durable source, actuation, and plan ledger with pure governance-artifact validation.

`ledger` stores disconfirmed hypotheses, failed routes, reopening criteria, and route-exclusion evidence in an append-only JSONL file that future runs can query directly.
It also owns causal actuation under `--source actuation` and learning capture under `--source learnings`.
`ledger validate` checks immutable governance artifacts without reading or writing
any ledger store and without granting execution authority.

Default store:

```bash
.ledger/negative-ledger/events.jsonl
```

Learning source store:

```bash
.ledger/learnings/events.jsonl
```

Actuation source store:

```bash
.ledger/actuation/events.jsonl
```

Universalist plan artifacts:

```bash
.ledger/universalist-plan-<UTC_TIMESTAMP>-<ORDINAL>.md
```

Plan ids use the sortable form `YYYYMMDDTHHMMSSnnnnnnnnnZ-NNNN`. The
nanosecond UTC timestamp makes recency visible, while atomic ordinal retries
make creation collision-safe without rewriting an earlier plan. The
Universalist source resolves `latest` by the greatest valid plan id; it does
not maintain a mutable latest pointer.

The actuation store lock sidecar must be Git-ignored before `open`; ignoring
`.ledger/` covers the default store and lock.

## Commands

```bash
ledger init
ledger capture --json capture.json
ledger query
ledger map --route review-route --cluster same-cluster --artifact HEAD
ledger show --id NEG-000001
ledger status --id NEG-000001 --to stale --reason "artifact state changed"
ledger reopen --id NEG-000001
ledger export --id NEG-000001 --format full
ledger export --id NEG-000001 --format memory-note
ledger handoff
ledger compact
ledger doctor
ledger migrate --mode copy
ledger capture --source learnings --learning "When X, prefer Y because Z." --evidence "command/result" --application "Do Y next time."
ledger recall --source learnings --query "focused task" --limit 5 --drop-superseded
ledger migrate --source learnings --mode copy
ledger doctor --source learnings
ledger open --source actuation --json actuation-open.json
ledger prepare --source actuation --run RUN-ID --json operation.json
ledger state --source actuation --run RUN-ID
ledger decide --source actuation --run RUN-ID
ledger create --source universalist --template universalist-plan.md
ledger latest --source universalist
ledger latest --source universalist --format path
ledger path --source universalist --id 20260711T164436123456789Z-0000
ledger validate plan-source-contract --input plan-source-contract.json
ledger validate policy-synthesis-receipt --input synthesis-receipt.json
ledger validate review-fold --input review-fold.json
```

Use `--file PATH` to point at a non-default store.
For `--source learnings`, `--file PATH` is accepted as an alias for the learning event path.

## Universalist plan addressing

`ledger --source universalist` owns plan identity, allocation, and lookup;
Universalist owns each plan's Markdown fields and subsequent updates.

Create a fresh plan from a skill-owned template:

```bash
ledger create --source universalist \
  --template /path/to/templates/universalist-plan.md
```

The command prepends a `universalist-plan/v1` frontmatter envelope and returns
`universalist-plan-address/v1` JSON containing `plan_id`, `created_at`, and the
absolute `path`. Every invocation creates a new file. It never reuses or
truncates an existing plan.

Resolve the newest plan when no run-specific address survives:

```bash
ledger latest --source universalist
ledger latest --source universalist --format path
```

Prefer the exact id returned by `create` during an active run:

```bash
ledger path --source universalist \
  --id 20260711T164436123456789Z-0000
```

`latest` is a recovery aid, not run identity: concurrent runs must retain their
own returned plan id and verify a recovered plan's task metadata before
resuming it.

## Stateless validation

`ledger validate` is the pure validation surface for artifacts that participate
in planning and review evidence:

```bash
ledger validate plan-source-contract --input plan-source-contract.json
ledger validate policy-synthesis-receipt --input synthesis-receipt.json
ledger validate review-fold --input review-fold.json
```

Input is canonical JSON from a file or `-` for stdin. Every invocation emits a
`ledger-validate-decision/v1` object, exits `0` for `pass`, and exits `2` for a
blocked or malformed artifact. The decision always records
`authority_granted:false` and `storage_mutated:false`.

This is intentionally a command rather than a `--source` namespace. Sources own
state and event folds; validation is a deterministic observation over one
immutable input.

## Actuation kernel

`ledger --source actuation` advances one causal kernel transition per invocation. It does not run a recursive controller: `/goal` observes the projected `next_transition` and decides whether to invoke the kernel again.

The workflow is an executable recursion-scheme split:

```text
coalgebra: current state -> next legal transition
handler:   prepared capability -> process effect or external-edit reconciliation
algebra:   prior state + immutable event -> next state
```

Open a run with authority, exact path scope, and verifier-backed obligations:

```json
{
  "schema": "actuation-open/v1",
  "run_id": "run-1",
  "goal_id": "goal-1",
  "goal_contract_digest": "sha256:...",
  "resolution_digest": null,
  "source_ref": "user:turn-1",
  "execution_authority_ref": "user:turn-1",
  "mutation_allowed": true,
  "completion": "complete",
  "allowed_paths": ["src/kernel.zig"],
  "obligations": [
    {
      "id": "obl-test",
      "kind": "implementation",
      "statement": "The kernel law tests pass.",
      "verifier": ["zig", "build", "test-ledger"]
    }
  ]
}
```

Prepare exactly one operation:

```json
{
  "schema": "actuation-operation/v1",
  "step_id": "step-1",
  "effect": "edit",
  "idempotency_key": "run-1:step-1",
  "owner_boundary": "actuation-kernel",
  "paths": ["src/kernel.zig"],
  "obligation_refs": ["obl-test"]
}
```

The transition sequence is:

```bash
ledger open --source actuation --json actuation-open.json
ledger prepare --source actuation --run run-1 --json operation.json
# Perform the admitted edit with the returned capability outstanding.
ledger record --source actuation --run run-1 --capability AKC1-...
ledger observe --source actuation --run run-1 --step step-1
ledger close --source actuation --run run-1
ledger decide --source actuation --run run-1
```

For `inspect` and `verify`, use `execute` instead of `record` plus `observe`; the kernel runs the admitted verifier directly. Set `completion` to `ready-to-ship` for a generation that hands off to `$ship`, or `complete` for a terminal local/review generation. Supply `resolution_digest` for a review-bound generation. Obligation `kind` is `implementation`, `review`, `ship`, or `acceptance`; `decide` preserves those proof bases separately. It returns `continue` until the run is closed, then projects the selected terminal verdict as `closure-decision/v1`.

The kernel:

- returns 256-bit capability material once and persists only its SHA-256 digest;
- rejects duplicate idempotency keys, replay, stale pre-state, path escape, undeclared path movement, verifier substitution, verifier-side repository mutation, and uncovered closure obligations;
- executes the verifier declared by the obligation rather than accepting a caller-supplied success flag;
- folds a globally sequenced, predecessor-hashed `actuation-event/v1` chain into one run state;
- derives both continuation and terminal closure decisions in Zig from that folded state;
- exits `2` when an executed observation fails and `0` when it passes.

A repo-local process cannot physically intercept in-app mutation tools. Edit effects are therefore admitted before mutation and independently reconciled afterward. The kernel establishes causal admission and observed path conservation; it does not claim to be an OS sandbox.

The returned capability is a causal single-use token, not a secret-transport claim. Automation should capture the `prepare` result without echoing the raw value and consume it promptly; command-line and transcript confidentiality remain caller/runtime responsibilities.

Path migration:

```bash
ledger migrate \
  --from .ledger/negative-ledger.jsonl \
  --to .ledger/negative-ledger/events.jsonl \
  --mode copy
```

Learning path migration:

```bash
ledger migrate --source learnings --mode copy
```

The learnings migrator groups physical lines into logical JSON objects, reports
verified repairs and invalid line spans, and rejects irreparable records by
default. When preserving the legacy source is acceptable, an explicit copy-only
policy can migrate valid records and report the skipped spans:

```bash
ledger migrate --source learnings --dry-run --mode copy --invalid-policy skip
ledger migrate --source learnings --mode copy --invalid-policy skip
```

Successful partial migrations use a `*_with_skips` receipt status so omission
cannot be mistaken for a lossless migration.

`ledger doctor --source learnings` validates the selected canonical or legacy
store and exits nonzero when its JSON receipt has `status: "invalid"`.

This converts legacy rows from `.ledger/learnings/learnings.jsonl` or `.learnings.jsonl` into event envelopes:

```json
{"v":1,"source":"learnings","event":"learning.capture","learning_id":"lrn-...","status":"do_more","record":{ "...": "old learning row fields" }}
```

## Capture

`capture` accepts JSON from a file or stdin:

```json
{
  "hypothesis": "route fails under current artifact",
  "route_id": "review-route",
  "cluster_id": "same-cluster",
  "artifact_state_id": "HEAD",
  "source_refs": [
    { "kind": "test", "ref": "zig build test-ledger --summary all" }
  ]
}
```

Records get monotonic `NEG-*` ids. A capture that requests `active` without witness evidence is stored as `need-evidence`, not as an active exclusion.

For learning capture, use `--source learnings` with the learning flags:

```bash
ledger capture --source learnings \
  --status do_more \
  --learning "When a documented CLI form has already propagated, keep a tested compatibility alias because agents copy command forms." \
  --evidence "zig build test-ledger passed after adding parser coverage" \
  --application "Add compatibility before only updating docs." \
  --tag cli
```

Use `--record-source SOURCE` to override the source marker stored inside the learning row.

Active exclusions are route-scoped by default. Same-cluster recurrence is reusable memory, not an automatic ban.

To block a whole cluster, the capture must explicitly use `exclusion_scope:"cluster"` and include a non-empty `exclusion_rule`:

```json
{
  "hypothesis": "cluster route family is falsified",
  "cluster_id": "same-cluster",
  "exclusion_scope": "cluster",
  "exclusion_rule": "do not repeat this route family until reopened",
  "source_refs": [
    { "kind": "cas-review", "ref": "RGR-v2 wave 3" }
  ]
}
```

## Route Gate

`map` emits a machine-readable `negative_route_gate` object.

- Exact route matches can block when active, witnessed, and artifact-applicable.
- Exact cluster matches can block only when the record is explicitly cluster-scoped with an `exclusion_rule`.
- Fuzzy lexical matches are advisory only.
- A missing store fails closed with exit code `3` and `failure:"ledger_missing"`.
- Invalid gate input or invalid store content fails closed with exit code `3`.
- An active exact exclusion exits `2`.
- No active exclusion exits `0`.

This keeps "no active exclusion" as data instead of prose.

Example shape:

```json
{
  "negative_route_gate": {
    "checked": true,
    "query_or_map": "yes",
    "ledger_cli": "ledger",
    "store": ".ledger/negative-ledger/events.jsonl",
    "command": "ledger map --route review-route --cluster same-cluster --artifact HEAD",
    "exit_code": 0,
    "ledger_available": true,
    "active_exclusion_match": false,
    "exclusion_id": "none",
    "fuzzy_candidates": 0,
    "fuzzy_authority": "suggest_only",
    "failure": "none",
    "handoff_allowed": true
  }
}
```

`doctor` validates both JSONL integrity and projection safety, including malformed events and active records that cannot legally block.

## Lifecycle and memory projection

`status` appends lifecycle events without rewriting historical captures:

```bash
ledger status \
  --id NEG-000001 \
  --to reopened \
  --reason "The old benchmark fixture was replaced."
```

Supported projected statuses are `capture_candidate`, `need-evidence`, `unknown`, `active`, `accepted_risk`, `stale`, `reopened`, and `superseded`. Only `active` records can block route selection.

Use `export` for complete current projections:

```bash
ledger export --id NEG-000001 --format full
ledger export --id NEG-000001 --format memory-note |
  memory-note append --extension negative-ledger --kind ledger-projection --json -
```

`show` remains concise and now includes `source_event_count` and `projection_fingerprint`; memory admission should use `export --format memory-note`.
