# Local binary server

Zig 0.17.0; built-in `std.http.Server.WebSocket`, SQLite-backed gameplay with a
bounded RAM cache, and a separate persistent native CDK wallet. The server and
its tests use the SQLite build already bundled with the native CDK wallet, not
system SQLite. Native server builds require the pinned Rust/CDK toolchain
(`zig build setup -Dgame=false`; use `-Doffline` with warmed tools/Cargo caches). The native CDK target policy applies: native Linux
x86_64/aarch64 or Apple Silicon macOS. Server-only builds do not initialize Raylib;
installation remains opt-in.

```sh
zig build server -Dgame=false
zig build run-server -Dgame=false
zig build run-server -Dgame=false -- 4194304 65536
# executable arguments: [ws-bytes [app-bytes]]
```

Endpoint: **ws://127.0.0.1:9224/**. Saved cuts and player locations survive
restart; request replay history does not. Gameplay requests target a global 20 Hz
tick; wallet startup, authentication and SQLite I/O remain outside the tick.
Rewards, private gameplay, regrowth and inventory are not implemented.
Terrain generator v2 adds water; its region checksum is
`0x2beaf359deeea5bb` (see [world.md](world.md)).

Connections must prove signing-key ownership. This is not an access allowlist:
any key owner may modify the world. Do not expose it as a production security boundary.

## Headless wallet startup

Scoped `server_startup` info messages mark completed configuration (including
budgets), storage/lock, wallet, WebSocket memory, application and transport
initialization. `starting listener` precedes the blocking listener call; it does
not confirm a successful bind or readiness to accept connections.

Before listening, the server locks its separate `haystack-server` storage root
for its entire lifetime and opens a native CDK wallet. On Linux the defaults are
`~/.config/haystack-server/haystack.lock` and
`~/.local/share/haystack-server/wallet/{seed-words.txt,wallet.sqlite}`.
Absolute nonempty `XDG_CONFIG_HOME`/`XDG_DATA_HOME` overrides are honored; explicit
bases must already exist. macOS uses
`~/Library/Application Support/haystack-server` for both roots. Client storage
(`haystack`) and executable name `haystack_server` are unchanged.

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
override. Before opening or creating the wallet, startup fetches the mint’s live
`/v1/keysets` and requires an active `msat` keyset. If the mint cannot be
verified, the server logs the failure and exits without starting the listener.
Opening does not eagerly add a mint, poll or scan for restoration.

Main owns the wallet and gameplay database; the application borrows them through
its wallet and persistence references. Both are closed after task shutdown and
application cleanup; the root lock is released last. CDK/Rust and SQLite memory
are **outside the two reserved server budgets below**.

## Authentication and ephemeral connection sessions

The upgrade URL must be exactly `/`: no query (including `?pubkey=`), fragment,
escape, other path, trailing byte or NUL. Invalid upgrades close without an HTTP
response guarantee. HTTP 101 alone grants no identity or gameplay. Upgrade
validation requires GET/HTTP1.1, version 13, an upgrade Connection token, exactly
one valid 16-byte base64 key, and no ambiguous singleton duplicates, Expect or
request-body framing. No extensions are negotiated.

