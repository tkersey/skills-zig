# seq

`seq` is a Zig 0.16.0 CLI for mining Codex session and memory artifacts.

## Install (Homebrew)

```bash
brew tap tkersey/tap
brew install seq
```

## Build

```bash
zig build -Doptimize=ReleaseFast
```

Binary output:

```bash
./zig-out/bin/seq --help
```

## Usage

```bash
./zig-out/bin/seq datasets
./zig-out/bin/seq dataset-schema --dataset messages
./zig-out/bin/seq dataset-schema --dataset memory_blocks
./zig-out/bin/seq dataset-schema --dataset memory_stage1_outputs
./zig-out/bin/seq dataset-schema --dataset memory_extensions
./zig-out/bin/seq dataset-schema --dataset opencode_prompts
./zig-out/bin/seq dataset-schema --dataset opencode_events
./zig-out/bin/seq dataset-schema --dataset opencode_tool_calls
./zig-out/bin/seq dataset-schema --dataset opencode_sessions
./zig-out/bin/seq dataset-schema --dataset tool_invocations
./zig-out/bin/seq dataset-schema --dataset tool_call_args
./zig-out/bin/seq dataset-schema --dataset goal_runs
./zig-out/bin/seq dataset-schema --dataset workflow_signals
./zig-out/bin/seq dataset-schema --dataset skill_decision_signals
./zig-out/bin/seq dataset-schema --dataset skill_decision_episodes
./zig-out/bin/seq dataset-schema --dataset historical_decisions
./zig-out/bin/seq dataset-schema --dataset decision_capsules
./zig-out/bin/seq dataset-schema --dataset execution_policy_runs
./zig-out/bin/seq dataset-schema --dataset execution_policy_transitions
./zig-out/bin/seq role-breakdown --root ~/.codex/sessions --since 2026-03-01T00:00:00Z --format table
./zig-out/bin/seq query --spec '{"dataset":"tool_calls","group_by":["tool"],"metrics":[{"op":"count","as":"count"}],"sort":["-count"],"limit":10,"format":"json"}'
./zig-out/bin/seq query --root ~/.codex/sessions --spec '{"dataset":"tool_invocations","where":[{"field":"command_text","op":"contains","value":"learnings recall"}],"select":["path","tool_name","command_text","workdir"],"sort":["timestamp"],"limit":5,"format":"table"}'
./zig-out/bin/seq query --root ~/.codex/sessions --spec '{"dataset":"tool_call_args","where":[{"field":"tool_name","op":"eq","value":"exec_command"},{"field":"arg_path","op":"eq","value":"workdir"}],"select":["path","arg_path","value_text"],"sort":["timestamp"],"limit":5,"format":"table"}'
./zig-out/bin/seq workflow-audit --workflow fixed-point-driver --since 2026-04-01T00:00:00Z --format table
./zig-out/bin/seq workflow-audit --workflow fixed-point-driver --mode report --format markdown
./zig-out/bin/seq workflow-audit --workflow fixed-point-driver --mode cohort-report --last 7d --format markdown
./zig-out/bin/seq workflow-audit --workflow fixed-point-driver --mode term-summary --term-group additive=add,added,patch --term-group reductive=delete,remove,refactor --since 2026-05-02T00:00:00-07:00 --format table
./zig-out/bin/seq workflow-audit --workflow review-compiler --mode provenance --since 2026-05-01T00:00:00Z --until 2026-06-01T00:00:00Z --format table
./zig-out/bin/seq skill-blocks --skill fixed-point-driver --mode term-summary --term-group ablation=ablative,ablation --term-group isomorphism=isomorphic,isomorphism --since 2026-05-02T00:00:00-07:00 --format table
./zig-out/bin/seq workflow-overlap --workflow fixed-point-driver,review-adjudication --since 2026-05-02T00:00:00-07:00 --format table
./zig-out/bin/seq find-session --root ~/.codex/sessions --prompt "learnings recall" --since 2026-03-08T00:00:00Z --until 2026-03-10T23:59:59Z --limit 5 --format table
./zig-out/bin/seq plan-search --root ~/.codex/sessions --repo /Users/tk/workspace/tk/shift --since 2026-03-01T00:00:00Z --format table
./zig-out/bin/seq plan-search --root ~/.codex/sessions --repo /Users/tk/workspace/tk/shift --contains "PromptMode" --stats --format jsonl
./zig-out/bin/seq plan-search --root ~/.codex/sessions --session-id 019ce80b-9fb4-72a1-9c1e-3d626d4e4913 --include-body --format jsonl
./zig-out/bin/seq reply-latency --root ~/.codex/sessions --limit 10 --format table
./zig-out/bin/seq reply-latency --root ~/.codex/sessions --mode contiguous --since 2026-03-01T00:00:00Z --until 2026-03-05T00:00:00Z --format json
./zig-out/bin/seq session-tooling --root ~/.codex/sessions --since 2026-03-08T00:00:00Z --until 2026-03-10T23:59:59Z --summary --group-by executable --format table
./zig-out/bin/seq query-diagnose --path /absolute/path/to/rollout.jsonl --threshold-ms 10000 --next-actions --format json
./zig-out/bin/seq artifact-search --contains "spawn_agent" --kind orchestration --since 2026-03-01T00:00:00Z --limit 10 --format table
./zig-out/bin/seq artifact-search --contains-any "fixed-point-driver,review-adjudication" --surface messages --since 2026-05-02T00:00:00-07:00 --format jsonl
./zig-out/bin/seq artifact-search --contains "MEMORY.md" --kind memory --stats --format table
./zig-out/bin/seq skill-success-rank --root ~/.codex/sessions --last 14d --format table
./zig-out/bin/seq skill-success-rank --root ~/.codex/sessions --skill seq --mode sessions --last 14d --format jsonl
./zig-out/bin/seq skill-evidence --root ~/.codex/sessions --session-id <session_id> --skill seq --format json
./zig-out/bin/seq skill-decision-audit --root ~/.codex/sessions --skill team-patterns --last 30d --mode tune-packet --format json
./zig-out/bin/seq skill-decision-audit --root ~/.codex/sessions --skill team-patterns --session-id <session_id> --mode episodes --format table
./zig-out/bin/seq skill-decision-audit --root ~/.codex/sessions --skill team-patterns --session-id <session_id> --since-cursor '<cursor-json-or-token>' --mode delta --format json
./zig-out/bin/seq skill-contract validate --file codex/skills/team-patterns/references/decision-contract.yaml --format json
./zig-out/bin/seq skill-decision-receipt validate --file receipt.json --format json
./zig-out/bin/seq skill-audit --skill seq --mode trend --since 2026-04-01T00:00:00Z --format table
./zig-out/bin/seq skill-audit --skill universalist --mode activation --last 36h --exclude-current --format table
./zig-out/bin/seq tool-audit --group-by executable --since 2026-04-01T00:00:00Z --limit 20 --format table
./zig-out/bin/seq memory-inventory --mode categories --memory-root ~/.codex/memories --format table
./zig-out/bin/seq message-search --contains "release workflow" --roles user,assistant --exclude-current --limit 20 --format table
./zig-out/bin/seq message-audit --contains-any "jq,seq query" --roles user,assistant --exclude-current --limit 20 --format table
./zig-out/bin/seq skill-cohort --skill seq --since 2026-04-01T00:00:00Z --exclude-current --format table
./zig-out/bin/seq tool-search --contains "seq query" --group-by executable --mode summary --exclude-current --format table
./zig-out/bin/seq tool-search --session-id 019e5634-b21e-74f2-bc0a-9b0b0d9e37e3 --contains-any "jq,shasum,brew test" --mode rows --format table
./zig-out/bin/seq memory-extension-audit --extensions-root ~/.codex/memories/extensions --format table
./zig-out/bin/seq token-window --window-hours 24 --since 2026-04-01T00:00:00Z --exclude-current --format table
./zig-out/bin/seq goal-audit --root ~/.codex/sessions --workflow review,resolve --duration-gte 2h --summary --format table
./zig-out/bin/seq adjudication-audit --mode summary --include-root-equivalent resolve,fixed-point-driver --since 2026-05-02T00:00:00-07:00 --format table
./zig-out/bin/seq resolve-churn-audit --since 2026-05-01T00:00:00-07:00 --until 2026-06-01T00:00:00-07:00 --repo /Users/tk/workspace/tk/skills-zig --exclude-current --format markdown
./zig-out/bin/seq review-compiler-audit --protocol auto --since 2026-05-01T00:00:00-07:00 --until 2026-06-01T00:00:00-07:00 --repo /Users/tk/workspace/tk/skills-zig --exclude-current --format markdown
./zig-out/bin/seq workdir-report --workdir /Users/tk/workspace/tk/skills-zig --mode sessions --format table
./zig-out/bin/seq memory-provenance --thread-id 019bae5d-7d12-7b01-9cb5-b8bb6046b85b --format table
./zig-out/bin/seq memory-provenance --rollout-summary-file rollout_summaries/2026-01-11T18-42-01-jpEf-resolve_merge_pr_11_squash_cleanup.md --format json
./zig-out/bin/seq memory-map --thread-id 019bae5d-7d12-7b01-9cb5-b8bb6046b85b --format table
./zig-out/bin/seq memory-map --contains synesthesia --limit 5 --format table
./zig-out/bin/seq memory-history --thread-id 019bae5d-7d12-7b01-9cb5-b8bb6046b85b --format table
./zig-out/bin/seq memory-history --contains synesthesia --since 2026-04-01T00:00:00Z --limit 5 --format table
./zig-out/bin/seq opencode-prompts --limit 20 --format jsonl
./zig-out/bin/seq opencode-prompts --session ses_abc --since 1772700000000 --latest --format table
./zig-out/bin/seq opencode-prompts --source db --contains "grill me" --mode normal --select session_slug,message_id,prompt_text,part_types --sort -time_created_epoch_ms --format table
./zig-out/bin/seq opencode-events --source db --role assistant --tool shell --status completed --select session_slug,message_id,event_index,part_type,tool_name,tool_status,text --sort -time_created_epoch_ms --limit 50 --format table
./zig-out/bin/seq opencode-events --session ses_abc --since 2026-03-01T00:00:00Z --until 2026-03-05T00:00:00Z --latest --format jsonl
./zig-out/bin/seq query --spec '{"dataset":"opencode_tool_calls","params":{"source":"db"},"select":["session_id","tool_name","tool_status","tool_duration_ms"],"sort":["-time_created_epoch_ms"],"limit":10,"format":"table"}'
./zig-out/bin/seq query --spec '{"dataset":"opencode_sessions","params":{"source":"db"},"select":["session_id","event_count","tool_event_count","reasoning_event_count","duration_ms"],"sort":["-last_event_epoch_ms"],"limit":10,"format":"table"}'
./zig-out/bin/seq query --spec '{"dataset":"opencode_prompts","params":{"source":"db","opencode_db_path":"~/.local/share/opencode/opencode.db"},"where":[{"field":"part_types","op":"contains","value":"file"}],"select":["session_slug","prompt_text","part_types"],"sort":["-time_created_epoch_ms"],"format":"jsonl"}'
./zig-out/bin/seq routing-gap --cue-spec @cue-spec.json --discovery-skills grill-me,prove-it,complexity-mitigator,invariant-ace,tk
./zig-out/bin/seq orchestration-concurrency --session-id 019ca0e5-0beb-7740-a9bc-81664d994266 --format table
./zig-out/bin/seq orchestration-concurrency --path /absolute/path/to/rollout.jsonl --floor-threshold 3 --fail-on-floor --format json
./zig-out/bin/seq orchestration-concurrency --path /absolute/path/to/rollout.jsonl --fail-on-mesh-truth --format table
```

