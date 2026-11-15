"""Verify the resolved CDK and Spilman dependency identities in both roots.

The wallet FFI crate and the browser wallet are separate Cargo roots, but they
must resolve the *same* source for every CDK/Cashu package and for Spilman.
This check answers that question from Cargo's own resolution, so a registry
version that merely looks right, a second copy from another source, or a tag
that moved cannot pass unnoticed.

This is an explicit check, run after tool provisioning (locally and in CI).
A normal `zig build` only CHECKs the pinned toolchain and never runs this script
or installs tools. Its Cargo build can still fetch locked dependencies.
"""
from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent.parent

# Exact upstream pins. Check versions as well as Git identity so same-version
# source drift and version drift both fail loudly instead of compiling.
CDK_URL = "https://github.com/cashubtc/cdk.git"
CDK_TAG = "v0.18.1"
CDK_VERSION = "0.18.1"
CDK_COMMIT = "a056e0f0f69e94f431b1aeb90d883f18c61ea4c6"

SPILMAN_URL = "https://github.com/SatsAndSports/cashu_spilman_channels"
SPILMAN_REV = "8a5350dfd4d7c2902dc15c726a91dbfb2c793d43"
SPILMAN_VERSION = "0.2.0"
SPILMAN_PACKAGE = "cdk-spilman"

NATIVE_MANIFEST = ROOT / "vendor" / "cdk-wallet-ffi" / "Cargo.toml"
BROWSER_MANIFEST = ROOT / "browser" / "wallet" / "Cargo.toml"
WASM_PLATFORM = "wasm32-unknown-unknown"

# Packages each root must actually reach. The wrapper builds the native C ABI,
# the browser root builds the Wasm wallet; both need the same Spilman and CDK
# family sources.
REQUIRED = {
    "native": ("cashu", "cdk", "cdk-common", "cdk-sqlite", SPILMAN_PACKAGE),
    "browser": ("cashu", "cdk", "cdk-common", SPILMAN_PACKAGE),
}

DEFAULT_TOOLCHAIN = "1.99.0"


def is_cdk_family(name: str) -> bool:
    """True for every upstream package that ships from the pinned CDK repo.

    `cdk-spilman` shares the prefix but is a different repository with its own
    pin, so it is deliberately excluded here and checked separately.
    """
    if name == SPILMAN_PACKAGE:
        return False
    return name in ("cashu", "cdk") or name.startswith("cdk-")


def host_platform() -> str:
    """The host target triple `cargo metadata --filter-platform` expects."""
    machine = platform.machine().lower()
    arch = {
        "x86_64": "x86_64",
        "amd64": "x86_64",
        "aarch64": "aarch64",
        "arm64": "aarch64",
    }.get(machine)
    if arch is None:
        raise RuntimeError(f"unsupported host machine for platform filtering: {machine}")
    system = platform.system()
    if system == "Linux":
        return f"{arch}-unknown-linux-gnu"
    if system == "Darwin":
        return f"{arch}-apple-darwin"
    raise RuntimeError(f"unsupported host system for platform filtering: {system}")


def parse_source(source: str | None) -> dict:
    """Split a Cargo package source into its URL, selector, and commit."""
    if not source:
        return {"kind": "path", "url": None, "tag": None, "rev": None, "branch": None, "commit": None}
    if not source.startswith("git+"):
        # registry+https://..., sparse+https://..., local registry paths.
        return {
            "kind": "registry" if source.startswith("registry+") else source.split("+", 1)[0],
            "url": source,
            "tag": None,
            "rev": None,
            "branch": None,
            "commit": None,
        }
    without_prefix = source[len("git+"):]
    url, _, fragment = without_prefix.partition("#")
    split = urlsplit(url)
    query = parse_qs(split.query)
    return {
        "kind": "git",
        "url": f"{split.scheme}://{split.netloc}{split.path}",
        # Cargo writes exactly one selector; keep them separate for messages.
        "tag": query.get("tag", [None])[0],
        "rev": query.get("rev", [None])[0],
        "branch": query.get("branch", [None])[0],
        "commit": fragment or None,
    }


def packages_by_name(metadata: dict) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = {}
    for package in metadata.get("packages", []):
        name = package.get("name")
        if not name:
            continue
        grouped.setdefault(name, []).append(
            {
                "id": package.get("id"),
                "name": name,
                "version": package.get("version"),
                "source": parse_source(package.get("source")),
                "raw_source": package.get("source"),
            }
        )
    return grouped


def describe(package: dict) -> str:
    raw = package["raw_source"] or "(path)"
    return f"{package['name']} {package['version']} from {raw}"


def _check_git_pin(package: dict, problem: list[str], *, url: str, version: str,
                   tag: str | None = None, rev: str | None = None,
                   commit: str | None = None) -> None:
    source = package["source"]
    label = describe(package)
    if source["kind"] != "git":
        problem.append(f"{label}: must come from {url}, not {source['kind']}")
        return
    if source["url"] != url:
        problem.append(f"{label}: source URL must be {url}, got {source['url']}")
    if package["version"] != version:
        problem.append(f"{label}: version must be {version}, got {package['version']}")
    if tag is not None and source["tag"] != tag:
        problem.append(f"{label}: source selector must be tag {tag}, got {source['tag'] or source['rev'] or source['branch']}")
    if rev is not None and source["rev"] != rev:
        problem.append(f"{label}: source selector must be rev {rev}, got {source['tag'] or source['rev'] or source['branch']}")
    if commit is not None and source["commit"] != commit:
        problem.append(f"{label}: resolved commit must be {commit}, got {source['commit']}")


