#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEQ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SEQ_ROOT/../.." && pwd)"
WORKLOADS="${1:-$SEQ_ROOT/perf/frozen/workloads.json}"
BASELINE="${SEQ_E2E_BASELINE:-}"
ROUNDS="${SEQ_E2E_ROUNDS:-5}"

cd "$REPO_ROOT"
zig build build-seq -Doptimize=ReleaseFast >/dev/null

cd "$SEQ_ROOT"
PYTHON_BIN="${PYTHON:-python3}"
"$PYTHON_BIN" - "$SEQ_ROOT" "$REPO_ROOT/zig-out/bin/seq" "$WORKLOADS" "$BASELINE" "$ROUNDS" <<'PY'
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

seq_root = Path(sys.argv[1])
seq_bin = Path(sys.argv[2])
workloads_path = Path(sys.argv[3])
baseline_path = Path(sys.argv[4]) if sys.argv[4] else None
rounds = int(sys.argv[5])

workloads = json.loads(workloads_path.read_text())
baseline = {}
if baseline_path and baseline_path.exists():
    for line in baseline_path.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        baseline[row["workload"]] = row

def percentile(values, pct):
    ordered = sorted(values)
    idx = round((len(ordered) - 1) * pct)
    return ordered[idx]

def extract_first_stats(stdout):
    text = stdout.strip()
    if not text:
        return {}
    candidates = []
    if text.startswith("["):
        try:
            arr = json.loads(text)
            if arr:
                candidates.append(arr[0])
        except json.JSONDecodeError:
            pass
    elif text.startswith("{"):
        try:
            obj = json.loads(text)
            if "stats" in obj and isinstance(obj["stats"], dict):
                return obj["stats"]
            candidates.append(obj)
        except json.JSONDecodeError:
            pass
    else:
        first = text.splitlines()[0]
        try:
            candidates.append(json.loads(first))
        except json.JSONDecodeError:
            pass
    for obj in candidates:
        if isinstance(obj, dict):
            return {k: obj.get(k, 0) for k in (
                "candidate_files",
                "files_opened",
                "rows_materialized",
            )}
    return {}

failed = False
for workload in workloads:
    samples = []
    stats_samples = []
    argv = [str(seq_bin)] + workload["argv"]
    for _ in range(rounds):
        start = time.perf_counter()
        proc = subprocess.run(argv, cwd=seq_root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        if proc.returncode != 0:
            sys.stderr.write(proc.stderr)
            raise SystemExit(proc.returncode)
        samples.append(elapsed_ms)
        stats_samples.append(extract_first_stats(proc.stdout))

    p50 = percentile(samples, 0.50)
    p95 = percentile(samples, 0.95)
    med_stats = {}
    for key in ("candidate_files", "files_opened", "rows_materialized"):
        vals = [int(s.get(key, 0) or 0) for s in stats_samples]
        med_stats[f"{key}_p50"] = int(statistics.median(vals)) if vals else 0

    status = "PASS"
    old = baseline.get(workload["name"])
    if old:
        if p50 > float(old.get("p50_ms", p50)) * 1.10:
            status = "FAIL"
        if p95 > float(old.get("p95_ms", p95)) * 1.20:
            status = "FAIL"
        for key in ("candidate_files_p50", "files_opened_p50", "rows_materialized_p50"):
            old_value = int(old.get(key, med_stats[key]) or 0)
            if old_value > 0 and med_stats[key] > old_value * 2:
                status = "FAIL"

    row = {
        "workload": workload["name"],
        "rounds": rounds,
        "p50_ms": round(p50, 3),
        "p95_ms": round(p95, 3),
        **med_stats,
        "status": status,
    }
    print(json.dumps(row, separators=(",", ":")))
    failed = failed or status != "PASS"

raise SystemExit(1 if failed else 0)
PY
