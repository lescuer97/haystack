#!/usr/bin/env python3
"""Check or provision the pinned Emscripten SDK exactly once.

Normal browser builds pass ``--check`` and never update or install anything.
Only ``zig build setup -Dplatform=wasm`` passes ``--provision``; even then an
already matching SDK is reused without ``emsdk update``. The upstream raylib
build's unconditional activation step is detached by the Zig graph.
"""
from pathlib import Path
import argparse
import subprocess
import sys

EMSDK_VERSION = "4.0.19"


def emcc_path(root):
    return root / "upstream/emscripten/emcc.py"


def parse_emcc_version(output):
    """Return the exact version token from the first line of `emcc --version`.

    Emscripten prints a banner such as:

        emcc (Emscripten gcc/clang-like replacement + linker emulating GNU ld) 4.0.19 (hash)

    Only the first whitespace-delimited token that starts with a digit is the
    version. Callers compare it for exact equality, so suffixes such as
    ``4.0.190`` or ``4.0.19x`` and arbitrary text containing the pin are not
    accepted as the pinned SDK.
    """
    first_line = output.partition("\n")[0].strip()
    if not first_line.startswith("emcc "):
        return None
    for token in first_line.split()[1:]:
        candidate = token.strip("(),;")
        if candidate and candidate[0].isdigit():
            return candidate
    return None


def valid_emsdk(root, runner=subprocess.run, python=sys.executable):
    emcc = emcc_path(root)
    if not emcc.is_file() or not (root / ".emscripten").is_file():
        return False
    try:
        version = runner(
            [python, str(emcc), "--version"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return version.returncode == 0 and parse_emcc_version(version.stdout) == EMSDK_VERSION


def missing_tool_error(provision, offline, setup_command):
    what = f"Emscripten {EMSDK_VERSION} is missing or incompatible"
    if not provision:
        return RuntimeError(
            f"{what}; normal builds never install SDKs. Run `{setup_command}` "
            "to provision browser tools."
        )
    if offline:
        return RuntimeError(
            f"{what}; -Doffline forbids downloading it. Run `{setup_command}` "
            "without -Doffline."
        )
    return None


def ensure_emsdk(
    root,
    *,
    provision,
    offline,
    setup_command,
    runner=subprocess.run,
    python=sys.executable,
):
    root = Path(root).resolve()
    if valid_emsdk(root, runner=runner, python=python):
        return
    error = missing_tool_error(provision, offline, setup_command)
    if error:
        raise error
    sdk = root / "emsdk.py"
    for command in (["update"], ["install", EMSDK_VERSION], ["activate", EMSDK_VERSION]):
        # Bound transient network failures during first installation, never
        # silently reuse an incompatible or partially installed toolchain.
        runner(
            [python, str(sdk), *command],
            cwd=root,
            check=True,
            timeout=600,
        )
    for script in (emcc_path(root), root / "upstream/emscripten/emrun"):
        script.chmod(script.stat().st_mode | 0o111)
    if not valid_emsdk(root, runner=runner, python=python):
        raise RuntimeError(
            f"Emscripten installation did not produce the expected version {EMSDK_VERSION}"
        )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument(
        "--setup-command", default="zig build setup -Dplatform=wasm"
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--check", action="store_true", help="Only verify the installed SDK; never update or install"
    )
    mode.add_argument(
        "--provision", action="store_true", help="Install the pinned SDK (explicit setup only)"
    )
    args = parser.parse_args(argv)
    try:
        ensure_emsdk(
            args.root,
            provision=bool(args.provision),
            offline=args.offline,
            setup_command=args.setup_command,
        )
    except (
        RuntimeError,
        OSError,
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
    ) as error:
        sys.exit(f"Emscripten setup failed: {error}")


if __name__ == "__main__":
    main()
