"""Query configuration only: these tests never build either application."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent.parent

def configure(*args):
    return subprocess.run(["zig", "build", "--help", *args], cwd=ROOT, capture_output=True, text=True)

class GraphIsolationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        desktop = configure()
        wasm = configure("-Dplatform=wasm")
        if desktop.returncode or wasm.returncode:
            raise RuntimeError(desktop.stderr + wasm.stderr)
        cls.desktop = desktop.stdout
        cls.wasm = wasm.stdout

    def test_desktop_does_not_expose_browser_tools(self):
        self.assertIn("header-check", self.desktop)
        self.assertNotIn("-Dwasm-bindgen", self.desktop)
        self.assertNotIn("test-mint", self.desktop)
        self.assertNotIn("Provision pinned Rust, Wasm target", self.desktop)

    def test_wasm_does_not_expose_native_abi_steps(self):
        self.assertIn("-Dwasm-bindgen", self.wasm)
        self.assertIn("test-mint", self.wasm)
        self.assertNotIn("header-check", self.wasm)
        self.assertNotIn("test-spilman", self.wasm)

    def test_explicit_wasm_target_selects_the_complete_browser_graph(self):
        result = configure("-Dtarget=wasm32-emscripten")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("complete Wasm application", result.stdout)
        self.assertNotIn("header-check", result.stdout)

    def test_desktop_cannot_link_a_native_archive_into_wasm(self):
        result = configure("-Dplatform=desktop", "-Dtarget=wasm32-emscripten")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UnsupportedDesktopTarget", result.stderr)

    def test_wasm_cannot_silently_use_a_host_target(self):
        result = configure("-Dplatform=wasm", "-Dtarget=x86_64-linux-gnu")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UnsupportedBrowserTarget", result.stderr)

if __name__ == "__main__":
    unittest.main()
