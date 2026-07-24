# ledger

Repo-local artifact and durable-source toolchain.

`ledger` stores disconfirmed hypotheses, failed routes, reopening criteria, and
route-exclusion evidence in an append-only event store that future runs can
query through the Ledger API. It also materializes and validates Actuating,
Learnings, Synesthesia, Negative Ledger, and Universalist artifacts.

Ledger CLI is not the Evidence Ledger artifact. For an `$actuating` goal,
`$actuating` owns the Goal Contract interpretation, Construction selection,
review-finding evaluation, next action, and closure meaning. Ledger performs
only the requested artifact operation. It does not implement repository
changes, run or interpret review, select a repair, publish, or grant execution
authority. CAS owns review attempts, transport, principal proof, and verdicts.
`$ship` owns public effects and their readback.

The negative ledger, Actuating evidence, learning, and Synesthesia sources share
one storage contract: ordered snapshots, opaque revisions, compare-and-append,
atomic replacement, and logical store identity. The current persistent adapter
is JSONL; source callers do not split lines or coordinate storage locks.

Current negative-ledger adapter path:

```bash
.ledger/negative-ledger/events.jsonl
```

Current learning-source adapter path:

```bash
.ledger/learnings/events.jsonl
```

Universalist plan artifacts:

```bash
.ledger/universalist/plan-<UTC_TIMESTAMP>-<ORDINAL>.md
```

Plan ids use the sortable form `YYYYMMDDTHHMMSSnnnnnnnnnZ-NNNN`. The
nanosecond UTC timestamp makes recency visible, while atomic ordinal retries
make creation collision-safe without rewriting an earlier plan. The
Universalist source resolves `latest` by the greatest valid plan id; it does
not maintain a mutable latest pointer.

## Commands

```bash
ledger init
ledger capture --json capture.json
ledger query
ledger map --route review-route --cluster same-cluster --artifact "$(git rev-parse HEAD)"
ledger show --id NEG-000001
ledger status --id NEG-000001 --to stale --json transition.json
ledger reopen --id NEG-000001 --json reopen-proof.json
ledger export --id NEG-000001 --format full
ledger export --id NEG-000001 --format memory-note
ledger export --source negative-ledger --id NEG-000001 --format memory-note
ledger handoff
ledger compact
ledger doctor
ledger migrate --mode copy
ledger capture --source learnings --learning "When X, prefer Y because Z." --evidence "command/result" --application "Do Y next time."
ledger recall --source learnings --query "focused task" --limit 5 --drop-superseded
ledger show --source learnings --id lrn-...
ledger export --source learnings --id lrn-... --format memory-note
ledger migrate --source learnings --mode copy
ledger doctor --source learnings
ledger --source actuation --goal GOAL_ID prepare --input operation.json
ledger --source actuation --goal GOAL_ID append --input artifact-or-evidence.json
ledger --source actuation --goal GOAL_ID state
ledger --source actuation --goal GOAL_ID project
ledger --source actuation --goal GOAL_ID project \
  --review-contract /path/to/review-contract.json
ledger --source actuation --goal GOAL_ID doctor
ledger --source actuation --goal GOAL_ID path
ledger create --source universalist --template universalist-plan.md
ledger latest --source universalist
ledger latest --source universalist --format path
ledger path --source universalist --id 20260711T164436123456789Z-0000
ledger emit --source universalist --plan PLAN --contract CONTRACT [receipt fields] [--write-plan]
ledger validate plan-source-contract --input plan-source-contract.json
ledger validate policy-synthesis-receipt --input synthesis-receipt.json
ledger validate source-memory-checkpoint --input source-memory-checkpoint.json
```


Use `--file PATH` to point at a non-default store.
For `--source learnings`, `--file PATH` is accepted as an alias for the learning event path.
`--source negative-ledger` is an additive namespace alias for the source-less
Negative Ledger commands; it preserves `--file` and all existing command
semantics.

## Universalist plan and receipt ownership

`ledger --source universalist` owns plan identity, allocation, lookup, and
SDR-v1 receipt emission. Universalist owns the decision policy, SKDC-v1
contract, plan template, and ordinary Markdown field updates. This receipt
boundary requires Ledger 0.10.4 or newer and Skills Seq 0.3.51 or newer. Ledger
checks a sibling `seq` first, then searches `PATH`, and accepts only a binary
advertising the SKDC-v1 receipt-binding projection and SDR-v1 validation
capabilities
it needs.

Create a fresh plan from a skill-owned template:

```bash
ledger create --source universalist \
  --template /path/to/templates/universalist-plan.md
```

The command prepends a `universalist-plan/v1` frontmatter envelope and returns
`universalist-plan-address/v1` JSON containing `plan_id`, `created_at`, and the
absolute `path`. Every invocation creates a new file. It never reuses or
truncates an existing plan.

