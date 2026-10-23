import argparse
import hashlib
import json
import platform
import re
import statistics
import subprocess
from pathlib import Path


def command(args, root):
    return subprocess.check_output(args, cwd=root, text=True).strip()


def inputs(root, baseline):
    relative = "libs/siwc/src/transport.zig"
    source = {
        "baseline": command(["git", "show", f"{baseline}:{relative}"], root) + "\n",
        "candidate": (root / relative).read_text(),
    }
    return source, {
        "baseline_commit": command(["git", "rev-parse", baseline], root),
        "source_sha256": {
            label: hashlib.sha256(value.encode()).hexdigest()
            for label, value in source.items()
        },
        "harness_sha256": hashlib.sha256(
            Path(__file__).with_name("harness.zig").read_bytes()
        ).hexdigest(),
        "optimize": "ReleaseFast",
        "zig": command(["zig", "version"], root),
        "system": f"{platform.system()} {platform.release()} {platform.machine()}",
    }


def prepare(root, output, source, metadata):
    fixture = source["candidate"].split("const HttpTestReply = struct {", 1)[1]
    fixture = "const HttpTestReply = struct {" + fixture.split(
        "fn expectPooledBuffersErased(", 1
    )[0]
    harness = Path(__file__).with_name("harness.zig").read_text()
    for label, value in source.items():
        value = re.sub(
            r"    pub fn url\(.*?    fn body\(",
            "    pub fn url(_: Request) []const u8 {\n"
            "        return benchmark_url;\n    }\n\n    fn body(",
            value,
            count=1,
            flags=re.DOTALL,
        )
        value = value.split("const HttpTestReply = struct {", 1)[0]
        path = output / f"{label}_bench.zig"
        path.write_text(value + "\n" + fixture + "\n" + harness)
        with (output / f"{label}-compile.log").open("w") as log:
            subprocess.run(
                ["zig", "test", str(path), "-lc", "-OReleaseFast", "--test-filter",
                 "transport performance", "--test-no-exec",
                 f"-femit-bin={output / (label + '_bench')}"],
                cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True,
            )
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")


def sample(root, output, pairs, metadata):
    recorded = json.loads((output / "metadata.json").read_text())
    if recorded != metadata:
        raise ValueError("Benchmark inputs changed; rebuild before collecting samples")
    rows = {"baseline": [], "candidate": []}
    process_medians = {"baseline": [], "candidate": []}
    for pair in range(1, pairs + 1):
        order = ("baseline", "candidate") if pair % 2 else ("candidate", "baseline")
        for label in order:
            result = subprocess.run(
                [str(output / f"{label}_bench")], cwd=root, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True,
            )
            (output / f"{label}-{pair}.log").write_text(result.stdout)
            values = [json.loads(value) for value in re.findall(
                r'\{"round":.*?\}', result.stdout
            )]
            if len(values) != 25:
                raise ValueError(f"Expected 25 samples for {label}, got {len(values)}")
            rows[label].extend(values)
            process_medians[label].append(statistics.median(
                value["elapsed_ns"] for value in values
            ))
    summaries = {}
    for label, values in rows.items():
        elapsed = [value["elapsed_ns"] for value in values]
        deciles = statistics.quantiles(elapsed, n=10)
        summaries[label] = {
            "samples": len(values), "requests_each": 3,
            "connections_each": sorted({value["connections"] for value in values}),
            "median_ns": statistics.median(elapsed),
            "p10_ns": deciles[0], "p90_ns": deciles[8],
            "process_medians_ns": process_medians[label],
        }
    summaries["median_reduction_percent"] = 100 * (
        1 - summaries["candidate"]["median_ns"] / summaries["baseline"]["median_ns"]
    )
    text = json.dumps(summaries, indent=2) + "\n"
    (output / "summary.json").write_text(text)
    print(text, end="")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", default="8e470a2")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", default=5, type=int)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--build-only", action="store_true")
    mode.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    if args.pairs < 1:
        parser.error("--pairs must be positive")
    root = Path(__file__).resolve().parents[4]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source, metadata = inputs(root, args.baseline)
    if not args.skip_build:
        prepare(root, output, source, metadata)
    if not args.build_only:
        sample(root, output, args.pairs, metadata)


if __name__ == "__main__":
    main()
