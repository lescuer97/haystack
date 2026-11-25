"""Report stack-hardening evidence from one crate's native Rust archive members."""

import argparse
from collections import Counter
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


DEFAULT_ARCHIVE = (
    Path(__file__).resolve().parents[1]
    / "vendor/cdk-wallet-ffi/target/x86_64-unknown-linux-gnu/release/libcdk_wallet_ffi.a"
)
TOOL_ENV = dict(os.environ, LC_ALL="C")
SYMBOL = re.compile(r"\s*[0-9a-f]+ <(.+)>:")
INSTRUCTION = re.compile(r"\s*[0-9a-f]+:\s+(.+)")
PAGE_STEP = re.compile(r"subq?\s+\$0x1000,\s*%rsp")
PAGE_TOUCH = re.compile(r"(?:movq?|orq?)\s+\$0x0,\s*\(%rsp\)")
CANARY_RELOCATION = re.compile(
    r"R_X86_64_\S+\s+(__stack_chk_(?:fail(?:_local)?|guard))(?:[+-]0x[0-9a-f]+)?"
)


def crate_members(names, crate):
    # Restrict attribution to rustc's codegen-unit naming convention for this
    # crate; .o suffixes or symbols alone cannot distinguish bundled C code.
    name = re.escape(crate.replace("-", "_"))
    prefix = rf"(?:{name}-[0-9a-f]+|lib{name})"
    pattern = re.compile(rf"{prefix}\.{name}\.[0-9a-f]+-cgu\.\d+\.rcgu\.o")
    return [member for member in names if pattern.fullmatch(member)]


def object_kind(path):
    with path.open("rb") as member:
        header = member.read(20)
    if header[:4] == b"\x7fELF" and len(header) == 20 and header[5] in (1, 2):
        order = "little" if header[5] == 1 else "big"
        elf_type = int.from_bytes(header[16:18], order)
        machine = int.from_bytes(header[18:20], order)
        if (machine, header[4], order, elf_type) == (62, 2, "little", 1):
            return "x86_64 ELF relocatable"
        arch = {3: "x86", 62: "x86_64", 183: "AArch64", 243: "RISC-V"}.get(machine, str(machine))
        return f"ELF ({arch}, class={header[4]}, {order}-endian, e_type={elf_type})"
    if header[:4] in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce"):
        return "Mach-O"
    if header[:4] in (b"BC\xc0\xde", b"\xde\xc0\x17\x0b"):
        return "LLVM bitcode (no native instructions to inspect)"
    return "unknown object format"


def scan_disassembly(lines):
    """Return the first probe location and any canary-related code relocations."""
    symbol = None
    previous_step = False
    probe = None
    canary_symbols = set()
    for line in lines:
        line = line.strip()
        if match := SYMBOL.fullmatch(line):
            symbol = match[1]
            previous_step = False
        elif match := INSTRUCTION.fullmatch(line):
            instruction = match[1]
            if relocation := CANARY_RELOCATION.fullmatch(instruction):
                canary_symbols.add(relocation[1])
            if instruction.startswith("R_X86_64_"):
                continue
            if probe is None and previous_step and PAGE_TOUCH.fullmatch(instruction):
                probe = f"{symbol} (touch at 0x{line.split(':', 1)[0]})"
            previous_step = symbol is not None and bool(PAGE_STEP.fullmatch(instruction))
        elif not line or line.startswith("Disassembly of section "):
            symbol = None
            previous_step = False
    return probe, canary_symbols