`query.where.op` supports `contains_any` and `regex_any` in addition to `contains` and `regex`.
`regex` uses a fast regex-like subset (`^`, `$`, `|`) and fails fast on unsupported constructs.
`query.joins` supports session-local enrichment without shell/Python post-processing. Each join entry names a `dataset`, `left` field, `right` field, optional `type` (`inner` or `left`), optional `prefix`, optional `where`, and optional `params`.

Example join:
```bash
seq query --root ~/.codex/sessions --spec '{"dataset":"messages","joins":[{"dataset":"sessions","left":"path","right":"path","type":"left","prefix":"session"}],"where":[{"field":"text","op":"contains","value":"fixed-point-driver"}],"select":["timestamp","role","session.cwd","text"],"limit":20,"format":"table"}'
```

`workflow-audit` is the high-level surface for workflow utilization reports:
- selects sessions by exact `$workflow` / skill mention after stripping injected skill blocks
- preserves signal source breakdown (`user_prompt`, `assistant_text`, `tool_trace`, `session_graph`)
- emits `summary`, `signals`, `outcomes`, `sessions`, `report`, `term-summary`, or `cohort-report` modes
- `term-summary` accepts repeated `--term-group <name=csv>` flags, `--examples N`, and `--unique-by snippet|path-snippet` for native phrase-bucket rollups without shell `jq`
- `cohort-report` emits a Markdown-by-default or JSON workflow cohort packet with one direct cohort path selection, summary/outcome/session/evidence sections, and a replaced raw-query map for common `seq query` rollups
- `provenance` emits controller-grade and non-controller evidence classes for one workflow; `artifact_under_repair` and `filename_or_path_mention` are never controller invocation evidence by themselves
- supports `--since`, `--until`, `--workdir`, `--limit`, and `--format table|json|csv|jsonl|markdown`

