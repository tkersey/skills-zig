# ledger

Repo-local durable source, actuation, and plan ledger with pure validation of governance and review artifacts. Its replay product surface is available on macOS.

`ledger` stores disconfirmed hypotheses, failed routes, reopening criteria, and route-exclusion evidence in an append-only event store that future runs can query through the Ledger API.
It also owns causal actuation under `--source actuation`, learning capture under `--source learnings`, and, on macOS, replay-campaign evidence under `--source hylo`.
`ledger validate` checks immutable governance and review artifacts without reading or writing
any ledger store and without granting execution authority.

The negative ledger, actuation, learning, and Synesthesia sources, plus the
macOS-only Hylo source, share one
storage contract: ordered snapshots, opaque revisions, compare-and-append,
atomic replacement, exclusive effectful-transition sessions, and logical store
identity. The current persistent adapter is JSONL, so existing commands, paths,
stores, and migration workflows remain compatible. A backend change is
confined to the persistent adapter; migrated source callers do not split lines
or coordinate storage locks.

Current negative-ledger adapter path:

```bash
.ledger/negative-ledger/events.jsonl
```

Current learning-source adapter path:

```bash
.ledger/learnings/events.jsonl
```

Current actuation-source adapter path:

```bash
.ledger/actuation/events.jsonl
```

Current macOS Hylo adapter path:

```bash
.ledger/hylo/events.jsonl
```

Ledger 0.10.1 adds the additive `hylo-trial/v1` profile. The native Hylo source
owns atomic twin-trial registration, FD-delivered lane leases, signed run and
grade receipts, blinded arm reveal, cluster-balanced effects, calibrated claim
derivation, publication identity, and reproducible proof bundles. Legacy Hylo
campaigns retain their original attempt semantics.

The `ledger --source hylo` replay and HCTP lifecycle is supported only on
macOS. The stateless `ledger validate hylo-*` contracts remain pure,
platform-neutral validation: they neither expose the Hylo source runtime nor
grant execution authority.

```bash
ledger --source hylo capabilities
ledger --source hylo validate-trial --repo REPO --trial trial.json
ledger --source hylo register-trial --repo REPO --trial trial.json
ledger --source hylo start-lane --repo REPO --campaign-id CAMPAIGN --trial-id TRIAL \
  --lane-id LANE --runner-id cas-trial --lease-output-fd 3
ledger --source hylo recover-lane-start --repo REPO --campaign-id CAMPAIGN \
  --trial-id TRIAL --lane-id LANE --runner-id cas-trial \
  --lane-lease-digest DIGEST --lease-input-fd 3
ledger --source hylo recover-lane-finish --repo REPO --receipt run-receipt.json \
  --lease-input-fd 3
ledger --source hylo trial-result --repo REPO --trial-id TRIAL --format markdown
ledger --source hylo proof-artifact-set --repo REPO --trial-id TRIAL \
  --output proof-artifacts.json
# A trusted source_owner signs that exact set as hylo-proof-sanitization-receipt/v1.
ledger --source hylo export-proof --repo REPO --trial-id TRIAL --output proof.tar \
  --sanitization-receipt proof-sanitization.json
ledger --source hylo verify-proof --repo REPO --input proof.tar
```

Trial lifecycle events can be mutated only through the high-level commands.
The low-level `append` command rejects them, and lease secrets never enter the
event store, normal stdout, or proof bundles. `start-lane` first transfers one
`PIPE_BUF`-bounded lease record through a validated anonymous pipe and only then
appends `lane_started`; the raw nonce is inert until that event commits its
digest. If the public receipt is lost after the commit, `recover-lane-start`
re-emits it without appending only when the caller supplies the retained lease
and the exact campaign, trial, lane, runner, and lease digest. This recovery
contract assumes the broker survives long enough to retain the delivered
lease. It does not recover a capability discarded by a dead broker or receiver;
that stronger failure model requires an explicit lease-rotation transition.
If a terminal append commits before its public acknowledgement is retained,
`recover-lane-finish` emits a typed acknowledgement without appending only when
the retained lease, receipt lineage, and canonical run-receipt fingerprint equal
Ledger's terminal lane state. Bare terminal status is not recovery authority.

