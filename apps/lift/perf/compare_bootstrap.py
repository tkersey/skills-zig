import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


def arguments():
    parser = argparse.ArgumentParser(description="Compare seeded bench_stats bootstrap workloads")
    parser.add_argument("--binary", action="append", required=True, metavar="LABEL=PATH")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=9)
    parser.add_argument("--ci-samples", type=int, default=1000)
    parser.add_argument("--toolchain", default="0.17.0")
    parser.add_argument("--build-mode", default="fast")
    args = parser.parse_args()
    if not 1 <= args.rounds <= 31 or not 1 <= args.ci_samples <= 5000:
        parser.error("rounds must be 1..31 and ci-samples must be 1..5000")
    binaries = {}
    for entry in args.binary:
        label, separator, raw_path = entry.partition("=")
        path = Path(raw_path).resolve()
        if not separator or not label.isidentifier() or label in binaries:
            parser.error("binary labels must be distinct identifiers")
        if not path.is_file() or not os.access(path, os.X_OK):
            parser.error(f"binary is not executable: {path}")
        binaries[label] = path
    if not 2 <= len(binaries) <= 3:
        parser.error("provide two or three binaries")
    return args, binaries


def fixture_cases(ci_samples):
    for count in (16, 128, 1024, 4096):
        for distribution in ("uniform", "duplicates", "descending"):
            if distribution == "uniform":
                baseline = [(index * 7919 % 104729) / 17.0 for index in range(count)]
            elif distribution == "duplicates":
                baseline = [index % 7 for index in range(count)]
            else:
                baseline = [count - index for index in range(count)]
            variant = [value * 0.91 + (index % 3) * 0.01 for index, value in enumerate(baseline)]
            yield f"{distribution}-{count}", baseline, variant, ci_samples, 42
    special = {
        "signed-zero": ["-0", "0", "-1", "1", "-0", "0"],
        "extremes": ["1e308", "-1e308", "1e-300", "-1e-300", "0", "3"],
        "infinity": ["1e309", "-1e309", "1", "0"],
        "singleton": ["42"],
    }
    for name, baseline in special.items():
        yield name, baseline, baseline[::-1], 73, 0


def write_fixture(path, values):
    lines = (value if isinstance(value, str) else format(value, ".17g") for value in values)
    text = "\n".join(lines)
    encoded = (text + "\n").encode()
    path.write_bytes(encoded)
    return hashlib.sha256(encoded).hexdigest()


def execute(binary, baseline, variant, samples, seed):
    command = [
        str(binary), "--input", str(baseline), "--compare", str(variant),
        "--ci-samples", str(samples), "--seed", str(seed), "--json",
    ]
    started = time.perf_counter_ns()
    process = subprocess.run(
        command, capture_output=True, timeout=30, env={**os.environ, "LC_ALL": "C"}
    )
    elapsed = time.perf_counter_ns() - started
    return elapsed, (process.returncode, process.stdout, process.stderr)


def summarize(samples):
    ordered = sorted(samples)
    return {
        "median_ns": statistics.median(samples),
        "minimum_ns": ordered[0],
        "maximum_ns": ordered[-1],
        "samples_ns": samples,
    }


def compare_case(directory, binaries, case, rounds):
    name, baseline, variant, samples, seed = case
    baseline_path = directory / "baseline.txt"
    variant_path = directory / "variant.txt"
    baseline_digest = write_fixture(baseline_path, baseline)
    variant_digest = write_fixture(variant_path, variant)
    timings = {label: [] for label in binaries}
    warmup = {}
    expected = None
    for round_index in range(rounds + 1):
        order = list(binaries.items())
        if round_index % 2:
            order.reverse()
        for label, binary in order:
            elapsed, output = execute(binary, baseline_path, variant_path, samples, seed)
            if output[0] != 0:
                raise RuntimeError(f"benchmark command failed: {name}/{label}/{output[0]}")
            if expected is None:
                expected = output
            if output != expected:
                raise RuntimeError(f"output/status mismatch: {name}/{label}/round-{round_index}")
            if round_index == 0:
                warmup[label] = elapsed
            else:
                timings[label].append(elapsed)
    result = {
        "case": name, "baseline_count": len(baseline), "variant_count": len(variant),
        "ci_samples": samples, "seed": seed, "baseline_input_sha256": baseline_digest,
        "variant_input_sha256": variant_digest, "exit_status": expected[0],
        "stdout_sha256": hashlib.sha256(expected[1]).hexdigest(),
        "stderr_sha256": hashlib.sha256(expected[2]).hexdigest(),
        "initial_invocation_ns": warmup,
        "measurements": {label: summarize(values) for label, values in timings.items()},
    }
    summary = " ".join(
        f"{label}={statistics.median(values) / 1e6:.3f}ms"
        for label, values in timings.items()
    )
    print(f"{name}: {summary}", flush=True)
    return result


def main():
    args, binaries = arguments()
    result = {
        "schema": "lift-bootstrap-comparison/v1",
        "captured_utc": datetime.now(timezone.utc).isoformat(),
        "host": platform.platform(), "machine": platform.machine(),
        "toolchain": args.toolchain, "build_mode": args.build_mode,
        "measurement": "whole CLI process elapsed time including startup and input/output",
        "rounds": args.rounds, "order": "alternating forward/reverse; first invocation excluded",
        "binaries_sha256": {
            label: hashlib.sha256(path.read_bytes()).hexdigest()
            for label, path in binaries.items()
        },
        "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "cases": [],
    }
    with tempfile.TemporaryDirectory(prefix="lift-bootstrap-") as temporary:
        for case in fixture_cases(args.ci_samples):
            result["cases"].append(compare_case(Path(temporary), binaries, case, args.rounds))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
