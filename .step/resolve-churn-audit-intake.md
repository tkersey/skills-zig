# st graph intake

Source: .step/resolve-churn-audit-spec.md

## Intent

- intent-001 | requirement | covered
  Text: Add native `seq resolve-churn-audit` command recognition and CLI validation for `--since`, `--until`, `--repo`, `--exclude-current`, and `--format markdown|json`.
  Source: .step/resolve-churn-audit-spec.md#command-contract

- intent-002 | requirement | covered
  Text: Emit the required `resolve_churn_audit` tree in markdown and JSON, including denominator, review horizon, finding liability, normal forms, fuse, owner pressure, mutation, permits, negative ledger, review, and compliance sections.
  Source: .step/resolve-churn-audit-spec.md#required-output-shape

- intent-003 | requirement | covered
  Text: Use transcript/session evidence for workflow attribution and only use Git/tool lifecycle as supplemental repo evidence.
  Source: .step/resolve-churn-audit-spec.md#evidence-rules

- intent-004 | requirement | covered
  Text: Do not classify raw `$resolve` mentions as true resolve sessions without assistant-side workflow/tool evidence.
  Source: .step/resolve-churn-audit-spec.md#evidence-rules

- intent-005 | test-expectation | covered
  Text: Add focused tests and run `zig fmt`, `zig build test-seq --summary all`, `zig build build-seq --summary all`, and `git diff --check`.
  Source: .step/resolve-churn-audit-spec.md#validation

- intent-006 | requirement | covered
  Text: Update docs and release-relevant `seq` version metadata.
  Source: .step/resolve-churn-audit-spec.md#acceptance

## Items

### st-121 | feature | high

Step: Wire native `seq resolve-churn-audit` command surface

Covers:
- intent-001

Depends:
- none

Locations:
- apps/seq/src/lib.zig
- apps/seq/src/commands/mod.zig
- apps/seq/src/tests.zig

Acceptance:
- `lib.parseCommand("resolve-churn-audit")` maps to `Command.resolve_churn_audit`.
- `run` dispatches the command to an implementation function.
- Help text documents required options.
- Validation requires `--since`, `--until`, and `--repo`.
- Validation accepts `--exclude-current` and rejects non-markdown/non-json formats.

Validation:
- `zig build test-seq --summary all`

Proof:
- proof-001 | unit | `zig build test-seq --summary all`

Contract:
Background:
The user requested a native command, not a shell/JQ report.

Objective:
Expose the command through the existing `seq` command registry and validation path.

Implementation Approach:
Follow nearby audit command patterns in `apps/seq/src/commands/mod.zig` and keep option handling on existing shared validators.

Risks:
- Accidentally allowing unsupported formats.
- Treating missing required flags as generic unsupported options instead of a hard command contract failure.

### st-122 | feature | high

Step: Implement transcript-first resolve churn audit aggregation and rendering

Covers:
- intent-002
- intent-003
- intent-004

Depends:
- st-121

Locations:
- apps/seq/src/commands/mod.zig

Acceptance:
- Scans local rollout JSONL traces under the selected root.
- Applies `--since`, `--until`, `--repo`, and `--exclude-current`.
- Counts candidate sessions separately from true resolve sessions.
- Raw `$resolve` mentions are exclusions unless assistant workflow/tool evidence exists.
- Emits markdown with the required YAML-shaped `resolve_churn_audit` tree.
- Emits JSON with the same top-level sections.
- Mutation, review, and repo evidence are derived from canonical tool lifecycle records only after session/repo filters.

Validation:
- `zig build test-seq --summary all`
- `git diff --check`

Proof:
- proof-001 | unit | `zig build test-seq --summary all`
- proof-002 | hygiene | `git diff --check`

Contract:
Background:
The audit is intended to measure workflow churn, so workflow attribution must come from transcript/session evidence rather than raw mentions or Git state alone.

Objective:
Produce conservative churn counts with stable markdown and JSON output.

Implementation Approach:
Use canonical trace parsing and messages parsing; summarize assistant-side evidence, then augment with tool lifecycle data for mutation/review counters.

Risks:
- Over-counting mention-only sessions.
- Treating supplemental tool/Git evidence as primary workflow attribution.
- Line-count attribution is best-effort when traces do not preserve patch body text.

### st-123 | verification | high

Step: Add tests, docs, version bump, and proof closure for `resolve-churn-audit`

Covers:
- intent-005
- intent-006

Depends:
- st-122

Locations:
- apps/seq/src/commands/mod.zig
- apps/seq/src/tests.zig
- apps/seq/README.md
- apps/seq/VERSION

Acceptance:
- Regression test proves one true resolve session and one mention-only session produce `candidate_sessions: 2`, `true_resolve_sessions: 1`, and `exclusions: 1`.
- README documents command examples and evidence semantics.
- `apps/seq/VERSION` is bumped for the release-relevant CLI surface.
- Formatter, focused tests, build, and diff hygiene pass.

Validation:
- `zig fmt apps/seq/src/lib.zig apps/seq/src/commands/mod.zig apps/seq/src/tests.zig`
- `zig build test-seq --summary all`
- `zig build build-seq --summary all`
- `git diff --check`

Proof:
- proof-001 | format | `zig fmt apps/seq/src/lib.zig apps/seq/src/commands/mod.zig apps/seq/src/tests.zig`
- proof-002 | unit | `zig build test-seq --summary all`
- proof-003 | build | `zig build build-seq --summary all`
- proof-004 | hygiene | `git diff --check`

Contract:
Background:
The command is a user-facing `seq` surface and needs test/docs/version closure.

Objective:
Prove the requested behavior, document it, and leave release metadata coherent.

Implementation Approach:
Add focused fixture-style tests beside existing command tests, document usage in `apps/seq/README.md`, and bump the `seq` version file.

Risks:
- Passing tests that do not cover the denominator rule.
- Forgetting the version bump for a release-relevant CLI addition.
