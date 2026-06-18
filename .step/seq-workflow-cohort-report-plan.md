# Implement `seq workflow-audit --mode cohort-report`

## Summary
Implement a new `seq workflow-audit --mode cohort-report` mode in `apps/seq` to replace recurring raw `seq query` patterns used for workflow/skill forensic analysis. The mode must produce a source-backed cohort report from one workflow cohort selection pass, with Markdown as the default human output and JSON as the structured output. Also fix the advertised `seq query-diagnose --session-id` parity gap if the current source still rejects it.

## Requirements
- Add one `workflow-audit` mode: `cohort-report`.
- Do not add a new top-level `seq` command.
- Select cohort paths exactly once from rows where `isWorkflowCohortSignal` matches the requested workflow.
- Derive all report sections only from that selected path set.
- Render Markdown by default.
- Render JSON from the same in-memory report model.
- Reject table, CSV, and JSONL for this mode with a clear unsupported-format error.
- Include a "replaced raw queries" report section mapping old raw-query families to the new report.
- Update help text, README, command-surface gate coverage, tests, and `apps/seq/VERSION`.
- Ensure `seq query-diagnose --session-id <id>` works if help advertises it.
- Do not perform public release, Homebrew tap updates, or public tracker activity.

## Acceptance
- `zig build test` passes.
- `zig build -Doptimize=ReleaseFast` passes.
- `apps/seq/scripts/release/command_surface_gate.sh ./zig-out/bin/seq` passes.
- Fixture coverage proves cohort isolation: sessions with derived rows but no direct cohort signal are excluded.
- Fixture coverage proves Markdown output includes cohort summary and replaced raw-query section.
- Fixture coverage proves JSON output uses the same selected path set and counts as Markdown.
- Fixture coverage proves unsupported formats fail clearly.
- Fixture coverage proves `query-diagnose --session-id` succeeds or help no longer advertises it.
- A representative performance proof shows the implementation avoids repeated full-corpus rescans.