Default live `verify-proof` treats the manifest's declared global event range
as an immutable prefix: it matches every declared digest against one current
store snapshot and validates the complete live suffix chain. Later valid events,
including events in the same campaign, therefore do not invalidate an earlier
closed-trial proof. The explicit `--expected-campaign-head` and
`--expected-trust-policy-fingerprint` pair remains an offline exact-value
anchor; it does not consult or imply the current live head.

Universalist plan artifacts:

```bash
.ledger/universalist/plan-<UTC_TIMESTAMP>-<ORDINAL>.md
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
ledger export --source learnings --id lrn-... --format memory-note
ledger migrate --source learnings --mode copy
ledger doctor --source learnings
ledger open --source actuation --json actuation-open.json
ledger prepare --source actuation --run RUN-ID --json operation.json
ledger state --source actuation --run RUN-ID
ledger decide --source actuation --run RUN-ID
ledger --source hylo validate-campaign --campaign campaign.json
ledger --source hylo fingerprint --input artifact.json
ledger --source hylo snapshot-target --repo . --revision INDEX --input target-roots.json
ledger --source hylo append --repo . --json event-intent.json
ledger --source hylo doctor --repo .
ledger --source hylo progress --repo . --campaign-id cmp-example --format markdown
ledger --source hylo frontier --repo . --campaign-id cmp-example --format markdown
ledger --source hylo next-experiment --repo . --campaign-id cmp-example
ledger --source hylo path --repo .
ledger create --source universalist --template universalist-plan.md
ledger latest --source universalist
ledger latest --source universalist --format path
ledger path --source universalist --id 20260711T164436123456789Z-0000
ledger emit --source universalist --plan PLAN --contract CONTRACT [receipt fields] [--write-plan]
ledger validate plan-source-contract --input plan-source-contract.json
ledger validate policy-synthesis-receipt --input synthesis-receipt.json
ledger validate review-fold --input review-fold.json
ledger validate actuation-review-policy --phase preflight --input review-policy.json
ledger validate review-resolution --phase preflight --input review-resolution.json
ledger validate hylo-replay-episode --input episode.json
ledger validate hylo-runner-input --input runner-input.json
ledger validate source-memory-checkpoint --input source-memory-checkpoint.json
```

The CRF episode validator checks the cut-bound causal fingerprint and ordered stimulus contract. The runner validator checks the allow-listed projection, rejects custody fields recursively, and never grants execution or edit authority.

Use `--file PATH` to point at a non-default store.
For `--source learnings`, `--file PATH` is accepted as an alias for the learning event path.
`--source negative-ledger` is an additive namespace alias for the source-less
Negative Ledger commands; it preserves `--file` and all existing command
semantics.

## Universalist plan and receipt ownership

`ledger --source universalist` owns plan identity, allocation, lookup, and
SDR-v1 receipt emission. Universalist owns the decision policy, SKDC-v1
contract, plan template, and ordinary Markdown field updates. This receipt
boundary requires Ledger 0.10.4 or newer and `seq` on `PATH`.

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

Ledger validates the contract through Seq, rejects unknown trigger, clause, or
route references, derives the decision id and repository state, constructs
canonical compact SDR-v1 JSON, and validates the generated receipt through Seq
before any plan mutation. `--write-plan` accepts only the canonical
`.ledger/universalist/plan-<id>.md` path, atomically appends one receipt, and
rejects a second append. Without `--write-plan`, the command is a plan-read-only
receipt projection and may use a non-addressed plan when `--decision-id` is
explicit.

## Hylo replay kernel

On macOS, `ledger --source hylo` owns the durable evidence boundary for replay-driven
improvement campaigns. This hardened contract requires Ledger 0.6.1 or newer:

```text
unfold historical evidence -> content-addressed campaign and scenarios
interpret one scenario      -> attempt trace
grade frozen observations   -> evidence-bound grade
fold immutable events       -> progress, deltas, and frontier
```

