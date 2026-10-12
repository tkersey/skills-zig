#!/usr/bin/env python3
"""Portable process-death witnesses for the real development memory-note CLI."""

import fcntl
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time


def command(binary, home, verb, *options):
    return [
        str(binary), verb, "--codex-home", str(home), "--memory-version", "v2",
        "--extension", "harness", *options,
    ]


def run_json(argv):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, (argv, result.returncode, result.stderr)
    return json.loads(result.stdout)


def interrupted_migration(binary, home):
    source = home / "memories/extensions/harness/notes"
    target = home / "memories_v2/extensions/harness/notes"
    staging = target.parent / ".memory-note-staging"
    source.mkdir(parents=True)
    count = 1024
    for index in range(count):
        envelope = {
            "schema": "memory-source-note/v1", "id": f"MSN-20261011T000000Z-{index:016x}",
            "captured_at": "2026-10-11T00:00:00Z", "extension": "harness",
            "kind": "harness-rule", "operation": "assert", "summary": "fixture",
            "fingerprint": f"{index:064x}", "authority": "test-fixture",
            "scope": {"kind": "global", "repo": None, "paths": []},
            "source_refs": [{"kind": "test", "ref": "recovery", "summary": "fixture"}],
            "related_ids": [],
            "supersedes_id": None, "payload": {"evidence": "x" * 2048},
        }
        (source / f"{index:04d}.md").write_text(json.dumps(envelope) + "\n")
    argv = command(binary, home, "migrate", "--from-memory-version", "v1")
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if process.poll() is not None:
                stdout, stderr = process.communicate()
                raise AssertionError(("migration finished before the interruption witness",
                                      process.returncode, stdout, stderr))
            if target.exists() and next(target.glob("*.md"), None) is not None:
                process.send_signal(signal.SIGSTOP)
                _, status = os.waitpid(process.pid, os.WUNTRACED)
                assert os.WIFSTOPPED(status), status
                break
            time.sleep(0.001)
        else:
            raise AssertionError("migration did not reach publication")
        completed = len(list(target.glob("*.md")))
        assert 0 < completed < count, completed
        # Represent a writer killed in the middle of the portable named-stage
        # write. Those bytes must never enter the admission inventory.
        abandoned = staging / "abandoned-partial"
        abandoned.write_bytes(b'{"partial":')
        process.kill()
        process.communicate(timeout=5)
        assert process.returncode == -signal.SIGKILL, process.returncode
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=5)
    lock = home / ".memory-note/locks/harness.lock"
    assert lock.read_bytes() == b"memory-note-extension-lock/v1\n"
    recovered = run_json(argv)
    assert recovered["copied"] == count - completed, recovered
    assert recovered["duplicate_skip"] == completed, recovered
    assert len(list(target.iterdir())) == count
    for original in source.iterdir():
        published = target / original.name
        assert published.read_bytes() == original.read_bytes()
        assert stat.S_IMODE(published.stat().st_mode) == 0o600
    assert abandoned.read_bytes() == b'{"partial":'
    retry = run_json(argv)
    assert retry["copied"] == 0 and retry["duplicate_skip"] == count, retry
    with lock.open("rb") as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        busy = subprocess.run(argv, capture_output=True, text=True, timeout=10)
        assert busy.returncode == 6 and "MemoryNoteBusy" in busy.stderr, busy


def legacy_lock_is_not_stolen(binary, home):
    lock = home / ".memory-note/locks/harness.lock"
    lock.parent.mkdir(parents=True)
    lock.write_bytes(b"")
    result = subprocess.run(
        command(binary, home, "migrate", "--from-memory-version", "v1"),
        capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 6 and "LegacyLockNeedsReview" in result.stderr, result
    assert lock.read_bytes() == b""
    assert not (home / "memories_v2").exists()


def empty_migration_reports_control_creation(binary, home):
    argv = command(binary, home, "migrate", "--from-memory-version", "v1")
    dry_run = run_json([*argv, "--dry-run"])
    assert not dry_run["storage_mutated"] and not home.exists(), dry_run
    first = run_json(argv)
    assert first["copied"] == 0 and first["storage_mutated"], first
    assert (home / ".memory-note/locks/harness.lock").is_file()
    second = run_json(argv)
    assert second["copied"] == 0 and not second["storage_mutated"], second
    assert not (home / "memories_v2").exists()


def duplicate_append_rejects_symlink(binary, root):
    fixture = Path(__file__).resolve().parent.parent / "fixtures/valid/harness-rule-input.json"
    home = root / "real"
    options = ("--kind", "harness-rule", "--json", str(fixture))
    assert run_json(command(binary, home, "append", *options))["status"] == "created"
    alias = root / "alias"
    alias.mkdir()
    (alias / "memories_v2").symlink_to(home / "memories_v2", target_is_directory=True)
    result = subprocess.run(
        command(binary, alias, "append", *options), capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 5 and "SymlinkComponent" in result.stderr, result
    assert not (alias / ".memory-note").exists()


def config_cleanup_is_bounded(binary, root):
    root.mkdir()
    child = root / "codex"
    pid_file = root / "pid"
    child.write_text(f"#!{sys.executable}\n" + '''
import json, os, signal, sys
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(os.environ["CONFIG_CHILD_PID"]).write_text(str(os.getpid()))
mode = os.environ["CONFIG_CHILD_MODE"]
if mode != "timeout":
    sys.stdin.readline()
    print('{"id":1,"result":{}}', flush=True)
    sys.stdin.readline()
    sys.stdin.readline()
    response = {"id":2,"result":{"config":{"memories":{"version":"v2"}}}}
    if mode == "reject":
        response = {"id":2,"error":{"message":"rejected"}}
    print(json.dumps(response), flush=True)
while True:
    signal.pause()
''')
    child.chmod(0o700)
    home = root / "home"
    for mode in ("success", "reject", "timeout"):
        env = dict(os.environ, CODEX_BIN=str(child), CONFIG_CHILD_PID=str(pid_file),
                   CONFIG_CHILD_MODE=mode)
        try:
            started = time.monotonic()
            result = subprocess.run(
                [str(binary), "path", "--codex-home", str(home), "--extension", "harness"],
                capture_output=True, text=True, env=env, timeout=15,
            )
            elapsed = time.monotonic() - started
            assert elapsed < (15 if mode == "timeout" else 5), (mode, elapsed)
            if mode == "success":
                assert result.returncode == 0 and "memories_v2" in result.stdout, result
            else:
                expected = "CodexConfigTimeout" if mode == "timeout" else "CodexConfigRejected"
                assert result.returncode != 0 and expected in result.stderr, result
            pid = int(pid_file.read_text())
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError(("config child was not reaped", mode, pid))
            assert not home.exists()
        finally:
            if pid_file.exists():
                try:
                    os.kill(int(pid_file.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
                pid_file.unlink()


def main():
    binary = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="memory-note-recovery-") as raw:
        root = Path(raw).resolve()
        interrupted_migration(binary, root / "recovery")
        legacy_lock_is_not_stolen(binary, root / "legacy")
        empty_migration_reports_control_creation(binary, root / "empty")
        duplicate_append_rejects_symlink(binary, root / "duplicate")
        config_cleanup_is_bounded(binary, root / "config")
    print("memory-note interrupted publication, kernel lock recovery, and path safety: pass")


if __name__ == "__main__":
    main()
