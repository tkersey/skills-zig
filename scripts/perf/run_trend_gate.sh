#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "usage: $0 <zig-step> <config-path> <baseline-artifact> <trend-artifact> [extra-zig-args...]" >&2
  exit 2
fi

zig_step="$1"
config_path="$2"
baseline_artifact="$3"
trend_artifact="$4"
shift 4

mkdir -p "$(dirname "$trend_artifact")"
if [[ -f "$baseline_artifact" ]]; then
  cp "$baseline_artifact" "$trend_artifact"
else
  rm -f "$trend_artifact"
fi

zig build "$zig_step" -Doptimize="${PERF_OPTIMIZE_MODE:-ReleaseFast}" -- \
  --config "$config_path" \
  --artifact "$trend_artifact" \
  "$@"
