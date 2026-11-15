"""Unit tests for the dependency provenance checker (no Cargo, no network)."""
from pathlib import Path
import subprocess
import unittest
from unittest import mock

import check_dependency_pins as pins

ROOT = Path(__file__).resolve().parent.parent

CDK_SOURCE = f"git+{pins.CDK_URL}?tag={pins.CDK_TAG}#{pins.CDK_COMMIT}"
SPILMAN_SOURCE = f"git+{pins.SPILMAN_URL}?rev={pins.SPILMAN_REV}#{pins.SPILMAN_REV}"


def package(name, version, source):
    return {"name": name, "version": version, "source": source}


def cdk_package(name, version=pins.CDK_VERSION, source=CDK_SOURCE):
    return package(name, version, source)


def spilman_package(version=pins.SPILMAN_VERSION, source=SPILMAN_SOURCE):
    return package(pins.SPILMAN_PACKAGE, version, source)


def registry(name, version):
    return package(name, version, "registry+https://github.com/rust-lang/crates.io-index")


def native_metadata(*extra):
    return {
        "packages": [
            cdk_package("cdk"),
            cdk_package("cdk-common"),
            cdk_package("cdk-sqlite"),
            cdk_package("cashu"),
            registry("serde", "1.0.220"),
            spilman_package(),
            *extra,
        ]
    }


def browser_metadata(*extra):
    return {
        "packages": [
            cdk_package("cdk"),
            cdk_package("cdk-common"),
            cdk_package("cashu"),
            registry("serde", "1.0.220"),
            spilman_package(),
            *extra,
        ]
    }


class ParseSourceTests(unittest.TestCase):
    def test_git_tag_source_yields_url_tag_and_commit(self):
        parsed = pins.parse_source(CDK_SOURCE)
        self.assertEqual(parsed["kind"], "git")
        self.assertEqual(parsed["url"], pins.CDK_URL)
        self.assertEqual(parsed["tag"], pins.CDK_TAG)
        self.assertIsNone(parsed["rev"])
        self.assertEqual(parsed["commit"], pins.CDK_COMMIT)

    def test_git_rev_source_yields_rev_and_commit(self):
        parsed = pins.parse_source(SPILMAN_SOURCE)
        self.assertEqual(parsed["url"], pins.SPILMAN_URL)
        self.assertEqual(parsed["rev"], pins.SPILMAN_REV)
        self.assertIsNone(parsed["tag"])
        self.assertEqual(parsed["commit"], pins.SPILMAN_REV)

    def test_registry_and_path_sources_are_not_git(self):
        self.assertEqual(pins.parse_source(registry("x", "1")["source"])["kind"], "registry")
        self.assertEqual(pins.parse_source(None)["kind"], "path")


class FamilyTests(unittest.TestCase):
    def test_family_covers_cdk_workspace_packages(self):
        for name in ("cashu", "cdk", "cdk-common", "cdk-sqlite", "cdk-axum", "cdk-fake-wallet", "cdk-sql-common", "cdk-signatory"):
            with self.subTest(name=name):
                self.assertTrue(pins.is_cdk_family(name))

    def test_unrelated_packages_are_not_family(self):
        for name in ("serde", "tokio", "spilman", "cdk-spilman", "safe-ffi"):
            with self.subTest(name=name):
                # `cdk-spilman` is checked separately against its own pin.
                self.assertFalse(pins.is_cdk_family(name))


