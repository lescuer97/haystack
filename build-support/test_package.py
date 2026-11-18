"""Small package-filter fixtures; never invoke the full test-package build."""
from pathlib import Path
import io
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

import check_package as package

ROOT = Path(__file__).resolve().parent.parent


class PackageTests(unittest.TestCase):
    def test_generated_and_private_paths_are_excluded_independently_of_manifest(self):
        for name in ("browser/wallet/target/a", "vendor/cdk-wallet-ffi/target/a",
                     ".git/config", ".zig-cache/tools/a", "zig-out/a", "zig-out-release/a",
                     "zig-pkg/a", "node_modules/a", "build-support/__pycache__/a.pyc",
                     "repros/a", "profiles/a", ".env", ".env.local", "wallet.sqlite",
                     "wallet.db-wal", "haystack.sqlite3-wal", "haystack.sqlite3-shm", "private.key", "run.log"):
            with self.subTest(name=name):
                self.assertTrue(package.excluded(name))
        for name in (*package.REQUIRED, "assets/real.png", "untracked-source.js"):
            self.assertFalse(package.excluded(name), name)

    def test_symlink_source_is_rejected_without_dereferencing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "link").symlink_to(ROOT)
            with self.assertRaisesRegex(RuntimeError, "unsupported source input"):
                package.source_tar(source, root / "input.tar")

    @unittest.skipUnless(shutil.which("zig"), "Zig required for actual filter fixture")
    def test_actual_zig_filter_and_missing_bridge_regression(self):
        zig = shutil.which("zig")
        cache = package.default_global_cache(zig)
        base = Path("/tmp/opencode")
        with tempfile.TemporaryDirectory(dir=base if base.is_dir() else None) as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            for name in (*package.REQUIRED, "unlisted-source.js", "browser/wallet/target/output",
                         ".env", "assets/real.png"):
                file = source / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(f"working-tree contents: {name}", encoding="utf-8")
            manifest = source / "build.zig.zon"
            def write_manifest(names):
                manifest.write_text('.{ .name = .probe, .version = "0.0.0", '
                                    '.fingerprint = 0xd75e6f2a25e501e7, .paths = .{'
                                    + ', '.join(f'"{name}"' for name in names) + '} }', encoding="utf-8")

            write_manifest((*package.REQUIRED, "assets"))
            scratch = root / "good"
            scratch.mkdir()
            archive, hash_value = package.fetch_filtered(source, scratch, zig, cache)
            with tarfile.open(scratch / "working-tree.tar") as input_tar:
                self.assertIn("unlisted-source.js", input_tar.getnames())
                self.assertIn("assets/real.png", input_tar.getnames())
                self.assertNotIn("browser/wallet/target/output", input_tar.getnames())
                self.assertNotIn(".env", input_tar.getnames())
            with tarfile.open(archive) as filtered:
                self.assertNotIn(f"{hash_value}/unlisted-source.js", filtered.getnames())
                bridge = filtered.extractfile(f"{hash_value}/browser/game-onboarding.js").read()
                self.assertEqual(bridge, b"working-tree contents: browser/game-onboarding.js")
            package.validate_package(archive, hash_value)

            # Mutate only this disposable fixture's actual manifest, then fetch
            # again: a fake/manual allowlist copy cannot satisfy this regression.
            for index, missing in enumerate(("browser/game-onboarding.js", "shared/world.zig", "server/main.zig")):
                with self.subTest(missing=missing):
                    write_manifest(name for name in package.REQUIRED if name != missing)
                    scratch = root / f"bad-{index}"
                    scratch.mkdir()
                    archive, hash_value = package.fetch_filtered(source, scratch, zig, cache)
                    with self.assertRaisesRegex(RuntimeError, f"missing required package inputs: {missing}"):
                        package.validate_package(archive, hash_value)

    def test_output_membership_rejects_artifacts_before_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "bad.tar"
            with tarfile.open(archive, "w") as output:
                member = tarfile.TarInfo("hash/browser/wallet/target/output")
                member.size = 1
                output.addfile(member, io.BytesIO(b"x"))
            with self.assertRaisesRegex(RuntimeError, "generated/private package member"):
                package.validate_package(archive, "hash")

    def test_renamed_browser_inputs_are_required(self):
        for missing in ("browser/game-ui.js", "browser/wallet-integration.js",
                        "browser/wallet-test.html", "browser/app.js"):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as temporary:
                self.assertIn(missing, package.REQUIRED)
                archive = Path(temporary) / "missing.tar"
                with tarfile.open(archive, "w") as output:
                    for name in package.REQUIRED:
                        if name != missing:
                            output.addfile(tarfile.TarInfo(f"hash/{name}"))
                with self.assertRaisesRegex(RuntimeError, f"missing required package inputs: {missing}"):
                    package.validate_package(archive, "hash")

    def test_missing_shared_server_and_vendor_inputs_are_rejected(self):
        base = Path("/tmp/opencode")
        for missing in ("shared/world.zig", "server/main.zig", "build/server.zig", "build/shared.zig",
                        "server/ws_auth.zig", "server/world_state.zig", "server/world_state_tests.zig"):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory(dir=base if base.is_dir() else None) as temporary:
                self.assertIn(missing, package.REQUIRED)
                archive = Path(temporary) / "missing.tar"
                with tarfile.open(archive, "w") as output:
                    for name in package.REQUIRED:
                        if name != missing:
                            output.addfile(tarfile.TarInfo(f"hash/{name}"))
                with self.assertRaisesRegex(RuntimeError, f"missing required package inputs: {missing}"):
                    package.validate_package(archive, "hash")

    def test_command_failure_is_not_reported_as_success(self):
        with mock.patch.object(package.subprocess, "Popen") as launch:
            process = launch.return_value.__enter__.return_value
            process.communicate.return_value = ("broken\n", None)
            process.returncode = 7
            with self.assertRaisesRegex(RuntimeError, "stage failed \\(7\\)"):
                package.run(["zig", "build", "browser"], ROOT)

    def test_command_timeout_is_bounded_and_identifies_stage(self):
        with mock.patch.object(package.subprocess, "Popen") as launch, mock.patch.object(package.os, "killpg") as kill:
            process = launch.return_value.__enter__.return_value
            process.communicate.side_effect = [subprocess.TimeoutExpired("zig", 1), ("partial log\n", None)]
            with self.assertRaisesRegex(RuntimeError, "stage timed out after 1s.*browser"):
                package.run(["zig", "build", "browser"], ROOT, timeout=1)
            kill.assert_called_once_with(process.pid, package.signal.SIGKILL)

    def test_package_step_is_explicit_and_nonrecursive(self):
        source = (ROOT / "build.zig").read_text(encoding="utf-8")
        self.assertIn('b.step("test-package"', source)
        self.assertIn('"build-support/check_package.py"', source)
        self.assertNotIn('dependOn(&package_check.step)', source.split('b.step("test-package"')[0])
        self.assertEqual(source.count("dependOn(&package_check.step)"), 1)
        self.assertFalse(Path(package.__file__).name.startswith("test_"))
        # The explicit script builds test-build, never itself or the full
        # browser suite with its known failures/public-mint restrictions.
        script = (ROOT / "build-support/check_package.py").read_text(encoding="utf-8")
        self.assertNotIn('["test-package"', script)
        self.assertIn('["browser", "-Dplatform=wasm"', script)
        self.assertIn('["server", "test-server", "-Dgame=false"]', script)
        self.assertIn('"--system", str(pkg_dir)', script)


if __name__ == "__main__":
    unittest.main()
