# Local binary server

Zig 0.17.0; vendored WebSocket and zig-sqlite integration. SQLite 3.54.0 is built
from pinned official sources, **not** linked from the system. See
`vendor/zig-sqlite/PROVENANCE.md` and `vendor/websocket/` for revisions/patches.

Native server builds also require the pinned Rust/CDK toolchain (`zig build
setup -Dgame=false`; use `-Doffline` with warmed tools/Cargo caches). The native
CDK target policy applies: native Linux x86_64/aarch64 or Apple Silicon macOS.
Server-only builds do not initialize Raylib; installation remains opt-in.

```sh
zig build server -Dgame=false
zig build run-server -Dgame=false -- /absolute/local/path/world.sqlite3
# executable arguments: [database-path [sqlite-bytes [ws-bytes [app-bytes]]]]
```

Default database: `haystack.sqlite3`, local filesystem only. Standalone endpoint:
**ws://127.0.0.1:9224/?pubkey=<66 hex characters>**. The process bind address
and database-path CLI argument are unchanged. Game/Raylib targets and terrain checksum
`0xec04d88c8e6885e5` are unchanged. No client networking/rendering changes,
authentication, rewards, private gameplay, regrowth or inventory are included.
Loopback is not authentication: local processes and browsers may modify this
world. Do not expose it as a production security boundary.

## Headless wallet startup

Before listening, the server locks its separate `haystack-server` storage root
for its entire lifetime and opens a native CDK wallet. On Linux the defaults are
`~/.config/haystack-server/haystack.lock` and
`~/.local/share/haystack-server/wallet/{seed-words.txt,wallet.sqlite}`.
Absolute nonempty `XDG_CONFIG_HOME`/`XDG_DATA_HOME` overrides are honored; explicit
bases must already exist. macOS uses
`~/Library/Application Support/haystack-server` for both roots. Client storage
(`haystack`), executable name `haystack_server`, world DB path and CLI do not change.

Only a truly absent wallet is automatically created, using a 12-word BIP39 seed.
The seed is plaintext in an owner-only `0600` file, alongside the `0600` wallet
database in private `0700` directories. It is never printed. **The operator is
responsible for securely backing up both the seed and wallet database.** Later
startups validate and reopen that same identity, not a new wallet.

Existing empty, partial, invalid, insecure or locked wallet storage fails startup
without replacement or permission repair. A failed post-commit durability flush
retains the pair and fails that run; restart validates and flushes it again,
including standard-parent/config directory chains. Never delete retained storage
to bypass a failure unless intentionally abandoning that identity and its funds.
No config.json, content directory, onboarding state, UI, wallet worker, wallet
actions or endpoints are added. Mint selection matches the native client:
`https://testnut.cashu.space/`, or the existing isolated `-Dapp-fixture-mint`
override. Opening does not eagerly add a mint, poll or scan for restoration.

Main owns the wallet; App borrows it. WebSocket callback draining and App cleanup
precede wallet close; the root lock is released last. CDK/Rust's runtime, SQLite
and allocations are **outside the three reserved server budgets below**. World
SQLite retains its fixed heap and lifecycle, with all public C symbols renamed
at compilation and translation to isolate it from CDK's bundled SQLite. The
server/test/benchmark graphs audit the complete public manifest, translated
extern linkage and actual world archive definitions/unresolved references.

## Ephemeral connection sessions

Every upgrade requires exactly the root URL `/?pubkey=` followed by 66 ASCII
hex characters, decoded to 33 opaque bytes. Hex case is ignored; the `pubkey`
parameter name is case-sensitive. This intentionally strict URL policy rejects
other paths, extra/unknown/duplicate parameters, percent escapes, fragments,
trailing bytes and NULs. All 33-byte values, including zero, are accepted: there
is no curve validation, signature or authentication. **FIXME: validate key
ownership before using identity for authorization.** Public unverified keys allow
key-squatting. One active connection per decoded key is claimed atomically;
duplicates reject the new connection without disturbing the old one. Missing,
malformed or duplicate keys use the existing generic HTTP 400 and close before
HTTP 101, not a custom status or binary registration message.

