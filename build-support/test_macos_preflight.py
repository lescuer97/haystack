"""macOS preflight contracts: host, SDK, compiler and deployment-target checks.

They run on Linux too; the macOS commands are replaced by a fake runner, so no
macOS host, Xcode installation or network access is required.
"""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "macos_preflight", Path(__file__).with_name("macos-preflight.py")
)
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class FakeRunner:
    """Return canned CompletedProcess values keyed by the exact command list."""

    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def __call__(self, command, **kwargs):
        self.calls.append(tuple(command))
        try:
            returncode, stdout, stderr = self.responses[tuple(command)]
        except KeyError as error:
            raise AssertionError(f"unexpected command: {command}") from error
        return subprocess.CompletedProcess(command, returncode, stdout, stderr)


class HostTests(unittest.TestCase):
    def test_accepts_native_arm64(self):
        preflight.check_arm64("arm64", translated=False)

    def test_rejects_intel_and_universal_hosts(self):
        for machine in ("x86_64", "i386"):
            with self.assertRaisesRegex(preflight.PreflightError, "Apple Silicon"):
                preflight.check_arm64(machine)

    def test_rejects_rosetta_translation(self):
        with self.assertRaisesRegex(preflight.PreflightError, "Rosetta"):
            preflight.check_arm64("arm64", translated=True)

    def test_rejects_non_darwin_host(self):
        with self.assertRaisesRegex(preflight.PreflightError, "Darwin"):
            preflight.check_host("Linux", "x86_64")

    def test_rosetta_probe_is_safe_when_sysctl_reports_unknown(self):
        runner = FakeRunner({("sysctl", "-n", "-i", "sysctl.proc_translated"): (1, "", "unknown oid")})
        self.assertFalse(preflight.is_translated(runner))


class RunningVersionTests(unittest.TestCase):
    def test_accepts_running_os_at_or_above_deployment_target(self):
        self.assertEqual(preflight.check_running_version("15.0", "15.0"), (15, 0, 0))
        self.assertEqual(preflight.check_running_version("26.1", "15.0"), (26, 1, 0))

    def test_rejects_running_os_below_deployment_target(self):
        with self.assertRaisesRegex(preflight.PreflightError, "older than"):
            preflight.check_running_version("14.6", "15.0")

    def test_rejects_unparseable_running_version(self):
        with self.assertRaisesRegex(preflight.PreflightError, "parse"):
            preflight.check_running_version("unknown", "15.0")

    def test_reads_running_version_with_sw_vers(self):
        runner = FakeRunner({("sw_vers", "-productVersion"): (0, "15.3\n", "")})
        self.assertEqual(preflight.check_running_os(runner), "15.3")

    def test_missing_sw_vers_is_actionable(self):
        runner = FakeRunner({("sw_vers", "-productVersion"): (1, "", "not found")})
        with self.assertRaisesRegex(preflight.PreflightError, "sw_vers"):
            preflight.check_running_os(runner)


class XcodeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.developer = root / "CommandLineTools"
        self.sdk = root / "MacOSX15.0.sdk"
        self.clang = root / "clang"
        self.developer.mkdir()
        self.sdk.mkdir()
        self.clang.write_text("#!/bin/sh\n", encoding="utf-8")
        self.clang.chmod(0o755)

    def responses(self, *, developer=None, sdk_path=None, sdk_version="15.0", clang=None, clang_probe=0):
        clang = clang or self.clang
        return {
            ("xcode-select", "-p"): (0, f"{developer or self.developer}\n", ""),
            ("xcrun", "--sdk", "macosx", "--show-sdk-path"): (0, f"{sdk_path or self.sdk}\n", ""),
            ("xcrun", "--sdk", "macosx", "--show-sdk-version"): (0, f"{sdk_version}\n", ""),
            ("xcrun", "--sdk", "macosx", "--find", "clang"): (0, f"{clang}\n", ""),
            (str(clang), "--version"): (clang_probe, "Apple clang version 15.0.0\n" if clang_probe == 0 else "", "clang failed"),
        }

    def test_success_returns_sdk_path_version_and_clang(self):
        sdk_path, sdk_version, clang = preflight.check_xcode(FakeRunner(self.responses()))
        self.assertEqual(sdk_path, str(self.sdk))
        self.assertEqual(sdk_version, "15.0")
        self.assertEqual(clang, str(self.clang))

    def test_missing_command_line_tools_suggests_xcode_select_install(self):
        responses = self.responses()
        responses[("xcode-select", "-p")] = (1, "", "xcode-select: error: unable to get active developer directory")
        with self.assertRaisesRegex(preflight.PreflightError, "xcode-select --install"):
            preflight.check_xcode(FakeRunner(responses))

    def test_missing_sdk_suggests_reselecting_developer_directory(self):
        responses = self.responses()
        responses[("xcrun", "--sdk", "macosx", "--show-sdk-path")] = (1, "", "SDK not found")
        with self.assertRaisesRegex(preflight.PreflightError, "show-sdk-path"):
            preflight.check_xcode(FakeRunner(responses))

    def test_nonexistent_sdk_path_is_rejected(self):
        missing = Path(self.temporary.name) / "missing.sdk"
        with self.assertRaisesRegex(preflight.PreflightError, "does not exist"):
            preflight.check_xcode(FakeRunner(self.responses(sdk_path=missing)))

    def test_missing_clang_is_rejected(self):
        missing = Path(self.temporary.name) / "missing-clang"
        with self.assertRaisesRegex(preflight.PreflightError, "clang"):
            preflight.check_xcode(FakeRunner(self.responses(clang=missing)))

    def test_non_executable_clang_is_rejected(self):
        self.clang.chmod(0o644)
        with self.assertRaisesRegex(preflight.PreflightError, "executable"):
            preflight.check_xcode(FakeRunner(self.responses()))

    def test_clang_must_run(self):
        with self.assertRaisesRegex(preflight.PreflightError, "could not run"):
            preflight.check_xcode(FakeRunner(self.responses(clang_probe=1)))


class SdkRootTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sdk = self.root / "MacOSX15.0.sdk"
        self.other = self.root / "MacOSX14.0.sdk"
        self.sdk.mkdir()
        self.other.mkdir()

    def test_unset_sdkroot_uses_xcrun_sdk(self):
        self.assertEqual(preflight.check_sdkroot(str(self.sdk), {}), str(self.sdk))

    def test_matching_sdkroot_is_honored(self):
        self.assertEqual(
            preflight.check_sdkroot(str(self.sdk), {"SDKROOT": str(self.sdk)}),
            str(self.sdk),
        )

    def test_nonexistent_sdkroot_is_rejected(self):
        missing = self.root / "missing.sdk"
        with self.assertRaisesRegex(preflight.PreflightError, "does not exist"):
            preflight.check_sdkroot(str(self.sdk), {"SDKROOT": str(missing)})

    def test_conflicting_sdkroot_is_rejected(self):
        with self.assertRaisesRegex(preflight.PreflightError, "conflicts"):
            preflight.check_sdkroot(str(self.sdk), {"SDKROOT": str(self.other)})


class ExplicitCompilerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.clang = self.root / "clang"
        self.other = self.root / "other-cc"
        for path in (self.clang, self.other):
            path.write_text("#!/bin/sh\n", encoding="utf-8")
            path.chmod(0o755)

    def which(self, mapping):
        return lambda name: mapping.get(name)

    def check(self, environ, mapping):
        return preflight.check_selected_cc(
            str(self.clang),
            "aarch64-apple-darwin",
            "aarch64-apple-darwin",
            environ,
            self.which(mapping),
        )

    def test_unset_cc_checks_the_default_cc(self):
        self.assertEqual(
            self.check({}, {"cc": str(self.clang)}),
            str(self.clang),
        )

    def test_matching_cc_is_allowed(self):
        self.assertEqual(
            self.check({"CC": "clang"}, {"clang": str(self.clang)}),
            str(self.clang),
        )

    def test_target_specific_cc_is_selected_over_invalid_generic(self):
        environ = {
            "CC_aarch64-apple-darwin": "clang",
            "CC": "missing-cc",
        }
        self.assertEqual(
            self.check(environ, {"clang": str(self.clang)}),
            str(self.clang),
        )

    def test_underscore_target_specific_cc_is_selected(self):
        environ = {
            "CC_aarch64_apple_darwin": "clang",
            "CC": "missing-cc",
        }
        self.assertEqual(
            self.check(environ, {"clang": str(self.clang)}),
            str(self.clang),
        )

    def test_missing_active_target_specific_cc_is_rejected(self):
        environ = {
            "CC_aarch64-apple-darwin": "missing-cc",
            "CC": "clang",
        }
        with self.assertRaisesRegex(preflight.PreflightError, "CC_aarch64-apple-darwin"):
            self.check(environ, {"clang": str(self.clang)})

    def test_missing_cc_is_rejected(self):
        with self.assertRaisesRegex(preflight.PreflightError, "not found"):
            self.check({"CC": "missing-cc"}, {})

    def test_different_cc_is_rejected(self):
        with self.assertRaisesRegex(preflight.PreflightError, "not the clang"):
            self.check({"CC": "other-cc"}, {"other-cc": str(self.other)})

    def test_apple_system_clang_shim_is_allowed(self):
        result = preflight.check_selected_cc(
            "/Xcode/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
            "aarch64-apple-darwin",
            "aarch64-apple-darwin",
            {"CC": "/usr/bin/cc"},
            lambda name: "/usr/bin/cc" if name == "/usr/bin/cc" else None,
            lambda path: (
                "/usr/bin/clang"
                if str(path) == "/usr/bin/cc"
                else "/Xcode/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
            ),
        )
        self.assertEqual(result, "/usr/bin/cc")

    def test_wrapper_without_compiler_is_rejected(self):
        with self.assertRaisesRegex(preflight.PreflightError, "without a compiler"):
            self.check({"CC": "ccache"}, {"ccache": str(self.other)})

    def test_wrapper_underlying_compiler_is_checked(self):
        self.assertEqual(
            self.check(
                {"CC": "sccache clang"},
                {"sccache": str(self.other), "clang": str(self.clang)},
            ),
            str(self.clang),
        )
        with self.assertRaisesRegex(preflight.PreflightError, "not found"):
            self.check(
                {"CC": "sccache missing-clang"},
                {"sccache": str(self.other)},
            )


class SdkFlagTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sdk = self.root / "MacOSX15.0.sdk"
        self.other = self.root / "MacOSX14.0.sdk"
        self.sdk.mkdir()
        self.other.mkdir()

    def check(self, environ):
        return preflight.check_sdk_flags(
            str(self.sdk),
            "aarch64-apple-darwin",
            "aarch64-apple-darwin",
            environ,
        )

    def test_matching_generic_cflags_sdk_is_allowed(self):
        self.assertEqual(
            self.check({"CFLAGS": f"-isysroot {self.sdk}"}), str(self.sdk)
        )

    def test_conflicting_generic_cflags_sdk_is_rejected(self):
        with self.assertRaisesRegex(preflight.PreflightError, "different SDK"):
            self.check({"CFLAGS": f"-isysroot {self.other}"})

    def test_target_specific_cflags_conflict_is_rejected(self):
        environ = {
            "CFLAGS": f"-isysroot {self.sdk}",
            "CFLAGS_aarch64-apple-darwin": f"-isysroot {self.other}",
        }
        with self.assertRaisesRegex(
            preflight.PreflightError, "CFLAGS_aarch64-apple-darwin.*different SDK"
        ):
            self.check(environ)

    def test_host_cflags_conflict_is_rejected(self):
        with self.assertRaisesRegex(preflight.PreflightError, "HOST_CFLAGS.*different SDK"):
            self.check({"HOST_CFLAGS": f"--sysroot={self.other}"})

    def test_cc_arguments_sdk_conflict_is_rejected(self):
        with self.assertRaisesRegex(
            preflight.PreflightError, "CC compiler arguments.*different SDK"
        ):
            self.check({"CC": f"clang -isysroot {self.other}"})

    def test_shadowed_generic_cc_arguments_are_not_validated(self):
        environ = {
            "CC_aarch64-apple-darwin": "clang",
            "CC": f"clang -isysroot {self.other}",
        }
        self.assertEqual(self.check(environ), str(self.sdk))

    def test_target_specific_cc_arguments_conflict_is_rejected(self):
        environ = {
            "CC_aarch64-apple-darwin": f"clang -isysroot {self.other}",
            "CC": "clang",
        }
        with self.assertRaisesRegex(
            preflight.PreflightError, "CC_aarch64-apple-darwin.*different SDK"
        ):
            self.check(environ)

    def test_forms_and_repeated_matching_paths_are_allowed(self):
        environ = {
            "CFLAGS": (
                f"-isysroot {self.sdk} "
                f"-isysroot{self.sdk} "
                f"--sysroot={self.sdk} "
                f"--sysroot {self.sdk}"
            )
        }
        self.assertEqual(self.check(environ), str(self.sdk))

    def test_two_distinct_override_paths_are_rejected(self):
        environ = {
            "CFLAGS": f"-isysroot {self.sdk} --sysroot={self.other}",
        }
        with self.assertRaisesRegex(preflight.PreflightError, "different SDK"):
            self.check(environ)

    def test_malformed_empty_override_is_rejected(self):
        for value in ("-isysroot", "--sysroot", "--sysroot="):
            with self.subTest(value=value):
                with self.assertRaisesRegex(preflight.PreflightError, "without a path|empty path"):
                    self.check({"CFLAGS": value})

    def test_relative_override_is_rejected(self):
        with self.assertRaisesRegex(preflight.PreflightError, "absolute"):
            self.check({"CFLAGS": "-isysroot relative.sdk"})


class DeploymentTargetTests(unittest.TestCase):
    def test_accepts_sdk_newer_than_minimum(self):
        self.assertEqual(preflight.check_deployment_target("15.0", "26.0"), (15, 0, 0))

    def test_rejects_deployment_target_below_supported_minimum(self):
        with self.assertRaisesRegex(preflight.PreflightError, "15.0"):
            preflight.check_deployment_target("14.6", "15.0")

    def test_rejects_sdk_older_than_requested_target(self):
        with self.assertRaisesRegex(preflight.PreflightError, "older"):
            preflight.check_deployment_target("16.0", "15.0")

    def test_rejects_unparseable_versions(self):
        with self.assertRaisesRegex(preflight.PreflightError, "parse"):
            preflight.check_deployment_target("latest", "15.0")

    def test_build_and_preflight_share_pinned_minimum(self):
        root = Path(__file__).resolve().parent.parent
        platform_source = (root / "build" / "platform.zig").read_text(encoding="utf-8")
        self.assertIn('macos_deployment_target = "15.0"', platform_source)
        self.assertEqual(preflight.MIN_MACOS_TEXT, "15.0")


if __name__ == "__main__":
    unittest.main()
