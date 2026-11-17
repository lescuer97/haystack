# Vendored SQLite integration

Upstream wrapper: https://github.com/vrischmann/zig-sqlite
revision `1eba1e490629897e71dc3a23aad6fe9a319e0c82` (MIT; see LICENSE).
Downloaded the GitHub archive for that exact revision, not a mutable branch.

Local patches: `build.zig.zon` replaces SQLite 3.49.2 with official SQLite 3.54.0;
`build.zig` adjusts include/source/header paths for the archive directory retained
by this Zig 0.17 build dependency extractor. Wrapper API source is unchanged.
The server actually imports the wrapper module's public `c` export, using raw
SQLite APIs for heap configuration, prepared statements and checked cleanup.
It does not use `all`, `nextAlloc`, or wrapper reset logging.

SQLite source: https://www.sqlite.org/2026/sqlite-amalgamation-3540000.zip

- ZIP SHA-256: `68e913b0fe8ec6b4e5f391c594a28872884e80d6cd042a1e50c957be46b5aa4d`
- Verified build dependency content hash:
  `N-V-__8AAIbIsABmhNL-E7oK5rlD3SerdmNKnogPURc3BRc3`
- This installed Zig's standalone `zig fetch` strips the ZIP root for hashing
  and reports `N-V-__8AAIbIsACiE8KD1p1yFmEmwfDyxM6oeFpCwhUhBARB` instead.
  Its build dependency extractor retains `sqlite-amalgamation-3540000/` and
  reports the first hash. The manifest pins the actual build-verified hash;
  the ZIP digest was independently checked on two downloads. No cache source
  was edited to make the hashes agree.
- SQLite is public domain: https://www.sqlite.org/copyright.html .
- SQLite 3.49.2 was deliberately not used because of the older WAL-reset
  corruption bug affecting multiple connections.

Translate-C dependency remains upstream's exact revision
`cfac21f3199b2b02ce3fd7db652aa456421fe4ab`, hash
`translate_c-2.0.2-Q_BUWvBNBwDnyehSiuAJmdFcMYHYGA-Jc3KiYdrV2Dqx`.

Root build selects `memsys5=true`, `zero_malloc=true`, `omit_autoinit=true`,
`threadsafe=1`. The resulting server does not dynamically link system sqlite3.
No SQLite scheduling/durability options were relaxed. In particular, builds
retain WAL, FULL synchronous commits and SQLite's default checkpoint policy.