Examples:
```bash
seq workflow-audit --root ~/.codex/sessions --workflow fixed-point-driver --mode summary --since 2026-04-01T00:00:00Z --format table
seq workflow-audit --root ~/.codex/sessions --workflow fixed-point-driver --mode report --since 2026-04-01T00:00:00Z --format markdown
seq workflow-audit --root ~/.codex/sessions --workflow fixed-point-driver --mode cohort-report --last 7d --format markdown
seq workflow-audit --root ~/.codex/sessions --workflow fixed-point-driver --mode cohort-report --last 7d --format json
seq workflow-audit --root ~/.codex/sessions --workflow fixed-point-driver --mode term-summary --term-group additive=add,added,patch --term-group reductive=delete,remove,refactor --format table
seq workflow-audit --root ~/.codex/sessions --workflow review-compiler --mode provenance --since 2026-05-01T00:00:00Z --until 2026-06-01T00:00:00Z --format json
seq workflow-overlap --root ~/.codex/sessions --workflow fixed-point-driver,review-adjudication --mode summary --since 2026-05-02T00:00:00-07:00 --format table
seq workflow-overlap --root ~/.codex/sessions --workflow fixed-point-driver,review-adjudication --mode sessions --limit 20 --format jsonl
```

`resolve-churn-audit` emits the native `$resolve` churn ledger requested by the Review Governor loop:
- requires `--since`, `--until`, and `--repo`
- supports `--exclude-current` to avoid counting the active audit session
- emits `markdown` by default or `json` with `--format json`
- uses transcript/session evidence for workflow attribution and Git/tool lifecycle only as supplemental repo evidence
- treats raw `$resolve` mentions as denominator candidates only; true resolve sessions require assistant-side workflow or review/tool evidence

Examples:
```bash
seq resolve-churn-audit --root ~/.codex/sessions --since 2026-05-01T00:00:00-07:00 --until 2026-06-01T00:00:00-07:00 --repo /Users/tk/workspace/tk/skills-zig --exclude-current --format markdown
seq resolve-churn-audit --root ~/.codex/sessions --since 2026-05-01T00:00:00Z --until 2026-06-01T00:00:00Z --repo /Users/tk/workspace/tk/skills-zig --format json
```

`review-compiler-audit` emits separate `$resolve` Review Compiler ledgers for MBK, C3/MRPC, and legacy-cleanroom protocols:
- requires `--since`, `--until`, and `--repo`
- supports `--protocol auto|legacy-cleanroom|c3|c3-mrpc|mbk` (default `auto`)
- supports `--exclude-current` to avoid counting the active audit session
- emits `markdown` by default or `json` with `--format json`
- uses transcript/session evidence as primary workflow attribution and Git/tool lifecycle only as supplemental repo evidence
- treats raw `$resolve` mentions as candidate sessions only; MBK activation requires MBKC evidence such as `MBKC-v1`, `minimum_behavioral_kernel`, `review-compiler campaign begin`, `kernel-accepted`, or `terminal-closed`
- keeps historical `legacy-cleanroom` and C3/MRPC counts separate; `c3-mrpc` is an explicit alias for the existing MRPC-era `c3` behavior
- reports C3/MRPC `closure_compression` state for closed runs, including `CLOSED_UNCOMPRESSED` when material closed sessions lack basis, tournament, ablation, proof, holdout, permit, or bypass-free MRPC evidence
- emits C3/MRPC `denominator.included_sessions` rows so each true C3 session carries its `session_id`, path, protocol, classification, `c3_required` / `c3_entered` / `c3_closed` booleans, and evidence refs for the native count and closure-compression decisions
- `--emit-count-evidence` emits the per-count evidence table directly; it is equivalent to `--mode evidence`
- marks absence-derived evidence explicitly with `source: "absent"` and deterministic reasons such as `no_c3_begin_signal`; aggregate `closure_compression` remains the cohort summary
- reports MBK semantic-surface metrics separately from base-relative Git tree metrics
- in `--mode summary --format json` and `--mode runs --format jsonl`, emits flat authority-transfer fields for candidate/material sessions, tuple and terminal closure, RAC/mutation/closure gates, semantic-surface delta, orphan/unmapped/wound counters, and the `no mechanically closed material resolve run found` falsifier when no material run satisfies the mechanical closure predicate

