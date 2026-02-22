#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
GATE_HELPER="$ROOT_DIR/../../scripts/perf/run_trend_gate.sh"

CONFIG_PATH="${PARSER_CONFIG_PATH:-perf/parser/workload_config.json}"
BASELINE_ARTIFACT="${PARSER_BASELINE_ARTIFACT:-perf/parser/artifacts/baseline.json}"
TREND_ARTIFACT="${PARSER_TREND_ARTIFACT:-.zig-cache/perf/parser/latest.json}"
CORPUS_DIR="${PARSER_CORPUS_DIR:-testdata/golden/sessions}"

# Synthetic run enforces both absolute and trend gates.
"$GATE_HELPER" \
  bench-parser \
  "$CONFIG_PATH" \
  "$BASELINE_ARTIFACT" \
  "$TREND_ARTIFACT"

# Real-corpus run is informational for drift visibility; absolute gates stay on synthetic.
zig build bench-parser -Doptimize=ReleaseFast -- \
  --config "$CONFIG_PATH" \
  --real-corpus-dir "$CORPUS_DIR" \
  --report-only