Immediately before writing HTTP 101, the server starts an absolute **5-second**
monotonic deadline. It includes upgrade/challenge writes, proof arrival/assembly,
verification, session claim and reply transmission. Auth uses the same
[TLV envelope](#binary-tlv-no-compatibility) as gameplay, but has no request ID:

| Direction | Message tag | Body fields in order | Total bytes |
|---|---|---|---:|
| Server challenge | `0xf0` | `0x10`: fresh OS-secure random nonce (32 bytes) | 39 |
| Client proof | `0xf1` | `0x11`: compressed secp256k1 public key (33 bytes); `0x12`: signature (64 bytes) | 107 |
| Server auth reply | `0xf2` | `ok` (`0x03`): x:i32, y:i32 (8 bytes, little-endian tile coordinates); or `failed` (`0x04`) with a u16 code | 15 or 9 |

The former empty auth `ok` is not accepted. Auth failure codes are `1`
(`invalid_credentials`, key or signature verification failed) and `2`
(`unavailable`, player load or session claim failed). A typed failure reply is
followed by disconnect.

The signature is **BIP340 Schnorr** over the 32-byte digest
`SHA256("haystack/ws-auth/v1" || nonce)`. The domain is exactly 19 ASCII bytes,
without NUL; the outer SHA256 is applied **once**, not twice. BIP340's tagged
challenge hashing is part of BIP340, not an additional application prehash.
The compressed prefix must be `02` or `03` and x must lift to a valid curve point.
Both valid parities of the same x are **one identity**, stored as `02 || x`.

Only after successful verification is a bounded session claimed atomically.
The existing verified incumbent always wins a duplicate; an unverified connection
never reserves a key or evicts an incumbent. A claim is provisional until the
`0xf2` success reply is written and the deadline is checked again. No gameplay is
dispatched before this completes. Cleanup releases a provisional claim on failure
or expiry. Before authentication, malformed application messages (including text,
wrong-tag proofs and premature gameplay) receive the generic protocol error; the
server keeps reading under the original deadline without sending a new challenge.
A well-formed proof that fails verification or admission is rejected as above;
expiry or a transport failure can close without a reply. After authentication,
text and auth messages (including repeated proofs) get the generic protocol error
rather than restarting authentication. Only single-frame messages are supported;
fragmentation and continuation frames are rejected. Pings, pongs, trickles and
buffered traffic never extend either deadline.

Authentication payload types live in `shared/protocol.zig`; allocation-free
`encodeAuth`/`decodeAuth` codecs in `shared/wire.zig` enforce the expected auth tag
and its exact field schema. Hashing, signature verification, nonce generation,
deadlines and admission remain server-only.
Authentication protocol, hashing, frame handling and admission are Zig. BIP340
verification calls Bitcoin Core **libsecp256k1 v0.8.0** directly through translated
upstream C headers, using its immutable shared static context (no context allocation).
This proves possession of the supplied key, **not wallet provenance**. The
canonical public key identifies the stored player; auth nonces and proofs are not
persisted.

The native-server-only lazy Zig dependency is the official release archive:
`https://github.com/bitcoin-core/secp256k1/releases/download/v0.8.0/libsecp256k1-0.8.0.tar.gz`.
Its verified SHA256 is `dd685546f9e717b9adde329acd5a4cd8083d40f710fdb0a603ee5a83f908132b`;
the package pin is `N-V-__8AAFwQbQAc-L8ZUw4rqyk_OWdYX4-V8crqiWlJ1dhl`.
Upstream's MIT-licensed source remains in the Zig package cache, not vendored here.
`build/secp256k1.zig` compiles its three C sources with only extrakeys/schnorrsig
modules enabled and explicit upstream desktop table settings (window 15, comb
blocks 43, teeth 6). No system installation, CMake, Cargo source path, Rust ABI or
handwritten crypto is used. The browser/Wasm graph never requests this dependency.
Warm Zig dependencies before using offline builds.

Connection sessions are ephemeral, but player positions are saved by canonical
public key. Login restores the latest pending RAM position if present, otherwise
the stored position. A first login chooses a random grass/dirt tile with a
walkable cardinal neighbor in the 9×9 chunk region centered on the origin, with
`(0,0)` as fallback. The auth ACK carries this starting or restored position; a
new player becomes eligible for saving only after authentication succeeds.

A location update may stay put or move one tile onto grass or dirt. A diagonal
also needs both side tiles clear. Rejected moves return `invalid_request` without
changing position or closing a live session. Acknowledgement means RAM acceptance,
not durability. Location
updates are not replay-cached and do not enforce movement cadence or consult
cuts or other characters. Cut/read connections must first complete authentication.
There is no listing, client query, subscription, broadcast or location history.

The default Debug server (`zig build run-server -Dgame=false`) writes
`debug(gameplay)` logs to stderr. Each entry identifies the authenticated player
by their lowercase hex public key and reports the old and new movement tiles,
the newly cut tile, or the requested chunk bounds for a successful area read.
Rejected actions, movement no-ops, and cached cut replays are not logged.
Release builds suppress these debug logs.

Normal/error/shutdown cleanup and failed-upgrade cleanup after admission release
the session. Generation-checked handles protect reused connection records from
stale cleanup/update. An undetected authenticated old socket may temporarily
block reconnect: no post-authentication heartbeat or idle deadline is added. Registry locking never spans
world or socket operations. Cut replay history is global across sessions, not
owned by the connection and not cleared on disconnect.

HTTP has its own absolute five-second window captured immediately after accept,
including scheduling and parsing. Authentication gets a fresh five-second window
immediately before launching the phase that writes HTTP101. Each phase races work
against `std.Io.Clock.Timestamp.wait` using a two-result `std.Io.Select`.
Every exit cancels and joins both tasks before accessing their state or closing
the stream. Explicit clock checks cover buffered reads, verification, registry
publication under its mutex, and before/after ACK flush; equality is expired.
The auth worker never dispatches gameplay. A losing race can have delivered `0xf2`,
but cannot dispatch gameplay and always releases its provisional identity.
Native I/O cancellation interrupts pending network reads/writes; this is not a
hard real-time scheduling guarantee. There is no custom event loop or watchdog.
Authenticated writes have no new deadline and never hold the world context lease;
group cancellation joins all connection tasks before freeing application/slot storage.

## Binary TLV (no compatibility)

One application message per binary WebSocket message:
`message_tag:u8 || body_len:u16 || body[body_len] || BYE:0x7e`.
The body is a sequence of `field_tag:u8 || value_len:u16 || value[value_len]`
fields. Lengths count only the body or value, respectively. All application
integers are little-endian; signed i32 coordinates use two's complement, not Zig
struct layout. Fields must appear in strictly increasing tag order. Unknown,
duplicate, out-of-order or missing required fields, wrong lengths or values,
conflicting outcomes, missing or invalid BYE, and trailing bytes are rejected.
There is no version or flags field, negotiation, or fallback to the old fixed
header, old auth framing, or JSON.

Inbound WebSocket data payloads are capped at **1 KiB (1024 bytes)**. Only a channel-open
request can use the full cap; the application decoder keeps the **256-byte** cap
for auth and other requests. Outbound payloads are at most **2128 bytes**.
These sizes exclude WebSocket framing. Control frames remain limited to 125 bytes. Messages that reach the application
decoder but fail validation, including text and unexpected message tags, receive
the binary generic protocol error `ff 00 00 7e` (tag `0xff`, empty body). It has no request ID or error code,
even if the input contained a readable ID. Handshake and frame-level failures
(including oversized inbound frames) may close without an application reply.

Gameplay requests contain `id` (`0x01`, 16 opaque bytes; all-zero is valid) then
`payload` (`0x02`). The corresponding typed reply echoes the ID and carries
exactly one of `ok` (`0x03`) or `failed` (`0x04`).

| Operation | Request tag | Payload value | Request bytes | Reply tag | `ok` value (total reply bytes) |
|---|---|---|---:|---|---|
| `cut` | `0x01` | x:i32, y:i32 | 34 | `0x81` | Tile state (36) |
| `read_area` | `0x02` | cx0:i32, cy0:i32, cx1:i32, cy1:i32 | 42 | `0x82` | Snapshot (112–2128) |
| `update_location` | `0x03` | x:i32, y:i32 | 34 | `0x83` | Empty (26) |

Tile state is `x:i32, y:i32, terrain:u8, cut:u8` (10 bytes). Terrain values are
grass=0, dirt=1, rock=2, tree=3, water=4; booleans are strictly 0/1. A `failed` value is a
u16 code (28-byte reply), except `already_cut` appends the current tile state
(38-byte reply). Failure codes are scoped to the operation:

| Reply | Allowed failure codes |
|---|---|
| `cut` | `1 invalid_request`, `9 not_cuttable`, `10 already_cut`, `11 request_id_conflict`, `12 server_busy` |
| `read_area` | `1 invalid_request`, `6 out_of_bounds`, `7 invalid_area`, `8 area_too_large`, `12 server_busy` |
| `update_location` | `1 invalid_request`, `12 server_busy` |


Snapshots contain **every chunk**, including empty chunks, in increasing cy then
cx. The rectangle is inclusive and covers 1–64 chunks. Offsets within the `ok`
value are rectangle=0 (four i32s as in the request), generator version=16 (u32),
public seed=20 (32 bytes), chunk count=52 (u16), bitmaps=54. The maximum reply is
`4 + (3 + 16) + (3 + 54 + 64 * 32) = 2128` bytes.
Generator v2 uses the public all-zero 32-byte seed; v1 snapshots are rejected.
Each chunk has exactly 32 bytes:
bit `local_y*16+local_x`, least-significant bit first. One means cut; zero is
authoritative uncut, not an omitted update. Replace the rectangle's previous delta
view. Reads reset the entire fixed snapshot and fill it under the exclusive lease;
there is no truncation, pagination, subscription or temporary list. All i32 tile
coordinates are supported, including negatives; chunk coordinates are
[-134217728,134217727], unrelated to renderer pixel bounds. Floor division and
nonnegative modulo 16 determine chunk and local coordinates.
Public `shared/wire.zig` request/reply codecs allocate nothing. Reply decoding
checks the expected operation tag and request ID, and validates snapshot metadata,
count and rectangle. Snapshot encoding and decoding reject overlapping source and
output storage before modifying either buffer.

`wire.Pending` has eight fixed entries and matches typed replies by operation
and request ID. It reports a validated late or unknown reply separately from a
matched reply, and a generic protocol error does not consume any pending entry.

### Native and browser chunk streaming

Both clients restore the player and camera from the auth ACK and request cut
bitmaps with `read_area`. The restored viewport is synchronized first, followed
by the resident area (including minimap coverage). The native client can batch
up to 64 chunks; the browser batches up to five to fit its 256-byte receive
bridge. Clients generate the base terrain locally and apply authoritative cut
bits to resident chunks for world and minimap rendering. Reconnect invalidates
old bitmaps and refetches them around the restored position. This is pull-based
streaming, not a server push or live subscription.

## Spilman channel messages

Channel requests are accepted only after WebSocket authentication. Each starts
with the usual 16-byte request `id` (`0x01`), then the following TLV fields:

| Operation | Request / reply tags | Additional request fields, in order | Request size |
|---|---|---|---:|
| Requirements | `0x21` / `0xa1` | Tool (`0x23`, u8: axe=0, hoe=1, pickaxe=2) | 27 |
| Open | `0x22` / `0xa2` | Channel ID (`0x20`, 32 bytes), funding proof (`0x24`, 1–963 bytes) | 62–1024 |
| Payment | `0x20` / `0xa0` | Channel ID (`0x20`, 32 bytes), amount (`0x21`, u64), signature (`0x22`, 64 bytes) | 136 |
| Close | `0x23` / `0xa3` | Channel ID (`0x20`, 32 bytes) | 58 |

Replies echo the request ID and contain exactly one `ok` or `failed`. The
requirements `ok` value is `pubkey:[33]u8 | amount:u64 | refund_time:u64`
(absolute Unix seconds); the other `ok` values are empty. Failure codes are
`1 invalid_request`, `12 server_busy`, and `20 unavailable` for all four;
open additionally allows `21 invalid_proof`, payment `22 payment_rejected`,
and close `23 close_rejected`. These codes do not replace structural decode errors.

The cap is sized for single-proof funding. One proof from
`src/testdata/spilman_vectors.json` takes 797–798 bytes as a one-element JSON list,
or 858–859 bytes including the 61 bytes of channel-open framing. The full
three-proof fixture exceeds the cap. The byte limit does not enforce proof count;
the funding parser must enforce exactly one proof when channel handling is enabled.

Funding proof bytes are opaque to the wire codec. Decoding borrows the receive
buffer, so the proof slice must not outlive or survive reuse of that buffer.
Encoding rejects a proof that overlaps the bytes it would write.
Channel requests bypass the tick mailbox and are answered synchronously. The server
currently replies `unavailable` to every well-formed channel request without
closing the connection. It does not issue live quotes, verify or redeem funding,
accept payments, or settle channels; those require a channel service and durable
state, not just the startup wallet. Malformed messages receive `PROTOCOL_ERROR`.

## Gameplay SQLite, cache and saves

The separate gameplay database is `game.sqlite` in the server data root, next
to the `wallet/` directory: `~/.local/share/haystack-server/game.sqlite` by
default on Linux (`$XDG_DATA_HOME/haystack-server/game.sqlite` with an override),
or `~/Library/Application Support/haystack-server/game.sqlite` on macOS.

| Table | Contents |
|---|---|
| `game_meta` | Single row (`id = 1`) with the 32-byte public seed and generator version. |
| `game_chunks` | `(cx, cy)` primary key in chunk coordinates and a 32-byte cut bitmap (`bits`). |
| `game_users` | Canonical 33-byte `pubkey` primary key, signed 32-bit tile coordinates `x, y`, and a nullable 32-byte `channel_id` (no live channel service). |

Startup creates the schema for a new database. For an existing database, it
checks that SQLite opened it for writing, then validates the seed, generator
version, integrity, and stored gameplay rows. A read-only database, mismatch,
or invalid data fails startup rather than resetting the world. The older
renderer-limited player table is migrated in one transaction to allow the full
signed `i32` tile range, preserving all player fields. The wire format is
unchanged.

**No chunk rows are cached at startup or login.** On demand, connection tasks
load missing cut/read chunks from SQLite, using an all-zero bitmap for an absent
row, and pin them through tick execution. Cache hits need no disk I/O.

The server shares one cache across all connections: **5,184 base entries plus
512 overflow entries**. At or above base capacity, a miss first tries to evict
an unpinned, clean entry with no save in flight. The victim is farthest from its
nearest active player by squared distance in chunk coordinates (first eligible
entry if no players are active). If no entry can be evicted, the miss uses an
available overflow slot or returns `server_busy` at the hard limit. Dirty rows
cannot be evicted before saving. Releasing pins or successfully saving dirty
rows lets background tasks drain overflow back toward the base capacity. The
limits are independent of the application byte budget.

The save task runs on a fixed five-second schedule, skipping elapsed deadlines
rather than overlapping writes. It snapshots dirty chunk bitmaps and player
records and upserts them in one SQLite transaction per nonempty pass. Only
records that still match what was committed are marked clean. Changes not yet
committed remain dirty for a later pass. If rollback fails, the next flush tries to reopen
the existing database. A cut or movement ACK is RAM acceptance, not a disk commit.
`SIGINT` and `SIGTERM` stop accepts and cancel
and join the connection, tick and save tasks, letting claimed tick work finish.
The server then attempts a final flush before closing the database; it logs and
returns a final save failure. An abrupt exit can lose uncommitted changes.

### Cut rules and replay

Only generated grass/tree can be cut; cuts preserve the base terrain and set
its cut bit. Dirt/rock/water reject; another ID for a cut tile gets `already_cut`.
All 16 opaque ID bytes (including zero) bind the cut coordinates. A retained ID
replays its original success or terminal game error; different coordinates
return `request_id_conflict` before mutation. Reads, location updates, malformed
requests and capacity/admission failures do not consume IDs.

The global RAM replay history keeps **512 terminal cut results**. A new result
at capacity evicts the oldest admitted result; hits and conflicts do not refresh
age. Retry an uncertain cut with the same ID while it is still retained. Once
evicted, or after restart, that ID is evaluated against current world state and
may return `already_cut` instead of the original success.

## Reserved memory and admission

The WebSocket slots and application layout use startup-reserved memory with
**no upstream system-heap fallback**. The gameplay cache, bounded 1,024-player
record array and save scratch are separately allocated at startup. These budgets
do not bound total RSS or latency, and exclude SQLite and OS/runtime resources.

| Budget | Default bytes | Reservation and checks |
|---|---:|---|
| WebSocket recycler | 4,194,304 | Slot array is `64 * @sizeOf(transport.Slot)` before buddy rounding. The socket-free memory test asserts a 1,048,576-byte rounded allocation, unchanged by reuse and tick work. Metadata is separate: `ws_budget / 64` bytes (65,536 at the default). |
| Application buffers | 65,536 | `@sizeOf(app.Layout)` includes the context (inline `WorldState`, response buffer and snapshot) and session registry. The layout test asserts that it fits within 65,536 bytes and rejects a budget one byte below `@sizeOf(app.Layout)`. |

The WS budget must be a power of two, at least 4096, with a correspondingly
aligned startup region. Its synchronized buddy recycler splits/coalesces in
bounded logarithmic steps, charges fixed metadata to that region, never retains
a backing allocator, and returns OOM rather than growing. Resize stays within the
current block; larger reallocations allocate/copy/free inside the pool. High-water
counters count rounded allocated blocks separately from fixed metadata. These
are component measurements, **not server/RSS high-water measurements**.
Application startup requires at least `@sizeOf(app.Layout)` bytes; insufficient
budgets fail initialization. Additional application bytes are unused headroom.

64 total connections **including pending HTTP and authentication**, with **at most
one pending gameplay request per connection**. Each stable slot owns a copied
request, generation-checked session handle, completion event, and a 2128-byte
buffer for the encoded reply. No queued pointer borrows a handler, reader,
request buffer or App snapshot.
One exclusively leased context owns world state and scratch response/snapshot;
the tick copies its encoded reply into the slot **before releasing the lease**,
and only then may the connection write to its socket. Location updates use the
session registry rather than this lease, but are dispatched on the same tick.
A cut/read without an available context or cache lock gets `server_busy`
**before mutation**. Cache preparation can also return `server_busy` on storage
failure or cache saturation. Socket writes hold neither the lease nor chunk pins.
At connection capacity an accepted socket is immediately closed without launching
a task or promising HTTP503. HTTP limits: 5 seconds, 8192 bytes, 32 headers.
`server/ws_config.zig` holds the fixed production/test limits.

Before listening, the buddy reserves one array of 64 slots. Each owns 8192-byte
HTTP, 1024-byte inbound WebSocket and 512-byte output writer buffers plus stable
key/bookkeeping and the mailbox. The writer buffer is not the outbound payload
limit. Socket-free capacity/reuse/tick tests check that no further managed
allocation occurs. Insufficient startup reservation fails closed.
The retained HTTP reader preserves pipelined frame bytes. A thin forwarding guard
checks RSV, FIN, mask, opcode, canonical lengths, control limits and payload cap
before passing unchanged bytes to std, including internally skipped pongs. Close
ends the connection; complete close-payload validation is not claimed.
Connection tasks use `std.Io.Group.concurrent` (no inline fallback). The standard
I/O runtime, tasks, thread stacks, sockets and OS resources are **outside the WS
reservation**. Slow writers occupy only their own slots, not the world lease.
The sequential connection reader does not read more messages while awaiting a
tick reply or writing it: ping and disconnect detection can therefore be delayed.
There is no claim of uninterrupted ping service, post-auth heartbeat, or new
write-timeout policy.

## Tick handoff and cancellation

The tick and periodic save tasks start in the listener group before accepts;
failure to start either fails listening. The tick uses the shared 20 Hz schedule
and absolute monotonic `awake` deadlines (50 ms), with an immediate initial batch. At each due batch it
snapshots up to 64 queued `(slot, request generation)` records under one mailbox
mutex, in round-robin order. Later arrivals, including a new request from a slot
already served, wait for the next tick. All decoded cut/read/location requests
use this path; malformed messages, proof verification, admission, HTTP/auth
deadlines and ping replies are not quantized.

Each batch has a soft 50 ms work budget from its actual start, checked between
requests. Unclaimed work stays queued, and the cursor advances past the last
serviced/examined slot so a costly prefix cannot starve the tail. Bounded world
actions finish once claimed, even if that overruns the target. Missed boundaries
are discarded after work; there are no catch-up batches or tick IDs on the wire.
This is a scheduling target, not a hard real-time latency guarantee. The tick
works on in-memory state; connection tasks handle
SQLite loads before publication, and the saver handles writes separately.

Mailbox states are idle, queued, executing and ready. A connection owns its slot
through completion and the end of its socket write. Queued cancellation removes
work immediately under the mutex, without waiting for another tick. Executing
cancellation marks it abandoned, then waits **uncancelably** for completion before
releasing its session and slot. Claimed execution has no cancellation points:
registry locks are uncancelable, actions touch bounded RAM, and ready publication
always sets the completion event, including stale-session/busy replies. Neither
the mailbox mutex nor the world lease spans socket I/O or completion waits; no
registry/mailbox locks nest. Cancellation is checked between requests and during
absolute tick sleep, and group cancellation joins tick and connection tasks before
App/slot teardown. Tick exit wakes any still-queued waiters with a closing busy
reply and rejects new publication, so no waiter depends on another tick after exit.
Ready cancellation discards the reply after the write ends; event reset occurs
only on the next publication after all prior waits returned. Request generations
persist across slot reuse and reject exhaustion rather than wrapping, so cutoff
records cannot execute a replacement request.

## Chunk read benchmark

```sh
zig build bench-chunk-reads -Dgame=false -Doffline -Doptimize=ReleaseSafe
```

The benchmark seeds a temporary SQLite file with 16,384 edited chunks and
reports p50, p95, p99, and maximum latency in nanoseconds for 1-, 16-, and
64-chunk requests. Each case uses 256 samples. `sqlite_miss` requests start with
those chunks absent from the server cache; `ram_hit` immediately repeats the same
request. `prepare` measures the lookup, any SQLite reads, and cache pinning;
`total` also includes assembling the bitmap snapshot and releasing the pins.

This measures one connection with no tick wait, socket I/O, background writes,
or cache eviction. SQLite and OS page caches are not cleared, so a server cache
miss does not necessarily mean a physical disk read. The benchmark does not
open the wallet or touch the live game database.

## Verification

```sh
zig build server test-server -Dgame=false -Doffline --summary all
zig build server test-server -Dgame=false -Doffline -Doptimize=ReleaseSafe --summary all
zig build test-game-db -Dgame=false -Doffline
python3 -B -m unittest discover -s build-support -p 'test_*.py'
git diff --check
```

`test-server` covers shared wire encoding/validation, rules, SQLite storage,
cache and replay eviction, snapshots/extremes, capacity atomicity, startup, budget
failures, cross-thread exclusive leasing, frozen allocator checks, session tests,
buddy reclamation/concurrent churn, fixed-buffer transport tests, and real CDK
wallet tests in isolated temporary storage. It never opens sockets. Wallet tests
retain seed hashes/inodes across reopen, borrowed ownership, locking and failure
preservation checks. Authentication tests retain message goldens, positive/negative
signature fixtures, parity/domain/nonce/single-hash binding, malformed keys and
signatures, admission/deadline/ownership checks. Tick tests exercise production
snapshot/claim/execute/cleanup methods with explicit clock inputs, cutoff and
generation reuse, all three operations, soft-budget fairness, FIFO replay and
busy behavior, owned replies after context reuse, event-reset lifecycle,
queued/executing cancellation and group join. The real tick task's absolute wait
and cancellation are also checked without listening or opening sockets.
