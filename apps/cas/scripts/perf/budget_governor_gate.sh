#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE_HELPER="$ROOT_DIR/../../scripts/perf/run_trend_gate.sh"

CONFIG_PATH="${CAS_BUDGET_CONFIG_PATH:-perf/budget_governor/workload_config.json}"
BASELINE_ARTIFACT="${CAS_BUDGET_BASELINE_ARTIFACT:-perf/budget_governor/artifacts/baseline.json}"
TREND_ARTIFACT="${CAS_BUDGET_TREND_ARTIFACT:-.zig-cache/perf/budget_governor/latest.json}"

# Defaults and relative overrides belong to the app; Zig's package belongs to
# the repository root, regardless of the caller's working directory.
app_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$ROOT_DIR" "$1" ;;
  esac
}
CONFIG_PATH="$(app_path "$CONFIG_PATH")"
BASELINE_ARTIFACT="$(app_path "$BASELINE_ARTIFACT")"
TREND_ARTIFACT="$(app_path "$TREND_ARTIFACT")"
cd "$ROOT_DIR/../.."

"$GATE_HELPER" \
  bench-cas-budget-governor \
  "$CONFIG_PATH" \
  "$BASELINE_ARTIFACT" \
  "$TREND_ARTIFACT"
