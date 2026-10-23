import argparse
import csv
import hashlib
import io
import json
import shutil
import statistics
import subprocess
import tarfile
from pathlib import Path


CASES = [f"ledger-topk-16384-k{k}" for k in (1, 10, 100, 1000)]
CASES.append("ledger-topk-32-k10")


def run(argv, cwd=None):
    return subprocess.check_output(argv, cwd=cwd, text=True)


def prepare(args):
    package = Path(__file__).resolve().parent
    repository = args.repository.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    metadata = {"zig": run(["zig", "version"]).strip(), "optimize": "fast", "sources": {}}
    for side in ("baseline", "candidate"):
        revision = getattr(args, side)
        target = args.output / side
        target.mkdir()
        archive = subprocess.check_output(["git", "archive", revision], cwd=repository)
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            source.extractall(target, filter="data")
        metadata["sources"][side] = run(["git", "rev-parse", revision], repository).strip()
        (target / "build.zig").rename(target / "product-build.zig")
        shutil.copyfile(package / "build.zig", target / "build.zig")
        shutil.copyfile(package / "graph.zig", target / "tools/selection_benchmark.zig")
        shutil.copyfile(repository / "tools/optimization_driver.zig",
                        target / "tools/optimization_driver.zig")
        for kind in (("graph",) if args.graph_only else ("graph", "ledger")):
            command = ["zig", "build", "selection-benchmark", "-Doptimize=fast", "-j1"]
            if kind == "ledger":
                command.append("-Dledger-benchmark=true")
            subprocess.run(command, cwd=target, check=True)
            shutil.copyfile(target / "zig-out/bin/perf_hub", args.output / f"{side}-{kind}-bench")
            (args.output / f"{side}-{kind}-bench").chmod(0o755)
    for name in ("graph.zig", "build.zig", "reproduce.py"):
        metadata[name] = hashlib.sha256((package / name).read_bytes()).hexdigest()
    (args.output / "source-environment.json").write_text(json.dumps(metadata, indent=2) + "\n")


def graph_rows(path):
    rows = {}
    for row in csv.DictReader(path.read_text().splitlines(), delimiter="\t"):
        key = tuple(row[name] for name in ("rows", "width", "k", "descending"))
        samples = [int(value.strip()) for value in row["samples_ns"].strip("{} ").split(",")]
        if len(samples) != 30:
            raise ValueError("unexpected graph sample count")
        rows[key] = {**row, "samples": samples}
    return rows


def measure(args):
    raw = args.output / "raw"
    raw.mkdir(exist_ok=False)
    graph = {}
    ledger = {}
    for round_index, side in enumerate(("baseline", "candidate", "candidate", "baseline")):
        target = args.output / side
        result = run([str(args.output / f"{side}-graph-bench")], target)
        path = raw / f"graph-{round_index}-{side}.tsv"
        path.write_text(result)
        graph[(round_index, side)] = graph_rows(path)
        for case in (() if args.graph_only else CASES):
            run([str(args.output / f"{side}-ledger-bench"), "capture", "--target", case], target)
            artifacts = list(target.glob(f".perf-local/*/baselines/ledger/{case}.json"))
            if len(artifacts) != 1:
                raise ValueError("expected one Ledger capture artifact")
            artifact = json.loads(artifacts[0].read_text())
            artifact["machine_id"] = "redacted-local-host"
            (raw / f"ledger-{round_index}-{side}-{case}.json").write_text(
                json.dumps(artifact, indent=2) + "\n")
            ledger[(round_index, side, case)] = artifact
    summarize(args.output, graph, ledger)


def summaries(before, after):
    return {
        "baseline_p50_ns": statistics.median(before),
        "candidate_p50_ns": statistics.median(after),
        "candidate_over_baseline": statistics.median(after) / statistics.median(before),
        "samples_per_side": len(before),
    }


def summarize(output, graph, ledger):
    result = {"graph": [], "ledger": []}
    for key, oracle in graph[(0, "baseline")].items():
        before, after = [], []
        for (_, side), rows in graph.items():
            row = rows[key]
            if row["digest"] != oracle["digest"]:
                raise ValueError(f"graph output differs: {key}")
            (before if side == "baseline" else after).extend(row["samples"])
        current = graph[(1, "candidate")][key]
        result["graph"].append({
            "case": key, **summaries(before, after), "output_digest": oracle["digest"],
            "baseline_alloc_calls": int(oracle["alloc_calls"]),
            "candidate_alloc_calls": int(current["alloc_calls"]),
            "baseline_allocated_bytes": int(oracle["allocated_bytes"]),
            "candidate_allocated_bytes": int(current["allocated_bytes"]),
        })
    for case in (CASES if ledger else ()):
        oracle = ledger[(0, "baseline", case)]
        before, after = [], []
        for (_, side, observed_case), row in ledger.items():
            if observed_case != case:
                continue
            for field in ("workload_sha256", "output_sha256"):
                if row[field] != oracle[field]:
                    raise ValueError(f"Ledger output or fixture differs: {case}")
            (before if side == "baseline" else after).extend(row["metrics"]["samples_ns"])
        current = ledger[(1, "candidate", case)]
        result["ledger"].append({
            "case": case, **summaries(before, after), "output_sha256": oracle["output_sha256"],
            "baseline_alloc_calls": oracle["metrics"]["p50_alloc_calls"],
            "candidate_alloc_calls": current["metrics"]["p50_alloc_calls"],
        })
    (output / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"Matched {len(result['graph'])} graph and {len(result['ledger'])} Ledger cases")


parser = argparse.ArgumentParser()
parser.add_argument("phase", choices=("prepare", "measure"))
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[4])
parser.add_argument("--baseline", default="8e470a24b533dba479f39f7ae3cc7f07b5fc5aeb")
parser.add_argument("--candidate", default="HEAD")
parser.add_argument("--graph-only", action="store_true")
arguments = parser.parse_args()
arguments.output = arguments.output.resolve()
(prepare if arguments.phase == "prepare" else measure)(arguments)