Sessions are internal RAM only, with immutable connection identity and an
optional packed 8-byte `Location{x:i32,y:i32}` in **tile** coordinates. Location
is UNKNOWN until the first explicit update, distinct from known `(0,0)`.
Every valid update is acknowledged; latest received wins, including reused or
all-zero request IDs. An acknowledgement means RAM acceptance, not durability.
All signed i32 coordinates are accepted for tracking only: no terrain, speed,
proximity or game-rule enforcement. Cut/read rules and durable cut-ID replay
remain unchanged; their connections must first pass the same URL admission.
There is no listing, client query, subscription, broadcast or location history.

Normal/error/shutdown cleanup and failed-upgrade cleanup after admission release
the session. Generation-checked handles protect reused connection records from
stale cleanup/update. Reconnect after close starts UNKNOWN, without a cache.
An undetected old socket may temporarily block reconnect: no heartbeat or
deadline was added. Registry locking never spans database or socket operations.

## Binary v1 (no JSON compatibility)

One binary WebSocket message per request/reply. All integers are explicit
little-endian, signed i32 coordinates use two's complement, never struct layout.
Every message starts with this 20-byte common header:

| Offset | Bytes | Value |
|---|---:|---|
| 0 | 2 | protocol version u16 = 1 |
| 2 | 1 | kind u8 |
| 3 | 1 | flags; only bit 0 (ID present) exists |
| 4 | 16 | opaque ID; all-zero is valid when present |

Requests require flags=1. A no-ID error reply has flags=0 and sixteen zero bytes.
IDs echo only after a complete structurally valid header is known; unknown
version/operation may echo. Unknown flags, incorrect lengths/trailing bytes,
invalid enums/booleans are rejected. Text gets a binary `unsupported_message`
reply without an ID. Logical WebSocket message cap is 128 bytes (control frames
still support 125); actual largest request is 36. Earlier handshake/frame/OOM
failures may close the connection without a structured reply.

| Kind | Payload beginning at offset 20 | Total bytes |
|---|---|---:|
| 1 cut | x:i32, y:i32 | 28 |
| 2 read_area | cx0:i32, cy0:i32, cx1:i32, cy1:i32 | 36 |
| 3 update_location | x:i32, y:i32 | 28 |
| 129 cut success | x:i32, y:i32, terrain:u8, cut:u8 | 30 |
| 130 snapshot | rectangle:16, generator_version:u32, public_seed:32, chunk_count:u16, bitmaps | 106..2122 |
| 131 location_updated | none; flags=1 and echoed request ID required | 20 |
| 255 error | code:u16, current_present:u8, optional state:10 | 23 or 33 |

Terrain values: grass=0, dirt=1, rock=2, tree=3. Booleans are strictly 0/1.
Only `already_cut` carries current state (the same ten-byte layout as kind 129's
payload). Error numbers are frozen, never silently renumbered:

1 invalid_request; 2 unsupported_version; 3 unknown_operation;
4 unsupported_message; 5 too_large; 6 out_of_bounds; 7 invalid_area;
8 area_too_large; 9 not_cuttable; 10 already_cut; 11 request_id_conflict;
12 database_busy; 13 internal_error.

Snapshots contain **every chunk**, including empty chunks, in increasing cy then
cx. Rectangle is inclusive, valid size 1..64 chunks. Metadata offsets are
rectangle=20, generator version=36, public seed=40, chunk count=72, bitmaps=74.
Generator v1 uses the public all-zero 32-byte seed. Each chunk has exactly
32 bytes: bit `local_y*16+local_x`, least-significant bit first. One means cut;
zero is authoritative uncut, not an omitted update. Replace the rectangle's
previous delta view. One consistent SELECT fills a zeroed fixed snapshot;
there is no ORDER BY, truncation, pagination, subscription or temporary list.
All i32 tile coordinates are supported, including negatives; valid chunk
coordinates are [-134217728,134217727], unrelated to renderer pixel bounds.
The cached area SELECT binds 64 column `IN` parameters (unused slots repeat the
first column), then two cy bounds. SQLite's clustered `chunk_state` primary key uses
`cx=? AND cy>? AND cy<?`, avoiding scans of unrelated row history in those
columns. Duplicate IN values do not duplicate rows. This bounds result/VM work
for a fixed rectangle, not all database I/O: B-tree seeks still depend on size.
Public `shared/wire.zig` request/reply codecs allocate nothing and validate exact
lengths; reply decoding also checks snapshot metadata, count and rectangle.

