"""Check platform isolation; only the socket-free server build is executed."""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
HOST_SYSTEM = platform.system()
HOST_MACHINE = platform.machine()
SUPPORTED_DESKTOP_HOST = (
    (HOST_SYSTEM == "Linux" and HOST_MACHINE in ("x86_64", "amd64", "aarch64", "arm64"))
    or (HOST_SYSTEM == "Darwin" and HOST_MACHINE == "arm64")
)

def configure(*args):
    return subprocess.run(["zig", "build", "--help", *args], cwd=ROOT, capture_output=True, text=True)

class GraphIsolationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        desktop = configure()
        wasm = configure("-Dplatform=wasm")
        if wasm.returncode or (SUPPORTED_DESKTOP_HOST and desktop.returncode):
            raise RuntimeError(desktop.stderr + wasm.stderr)
        cls.desktop = desktop.stdout
        cls.wasm = wasm.stdout

    def test_server_only_exposes_only_native_server_steps(self):
        result = configure("-Dgame=false", "-Doffline", "-Drust-toolchain=9.99.0-missing-server-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        step_help = result.stdout.split("Steps:\n", 1)[1].split("\nProject-Specific Options:", 1)[0]
        steps = {line.split()[0] for line in step_help.splitlines() if line.split()}
        for step in ("server", "run-server", "test-server", "build-bench-server", "bench-server"):
            self.assertIn(step, steps)
        for step in ("desktop", "run", "test", "wallet", "setup", "header-check", "test-wallet",
                     "test-spilman", "browser", "renderer", "test-mint", "test-build", "test-package",
                     "wasm", "test-storage", "browser-fixture", "wallet-fixture", "test-onboarding",
                     "test-wallet-ui", "test-withdrawal-ui", "test-qr-portability", "test-platform"):
            self.assertNotIn(step, steps)

    def test_server_only_build_does_not_check_the_selected_rust_toolchain(self):
        result = subprocess.run(
            ["zig", "build", "server", "-Dgame=false", "-Doffline",
             "-Drust-toolchain=9.99.0-missing-server-only"],
            cwd=ROOT, capture_output=True, text=True, timeout=180,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("check installed Rust", result.stdout + result.stderr)

    def test_server_only_target_is_not_restricted_by_desktop_policy(self):
        result = configure("-Dgame=false", "-Dtarget=aarch64-linux-gnu")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_explicit_desktop_server_only_rejects_wasm_targets(self):
        for target in ("wasm32-emscripten", "wasm64-emscripten", "wasm32-wasi"):
            with self.subTest(target=target):
                result = configure("-Dplatform=desktop", "-Dgame=false", f"-Dtarget={target}")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("UnsupportedDesktopTarget", result.stderr)
                self.assertIn("native desktop/server builds cannot target Wasm", result.stderr)
                self.assertIn("-Dplatform=wasm and -Dgame=true", result.stderr)

    def test_wasm_does_not_expose_native_server_steps(self):
        for step in ("server", "run-server", "test-server", "build-bench-server", "bench-server"):
            self.assertNotRegex(self.wasm, rf"(?m)^  {step}\s")

    def test_wasm_server_only_is_explicitly_rejected(self):
        result = configure("-Dplatform=wasm", "-Dgame=false")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ServerOnlyRequiresNativePlatform", result.stderr)
        self.assertIn("-Dplatform=wasm requires -Dgame=true", result.stderr)

    def test_default_install_does_not_install_server(self):
        # No game means the default install should be empty, even though all
        # five explicit server steps are available. Never run the server.
        base = Path("/tmp/opencode")
        with tempfile.TemporaryDirectory(dir=base if base.is_dir() else None) as prefix:
            result = subprocess.run(
                ["zig", "build", "-Dgame=false", "-Doffline", "--prefix", prefix],
                cwd=ROOT, capture_output=True, text=True, timeout=180,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((Path(prefix) / "bin" / "haystack_server").exists())
        source = (ROOT / "build" / "server.zig").read_text(encoding="utf-8")
        self.assertNotIn("getInstallStep", source)
        self.assertNotIn("b.installArtifact", source)
        self.assertNotIn('"build/server.zig"', (ROOT / "build" / "desktop.zig").read_text())

    @unittest.skipUnless(SUPPORTED_DESKTOP_HOST, "desktop host is not supported")
    def test_desktop_does_not_expose_browser_tools(self):
        self.assertIn("header-check", self.desktop)
        for step in ("server", "run-server", "test-server", "build-bench-server", "bench-server"):
            self.assertRegex(self.desktop, rf"(?m)^  {step}\s")
        self.assertNotIn("-Dwasm-bindgen", self.desktop)
        self.assertNotIn("test-mint", self.desktop)
        self.assertNotIn("Provision pinned Rust, Wasm target", self.desktop)

    def test_wasm_does_not_expose_native_abi_steps(self):
        self.assertIn("-Dwasm-bindgen", self.wasm)
        # The test-only native fake mint remains gated to Linux hosts; the
        # browser wallet/renderer graph itself is independent of that helper.
        if HOST_SYSTEM == "Linux":
            self.assertIn("test-mint", self.wasm)
            self.assertIn("test-withdrawal-ui", self.wasm)
        else:
            self.assertNotIn("test-mint", self.wasm)
        self.assertNotIn("header-check", self.wasm)
        self.assertNotIn("test-spilman", self.wasm)
        self.assertNotIn("test-withdrawal-ui", self.desktop)

    def test_wasm_does_not_configure_macos_desktop_preflight(self):
        # The wasm help text itself mentions macOS in Zig's generic host
        # integration options, so assert the graph split at the source level.
        desktop_source = (ROOT / "build" / "desktop.zig").read_text(encoding="utf-8")
        wasm_source = (ROOT / "build" / "wasm.zig").read_text(encoding="utf-8")
        self.assertIn("macos-preflight.py", desktop_source)
        self.assertNotIn("macos-preflight.py", wasm_source)
        self.assertNotIn("macos_deployment_target", wasm_source)

    def test_both_browser_links_preload_only_grass_and_maple_sheets_and_track_their_contents(self):
        source = (ROOT / "build" / "wasm.zig").read_text(encoding="utf-8")
        self.assertIn('const grass_sheet = b.path("assets/Tileset/Tileset Grass Spring.png");', source)
        self.assertIn('const maple_sheet = b.path("assets/Objects/Maple Tree.png");', source)
        self.assertIn('.src_path = grass_sheet,', source)
        self.assertIn('.src_path = maple_sheet,', source)
        self.assertIn('.virtual_path = "/assets/Tileset/Tileset Grass Spring.png",', source)
        self.assertIn('.virtual_path = "/assets/Objects/Maple Tree.png",', source)
        self.assertEqual(source.count(".preload_paths = preload_paths,"), 2)
        self.assertEqual(source.count(".src_path ="), 2)
        self.assertEqual(source.count(".virtual_path ="), 2)
        self.assertIn("for ([_]*std.Build.Step{ linked, fixture_linked })", source)
        self.assertIn(".cast(std.Build.Step.Run)", source)
        self.assertIn("emcc.addFileInput(grass_sheet);", source)
        self.assertIn("emcc.addFileInput(maple_sheet);", source)
        self.assertEqual(source.count("emcc.addFileInput("), 2)

    def test_explicit_wasm_platform_and_target_select_the_complete_browser_graph(self):
        result = configure("-Dplatform=wasm", "-Dtarget=wasm32-emscripten")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("complete Wasm application", result.stdout)
        self.assertNotIn("header-check", result.stdout)

    def test_wasm_target_alone_does_not_select_the_browser_graph(self):
        result = configure("-Dtarget=wasm32-emscripten")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("WasmRequiresPlatform", result.stderr)
        self.assertIn("-Dplatform=wasm", result.stderr)
        self.assertNotIn("complete Wasm application", result.stdout)

    def test_wasm64_target_alone_is_rejected(self):
        result = configure("-Dtarget=wasm64-emscripten")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("WasmRequiresPlatform", result.stderr)

    def test_wasi_target_alone_is_rejected(self):
        result = configure("-Dtarget=wasm32-wasi")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("WasmRequiresPlatform", result.stderr)

    def test_wasm_platform_rejects_wasm64_and_wasi_targets(self):
        for target in ("wasm64-emscripten", "wasm32-wasi"):
            with self.subTest(target=target):
                result = configure("-Dplatform=wasm", f"-Dtarget={target}")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("UnsupportedBrowserTarget", result.stderr)

    def test_desktop_cannot_link_a_native_archive_into_wasm(self):
        result = configure("-Dplatform=desktop", "-Dtarget=wasm32-emscripten")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UnsupportedDesktopTarget", result.stderr)

    def test_wasm_cannot_silently_use_a_host_target(self):
        result = configure("-Dplatform=wasm", "-Dtarget=x86_64-linux-gnu")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UnsupportedBrowserTarget", result.stderr)

    def test_macos_intel_desktop_target_is_rejected_everywhere(self):
        result = configure("-Dplatform=desktop", "-Dtarget=x86_64-macos")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UnsupportedDesktopTarget", result.stderr)

    def test_apple_silicon_target_is_native_only(self):
        result = configure("-Dplatform=desktop", "-Dtarget=aarch64-macos")
        if HOST_SYSTEM == "Darwin" and HOST_MACHINE == "arm64":
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("UnsupportedDesktopTarget", result.stderr)

    def test_wasm_rejects_apple_silicon_desktop_targets(self):
        result = configure("-Dplatform=wasm", "-Dtarget=aarch64-macos")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UnsupportedBrowserTarget", result.stderr)

    def test_help_and_setup_graph_configure_without_the_selected_toolchain(self):
        missing = "9.99.0-missing-configure-only"
        for args in ((), ("-Dplatform=wasm",)):
            with self.subTest(platform=args):
                result = configure(f"-Drust-toolchain={missing}", *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("setup", result.stdout)
                if args:
                    self.assertIn("Provision pinned Rust, Wasm target", result.stdout)
                else:
                    self.assertIn("Provision the pinned desktop Rust toolchain", result.stdout)

    def test_cargo_launcher_never_uses_the_implicit_installing_plus_toolchain_form(self):
        source = (ROOT / "build" / "common.zig").read_text(encoding="utf-8")
        self.assertIn('"rustup", "run", options.toolchain, "cargo"', source)
        self.assertNotIn('b.fmt("+{s}"', source)

    @unittest.skipUnless(shutil.which("rustup"), "rustup is required for misspelled-toolchain checks")
    def test_normal_desktop_missing_toolchain_fails_with_setup_hint_and_does_not_install(self):
        missing = f"9.99.0-missing-normal-{os.getpid()}"
        result = subprocess.run(
            ["zig", "build", "wallet", f"-Drust-toolchain={missing}"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=120,
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("zig build setup", output)
        self.assertIn(f"-Drust-toolchain={missing}", output)
        self.assertNotIn("toolchain install", output)
        self.assertNotIn("downloading", output.lower())
        installed = subprocess.run(
            ["rustup", "toolchain", "list"], capture_output=True, text=True, timeout=30
        )
        self.assertNotIn(missing, installed.stdout + installed.stderr)

    @unittest.skipUnless(shutil.which("rustup"), "rustup is required for misspelled-toolchain checks")
    def test_normal_wasm_missing_toolchain_points_to_the_wasm_setup_command(self):
        missing = f"9.99.0-missing-wasm-{os.getpid()}"
        result = subprocess.run(
            ["zig", "build", "wallet", "-Dplatform=wasm", f"-Drust-toolchain={missing}"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=120,
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("zig build setup -Dplatform=wasm", output)
        self.assertIn(f"-Drust-toolchain={missing}", output)
        self.assertNotIn("toolchain install", output)
        installed = subprocess.run(
            ["rustup", "toolchain", "list"], capture_output=True, text=True, timeout=30
        )
        self.assertNotIn(missing, installed.stdout + installed.stderr)

    @unittest.skipUnless(shutil.which("rustup"), "rustup is required for misspelled-toolchain checks")
    def test_offline_setup_missing_toolchain_fails_without_installing(self):
        missing = f"9.99.0-missing-setup-{os.getpid()}"
        result = subprocess.run(
            ["zig", "build", "setup", "-Doffline", f"-Drust-toolchain={missing}"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=120,
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("-Doffline", output)
        self.assertIn("zig build setup", output)
        self.assertIn(f"-Drust-toolchain={missing}", output)
        self.assertNotIn("toolchain install", output)
        installed = subprocess.run(
            ["rustup", "toolchain", "list"], capture_output=True, text=True, timeout=30
        )
        self.assertNotIn(missing, installed.stdout + installed.stderr)

if __name__ == "__main__":
    unittest.main()
