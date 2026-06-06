<proposed_plan>
Iteration: 5

# Plan: Native `seq skill-blocks` Term Analysis

## Round Delta
- Converted the spec-pipeline handoff into an execution-ready `skills-zig` plan for `seq skill-blocks`.
- Refined the spec from summary-only to two native modes: `term-counts` for exact per-block replacement of yesterday’s `jq`, and `term-summary` as the aggregate report surface.
- Locked compatibility: legacy `skill-blocks` remains JSON/JSONL-only; table/csv output is allowed only for term-analysis modes.

## Summary
Build native vocabulary analysis for recovered skill block bodies by extending `seq skill-blocks` with `--mode term-counts|term-summary`. First wave changes option validation and CLI usage so the new modes can accept `--term-group` and table/csv formats without changing legacy output. Done means the prior jq workflow can be replaced with `seq skill-blocks --mode term-counts` for per-block counts and `--mode term-summary` for aggregate report rows, with `zig build test-seq` and smoke commands passing.

The governing boundary is: `skill-blocks` owns analysis of exact injected skill envelopes and `workflow-audit` keeps ownership of workflow signal text. Do not move this into `workflow-audit`, do not add an Ablation-specific command, and do not add a generic jq-like projection language.

## Iteration Change Log
- iteration=1; focus=baseline; round_decision=continue; delta_kind=material; evidence=spec-pipeline handoff plus source inspection; what_we_did=converted objective into implementation plan; change=locked target as `seq skill-blocks`; sections_touched=Summary,Scope,Decision Log
- iteration=2; focus=interfaces; round_decision=continue; delta_kind=material; evidence=report jq emitted per-block `block_hash` term counts; what_we_did=added `term-counts` alongside `term-summary`; change=canonical primitive is per-block rows, summary derives from same count path; sections_touched=Interfaces,Data Flow,Tests
- iteration=3; focus=operability; round_decision=continue; delta_kind=material; evidence=current `validateFormatForCommand(cmd, fmt)` rejects table before mode is visible; what_we_did=specified mode-aware validation and fail-closed option handling; change=legacy formats remain restricted; sections_touched=Edge Cases,Rollback,Implementation Brief
- iteration=4; focus=adversarial press; round_decision=continue; delta_kind=none; evidence=feasibility/operability/risk pass found no blocking errors after mode-aware validation was locked; what_we_did=verified ownership, tests, rollback; change=no material delta; sections_touched=Adversarial Findings,Convergence Evidence
- iteration=5; focus=closure; round_decision=close; delta_kind=none; evidence=press pass checked Summary,Interfaces,Requirement-to-Test Traceability,Implementation Brief; what_we_did=confirmed plan is self-contained and implementation-ready; change=no material delta; sections_touched=Contract Signals,Implementation Brief

## Non-Goals/Out of Scope
- No `ablation` or doctrine-specific top-level command.
- No generic JSON projection, query language, or `--select` support for `skill-blocks`.
- No change to `workflow-audit --mode term-summary`.
- No Homebrew tap, release tag, or installed binary publication in this implementation plan.
- No broad refactor outside the existing `seq` command implementation unless extracting the term-group parser is smaller than duplication.

## Scope Change Log
| scope_change | reason | approved_by |
|---|---|---|
| expand from `term-summary` only to `term-counts` plus `term-summary` | yesterday's jq counted terms per `block_hash`; summary-only would not replace the observed workflow | `$plan` refinement from verified session evidence |
| keep release/tap out of scope | implementation proof should land before publication work | spec-pipeline handoff |

## Interfaces/Types/APIs Impacted
- CLI usage becomes:
  `seq skill-blocks --skill <name> [--history distinct|latest] [--mode blocks|term-counts|term-summary] [--term-group <name=csv>] [--examples N] ... [--format json|jsonl|table|csv]`
- Default mode is `blocks`; legacy behavior and default format stay unchanged: JSON/JSONL only, default JSONL.
- `term-counts` output columns:
  `skill`, `block_hash`, `term_group`, `terms`, `matched`, `term_occurrence_count`, `block_occurrence_count`, `first_seen_timestamp`, `last_seen_timestamp`.
- `term-summary` output columns:
  `skill`, `term_group`, `terms`, `blocks_scanned`, `matching_blocks`, `term_occurrence_count`, and `examples`.
