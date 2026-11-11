#!/usr/bin/env python3
"""Idempotent tool provisioning only. Zig owns the actual application graph."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys

BINDGEN_VERSION = "0.2.130"


def _load_native_tools():
    spec = importlib.util.spec_from_file_location(
        "build_support_native_tools", Path(__file__).with_name("native_tools.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


native_tools = _load_native_tools()

def run(*command):
    subprocess.run(command, check=True)

def capture(*command):
    return subprocess.run(list(command), capture_output=True, text=True)

def require_tool(name):
    if not shutil.which(name):
        raise RuntimeError(f"{name} is required on PATH; install Rustup before running zig build")

def parse_rustc_host(output):
    """Return (arch, os, host triple) from `rustc -vV` output."""
    host = None
    for line in output.splitlines():
        if line.startswith("host:"):
            host = line.split(":", 1)[1].strip()
            break
    if not host:
        raise RuntimeError("could not parse the Rust compiler host from `rustc -vV` output")
    if host.startswith(("aarch64-", "arm64-")):
        arch = "aarch64"
    elif host.startswith(("x86_64-", "amd64-")):
        arch = "x86_64"
    else:
        raise RuntimeError(f"unsupported Rust compiler architecture in host triple {host!r}")
    if "-apple-darwin" in host:
        os_name = "macos"
    elif "-linux-" in host:
        os_name = "linux"
    elif "-windows-" in host:
        os_name = "windows"
    else:
        raise RuntimeError(f"malformed or unsupported Rust compiler host triple {host!r}")
    return arch, os_name, host

def validate_rustc_host(arch, os_name, host, expected_arch, expected_os):
    """Reject foreign/Rosetta compilers without requiring host ABI == target ABI."""
    if expected_arch is None and expected_os is None:
        return
    if expected_arch is None or expected_os is None:
        raise RuntimeError("both --host-arch and --host-os are required when validating the Rust compiler host")
    if arch == expected_arch and os_name == expected_os:
        return
    hint = ""
    if expected_os == "macos" and expected_arch == "aarch64" and arch == "x86_64":
        hint = " This is an x86_64/Rosetta compiler; run the build from a native arm64 shell."
    raise RuntimeError(
        f"Rust compiler host {host!r} ({arch}-{os_name}) is not compatible with the Zig "
        f"host {expected_arch}-{expected_os}. Use a Rust toolchain whose compiler runs "
        f"natively on this machine; host ABI and target ABI are validated separately.{hint}"
    )

def _validate_command(command, what, runner, which):
    path = which(command.compiler)
    if path is None:
        raise RuntimeError(f"{what} {command.compiler!r} was not found on PATH")
    if command.wrapper:
        wrapper_path = which(command.wrapper)
        if wrapper_path is None:
            raise RuntimeError(
                f"{what} wrapper {command.wrapper!r} was not found on PATH"
            )
    argv = [path, *command.arguments, "--version"]
    result = runner(argv, capture_output=True, text=True, check=False)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(
            f"{what} {path!r} failed to run"
            + (f": {detail}" if detail else "")
        )
    return path


def _validate_program(value, what, runner, which):
    program = value
    if not program:
        raise RuntimeError(f"{what} is empty")
    path = which(program)
    if path is None:
        raise RuntimeError(
            f"{what} {program!r} was not found as an executable. "
            "CARGO_TARGET_*_LINKER must be a single program name or path "
            "(including a real wrapper script), not a command string. Put extra "
            'linker arguments in RUSTFLAGS, for example '
            'RUSTFLAGS="-C link-arg=-fuse-ld=lld".'
        )
    result = runner([path, "--version"], capture_output=True, text=True, check=False)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(
            f"{what} {path!r} failed to run"
            + (f": {detail}" if detail else "")
        )
    return path


def check_native_c_compiler(host_os, host_arch, rust_host, rust_target, env=None, runner=subprocess.run, which=shutil.which):
    """Validate the C compiler the native Cargo dependencies will actually use.

    The pinned cc-rs first uses the most specific CC-family variable that is set
    and otherwise falls back to its actual default `cc`. The host/target kind is
    derived from the selected Rust compiler host and the output Rust target,
    matching Cargo's HOST/TARGET distinction (a GNU-hosted compiler may build a
    musl target).

    For a cross-compilation the default is not `cc`: cc-rs selects a prefixed
    target compiler. This build does not implement that selection, so it requires
    an explicit effective CC-family setting instead of validating the wrong tool.
    """
    env = os.environ if env is None else env
    selected = native_tools.effective_tool(env, "CC", rust_host, rust_target)
    if selected is None:
        if rust_host != rust_target:
            raise RuntimeError(
                f"cross-compiling native C dependencies from Rust host "
                f"{rust_host!r} to {rust_target!r} requires an explicit CC-family "
                f"setting: cc-rs would select a prefixed target compiler, not the "
                f"default `cc`. Set CC_{rust_target} (or the underscore form, "
                f"TARGET_CC, or CC) to the actual C compiler for that target, or "
                f"build on a native {rust_target} host."
            )
        command = native_tools.ToolCommand(
            "default CC (cc-rs uses `cc`)", "cc", "cc", (), None
        )
        what = f"default native C compiler for {host_arch}-{host_os}"
    else:
        command = selected
        what = f"native C compiler from {command.source}"

    cc_path = _validate_command(command, what, runner, which)

    linker_key = f"CARGO_TARGET_{rust_target.upper().replace('-', '_')}_LINKER"
    explicit_linker = env.get(linker_key)
    if explicit_linker is not None:
        _validate_program(explicit_linker, f"{linker_key} linker", runner, which)

    return cc_path

def ensure_rust(toolchain, target, offline, host_os=None, host_arch=None, require_native_c=False):
    require_tool("rustup")
    probe = capture("rustup", "run", toolchain, "rustc", "--version")
    if probe.returncode:
        if offline:
            raise RuntimeError(f"Rust {toolchain} is not installed; -Doffline forbids downloading it")
        run("rustup", "toolchain", "install", toolchain, "--profile", "minimal", "--no-self-update")

    version = capture("rustup", "run", toolchain, "rustc", "-vV")
    if version.returncode:
        detail = (version.stderr or version.stdout).strip()
        raise RuntimeError(
            f"Rust {toolchain} cannot run `rustc -vV`"
            + (f": {detail}" if detail else "")
        )
    rust_arch, rust_os, rust_host = parse_rustc_host(version.stdout)
    validate_rustc_host(rust_arch, rust_os, rust_host, host_arch, host_os)

    if require_native_c:
        check_native_c_compiler(host_os, host_arch, rust_host, target)

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
    parser.add_argument("--host-os")
    parser.add_argument("--host-arch")
    parser.add_argument("--require-native-c", action="store_true")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    if args.kind == "rust":
        if not args.target:
            parser.error("rust provisioning requires --target")
        ensure_rust(
            args.toolchain,
            args.target,
            args.offline,
            host_os=args.host_os,
            host_arch=args.host_arch,
            require_native_c=args.require_native_c,
        )
    else:
        if not args.root:
            parser.error("bindgen provisioning requires --root")
        ensure_bindgen(args.toolchain, args.root.resolve(), args.override, args.offline)

if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"tool setup failed: {error}")
