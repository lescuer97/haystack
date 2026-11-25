"""Verify a GNU/Linux or macOS standalone release and its private debug copy."""
import argparse
import filecmp
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile


def verify_elf_hardening(binary):
    dynamic = subprocess.check_output(["readelf", "-dW", binary], text=True)
    headers = subprocess.check_output(["readelf", "-lW", binary], text=True)
    if not re.search(r"\(FLAGS_1\).*\bPIE\b", dynamic):
        raise RuntimeError(f"{binary} must be a PIE")
    if "GNU_RELRO" not in headers or not re.search(r"\b(?:BIND_NOW|NOW)\b", dynamic):
        raise RuntimeError(f"{binary} must use full RELRO")
    stack = re.search(r"(?m)^\s*GNU_STACK\b(.*)$", headers)
    if stack is None or not re.search(r"\sRW\s", stack.group(1)):
        raise RuntimeError(f"{binary} must have a non-executable stack")
    if re.search(r"(?m)^\s*LOAD\b.*\bRW\s*E\b", headers) or re.search(r"\bTEXTREL\b", dynamic):
        raise RuntimeError(f"{binary} must not have writable-executable segments or text relocations")
    if "(RPATH)" in dynamic or "(RUNPATH)" in dynamic:
        raise RuntimeError(f"{binary} has a runtime search path")
    return dynamic


def verify_links(binary):
    if platform.system() == "Darwin":
        dependencies = subprocess.check_output(["otool", "-L", binary], text=True).splitlines()[1:]
        dylibs = [line.strip().split(" (", 1)[0] for line in dependencies]
        if not dylibs or any(not path.startswith(("/usr/lib/", "/System/Library/Frameworks/")) for path in dylibs):
            raise RuntimeError(f"unexpected Mach-O dependencies: {dylibs}")
        header = subprocess.check_output(["otool", "-hv", binary], text=True)
        if not re.search(r"\bPIE\b", header) or "ALLOW_STACK_EXECUTION" in header:
            raise RuntimeError("standalone Mach-O must enable PIE without allowing stack execution")
        commands = subprocess.check_output(["otool", "-l", binary], text=True)
        if "LC_RPATH" in commands:
            raise RuntimeError("standalone Mach-O has an rpath")
        if "__DWARF" in commands:
            raise RuntimeError("standalone Mach-O still contains debug sections")
        subprocess.run(["codesign", "--verify", "--strict", binary], check=True)
        build = subprocess.check_output(["xcrun", "vtool", "-show-build", binary], text=True)
        if not re.search(r"(?m)^\s*minos 15\.0\s*$", build):
            raise RuntimeError(f"unexpected macOS deployment target:\n{build}")
        print("System dependencies:", ", ".join(dylibs))
    elif platform.system() == "Linux":
        sections = subprocess.check_output(["readelf", "--wide", "--sections", binary], text=True)
        if re.search(r"\s\.(?:z?debug_\S*|symtab)\s", sections):
            raise RuntimeError("standalone ELF still contains debug sections or a static symbol table")
        dynamic = verify_elf_hardening(binary)
        needed = set(re.findall(r"\(NEEDED\).*\[(.*?)\]", dynamic))
        if "libc.so.6" not in needed:
            raise RuntimeError("the Linux release audit requires a glibc-linked executable (not musl)")
        system = {
            "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1",
            "libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1", "libutil.so.1",
            "libX11.so.6",
        }
        if unexpected := needed - system:
            raise RuntimeError(f"unexpected ELF dependencies: {sorted(unexpected)}")
        resolved = subprocess.check_output(["ldd", binary], text=True)
        if "not found" in resolved:
            raise RuntimeError(f"unresolved ELF dependencies:\n{resolved}")
        print("System dependencies:", ", ".join(sorted(needed)))
        versions = subprocess.check_output(["readelf", "--version-info", binary], text=True)
        glibc = {tuple(map(int, item.split("."))) for item in re.findall(r"GLIBC_([\d.]+)", versions)}
        if glibc:
            print("Highest required glibc symbol version:", ".".join(map(str, max(glibc))))
    else:
        raise RuntimeError("release audit supports GNU/Linux and Apple Silicon macOS")


def verify_debug_copy(binary, debug, scratch):
    if debug.stat().st_size <= binary.stat().st_size:
        raise RuntimeError("expected a larger, unstripped private executable")
    if platform.system() == "Darwin":
        def uuids(path):
            output = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", path], text=True)
            return set(re.findall(r"UUID: ([\da-fA-F-]+) \([^)]+\)", output))

        release_ids = uuids(binary)
        if not release_ids or release_ids != uuids(debug):
            raise RuntimeError("standalone release and private Mach-O UUIDs do not match")
    else:
        stripped_debug = scratch / "stripped-debug"
        subprocess.run(["strip", "--strip-unneeded", "-o", stripped_debug, debug], check=True)
        if not filecmp.cmp(binary, stripped_debug, shallow=False):
            raise RuntimeError("standalone release does not match the archived debug executable")
        if platform.machine() == "x86_64":
            verify_x86_stack_code(debug)
    print("Verified matching private debug executable")