- `--term-group` is required for `term-counts` and `term-summary`; repeated groups are allowed.
- Term matching is case-insensitive literal substring matching, not regex.

## Data Flow
1. Parse options, including `mode`; validate mode-aware format support before command execution.
2. Resolve session inputs exactly as current `skill-blocks` does.
3. Collect and aggregate skill blocks using the existing `collectSkillBlockRows` and `aggregateSkillBlockRows` path.
4. For `blocks`, emit the existing rows unchanged.
5. For `term-counts`, scan each selected aggregate block's `block_text` once per term group, emit one row per `block_hash + term_group`, including zero-count rows.
6. For `term-summary`, aggregate the same term-count data by `skill + term_group`, emitting one row per term group with examples capped by `--examples` default `3`, maximum `10`.

## Edge Cases/Failure Modes
| case | required behavior |
|---|---|
| `--mode term-counts` without `--term-group` | fail closed with existing argument error style |
| `--mode term-summary` without `--term-group` | fail closed |
| `--history all` with term-analysis modes | reject for v1; term analysis is over aggregate block versions only |
| no matching skill blocks | `term-counts` emits no rows; `term-summary` emits one zero row per term group |
| overlapping terms in one group | count each term independently with non-overlapping literal matches per term |
| `--format table` with default `blocks` mode | still invalid |
| very large `block_text` | use current collected block rows; no new corpus-wide caching or index dependency |

## Tests/Acceptance
- Unit-level option validation tests:
  `skill-blocks --format table` without term mode still errors; `--mode term-counts --format table` is accepted.
- Fixture test for `term-counts`:
  two distinct block hashes, repeated mixed-case terms, multiple term groups, zero-count rows included.
- Fixture test for `term-summary`:
  validates `blocks_scanned`, `matching_blocks`, `term_occurrence_count`, and capped examples.
- Fail-closed tests:
  missing `--term-group`, invalid mode, and `--history all` with term modes.
- Regression tests:
  existing `skill-blocks distinct` and `history all` tests still pass unchanged.

## Requirement-to-Test Traceability
| requirement | acceptance check |
|---|---|
| R1 legacy output compatibility | existing skill-blocks tests; smoke legacy JSONL command |
| R2 per-block jq replacement | new `term-counts` fixture asserts per-`block_hash` counts |
| R3 aggregate report surface | new `term-summary` fixture asserts group-level totals |
| R4 mode-aware format support | validation tests for table/csv allowed only in term modes |
| R5 fail-closed invalid states | tests for missing groups, invalid mode, and `history all` rejection |
| R6 docs discoverability | `seq skill-blocks --help` includes modes and examples; seq skill docs mention replacement workflow |

## Rollout/Monitoring
- Rollout is local source implementation in `/Users/tk/workspace/tk/skills-zig`.
- After proof, update the `seq` skill docs in `/Users/tk/.dotfiles` only if implementation is accepted.
- Release/tap monitoring is deferred; do not claim installed `/opt/homebrew/bin/seq` has the feature until a separate release/tap plan lands it.
- Smoke the source-built binary with `zig build run-seq -- ...` before any publication work.

## Rollback/Abort Criteria
| trigger | action |
|---|---|
| existing `skill-blocks` JSON/JSONL output changes unexpectedly | abort and revert implementation |
| `zig build test-seq` fails | abort until fixed |
| table/csv becomes accepted for legacy `blocks` mode | abort; validation boundary is broken |
| term modes silently accept missing `--term-group` | abort; invalid analysis state accepted |
| implementation requires broad query engine or dataset migration | abort and return to spec-pipeline |

## Assumptions/Defaults
| assumption | provenance | confidence | verification_plan |
|---|---|---|---|
| current installed `seq` is `0.2.42` and lacks this feature as of 2026-06-06 | `seq --version`; negative option probes | high | rerun help and invalid-option probes before implementation if delayed |
| term matching should be literal, not regex | jq report used simple `scan` terms; spec non-goal avoids generic query language | medium-high | fixture with punctuation and mixed case |
| term-analysis v1 should reject `history all` | avoids ambiguous duplicate occurrence semantics | medium | explicit fail-closed test |
| examples default to `3`, max `10` | matches existing workflow-audit term-summary style | high | test `--examples` cap |

