# Native seq resolve-churn-audit

Source: user request in Codex session.

## Goal

Add a native `seq resolve-churn-audit` command to the `skills-zig` repo.

## Command Contract

```bash
seq resolve-churn-audit \
  --since <time> \
  --until <time> \
  --repo <path> \
  --exclude-current \
  --format markdown|json
```

## Required Output Shape

```yaml
resolve_churn_audit:
  denominator:
    candidate_sessions:
    true_resolve_sessions:
    exclusions:
  review_horizon:
    initial_broad:
    targeted:
    final_holdout:
  finding_liability:
    introduced_by_diff:
    acceptance_required:
    preexisting_blocker:
    adjacent_preexisting:
    reviewer_preference:
    unknown:
  normal_forms:
    proposed:
    falsified:
    repeated_after_falsification:
  fuse:
    required:
    tripped:
    mutations_after_trip:
    production_net_after_trip:
  owner_pressure:
    by_owner: []
  mutation:
    apply_patch_calls:
    commits:
    production_insertions:
    production_deletions:
    production_net:
    test_insertions:
    test_deletions:
    test_net:
  permits:
    required:
    emitted:
    missing:
  negative_ledger:
    maps_or_gates:
    captures:
    route_changes:
  review:
    cas_reviews_by_head: []
    pr_sweeps:
  compliance:
    mutations_without_permit:
    normal_form_retries_after_falsification:
    mutations_after_fuse_without_distillation:
```

## Evidence Rules

- Use transcript/session evidence for workflow attribution.
- Use Git/tool lifecycle only as explicitly labeled supplemental repo evidence.
- Do not classify raw `$resolve` mentions as true sessions without assistant-side workflow/tool evidence.

## Acceptance

- CLI parser recognizes `resolve-churn-audit`.
- Command requires `--since`, `--until`, and `--repo`.
- Command accepts `--exclude-current`.
- Command accepts only `--format markdown|json`.
- Markdown output contains the required `resolve_churn_audit` YAML shape.
- JSON output contains the same top-level shape.
- Raw `$resolve` mentions increase candidate/exclusion counts but not true resolve session counts.
- Tests cover the denominator rule.
- Documentation includes command examples.
- Release-relevant `seq` version metadata is bumped.

## Validation

- `zig fmt apps/seq/src/lib.zig apps/seq/src/commands/mod.zig apps/seq/src/tests.zig`
- `zig build test-seq --summary all`
- `zig build build-seq --summary all`
- `git diff --check`