Examples:
```bash
seq review-compiler-audit --root ~/.codex/sessions --protocol auto --since 2026-05-01T00:00:00-07:00 --until 2026-06-01T00:00:00-07:00 --repo /Users/tk/workspace/tk/skills-zig --exclude-current --format markdown
seq review-compiler-audit --root ~/.codex/sessions --protocol c3 --since 2026-05-01T00:00:00Z --until 2026-06-01T00:00:00Z --repo /Users/tk/workspace/tk/skills-zig --format json
seq review-compiler-audit --root ~/.codex/sessions --protocol c3 --since 2026-05-01T00:00:00Z --until 2026-06-01T00:00:00Z --repo /Users/tk/workspace/tk/skills-zig --emit-count-evidence --format table
seq review-compiler-audit --root ~/.codex/sessions --protocol c3-mrpc --since 2026-05-01T00:00:00Z --until 2026-06-01T00:00:00Z --repo /Users/tk/workspace/tk/skills-zig --format json
seq review-compiler-audit --root ~/.codex/sessions --protocol mbk --since 2026-05-01T00:00:00Z --until 2026-06-01T00:00:00Z --repo /Users/tk/workspace/tk/skills-zig --format json
seq review-compiler-audit --root ~/.codex/sessions --protocol legacy-cleanroom --since 2026-05-01T00:00:00Z --until 2026-06-01T00:00:00Z --repo /Users/tk/workspace/tk/skills-zig --format json
```

`cas-review-audit` projects CAS review-session receipts and shell outputs into a review-transport projection:
- accepts bounded session selectors (`--session-id`, `--path`, `--repo`, `--workdir`, `--since`, `--until`, `--last`) plus persisted receipts via `--receipt-path` or `--receipt-glob`
- emits one projection row per receipt-like JSON surface with review attempt phase, attempt/tuple verdict booleans, tuple identity, backend class, failure class, normalized verdict status, and non-authoritative review transport fields such as `surface`
- classifies legacy `lane_transport_lost` receipts with no review thread and no review count as `pre_review_lane_transport_lost`
- reports derived counts for pre-review lane deaths, review-attempt transport failures, clean/findings verdicts, account exhaustion, timeouts with handles, duplicate prevention, and start-wait normalization
- summarizes persistent-lane backend readiness as `available`, `unavailable`, `failing_pre_review`, or `degraded`

Examples:
```bash
seq cas-review-audit --root ~/.codex/sessions --path rollout.jsonl --mode rows --format jsonl
seq cas-review-audit --receipt-path start-wait.json --base-sha <base> --head-sha <head> --target-fingerprint <fp> --mode summary --format json
seq cas-review-audit --root ~/.codex/sessions --repo /path/to/repo --last 7d --mode report --format markdown
```

`skill-blocks` is the exact-body surface for injected `<skill>...</skill>` content:
- defaults to `--mode blocks --history distinct --format jsonl`, preserving the existing exact block export contract
- `--mode body` emits exactly one selected `block_text` directly, replacing shell `jq -r '.[0].block_text'`; narrow with `--history latest`, `--session-id`, `--path`, or time filters if more than one distinct body matches
- `--mode term-counts` emits one row per selected distinct/latest `block_hash + term_group`, including zero-count rows
- `--mode term-summary` aggregates the same term-count data by `skill + term_group` and caps examples with `--examples N` (default 3, max 10)
- term modes require repeated `--term-group <name=csv>` flags, count case-insensitive literal terms inside `block_text`, and reject `--history all` for v1
- term modes support `--format table|json|csv|jsonl`; legacy `blocks` mode remains `json|jsonl`; `body` mode writes raw text and does not accept `--format`

Examples:
```bash
seq skill-blocks --root ~/.codex/sessions --skill review-adjudication --last 30d --until 2026-06-19T18:54:00Z --history latest --mode body --output ~/Downloads/review-adjudication.md
seq skill-blocks --root ~/.codex/sessions --skill fixed-point-driver --mode term-counts --term-group ablation=ablative,ablation --format table
seq skill-blocks --root ~/.codex/sessions --skill fixed-point-driver --mode term-summary --term-group ablation=ablative,ablation --term-group isomorphism=isomorphic,isomorphism --examples 5 --format table
```

`skill-evidence` summarizes skill-use evidence for one watched session:
- requires `--skill <name>` plus `--session-id <id>` or `--path <jsonl>`
- distinguishes injected skill blocks, assistant-declared use, manual `SKILL.md` reads, target-skill lens use, successful outcome evidence, and raw mentions
- emits a cursor in JSON and base64url token forms; pass `--since-cursor <cursor>` for delta mode
- defaults to sanitized examples only; pass `--include-raw` when raw snippets are explicitly needed
- supports `--last`, `--since`, and `--until`; output is JSON-only

Examples:
```bash
seq skill-evidence --root ~/.codex/sessions --session-id <session_id> --skill seq --format json
seq skill-evidence --root ~/.codex/sessions --session-id <session_id> --skill seq --since-cursor '<cursor-token>' --format json
```

`skill-decision-audit` compiles conservative decision episodes for one skill:
- requires `--skill <name>` plus a bounded scope such as `--session-id`, `--path`, `--last`, `--since`, `--until`, `--repo`, or `--workdir`
- treats SDR-v1 receipts as the strongest deterministic decision attribution
- emits STE-v1 with `--mode tune-packet` for `$tune`, and SDD-v1 with `--mode delta` for watched-session deltas
- supports SKDC-v1 contracts through `--contract <file>` or `--skill-root <path>` discovery under `<skill>/references/decision-contract.yaml`
- keeps raw transcript text out of output by default; `--include-excerpts` is explicit and prints a privacy warning
- associates downstream outcomes without claiming the skill caused the outcome
- leaves matched-cohort analysis disabled in capabilities as P2/deferred

