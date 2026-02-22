#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
GATE_HELPER="$ROOT_DIR/../../scripts/perf/run_trend_gate.sh"

CONFIG_PATH="${LIFT_BENCH_CONFIG_PATH:-perf/bench_stats/workload_config.json}"
BASELINE_ARTIFACT="${LIFT_BENCH_BASELINE_ARTIFACT:-perf/bench_stats/artifacts/baseline.json}"
TREND_ARTIFACT="${LIFT_BENCH_TREND_ARTIFACT:-.zig-cache/perf/bench_stats/latest.json}"

"$GATE_HELPER" \
  bench-lift-bench-stats \
  "$CONFIG_PATH" \
  "$BASELINE_ARTIFACT" \
  "$TREND_ARTIFACT"