## Rules and durability

Only generated grass/tree can be cut, permanently preserving terrain with
`cut:true`. Dirt/rock reject; another ID for a cut tile gets `already_cut`.
A valid typed cut ID binds `(version,operation,x,y)`. A sixteen-byte SQL BLOB key
stores the original typed terminal success or game error, not encoded bytes.
Same ID/payload replays that original result after restart; an original success
does not become `already_cut`. Changed valid payload conflicts before mutation.
Reads, malformed requests and transient DB/internal errors are not cached.

Development schema **v3** has version/seed metadata, `chunk_state(cx,cy,cuts)`
and unchanged BLOB-ID action results. `chunk_state` is STRICT, WITHOUT ROWID,
with primary key `(cx,cy)`, bounded integer chunk coordinates and exactly 32 BLOB
bytes per occupied chunk. Missing rows mean all-zero uncut bitmaps. There is no
authoritative per-tile cuts table or separate area index. Existing schema v2
databases refuse startup with IncompatibleDatabase: no migration, conversion,
deletion or rewrite is performed. Keep old databases separately; use a new path
for development v3. Retained chunks/IDs still have uncapped disk growth.

WAL, `synchronous=FULL`, 250 ms busy timeout. `BEGIN IMMEDIATE`, chunk bitmap
read/modify/upsert and terminal result insertion are atomic; the write transaction
prevents independent writers from losing different bits in the same chunk.
The 32-byte upsert uses SQLITE_TRANSIENT (a copy inside the fixed SQL heap).
Both lookup and area reads validate BLOB type/length; area rows also validate
integer coordinate types and bounds before indexing/copying. A malformed row is
a database failure, never a successful partial snapshot. Commit completes **before** success
encoding/write. All operational SQL, including BEGIN/COMMIT/ROLLBACK, is cached
per handle. Static ID bindings are cleared before input reuse. Raw reset and
clear-bindings return codes are checked (reset may repeat a previous step error).
Failures attempt rollback and verify autocommit. Poisoned handles are quarantined
and rebuilt inside the same SQLite heap; failed rebuild leaves them unavailable.
There is no automatic replay of a possibly committed action. Delivery uncertainty
is resolved only by a caller resending the same ID. No socket I/O occurs in a
transaction; no checkpoint scheduling or weakened durability was introduced.

## Reserved memory and admission

After readiness, managed application, WebSocket and SQLite heap requests are
served only from startup-reserved memory; there is **no upstream system-heap
fallback**. This does not bound total RSS or exclude OS/kernel allocations,
thread resources/stacks or file-backed mappings. Initialization/shutdown may use
the process allocator. Allocation-related latency is the goal, not a zero-OS-
memory claim or a guaranteed request latency.

Separate startup-configurable defaults:

| Budget | Bytes | Basis |
|---|---:|---|
| SQLite | 4,194,304 | v3 query-stress peak 1,279,296; budget >3x peak |
| WebSocket recycler | 4,194,304 | measured socket-free component peak 812,672 + metadata 65,536 with actual session Handler; room for remaining worker/queue objects and churn |
| Application buffers | 65,536 | stable Layout 21,472 bytes: four contexts 17,344 + session registry 4,128; remaining bytes are headroom |

SQLite uses non-null 8-aligned `SQLITE_CONFIG_HEAP` before explicit initialize,
MEMSYS5 + ZERO_MALLOC + OMIT_AUTOINIT, and global multithread-mode mutexes.
Each NOMUTEX handle is exclusively owned while leased. Per-handle page cache
target is 256 KiB; actual allocations still share the hard fixed SQLite heap.
Close/finalize all handles before SQLite shutdown/free. Tests serialize complete
global lifecycles and perform concurrency within one runtime.

