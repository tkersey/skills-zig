#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
GATE_HELPER="$ROOT_DIR/../../scripts/perf/run_trend_gate.sh"

CONFIG_PATH="${CAS_BUDGET_CONFIG_PATH:-perf/budget_governor/workload_config.json}"
BASELINE_ARTIFACT="${CAS_BUDGET_BASELINE_ARTIFACT:-perf/budget_governor/artifacts/baseline.json}"
TREND_ARTIFACT="${CAS_BUDGET_TREND_ARTIFACT:-.zig-cache/perf/budget_governor/latest.json}"

"$GATE_HELPER" \
  bench-cas-budget-governor \
  "$CONFIG_PATH" \
  "$BASELINE_ARTIFACT" \
  "$TREND_ARTIFACT"
