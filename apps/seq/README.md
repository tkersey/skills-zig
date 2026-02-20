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
```

## Validation

```bash
zig build test
# Note: `zig build test --fuzz` may fail on macOS due Zig InvalidElfMagic runtime issue.
zig build bench -Doptimize=ReleaseFast -- --config perf/frozen/workload_config.json

# Differential parity against Python oracle
scripts/parity/run_diff.sh --root ~/.codex/sessions/2026/02/19

# Head-to-head performance gate (requires parity pass first)
scripts/perf/head_to_head.sh --root testdata/golden/sessions --gate 20 --samples 9 --warmup 1
```
