#!/usr/bin/env python3
"""Idempotent tool provisioning only. Zig owns the actual application graph."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

BINDGEN_VERSION = "0.2.130"

def run(*command):
    subprocess.run(command, check=True)

def require_tool(name):
    if not shutil.which(name):
        raise RuntimeError(f"{name} is required on PATH; install Rustup before running zig build")

def ensure_rust(toolchain, target, offline):
    require_tool("rustup")
    probe = subprocess.run(["rustup", "run", toolchain, "rustc", "--version"], capture_output=True, text=True)
    if probe.returncode:
        if offline:
            raise RuntimeError(f"Rust {toolchain} is not installed; -Doffline forbids downloading it")
        run("rustup", "toolchain", "install", toolchain, "--profile", "minimal", "--no-self-update")
    installed = subprocess.check_output(["rustup", "target", "list", "--installed", "--toolchain", toolchain], text=True).splitlines()
    if target not in installed:
        if offline:
            raise RuntimeError(f"Rust target {target} is missing; -Doffline forbids downloading it")
        run("rustup", "target", "add", target, "--toolchain", toolchain)

def valid_bindgen(path):
    if not path:
        return False
    try:
        version = subprocess.check_output([str(path), "--version"], text=True, stderr=subprocess.DEVNULL).strip()
        return version == f"wasm-bindgen {BINDGEN_VERSION}"
    except (OSError, subprocess.CalledProcessError):
        return False

def ensure_bindgen(toolchain, root, override, offline):
    if override:
        if not valid_bindgen(shutil.which(override)):
            raise RuntimeError(f"-Dwasm-bindgen must point to wasm-bindgen {BINDGEN_VERSION}")
        return
    binary = root / "bin" / ("wasm-bindgen.exe" if sys.platform == "win32" else "wasm-bindgen")
    if valid_bindgen(binary):
        return
    if offline:
        raise RuntimeError(f"managed wasm-bindgen {BINDGEN_VERSION} is missing; run once without -Doffline")
    root.mkdir(parents=True, exist_ok=True)
    run("cargo", f"+{toolchain}", "install", "wasm-bindgen-cli", "--version", f"={BINDGEN_VERSION}", "--locked", "--root", str(root))
    if not valid_bindgen(binary):
        raise RuntimeError("wasm-bindgen installation did not produce the expected version")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=["rust", "bindgen"])
    parser.add_argument("--toolchain", required=True)
    parser.add_argument("--target")
    parser.add_argument("--root", type=Path)
    parser.add_argument("--override")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    if args.kind == "rust":
        if not args.target:
            parser.error("rust provisioning requires --target")
        ensure_rust(args.toolchain, args.target, args.offline)
    else:
        if not args.root:
            parser.error("bindgen provisioning requires --root")
        ensure_bindgen(args.toolchain, args.root.resolve(), args.override, args.offline)

if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"tool setup failed: {error}")
