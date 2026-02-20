#!/usr/bin/env bash
set -euo pipefail

ROOT="${HOME}/.codex/sessions"
GATE="20"
SAMPLES="15"
WARMUP="2"
WORK_DIR=".zig-cache/perf"
REPORT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --gate) GATE="$2"; shift 2 ;;
    --samples) SAMPLES="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

mkdir -p "$WORK_DIR"
FROZEN_ROOT="$WORK_DIR/frozen-root"
rm -rf "$FROZEN_ROOT"
mkdir -p "$FROZEN_ROOT"
rsync -a --delete "$ROOT/" "$FROZEN_ROOT/"

# Hard prerequisite: parity must pass on frozen root.
PARITY_SUMMARY="$WORK_DIR/parity-summary.json"
scripts/parity/run_diff.sh --root "$FROZEN_ROOT" >"$PARITY_SUMMARY"

ZIG_BIN="./zig-out/bin/seq"
PY_ORACLE="$(jq -r '.python_oracle' scripts/parity/matrix.json)"

BENCH_JSON="$WORK_DIR/bench.json"
export FROZEN_ROOT
export ZIG_BIN
export PY_ORACLE
export GATE
export SAMPLES
export WARMUP
uv run python - <<'PY' >"$BENCH_JSON"
import json
import os
import statistics
import subprocess
import sys
import time

root = os.environ.get("FROZEN_ROOT")
zig = os.environ.get("ZIG_BIN")
py_oracle = os.environ.get("PY_ORACLE")
gate = float(os.environ.get("GATE", "20"))
samples = int(os.environ.get("SAMPLES", "15"))
warmup = int(os.environ.get("WARMUP", "2"))

cases = [
    ("query_tool_calls_day_tool", "testdata/parity/specs/query_tool_calls_day_tool.json"),
    ("query_token_deltas_day", "testdata/parity/specs/query_token_deltas_day.json"),
    ("query_token_sessions_day", "testdata/parity/specs/query_token_sessions_day.json"),
]

def run(cmd):
    t0 = time.perf_counter_ns()
    proc = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.strip() or f"command failed: {' '.join(cmd)}")
    return time.perf_counter_ns() - t0

rows = []
for case_id, spec in cases:
    for _ in range(warmup):
        run([zig, "query", "--root", root, "--spec", f"@{spec}"])
        run([sys.executable, py_oracle, "query", "--root", root, "--spec", f"@{spec}"])

    zig_samples = []
    py_samples = []
    for _ in range(samples):
        py_samples.append(run([sys.executable, py_oracle, "query", "--root", root, "--spec", f"@{spec}"]))
        zig_samples.append(run([zig, "query", "--root", root, "--spec", f"@{spec}"]))

    py_p50 = statistics.median(py_samples)
    zig_p50 = statistics.median(zig_samples)
    speedup_pct = ((py_p50 - zig_p50) / py_p50) * 100.0 if py_p50 else 0.0
    rows.append({
        "id": case_id,
        "py_p50_ns": py_p50,
        "zig_p50_ns": zig_p50,
        "speedup_pct": speedup_pct,
    })

overall_p50_speedup_pct = statistics.median([r["speedup_pct"] for r in rows]) if rows else 0.0
status = "PASS" if overall_p50_speedup_pct >= gate else "FAIL"

print(json.dumps({
    "samples": samples,
    "warmup": warmup,
    "gate_pct": gate,
    "cases": rows,
    "overall_p50_speedup_pct": overall_p50_speedup_pct,
    "status": status,
}, indent=2))

if status != "PASS":
    raise SystemExit(2)
PY

if [[ -n "$REPORT" ]]; then
  cp "$BENCH_JSON" "$REPORT"
fi

cat "$BENCH_JSON"
