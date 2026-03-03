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
./zig-out/bin/seq dataset-schema --dataset opencode_prompts
./zig-out/bin/seq dataset-schema --dataset opencode_events
./zig-out/bin/seq role-breakdown --root ~/.codex/sessions --format table
./zig-out/bin/seq query --spec '{"dataset":"tool_calls","group_by":["tool"],"metrics":[{"op":"count","as":"count"}],"sort":["-count"],"limit":10,"format":"json"}'
./zig-out/bin/seq opencode-prompts --limit 20 --format jsonl
./zig-out/bin/seq opencode-prompts --source db --contains "grill me" --mode normal --select session_slug,message_id,prompt_text,part_types --sort -time_created_epoch_ms --format table
./zig-out/bin/seq opencode-events --source db --role assistant --tool shell --status completed --select session_slug,message_id,event_index,part_type,tool_name,tool_status,text --sort -time_created_epoch_ms --limit 50 --format table
./zig-out/bin/seq query --spec '{"dataset":"opencode_prompts","params":{"source":"db","opencode_db_path":"~/.local/share/opencode/opencode.db"},"where":[{"field":"part_types","op":"contains","value":"file"}],"select":["session_slug","prompt_text","part_types"],"sort":["-time_created_epoch_ms"],"format":"jsonl"}'
./zig-out/bin/seq routing-gap --cue-spec @cue-spec.json --discovery-skills grill-me,prove-it,complexity-mitigator,invariant-ace,tk
./zig-out/bin/seq orchestration-concurrency --session-id 019ca0e5-0beb-7740-a9bc-81664d994266 --format table
./zig-out/bin/seq orchestration-concurrency --path /absolute/path/to/rollout.jsonl --floor-threshold 3 --fail-on-floor --format json
./zig-out/bin/seq orchestration-concurrency --path /absolute/path/to/rollout.jsonl --fail-on-mesh-truth --format table
```

`query.where.op` supports `contains_any` and `regex_any` in addition to `contains` and `regex`.
`regex` uses a fast regex-like subset (`^`, `$`, `|`) and fails fast on unsupported constructs.
`query.params` is now functional for dataset-specific source overrides:
- `memory_files`: `params.memory_root`, `params.include_preview`
- `opencode_prompts`: `params.source`, `params.opencode_db_path`, `params.opencode_path`, `params.include_raw`, `params.include_summary_fallback`
- `opencode_events`: `params.source`, `params.opencode_db_path`, `params.opencode_path`, `params.include_raw`

`opencode-prompts` and `opencode-events` are hybrid surfaces:
- accepts `--spec <json|@path>` for full query controls
- supports convenience flags (`--contains`, `--regex`, `--mode`, `--part-type`, `--group-by`, `--metric`, `--select`, `--sort`)
- `opencode-events` also supports `--role`, `--tool`, and `--status`
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

## Validation

```bash
zig build test
# Note: `zig build test --fuzz` may fail on macOS due Zig InvalidElfMagic runtime issue.
zig build bench -Doptimize=ReleaseFast -- --config perf/frozen/workload_config.json
bash scripts/perf/parser_gate.sh

# Linux-only bounded fuzz smoke (matches CI behavior).
timeout 180 zig test --dep core_path -Mroot=src/tests.zig -Mcore_path=../../libs/core/src/path_helpers.zig -ffuzz --test-filter "fuzz "

# Differential parity against Python oracle
scripts/parity/run_diff.sh --root ~/.codex/sessions/2026/02/19

# Head-to-head performance gate (requires parity pass first)
scripts/perf/head_to_head.sh --root testdata/golden/sessions --gate 20 --samples 9 --warmup 1
```
