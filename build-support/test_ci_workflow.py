"""Static CI workflow contracts; this does not parse YAML or run a build."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
DESKTOP_JOBS = ("linux-desktop", "macos-arm64-desktop")
ASSETS_STEP = "Create empty desktop assets fixture"
FIRST_DESKTOP_INSTALL = "- name: Debug desktop build"
JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")


def job_block(text, job):
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line == f"  {job}:":
            start = index
            break
    if start is None:
        return None
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if JOB_HEADER.match(lines[index]):
            end = index
            break
    return "\n".join(lines[start:end])


def step_block(block, name):
    lines = block.splitlines()
    for index, line in enumerate(lines):
        if line.strip() == f"- name: {name}":
            end = len(lines)
            for following in range(index + 1, len(lines)):
                if lines[following].lstrip().startswith("- name: "):
                    end = following
                    break
            return "\n".join(lines[index:end])
    return None


class DesktopAssetsFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_each_desktop_job_creates_assets_before_first_desktop_install(self):
        for job in DESKTOP_JOBS:
            with self.subTest(job=job):
                block = job_block(self.text, job)
                self.assertIsNotNone(block, f"missing CI job {job}")
                assets = block.find(f"- name: {ASSETS_STEP}")
                self.assertNotEqual(assets, -1, f"{job} has no empty assets fixture step")
                install = block.find(FIRST_DESKTOP_INSTALL)
                self.assertNotEqual(install, -1, f"{job} has no first desktop install step")
                self.assertLess(assets, install, f"{job} must create assets before its first desktop install")

    def test_assets_fixture_is_empty_and_never_downloaded(self):
        for job in DESKTOP_JOBS:
            with self.subTest(job=job):
                block = job_block(self.text, job)
                step = step_block(block, ASSETS_STEP)
                self.assertIsNotNone(step, f"missing empty assets fixture step in {job}")
                self.assertIn("mkdir -p assets", step)
                for fetch in ("curl", "wget", "git clone", "tar ", "unzip"):
                    self.assertNotIn(fetch, step, f"{job} must not fetch asset content")


DEPENDENCY_CHECK_STEP = "Verify dependency provenance"
DEPENDENCY_CHECK_COMMAND = "python3 build-support/check_dependency_pins.py"
PROVISIONING_STEPS = {
    "linux-desktop": "Provision selected desktop toolchain",
    "macos-arm64-desktop": "Provision selected desktop toolchain and run native preflight",
    "linux-browser-wasm": "Provision Wasm toolchain, wasm-bindgen and Emscripten",
}


class DependencyProvenanceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_each_job_verifies_dependency_provenance(self):
        for job in (*DESKTOP_JOBS, "linux-browser-wasm"):
            with self.subTest(job=job):
                block = job_block(self.text, job)
                self.assertIsNotNone(block, f"missing CI job {job}")
                step = step_block(block, DEPENDENCY_CHECK_STEP)
                self.assertIsNotNone(step, f"{job} has no dependency provenance step")
                self.assertIn(DEPENDENCY_CHECK_COMMAND, step)

    def test_dependency_check_runs_after_tool_provisioning(self):
        for job, provisioning in PROVISIONING_STEPS.items():
            with self.subTest(job=job):
                block = job_block(self.text, job)
                provision = block.find(f"- name: {provisioning}")
                verify = block.find(f"- name: {DEPENDENCY_CHECK_STEP}")
                self.assertNotEqual(provision, -1, f"{job} has no provisioning step")
                self.assertNotEqual(verify, -1, f"{job} has no dependency provenance step")
                self.assertLess(
                    provision,
                    verify,
                    f"{job} must provision the pinned toolchain before the provenance check",
                )

    def test_dependency_check_never_installs_tools_or_uses_the_network(self):
        for job in (*DESKTOP_JOBS, "linux-browser-wasm"):
            with self.subTest(job=job):
                block = job_block(self.text, job)
                step = step_block(block, DEPENDENCY_CHECK_STEP)
                for forbidden in ("zig build setup", "cargo install", "rustup toolchain install", "curl", "wget"):
                    self.assertNotIn(
                        forbidden,
                        step,
                        f"{job} provenance check must stay a pure check, found {forbidden}",
                    )


class PackageRegressionContractTests(unittest.TestCase):
    def test_browser_package_check_runs_after_warm_build_before_known_failing_suite(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        block = job_block(text, "linux-browser-wasm")
        name = "Offline Zig-filtered source package regression"
        step = step_block(block, name)
        self.assertIsNotNone(step)
        self.assertIn("zig build test-package -Dplatform=wasm -Doffline", step)
        self.assertLess(block.index("- name: Build the complete browser application"), block.index(f"- name: {name}"))
        self.assertLess(block.index("- name: Browser database conformance tests"), block.index(f"- name: {name}"))
        self.assertLess(block.index(f"- name: {name}"), block.index("- name: Browser and fake-mint integration tests"))
        self.assertNotIn("continue-on-error", block)
        self.assertNotIn("zig build setup", step)
        for job in DESKTOP_JOBS:
            self.assertNotIn("zig build test-package", job_block(text, job))


if __name__ == "__main__":
    unittest.main()