def verify_x86_stack_code(binary):
    # checksec cannot see these patterns reliably after stripping, and Zig's
    # out-of-line probe is not the inline GCC/Clang sequence it looks for.
    canary = probe = False
    with subprocess.Popen(["objdump", "-d", binary], stdout=subprocess.PIPE, text=True) as disassembly:
        for line in disassembly.stdout:
            canary |= "%fs:0x28" in line
            probe |= bool(re.search(r"\bcallq?\s+.*<__zig_probe_stack>", line))
        if disassembly.wait() != 0:
            raise RuntimeError(f"objdump failed for {binary}")
    if not canary or not probe:
        raise RuntimeError(f"missing x86_64 stack hardening in {binary}: canary={canary}, Zig probe={probe}")
    print("Confirmed x86_64 canary accesses and Zig stack-probe calls")


def smoke(binary, home):
    # A release binary would ignore the environment switch and check the real
    # mint at startup. Reject it without executing it. The gated getenv string
    # is referenced by the executable code, so stripping does not remove it.
    if b"HAYSTACK_STANDALONE_SMOKE\0" not in binary.read_bytes():
        raise RuntimeError("--smoke requires an executable built with -Dstandalone-smoke")

    home.mkdir(mode=0o700)
    env = {key: os.environ[key] for key in (
        "DISPLAY", "XAUTHORITY", "LIBGL_ALWAYS_SOFTWARE", "ALSA_CONFIG_PATH",
    ) if key in os.environ}
    env.update(HOME=str(home), TMPDIR=str(home.parent), HAYSTACK_STANDALONE_SMOKE="1")
    try:
        result = subprocess.run(
            [binary], cwd=binary.parent, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30,
        )
    except subprocess.TimeoutExpired as exc:
        print((exc.output or b"").decode(errors="replace"), end="")
        raise RuntimeError("relocated client did not exit within 30 seconds") from exc
    print(result.stdout, end="")
    result.check_returncode()
    if result.stdout.count("IMAGE: Data loaded successfully") < 7 or "Window closed successfully" not in result.stdout:
        raise RuntimeError("relocated client did not load all seven embedded atlases and exit cleanly")
    for milestone in (
        "wallet not initialized; onboarding blocks",
        "embedded music advanced",
        "snip, fail and reward cues played",
    ):
        if f"standalone smoke: {milestone}" not in result.stdout:
            raise RuntimeError(f"relocated client did not confirm: {milestone}")

    if platform.system() == "Darwin":
        config = data = home / "Library/Application Support/haystack"
    else:
        config = home / ".config/haystack"
        data = home / ".local/share/haystack"
    if not config.is_dir():
        raise RuntimeError("relocated client did not initialize its isolated storage")
    if (config / "wallet-onboarding.json").exists() or (data / "wallet").exists():
        raise RuntimeError("wallet startup inspection unexpectedly wrote wallet state")
    if set(binary.parent.iterdir()) != {binary}:
        raise RuntimeError("relocated client unexpectedly wrote output (including a possible private screenshot)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix", type=Path, help="fresh standalone install prefix")
    parser.add_argument("--smoke", action="store_true", help="launch a smoke-enabled build on Linux (X11) or Apple Silicon macOS (WindowServer), with audio output")
    parser.add_argument("--server", type=Path, help="also audit the installed ReleaseSafe Linux server")
    args = parser.parse_args()
    if args.server and platform.system() != "Linux":
        parser.error("--server requires Linux")
    if args.smoke and not (platform.system() == "Linux" or (platform.system(), platform.machine()) == ("Darwin", "arm64")):
        parser.error("--smoke requires Linux or a native Apple Silicon macOS session")
    installed = args.prefix / "desktop-standalone/haystack_game"
    debug = args.prefix / "desktop-standalone-debug/haystack_game"
    if (set(args.prefix.iterdir()) != {installed.parent, debug.parent}
            or any(not path.is_file() or not os.access(path, os.X_OK)
                   or set(path.parent.iterdir()) != {path} for path in (installed, debug))):
        raise RuntimeError(f"expected only the deployable executable at {installed} and its private copy at {debug}")
    with tempfile.TemporaryDirectory(prefix="haystack-standalone-") as tmp:
        scratch = Path(tmp).resolve()
        relocated = scratch / "relocated"
        relocated.mkdir()
        binary = Path(shutil.copy2(installed, relocated))
        verify_links(binary)
        verify_debug_copy(binary, debug, scratch)
        if args.smoke:
            smoke(binary, scratch / "home")
    if args.server:
        verify_elf_hardening(args.server)
        if platform.machine() == "x86_64":
            verify_x86_stack_code(args.server)
        print(f"Verified Linux server hardening: {args.server}")


if __name__ == "__main__":
    main()