The WS budget must be a power of two, at least 4096, with a correspondingly
aligned startup region. Its synchronized buddy recycler splits/coalesces in
bounded logarithmic steps, charges fixed metadata to the same region, never
retains a backing allocator, and returns OOM rather than growing. Resize stays
within the current block; larger reallocations allocate/copy/free inside the
pool. High-water counters count rounded allocated blocks separately from fixed
metadata. WS measurements are component tests, **not a server/RSS high-water
measurement**. Insufficient budgets fail initialization (named invalid-budget,
SqliteOutOfMemory, InsufficientApplicationBudget or WebSocket OOM errors).

64 total connections **including pending handshakes**, four callback workers,
64 connection-readiness jobs, and **no additional request queue**. Four leased
contexts own their DB handle, prepared statements, 64x32 bitmap and 2122-byte
reply buffer through synchronous socket write; leases do not assume thread
affinity. Location updates bypass DB leasing entirely. A fully decoded cut/read
request without a healthy available context returns
retryable binary `database_busy` **before mutation**, from fixed 33-byte callback
error storage. SQLite heap OOM after admission is internal_error, not a falsely
premutation busy result. At the connection cap, bounded rejection batches try
one nonblocking constant HTTP 503 write, then raw-close; delivery is not promised.
Handshake limits: 5 seconds, 8192 bytes, 32 headers. Fragment buffers are bounded.
`server/ws_config.zig` is shared by production and component tests. All 64
128-byte fragment buffers are prewarmed; 64-way repeated fragment churn requires
zero additional buddy allocation calls. The three-argument callback does not
request an allocator, so callback allocator scratch size is zero. Connection
read buffers remain 64x2048; four callback workers and the 64-job queue are unchanged.
Synchronous writes remain unchanged: a slow reader can block a callback worker
and hold a context. Budgeting does not solve that latency source.

## Socket-free benchmark

```sh
zig build bench-server -Dgame=false -Doptimize=ReleaseSafe
zig build bench-server -Dgame=false -Doptimize=ReleaseSafe -- 128
# Separate opt-in million-chunk out-of-area history regression; no sockets:
zig build bench-server -Dgame=false -Doptimize=ReleaseSafe -- --area-query-stress
# Separate opt-in write-stage instrumentation (default 128, optional 16..512):
zig build bench-server -Dgame=false -Doptimize=ReleaseSafe -- --write-profile 16
```

The stress mode uses the actual cached production statement and the same fixed
4 MiB MEMSYS5 heap in a temporary real-file database. It reports its query plan,
VM steps, empty/two-cut snapshot outcomes and wire hashes, and SQLite current/
peak bytes. History is now **one million distinct outside chunks**, in matching
cx columns but outside the requested cy range; this is not historically equivalent
to the earlier one-million-tile fixture (roughly 62,500 occupied chunks).
Unit tests separately cover 10k/100k outside chunks and four concurrent
active area statements (including their temporary IN structures). VM-step
ceilings, not elapsed time or FULLSCAN_STEP alone, detect the old range-scan bug.
Historical schema-v2 bounded-query stress used 292 VM steps empty and 304 with
two cuts (also 304 in its 10k/100k tile-row tests); its four active SELECTs used
1,097,600 current/peak bytes, leaving 3,096,704 bytes free, and its million-tile
stress peak was 1,302,720 bytes. Those retained measurements concern the older
per-tile schema and history unit, not the chunk schema below.
Latest v3 ReleaseSafe million-chunk stress: 291 VM steps empty, 303 with two cuts;
the 10k/100k two-cut unit cases also used 303 steps. The query plan is
`SEARCH chunk_state USING PRIMARY KEY (cx=? AND cy>? AND cy<?)`.
Both stress replies are complete 64-chunk, 2122-byte snapshots (zero/two bits);
wire Wyhash values remain `24a8e39e3e6cd469` / `8d0ad7a4cd90f111`.
Four simultaneously active 64-column SELECTs used 1,108,608 current/peak bytes,
leaving 3,085,696 bytes of the unchanged SQLite heap free. The million-chunk stress
peak was 1,279,296 bytes; application contexts remain 17,344 bytes within 64 KiB.
Full dense 64-chunk unit cases also assert at most 64 unique returned rows and
fewer than 2000 VM steps. These are memory/work bounds, not latency guarantees.
Historical paired benchmark captures below predate this query fix; their frozen
version-specific results are not measurements of the current query.

