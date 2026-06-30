# st graph intake

Source: user `$spec-pipeline`, `$plan`, and `$actuating $land` handoff for `seq review-compiler-audit`.

## Intent

- intent-rca-c3-001 | requirement | covered
  Text: `seq review-compiler-audit` must support `--protocol auto|legacy-cleanroom|c3`, defaulting to `auto`, without creating a second command.
  Source: .step/review-compiler-audit-plan.md#cli-contract

- intent-rca-c3-002 | requirement | covered
  Text: True C3 detection must require assistant/tool evidence for review_compile.py begin, .ledger/resolve/c3/state.json, minimal_review_patch_certificate, or MRPC-v1; raw `$resolve` text is candidate-only.
  Source: .step/review-compiler-audit-plan.md#locked-decisions

- intent-rca-c3-003 | compatibility | covered
  Text: Historical cleanroom counters must remain available under legacy_cleanroom and must not be combined with CEB/MRPC counters.
  Source: .step/review-compiler-audit-plan.md#compatibility

- intent-rca-c3-004 | requirement | covered
  Text: C3 audit output must expose denominator, controller, counterexamples, tournament, semantic_cost, ablation, lab_vs_delivery, holdout, delivery, and compliance sections in markdown and JSON.
  Source: .step/review-compiler-audit-plan.md#required-c3-output

- intent-rca-c3-005 | requirement | covered
  Text: Event ordering must use .ledger/resolve/c3/events.jsonl transcript evidence when present and otherwise derive ordered evidence from assistant text and controller tool records.
  Source: .step/review-compiler-audit-plan.md#event-ordering

- intent-rca-c3-006 | requirement | covered
  Text: Delivery mutation violations must be counted only between begin and closed or aborted, excluding lab/candidate worktree activity and compliant controller commit/push/apply events.
  Source: .step/review-compiler-audit-plan.md#event-ordering

- intent-rca-c3-007 | test-expectation | covered
  Text: The twelve user-specified C3/legacy scenarios must be covered by focused Zig fixture tests and local seq proof commands.
  Source: .step/review-compiler-audit-plan.md#required-tests

- intent-rca-c3-008 | documentation | covered
  Text: README, help text, and apps/seq/VERSION must reflect the shipped protocol option.
  Source: .step/review-compiler-audit-plan.md#done-state

## Items

### st-141 | feature | high

Step: Add review-compiler-audit protocol CLI surface

Covers:
- intent-rca-c3-001
- intent-rca-c3-008

Depends:
- none

Locations:
- apps/seq/src/commands/mod.zig
- apps/seq/README.md
- apps/seq/VERSION

Acceptance:
- `seq review-compiler-audit --help` documents `--protocol auto|legacy-cleanroom|c3`.
- The parser accepts `--protocol auto`, `--protocol legacy-cleanroom`, and `--protocol c3`.
- Invalid protocol values fail with `InvalidModeArg` or an equivalent validation error.
- `--protocol` is rejected for commands other than `review-compiler-audit`.
- `apps/seq/VERSION` is bumped by one patch version from the execution-time current value.

Validation:
- zig build test-seq --summary all
- zig build build-seq -Doptimize=ReleaseFast --summary all

Proof:
- proof-001 | unit | zig build test-seq --summary all
- proof-002 | build | zig build build-seq -Doptimize=ReleaseFast --summary all

Contract:
Background:
The existing command supports only the legacy cleanroom audit and has no protocol option in shared Options parsing.

Objective:
Expose the requested protocol selector without changing command identity or overloading `--mode`.

Implementation Approach:
Add a protocol option field, parser branch, validation helper, command support gate, help text, README documentation, and parser/validation tests.

Risks:
- Shared parser changes can accidentally expose `--protocol` to unrelated commands.
- Help/docs can drift from the actual accepted values.

### st-142 | feature | high

Step: Split legacy cleanroom and C3 audit model/output

Covers:
- intent-rca-c3-003
- intent-rca-c3-004

Depends:
- st-141 | requires

Locations:
- apps/seq/src/commands/mod.zig

Acceptance:
- Legacy fields render under `legacy_cleanroom`.
- CEC/DPR/compiled-permit counters are not added to CEB/MRPC counters.
- Markdown and JSON render the same protocol, denominator, C3 sections, and legacy compatibility data.
- `auto` renders protocol `c3` when any true C3 evidence exists and `legacy-cleanroom` otherwise.
- Metric ratios never divide by zero and emit null plus a reason when denominator data is missing.

Validation:
- zig build test-seq --summary all

Proof:
- proof-001 | unit | zig build test-seq --summary all

Contract:
Background:
The existing ReviewCompilerAudit struct is legacy-cleanroom shaped and directly writes markdown/JSON.

Objective:
Add protocol-aware output while preserving historical reporting.

Implementation Approach:
Refactor the accumulator into protocol selection, legacy cleanroom counters, C3 counters, metric helpers, and shared markdown/JSON renderers.

Risks:
- Output compatibility can regress if legacy fields move without stable namespacing.
- Nullable metric reasons can diverge between markdown and JSON.

### st-143 | feature | high

Step: Implement C3 evidence detection, ordering, and compliance counters

