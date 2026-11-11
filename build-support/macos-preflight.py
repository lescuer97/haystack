#!/usr/bin/env python3
"""Validate a native Apple Silicon macOS desktop build environment.

This is a prerequisite of the desktop graph only. It checks the running macOS
version, native arm64 execution, Xcode Command Line Tools, SDKROOT/CC/CFLAGS
consistency and a usable macOS SDK/clang. It never installs anything and never
invokes sudo: missing tooling produces actionable ``xcode-select`` instructions
instead.
"""
import argparse
import importlib.util
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path


def _load_native_tools():
    spec = importlib.util.spec_from_file_location(
        "build_support_native_tools", Path(__file__).with_name("native_tools.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


native_tools = _load_native_tools()

MIN_MACOS = (15, 0)
MIN_MACOS_TEXT = "15.0"

XCODE_SELECT_HELP = (
    "Install Xcode Command Line Tools with `xcode-select --install`, then verify "
    "`xcode-select -p`. If they are already installed but not selected, run "
    "`sudo xcode-select --switch /Library/Developer/CommandLineTools` (or point "
    "it at /Applications/Xcode.app/Contents/Developer). This build never runs "
    "sudo or installs system packages itself."
)


class PreflightError(RuntimeError):
    pass


def _run(command, runner=subprocess.run):
    try:
        return runner(command, capture_output=True, text=True, check=False)
    except OSError as error:
        raise PreflightError(f"could not run {' '.join(command)}: {error}") from error


def _capture(command, runner, failure):
    result = _run(command, runner)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise PreflightError(f"{failure}: {detail}" if detail else failure)
    return result.stdout.strip()


def check_arm64(machine=None, translated=None):
    """Reject Intel, universal and Rosetta/x86_64 macOS shells."""
    machine = machine if machine is not None else platform.machine()
    if machine not in ("arm64", "aarch64"):
        raise PreflightError(
            "native Apple Silicon (arm64) is required, but this process reports "
            f"{machine!r}. Intel Macs, Rosetta/x86_64 shells and universal "
            "builds are not supported; run `zig build` from a native arm64 "
            "Terminal."
        )
    if translated:
        raise PreflightError(
            "this process is running under Rosetta translation. Run `zig build` "
            "from a native arm64 Terminal instead; x86_64/Rosetta builds are not "
            "supported."
        )


def is_translated(runner=subprocess.run):
    """Best-effort Rosetta detection; unknown sysctl keys mean not translated."""
    try:
        result = _run(["sysctl", "-n", "-i", "sysctl.proc_translated"], runner)
    except PreflightError:
        return False
    return result.returncode == 0 and result.stdout.strip() == "1"


def parse_version(text, what):
    match = re.match(r"^\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?", text)
    if not match:
        raise PreflightError(f"could not parse {what} version from {text!r}")
    return tuple(int(part or 0) for part in match.groups())


def check_deployment_target(target_text, sdk_text):
    target = parse_version(target_text, "deployment target")
    sdk = parse_version(sdk_text, "macOS SDK")
    if target < MIN_MACOS:
        raise PreflightError(
            f"macOS deployment target {target_text} is unsupported: Apple Silicon "
            f"builds require macOS {MIN_MACOS_TEXT} or newer."
        )
    if sdk < target:
        raise PreflightError(
            f"the installed macOS SDK ({sdk_text}) is older than the required "
            f"deployment target {target_text}. Install a newer Xcode Command "
            "Line Tools/Xcode."
        )
    return target


def check_running_version(running_text, required_text):
    """Reject running an older OS than the binary's deployment target."""
    running = parse_version(running_text, "running macOS")
    required = parse_version(required_text, "deployment target")
    if running < MIN_MACOS:
        raise PreflightError(
            f"the running macOS version ({running_text}) is older than the "
            f"required macOS {MIN_MACOS_TEXT} minimum for Apple Silicon builds."
        )
    if running < required:
        raise PreflightError(
            f"the running macOS version ({running_text}) is older than the "
            f"required deployment target {required_text}; upgrade macOS before "
            "building this target."
        )
    return running


def check_running_os(runner=subprocess.run):
    return _capture(
        ["sw_vers", "-productVersion"],
        runner,
        "could not determine the running macOS version with `sw_vers -productVersion`",
    )


def check_sdkroot(sdk_path, environ=None, realpath=os.path.realpath):
    """Reject an SDKROOT that disagrees with the SDK selected by xcrun.

    Zig discovers the macOS SDK through xcrun, while Rust/clang may honor
    SDKROOT. Building with two different SDKs would validate one and compile
    against another, so a conflicting SDKROOT is a hard error. An unset
    SDKROOT needs no action.
    """
    environ = os.environ if environ is None else environ
    sdkroot = environ.get("SDKROOT")
    if not sdkroot:
        return sdk_path
    root = Path(sdkroot)
    if not root.is_dir():
        raise PreflightError(
            f"SDKROOT={sdkroot!r} does not exist or is not a directory. Unset "
            "SDKROOT or point it at the path from "
            "`xcrun --sdk macosx --show-sdk-path`."
        )
    if realpath(root) != realpath(Path(sdk_path)):
        raise PreflightError(
            f"SDKROOT={sdkroot!r} conflicts with the SDK selected by "
            f"`xcrun --sdk macosx --show-sdk-path` ({sdk_path!r}). Unset SDKROOT "
            "or select the same SDK so Zig, Rust and Cargo all use one SDK."
        )
    return sdk_path


def check_clang(clang, runner=subprocess.run):
    if not Path(clang).is_file() or not os.access(clang, os.X_OK):
        raise PreflightError(
            f"`xcrun --sdk macosx --find clang` returned {clang!r}, which is not "
            "an executable file. " + XCODE_SELECT_HELP
        )
    version = _capture(
        [clang, "--version"],
        runner,
        f"the SDK clang at {clang!r} could not run. " + XCODE_SELECT_HELP,
    )
    if not version:
        raise PreflightError(
            f"the SDK clang at {clang!r} reported no version. " + XCODE_SELECT_HELP
        )
    return clang


def check_selected_cc(clang, rust_host, rust_target, environ=None, which=shutil.which, realpath=os.path.realpath):
    """Validate the CC-family setting cc-rs will actually select."""
    environ = os.environ if environ is None else environ
    try:
        selected = native_tools.effective_tool(environ, "CC", rust_host, rust_target)
    except native_tools.NativeToolError as error:
        raise PreflightError(str(error)) from error
    if selected is None:
        source = "default CC (cc-rs uses `cc`)"
        compiler = "cc"
        wrapper = None
    else:
        source = selected.source
        compiler = selected.compiler
        wrapper = selected.wrapper

    if wrapper:
        wrapper_path = which(wrapper)
        if wrapper_path is None:
            raise PreflightError(
                f"{source} names wrapper {wrapper!r}, which was not found on PATH."
            )
    path = which(compiler)
    if path is None:
        raise PreflightError(
            f"{source} selects compiler {compiler!r}, which was not found on PATH. "
            "Unset or fix that CC-family setting."
        )
    resolved = realpath(path)
    selected_clang = realpath(clang)
    # /usr/bin/cc and /usr/bin/clang are Apple's xcrun shims and can point at a
    # different Xcode toolchain path than `xcrun --find clang` reports while
    # still using the selected Xcode. Accept those system shims explicitly.
    apple_shim = resolved in ("/usr/bin/cc", "/usr/bin/clang")
    if resolved != selected_clang and not apple_shim:
        raise PreflightError(
            f"{source} selects {compiler!r} ({path!r}), which is not the clang "
            f"selected by `xcrun --sdk macosx --find clang` ({clang!r}). Unset "
            "or fix that CC-family setting so Cargo's C dependencies use the "
            "validated SDK compiler."
        )
    return path


def check_sdk_flags(sdk_path, rust_host, rust_target, environ=None, realpath=os.path.realpath):
    """Reject effective CC/CFLAGS sysroot overrides that select another SDK."""
    environ = os.environ if environ is None else environ
    try:
        overrides = []

        selected = native_tools.effective_tool(environ, "CC", rust_host, rust_target)
        if selected is not None:
            overrides.extend(
                native_tools.sdk_overrides(
                    selected.arguments, f"{selected.source} compiler arguments"
                )
            )

        for variable, tokens in native_tools.flag_settings(
            environ, "CFLAGS", rust_host, rust_target
        ):
            overrides.extend(native_tools.sdk_overrides(tokens, variable))

        native_tools.check_sdk_overrides(overrides, sdk_path, realpath)
    except native_tools.NativeToolError as error:
        raise PreflightError(str(error)) from error
    return sdk_path


def check_xcode(runner=subprocess.run):
    """Return (sdk_path, sdk_version, clang) after validating CLT and the SDK."""
    developer = _capture(
        ["xcode-select", "-p"],
        runner,
        "Xcode Command Line Tools are not selected. " + XCODE_SELECT_HELP,
    )
    if not Path(developer).is_dir():
        raise PreflightError(
            f"`xcode-select -p` reports {developer!r}, which is not a directory. "
            + XCODE_SELECT_HELP
        )

    sdk_path = _capture(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
        runner,
        "`xcrun --sdk macosx --show-sdk-path` could not locate the macOS SDK. "
        + XCODE_SELECT_HELP,
    )
    if not Path(sdk_path).is_dir():
        raise PreflightError(
            f"`xcrun --sdk macosx --show-sdk-path` returned {sdk_path!r}, which "
            "does not exist. " + XCODE_SELECT_HELP
        )

    sdk_version = _capture(
        ["xcrun", "--sdk", "macosx", "--show-sdk-version"],
        runner,
        "could not determine the macOS SDK version. " + XCODE_SELECT_HELP,
    )

    clang = _capture(
        ["xcrun", "--sdk", "macosx", "--find", "clang"],
        runner,
        "the macOS SDK does not provide clang. " + XCODE_SELECT_HELP,
    )
    check_clang(clang, runner)
    return sdk_path, sdk_version, clang


def check_host(system=None, machine=None):
    system = system if system is not None else platform.system()
    if system != "Darwin":
        raise PreflightError(
            f"native macOS desktop configuration requires Darwin; this host is "
            f"{system!r}. The preflight is only added to the macOS desktop graph."
        )
    check_arm64(machine)
    return system


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--deployment-target",
        default=MIN_MACOS_TEXT,
        help=f"macOS deployment target required by the build (default: {MIN_MACOS_TEXT})",
    )
    parser.add_argument(
        "--rust-target",
        default="aarch64-apple-darwin",
        help="output Rust target used for cc-rs CC/CFLAGS precedence",
    )
    args = parser.parse_args(argv)

    check_host()
    check_arm64(platform.machine(), is_translated())
    running_version = check_running_os()
    check_running_version(running_version, args.deployment_target)
    sdk_path, sdk_version, clang = check_xcode()
    sdk_path = check_sdkroot(sdk_path)
    check_selected_cc(clang, args.rust_target, args.rust_target)
    check_sdk_flags(sdk_path, args.rust_target, args.rust_target)
    check_deployment_target(args.deployment_target, sdk_version)
    print(
        f"macOS preflight OK: arm64, running macOS {running_version}, "
        f"SDK {sdk_version} at {sdk_path}, clang {clang}, "
        f"deployment target {args.deployment_target}"
    )


if __name__ == "__main__":
    try:
        main()
    except PreflightError as error:
        sys.exit(f"macOS preflight failed: {error}")