Opt-in only, never part of default tests; 16..512 measured iterations per run,
default 128, eight warmups, three runs. Isolated real-file SQLite, no server,
sockets or network. Records individual `RAW,workload,run,thread,index,full_ns,
db_ns,reply_bytes,result_code` rows plus SQLite source/options and budget peaks
(result_code=0 for success). Full path:
decode -> lease -> actions -> binary encode -> release. DB interval includes
lease/actions, not encoding/release. Old baseline interval included per-request
open/actions/close; its full path included JSON and arena cleanup. Percentiles
are nearest-rank over individual samples (384/workload, 1536 for four threads).

Fresh database per workload; identical deterministic streams in old/new runs:
numeric ASCII IDs map to u128 little-endian IDs, with
`1000000+run*10000+thread*1000+i`; new cuts at `(100000+i,thread+run*4)`,
replays primed at `(0,0)`, rule errors at `(-128,-128)`. Sparse/dense snapshots
cover chunks [0,7]x[0,7], seeded with generated grass/tree cuts in [0,127]^2;
sparse keeps linear tile indices divisible by 97, dense keeps all cuttable tiles.
Four-thread contention uses independent IDs/connections against one database.
Current seeding builds fixed `[64][32]` bitmaps and inserts occupied chunk rows
in one transaction, preserving exactly 147/14,045 logical sparse/dense cut tiles
and the original generated-terrain filters and request streams.
Both artifact directories preserve `seed-and-operations.csv`: exact 14,045 dense
and 147 sparse seed rows plus every operation/prime, including warmups. The
post artifact includes its socket-free pure-generator manifest program.

### Benchmark-only write-stage profiling

`--write-profile [16..512]` runs the unchanged new/replay/rule/contention streams,
three runs with eight warmups each, four threads for contention. It does not run
area workloads. The generic `Storage.cutObserved` shares the actual cut body;
production `cut` uses a compile-time no-op observer with no clocks, profiling
allocation or logging. Normal benchmark mode specializes a separate unobserved
worker and retains the nine-column RAW format. Instrumented response encoding
still occurs, but outside the measured storage interval.

Each worker uses fixed stage counters and monotonic `clock_gettime` only in the
benchmark. `WRITE_PROFILE_HEADER` describes sample records:

```text
WRITE_PROFILE,workload,run,thread,index,outcome,result_code,begin_ns,replay_ns,rules_ns,chunk_upsert_ns,result_insert_ns,commit_ns,cleanup_ns,total_ns
```

`outcome` is success, rule_failure (including replay/conflict), or the actual
storage error name such as DatabaseBusy; result_code is the wire game-error code
for rule failures, otherwise zero. Storage errors are not relabeled as internal
errors in these records. Skipped stages are zero. BEGIN includes acquisition
execution **and wait**, not pure lock-wait time. Replay includes the cached result
lookup/reset; rules includes terrain generation, chunk lookup/reset and rules;
upsert/result stages include binding, stepping and checked reset/clear. COMMIT
includes SQLite's unchanged default auto-checkpoint work when triggered: these
measurements cannot isolate fsync from checkpoint time. No WAL hook is installed.
Cleanup includes remaining reset/clear and rollback on errors; total runs from
storage observer entry through checked cleanup, with one finalization on every
exit. A cleanup-poisoned success is reported as PoisonedConnection instead.
Clock/callback overhead perturbs profiling: use normal mode, not these samples,
for fair comparisons. The current schema-v3 measurements are reported below;
the separately labeled historical comparison measures an older frozen version.

### Schema-v3 chunk bitmap comparison (2026-11-17)