def report(archive, crate):
    print(f"Archive: {archive}")
    print(f"Scope: {crate} Rust codegen units (by rustc member name), not other Rust crates or bundled C objects.")
    print("Executable PIE, RELRO and stack permissions are out of scope for this archive report.")
    print("Pinned Rust 1.99.0 stable cannot enable nightly -Z stack-protector; this does not verify build flags.")

    with archive.open("rb") as artifact:
        magic = artifact.read(8)
    if magic == b"!<thin>\n":
        print("Not audited: thin archive (members are external files).")
        return 3
    if magic != b"!<arch>\n":
        raise ValueError("expected a native ar archive, not a linked executable or standalone object")

    ar = shutil.which("ar")
    if ar is None:
        raise ValueError("ar is required to list and extract archive members")
    names = subprocess.check_output([ar, "t", archive], text=True, env=TOOL_ENV).splitlines()
    members = crate_members(names, crate)
    print(f"Selected {len(members)} of {len(names)} archive members.")
    if not members:
        print("Not audited: no matching Rust codegen-unit names (check --crate or archive provenance).")
        return 3
    if len(set(members)) != len(members):
        raise ValueError("duplicate selected member names; ar p cannot unambiguously select the objects")

    inspected = 0
    probes = []
    canaries = []
    skipped = Counter()
    objdump = None
    with tempfile.TemporaryDirectory(prefix="rust-hardening-") as tmp:
        object_path = Path(tmp) / "member.o"
        for member in members:
            with object_path.open("wb") as output:
                subprocess.run([ar, "p", archive, member], stdout=output, check=True, env=TOOL_ENV)
            kind = object_kind(object_path)
            if kind != "x86_64 ELF relocatable":
                skipped[kind] += 1
                continue
            if objdump is None:
                objdump = shutil.which("objdump")
                if objdump is None or not subprocess.check_output(
                    [objdump, "--version"], text=True, env=TOOL_ENV
                ).startswith("GNU objdump"):
                    raise ValueError("GNU objdump with x86_64 support is required for the instruction scan")
            # Only extract one object at a time and stream its disassembly.
            with subprocess.Popen(
                [objdump, "-dr", "-M", "att", "--no-show-raw-insn", object_path],
                stdout=subprocess.PIPE, text=True, env=TOOL_ENV,
            ) as disassembly:
                probe, symbols = scan_disassembly(disassembly.stdout)
                if disassembly.wait():
                    raise ValueError(f"GNU objdump could not disassemble {member}; check its x86_64 support")
            inspected += 1
            if probe:
                probes.append((member, probe))
            if symbols:
                canaries.append((member, ", ".join(sorted(symbols))))

    print(f"Inspected {inspected}/{len(members)} selected members: x86_64 ELF only (GNU objdump).")
    for kind, count in sorted(skipped.items()):
        print(f"Not audited: {count} member(s) of type {kind}; no instruction check for this target/format.")
    if inspected:
        print(f"Inline stack probes: {'observed' if probes else 'not observed'} in {len(probes)}/{inspected} inspected members.")
        for member, location in probes[:3]:
            print(f"  {member}: {location}")
        print("  Looks for a 4 KiB stack decrement immediately followed by a touch at %rsp (Linux x86_64 pattern).")
        print("  Large frames may need probes; this pattern check does not establish coverage or prove absence.")
        print(f"Stack-canary-related code relocations: {'observed' if canaries else 'not observed'} in "
              f"{len(canaries)}/{inspected} inspected members.")
        for member, symbols in canaries[:3]:
            print(f"  {member}: {symbols}")
        print("  Relocations alone do not prove compiler-inserted canaries; absence is not a canary audit.")
    return 3 if skipped else 0


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog="Exit 0: report completed (findings are informational); 1: input/tool error; "
        "2: usage error; 3: skipped or partial audit.",
    )
    parser.add_argument("archive", nargs="?", type=Path, default=DEFAULT_ARCHIVE,
                        help="native static library (default: vendored Linux x86_64 CDK wallet archive)")
    parser.add_argument("--crate", default="cdk_wallet_ffi", help="Rust library crate name (default: cdk_wallet_ffi)")
    args = parser.parse_args()
    try:
        return report(args.archive.resolve(), args.crate)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Rust hardening report failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