## Decision Log
| decision_id | decision | rationale |
|---|---|---|
| D1 | implement under `skill-blocks` | exact skill block body analysis belongs with recovered skill envelopes |
| D2 | add `term-counts` and `term-summary` | `term-counts` replaces the observed jq per-block table; `term-summary` supports report rollups |
| D3 | keep legacy `blocks` output JSON/JSONL-only | prevents huge block text from being dumped into accidental tables and preserves compatibility |
| D4 | use literal case-insensitive matching | enough for doctrine vocabulary reporting without adding regex/query semantics |
| D5 | defer release/tap | source proof must precede publication |

## Decision Impact Map
| decision_id | impacted_sections | follow_up_action |
|---|---|---|
| D1 | Interfaces, Data Flow, Implementation Brief | edit `cmdSkillBlocks` and docs, not workflow-audit |
| D2 | Interfaces, Tests, Requirement-to-Test Traceability | add two mode branches and fixtures |
| D3 | Edge Cases, Rollback, Tests | make format validation mode-aware |
| D4 | Edge Cases, Tests | implement literal counter helper and mixed-case tests |
| D5 | Rollout/Monitoring, Open Questions | open separate release/tap plan after proof |

## Open Questions
None. owner=n/a; due_date=n/a; default_action=proceed with locked defaults.

## Stakeholder Signoff Matrix
| product | engineering | operations | security |
|---|---|---|---|
| owner=user; status=accepted need: reduce jq in seq reports | owner=implementer; status=ready after plan | owner=release owner; status=deferred until tap plan | owner=implementer; status=no new sensitive data surfaces |

## Adversarial Findings
| lens | type | severity | section | decision | status | probability | impact | trigger |
|---|---|---|---|---|---|---|---|---|
| feasibility | risk | medium | Interfaces | D3 | mitigated by mode-aware validation plan | medium | medium | validation keeps only cmd+format and cannot see mode |
| operability | risk | low | Rollout/Monitoring | D5 | accepted; release deferred explicitly | low | medium | user expects installed `seq` feature immediately |
| risk | risk | medium | Data Flow | D4 | mitigated by literal semantics and fixtures | medium | low | overlapping terms produce surprising counts |
| feasibility | preference | low | Data Flow | D1 | accepted | low | low | helper extraction may be cleaner than local duplication |

## Convergence Evidence
clean_rounds=2
press_pass_clean=true
new_errors=0
blocking_errors=0
material_risks_open=0
press_sections_checked=Summary,Interfaces/Types/APIs Impacted,Requirement-to-Test Traceability,Implementation Brief
implementation_ready_reason=all public CLI behavior, invalid-state handling, proof commands, and rollback criteria are decision-complete

## Contract Signals
contract_version=2
strictness_profile=balanced
blocking_errors=0
material_risks_open=0
clean_rounds=2
press_pass_clean=true
new_errors=0
rewrite_ratio=0.00
external_inputs_trusted=false
improvement_exhausted=true
stop_reason=none
iteration_count=5
scope_locked=true
mutation_allowed=false

## Implementation Brief
| step | owner | success_criteria |
|---|---|---|
| 1. Make validation mode-aware | implementer | `skill-blocks --mode term-counts --format table` can pass validation, while legacy `skill-blocks --format table` still fails |
| 2. Extend `skill-blocks` CLI help and option support | implementer | help documents `blocks`, `term-counts`, `term-summary`, `--term-group`, and `--examples` |
| 3. Add term-group parsing/count helpers | implementer | repeated `name=csv` groups parse once; empty group fails closed; matching is case-insensitive literal |
| 4. Implement `term-counts` | implementer | emits one row per selected aggregate block and term group with `term_occurrence_count` and `matched` |
| 5. Implement `term-summary` | implementer | emits one row per skill and term group with scanned/matching block totals and examples |
| 6. Add regression and fail-closed tests | implementer | legacy tests pass; new term-counts, term-summary, invalid-mode, missing-group, and `history all` tests pass |
| 7. Run proof commands | implementer | `zig build test-seq` plus source-built smoke commands pass |
| 8. Update seq skill docs after proof | implementer | docs show native replacement for jq term counts and note release/tap deferral |

Iteration: 5
</proposed_plan>
