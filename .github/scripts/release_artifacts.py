#!/usr/bin/env python3
"""Qualify native Windows releases and admit only the exact published asset set."""

import argparse
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile

APPS = ("seq", "lift", "ledger", "memory-note", "siwc")
PLATFORMS = ("linux-x86_64", "darwin-arm64", "windows-x86_64")
ROOT = Path(__file__).resolve().parents[2]


def payload_name(app, windows=False):
    name = "lift-bench-stats" if app == "lift" else app
    return name + (".exe" if windows else "")


def release_tag(app, tag, root=ROOT):
    version = (root / "apps" / app / "VERSION").read_text().strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", version):
        raise ValueError(f"Invalid {app} VERSION: {version!r}")
    expected = f"{app}-v{version}"
    if tag is not None and tag != expected:
        raise ValueError(f"Expected tag {expected}, got {tag}")
    return expected, version


def require_windows_image(data):
    if len(data) < 64 or data[:2] != b"MZ":
        raise ValueError("Windows payload is not a PE executable")
    offset = struct.unpack_from("<I", data, 0x3C)[0]
    if offset > len(data) - 26 or data[offset:offset + 4] != b"PE\0\0":
        raise ValueError("Invalid PE header")
    machine = struct.unpack_from("<H", data, offset + 4)[0]
    characteristics = struct.unpack_from("<H", data, offset + 22)[0]
    magic = struct.unpack_from("<H", data, offset + 24)[0]
    if (machine != 0x8664 or magic != 0x20B or
            not characteristics & 0x2 or characteristics & 0x2000):
        raise ValueError("Windows payload must be an x86_64 PE32+ executable, not a DLL")


def verify_archive(path, app, platform):
    expected = payload_name(app, platform == "windows-x86_64")
    if platform == "windows-x86_64":
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            if len(members) != 1 or members[0].filename != expected:
                raise ValueError(f"{path}: expected exactly {expected}")
            member = members[0]
            mode = member.external_attr >> 16
            if (member.is_dir() or stat.S_IFMT(mode) not in (0, stat.S_IFREG) or
                    member.file_size == 0):
                raise ValueError(f"{path}: payload must be a nonempty regular file")
            data = archive.read(member)
            require_windows_image(data)
            return data
    with tarfile.open(path, "r:gz") as archive:
        all_members = archive.getmembers()
        roots = [m for m in all_members if m.name in (".", "./")]
        if len(roots) > 1 or any(not m.isdir() for m in roots):
            raise ValueError(f"{path}: invalid archive root entry")
        members = [m for m in all_members if m.name not in (".", "./")]
        if len(members) != 1:
            raise ValueError(f"{path}: expected exactly {expected}")
        member = members[0]
        if member.name not in (expected, "./" + expected):
            raise ValueError(f"{path}: unexpected member {member.name!r}")
        if not member.isfile() or not member.mode & 0o111 or member.size == 0:
            raise ValueError(f"{path}: payload must be a nonempty regular executable")
    return None


def verify_set(directory, app, tag):
    expected = {
        f"{tag}-{platform}.{'zip' if platform == 'windows-x86_64' else 'tar.gz'}": platform
        for platform in PLATFORMS
    }
    files = sorted(p for p in directory.rglob("*") if p.is_file() or p.is_symlink())
    if len(files) != len(expected) or {p.name for p in files} != set(expected):
        raise ValueError(f"Expected exactly {sorted(expected)}, found {[p.name for p in files]}")
    for path in files:
        if path.is_symlink():
            raise ValueError(f"Release artifact must not be a link: {path}")
        verify_archive(path, app, expected[path.name])
    return files


def run_checked(argv, **kwargs):
    return subprocess.run([str(arg) for arg in argv], check=True, **kwargs)


def smoke_windows(executable, version, cwd):
    # The shipped binary must not accidentally depend on Git Bash, Zig, or MinGW DLLs.
    environment = os.environ.copy()
    system_root = Path(environment["SystemRoot"])
    environment["PATH"] = os.pathsep.join((str(system_root / "System32"), str(system_root)))
    result = run_checked(
        [executable, "--version"], cwd=cwd, env=environment,
        capture_output=True, text=True, timeout=30,
    )
    if result.stdout.strip() != version:
        raise ValueError(f"Extracted executable version {result.stdout!r} != {version!r}")
    run_checked([executable, "--help"], cwd=cwd, env=environment, timeout=30)


def qualify_windows(app, tag):
    if sys.platform != "win32":
        raise ValueError("Windows release qualification must execute on native Windows")
    tag, version = release_tag(app, tag, ROOT)
    options = ["-Dtarget=x86_64-windows-gnu", "-Dcpu=baseline", "-j2", "--summary", "all"]
    tests = [f"test-{app}"]
    if app == "seq":
        tests += ["test-seq-core", "test-seq-cli-smoke"]
    for mode in ("debug", "safe"):
        run_checked(["zig", "build", *tests, f"-Doptimize={mode}", *options], cwd=ROOT)
    run_checked(["zig", "build", f"build-{app}", "-Doptimize=fast", *options], cwd=ROOT)
    source = ROOT / "zig-out" / "bin" / ("bench_stats.exe" if app == "lift" else app + ".exe")
    if source.is_symlink() or not source.is_file():
        raise ValueError(f"Missing regular Windows executable: {source}")
    require_windows_image(source.read_bytes())
    output = ROOT / f"{tag}-windows-x86_64.zip"
    with tempfile.TemporaryDirectory(prefix="windows release ") as scratch:
        scratch = Path(scratch)
        candidate = scratch / output.name
        with zipfile.ZipFile(candidate, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.write(source, payload_name(app, True))
        data = verify_archive(candidate, app, "windows-x86_64")
        extracted = scratch / "extracted payload"
        extracted.mkdir()
        executable = extracted / payload_name(app, True)
        executable.write_bytes(data)
        smoke_windows(executable, version, extracted)
        shutil.copyfile(candidate, output)
    if "GITHUB_ENV" in os.environ:
        with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as environment:
            environment.write(f"RELEASE_ARCHIVE={output.name}\n")
    print(f"Qualified {output.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    windows = commands.add_parser("windows")
    windows.add_argument("app", choices=APPS)
    windows.add_argument("--tag")
    verify = commands.add_parser("verify-set")
    verify.add_argument("app", choices=APPS)
    verify.add_argument("tag")
    verify.add_argument("directory", type=Path)
    args = parser.parse_args()
    if args.command == "windows":
        qualify_windows(args.app, args.tag)
    else:
        release_tag(args.app, args.tag)
        for path in verify_set(args.directory, args.app, args.tag):
            print(path)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError, zipfile.BadZipFile) as error:
        print(f"Release qualification failed: {error}", file=sys.stderr)
        sys.exit(1)
