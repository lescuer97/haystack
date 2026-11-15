"""Explicit offline source-package regression, never invoked by test discovery."""
import argparse
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import tarfile
import tempfile


# Independent of .paths: omit local/generated/private data before Zig copies it.
# Everything else, including untracked sources and genuine assets, reaches Zig.
PRUNED = {
    ".git", ".zig-cache", "zig-out", "zig-out-release", "zig-pkg", "target",
    "node_modules", "__pycache__", ".pytest_cache", "repros", "profiles",
    ".profiles", "chromium-profile", "secrets", ".secrets",
}
REQUIRED = (
    "build.zig", "build.zig.zon", "README.md", "docs/build.md",
    "docs/browser-wallet.md", ".github/workflows/ci.yml",
    "build-support/test_ci_workflow.py", "build-support/check_package.py",
    "build-support/test_package.py", "browser/game-onboarding.js",
    "browser/game-onboarding-test.mjs", "browser/cdp-runner.mjs",
    "browser/cdp-runner-test.mjs", "browser/onboarding-browser-test.mjs",
    "browser/platform-hardening-browser-test.mjs", "browser/onboarding-test.html",
    "browser/onboarding-test.js", "browser/onboarding-regression-test.mjs",
    "browser/test-support/fake-indexeddb.mjs",
    "browser/test-support/fake-indexeddb-test.mjs",
)


def excluded(path):
    return any(
        part in PRUNED or part == ".env" or part.startswith(".env.")
        or part.startswith(":memory")
        or part.endswith((".log", ".sqlite", ".sqlite3", ".db", ".db-wal",
                          ".db-shm", ".sqlite-wal", ".sqlite-shm", ".pyc", ".pyo",
                          ".prof", ".profraw", ".pem", ".key"))
        for part in Path(path).parts
    )


def source_tar(source, destination):
    """No Git/manifest selection, no symlink dereferencing or external inputs."""
    with tarfile.open(destination, "w", dereference=False) as archive:
        for directory, dirs, files in os.walk(source, followlinks=False):
            parent = Path(directory)
            dirs[:] = sorted(d for d in dirs if not excluded((parent / d).relative_to(source)))
            for name in [*dirs, *sorted(files)]:
                path = parent / name
                relative = path.relative_to(source)
                if excluded(relative):
                    continue
                if path.is_symlink() or not (path.is_dir() or path.is_file()):
                    raise RuntimeError(f"unsupported source input (not a regular file/directory): {relative}")
                archive.add(path, arcname=relative.as_posix(), recursive=False)


def run(command, cwd, *, env=None, timeout=900):
    print(f"package check: {' '.join(map(str, command))}", flush=True)
    with subprocess.Popen(command, cwd=cwd, env=env, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          start_new_session=True) as process:
        try:
            output, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            # Zig may have Cargo/emcc children: kill this owned process group,
            # not just the launcher, before deleting its disposable workspace.
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate()
            print(output, end="", flush=True)
            raise RuntimeError(f"stage timed out after {timeout}s: {' '.join(map(str, command))}") from error
        print(output, end="", flush=True)
        if process.returncode:
            raise RuntimeError(f"stage failed ({process.returncode}): {' '.join(map(str, command))}")
        return output


def default_global_cache(zig):
    output = subprocess.check_output([zig, "env"], text=True, timeout=30)
    match = re.search(r'\.global_cache_dir = "([^"]+)"', output)
    if not match:
        raise RuntimeError("cannot determine Zig global cache from zig env")
    return Path(match[1])