Covers:
- intent-rca-c3-002
- intent-rca-c3-004
- intent-rca-c3-005
- intent-rca-c3-006

Depends:
- st-142 | requires

Locations:
- apps/seq/src/commands/mod.zig

Acceptance:
- Raw `$resolve` mentions are candidate sessions but not true C3 sessions.
- True C3 sessions are recognized from the four locked evidence tokens.
- Stage counters distinguish begin, apply-certified, final-certified, committed, pushed, and closed.
- Active run windows start at begin and end at closed or aborted.
- Delivery apply_patch and raw git commit/push while active count as bypass violations.
- Controller apply/commit/push commands are compliant.
- Candidate/lab worktree patching and commits count as lab activity only.
- Holdout new counterexamples followed by reset/new basis count as recompilations.
- Adjacent follow-ups do not count as scope expansion.
- Orphan edit atoms and stale MRPC evidence are surfaced.

Validation:
- zig build test-seq --summary all

Proof:
- proof-001 | unit | zig build test-seq --summary all

Contract:
Background:
The existing scanner already combines parsed messages with canonical_trace tool lifecycle records, but only for legacy cleanroom artifacts.

Objective:
Implement the C3 controller audit semantics from transcript/tool evidence without live Git or GitHub queries.

Implementation Approach:
Build per-session C3 signals from message text and tool records, derive ordered events by timestamp, classify lab/delivery cwd and command text, and finalize session-level compliance after scan.

Risks:
- Transcript wording can be sparse or inconsistent, so detection must remain conservative.
- Active-run state can overcount if abort/closed boundaries are missed.

### st-144 | test | high

Step: Add focused C3 and legacy regression fixtures

Covers:
- intent-rca-c3-001
- intent-rca-c3-002
- intent-rca-c3-003
- intent-rca-c3-004
- intent-rca-c3-005
- intent-rca-c3-006
- intent-rca-c3-007

Depends:
- st-143 | requires

Locations:
- apps/seq/src/commands/mod.zig

Acceptance:
- Test 1 proves raw `$resolve` mention is not true C3.
- Test 2 proves begin without MRPC is entered but incomplete.
- Test 3 proves apply-certified, final-certified, committed, pushed, and closed stages count separately.
- Test 4 proves direct delivery apply_patch while active is a violation.
- Test 5 proves candidate-worktree patching is lab activity.
- Test 6 proves raw git commit while active is a bypass.
- Test 7 proves controller commit and push are compliant.
- Test 8 proves new holdout counterexample plus reset/new basis counts as recompilation.
- Test 9 proves adjacent follow-up does not count as scope expansion.
- Test 10 proves orphan edit atoms are surfaced.
- Test 11 proves tournament waiver is distinct from material single-candidate violation.
- Test 12 proves historical legacy fixture output remains stable under `legacy_cleanroom`.

Validation:
- zig build test-seq --summary all

Proof:
- proof-001 | unit | zig build test-seq --summary all

Contract:
Background:
The current command has one inline legacy cleanroom test.

Objective:
Turn the user’s numbered scenarios into regression fixtures before shipping.

Implementation Approach:
Use temporary session JSONL traces consistent with existing tests, asserting JSON substrings for protocol and counters.

Risks:
- Overly broad substring assertions can pass despite wrong nesting; include protocol and section-specific substrings.

### st-145 | verification | high

Step: Validate, ship, and land review-compiler-audit C3 protocol

Covers:
- intent-rca-c3-007
- intent-rca-c3-008

Depends:
- st-144 | requires

Locations:
- apps/seq/src/commands/mod.zig
- apps/seq/README.md
- apps/seq/VERSION
- .step/review-compiler-audit-plan.md

Acceptance:
- `zig build test-seq --summary all` passes.
- `zig build build-seq -Doptimize=ReleaseFast --summary all` passes.
- `bash apps/seq/scripts/release/command_surface_gate.sh ./zig-out/bin/seq` passes.
- `git diff --check` passes.
- Durable `$st` proof is recorded for each required proof obligation.
- PR is opened or updated with proof.
- Review threads are fully paginated with zero unresolved threads before merge.
- Required checks are green and merge uses `--match-head-commit`.
- Local and remote branch cleanup is verified after landing.

Validation:
- zig build test-seq --summary all
- zig build build-seq -Doptimize=ReleaseFast --summary all
- bash apps/seq/scripts/release/command_surface_gate.sh ./zig-out/bin/seq
- git diff --check

Proof:
- proof-001 | unit | zig build test-seq --summary all
- proof-002 | build | zig build build-seq -Doptimize=ReleaseFast --summary all
- proof-003 | command-surface | bash apps/seq/scripts/release/command_surface_gate.sh ./zig-out/bin/seq
- proof-004 | diff-check | git diff --check

Contract:
Background:
The user requested `$actuating $land`, so implementation, PR publication, and guarded merge are in scope.

Objective:
Close the feature end-to-end with current proof and guarded PR landing.

Implementation Approach:
Record proof receipts, commit and push a scoped branch, create or update a ready PR, sweep review threads, wait for checks, squash-merge with `--match-head-commit`, and verify cleanup.

Risks:
- Hosted checks, branch protection, reviews, or permissions may block landing after local work is complete.