New plans are created under `.ledger/universalist/`. Exact-id and `latest`
lookup continue to resolve valid legacy `.ledger/universalist-plan-*.md`
artifacts without rewriting them. When both layouts contain the same plan id,
the namespaced path is canonical.

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

After Universalist selects one consequential route, emit its root decision
receipt before mutating the implementation seam:

```bash
ledger emit --source universalist \
  --plan "$UNIVERSALIST_PLAN" \
  --contract /path/to/references/decision-contract.yaml \
  --question "Which construction owns this seam?" \
  --selected-route UNI-ORDINARY \
  --rejected-route UNI-CANONICAL \
  --expected-outcome "The owner boundary enforces one observable law." \
  --disposition changed \
  --construction "checked adapter at the owner boundary" \
  --law "required observations are preserved" \
  --falsifier "a mismatched source is accepted" \
  --advanced-mechanics none \
  --evidence-ref "code:path" \
  --write-plan
```

Ledger snapshots a YAML or JSON SKDC-v1 contract once, then uses Seq's single
validation result for the fingerprint, decision-capable skill kind, parsed
trigger, clause, and route identities, and referenced-clause route coverage. It
rejects unknown or uncovered references, derives the decision id and repository
state only from an exact canonical plan address, constructs canonical compact
SDR-v1 JSON, and validates the generated receipt through Seq before any plan
mutation. `--write-plan` accepts only the canonical
`.ledger/universalist/plan-<id>.md` path, atomically appends one receipt, and
rejects a second JSON or YAML receipt. Without `--write-plan`, the command is a
plan-read-only receipt projection and may use a non-addressed plan when
`--decision-id` is explicit.

## Stateless validation

`ledger validate` is the pure validation surface for supported immutable
artifacts:

```bash
ledger validate plan-source-contract --input plan-source-contract.json
ledger validate policy-synthesis-receipt --input synthesis-receipt.json
ledger validate source-memory-checkpoint --input source-memory-checkpoint.json
```

Input is canonical JSON from a file or `-` for stdin. General governance
contracts emit `ledger-validate-decision/v1`. Every invocation exits `0` for
`pass` and `2` for a blocked or malformed artifact. Every decision records
`authority_granted:false` and `storage_mutated:false`.

`source-memory-checkpoint/v1` validation requires exactly one Learnings,
Synesthesia, and Negative Ledger disposition, checks source-specific IDs and
admission compatibility, and derives `complete`, `degraded`, or `blocked` from
those results. It validates coordination evidence only: source skills retain
semantic and mutation authority, and an admission failure after canonical
success must be represented as `degraded`, never as canonical rollback.

This is intentionally a command rather than a `--source` namespace. Validation
is a deterministic observation over one immutable input; it neither authors
the artifact's meaning nor grants authority.

## `$actuating` artifact support

The authoritative per-goal artifacts are the Goal Contract, Counterexample Set,
Construction Contract, and Evidence Ledger. `$actuating` governs their
lifecycle: it preserves accepted goal authority, selects the Construction,
directs its correct-by-construction implementation, evaluates review findings,
chooses the next action, and interprets closure. `ledger --source actuation` is
the thin storage and projection adapter `$actuating` invokes; it does not author
that meaning and is not an implementation or review controller.

Owner observations retain their semantic owner. Recording a CAS verdict or
`$ship` receipt does not convert it into a Ledger judgment.

Every command is bound to one goal. Its fixed Evidence Ledger path is:

```text
<repo>/.ledger/actuation/<safe-goal-id>/evidence.jsonl
```

The current command surface is:

```bash
ledger --source actuation --goal GOAL_ID prepare --input operation.json
ledger --source actuation --goal GOAL_ID append --input artifact-or-evidence.json
ledger --source actuation --goal GOAL_ID append \
  --input effect-evidence.json --capability AKC2-...
ledger --source actuation --goal GOAL_ID state
ledger --source actuation --goal GOAL_ID project
ledger --source actuation --goal GOAL_ID doctor
ledger --source actuation --goal GOAL_ID path
```

Add `--repo PATH` before `--goal` to locate `.ledger`; the default is `.`. The
adapter neither invokes Git nor derives subject identity from the repository.
Actuating supplies `actuating-operation/v1.expected_subject_digest`; `prepare`
exact-matches that opaque digest to the current structural subject and records
it in the durable event envelope. `append` accepts `goal-contract/v3`,
`construction-contract/v3`, `counterexample-set/v1`, or an
`actuating-evidence-input/v1` observation. Construction v3 records exactly four
ordinary candidate families, one selected candidate, the predecessor and
successor semantic-factor surfaces, and a total supersession disposition.
Owner-local implementation proof remains mandatory for accepted
Counterexample classes; recurrent classes require non-example implementation
proof. A Review Fold with accepted classes makes the current Construction
structurally stale until Actuating registers one successor Construction bound
to the latest Set and exact accepted-class set. Construction v1/v2 stores are
not migrated: append, replay, state, project, prepare, and doctor reject them as
`LegacyConstructionUnsupported`. Start a new goal-local store instead. Durable
evidence uses `actuating-evidence-event/v1`.