class GraphCheckTests(unittest.TestCase):
    def test_matching_graphs_pass(self):
        self.assertEqual(pins.evaluate(native_metadata(), browser_metadata()), [])

    def test_registry_cdk_version_fails(self):
        metadata = native_metadata(registry("cdk-common", pins.CDK_VERSION))
        # The duplicate alone is a failure; the registry copy is also wrong.
        problems = pins.check_graph(metadata, "native")
        self.assertTrue(any("duplicate package cdk-common" in problem for problem in problems))
        self.assertTrue(any("must come from" in problem for problem in problems))

    def test_registry_only_cdk_version_fails(self):
        metadata = {"packages": [registry("cdk", pins.CDK_VERSION), cdk_package("cdk-common"),
                                 cdk_package("cdk-sqlite"), spilman_package()]}
        problems = pins.check_graph(metadata, "native")
        self.assertTrue(any("cdk " in problem and "must come from" in problem for problem in problems))

    def test_wrong_cdk_version_fails(self):
        metadata = native_metadata()
        metadata["packages"][0]["version"] = "0.18.3"
        problems = pins.check_graph(metadata, "native")
        self.assertTrue(any("version must be 0.18.1" in problem for problem in problems))

    def test_wrong_cdk_tag_fails(self):
        wrong = f"git+{pins.CDK_URL}?tag=v0.18.3#{pins.CDK_COMMIT}"
        metadata = native_metadata(cdk_package("cdk-axum", source=wrong))
        problems = pins.check_graph(metadata, "native")
        self.assertTrue(any("selector must be tag v0.18.1" in problem for problem in problems))

    def test_wrong_cdk_commit_fails(self):
        wrong = f"git+{pins.CDK_URL}?tag={pins.CDK_TAG}#0000000000000000000000000000000000000000"
        metadata = native_metadata(cdk_package("cdk-http-client", source=wrong))
        problems = pins.check_graph(metadata, "native")
        self.assertTrue(any("resolved commit must be" in problem for problem in problems))

    def test_spilman_registry_source_fails(self):
        metadata = native_metadata(registry(pins.SPILMAN_PACKAGE, pins.SPILMAN_VERSION))
        problems = pins.check_graph(metadata, "native")
        self.assertTrue(any("duplicate package cdk-spilman" in problem for problem in problems))

    def test_spilman_wrong_rev_fails(self):
        wrong = f"git+{pins.SPILMAN_URL}?rev=deadbeef#{'deadbeef'}"
        metadata = native_metadata(package(pins.SPILMAN_PACKAGE, pins.SPILMAN_VERSION, wrong))
        problems = pins.check_graph(metadata, "native")
        self.assertTrue(any("duplicate package cdk-spilman" in problem for problem in problems))
        self.assertTrue(any("selector must be rev" in problem for problem in problems))

    def test_spilman_wrong_version_fails(self):
        metadata = native_metadata(spilman_package(version="0.3.0"))
        problems = pins.check_graph(metadata, "native")
        self.assertTrue(any("version must be 0.2.0" in problem for problem in problems))

    def test_missing_required_package_fails(self):
        metadata = {"packages": [cdk_package("cdk"), cdk_package("cdk-common"), spilman_package()]}
        problems = pins.check_graph(metadata, "native")
        self.assertTrue(any("required package cdk-sqlite is missing" in problem for problem in problems))

    def test_unrelated_crates_at_several_versions_are_ignored(self):
        metadata = native_metadata(registry("syn", "2.0.100"), registry("syn", "3.0.0"))
        self.assertEqual(pins.check_graph(metadata, "native"), [])

    def test_local_workspace_crate_is_not_an_upstream_claim(self):
        local = {
            "id": "path+file:///repo/vendor/cdk-wallet-ffi#cdk-wallet-ffi@0.1.0",
            "name": "cdk-wallet-ffi",
            "version": "0.1.0",
            "source": None,
        }
        metadata = native_metadata(local)
        metadata["workspace_members"] = [local["id"]]
        self.assertEqual(pins.check_graph(metadata, "native"), [])

    def test_path_spilman_copy_is_flagged(self):
        local = {
            "id": "path+file:///repo/vendor/cdk-spilman#cdk-spilman@0.2.0",
            "name": pins.SPILMAN_PACKAGE,
            "version": pins.SPILMAN_VERSION,
            "source": None,
        }
        metadata = native_metadata(local)
        problems = pins.check_graph(metadata, "native")
        self.assertTrue(any("duplicate package cdk-spilman" in problem for problem in problems))
        self.assertTrue(any("must come from" in problem for problem in problems))

    def test_cashu_is_required_in_both_roots(self):
        for label, metadata in (("native", native_metadata()), ("browser", browser_metadata())):
            metadata["packages"] = [p for p in metadata["packages"] if p["name"] != "cashu"]
            self.assertTrue(any("required package cashu is missing" in p
                                for p in pins.check_graph(metadata, label)))

    def test_workspace_members_cannot_hide_upstream_packages(self):
        for name in ("cashu", "cdk", pins.SPILMAN_PACKAGE, "cdk-unexpected"):
            metadata = native_metadata()
            bad = package(name, "0.1.0", None)
            bad["id"] = "path+file:///repo/pretend#" + name
            metadata["packages"].append(bad)
            metadata["workspace_members"] = [bad["id"]]
            self.assertTrue(any("must come from" in p for p in pins.check_graph(metadata, "native")))

    def test_duplicate_from_two_git_revisions_fails(self):
        other = f"git+{pins.CDK_URL}?tag=v0.18.1#1111111111111111111111111111111111111111"
        metadata = native_metadata(
            cdk_package("cdk-signatory"),
            cdk_package("cdk-signatory", source=other),
        )
        problems = pins.check_graph(metadata, "native")
        self.assertTrue(any("duplicate package cdk-signatory" in problem for problem in problems))