def check_graph(metadata: dict, label: str) -> list[str]:
    """Problems in one root's resolved graph, empty when it matches the pins."""
    problems: list[str] = []
    grouped = packages_by_name(metadata)
    # This repository's own crates are workspace members of their root and are
    # named `cdk-wallet-*`; they are ours, not upstream provenance claims.
    local_ids = set(metadata.get("workspace_members") or ())
    local_name = {"native": "cdk-wallet-ffi", "browser": "cdk-wallet-browser"}[label]

    for required in REQUIRED[label]:
        if required not in grouped:
            problems.append(f"{label}: required package {required} is missing from the resolved graph")

    for name, packages in sorted(grouped.items()):
        if not (is_cdk_family(name) or name == SPILMAN_PACKAGE):
            # Unrelated crates routinely resolve at several versions; only the
            # pinned provenance matters here.
            continue
        packages = [package for package in packages if not (
            name == local_name and package["id"] in local_ids
            and package["raw_source"] is None
        )]
        if not packages:
            continue
        if len(packages) > 1:
            rendered = ", ".join(describe(package) for package in packages)
            problems.append(f"{label}: duplicate package {name} resolved from multiple sources: {rendered}")
        if is_cdk_family(name):
            for package in packages:
                _check_git_pin(
                    package,
                    problems,
                    url=CDK_URL,
                    version=CDK_VERSION,
                    tag=CDK_TAG,
                    commit=CDK_COMMIT,
                )
        if name == SPILMAN_PACKAGE:
            for package in packages:
                _check_git_pin(
                    package,
                    problems,
                    url=SPILMAN_URL,
                    version=SPILMAN_VERSION,
                    rev=SPILMAN_REV,
                    commit=SPILMAN_REV,
                )
    return problems


def check_roots_agree(native: dict, browser: dict) -> list[str]:
    """Shared CDK/Spilman packages must resolve to identical identities.

    The two roots legitimately reach different *sets* of packages: only the
    native wrapper links SQLite, only the browser root ships the Wasm wallet.
    What must never differ is the source and version of a package both reach, so
    this compares the intersection rather than demanding identical sets.
    """
    problems: list[str] = []
    native_packages = packages_by_name(native)
    browser_packages = packages_by_name(browser)
    for name in sorted(set(native_packages) & set(browser_packages)):
        if not (is_cdk_family(name) or name == SPILMAN_PACKAGE):
            continue
        native_ids = {(package["version"], package["raw_source"]) for package in native_packages[name]}
        browser_ids = {(package["version"], package["raw_source"]) for package in browser_packages[name]}
        if native_ids != browser_ids:
            problems.append(
                f"roots disagree on {name}: native {sorted(native_ids, key=repr)}, browser {sorted(browser_ids, key=repr)}"
            )
    return problems


def load_metadata(manifest: Path, platform_triple: str, toolchain: str, offline: bool) -> dict:
    """Run the pinned `cargo metadata --locked` and return its JSON."""
    command = [
        "rustup",
        "run",
        toolchain,
        "cargo",
        "metadata",
        "--locked",
        "--all-features",
        "--format-version",
        "1",
        "--manifest-path",
        str(manifest),
        "--filter-platform",
        platform_triple,
    ]
    if offline:
        command.append("--offline")
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"cargo metadata failed for {manifest} ({platform_triple}):\n{result.stderr.strip()}"
        )
    return json.loads(result.stdout)


def evaluate(native: dict, browser: dict) -> list[str]:
    """Every problem across both graphs and their agreement."""
    problems = check_graph(native, "native") + check_graph(browser, "browser")
    problems += check_roots_agree(native, browser)
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--toolchain", default=DEFAULT_TOOLCHAIN, help="pinned Rust toolchain to run cargo with")
    parser.add_argument("--offline", action="store_true", help="forbid Cargo network access")
    parser.add_argument("--native-platform", default=None, help="platform triple for the native graph")
    parser.add_argument("--browser-platform", default=WASM_PLATFORM, help="platform triple for the browser graph")
    args = parser.parse_args(argv)

    native_platform = args.native_platform or host_platform()
    try:
        native = load_metadata(NATIVE_MANIFEST, native_platform, args.toolchain, args.offline)
        browser = load_metadata(BROWSER_MANIFEST, args.browser_platform, args.toolchain, args.offline)
        browser_host = load_metadata(BROWSER_MANIFEST, native_platform, args.toolchain, args.offline)
    except RuntimeError as error:
        print(f"dependency provenance check could not run: {error}", file=sys.stderr)
        return 2

    problems = evaluate(native, browser)
    problems += check_graph(browser_host, "browser")
    problems += check_roots_agree(native, browser_host)
    problems += check_roots_agree(browser, browser_host)
    if problems:
        print("dependency provenance check failed:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(
        "dependency provenance ok: CDK "
        f"{CDK_VERSION} tag {CDK_TAG} ({CDK_COMMIT}) and Spilman {SPILMAN_VERSION} rev {SPILMAN_REV} "
        f"in native ({native_platform}) and browser ({args.browser_platform}, {native_platform}) all-feature/dev graphs"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
