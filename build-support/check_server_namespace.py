"""Audit the pinned public API manifest, translated linkage and real C archive."""
from pathlib import Path
import re
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check(archive, header, bindings, manifest):
    source = re.sub(r"/\*.*?\*/", "", Path(header).read_text(), flags=re.S)
    public = set()
    for declaration in re.findall(r"^SQLITE_API\b[^;]*;", source, re.M):
        match = re.search(r"\b(sqlite3\w*)\s*(?:\(|\[|;)", declaration)
        require(match, f"unparseable SQLITE_API declaration: {declaration}")
        public.add(match[1])
    aliases = dict(re.findall(r"^#define (\w+) (\w+)$", Path(manifest).read_text(), re.M))
    for name in public | {"sqliteTransientAsDestructor"}:
        require(aliases.get(name) == "haystack_world_" + name,
                f"manifest alias for {name}: expected haystack_world_{name}, got {aliases.get(name)!r}")
    translated = Path(bindings).read_text()
    plain = re.search(r"\bextern\s+(?:fn|var|const)\s+(sqlite\w*)", translated)
    require(not plain, f"unprefixed translated extern: {plain[1] if plain else ''}")
    for declaration in ("extern fn haystack_world_sqlite3_config",
                        "extern var haystack_world_sqlite3_temp_directory"):
        require(declaration in translated, f"missing required binding: {declaration}")
    plain = re.search(r'\.name = "(sqlite\w*)', translated)
    require(not plain, f"unprefixed explicit linkname: {plain[1] if plain else ''}")
    require(re.search(r'haystack_world_sqlite3_version: \[7\]', translated),
            "missing required version binding: haystack_world_sqlite3_version: [7]")
    # -g includes definitions AND unresolved references, for every member.
    symbols = subprocess.check_output(["nm", "-g", str(archive)], text=True)
    names = {line.split()[-1].removeprefix("_") for line in symbols.splitlines() if line.split()}
    plain = {name for name in names if name.startswith("sqlite")}
    require(not plain, f"unprefixed archive symbols: {', '.join(sorted(plain))}")
    for name in ("haystack_world_sqlite3_initialize", "haystack_world_sqliteTransientAsDestructor"):
        require(name in names, f"missing required archive symbol: {name}")
    allocators = {"malloc", "calloc", "realloc", "free"} & names
    require(not allocators, f"forbidden archive allocator symbols: {', '.join(sorted(allocators))}")
    print(f"world SQLite namespace: {len(public)} public APIs, translated externs and archive checked")


if __name__ == "__main__":
    check(*sys.argv[1:])
