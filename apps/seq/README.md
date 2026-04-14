# seq

`seq` is a Zig 0.15.2 CLI for mining Codex session and memory artifacts.

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
./zig-out/bin/seq role-breakdown --root ~/.codex/sessions --since 2026-03-01T00:00:00Z --format table
./zig-out/bin/seq query --spec '{"dataset":"tool_calls","group_by":["tool"],"metrics":[{"op":"count","as":"count"}],"sort":["-count"],"limit":10,"format":"json"}'
./zig-out/bin/seq query --root ~/.codex/sessions --spec '{"dataset":"tool_invocations","where":[{"field":"command_text","op":"contains","value":"learnings recall"}],"select":["path","tool_name","command_text","workdir"],"sort":["timestamp"],"limit":5,"format":"table"}'
./zig-out/bin/seq query --root ~/.codex/sessions --spec '{"dataset":"tool_call_args","where":[{"field":"tool_name","op":"eq","value":"exec_command"},{"field":"arg_path","op":"eq","value":"workdir"}],"select":["path","arg_path","value_text"],"sort":["timestamp"],"limit":5,"format":"table"}'
./zig-out/bin/seq find-session --root ~/.codex/sessions --prompt "learnings recall" --since 2026-03-08T00:00:00Z --until 2026-03-10T23:59:59Z --limit 5 --format table
./zig-out/bin/seq plan-search --root ~/.codex/sessions --repo /Users/tk/workspace/tk/shift --since 2026-03-01T00:00:00Z --format table
./zig-out/bin/seq plan-search --root ~/.codex/sessions --repo /Users/tk/workspace/tk/shift --contains "PromptMode" --stats --format jsonl
./zig-out/bin/seq plan-search --root ~/.codex/sessions --session-id 019ce80b-9fb4-72a1-9c1e-3d626d4e4913 --include-body --format jsonl
./zig-out/bin/seq reply-latency --root ~/.codex/sessions --limit 10 --format table
./zig-out/bin/seq reply-latency --root ~/.codex/sessions --mode contiguous --since 2026-03-01T00:00:00Z --until 2026-03-05T00:00:00Z --format json
./zig-out/bin/seq session-tooling --root ~/.codex/sessions --since 2026-03-08T00:00:00Z --until 2026-03-10T23:59:59Z --summary --group-by executable --format table
./zig-out/bin/seq query-diagnose --path /absolute/path/to/rollout.jsonl --threshold-ms 10000 --next-actions --format json
./zig-out/bin/seq artifact-search --contains "spawn_agent" --kind orchestration --since 2026-03-01T00:00:00Z --limit 10 --format table
./zig-out/bin/seq artifact-search --contains "MEMORY.md" --kind memory --stats --format table
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
- accepts `--kind auto|session|memory|orchestration|tooling|prompt`
- accepts `--surface auto|messages|tool_calls|memory_blocks` when you need to pin the substrate
- emits `next_action_kind` / `next_action` suggestions for follow-up commands
- `--stats` adds scan counters (`surfaces_scanned`, `candidate_files`, `files_opened`, `rows_examined`, `rows_emitted`, `duration_ms`)

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

`memory_extensions` inventories the live `~/.codex/memories_extensions` tree:
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

`tool_calls` remains the compatibility dataset:
- existing fields stay intact
- additive fields now include raw argument/input text plus high-value derived fields such as `command_text`, `primary_executable`, and `workdir`

`session-tooling` summarizes shell/tool invocation behavior from rollout JSONL:
- raw mode (default) emits per-invocation rows with `command_text`, `primary_executable`, `workdir`, call lifecycle, and runtime markers
- `--summary` aggregates by `--group-by executable|command|tool` (default `executable`)
- session-backed time windows now accept `--since` and `--until`

`query-diagnose` inspects `seq query` lifecycle health inside rollout JSONL:
- raw mode (default) emits per-query diagnostics (`resolution_state`, `duration_ms`, `hang_flag`)
- also classifies each row with `command_class` and `diagnosis` (`polling_unresolved`, `actual_slow_query`, `unresolved_no_output`, `slow_but_completed`, `completed`)
- strict hang mode is enabled by default and requires unresolved lifecycle plus threshold breach
- `--fail-on-hang` exits non-zero when any query row is flagged as hanging
- `--next-actions` emits deterministic follow-up `seq` command suggestions
- session-backed time windows now accept `--since` and `--until`

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
