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
./zig-out/bin/seq role-breakdown --root ~/.codex/sessions --format table
./zig-out/bin/seq query --spec '{"dataset":"tool_calls","group_by":["tool"],"metrics":[{"op":"count","as":"count"}],"sort":["-count"],"limit":10,"format":"json"}'
./zig-out/bin/seq routing-gap --cue-spec @cue-spec.json --discovery-skills grill-me,prove-it,complexity-mitigator,invariant-ace,tk
./zig-out/bin/seq orchestration-concurrency --session-id 019ca0e5-0beb-7740-a9bc-81664d994266 --format table
```

`query.where.op` supports `contains_any` and `regex_any` in addition to `contains` and `regex`.
`regex` uses a fast regex-like subset (`^`, `$`, `|`) and fails fast on unsupported constructs.

`orchestration-concurrency` summarizes `spawn_agents_on_csv` fanout from session JSONL:
- `spawn_calls`
- `max_configured_concurrency` and `max_configured_occurrences`
- `max_effective_concurrency` and `max_effective_occurrences` (effective = `min(max_concurrency, csv_rows)`)
- CSV row observability (`csv_rows_known`, `csv_rows_missing`)

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
