# st graph intake

Source: .step/seq-workflow-cohort-report-plan.md

## Intent

- intent-001 | requirement | covered
  Text: Add `seq workflow-audit --mode cohort-report` as an existing-command mode, not a new top-level command.
  Source: .step/seq-workflow-cohort-report-plan.md#requirements

- intent-002 | requirement | covered
  Text: Select workflow cohort paths exactly once from direct `isWorkflowCohortSignal` matches and derive every report section only from that path set.
  Source: .step/seq-workflow-cohort-report-plan.md#requirements

- intent-003 | requirement | covered
  Text: Render Markdown by default and JSON from the same in-memory report model.
  Source: .step/seq-workflow-cohort-report-plan.md#requirements

- intent-004 | requirement | covered
  Text: Reject table, CSV, and JSONL for `cohort-report` with a clear unsupported-format error.
  Source: .step/seq-workflow-cohort-report-plan.md#requirements

- intent-005 | requirement | covered
  Text: Include a replaced raw queries section mapping recurring old query families to new report sections.
  Source: .step/seq-workflow-cohort-report-plan.md#requirements

- intent-006 | requirement | covered
  Text: Make `seq query-diagnose --session-id <id>` work if help advertises that option.
  Source: .step/seq-workflow-cohort-report-plan.md#requirements

- intent-007 | requirement | covered
  Text: Update help, README, command-surface gate coverage, tests, and `apps/seq/VERSION`.
  Source: .step/seq-workflow-cohort-report-plan.md#requirements

- intent-008 | test-expectation | covered
  Text: Run `zig build test`, `zig build -Doptimize=ReleaseFast`, command-surface gate, representative cohort-report smoke checks, and a performance proof.
  Source: .step/seq-workflow-cohort-report-plan.md#acceptance

- intent-009 | constraint | covered
  Text: Do not perform public release, Homebrew tap updates, or public tracker activity.
  Source: .step/seq-workflow-cohort-report-plan.md#requirements

## Items

### st-128 | feature | high

Step: Wire `cohort-report` into workflow-audit CLI mode and format validation

Covers:
- intent-001
- intent-004

Depends:
- none

Locations:
- apps/seq/src/commands/mod.zig
- apps/seq/src/lib.zig

Acceptance:
- `workflow-audit --help` lists `cohort-report`.
- Mode parsing dispatches `cohort-report` through the existing `workflow-audit` command.
- Markdown is accepted by default and JSON is accepted.
- Table, CSV, and JSONL are rejected for `cohort-report` before report execution with a clear message.

Validation:
- zig build test

Proof:
- proof-128 | unit | zig build test

Contract:
Background:
The source plan requires a bespoke report mode for recurring workflow forensics without expanding the top-level command surface.

Objective:
Add only the CLI surface and validation needed to route the new mode.

Implementation Approach:
Extend existing workflow-audit mode parsing, help text, dispatch, and mode-aware format checks. Reuse existing option parsing and command ownership.

Risks:
- Accidentally adding a top-level command.
- Allowing unsupported output formats to reach report rendering.

### st-129 | feature | high

Step: Implement single-authority cohort report model and Markdown/JSON renderers

Covers:
- intent-002
- intent-003
- intent-005

Depends:
- st-128:blocks

Locations:
- apps/seq/src/commands/mod.zig

Acceptance:
- Cohort membership is derived once from direct workflow cohort signals.
- Every section is derived only from the selected path set.
- Markdown output includes summary, sessions/evidence, outcomes/tooling, simplification candidates, and replaced raw-query families.
- JSON output comes from the same report model and includes selected workflow, selected paths, section counts, evidence rows, and replaced raw-query families.

Validation:
- zig build test

Proof:
- proof-129 | unit | zig build test

Contract:
Background:
The governing invariant is that direct cohort signals own membership; derived rows must never pull unrelated sessions into the report.

Objective:
Build one in-memory report model from the existing workflow audit collection path and render it as Markdown or JSON.

Implementation Approach:
Reuse current workflow audit row collection, materialize the authoritative path set once, filter derived rows through that set, and keep renderer logic downstream of the report model.

Risks:
- Reintroducing repeated full-corpus rescans.
- Cross-session contamination from derived rows.

### st-130 | feature | medium

Step: Align `query-diagnose --session-id` behavior with advertised help