Artifacts: `/tmp/opencode/chunk-bitmap-paired-20261117/summary.json`, with
metadata and raw logs in the same directory. Frozen before/after inputs are
`/tmp/opencode/chunk-bitmap-before-20261117` and
`/tmp/opencode/chunk-bitmap-candidate-20261117`; each retains `bin/bench-server`,
`source-fingerprint.sha256` and `seed-and-operations.csv`. The before version
already contains the bounded IN-query fix: this comparison is not against the
older unbounded query or the historical JSON/per-request-connection baseline.
Manifests match, preserving 147 sparse / 14,045 dense logical cuts and all RAW
request streams.

Both binaries were compiled before timing. Normal **uninstrumented ReleaseSafe**
runs executed sequentially AB then BA (two pairs), with no competing compiler
or coordinator-launched timed work. Both used SQLite 3.54.0, WAL/FULL and the
same explicit cwd `/home/leo/Programar/trabajo/open_source/server_initilization`,
with real-file fixtures beneath `.zig-cache/tmp` on `/home` Btrfs. All outcomes
are retained: 768 samples per single-thread workload and 3072 for contention,
per version. Full-path latency in **microseconds**:

| Workload | before p50 / p95 / p99 / max | v3 p50 / p95 / p99 / max |
|---|---|---|
| new cuts | 913.4 / 1038.7 / 1565.3 / 6223.3 | 864.0 / 1019.3 / 1548.4 / 5309.6 |
| replay | 9.5 / 13.6 / 15.0 / 25.1 | 9.2 / 13.9 / 17.0 / 53.4 |
| rule errors | 844.3 / 967.3 / 1099.5 / 3270.8 | 863.2 / 1031.0 / 1322.4 / 3262.0 |
| sparse 64 | 31.4 / 44.0 / 61.2 / 87.7 | 17.2 / 21.4 / 26.8 / 37.2 |
| dense 64 | 1774.8 / 1883.4 / 2066.6 / 2670.2 | 17.9 / 27.7 / 34.0 / 45.3 |
| four threads, all outcomes | 927.2 / 1108.2 / 3216.0 / 251833.2 | 855.4 / 1018.0 / 1544.2 / 129511.5 |

Each version produced identical outcome counts: new cuts 656 successes / 112
not_cuttable; replay 768 already_cut; rule errors 768 not_cuttable; each read
workload 768 successful snapshots; contention 2548 successes / 524 game errors,
zero busy or internal errors. Success-only contention p50/p95/p99/max was
939.3/1120.6/3277.5/251833.2 us before and
856.7/1022.4/1562.0/129511.5 us after.

Dense-read median latency was about 99x lower and p99 about 61x lower in these
runs, confirming the targeted read opportunity. Write changes are modest/mixed:
replay and rule-error p99 increased, and contention maxima remain substantial.
This is not a universal write improvement or latency guarantee. Disk/OS noise
remains; do not compare absolute timings with the older historical host conditions
below. Schema and common cleanup code both changed, so no isolated
allocation-related causal speedup is claimed.

#### Separate instrumented write diagnosis

`/tmp/opencode/chunk-bitmap-write-profile-20261117.log` captures a separate
128-iteration profile: 2688 samples (384 each new/replay/rule, 1536 contention).
New cuts produced 328 successes / 56 rule failures. For successful new cuts,
median BEGIN was 4.53 us, COMMIT 869.47 us and total storage time 882.01 us;
p99 COMMIT/total was 1673.05/1684.73 us. The median **per-request** COMMIT/total
ratio was 98.62% (ratios calculated per request before taking their median,
not a ratio or sum of percentiles). Stage percentiles are not additive; total
also includes the small entry-to-first-stage interval omitted from stage counters.

Profiled contention retained 1270 successes, 262 rule failures and **four
DatabaseBusy** outcomes, with no internal errors. Those four busy outcomes belong
to this instrumented run, not the normal paired comparison above, which had none.
Profiling alone diagnoses COMMIT as dominant for successful new writes on this
run; its timings are not comparable to the uninstrumented samples. COMMIT still
includes default auto-checkpoint work, BEGIN includes execution plus wait, and
there is no hook or fsync-only attribution.

### Historical fair paired comparison (explicit common filesystem)