`prepare` validates the operation against the current Goal Contract,
Construction Contract, and expected subject, appends `operation_prepared`,
returns the raw single-use capability once, and persists only its digest. The
capability binds later effect evidence; it is not mutation authority. An edit
must echo the executor-observed `pre_effect_subject_digest`; inspect and verify
use the event envelope's current subject. Ledger exact-matches those
caller-owned digests to the current tuple but never computes them. `append`
materializes and validates a document draft before registering it, or validates
and records an owner observation. It never performs the reported effect.
`--capability` is
required for `effect_recorded` and for a pre-effect `operation_observed`;
`operation_aborted` is capabilityless exact tuple-and-step recovery that
invalidates the pending capability digest. Artifact append returns
`actuating-append-result/v1` with the exact
canonical artifact, its `artifact_id`, and the registration `event_digest`;
observation append returns the same schema with `artifact` and `artifact_id` set
to `null`.
Construction admission derives Counterexample recurrence from immutable Set
lineage. Every accepted class must have a law-matched `implementation` proof
obligation; a recurrent accepted class must have a non-example implementation
proof. Aggregate acceptance checks cannot substitute for owner-local proof.
The selected candidate's factors must exactly equal the successor semantic
surface. Supersession must partition every predecessor and successor factor
exactly once as preserved, retired, introduced, or explicitly replaced;
preserved factors must remain byte-semantically equal. Ledger validates this
closed structure but does not select a candidate or decide whether an expansion
is semantically justified.
`state` projects current structural evidence. `project` emits a discardable
`actuating-structural-evidence-projection/v1` with a digest-derived
`projection_id`. With `--review-contract FILE|-`, `project` instead validates
the exact supplied Actuating package, recomputes its normative and lens-package
digests, and emits `actuating-review-identity-projection/v1` for the current
Goal, Construction, subject, Evidence head, Review Contract digest, and
campaign identity without appending an event. Both surfaces report
`authority_granted:false` and
`semantic_decision_established:false`; neither computes review credit, a next
action, or closure.
`doctor` validates the store and its hash chain. `path` prints the fixed
goal-local evidence path.

Repository tools perform implementation and verification. CAS returns review
attempt and verdict evidence. `$review-fold` classifies findings into a
Counterexample Set; `$actuating` evaluates that set, selects any successor
Construction, and chooses the next action.
`$ship` performs and reads back public effects. Ledger may record their
evidence only when `$actuating` requests it.

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
  "record_version": "NER-v2",
  "kind": "realization_route",
  "route_id": "review-route",
  "cluster_id": "same-cluster",
  "artifact_state_id": "HEAD",
  "artifact_state_label": "HEAD",
  "hypothesis": "The route fails under the current artifact.",
  "attempted_change": "Implemented the review-route repair.",
  "observed_outcome": "The representative contract test still fails.",
  "failure_class": "no-effect",
  "source_refs": [
    { "kind": "test", "ref": "zig build test-ledger --summary all" }
  ],
  "falsifying_evidence": ["The representative contract test still fails."],
  "exclusion_scope": "route",
  "exclusion_rule": "Do not retry review-route while this artifact and proof surface apply.",
  "applicability_conditions": ["The current implementation and contract fixture are unchanged."],
  "reopening_criteria": [
    {
      "id": "artifact-or-fixture-changed",
      "condition": "The implementation or representative fixture changes."
    }
  ],
  "confidence": "high",
  "next_search_hint": "Inspect the adjacent owner boundary.",
  "applicable_paths": ["apps/ledger"]
}
```

Records get monotonic `NEG-*` ids. Git labels such as `HEAD` are resolved to a full commit ID before persistence while the original text remains in `artifact_state_label`. `commit:` and `tree:` identities require a concrete full object ID or a suffix that Git can resolve to one; `sha256:` and `surface:` identities require exactly 64 hexadecimal digits. An unresolved, malformed, empty, or otherwise mutable artifact identity cannot become active. The CLI derives `repository_id` from the Git remote when the capture omits it.

One status-aware NER-v2 validator governs capture, replay/doctor, map, handoff, and export. An incomplete capture that requests or defaults to `active` is stored as `need-evidence`. Malformed typed fields, witness references, applicability arrays, or reopening criteria are rejected before append.

Capture may begin only in `capture_candidate`, `need-evidence`, `unknown`, or `active`; lifecycle-only states must be reached through a proof-bearing status event. Pre-NER-v2 captures and proofless legacy authority events remain readable but project as `need-evidence`, never block, and permit a complete NER-v2 replacement to be appended before the legacy record is superseded.

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

Active exclusions require an explicit supported scope. Same-cluster recurrence is reusable memory, not an automatic ban.

To block a whole cluster, use the complete active record above but replace its route identity with an explicit cluster identity:

```json
{
  "cluster_id": "same-cluster",
  "exclusion_scope": "cluster",
  "exclusion_rule": "Do not repeat this cluster while the recorded applicability conditions hold."
}
```

## Route Gate

`map` emits a machine-readable `negative_route_gate` object.

- Every advertised scope has a native exact matcher: `exact`, `route`, `route_family`, `cluster`, `authority_model`, `distinction_pattern`, and `proof_pattern`.
- Supply the corresponding selector with `--route`, `--route-family`, `--cluster`, `--authority-model`, `--distinction-pattern`, or `--proof-pattern`.
- An active record blocks only when its declared scope identity and immutable artifact identity both match.
- Fuzzy lexical matches are advisory only.
- A matching `reopened` record is reported as `reopen_required` rather than disappearing from the gate.
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
    "command": "ledger map --route review-route --cluster same-cluster --artifact 0123456789abcdef0123456789abcdef01234567",
    "exit_code": 0,
    "ledger_available": true,
    "active_exclusion_match": false,
    "exclusion_id": "none",
    "reopen_required": false,
    "reopen_evidence_id": "none",
    "fuzzy_candidates": 0,
    "fuzzy_authority": "suggest_only",
    "artifact_state_id": "0123456789abcdef0123456789abcdef01234567",
    "artifact_state_label": "0123456789abcdef0123456789abcdef01234567",
    "failure": "none",
    "handoff_allowed": true
  }
}
```