Campaigns and scenarios are language-neutral JSON contracts. Validate the
content-addressed pair before running it:

```bash
ledger --source hylo validate-campaign --campaign campaign.json
```

Use `fingerprint` to obtain the canonical lowercase SHA-256 fingerprint of any
JSON snapshot. A `campaign_created` intent embeds the complete
`hylo-campaign/v1` snapshot, its complete scenario manifest, and its
fingerprint; a `scenario_admitted` intent does the same for one
`hylo-scenario/v1`. Attempts remain blocked until every manifest member is
admitted. This keeps later folds independent of mutable campaign files and
prevents selective admission of easy cases.

New Hylo, HCTP, and CRF identity use the published
`hylo-canonical-json/v1` profile. A campaign that enables the
`hylo-trial/v1` protocol must set
`"canonical_json_profile":"hylo-canonical-json/v1"`; every registered trial
must repeat that binding, and canonical JSON SHA-256 commitments use the
profile-specific `sha256-hylo-canonical-json-v1` algorithm label. Legacy Hylo
campaigns reject the profile field. Released DCP-v2 packet identity remains on
its frozen legacy writer; adopting this profile for DCP requires a versioned
DCP-v3 migration. The new profile is deliberately narrower and more explicit
than a claim of complete RFC 8785 support:

- JSON `integer` values retain their exact signed 64-bit value. Arbitrary
  `number_string` values and non-finite floats are rejected.
- Finite `f64` values use shortest-round-trip Ryu digits with the pinned
  ECMAScript fixed/scientific thresholds and exponent spelling; negative zero
  is `0`.
- Strings and keys must be valid UTF-8. Their code points are preserved without
  Unicode normalization, escapes are fixed, and object keys sort by raw UTF-8
  bytes. RFC 8785 instead specifies UTF-16 code-unit key order.

The executable corpus, including RFC 8785 Appendix B numeric samples and
profile-specific Unicode, key-order, escape, integer, and digest vectors, is
`testdata/hctp-v1/canonical-json-v1.json`. Identity-bearing code must use the
shared codec rather than language-default float formatting.

The profile's repo-owned layout and threshold logic consumes shortest decimal
digits from the Zig 0.16 standard library's explicit Ryu renderer; the Ryu
implementation is not vendored. A Zig toolchain upgrade must pass this corpus
before it can author identity bytes. If it cannot preserve the locked bytes,
the profile must be versioned and existing identities migrated explicitly. In
addition to every RFC 8785 Appendix B case, the tests bind a deterministic
16,384-bit-pattern digest and verify finite-value round trips. This is a broad
compatibility lock, not an exhaustive proof over all 64-bit floating-point bit
patterns.

For Git-backed targets, capture the exact tree projection used by a replay:

```bash
ledger --source hylo snapshot-target \
  --repo /path/to/repo \
  --revision INDEX \
  --input target-roots.json
```

The request is `hylo-target-snapshot-request/v1` with ordered `roots`. Use
`INDEX` for a staged candidate. A baseline input such as `HEAD` is resolved in
the receipt to its full immutable commit SHA; scenario and attempt contracts
store that resolved SHA rather than the moving name. Comparable attempts in a
commit-authorized campaign embed the receipt's revision, snapshot, and
fingerprint.

A target bundle fingerprint is semantic identity modulo artifact locator: the
entrypoint, path/mode/content fingerprints, target-content fingerprint, loader
contract, and dependency bundle fingerprints are identity-bearing, while a
`content_ref` that merely relocates the same verified bytes is not. Moving
identical content therefore cannot manufacture a new treatment. The complete
admitted manifest remains retained as provenance and its referenced bytes are
verified independently.

Only `append` mutates the logical Hylo event store; the current JSONL adapter
retains the default path above:

```bash
ledger --source hylo append --repo /path/to/repo --json event-intent.json
```

The native source supplies global and per-campaign sequence numbers,
timestamps, predecessor digests, canonical body digests, and event digests. It
then validates the proposed state transition inside one exclusive durable
event-store session, appends against the loaded revision, and enforces a strict
post-append reload cap. `doctor` replays both hash chains and all transition
laws from genesis.

