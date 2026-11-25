"""Tests for the standalone Rust archive report."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from check_rust_hardening import crate_members, scan_disassembly


SCRIPT = Path(__file__).with_name("check_rust_hardening.py").resolve()
RUST_OBJECT = "fixture-aaaa.fixture.bbbb-cgu.0.rcgu.o"


class DisassemblyTests(unittest.TestCase):
    def test_cargo_and_direct_rustc_member_names(self):
        direct = "libfixture.fixture.bbbb-cgu.0.rcgu.o"
        names = [RUST_OBJECT, direct, "fixture-c.o", "other-aaaa.other.bbbb-cgu.0.rcgu.o"]
        self.assertEqual(crate_members(names, "fixture"), [RUST_OBJECT, direct])

    def test_page_probe_and_canary_relocation_are_separate_observations(self):
        probe, symbols = scan_disassembly([
            "0000 <rust_function>:",
            "   0: sub $0x1000,%rsp",
            "   7: movq $0x0,(%rsp)",
            "   f: call 14 <rust_function+0x14>",
            "  10: R_X86_64_PLT32 __stack_chk_fail-0x4",
        ])
        self.assertEqual(probe, "rust_function (touch at 0x7)")
        self.assertEqual(symbols, {"__stack_chk_fail"})

    def test_unrelated_instructions_do_not_form_a_probe(self):
        for intervening_line in ("0007 <other>:", "   7: nop", "Disassembly of section .text.other:"):
            with self.subTest(intervening_line=intervening_line):
                probe, symbols = scan_disassembly([
                    "0000 <rust_function>:",
                    "   0: sub $0x1000,%rsp",
                    intervening_line,
                    "   8: movq $0x0,(%rsp)",
                    "  10: call 0 <__stack_chk_fail>",
                    "  11: R_X86_64_PLT32 __stack_chk_failure-0x4",
                ])
                self.assertIsNone(probe)
                self.assertFalse(symbols)


@unittest.skipUnless(sys.platform == "linux" and shutil.which("ar"), "requires Linux binutils fixtures")
class ArchiveTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.directory = Path(scratch.name)
        self.archive = self.directory / "libfixture.a"

    def make_archive(self, *names):
        subprocess.run(["ar", "rcs", self.archive, *names], cwd=self.directory, check=True)

    def report(self):
        return subprocess.run([sys.executable, SCRIPT, self.archive, "--crate", "fixture"],
                              capture_output=True, text=True)

    def test_non_archive_is_an_error(self):
        self.archive.write_bytes(b"\x7fELF")
        result = self.report()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("expected a native ar archive", result.stderr)

    def test_other_architecture_is_not_a_negative_finding(self):
        # Little-endian ELF64 ET_REL header identifying AArch64.
        header = bytearray(64)
        header[:7] = b"\x7fELF\x02\x01\x01"
        header[16:24] = b"\x01\x00\xb7\x00\x01\x00\x00\x00"  # e_type, e_machine, e_version
        header[52] = len(header)  # e_ehsize
        (self.directory / RUST_OBJECT).write_bytes(header)
        self.make_archive(RUST_OBJECT)
        result = self.report()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("Not audited: 1 member(s) of type ELF (AArch64", result.stdout)
        self.assertNotIn("not observed", result.stdout)

    def test_ignores_native_dependency_objects(self):
        if not all(shutil.which(tool) for tool in ("as", "objdump")):
            self.skipTest("requires GNU x86_64 as and objdump")
        check = subprocess.run(["as", "--64", "--version"], capture_output=True)
        version = subprocess.check_output(["objdump", "--version"])
        if check.returncode or not version.startswith(b"GNU objdump"):
            self.skipTest("requires GNU x86_64 as and objdump")
        # A non-Rust member has both signals and must not affect the report.
        for name, instructions in (
            (RUST_OBJECT, "ret"),
            ("native_dep.o", "sub $0x1000,%rsp\nmovq $0,(%rsp)\ncall __stack_chk_fail\nret"),
        ):
            subprocess.run(["as", "--64", "-o", name, "-"], cwd=self.directory,
                           input=f".text\n.globl entry\nentry:\n{instructions}\n", text=True, check=True)
        self.make_archive(RUST_OBJECT, "native_dep.o")
        result = self.report()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Selected 1 of 2", result.stdout)
        self.assertIn("Inline stack probes: not observed", result.stdout)
        self.assertIn("Stack-canary-related code relocations: not observed", result.stdout)


if __name__ == "__main__":
    unittest.main()