Companion commands:
- `skill-contract validate --file <decision-contract.yaml>` validates SKDC-v1 and emits the stable contract fingerprint
- `skill-contract scaffold --skill <name> --kind decision --output <file>` writes a placeholder contract only; it does not infer semantics
- `skill-decision-receipt validate --file <receipt.json>` validates SDR-v1 receipts
- `decision-capsule` freezes one visible historical decision as DCP-v2 for controlled replay
- `capabilities --format json` reports `skill_decision_audit`, `skill_decision_delta`, `skill_contract_v1`, `skill_decision_receipt_v1`, `tune_packet_v1`, `decision_capsule_v1`, `decision_anchor_v1`, `historical_decisions_dataset_v1`, and `dcp_validation_v1`

Examples:
```bash
seq skill-decision-audit --root ~/.codex/sessions --skill team-patterns --last 30d --mode tune-packet --format json
seq skill-decision-audit --root ~/.codex/sessions --skill team-patterns --session-id <session_id> --mode episodes --format table
seq skill-decision-audit --root ~/.codex/sessions --skill team-patterns --session-id <session_id> --since-cursor '<cursor-json-or-token>' --mode delta --format json
seq skill-contract validate --file codex/skills/team-patterns/references/decision-contract.yaml --format json
seq decision-capsule --root ~/.codex/sessions --session-id <session_id> --turn-index 4 --format json
seq decision-capsule --path rollout.jsonl --mode candidates --format table
seq decision-capsule --mode validate --file capsule.json --format json
```

Decision-audit query datasets:
```bash
seq query --root ~/.codex/sessions --spec '{"dataset":"skill_decision_episodes","where":[{"field":"skill","op":"eq","value":"team-patterns"}],"group_by":["decision_effect"],"metrics":[{"op":"count","as":"episodes"}],"sort":["-episodes"],"format":"table"}'
seq query --root ~/.codex/sessions --spec '{"dataset":"skill_decision_outcomes","where":[{"field":"causal_claim_allowed","op":"eq","value":false}],"select":["episode_id","outcome_kind","association_method"],"limit":20,"format":"table"}'
seq query --root ~/.codex/sessions --spec '{"dataset":"historical_decisions","params":{"path":"rollout.jsonl"},"select":["decision_id","turn_index","selected_route","confidence"],"format":"table"}'
```

`actuation-audit` compiles SEQ-ACTRUN-v1 ledgers for `$actuating` plan-to-PR runs:
- requires a bounded selector: `--session-id`, `--path`, or `--repo`/`--workdir` with `--since`, `--until`, or `--last`
- classifies true runs separately from pasted skill blocks, examples, reports, and incidental mentions
- recovers GCR attempts, material mutations without current executable GCR, projection inversion, proof cadence, compaction resume signals, worker linkage, churn, and ship flags from canonical trace evidence
- keeps raw prompts/excerpts out by default; `--include-excerpts` is explicit
- `--strict` exits 2 for graph bypass or projection inversion rows

Examples:
```bash
seq actuation-audit --root ~/.codex/sessions --path rollout.jsonl --mode summary --format json
seq actuation-audit --root ~/.codex/sessions --repo /path/to/repo --last 7d --mode report --format markdown
seq query --root ~/.codex/sessions --spec '{"dataset":"actuation_runs","params":{"path":"rollout.jsonl"},"select":["session_id","verdict","graph.compile_failures","projection.update_plan_calls","surface.churn.apply_patch_calls"],"format":"table"}'
```

Actuation query datasets:
- `actuation_runs`
- `actuation_slices`
- `actuation_graph_events`
- `actuation_proofs`
- `actuation_compactions`
- `actuation_workers`

`execution-policy-audit` compiles EPRUN-v1 ledgers for closed-loop EPG/EPS/EPD/ETR policy runtime evidence:
- requires a bounded selector: `--session-id`, `--path`, `--repo`, `--since`, `--until`, or `--last`
- separates authoritative policy runtime, structured manual runtime, declared unstructured, candidate-only, and contamination-only sessions
- projects source/regime currentness, GCR materialization, horizon, shield, potential, proof, calibration, unknown latency, recurrence, regret candidates, and retrace decision IDs from canonical trace evidence
- preserves outcome discipline: selection, materialization, action result, transition, policy terminal, and delivery success are exposed separately
- `--strict` exits 2 for current-protocol hard failures such as mutation without lineage, shield bypass, horizon mismatch, invalid transition, stale source execution, or success terminal without proof

Examples:
```bash
seq execution-policy-audit --root ~/.codex/sessions --path rollout.jsonl --mode report --format markdown
seq execution-policy-audit --root ~/.codex/sessions --repo /path/to/repo --last 7d --mode calibration --format table
seq query --root ~/.codex/sessions --spec '{"dataset":"execution_policy_transitions","params":{"path":"rollout.jsonl"},"select":["session_id","transition_id","matches","misses","unexpected"],"format":"table"}'
```

Execution-policy query datasets:
- `execution_policy_runs`
- `execution_policies`
- `execution_policy_states`
- `execution_policy_decisions`
- `execution_policy_transitions`
- `execution_policy_unknowns`
- `execution_policy_actions`
- `execution_policy_regret_candidates`

`st-workspace-audit` compiles STWA-v1 ledgers for `.ledger/st/` multi-plan workspace artifacts:
- reads controller/workspace/plan artifacts under `--workspace-root` as primary evidence
- reconstructs workspace and plan lifecycles, held claims, fencing tokens, session projections, aperture allocations, GCR-v2 receipts, graph-intelligence GCR-v2 rows, GRR-v1 graph repair receipts, AMR-v1 artifact maintenance receipts, change sets, integrations, proof invalidations, and normalized controller decisions
- synthesizes resource-conflict findings from overlapping held claims; different `plan_id` values do not make resources nonconflicting
- scans session JSONL under `--root` only for actual `.step/` or `.retrace/` write attempts; migration reads and filename mentions are not counted as legacy writes
- `--strict` exits 2 when P0/P1 findings or artifact inconsistency are present

