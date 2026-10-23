import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fixture():
    return {
        "operation": "assert", "authority": "benchmark-fixture", "summary": "Synthetic note",
        "scope": {"kind": "global", "repo": None, "paths": []},
        "source_refs": [{"kind": "test", "ref": "synthetic", "summary": "Synthetic evidence"}],
        "related_ids": [], "supersedes_id": None,
        "payload": {"harness_rule": "r", "trigger": "t", "preferred_behavior": "p",
                    "failure_avoided": "f", "verification_cue": "v", "evidence_count": 1},
    }


def encode(value):
    return json.dumps(value, separators=(",", ":")).encode()


def prepare(root, counts):
    source = fixture()
    raw = encode(source)
    (root / "input.json").write_bytes(raw)
    fingerprint = digest(b"harness\nharness-rule\n" + raw)
    for count in counts:
        notes = root / f"home-{count}" / "memories/extensions/harness/notes"
        notes.mkdir(parents=True)
        for index in range(count):
            note = dict(source, schema="memory-source-note/v1", extension="harness",
                        kind="harness-rule", id=f"MSN-20261011T000000Z-{index:016x}",
                        captured_at="2026-10-11T00:00:00Z",
                        fingerprint=fingerprint if index == count - 1 else f"{index:064x}")
            if index != count - 1:
                note["payload"] = {"evidence": "x" * 512}
            (notes / f"legacy-{index:05d}.md").write_bytes(encode(note) + b"\n")
    source["summary"] = "Fresh unique admission"
    (root / "fresh.json").write_bytes(encode(source))
    source["payload"]["harness_rule"] = "x" * 131072
    (root / "fresh-large.json").write_bytes(encode(source))
    return digest(raw)


def commands(root, count):
    def append(name):
        return ["append", "--kind", "harness-rule", "--json", str(root / name), "--dry-run"]
    return {
        "list": ["list", "--limit", "10000"],
        "show": ["show", "--id", f"MSN-20261011T000000Z-{count - 1:016x}"],
        "duplicate": append("input.json"), "fresh": append("fresh.json"),
        "fresh-large": append("fresh-large.json"),
        "migration-preview": ["migrate", "--from-memory-version", "v1", "--dry-run"],
    }


def normalized(output, case, root):
    if case.startswith("fresh"):
        value = json.loads(output)
        note = json.loads(value["note"])
        stamp = note["captured_at"]
        time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")
        compact = stamp.replace("-", "").replace(":", "")
        expected_id = "MSN-" + compact + "-" + note["fingerprint"][:16]
        assert note["id"] == value["id"] == expected_id
        assert Path(value["path"]).name.startswith(stamp[:-1].replace(":", "-") + "-")
        output = output.replace(expected_id.encode(),
                                ("MSN-TIME-" + note["fingerprint"][:16]).encode())
        output = output.replace(stamp.encode(), b"TIME")
        output = output.replace(stamp[:-1].replace(":", "-").encode(), b"TIME")
    return output.replace(str(root).encode(), b"$SYNTHETIC_ROOT")


def measure(args, binaries, root):
    samples = []
    for count in args.counts:
        home = root / f"home-{count}"
        for case, command in commands(root, count).items():
            for round_index in range(args.samples):
                observed = []
                order = list(binaries) if round_index % 2 == 0 else list(reversed(binaries))
                for label in order:
                    version = "v2" if case == "migration-preview" else "v1"
                    argv = [str(binaries[label]), *command, "--codex-home", str(home),
                            "--memory-version", version, "--extension", "harness"]
                    started = time.perf_counter_ns()
                    result = subprocess.run(argv, capture_output=True, timeout=60, check=True)
                    elapsed = time.perf_counter_ns() - started
                    assert result.stderr == b"", (case, label, result.stderr)
                    output_hash = digest(normalized(result.stdout, case, root))
                    observed.append(output_hash)
                    samples.append(dict(binary=label, case=case, files=count,
                                        round=round_index, elapsed_ns=elapsed,
                                        output_sha256=output_hash))
                assert len(set(observed)) == 1, (count, case, observed)
    return samples


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--counts", type=int, nargs="+", default=[32, 1024, 4096])
    args = parser.parse_args()
    if not 1 <= args.samples <= 100 or any(not 1 <= count <= 10000 for count in args.counts):
        parser.error("samples must be 1..100 and counts must be 1..10000")
    binaries = {name: getattr(args, name).resolve(strict=True) for name in ("baseline", "candidate")}
    metadata = {name: {"sha256": digest(path.read_bytes()),
                       "version": subprocess.check_output([str(path), "--version"]).decode().strip()}
                for name, path in binaries.items()}
    with tempfile.TemporaryDirectory(prefix="memory-note-benchmark-") as temporary:
        root = Path(temporary).resolve()
        workload_hash = prepare(root, args.counts)
        samples = measure(args, binaries, root)
    report = {"schema": "memory-note-inventory-benchmark/v1", "platform": platform.platform(),
              "machine": platform.machine(), "python": platform.python_version(),
              "input_sha256": workload_hash, "binaries": metadata, "samples": samples}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    for count in args.counts:
        for case in commands(Path("."), count):
            medians = {label: statistics.median(row["elapsed_ns"] for row in samples
                       if row["binary"] == label and row["files"] == count and row["case"] == case)
                       for label in binaries}
            improvement = 100 * (1 - medians["candidate"] / medians["baseline"])
            print(f"{case} files={count} medians_ns={medians} improvement={improvement:.2f}%")


if __name__ == "__main__":
    main()
