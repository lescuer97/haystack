"""Contract tests for the pinned CI Zig installer."""
import hashlib
import importlib.util
import io
import re
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location(
    "install_zig", Path(__file__).with_name("install-zig.py")
)
install_zig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(install_zig)

TOP = "zig-x86_64-linux-0.17.0"


def make_archive(path, members):
    with tarfile.open(path, "w:xz") as archive:
        for name, data, mode in members:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = mode
            archive.addfile(info, io.BytesIO(data))
    return Path(path).read_bytes()


def fixture_archive(tmp):
    return make_archive(
        Path(tmp) / "zig.tar.xz",
        [
            (f"{TOP}/zig", b"#!/bin/sh\nexit 0\n", 0o755),
            (f"{TOP}/lib/readme.txt", b"pinned zig\n", 0o644),
        ],
    )


class SelectionTests(unittest.TestCase):
    def test_pinned_hashes_and_keys(self):
        linux = install_zig.select_artifact("0.17.0", "Linux", "x86_64")
        macos = install_zig.select_artifact("0.17.0", "Darwin", "arm64")
        self.assertEqual(linux.key, "x86_64-linux")
        self.assertEqual(
            linux.sha256,
            "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026",
        )
        self.assertEqual(macos.key, "aarch64-macos")
        self.assertEqual(
            macos.sha256,
            "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a",
        )

    def test_rejects_wrong_version(self):
        with self.assertRaisesRegex(install_zig.InstallError, "pins 0.17.0"):
            install_zig.select_artifact("0.16.0", "Linux", "x86_64")

    def test_rejects_unsupported_platform_without_fallback(self):
        for system, machine in (
            ("Windows", "AMD64"),
            ("Linux", "riscv64"),
            ("Darwin", "x86_64"),
        ):
            with self.subTest(system=system, machine=machine):
                with self.assertRaisesRegex(install_zig.InstallError, "no pinned"):
                    install_zig.select_artifact("0.17.0", system, machine)


class InstallTests(unittest.TestCase):
    def test_checksum_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive_bytes = fixture_archive(tmp)
            artifact = install_zig.Artifact("x86_64-linux", "0" * 64)
            calls = []

            def downloader(url, dest):
                calls.append((url, dest))
                Path(dest).write_bytes(archive_bytes)

            with self.assertRaisesRegex(
                install_zig.InstallError, "checksum mismatch"
            ):
                install_zig.install_artifact(
                    artifact, downloader=downloader, work_dir=Path(tmp) / "work"
                )
            self.assertEqual(len(calls), 1)

    def test_installs_valid_archive_and_writes_github_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive_bytes = fixture_archive(tmp)
            digest = hashlib.sha256(archive_bytes).hexdigest()
            artifact = install_zig.Artifact("x86_64-linux", digest)
            github_path = Path(tmp) / "github-path"

            def downloader(url, dest):
                self.assertEqual(
                    url,
                    "https://ziglang.org/download/0.17.0/"
                    "zig-x86_64-linux-0.17.0.tar.xz",
                )
                Path(dest).write_bytes(archive_bytes)

            zig = install_zig.install_artifact(
                artifact,
                downloader=downloader,
                github_path=github_path,
                work_dir=Path(tmp) / "work",
            )
            self.assertTrue(zig.is_file())
            self.assertTrue(zig.parent.name == TOP)
            self.assertEqual(
                github_path.read_text(encoding="utf-8"),
                f"{zig.parent}\n",
            )

    def test_safe_extract_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "escape.tar.xz"
            make_archive(archive, [("../escape", b"bad", 0o644)])
            with self.assertRaisesRegex(install_zig.InstallError, "escapes"):
                install_zig.safe_extract(archive, Path(tmp) / "extract")

    def test_safe_extract_rejects_symlink_escape(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "link.tar.xz"
            with tarfile.open(archive, "w:xz") as tar:
                info = tarfile.TarInfo(f"{TOP}/link")
                info.type = tarfile.SYMTYPE
                info.linkname = "../../outside"
                tar.addfile(info)
            with self.assertRaisesRegex(install_zig.InstallError, "link escapes"):
                install_zig.safe_extract(archive, Path(tmp) / "extract")


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        workflow = ROOT / ".github" / "workflows" / "ci.yml"
        if not workflow.exists():
            self.skipTest("CI workflow is not part of the packaged source tree")
        self.workflow = workflow.read_text(encoding="utf-8")

    def test_every_job_uses_the_pinned_installer(self):
        self.assertEqual(
            self.workflow.count("build-support/install-zig.py"),
            3,
            "all three CI jobs must use the shared installer",
        )
        self.assertNotIn("urllib.request", self.workflow)
        self.assertNotIn("ziglang.org/download/index.json", self.workflow)

    def test_checkouts_disable_persisted_credentials(self):
        self.assertEqual(self.workflow.count("uses: actions/checkout@"), 3)
        self.assertEqual(self.workflow.count("persist-credentials: false"), 3)

    def test_actions_are_pinned_to_full_commit_shas(self):
        uses = re.findall(r"uses:\s*([^\s#]+)", self.workflow)
        self.assertTrue(uses, "workflow has action uses")
        for action in uses:
            self.assertRegex(
                action,
                r"^[^\s@]+@[0-9a-f]{40}$",
                f"action is not pinned by full commit SHA: {action}",
            )


if __name__ == "__main__":
    unittest.main()
