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

class RustSetupTests(unittest.TestCase):
    def invoke(self, installed, probe=0, offline=False):
        with patch.object(bootstrap, "require_tool"), \
             patch.object(bootstrap.subprocess, "run", return_value=subprocess.CompletedProcess([], probe)), \
             patch.object(bootstrap.subprocess, "check_output", return_value=installed), \
             patch.object(bootstrap, "run") as install:
            bootstrap.ensure_rust("1.99.0", "wasm32-unknown-unknown", offline)
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
