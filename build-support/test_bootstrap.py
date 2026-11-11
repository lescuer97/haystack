"""Provisioning contracts: cached/offline builds must not install or update tools."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("bootstrap", Path(__file__).with_name("bootstrap.py"))
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)

RUST_VERSION = "rustc 1.99.0 (b940084d7 2026-09-28)\n"
RUST_HOST = "host: x86_64-unknown-linux-gnu\n"


def rust_vv(host=RUST_HOST):
    return RUST_VERSION + host + "release: 1.99.0\n"


class RustSetupTests(unittest.TestCase):
    def invoke(
        self,
        installed,
        probe=0,
        offline=False,
        host=RUST_HOST,
        host_os="linux",
        host_arch="x86_64",
        target="wasm32-unknown-unknown",
        require_native_c=False,
    ):
        def fake_run(command, **kwargs):
            if command[:3] == ["rustup", "run", "1.99.0"]:
                if command[-1] == "--version":
                    return subprocess.CompletedProcess(command, probe, RUST_VERSION, "")
                if command[-1] == "-vV":
                    return subprocess.CompletedProcess(command, 0, rust_vv(host), "")
            raise AssertionError(f"unexpected command: {command}")

        with patch.object(bootstrap, "require_tool"), \
             patch.object(bootstrap.subprocess, "run", side_effect=fake_run), \
             patch.object(bootstrap.subprocess, "check_output", return_value=installed), \
             patch.object(bootstrap, "run") as install:
            bootstrap.ensure_rust(
                "1.99.0",
                target,
                offline,
                host_os=host_os,
                host_arch=host_arch,
                require_native_c=require_native_c,
            )
            return install.call_args_list

    def test_installed_rust_and_target_do_not_download(self):
        self.assertEqual(self.invoke("wasm32-unknown-unknown\n", offline=True), [])

    def test_missing_target_installs_only_target(self):
        calls = self.invoke("x86_64-unknown-linux-gnu\n")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0].args, ("rustup", "target", "add", "wasm32-unknown-unknown", "--toolchain", "1.99.0"))

    def test_missing_toolchain_installs_pinned_minimal_toolchain(self):
        calls = self.invoke("wasm32-unknown-unknown\n", probe=1)
        self.assertEqual(calls[0].args, ("rustup", "toolchain", "install", "1.99.0", "--profile", "minimal", "--no-self-update"))

    def test_offline_missing_target_is_an_error(self):
        with self.assertRaisesRegex(RuntimeError, "target.*missing"):
            self.invoke("x86_64-unknown-linux-gnu\n", offline=True)

    def test_offline_missing_toolchain_is_an_error(self):
        with self.assertRaisesRegex(RuntimeError, "not installed"):
            self.invoke("", probe=1, offline=True)

    def test_wrong_compiler_os_or_architecture_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "not compatible"):
            self.invoke(
                "aarch64-unknown-linux-gnu\n",
                host="host: aarch64-unknown-linux-gnu\n",
                host_arch="x86_64",
            )

    def test_rosetta_compiler_host_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "Rosetta"):
            self.invoke(
                "x86_64-apple-darwin\n",
                host="host: x86_64-apple-darwin\n",
                host_os="macos",
                host_arch="aarch64",
            )

    def test_malformed_compiler_host_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "malformed|unsupported"):
            self.invoke("", host="host: not-a-triple\n")

    def test_gnu_host_to_musl_target_is_not_rejected_for_cross_abi(self):
        calls = self.invoke(
            "x86_64-unknown-linux-musl\n",
            host_os="linux",
            host_arch="x86_64",
            target="x86_64-unknown-linux-musl",
        )
        self.assertEqual(calls, [])

    def test_native_c_compiler_is_required_for_desktop(self):
        def fake_run(command, **kwargs):
            if command[:3] == ["rustup", "run", "1.99.0"]:
                return subprocess.CompletedProcess(command, 0, rust_vv(), "")
            if command == ["/usr/bin/cc", "--version"]:
                return subprocess.CompletedProcess(command, 0, "cc version\n", "")
            raise AssertionError(f"unexpected command: {command}")

        with patch.object(bootstrap, "require_tool"), \
             patch.object(bootstrap.subprocess, "run", side_effect=fake_run), \
             patch.object(bootstrap.subprocess, "check_output", return_value="x86_64-unknown-linux-gnu\n"), \
             patch.object(bootstrap, "run") as install, \
             patch.object(bootstrap.os, "environ", {}), \
             patch.object(bootstrap.shutil, "which", side_effect=lambda name: "/usr/bin/cc" if name == "cc" else None):
            bootstrap.ensure_rust(
                "1.99.0",
                "x86_64-unknown-linux-gnu",
                False,
                host_os="linux",
                host_arch="x86_64",
                require_native_c=True,
            )
            install.assert_not_called()


class NativeCCompilerTests(unittest.TestCase):
    def runner(self, responses):
        calls = []

        def run(command, **kwargs):
            calls.append(tuple(command))
            returncode, output = responses.get(tuple(command), (1, "missing"))
            return subprocess.CompletedProcess(
                command,
                returncode,
                output if returncode == 0 else "",
                "" if returncode == 0 else output,
            )

        return run, calls

    def which(self, mapping):
        return lambda name: mapping.get(name)

    def check(self, environ, runner, which, host="x86_64-unknown-linux-gnu", target=None):
        target = target or host
        return bootstrap.check_native_c_compiler(
            "linux", "x86_64", host, target, environ, runner, which
        )

    def test_linux_default_is_cc_and_does_not_fall_back_to_gcc(self):
        runner, calls = self.runner({})
        which = self.which({"gcc": "/usr/bin/gcc", "clang": "/usr/bin/clang"})
        with self.assertRaisesRegex(RuntimeError, "default native C compiler.*'cc'"):
            self.check({}, runner, which)
        self.assertEqual(calls, [])

    def test_target_specific_hyphen_beats_underscore_kind_and_generic(self):
        runner, calls = self.runner({("/hyphen/cc", "--version"): (0, "cc\n")})
        which = self.which(
            {
                "/hyphen/cc": "/hyphen/cc",
                "/underscore/cc": "/underscore/cc",
                "/host/cc": "/host/cc",
                "/generic/cc": "/generic/cc",
            }
        )
        environ = {
            "CC_x86_64-unknown-linux-gnu": "/hyphen/cc",
            "CC_x86_64_unknown_linux_gnu": "/underscore/cc",
            "HOST_CC": "/host/cc",
            "CC": "/generic/cc",
        }
        self.assertEqual(self.check(environ, runner, which), "/hyphen/cc")
        self.assertEqual(calls, [("/hyphen/cc", "--version")])

    def test_shadowed_generic_cc_is_not_validated_or_rejected(self):
        runner, calls = self.runner({("/good/cc", "--version"): (0, "cc\n")})
        which = self.which({"/good/cc": "/good/cc"})
        environ = {
            "CC_x86_64-unknown-linux-gnu": "/good/cc",
            "CC": "/missing/cc",
        }
        self.assertEqual(self.check(environ, runner, which), "/good/cc")
        self.assertEqual(calls, [("/good/cc", "--version")])

    def test_missing_active_override_is_not_replaced_by_generic(self):
        runner, calls = self.runner({("/generic/cc", "--version"): (0, "cc\n")})
        which = self.which({"/generic/cc": "/generic/cc"})
        environ = {
            "CC_x86_64-unknown-linux-gnu": "/missing/cc",
            "CC": "/generic/cc",
        }
        with self.assertRaisesRegex(RuntimeError, "CC_x86_64-unknown-linux-gnu.*not found"):
            self.check(environ, runner, which)
        self.assertEqual(calls, [])

    def test_cross_compilation_uses_target_cc_not_host_cc(self):
        runner, calls = self.runner({("/target/cc", "--version"): (0, "cc\n")})
        which = self.which({"/target/cc": "/target/cc"})
        environ = {"TARGET_CC": "/target/cc", "HOST_CC": "/missing/host-cc"}
        self.assertEqual(
            self.check(
                environ,
                runner,
                which,
                host="x86_64-unknown-linux-gnu",
                target="x86_64-unknown-linux-musl",
            ),
            "/target/cc",
        )
        self.assertEqual(calls, [("/target/cc", "--version")])

    def test_cross_compilation_without_cc_override_fails_instead_of_using_cc(self):
        runner, calls = self.runner({("/usr/bin/cc", "--version"): (0, "cc\n")})
        which = self.which({"cc": "/usr/bin/cc"})
        with self.assertRaisesRegex(RuntimeError, "requires an explicit CC-family"):
            self.check(
                {},
                runner,
                which,
                host="x86_64-unknown-linux-gnu",
                target="x86_64-unknown-linux-musl",
            )
        self.assertEqual(calls, [])

    def test_explicit_cc_allows_cross_abi_without_host_abi_equality_rule(self):
        runner, calls = self.runner({("/musl/cc", "--version"): (0, "cc\n")})
        which = self.which({"/musl/cc": "/musl/cc"})
        self.assertEqual(
            self.check(
                {"CC": "/musl/cc"},
                runner,
                which,
                host="x86_64-unknown-linux-gnu",
                target="x86_64-unknown-linux-musl",
            ),
            "/musl/cc",
        )
        self.assertEqual(calls, [("/musl/cc", "--version")])

    def test_cross_target_specific_cc_is_selected_over_kind_and_generic(self):
        runner, calls = self.runner({("/target/cc", "--version"): (0, "cc\n")})
        which = self.which(
            {
                "/target/cc": "/target/cc",
                "/kind/cc": "/kind/cc",
                "/generic/cc": "/generic/cc",
            }
        )
        environ = {
            "CC_x86_64-unknown-linux-musl": "/target/cc",
            "TARGET_CC": "/kind/cc",
            "CC": "/generic/cc",
        }
        self.assertEqual(
            self.check(
                environ,
                runner,
                which,
                host="x86_64-unknown-linux-gnu",
                target="x86_64-unknown-linux-musl",
            ),
            "/target/cc",
        )
        self.assertEqual(calls, [("/target/cc", "--version")])

    def test_known_wrapper_validates_the_underlying_compiler(self):
        runner, calls = self.runner({("/usr/bin/cc", "-m32", "--version"): (0, "cc\n")})
        which = self.which({"sccache": "/usr/bin/sccache", "cc": "/usr/bin/cc"})
        self.assertEqual(
            self.check({"CC": "sccache cc -m32"}, runner, which),
            "/usr/bin/cc",
        )
        self.assertEqual(calls, [("/usr/bin/cc", "-m32", "--version")])

    def test_known_wrapper_with_missing_compiler_is_rejected(self):
        runner, calls = self.runner({})
        which = self.which({"sccache": "/usr/bin/sccache"})
        with self.assertRaisesRegex(RuntimeError, "native C compiler.*not found"):
            self.check({"CC": "sccache missing-cc"}, runner, which)
        self.assertEqual(calls, [])

    def test_unknown_wrapper_with_missing_command_is_rejected(self):
        runner, calls = self.runner({})
        which = self.which({"cc": "/usr/bin/cc"})
        with self.assertRaisesRegex(RuntimeError, "native C compiler.*not found"):
            self.check({"CC": "not-a-known-wrapper cc"}, runner, which)
        self.assertEqual(calls, [])

    def test_exact_path_with_spaces_is_probed_as_one_argv_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            compiler = Path(directory) / "my cc"
            compiler.write_text("#!/bin/sh\n", encoding="utf-8")
            runner, calls = self.runner({(str(compiler), "--version"): (0, "cc\n")})
            which = self.which({str(compiler): str(compiler)})
            self.assertEqual(self.check({"CC": str(compiler)}, runner, which), str(compiler))
            self.assertEqual(calls, [(str(compiler), "--version")])

    def test_failing_active_compiler_is_rejected(self):
        runner, _ = self.runner({})
        with self.assertRaisesRegex(RuntimeError, "failed to run"):
            self.check({"CC": "broken-cc"}, runner, self.which({"broken-cc": "/broken-cc"}))

    def test_target_linker_literal_path_with_spaces_is_validated(self):
        with tempfile.TemporaryDirectory() as directory:
            linker = Path(directory) / "my linker"
            linker.write_text("#!/bin/sh\n", encoding="utf-8")
            linker.chmod(0o755)
            runner, calls = self.runner(
                {
                    ("/usr/bin/cc", "--version"): (0, "cc\n"),
                    (str(linker), "--version"): (0, "ld\n"),
                }
            )
            which = self.which(
                {
                    "cc": "/usr/bin/cc",
                    str(linker): str(linker),
                }
            )
            environ = {
                "CC": "cc",
                "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER": str(linker),
            }
            self.assertEqual(self.check(environ, runner, which), "/usr/bin/cc")
            self.assertEqual(
                calls,
                [
                    ("/usr/bin/cc", "--version"),
                    (str(linker), "--version"),
                ],
            )

    def test_target_linker_command_string_is_rejected(self):
        runner, calls = self.runner({("/usr/bin/cc", "--version"): (0, "cc\n")})
        with self.assertRaisesRegex(RuntimeError, "single program name or path"):
            self.check(
                {
                    "CC": "cc",
                    "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER": "cc -fuse-ld=lld",
                },
                runner,
                self.which({"cc": "/usr/bin/cc"}),
            )
        self.assertEqual(calls, [("/usr/bin/cc", "--version")])

    def test_invalid_target_linker_override_is_rejected(self):
        runner, _ = self.runner({("/usr/bin/cc", "--version"): (0, "cc\n")})
        with self.assertRaisesRegex(RuntimeError, "LINKER.*not found"):
            self.check(
                {
                    "CC": "cc",
                    "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER": "missing-linker",
                },
                runner,
                self.which({"cc": "/usr/bin/cc"}),
            )


class BindgenSetupTests(unittest.TestCase):
    def test_cached_managed_binary_does_not_install(self):
        with patch.object(bootstrap, "valid_bindgen", return_value=True), patch.object(bootstrap, "run") as install:
            bootstrap.ensure_bindgen("1.99.0", Path("unused-cache"), None, True)
            install.assert_not_called()

    def test_missing_offline_binary_does_not_install(self):
        with patch.object(bootstrap, "valid_bindgen", return_value=False), patch.object(bootstrap, "run") as install:
            with self.assertRaisesRegex(RuntimeError, "missing"):
                bootstrap.ensure_bindgen("1.99.0", Path("unused-cache"), None, True)
            install.assert_not_called()

    def test_wrong_override_does_not_fall_back_to_download(self):
        with patch.object(bootstrap, "valid_bindgen", return_value=False), patch.object(bootstrap, "run") as install:
            with self.assertRaisesRegex(RuntimeError, "0.2.130"):
                bootstrap.ensure_bindgen("1.99.0", Path("unused-cache"), "wrong-binary", False)
            install.assert_not_called()

    def test_install_is_locked_pinned_and_local(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(bootstrap, "valid_bindgen", side_effect=[False, True]), \
             patch.object(bootstrap, "run") as install:
            root = Path(directory) / "managed-tools"
            bootstrap.ensure_bindgen("1.99.0", root, None, False)
            install.assert_called_once_with("cargo", "+1.99.0", "install", "wasm-bindgen-cli", "--version", "=0.2.130", "--locked", "--root", str(root))

if __name__ == "__main__":
    unittest.main()