Examples:
```bash
seq st-workspace-audit --workspace-root /path/to/repo/.ledger/st --mode summary --format table
seq st-workspace-audit --root ~/.codex/sessions --repo /path/to/repo --workspace-root /path/to/repo/.ledger/st --mode report --format markdown
seq st-workspace-audit --workspace-root /path/to/repo/.ledger/st --mode graph-control --format json
seq st-workspace-audit --workspace-root /path/to/repo/.ledger/st --mode workflow-provenance --format json
seq query --root ~/.codex/sessions --spec '{"dataset":"st_gcr_v2","params":{"workspace_root":"/path/to/repo/.ledger/st"},"select":["gcr_id","workspace_id","plan_id","execution_allowed","current_at_mutation"],"format":"table"}'
seq query --root ~/.codex/sessions --spec '{"dataset":"st_artifact_maintenance_receipts","params":{"workspace_root":"/path/to/repo/.ledger/st"},"select":["maintenance_id","artifact_paths","activation_signal","controller_invocation"],"format":"table"}'
seq query --root ~/.codex/sessions --spec '{"dataset":"historical_decisions","params":{"workspace_root":"/path/to/repo/.ledger/st"},"select":["decision_id","source_kind","selected_route"],"format":"table"}'
```

ST workspace query datasets:
- `st_workspaces`
- `st_plans`
- `st_cross_plan_edges`
- `st_claims`
- `st_resource_conflicts`
- `st_session_views`
- `st_workspace_apertures`
- `st_gcr_v2`
- `st_graph_control_receipts`
- `st_graph_repair_receipts`
- `st_artifact_maintenance_receipts`
- `workflow_provenance_evidence`
- `st_changesets`
- `st_integrations`
- `st_proof_invalidations`
- `st_legacy_artifacts`
- `st_findings`
- `st_decisions`

## Trace-native session surfaces

`seq` can parse Codex rollout JSONL into canonical sessions, turns, tool lifecycle rows, and worker graph edges. These commands preserve the existing local-first flow: they read local `rollout-*.jsonl` files under `~/.codex/sessions` or an explicit `--path`.

Trace inventory:
```bash
seq sessions --root ~/.codex/sessions --limit 10 --format table
seq sessions --root ~/.codex/sessions --format table
seq sessions --root ~/.codex/sessions --ongoing --format jsonl
seq sessions --root ~/.codex/sessions --repo /path/to/repo --since 2026-04-01T00:00:00Z --format table
```

Unfiltered latest-session queries use the same newest-rollout fast path when
sorted by descending `start_time` with a `limit`, so `seq query` can replace
shell/JQ scans for recent session inventory:
```bash
seq query --root ~/.codex/sessions --spec '{"dataset":"sessions","select":["start_time","session_id","cwd","thread_name"],"sort":["-start_time"],"limit":10,"format":"table"}'
```

Canonical turns:
```bash
seq turns --path /absolute/rollout.jsonl --format table
seq turns --session-id <id> --root ~/.codex/sessions --status error --format jsonl
```

Full per-session proof:
```bash
seq session-detail --path /absolute/rollout.jsonl --format json
seq session-detail --session-id <id> --root ~/.codex/sessions --format markdown
```

Tool lifecycle completeness:
```bash
seq tool-lifecycle --path /absolute/rollout.jsonl --format table
seq tool-lifecycle --session-id <id> --root ~/.codex/sessions --include-raw --format json
```

Worker/session graph:
```bash
seq session-graph --session-id <id> --root ~/.codex/sessions --format table
seq session-graph --session-id <id> --root ~/.codex/sessions --format dot
```

Live or one-shot tailing:
```bash
seq tail --current --root ~/.codex/sessions --format table
seq tail --path /absolute/rollout.jsonl --events raw,turns,tools --once --format jsonl
```

Trace datasets are available through `seq query`:
- `sessions`
- `turns`
- `tool_lifecycle`
- `session_graph_edges`

Examples:
```bash
seq query --root ~/.codex/sessions --spec '{"dataset":"sessions","select":["start_time","session_id","thread_name","turn_count","total_tokens"],"sort":["-start_time"],"limit":10,"format":"table"}'
seq query --root ~/.codex/sessions --spec '{"dataset":"turns","where":[{"field":"status","op":"eq","value":"error"}],"select":["started_at","session_id","turn_index","error","path"],"sort":["-started_at"],"limit":20,"format":"table"}'
seq query --root ~/.codex/sessions --spec '{"dataset":"tool_lifecycle","where":[{"field":"lifecycle_status","op":"eq","value":"unresolved"}],"select":["path","turn_index","tool_name","call_id"],"limit":20,"format":"jsonl"}'
seq query --root ~/.codex/sessions --spec '{"dataset":"session_graph_edges","select":["parent_session_id","worker_session_id","agent_role","worker_path"],"format":"table"}'
```

`plan-search` is the strict finalized-plan surface:
- searches assistant messages for complete `<proposed_plan> ... </proposed_plan>` blocks only
- matches by repo (`--repo`), session (`--session-id` / `--path`), time (`--since` / `--until`), and title/body text (`--contains` / `--regex`)
- defaults to newest-first metadata rows and exposes the exact plan block only with `--include-body`
- `--stats` adds scan counters (`candidate_files`, `files_opened`, `messages_examined`, `plan_blocks_found`, `rows_emitted`, `duration_ms`) plus filter-usage flags

`reply-latency` computes reply waits from ordered user/assistant message sequences:
- default mode is `single-message`, which measures one user message to the next assistant reply
- `--mode contiguous` measures a contiguous block of user messages to the next assistant reply
- emits `turn_index`, timestamps, numeric/human duration, per-turn user message counts, and compact previews

`artifact-search` is the seq-first forensic entrypoint:
- searches `messages`, `tool_calls`, and `memory_blocks` with one normalized result shape
- accepts `--contains`, `--contains-any <csv>`, or `--regex` as the native text match owner
- accepts `--kind auto|session|memory|orchestration|tooling|prompt`
- accepts `--surface auto|messages|tool_calls|memory_blocks` when you need to pin the substrate
- emits `next_action_kind` / `next_action` suggestions for follow-up commands
- `--stats` adds scan counters (`surfaces_scanned`, `candidate_files`, `files_opened`, `rows_examined`, `rows_emitted`, `duration_ms`)