Covers:
- intent-006

Depends:
- none

Locations:
- apps/seq/src/commands/mod.zig

Acceptance:
- `seq query-diagnose --session-id <id>` resolves the session like other session-aware commands.
- Existing `--path` behavior remains unchanged.
- Help text and implementation agree.

Validation:
- zig build test

Proof:
- proof-130 | unit | zig build test

Contract:
Background:
The current help advertises `--session-id`; the implementation must honor advertised CLI behavior.

Objective:
Make the advertised session-id input route work or remove the advertisement if implementation proves impossible.

Implementation Approach:
Reuse existing session-id resolution patterns from nearby commands and keep `--path` precedence/validation compatible.

Risks:
- Duplicating session resolution logic.
- Breaking query-diagnose path-based workflows.

### st-131 | feature | high

Step: Add cohort-report and query-diagnose regression coverage

Covers:
- intent-002
- intent-003
- intent-004
- intent-005
- intent-006
- intent-008

Depends:
- st-129:blocks
- st-130:blocks

Locations:
- apps/seq/src/commands/mod.zig

Acceptance:
- Fixture coverage proves cohort isolation.
- Fixture coverage proves Markdown summary and replaced raw-query section.
- Fixture coverage proves JSON parity with Markdown-selected paths and counts.
- Fixture coverage proves unsupported formats fail clearly.
- Fixture coverage proves `query-diagnose --session-id` works.

Validation:
- zig build test

Proof:
- proof-131 | unit | zig build test

Contract:
Background:
The new mode exists to replace hand-composed raw queries; tests must prove both simplification and the cohort contamination boundary.

Objective:
Add focused tests around the new behavior and the advertised query-diagnose surface.

Implementation Approach:
Extend existing command fixture tests near current workflow-audit and query-diagnose coverage.

Risks:
- Tests that only check headers and miss contamination.
- JSON and Markdown diverging silently.

### st-132 | feature | medium

Step: Update docs, command-surface gate, and seq version metadata

Covers:
- intent-007
- intent-009

Depends:
- st-131:blocks

Locations:
- README.md
- apps/seq/scripts/release/command_surface_gate.sh
- apps/seq/VERSION

Acceptance:
- README documents `cohort-report` at the level of existing workflow-audit modes.
- Command-surface gate checks the new help surface.
- `apps/seq/VERSION` is bumped for release-relevant CLI behavior.
- No public release, tap update, or tracker side effect is performed.

Validation:
- apps/seq/scripts/release/command_surface_gate.sh ./zig-out/bin/seq

Proof:
- proof-132 | gate | apps/seq/scripts/release/command_surface_gate.sh ./zig-out/bin/seq

Contract:
Background:
Repo policy requires version bumps for shipped CLI surface changes, but publication is out of scope until explicit release intent.

Objective:
Document and gate the new surface while stopping before release publication.

Implementation Approach:
Update local docs/help references, release gate checks, and the seq version file only.

Risks:
- Forgetting the version bump.
- Accidentally initiating release/tap work.

### st-133 | feature | high

Step: Run full local proof for the cohort-report change set

Covers:
- intent-008

Depends:
- st-132:blocks

Locations:
- apps/seq
- build.zig

Acceptance:
- `zig build test` passes on the final change set.
- `zig build -Doptimize=ReleaseFast` passes on the final change set.
- Command-surface gate passes against `./zig-out/bin/seq`.
- Representative Markdown and JSON cohort-report smoke commands pass.
- Performance proof records that the report does not perform repeated full-corpus rescans.

Validation:
- zig build test
- zig build -Doptimize=ReleaseFast
- apps/seq/scripts/release/command_surface_gate.sh ./zig-out/bin/seq

Proof:
- proof-133 | full | zig build test && zig build -Doptimize=ReleaseFast && apps/seq/scripts/release/command_surface_gate.sh ./zig-out/bin/seq

Contract:
Background:
Actuation may ship only after all implementation tasks are complete and proof is current for the final head.

Objective:
Collect final local proof for the implemented plan before PR publication and landing.

Implementation Approach:
Run the planned validation suite, preserve logs under `.step/proof`, and complete the durable graph only when evidence matches the current artifact state.

Risks:
- Treating an earlier green build as current proof after more edits.
- Overclaiming performance without an implementation-level or command-level witness.
