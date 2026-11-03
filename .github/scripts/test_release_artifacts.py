import io
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile

import release_artifacts as release


def pe_image(machine=0x8664, characteristics=0x2):
    data = bytearray(128)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 64)
    data[64:68] = b"PE\0\0"
    struct.pack_into("<H", data, 68, machine)
    struct.pack_into("<H", data, 86, characteristics)
    struct.pack_into("<H", data, 88, 0x20B)
    return bytes(data)


class ReleaseArtifactsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.assets = self.root / "release-assets"
        self.assets.mkdir()
        self.app = "lift"
        self.tag = "lift-v1.2.3"
        version = self.root / "apps" / self.app / "VERSION"
        version.parent.mkdir(parents=True)
        version.write_text("1.2.3\n")

    def zip(self, names=None, data=None, mode=stat.S_IFREG | 0o755):
        path = self.assets / f"{self.tag}-windows-x86_64.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w") as archive:
                for name in names if names is not None else ["lift-bench-stats.exe"]:
                    member = zipfile.ZipInfo(name)
                    member.create_system = 3
                    member.external_attr = mode << 16
                    archive.writestr(member, pe_image() if data is None else data)
        return path

    def tar(self, platform, names=None, kind=tarfile.REGTYPE, executable=True):
        path = self.assets / f"{self.tag}-{platform}.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for name in names if names is not None else ["./lift-bench-stats"]:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.mode = 0o755 if executable else 0o644
                member.size = 4 if kind == tarfile.REGTYPE else 0
                member.linkname = "elsewhere" if kind != tarfile.REGTYPE else ""
                archive.addfile(member, io.BytesIO(b"test") if member.size else None)
        return path

    def complete_set(self):
        self.tar("linux-x86_64")
        self.tar("darwin-arm64")
        self.zip()

    def test_tag_must_match_version(self):
        self.assertEqual(release.release_tag(self.app, self.tag, self.root), (self.tag, "1.2.3"))
        for tag in ("lift-v0.0.0", "seq-v1.2.3", "../lift-v1.2.3"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.release_tag(self.app, tag, self.root)

    def test_exact_archive_set(self):
        self.complete_set()
        self.assertEqual(len(release.verify_set(self.assets, self.app, self.tag)), 3)

    def test_nested_download_layout(self):
        self.complete_set()
        for path in list(self.assets.glob(f"{self.tag}-*")):
            directory = self.assets / (path.name + "-artifact")
            directory.mkdir()
            path.rename(directory / path.name)
        self.assertEqual(len(release.verify_set(self.assets, self.app, self.tag)), 3)

    def test_missing_windows_archive_blocks_publication(self):
        self.tar("linux-x86_64")
        self.tar("darwin-arm64")
        with self.assertRaises(ValueError):
            release.verify_set(self.assets, self.app, self.tag)

    def test_unexpected_file_blocks_publication(self):
        self.complete_set()
        (self.assets / "stale.zip").write_bytes(b"stale")
        with self.assertRaises(ValueError):
            release.verify_set(self.assets, self.app, self.tag)

    def test_duplicate_asset_name_blocks_publication(self):
        self.complete_set()
        other = self.assets / "duplicate"
        other.mkdir()
        (other / f"{self.tag}-windows-x86_64.zip").write_bytes(self.zip().read_bytes())
        with self.assertRaises(ValueError):
            release.verify_set(self.assets, self.app, self.tag)

    def test_wrong_platform_cannot_satisfy_count(self):
        self.complete_set()
        path = self.assets / f"{self.tag}-darwin-arm64.tar.gz"
        path.rename(self.assets / f"{self.tag}-darwin-x86_64.tar.gz")
        with self.assertRaises(ValueError):
            release.verify_set(self.assets, self.app, self.tag)

    def test_windows_payload_is_exact(self):
        for names in ([], ["bench_stats.exe"], ["../lift-bench-stats.exe"],
                      ["lift-bench-stats.exe", "lift-bench-stats.exe"],
                      ["lift-bench-stats.exe", "debug.pdb"]):
            with self.subTest(names=names), self.assertRaises(ValueError):
                release.verify_archive(self.zip(names), self.app, "windows-x86_64")

    def test_windows_rejects_non_executable_and_other_architecture(self):
        for data in (b"", b"ELF", pe_image(0xAA64), pe_image(characteristics=0x2002),
                     pe_image(characteristics=0)):
            with self.subTest(data=data[:4]), self.assertRaises(ValueError):
                release.verify_archive(self.zip(data=data), self.app, "windows-x86_64")

    def test_windows_rejects_link_or_special_file(self):
        for mode in (stat.S_IFLNK | 0o755, stat.S_IFIFO | 0o644):
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                release.verify_archive(self.zip(mode=mode), self.app, "windows-x86_64")

    def test_unix_rejects_links_and_nonexecutable_files(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                release.verify_archive(self.tar("linux-x86_64", kind=kind), self.app, "linux-x86_64")
        with self.assertRaises(ValueError):
            release.verify_archive(self.tar("linux-x86_64", executable=False), self.app, "linux-x86_64")

    def test_unix_rejects_duplicates_traversal_and_root_links(self):
        for names in (["lift-bench-stats", "lift-bench-stats"], ["../lift-bench-stats"], ["."]):
            with self.subTest(names=names), self.assertRaises(ValueError):
                release.verify_archive(self.tar("linux-x86_64", names), self.app, "linux-x86_64")

    def test_native_process_failure_is_not_success(self):
        with self.assertRaises(subprocess.CalledProcessError) as failure:
            release.run_checked([sys.executable, "-c", "raise SystemExit(7)"])
        self.assertEqual(failure.exception.returncode, 7)

    def test_cross_compilation_is_not_native_qualification(self):
        with mock.patch.object(sys, "platform", "linux"), self.assertRaises(ValueError):
            release.qualify_windows(self.app, self.tag)

    def test_failed_test_never_builds_or_packages(self):
        failure = subprocess.CalledProcessError(1, ["zig", "build"])
        with mock.patch.object(sys, "platform", "win32"), \
             mock.patch.object(release, "ROOT", self.root), \
             mock.patch.object(release, "run_checked", side_effect=failure) as run, \
             self.assertRaises(subprocess.CalledProcessError):
            release.qualify_windows(self.app, self.tag)
        self.assertEqual(run.call_count, 1)
        self.assertFalse(list(self.root.glob("*.zip")))

    def test_windows_build_follows_both_test_modes(self):
        source = self.root / "zig-out" / "bin" / "bench_stats.exe"
        source.parent.mkdir(parents=True)
        source.write_bytes(pe_image())
        with mock.patch.object(sys, "platform", "win32"), \
             mock.patch.object(release, "ROOT", self.root), \
             mock.patch.object(release, "run_checked") as run, \
             mock.patch.object(release, "smoke_windows") as smoke, \
             mock.patch.dict(os.environ, {}, clear=True):
            release.qualify_windows(self.app, self.tag)
        self.assertEqual(run.call_count, 3)
        self.assertIn("-Doptimize=debug", run.call_args_list[0].args[0])
        self.assertIn("-Doptimize=safe", run.call_args_list[1].args[0])
        self.assertIn("build-lift", run.call_args_list[2].args[0])
        self.assertIn("-Doptimize=fast", run.call_args_list[2].args[0])
        self.assertEqual(smoke.call_count, 1)
        release.verify_archive(self.root / f"{self.tag}-windows-x86_64.zip", self.app, "windows-x86_64")


if __name__ == "__main__":
    unittest.main()
