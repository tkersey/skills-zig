# seq review-compiler-audit implementation plan

Source: user `$spec-pipeline` and `$plan` handoff for `seq review-compiler-audit`.

## Objective

Add a native `seq review-compiler-audit` command for `skills-zig`.

## CLI Contract

```bash
seq review-compiler-audit \
  --since <time> \
  --until <time> \
  --repo <path> \
  --exclude-current \
  --format markdown|json
```

`--since`, `--until`, and `--repo` are required. `--exclude-current` is optional. The default output format is markdown. Only markdown and JSON are valid formats.

## Required Output

```yaml
review_compiler_audit:
  denominator:
    candidate_sessions:
    true_resolve_sessions:
    exclusions: []
  cleanroom:
    delivery_freezes:
    counterexample_contracts:
    delivery_recipes:
    ablation_certificates:
    compiled_delivery_permits:
  lab_vs_delivery:
    lab_apply_patch_calls:
    lab_commits:
    delivery_apply_patch_calls:
    delivery_commits:
    lab_surface_added:
    lab_surface_discarded:
    delivery_surface_shipped:
  liability:
    branch_liabilities:
    non_branch_liabilities:
    followups_captured:
    non_branch_liabilities_mutated:
  recipe:
    falsified_routes_excluded:
    surfaces_to_retire:
    permitted_new_surface:
  ablation:
    surfaces_removed:
    surfaces_survived:
    tests_merged_or_retired:
  review_horizon:
    initial_broad_reviews:
    targeted_reviews:
    final_holdout_reviews:
    holdout_findings_added_to_scope:
    holdout_followups_captured:
  compliance:
    delivery_mutations_before_recipe:
    review_derived_delivery_patches:
    missing_contract:
    missing_recipe:
    missing_ablation:
```

## Locked Decisions

- Use transcript evidence as primary workflow attribution.
- Use tool lifecycle and Git command transcript evidence only as supplemental repo evidence.
- Do not run live Git or GitHub commands from the audit command.
- Candidate sessions may come from broad `$resolve`, cleanroom, review compiler, or artifact mentions.
- True sessions require assistant-side cleanroom workflow or artifact evidence, not raw user mentions or pasted skill/spec text.
- `denominator.exclusions` is an array of records with `session_id`, `path`, and `reason`.
- Lab vs delivery mutation classification is conservative and event-order-sensitive.
- Surface counts come from transcript patch text line counts; missing patch text counts the mutation but contributes zero surface.

## Implementation Sequence

1. Wire command surface: enum, command definitions, help, dispatcher, option support, required-argument validation, format validation, and parse/validation tests.
2. Add `ReviewCompilerAudit` accumulator and markdown/JSON renderers with the exact required tree.
3. Implement scanner over canonical traces and parsed messages, reusing `resolve-churn-audit` repo/time/current-session filtering patterns.
4. Implement event-order cleanroom state tracking for freeze, contract, recipe, ablation, compiled permit, lab context, delivery mutations, and review horizon.
5. Add focused fixture tests for true-vs-raw attribution, cleanroom artifact counters, lab-vs-delivery surface, compliance fields, and output shape.
6. Update README and bump `apps/seq/VERSION` from the execution-time current value by one patch version.
7. Run proof commands:
   - `zig fmt apps/seq/src/lib.zig apps/seq/src/commands/mod.zig apps/seq/src/tests.zig`
   - `zig build test-seq --summary all`
   - `zig build build-seq --summary all`
   - `cd apps/seq && zig build test --summary all`
   - `bash apps/seq/scripts/release/command_surface_gate.sh ./zig-out/bin/seq`
   - `git diff --check`

## Done State

Done means the command exists, emits required markdown and JSON output, preserves transcript-primary attribution, passes focused regression tests, updates docs/version, has durable `$st` proof, and is shipped as a proof-backed PR without merging.