`doctor` validates both event-stream integrity and projection safety, including malformed events and active records that cannot legally block. With the current JSONL adapter, diagnostics retain physical line locations.

## Lifecycle and memory projection

`status` and `reopen` append typed lifecycle events without rewriting historical captures. Every transition requires a JSON proof packet with a reason and structured source references:

```json
{
  "reason": "The prior evidence was accepted as a bounded risk.",
  "source_refs": [
    { "kind": "review", "ref": "PR 123 acceptance" }
  ]
}
```

```bash
ledger status \
  --id NEG-000001 \
  --to accepted_risk \
  --json transition.json
```

A reopen packet must prove an actual before/after change for at least one recorded criterion:

```json
{
  "reason": "The implementation and representative fixture changed.",
  "criterion_changes": [
    {
      "criterion_id": "artifact-or-fixture-changed",
      "before": "commit abc123 with fixture v1",
      "after": "commit def456 with fixture v2"
    }
  ],
  "source_refs": [
    { "kind": "git", "ref": "commit:def456" },
    { "kind": "test", "ref": "zig build test-ledger --summary all" }
  ]
}
```

```bash
ledger reopen --id NEG-000001 --json reopen-proof.json
```

Ledger rejects illegal status edges, mismatched `from` state, proofless promotion, and reopen packets whose criterion is absent or unchanged before append. New transition events carry an event ID, timestamp, `from`, `to`, reason, criterion IDs and changes, and source references. Supported projected statuses are `capture_candidate`, `need-evidence`, `unknown`, `active`, `accepted_risk`, `stale`, `reopened`, and `superseded`. Only `active` records block; `reopened` records remain visible as retry proof obligations.

Use `export` for complete current projections:

```bash
ledger export --id NEG-000001 --format full
ledger export --id NEG-000001 --format memory-note |
  memory-note append --extension negative-ledger --kind ledger-projection --json -
```

The same Negative Ledger commands are available through the uniform source
namespace, for example `ledger export --source negative-ledger --id
NEG-000001 --format memory-note`. Source-less commands remain supported.

`export` and `handoff` fail closed when the store or selected projection is semantically invalid. Repo-scoped memory projections include a stable repository identity and applicable paths, so identical `NEG-*` IDs from different repositories remain distinct.

Negative Ledger `show` remains concise. Learnings `show` is an exact alias for
`export --format full` because the canonical learning row is already the full
single-record projection. Negative Ledger full projections expose separate
`capture_event_count`, `status_event_count`, and `source_event_count`, the event-chain fingerprint, the current projection fingerprint, and the prior projection fingerprint when a lifecycle transition created a linked projection. Transport-only export timestamps do not affect projection identity. Re-exporting unchanged memory-note output is byte-stable; a meaningful lifecycle transition produces a new projection linked to the prior fingerprint.