class CrossRootTests(unittest.TestCase):
    def test_path_and_git_duplicate_reports_disagreement_without_crashing(self):
        native = native_metadata(package("cdk", pins.CDK_VERSION, None))
        problems = pins.evaluate(native, browser_metadata())
        self.assertTrue(any("duplicate package cdk" in p for p in problems))
        self.assertTrue(any("roots disagree on cdk" in p for p in problems))

    def test_roots_disagree_on_version(self):
        browser = browser_metadata()
        browser["packages"][0]["version"] = "0.18.3"
        problems = pins.check_roots_agree(native_metadata(), browser)
        self.assertTrue(any("roots disagree on cdk" in problem for problem in problems))

    def test_roots_disagree_when_browser_uses_registry(self):
        browser = {"packages": [registry("cdk", pins.CDK_VERSION), cdk_package("cdk-common"),
                                spilman_package()]}
        problems = pins.check_roots_agree(native_metadata(), browser)
        self.assertTrue(any("roots disagree on cdk" in problem for problem in problems))

    def test_native_only_family_packages_are_not_a_split(self):
        # Only the native wrapper links SQLite; the browser root has no SQLite
        # at all. A one-sided package is a real difference in needs, not a
        # provenance split, so it must not be reported as roots disagreeing.
        native = native_metadata()
        browser = {"packages": [cdk_package("cdk"), cdk_package("cdk-common"), spilman_package()]}
        self.assertEqual(pins.check_roots_agree(native, browser), [])

    def test_roots_agree_ignores_unrelated_packages(self):
        native = native_metadata(registry("tempfile", "3.13.0"))
        browser = browser_metadata(registry("paste", "1.0.15"))
        self.assertEqual(pins.check_roots_agree(native, browser), [])