def fetch_filtered(source, scratch, zig, global_cache):
    archive = scratch / "working-tree.tar"
    source_tar(source, archive)
    isolated = scratch / "fetch-cache"
    isolated.mkdir()
    # Reuse only compiler caches, NOT p/ (packages) or tmp/. This avoids
    # recompiling Zig's self-hosted fetch command with each isolated fetch.
    for name in ("b", "h", "o", "z"):
        cached = global_cache / name
        if cached.is_dir():
            (isolated / name).symlink_to(cached, target_is_directory=True)
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(isolated))
    output = run([zig, "fetch", str(archive)], source, env=env, timeout=180)
    hashes = [line for line in output.splitlines() if re.fullmatch(r"[A-Za-z0-9_.-]+", line)]
    if len(hashes) != 1:
        raise RuntimeError("zig fetch did not return exactly one package hash")
    package_hash = hashes[0]
    filtered = isolated / "p" / f"{package_hash}.tar.gz"
    if not filtered.is_file():
        raise RuntimeError(f"Zig 0.17 filtered cache archive missing: {filtered}")
    return filtered, package_hash


def validate_package(archive, package_hash):
    """Validate actual Zig output before extracting anything into a build tree."""
    names = set()
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            parts = Path(member.name).parts
            if (not parts or parts[0] != package_hash or ".." in parts
                    or Path(member.name).is_absolute()
                    or not (member.isfile() or member.isdir())):
                raise RuntimeError(f"unsafe package member: {member.name}")
            relative = Path(*parts[1:])
            if excluded(relative):
                raise RuntimeError(f"generated/private package member: {relative}")
            if member.isfile():
                names.add(relative.as_posix())
    missing = sorted(set(REQUIRED) - names)
    if missing:
        raise RuntimeError(f"missing required package inputs: {', '.join(missing)}")
    print(f"package check: validated {len(names)} Zig-filtered files; no generated/private inputs", flush=True)


def check(args):
    source = Path.cwd().resolve()
    global_cache = (args.global_cache or default_global_cache(args.zig)).resolve()
    local_cache = (args.local_cache or source / ".zig-cache").resolve()
    pkg_dir = Path(os.environ.get("ZIG_LOCAL_PKG_DIR", source / "zig-pkg")).resolve()
    bindgen = local_cache / "tools/wasm-bindgen-0.2.130/bin/wasm-bindgen"
    if not bindgen.is_file() or not pkg_dir.is_dir():
        raise RuntimeError("warmed Zig dependencies and managed wasm-bindgen required; run zig build setup -Dplatform=wasm and a browser build first")
    base = Path("/tmp/opencode")
    with tempfile.TemporaryDirectory(prefix="package-check-", dir=base if base.is_dir() else None) as temporary:
        scratch = Path(temporary)
        archive, package_hash = fetch_filtered(source, scratch, args.zig, global_cache)
        validate_package(archive, package_hash)
        with tarfile.open(archive) as package:
            package.extractall(scratch / "filtered", filter="data")
        workspace = scratch / "filtered" / package_hash
        for path in workspace.rglob("*"):
            path.chmod(path.stat().st_mode | 0o200)
        workspace.chmod(workspace.stat().st_mode | 0o700)
        # No original source directories or generated artifacts are copied or
        # linked into the package. Only provisioned dependency/tool caches recur.
        env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(global_cache),
                   ZIG_LOCAL_PKG_DIR=str(pkg_dir), RUSTUP_AUTO_INSTALL="0",
                   CARGO_NET_OFFLINE="true")
        env.pop("ZIG_LOCAL_CACHE_DIR", None)
        common = ["--system", str(pkg_dir), "-Doffline", f"-Drust-toolchain={args.rust_toolchain}"]
        commands = [
            ["--help"], ["--help", "-Dplatform=wasm"],
            ["test-build"], ["test-storage", "-Dplatform=wasm"],
            ["browser", "-Dplatform=wasm", f"-Dwasm-bindgen={bindgen}"],
        ]
        for command in commands:
            run([args.zig, "build", *command, *common], workspace, env=env)
    print("package check: PASS (filtered sources, configuration, build tests, Node tests, production browser)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default=shutil.which("zig") or "zig")
    parser.add_argument("--global-cache", type=Path)
    parser.add_argument("--local-cache", type=Path)
    parser.add_argument("--rust-toolchain", default="1.99.0")
    args = parser.parse_args()
    try:
        check(args)
    except (RuntimeError, OSError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, f"package check: FAIL: {error}\n")


if __name__ == "__main__":
    main()
