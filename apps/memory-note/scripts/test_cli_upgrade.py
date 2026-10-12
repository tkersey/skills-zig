#!/usr/bin/env python3
"""Exercise old-produced admissions and migration capacity in temporary homes."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


BINARY = Path(sys.argv[1]).resolve(strict=True)
FIXTURES = Path(__file__).resolve().parents[1] / "fixtures" / "legacy-v0.2.0"


def invoke(home, command, extension="harness", version="v1", extra=(), raw=None):
    args = [str(BINARY), command, "--codex-home", str(home), "--extension", extension]
    if version is not None:
        args += ["--memory-version", version]
    args += list(extra)
    env = dict(os.environ, CODEX_BIN=str(home.parent / "absent-codex"))
    return subprocess.run(args, input=raw, capture_output=True, env=env, timeout=60)


def successful(result):
    assert result.returncode == 0, (result.args, result.returncode, result.stderr)
    return json.loads(result.stdout)


def notes_dir(home, version, extension="harness"):
    root = "memories" if version == "v1" else "memories_v2"
    return home / root / "extensions" / extension / "notes"


def legacy_roundtrip(home, note):
    extension = note["extension"]
    raw = (FIXTURES / note["fixture"]).read_bytes()
    assert hashlib.sha256(raw).hexdigest() == note["sha256"]
    assert json.loads(raw)["id"] == note["id"]
    source_dir = notes_dir(home, "v1", extension)
    source_dir.mkdir(parents=True)
    source = source_dir / note["filename"]
    source.write_bytes(raw)
    listed = successful(invoke(home, "list", extension))
    assert [item["id"] for item in listed["notes"]] == [note["id"]]
    shown = invoke(home, "show", extension, extra=("--id", note["id"]))
    assert shown.returncode == 0 and shown.stdout == raw
    path = invoke(home, "path", extension)
    assert path.returncode == 0 and path.stdout == (str(source_dir) + "\n").encode()
    migration = ("--from-memory-version", "v1")
    preview = successful(invoke(home, "migrate", extension, "v2", (*migration, "--dry-run")))
    assert preview["planned"] == 1 and not preview["storage_mutated"]
    copied = successful(invoke(home, "migrate", extension, "v2", migration))
    assert copied["copied"] == 1
    target = notes_dir(home, "v2", extension) / source.name
    assert target.read_bytes() == source.read_bytes() == raw
    duplicate = successful(invoke(home, "append", extension, "v2",
                                 ("--kind", note["kind"], "--json", "-"),
                                 note["input"].encode()))
    assert duplicate["status"] == "duplicate_skip" and duplicate["id"] == note["id"]
    reverse = successful(invoke(home, "migrate", extension, "v1",
                                ("--from-memory-version", "v2")))
    assert reverse["copied"] == 0 and reverse["duplicate_skip"] == 1
    assert target.read_bytes() == source.read_bytes() == raw


def offline_and_reverse(home, note):
    unavailable = invoke(home, "list", version=None)
    assert unavailable.returncode != 0 and b"CodexConfigUnavailable" in unavailable.stderr
    payload = json.loads(note["input"])
    payload["summary"] += "; new admission before a layout rollback"
    made = successful(invoke(home, "append", version="v2",
                             extra=("--kind", "harness-rule", "--json", "-"),
                             raw=json.dumps(payload).encode()))
    raw = Path(made["path"]).read_bytes()
    reverse = successful(invoke(home, "migrate", extra=("--from-memory-version", "v2")))
    assert reverse["copied"] == 1 and reverse["duplicate_skip"] == 1
    shown = invoke(home, "show", extra=("--id", made["id"]))
    assert shown.returncode == 0 and shown.stdout == raw


def large_inventory(root, note):
    home, capture = root / "large", root / "capture"
    source = notes_dir(home, "v1")
    source.mkdir(parents=True)
    payload = json.loads(note["input"])
    payload["payload"]["harness_rule"] = "x" * 1_000_000
    # Capture into an empty spool each time so fixture setup does not scan O(n²) bytes.
    for index in range(68):
        payload["summary"] = f"Large retained admission {index}"
        made = successful(invoke(capture, "append",
                                 extra=("--kind", "harness-rule", "--json", "-"),
                                 raw=json.dumps(payload).encode()))
        original = Path(made["path"])
        original.rename(source / original.name)
    source_bytes = sum(path.stat().st_size for path in source.iterdir())
    assert source_bytes > 64 * 1024 * 1024
    extra = ("--from-memory-version", "v1")
    first = successful(invoke(home, "migrate", version="v2", extra=extra))
    assert first["copied"] == 68 and first["duplicate_skip"] == 0
    retry = successful(invoke(home, "migrate", version="v2", extra=extra))
    assert retry["copied"] == 0 and retry["duplicate_skip"] == 68
    assert not retry["storage_mutated"]
    listed = successful(invoke(home, "list", version="v2"))
    assert len(listed["notes"]) == 68
    destination = notes_dir(home, "v2")
    assert {path.name for path in source.iterdir()} == {path.name for path in destination.iterdir()}
    for path in source.iterdir():
        assert path.read_bytes() == (destination / path.name).read_bytes()
    reverse = successful(invoke(home, "migrate", extra=("--from-memory-version", "v2")))
    assert reverse["copied"] == 0 and reverse["duplicate_skip"] == 68


def main():
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    assert manifest["binary_version"] == "0.2.0"
    with tempfile.TemporaryDirectory(prefix="memory-note-upgrade-") as temporary:
        root = Path(temporary).resolve()
        for note in manifest["notes"]:
            legacy_roundtrip(root / "legacy", note)
        harness = next(note for note in manifest["notes"] if note["extension"] == "harness")
        offline_and_reverse(root / "legacy", harness)
        large_inventory(root, harness)
    print("memory-note 0.2.0 admissions, offline selection, reverse migration, and large retry: pass")


if __name__ == "__main__":
    main()