Query-lift commands provide top-level shortcuts for common `seq query` shapes:
- `skill-success-rank` ranks user-called skills by sessions with positive outcome evidence, avoiding raw mention-count inflation and full `workflow_signals` scans.
- `skill-evidence` is the session-scoped watched-run surface for "what changed since cursor X?" skill-use evidence; use it before broad corpus ranking when the question is about one session.
- `skill-audit` summarizes `skill_mentions` by skill, emits mention rows, produces a daily trend for one skill, or classifies activation evidence with `--mode activation`.
- `skill-audit --mode activation --skill <name> --last <window> --exclude-current` is the optimized path for "was `$skill` called explicitly or implicitly?" It emits explicit user calls, implicit assistant calls, injected skill blocks, and other references separately, so pasted skill bodies are not counted as activation.
- `workflow-audit` summarizes workflow cohorts across session text, skill mentions, tool traces, session graph roles, and outcome signals; use `--exclude-current` when auditing an active run.
- `tool-audit` summarizes `tool_invocations` by tool, executable, session, workdir, or command, with row and unresolved modes for drilling down.
- `memory-inventory` summarizes file-backed memory categories and can switch to file, block, stage1, or extension inventory modes.
- `message-search` searches session message text with `--contains`, `--regex`, `--contains-any`, or `--contains-all`.
- `message-audit` summarizes message hits by role, emits matching rows, or groups matching sessions; use `--exclude-current` when mining an active Codex run and `--show-query` to print the generated `query` spec.
- `skill-cohort` reports skills seen in the same session cohort as `--skill <name>`, or can fall back to summary/mention modes over `skill_mentions`.
- `tool-search` searches lifecycle-enriched tool invocations and flattened tool arguments without shell `jq` post-processing. Use `--session-id` or `--path` for a single rollout and `--contains-any` when auditing several shell fragments at once.
- `memory-extension-audit` inventories live memory extensions and labels results as `inventory_only` with `causality_claimed=false` so read/config evidence is not overclaimed.
- `token-window` computes the max rolling token window from timestamp-sorted `token_deltas` rows and can emit the contributing rows.
- `goal-audit` summarizes `/goal` runs from `get_goal` / `update_goal` / `create_goal` outputs, with workflow filters for `review` and `resolve` and duration thresholds like `--duration-gte 2h`.
- `workdir-report` summarizes canonical session rows by `cwd` and can list matching sessions.

Generic `seq query` remains the right tool for novel joins, custom denominators,
or one-off dataset projections that are not covered by a lifted command. Use a
lifted command when it matches the question; do not avoid raw `query` when it is
the simpler and more exact expression.

`memory-provenance` answers the targeted origin question for one memory thread or rollout summary:
- accepts `--thread-id` or `--rollout-summary-file`
- joins live `stage1_outputs` truth from the Codex state DB with current memory artifacts
- emits `current_surfaces`, `active_extensions`, `evidence_ref`, and an exact `session-prompts` follow-up command

`memory-map` is the archaeology-first artifact router:
- targeted mode (`--thread-id`) maps the live stage1 row, rollout summary artifact, and current memory-block surfaces for one memory thread
- topic mode (`--contains` / `--regex`) searches memory artifacts directly and emits the fastest proof path for each hit

`memory-history` emits an observed evidence timeline instead of inventing historical diffs:
- targeted mode (`--thread-id`) summarizes stage1 + rollout-summary observable timestamps for one thread
- topic mode (`--contains` / `--regex`) emits a topic-scoped artifact timeline with proof pointers
- summary rows always lead the output; event rows follow in timestamp order

`memory_blocks` is a markdown-block dataset over `~/.codex/memories`:
- one row per heading-delimited block
- exposes `doc_kind`, `heading_path`, `title`, `body`, `preview`, and optional `thread_id` / `rollout_path`
- use it when memory inventory is not enough and you need searchable body content

`memory_stage1_outputs` is the current Codex memory-selection truth from the local state DB:
- one row per `stage1_outputs` entry joined to the owning `threads` row
- exposes `selected_for_phase2`, `usage_count`, `last_usage`, `rollout_path`, `cwd`, and `memory_mode`

`memory_extensions` inventories the live `~/.codex/memories/extensions` tree:
- one row per extension directory
- exposes whether `instructions.md` is present and where it lives

`query.params` is now functional for dataset-specific source overrides:
- `memory_files`: `params.memory_root`, `params.include_preview`
- `memory_stage1_outputs`: `params.state_db_path`
- `memory_extensions`: `params.extensions_root`
- `opencode_prompts`: `params.source`, `params.opencode_db_path`, `params.opencode_path`, `params.include_raw`, `params.include_summary_fallback`
- `opencode_events`: `params.source`, `params.opencode_db_path`, `params.opencode_path`, `params.include_raw`

`opencode-prompts` and `opencode-events` are hybrid surfaces:
- accepts `--spec <json|@path>` for full query controls
- supports convenience flags (`--contains`, `--regex`, `--mode`, `--part-type`, `--group-by`, `--metric`, `--select`, `--sort`)
- `opencode-events` also supports `--role`, `--tool`, and `--status`
- both opencode commands support `--session <id|slug>`, `--since`, `--until`, and `--latest`
- convenience flags override conflicting values from `--spec`
- source controls:
  - `--source auto|db|jsonl` (default: `auto`)
  - `--opencode-db-path` overrides DB source path
  - `--opencode-path` overrides JSONL fallback path
  - `--include-raw` includes raw JSON payload fields

Default opencode source resolution:
- `auto`: try DB first (`$HOME/.local/share/opencode/opencode.db`), then JSONL fallback (`$HOME/.local/state/opencode/prompt-history.jsonl`)
- `db`: use DB only
- `jsonl`: use JSONL only

