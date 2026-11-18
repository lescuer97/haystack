"""Namespace audit regressions, including Python's optimized execution modes."""
from pathlib import Path
import types
import unittest
from unittest import mock


SOURCE = Path(__file__).with_name("check_server_namespace.py").read_text()
HEADER = "SQLITE_API int sqlite3_initialize(void);\nSQLITE_API const char sqlite3_version[];\n"
MANIFEST = """#define sqlite3_initialize haystack_world_sqlite3_initialize
#define sqlite3_version haystack_world_sqlite3_version
#define sqliteTransientAsDestructor haystack_world_sqliteTransientAsDestructor
"""
BINDINGS = """pub extern fn haystack_world_sqlite3_config() void;
pub extern var haystack_world_sqlite3_temp_directory: ?[*:0]u8;
pub extern const haystack_world_sqlite3_version: [7]u8;
"""
SYMBOLS = """world.o:
00000000 T haystack_world_sqlite3_initialize
00000000 T _haystack_world_sqliteTransientAsDestructor
"""


class NamespaceTests(unittest.TestCase):
    def run_audit(self, optimize, changes, error=None):
        module = types.ModuleType("namespace_audit_test")
        exec(compile(SOURCE, "check_server_namespace.py", "exec", optimize=optimize), module.__dict__)
        fixtures = dict(header=HEADER, manifest=MANIFEST, bindings=BINDINGS, symbols=SYMBOLS)
        fixtures.update(changes)
        with mock.patch.object(module, "Path", side_effect=lambda path: mock.Mock(
                read_text=mock.Mock(return_value=fixtures[path]))), \
                mock.patch.object(module.subprocess, "check_output", return_value=fixtures["symbols"]) as nm, \
                mock.patch("builtins.print") as output:
            if error is None:
                module.check("archive.a", "header", "bindings", "manifest")
                nm.assert_called_once_with(["nm", "-g", "archive.a"], text=True)
                output.assert_called_once_with(
                    "world SQLite namespace: 2 public APIs, translated externs and archive checked")
            else:
                with self.assertRaises(ValueError) as raised:
                    module.check("archive.a", "header", "bindings", "manifest")
                self.assertIn(error, str(raised.exception))
                output.assert_not_called()

    def test_valid_under_all_optimization_levels(self):
        for optimize in (0, 1, 2):
            with self.subTest(optimize=optimize):
                self.run_audit(optimize, {})

    def test_invalid_under_all_optimization_levels(self):
        cases = [
            ("missing alias", {"manifest": MANIFEST.replace(
                "#define sqlite3_version haystack_world_sqlite3_version\n", "")},
             "manifest alias for sqlite3_version"),
            ("wrong alias", {"manifest": MANIFEST.replace(
                "haystack_world_sqlite3_initialize", "wrong_initialize")},
             "manifest alias for sqlite3_initialize"),
            ("missing helper alias", {"manifest": MANIFEST.replace(
                "#define sqliteTransientAsDestructor haystack_world_sqliteTransientAsDestructor\n", "")},
             "manifest alias for sqliteTransientAsDestructor"),
            ("unparseable API", {"header": HEADER + "SQLITE_API int unknown_api(void);\n"},
             "unparseable SQLITE_API declaration: SQLITE_API int unknown_api"),
            ("explicit linkname", {"bindings": BINDINGS + '.name = "sqlite3_open"'},
             "unprefixed explicit linkname: sqlite3_open"),
            ("wrong version size", {"bindings": BINDINGS.replace("[7]", "[8]")},
             "missing required version binding: haystack_world_sqlite3_version"),
        ]
        for kind in ("fn", "var", "const"):
            cases.append((f"plain extern {kind}", {"bindings": BINDINGS + f"extern {kind} sqlite3_open"},
                          "unprefixed translated extern: sqlite3_open"))
        for line in BINDINGS.splitlines(keepends=True):
            name = line.split()[3].split(":")[0].split("(")[0]
            cases.append((f"missing {name}", {"bindings": BINDINGS.replace(line, "")}, name))
        for symbol in ("haystack_world_sqlite3_initialize", "_haystack_world_sqliteTransientAsDestructor"):
            cases.append((f"missing {symbol}", {"symbols": SYMBOLS.replace(f"00000000 T {symbol}\n", "")},
                          "missing required archive symbol: " + symbol.removeprefix("_")))
        for kind in ("T", "U"):
            for prefix in ("", "_"):
                cases.append((f"plain archive {kind} {prefix}",
                              {"symbols": SYMBOLS + f" {kind} {prefix}sqlite3_open\n"},
                              "unprefixed archive symbols: sqlite3_open"))
        for name in ("malloc", "calloc", "realloc", "free"):
            cases.append((name, {"symbols": SYMBOLS + f" U {name}\n"},
                          "forbidden archive allocator symbols: " + name))
        for optimize in (0, 1, 2):
            for label, changes, error in cases:
                with self.subTest(optimize=optimize, case=label):
                    self.run_audit(optimize, changes, error)


if __name__ == "__main__":
    unittest.main()