The fold distinguishes two baselines:

- `historical_baseline` records and grades the response that actually happened;
  its grades are diagnostic and cannot enter progress denominators.
- `replay_baseline` is a fresh blind controlled replay of the frozen baseline
  target; its attempt must predate the candidate attempt for the same scenario.
  Only eligible blind replays can be compared with candidates.

For comparable pass/fail grades, Ledger re-derives the aggregate from the
campaign's frozen dimension weights. It rejects duplicate eligible grades for
one attempt, target/environment/replay-policy drift, grader drift, historical
comparison, non-blind comparison, pass/fail labels that contradict policy, and
critical oracles without evidence from their declared authority. Candidate
comparison requires a like-for-like controlled replay baseline. Ledger freezes
declared judge and dimension authority in campaign syntax and oracle authority
in scenario syntax before replay; the referenced receipts or human
confirmations establish authenticity outside this declaration-consistency
check.

Hylo does not edit a target or create a commit by itself. An authorized owner
workflow may apply the change and, only when the campaign grants publication
authority, create the commit. An applied change must be the exact staged
`git-index:HEAD` diff: Ledger re-derives its fingerprint, requires the staged
path set to equal the event paths, and rejects tracked or untracked
contamination under every target root. Each candidate attempt rechecks that
diff and recomputes its staged snapshot. Only practice evidence may motivate
repair; once an eligible holdout or challenge grade is exposed, the campaign
rejects further applied changes. A committed publication must cite exactly the
latest configured repeat cohort for every frozen scenario, and the entire
cohort must pass. The append path independently resolves the cited Git commit,
tree, and exact changed-path set, then requires the committed target projection
to equal the snapshot used by every promotion attempt. One promotion trial may
authorize at most one committed publication; a second committed publication is
rejected atomically even when it uses a distinct publication ID.

Derive a current view without storing a mutable summary:

```bash
ledger --source hylo progress \
  --repo /path/to/repo \
  --campaign-id cmp-example \
  --format json
```

The `hylo-progress/v1` projection reports current-target split results,
target-by-split summaries, per-dimension means, current-target scenario
outcomes, repeat-aware frontier cases, and grader-stable cross-target edges.
Passing repeats are consecutive in the latest current-target cohort, so a new
failure reopens the frontier. Its fingerprint is bound to the campaign chain
head. A changed rubric,
visibility policy, environment observation surface, grader configuration, or
replay policy requires a new campaign rather than a misleading continuation.

The causal frontier retains typed state through
`failure_signature_recorded`, `hypothesis_recorded`, `experiment_recorded`,
and `next_step_recorded` events. Ledger derives experiment eligibility,
Pareto dominance, and the next-step decision from the current immutable
campaign state; `next_step_recorded` must match that recomputed decision
exactly.

Inspect the complete frontier or only its `RUN`, `OBSERVE`, or `STOP`
decision without mutating campaign state:

```bash
ledger --source hylo frontier \
  --repo /path/to/repo \
  --campaign-id cmp-example \
  --format json

ledger --source hylo next-experiment \
  --repo /path/to/repo \
  --campaign-id cmp-example
```

These projections always report `authority_granted:false` and
`target_mutated:false`. `RUN` selects one non-dominated eligible experiment;
it does not authorize an edit. `OBSERVE` selects a bounded read-only probe.
`STOP` is the expected result when no eligible intervention exists or when
multiple non-dominated alternatives remain and no bounded probe can
discriminate among them.

## Stateless validation

`ledger validate` is the pure validation surface for artifacts that participate
in planning and review evidence:

```bash
ledger validate plan-source-contract --input plan-source-contract.json
ledger validate policy-synthesis-receipt --input synthesis-receipt.json
ledger validate review-fold --input review-fold.json
ledger validate actuation-review-policy --phase preflight --input review-policy.json
ledger validate review-resolution --phase preflight --input review-resolution.json
ledger validate hylo-replay-episode --input episode.json
ledger validate hylo-runner-input --input runner-input.json
ledger validate hylo-stimulus --input stimulus.json
ledger validate hylo-target-bundle --input target-bundle.json
ledger validate hylo-world-snapshot --input world-snapshot.json
ledger validate hylo-world-availability-receipt --input world-availability.json
ledger validate hylo-runtime-contract --input runtime-contract.json
ledger validate hylo-counterfactual-cut-receipt --input cut-receipt.json
ledger validate hylo-redaction-receipt --input redaction-receipt.json
ledger validate hylo-custody-manifest --input custody-manifest.json
ledger validate source-memory-checkpoint --input source-memory-checkpoint.json
```

Input is canonical JSON from a file or `-` for stdin. The general governance
contracts emit `ledger-validate-decision/v1`; the Actuating contracts emit their
domain decision schemas and require `--phase preflight|closeout`. Every
invocation exits `0` for `pass` and `2` for a blocked or malformed artifact.
Every decision records `authority_granted:false` and `storage_mutated:false`.
The Hylo validators are schema decisions only; their availability does not
admit the macOS-only replay or HCTP product routes.

`source-memory-checkpoint/v1` validation requires exactly one Learnings,
Synesthesia, and Negative Ledger disposition, checks source-specific IDs and
admission compatibility, and derives `complete`, `degraded`, or `blocked` from
those results. It validates coordination evidence only: source skills retain
semantic and mutation authority, and an admission failure after canonical
success must be represented as `degraded`, never as canonical rollback.

The Actuating review-policy checker preserves `actuation-review-policy/v1`
same-tuple suffix semantics and also accepts `actuation-review-policy/v2`.
Version 2 derives the standard clean suffix from an ordered attempt history and
permits tuple movement only through an `auxiliary-remediation` carry that binds
the resolution, correctness observations, actuation events, and SHIP receipt.
Carry transitions preserve credit but never add it, and closeout still requires
a clean standard attempt plus current auxiliary evidence on the current tuple.

The review-resolution checker continues to parse historical
`review-resolution/v1` snapshots while requiring
`owner-boundary-synthesis/v1` whenever a snapshot contains decisions. A
decision-free historical snapshot retains its prior result. A decision-bearing
historical snapshot parses but blocks until it carries resolution history,
owner syntheses, and synthesis-bound decisions.
The history goal must match every retained review fold, and every retained
prior synthesis must join exactly one current component.

Each synthesis identifies one stable structural component with
`stable_component_key`. The key is `sha256:` plus the lowercase SHA-256 digest
of this byte sequence:

```text
owner-boundary-synthesis/boundary-identity/v1\n
<compact JSON boundary identity>
```

The compact JSON object has the keys `source_worlds`, `target_worlds`,
`carriers`, `operations`, `observations`, and `laws` in that order. Each array
is sorted lexicographically before encoding. Generation, review tuple, commit,
publication, batch, and attempt provenance therefore cannot affect component
identity.

`reuse-owner` admits only pressure-free local repair and adds no structural
obligations. `converge-kernel` requires at least one abstraction-pressure
signal, a canonical owner, and structural obligations; its decisions must use
`replacement-kernel`. `separate-laws` carries a falsifiable obstruction and
cannot materialize repair. `blocked` carries a falsifier and cannot materialize
repair. Every repair decision cites its synthesis, uses the synthesis-owned
construction, and the resolution materializes exactly one selected work node
at the canonical owner named by the selected synthesis.

At closeout, every structural obligation needs an `observation_ref`.
`collapse`, `retire`, and `delegate` targets must be declared and completed as
semantic-balance retirements; `dominated_remaining` must be empty. The checker
validates those declarations but does not dereference observation artifacts or
execute verifier argv.

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

`show` remains concise. Full projections expose separate `capture_event_count`, `status_event_count`, and `source_event_count`, the event-chain fingerprint, the current projection fingerprint, and the prior projection fingerprint when a lifecycle transition created a linked projection. Transport-only export timestamps do not affect projection identity. Re-exporting unchanged memory-note output is byte-stable; a meaningful lifecycle transition produces a new projection linked to the prior fingerprint.