class MetadataInvocationTests(unittest.TestCase):
    def test_metadata_uses_pinned_toolchain_locked_and_platform(self):
        completed = mock.Mock(returncode=0, stdout='{"packages": []}', stderr="")
        with mock.patch.object(subprocess, "run", return_value=completed) as run:
            pins.load_metadata(pins.NATIVE_MANIFEST, "x86_64-unknown-linux-gnu", "1.99.0", offline=False)
        command = run.call_args.args[0]
        self.assertEqual(command[:4], ["rustup", "run", "1.99.0", "cargo"])
        self.assertIn("metadata", command)
        self.assertIn("--locked", command)
        self.assertIn("--all-features", command)
        self.assertIn("--format-version", command)
        self.assertIn("--filter-platform", command)
        self.assertIn("x86_64-unknown-linux-gnu", command)
        self.assertNotIn("--offline", command)

    def test_offline_flag_is_forwarded(self):
        completed = mock.Mock(returncode=0, stdout='{"packages": []}', stderr="")
        with mock.patch.object(subprocess, "run", return_value=completed) as run:
            pins.load_metadata(pins.BROWSER_MANIFEST, pins.WASM_PLATFORM, "1.99.0", offline=True)
        self.assertIn("--offline", run.call_args.args[0])

    def test_metadata_failure_is_reported_not_swallowed(self):
        completed = mock.Mock(returncode=101, stdout="", stderr="boom")
        with mock.patch.object(subprocess, "run", return_value=completed):
            with self.assertRaises(RuntimeError):
                pins.load_metadata(pins.NATIVE_MANIFEST, "x86_64-unknown-linux-gnu", "1.99.0", offline=False)

    def test_main_fails_closed_when_metadata_cannot_run(self):
        with mock.patch.object(pins, "load_metadata", side_effect=RuntimeError("offline")), \
                mock.patch("sys.stderr"):
            self.assertEqual(pins.main([]), 2)

    def test_main_checks_browser_wasm_and_host_graphs(self):
        host = "x86_64-unknown-linux-gnu"
        with mock.patch.object(pins, "load_metadata", side_effect=[
                native_metadata(), browser_metadata(), browser_metadata()]) as load, \
                mock.patch("sys.stdout"):
            self.assertEqual(pins.main(["--offline", "--native-platform", host]), 0)
        self.assertEqual(load.call_args_list, [
            mock.call(pins.NATIVE_MANIFEST, host, pins.DEFAULT_TOOLCHAIN, True),
            mock.call(pins.BROWSER_MANIFEST, pins.WASM_PLATFORM, pins.DEFAULT_TOOLCHAIN, True),
            mock.call(pins.BROWSER_MANIFEST, host, pins.DEFAULT_TOOLCHAIN, True),
        ])

    def test_browser_host_provenance_failure_is_not_hidden(self):
        bad = browser_metadata()
        bad["packages"][0]["version"] = "0.18.3"
        with mock.patch.object(pins, "load_metadata", side_effect=[
                native_metadata(), browser_metadata(), bad]), mock.patch("sys.stderr"):
            self.assertEqual(pins.main(["--native-platform", "x86_64-unknown-linux-gnu"]), 1)


class ManifestPinTests(unittest.TestCase):
    def test_both_roots_pin_the_same_source(self):
        for manifest in (pins.NATIVE_MANIFEST, pins.BROWSER_MANIFEST):
            with self.subTest(manifest=manifest.name):
                text = manifest.read_text(encoding="utf-8")
                self.assertIn(pins.CDK_URL, text)
                self.assertIn(f'tag = "{pins.CDK_TAG}"', text)
                self.assertIn(f'version = "={pins.CDK_VERSION}"', text)
                self.assertIn(pins.SPILMAN_URL, text)
                self.assertIn(f'rev = "{pins.SPILMAN_REV}"', text)

    def test_no_root_depends_on_a_path_spilman_copy(self):
        for manifest in (pins.NATIVE_MANIFEST, pins.BROWSER_MANIFEST):
            with self.subTest(manifest=manifest.name):
                text = manifest.read_text(encoding="utf-8")
                self.assertNotIn("path = \"../cdk-spilman\"", text)
                self.assertNotIn("path = \"../../vendor/cdk-spilman\"", text)

    def test_no_root_uses_a_registry_cdk_version(self):
        for manifest in (pins.NATIVE_MANIFEST, pins.BROWSER_MANIFEST):
            with self.subTest(manifest=manifest.name):
                text = manifest.read_text(encoding="utf-8")
                self.assertNotIn('"=0.18.3"', text)


class HostPlatformTests(unittest.TestCase):
    def test_host_platform_is_a_cargo_triple(self):
        system = pins.platform.system()
        if system not in ("Linux", "Darwin"):
            self.skipTest(f"unsupported host system {system}")
        triple = pins.host_platform()
        self.assertIn("-", triple)
        self.assertTrue(triple.startswith(("x86_64", "aarch64")))


if __name__ == "__main__":
    unittest.main()
