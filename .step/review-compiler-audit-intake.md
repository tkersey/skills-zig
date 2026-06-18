# st graph intake

Source: .step/review-compiler-audit-plan.md

## Intent

- intent-rca-001 | requirement | covered
  Text: Add native `seq review-compiler-audit` with required `--since`, `--until`, `--repo`, optional `--exclude-current`, and `--format markdown|json`.
  Source: .step/review-compiler-audit-plan.md#cli-contract

- intent-rca-002 | requirement | covered
  Text: Emit the required `review_compiler_audit` tree in markdown and JSON.
  Source: .step/review-compiler-audit-plan.md#required-output

- intent-rca-003 | requirement | covered
  Text: Use transcript evidence as primary workflow attribution and Git/tool lifecycle transcript evidence only as supplemental repo evidence.
  Source: .step/review-compiler-audit-plan.md#locked-decisions

- intent-rca-004 | requirement | covered
  Text: Separate raw mention candidates from true cleanroom resolve sessions requiring assistant-side workflow or artifact evidence.
  Source: .step/review-compiler-audit-plan.md#locked-decisions

- intent-rca-005 | requirement | covered
  Text: Count lab-vs-delivery mutations and surface movement conservatively from transcript tool records and patch text.
  Source: .step/review-compiler-audit-plan.md#implementation-sequence

- intent-rca-006 | test-expectation | covered
  Text: Add fixture tests for true-vs-raw attribution, cleanroom artifacts, lab-vs-delivery surface, compliance, and output shape.
  Source: .step/review-compiler-audit-plan.md#implementation-sequence

- intent-rca-007 | test-expectation | covered
  Text: Run formatter, seq tests/build, standalone apps/seq tests, command surface gate, and diff check before shipping.
  Source: .step/review-compiler-audit-plan.md#implementation-sequence

- intent-rca-008 | requirement | covered
  Text: Ship validated work as a proof-backed PR without merging.
  Source: .step/review-compiler-audit-plan.md#done-state

## Items

### st-124 | feature | high

Step: Wire native seq review-compiler-audit command surface

Covers:
- intent-rca-001

Depends:
- none

Locations:
- apps/seq/src/lib.zig
- apps/seq/src/commands/mod.zig
- apps/seq/src/tests.zig

Acceptance:
- `seq review-compiler-audit --help` documents the required CLI.
- Parser recognizes `review-compiler-audit`.
- Option validation requires `--since`, `--until`, and `--repo`.
- Only `markdown` and `json` are valid output formats.
- `--exclude-current` and `--repo` are supported for the command.

Validation:
- `zig build test-seq --summary all`

Proof:
- proof-rca-001 | unit | `zig build test-seq --summary all`

Contract:
Background:
The source plan requires a new native seq command matching the prior `resolve-churn-audit` command style.

Objective:
Expose the CLI surface without changing existing command behavior.

Implementation Approach:
Add a `review_compiler_audit` command enum/definition, dispatcher branch, help text, option capability entries, required-argument validation, and format gate. Add parser/validation tests.

Risks:
- Existing option validation is shared; a wrong support switch can regress other commands.
- Format validation must not broaden output formats.

### st-125 | feature | high

Step: Implement transcript-first review compiler audit aggregation and renderers

Covers:
- intent-rca-002
- intent-rca-003
- intent-rca-004
- intent-rca-005

Depends:
- st-124

Locations:
- apps/seq/src/commands/mod.zig

Acceptance:
- Scanner filters by time window, repo root, and current session.
- Raw mentions create denominator candidates and exclusion records, not true sessions.
- Assistant-side cleanroom artifacts or workflow evidence create true sessions.
- Markdown and JSON render the exact required `review_compiler_audit` tree.
- Lab/delivery mutation and surface counters use transcript tool lifecycle and patch text evidence only.
- Compliance counters reflect event order for delivery mutation before contract/recipe/ablation/permit.

Validation:
- `zig build test-seq --summary all`
- `git diff --check`

Proof:
- proof-rca-002 | unit | `zig build test-seq --summary all`
- proof-rca-003 | diff | `git diff --check`

Contract:
Background:
The audit measures cleanroom Review Compiler behavior, not raw keyword frequency.

Objective:
Aggregate required counters from transcript evidence and render stable markdown/JSON output.

Implementation Approach:
Add a typed `ReviewCompilerAudit` accumulator, exclusion record list, event-order session scanner, cleanroom artifact detection, lab/delivery mutation classification, patch surface counting, and renderers. Reuse existing resolve audit helper patterns where appropriate.

Risks:
- Pasted skill/spec text can falsely look like workflow evidence if role/source filtering is too broad.
- Missing patch text can undercount surface; count mutation but keep surface delta zero.

### st-126 | verification | high

Step: Add tests docs version bump and full local proof for review-compiler-audit

Covers:
- intent-rca-006
- intent-rca-007

Depends:
- st-125

Locations:
- apps/seq/src/commands/mod.zig
- apps/seq/src/tests.zig
- apps/seq/README.md
- apps/seq/VERSION
- .step/proof

Acceptance:
- Fixture proves candidate sessions differ from true sessions and includes exclusion records.
- Fixture proves cleanroom artifact counters and lab-vs-delivery counters.
- Fixture proves missing recipe/ablation compliance counters.
- README documents command, evidence semantics, and examples.
- `apps/seq/VERSION` is bumped by one patch version from execution-time current value.
- Required proof commands pass and are captured under `.step/proof`.

Validation:
- `zig fmt apps/seq/src/lib.zig apps/seq/src/commands/mod.zig apps/seq/src/tests.zig`
- `zig build test-seq --summary all`
- `zig build build-seq --summary all`
- `cd apps/seq && zig build test --summary all`
- `bash apps/seq/scripts/release/command_surface_gate.sh ./zig-out/bin/seq`
- `git diff --check`

Proof:
- proof-rca-004 | proof-log | `.step/proof/review-compiler-audit-validation.log`

Contract:
Background:
The plan requires focused regression coverage plus the repo-appropriate seq proof suite before publication.

Objective:
Close implementation proof and docs/version readiness.

Implementation Approach:
Add fixture tests near the existing resolve audit regression, update README near the resolve audit docs, bump `apps/seq/VERSION`, run the proof suite, and capture command output in `.step/proof/review-compiler-audit-validation.log`.

Risks:
- Hosted standalone `apps/seq` CI can expose parity issues not caught by root `test-seq`; run both local lanes.

### st-127 | verification | high

Step: Ship review-compiler-audit as a proof-backed PR

Covers:
- intent-rca-008

Depends:
- st-126

Locations:
- Git branch and GitHub PR
- .step/st-plan.jsonl

Acceptance:
- All in-scope st items are complete with proof or explicitly accounted for.
- Branch is pushed.
- Ready PR is created or updated with proof summary, branch/head/base, readiness, and caveats.
- Applicable hosted checks pass or any failures are investigated and resolved before final completion.

Validation:
- `st assert-projection --file .step/st-plan.jsonl`
- `gh pr checks <pr> --watch --fail-fast`

Proof:
- proof-rca-005 | ship | PR URL and hosted check results

Contract:
Background:
The `$actuating` workflow requires proof-backed PR publication after validation.

Objective:
Publish the validated implementation without merging.

Implementation Approach:
Use explicit PR mode. Fully validated complete work defaults to a ready PR. Because this branch is stacked on `feature/seq-resolve-churn-audit`, base the PR on that branch unless PR #8 has landed before shipping.

Risks:
- If PR #8 lands during execution, rebase or retarget to `main` before shipping.
- If hosted checks fail, inspect logs and fix before marking the goal complete.