**The original cross-filesystem comparison is invalid.** Baseline fixtures were
relative to a cwd under `/tmp` (tmpfs), whereas post fixtures were relative to
the repository under `/home` (Btrfs). Changing only cwd with the frozen binaries
reverses the apparent write regression. The earlier durable-write regression
conclusion is withdrawn, not a reason to weaken FULL durability. Historical
artifacts remain untouched apart from a warning in their README:
`/tmp/opencode/binary-server-baseline-WadrmKod` and
`/tmp/opencode/binary-server-post-b6pSj2MI`. The first capture contains the original
uncommitted working tree, not HEAD; original source fingerprints remain preserved.

The following commands document the historical paired comparison, not a
reproducible workflow in this checkout: `build-support/server_bench_dataset.zig`
and `build-support/compare_server_bench.py` (and their driver tests) were not
tracked in the server baseline and are absent here. They have not been restored.
The historical driver used Python 3's standard library and Linux `findmnt`, with
sequential timed pairs after compilation. No new timing claim follows from this
integration. Only `zig build build-bench-server -Dgame=false
-Doptimize=ReleaseSafe` below is a current build command; the missing-helper
commands are retained solely as a record of the old procedure:

```sh
zig build build-bench-server -Dgame=false -Doptimize=ReleaseSafe
zig run --dep shared -Mroot=build-support/server_bench_dataset.zig -Mshared=shared/root.zig 2> current-manifest.csv
find server shared vendor/zig-sqlite -type f -print0 | sort -z | xargs -0 sha256sum > current-source.sha256
# BASELINE is a frozen original benchmark executable, not a rebuilt implementation.
python3 -B build-support/compare_server_bench.py \
  --cwd /absolute/on-disk/checkout \
  --baseline /absolute/frozen/baseline.bin \
  --current /absolute/on-disk/checkout/zig-out/bin/bench-server \
  --baseline-manifest /absolute/frozen/seed-and-operations.csv \
  --current-manifest /absolute/on-disk/checkout/current-manifest.csv \
  --baseline-source-fingerprint /absolute/frozen/source-fingerprint.sha256 \
  --current-source-fingerprint /absolute/on-disk/checkout/current-source.sha256 \
  --baseline-sqlite-options /absolute/frozen/system-sqlite-compile-options.txt \
  --output /absolute/new/report-directory --pairs 2
python3 -B -m unittest discover -s build-support -p 'test_*.py' -v
```

Both executables inherit the same required absolute cwd, use matching default
128-iteration workloads and receive **no iteration arguments** (the frozen Zig
test binary need not accept them). Order alternates AB then BA; at least two
pairs are required. The driver records resolved fixture root and filesystem/device
metadata (validated before/after every run), binary/library hashes, toolchain, SQLite
versions/options, source fingerprints, manifest hashes, exact argv, wall time,
user/system CPU and child rusage peak RSS. Current benchmark logs its resolved
cwd and each real fixture path. A changed/mismatched filesystem, manifest,
sample identities/counts, invalid exit or internal error invalidates the result.
Named old outcomes and numeric new outcomes are normalized; busy is never dropped.
External manifests attest frozen source recipes; the old executable cannot emit
its dataset contents, so this is not independent proof about arbitrary binaries.

Fair artifacts: `/tmp/opencode/binary-server-fair-qO3wSIyN`; immutable inputs and
source snapshot: `/tmp/opencode/binary-server-paired-inputs-qO3wSIyN`.
Both ran at `/home/leo/Programar/trabajo/open_source/server_initilization`, with
resolved fixtures beneath its `.zig-cache/tmp` on `/home`, Btrfs,
`/dev/mapper/root[/@home]`. Manifest SHA-256:
`9d778d78ee82c432276870955a31ac17878385c84144804f47dfaefd1c7e5203`.
Binary SHA-256 baseline/current:
`1f4b0a60c54f688f51c955f5fcfc0c77778d48a131f4f0861bb3b83fc3d9eda4` /
`5aec8939d0f5786c01a728e6dac53e2475a1fb702ad0d750d9d47fb46076dee9`.

Pooled ReleaseSafe full latency in **microseconds**, including all outcomes;
768 samples/single-thread workload, 3072/contention across both pairs:

| Workload | baseline p50 / p95 / p99 / max | binary p50 / p95 / p99 / max |
|---|---|---|
| new cuts | 16790.5 / 21649.1 / 34111.3 / 42373.5 | 4737.0 / 9491.8 / 12101.8 / 24037.2 |
| replay | 591.6 / 947.7 / 1997.1 / 10052.6 | 19.5 / 41.8 / 75.0 / 715.3 |
| rule errors | 17051.0 / 29465.1 / 34918.7 / 600753.8 | 3904.6 / 6527.0 / 7612.7 / 12108.3 |
| sparse 64 | 435.5 / 620.5 / 746.3 / 1746.4 | 32.9 / 60.7 / 88.4 / 449.6 |
| dense 64 | 9779.4 / 11991.4 / 13071.6 / 14473.3 | 2503.9 / 4383.9 / 4933.7 / 5839.0 |
| four threads | 4743.6 / 57674.5 / 251211.5 / 1438339.8 | 4462.8 / 10070.3 / 40369.8 / 383583.7 |

`summary.json` and per-run summaries contain full **and DB-only** nearest-rank
p50/p95/p99/max, outcome counts and separate success/busy/game-error distributions.
Contention totals: baseline 2470 success / 512 game errors / 90 busy; binary
2530 / 524 / 18; no internal errors. Success-only contention p50/p95/p99/max:
baseline 4679.8/24220.9/141672.8/1438339.8 us, binary
4402.2/9591.3/17614.1/383583.7 us. Busy-only: baseline
251092.4/251639.4/258754.3/258754.3 us, binary
250867.7/251207.8/251207.8/251207.8 us. Both new-cut datasets have 656 successes
and 112 not_cuttable errors; replays here are original already_cut errors.
Original-success replay across restart is tested separately.

Executable-only child totals (setup/seeding/logging/teardown included):

| Run order | wall seconds | user / system CPU seconds | child ru_maxrss KiB |
|---|---:|---|---:|
| A1 baseline | 45.387 | 4.658 / 4.002 | 34184 |
| B1 binary | 17.965 | 1.367 / 1.156 | 34184 |
| B2 binary | 15.289 | 1.326 / 1.127 | 35276 |
| A2 baseline | 36.896 | 4.450 / 3.785 | 36812 |

Child peak RSS can include inherited launcher memory before exec; it is not a
steady-state server heap measurement. Load averages rose from ~4.25 to ~10
during this run; host/storage noise and large maxima are visible, so these are
observations, not latency guarantees. No compilation was launched by the driver.
FULL/WAL are unchanged in both builds. Closing the last old per-request handle
does genuine WAL cleanup/checkpoint work; persistent-handle savings are intentional.
The confirmed fsync/fdatasync build difference has unquantified impact, not an
established explanation for the invalid comparison. Protocol, response shape,
pooling, prepared SQL, page caches, SQLite builds and handle lifetimes all change:
**no isolated allocation-related causal speedup is claimed**.

## Verification (no sockets)

```sh
zig build test-server server -Dgame=false --summary all
zig build test-server server -Dgame=false -Doptimize=ReleaseSafe --summary all
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build
python3 -B -m unittest discover -s build-support -p 'test_*.py' -v
zig fmt --check build.zig build.zig.zon build shared server src/world.zig
git diff --check
```

Only pure/unit tests, isolated real-file SQLite and explicit in-process benchmarks
were run. Root tests select the vendor's `bounded-memory` filter, never upstream's
full socket-containing test suite. Tests cover wire goldens/malformed input,
bitmaps/metadata/extremes, durable replay/conflicts, atomic trigger rollback,
independent concurrent writers, consistent snapshots, real SQLite heap OOM,
quarantine/rebuild, failed budgets, context exhaustion, buddy reclamation and
concurrent churn. Actual startup allocator guards trap unexpected subsequent
upstream calls during application/WS component tests. They cannot instrument C:
SQLite's ZERO_MALLOC/MEMSYS5 build and no malloc/free/realloc undefined symbols
in its static archive are separate evidence, not a universal OS-memory proof.