`orchestration-concurrency` summarizes orchestration substrate and `spawn_agents_on_csv` fanout from session JSONL:
- `spawn_calls`
- direct-lane counters (`spawn_agent_calls`, `wait_calls`, `close_agent_calls`)
- `max_configured_concurrency` and `max_configured_occurrences`
- `max_effective_concurrency` and `max_effective_occurrences` (effective = `min(max_concurrency, csv_rows)`)
- `effective_peak` (alias for `max_effective_concurrency`)
- CSV row observability (`csv_rows_known`, `csv_rows_missing`)
- `spawn_substrate` and `mesh_truth_verdict`
- serialization signal (`serialized_wait_calls`, `serialized_wait_ratio`)
- floor gating fields (`floor_threshold`, `floor_applicable`, `floor_result`)

If a session has no `spawn_agents_on_csv` calls, the command now emits a row with `mesh_truth_verdict=false` and `spawn_substrate` set to `spawn_agent` or `none` instead of hard-failing.

Floor flags:
- `--floor-threshold N` sets the minimum effective peak target (default `3`).
- `--fail-on-floor` exits non-zero when any applicable row has `floor_result=fail`.
- `--fail-on-mesh-truth` exits non-zero when any row has `mesh_truth_verdict=false`.

`tool_invocations` is the queryable cross-session invocation dataset:
- one row per function/custom tool call with `command_text`, `primary_executable`, `workdir`, lifecycle markers, and runtime markers
- use it when you need `seq query` to replace raw JSONL mining of `exec_command.cmd`

`tool_call_args` is the flattened argument-leaf dataset:
- one row per parsed JSON leaf from function-call `arguments` or JSON-shaped custom-tool `input`
- use it when you need generic argument search without column explosion in `tool_calls`

`goal_runs` is the queryable `/goal` dataset:
- one row per session goal aggregate keyed by `thread_id` when available, falling back to session path
- derives objective, status, duration, token usage, and completion budget from goal tool outputs
- classifies `objective_kind` as `review`, `resolve`, or `other`
- counts actual `codex review` invocations in the same session while excluding search/help command contamination

`tool_calls` remains the compatibility dataset:
- existing fields stay intact
- additive fields now include raw argument/input text plus high-value derived fields such as `command_text`, `primary_executable`, and `workdir`

`workflow_signals` is the normalized workflow-analysis dataset:
- text-derived workflow mentions from `$name` tokens after injected skill blocks are stripped
- skill mentions from the same cleaned session text path
- outcome signals for tests, proof, commits, PRs, blocked/error states, and closure language
- tool-call signals from lifecycle-enriched invocations
- agent-role signals from the session graph

`session-tooling` summarizes shell/tool invocation behavior from rollout JSONL:
- raw mode (default) emits per-invocation rows with `command_text`, `primary_executable`, `workdir`, call lifecycle, and runtime markers
- `--summary` aggregates by `--group-by executable|command|tool` (default `executable`)
- session-backed time windows now accept `--since` and `--until`

`message-search`, `message-audit`, `tool-search`, `tool-audit`, `skill-blocks`, and `skill-evidence` accept `--last <duration>` using the same rolling-window syntax as `token-usage`.

`query-diagnose` inspects `seq query` lifecycle health inside rollout JSONL:
- raw mode (default) emits per-query diagnostics (`resolution_state`, `duration_ms`, `hang_flag`)
- also classifies each row with `command_class` and `diagnosis` (`polling_unresolved`, `actual_slow_query`, `unresolved_no_output`, `slow_but_completed`, `completed`)
- strict hang mode is enabled by default and requires unresolved lifecycle plus threshold breach
- `--fail-on-hang` exits non-zero when any query row is flagged as hanging
- `--next-actions` emits deterministic follow-up `seq` command suggestions
- session-backed time windows now accept `--since` and `--until`

`token-usage` reports local token usage from `token_count` traces:
- `--last <duration>` accepts rolling windows such as `90m`, `24h`, or `7d`, ending at `--until` or now
- `--summary` emits aggregate component totals: `input_tokens`, `cached_input_tokens`, `uncached_input_tokens`, `output_tokens`, and `reasoning_output_tokens`
- `--audit` adds proof fields for duplicate totals, resets, null/missing-total rows, requested/observed span days, and naive overcount

`token-cost` estimates token cost from local `token_count` traces:
- reuses monotonic `total_token_usage` deltas and keeps cached input separate from uncached input
- `--last <duration>` shares the same rolling window syntax as `token-usage`
- groups by `day`, `path`, `model`, or `fast_mode`; `--summary` emits one aggregate row
- defaults to OpenAI Codex credit rates with explicit fast-mode evidence only; missing fast evidence is reported as `standard_assumption`
- `--pricing api` switches to exact OpenAI API USD pricing for known models and emits source metadata, model-source metadata, and API component costs
- API pricing fails closed when the trace lacks a known exact model; pass `--model <name>` to price a specific what-if model
- GPT-5.5 API pricing reports long-context surcharge rows when input exceeds the documented long-context threshold
- `--pricing-file <json>` accepts pinned Codex credit or API USD rates for the selected pricing mode; `--refresh-pricing` refreshes current official pricing into the user cache, not the repo
- `--usd-per-credit <amount>` applies only to Codex credit pricing
- `--force-fast` and `--force-standard` are what-if overrides and are marked as override-sourced in output

## Validation

```bash
zig build test
# Note: `zig build test --fuzz` may fail on macOS due Zig InvalidElfMagic runtime issue.
zig build bench -Doptimize=ReleaseFast -- --config perf/frozen/workload_config.json
bash scripts/perf/parser_gate.sh
bash scripts/release/command_surface_gate.sh

# Linux-only bounded fuzz smoke (matches CI behavior).
timeout 180 zig test --dep core_path -Mroot=src/tests.zig -Mcore_path=../../libs/core/src/path_helpers.zig -ffuzz --test-filter "fuzz "

# Differential parity against Python oracle
scripts/parity/run_diff.sh --root ~/.codex/sessions/2026/02/19

# Head-to-head performance gate (requires parity pass first)
scripts/perf/head_to_head.sh --root testdata/golden/sessions --gate 20 --samples 9 --warmup 1
```
