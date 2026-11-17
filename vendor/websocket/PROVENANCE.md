# Pinned WebSocket dependency

- Upstream: <https://github.com/karlseguin/websocket.zig>
- Commit: `105eed779c1833583eb9ad2b9c1b5c78945506fa`
- Package version: `0.1.0`
- Zig package hash: `websocket-0.1.0-ZPISdakeBQAIRoY7BmxffmnGOKUDRXqci26gEEVGAA03`
- Source copied without modifying the package/cache from:
  `zig-pkg/websocket-0.1.0-ZPISdakeBQAIRoY7BmxffmnGOKUDRXqci26gEEVGAA03`.
- Original packaged-tree SHA-256: `495a2f15c7053d266f656ee197c35e84171f73a25b5f40616646c9ed3f4a5830`.
  Reproduce inside that original directory with
  `find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum`.
- The package omitted its license file. `LICENSE` restores the MIT license
  verbatim from the pinned commit's upstream `LICENSE`.

## Local patches

- `src/server/server.zig`: prewarm connection records and, by default, small
  reader buffers from existing `max_conn` settings; enforce the connection
  record limit including pending handshakes. Prewarm handshake states for at
  least `max_conn * worker_count`. An explicitly smaller handshake count no
  longer causes unbounded fallback allocations. Explicit `small_pool = 0`
  retains the existing per-connection allocation behavior.
- Call `Reader.deinit` before discarding readers, including empty-reader and
  shutdown paths, returning fragment/large/decompression storage exactly once.
  Return pending handshake states during shutdown as well.
- Nonblocking handshake ownership now remains active from listener dispatch
  through queued/running parsing and the entire callback cleanup tail. Dispatch
  takes the connection-manager lock before reading record state or handshake
  timestamps, including for established connections, and releases it before
  enqueueing work. After releasing the record cleanup mutex, successful callbacks
  hold the manager lock across one-shot rearm and publication of incomplete
  handshakes as pending. Unlock is the final ownership handoff: no later record
  access or cleanup-mutex defer survives it. Established connections stay active.
  Rearm failure unlocks before normal close/cleanup and never publishes pending.
  Timeout retirement shares that manager lock and only recycles owner-free
  pending records; it never takes the record cleanup mutex. No new queue,
  reference count, allocator or public protocol/configuration change is involved.
- Nonblocking listener stop now ends admission/dispatch without walking live
  connection records. After the listener thread has joined, teardown stops and
  drains the callback pool, joins every callback worker (including callback
  cleanup/rearm tails), then closes/cleans each active and pending connection
  through the normal cleanup path. Only then are callback-pool storage,
  connection/buffer pools and the event loop destroyed. The shutdown walk no
  longer holds the connection-manager lock across per-connection cleanup or
  handler close hooks. Synchronous slow-reader output can delay shutdown;
  callbacks are never abandoned and their storage is not reclaimed early.
- Outer listener startup/shutdown uses `lifecycle.Completion`: one mutex owns
  the persistent `completed`/`starting`/`running` phase and its condition.
  Idle servers start completed; a new listen reserves starting before thread
  spawn, and startup waiters loop until ready or completed (not merely notified).
  Spawn failure completes the reservation under the same mutex. A single final
  defer in the listener publishes completion under that mutex only after all
  resource cleanup, on both normal return and startup error, without double
  unlocking. Stop waits for startup resolution before closing published signal
  writers and loops on completion; already-completed/idle stop returns directly.
  New listen attempts reset the phase, and overlapping listens are rejected with
  `error.AlreadyListening`. Public method signatures and configuration are unchanged.
- `src/server/thread_pool.zig`: initialization failure sets `stopped` under
  the same mutex used by the worker's condition wait, unlocks, broadcasts and
  joins only successfully started workers. Private, zero-cost production hook
  instantiations permit deterministic socket-free failure/wait-boundary tests.
- `src/server/lifecycle.zig`: listener acquisition immediately guards the
  descriptor through socket-option/bind/listen failure. Worker/thread arrays
  have independent allocation guards. Both pipe ends are guarded until worker
  creation/thread spawn transfers the read end to `NonBlocking.run`; that
  thread closes the read end on every return. Failed listener startup closes
  published write ends, joins all started listener threads, then destroys their
  workers and arrays. Published write-end ownership is atomically taken and
  invalidated, allowing either `Server.stop` or listener completion to close it
  exactly once, including early event-loop setup failure.
- Limit each listener readiness turn to 16 accepts (admissions and rejections
  combined). Accepted descriptors initially remain nonblocking. At capacity,
  `src/server/rejection.zig` attempts one constant HTTP 503 raw send and closes
  immediately, even on a short send or any error. No connection record or
  blocking connection/handshake write is used for rejection. Admitted
  descriptors retain the original blocking synchronous-write behavior.
- `src/proto.zig`: check cumulative logical payload length before allocating
  wire/fragment storage; separately enforce RFC control framing (FIN, reserved
  bits, 125 bytes, valid opcode, and no one-byte close). Check extended data
  lengths for canonical encoding and avoid wire-length overflow. A capped
  payload may have a wire buffer larger by its header length.
- Fragment storage obtains one full logical-message-capacity buffer through
  the existing provider and returns it on completion or disconnect/error.
  This reuses an appropriately sized large pool without ArrayList growth.
  Allocation failure during wire growth preserves ownership of the old buffer.
- `src/buffer.zig` and handshake pool initialization reclaim partially
  initialized pools on allocation failure. Provider growth likewise retains
  the old buffer on failure. Exhausted handshake pools now return
  `error.OutOfMemory`, never dynamically expand.
- `build.zig` exports `bounded_tests`, rooted at `src/bounded_tests.zig`, with
  its own nonblocking options and libc linkage. `test-bounded` runs only tests
  whose names contain `bounded-memory`. The embedding build must apply the
  same filter when creating a test artifact from this module. Upstream socket
  tests are imported for discovery but excluded from execution. The upstream
  full `test` target remains unchanged (its runner is absent in the pinned
  packaged tree); it is not used for verification here.
- Package paths include this provenance and restored license; changed Zig
  files are formatted for Zig 0.17.

## Integration and allocation contract

No new public configuration fields or changed Server/Config/Handler/Conn
signatures. The application must pass its synchronized bounded recycling
allocator and configure one listener worker, `max_conn = 64`, four callback
workers, a readiness backlog of 64, `max_message_size = 128`, compression off,
and handshake timeout/size/header limits of 5 seconds/8192 bytes/32 headers.
The three-argument non-allocator callback remains supported. Application
request/response validation and response lifetime through synchronous
`writeBin` remain the application's responsibility.

Connection records remain in the prewarmed pool until worker deinitialization
and recycle on close. Small buffers are borrowed while a reader has partial
input and returned when empty or disconnected. Fragment buffers remain borrowed
until the completed message callback returns (`Reader.done`) or cleanup runs.
Large wire buffers return on `done` or `deinit`. All fallback buffer allocation
uses only the supplied allocator; the dependency does not introduce any system
heap fallback. Runtime allocation in the caller's startup-reserved region is
permitted. With a 128-byte cap, a reader needs at most its small buffer, one
128-byte fragment buffer, and one wire buffer of at most 142 bytes (a conservative
14-byte header allowance). Control payloads may reach 125 bytes independently
of the application payload cap.

For zero runtime allocator calls on the tested fragment path, configure
`buffers.large_pool = 64`, `buffers.large_size = 128` and keep small buffers
large enough for the 136-byte maximum masked data frame (the 2048-byte default
already is). Otherwise bounded-region allocation is allowed and exhaustion is
handled without a system allocator fallback. Explicitly smaller small pools
also retain the existing supplied-allocator fallback.

The existing one-shot per-connection readiness and callback queue are unchanged;
there is no additional application queue. With 64 connection records and a
64-entry readiness queue, one job per connection prevents an ordinary 65th
producer. Normal synchronous output and slow-reader waits are unchanged.

## Socket-free verification

From this directory:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-ws-global zig build test-bounded --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/opencode/zig-ws-global zig build test-bounded -Doptimize=ReleaseSafe --summary all
zig fmt --check build.zig build.zig.zon src/bounded_tests.zig src/buffer.zig src/proto.zig src/server/server.zig src/server/handshake.zig src/server/rejection.zig src/server/thread_pool.zig src/server/lifecycle.zig src/server/bounded_test_support.zig
```

Tests cover capped complete/fragmented messages, 125-byte controls, small
static-buffer wire growth, malformed/over-cap input, failure-safe ownership,
interrupted fragment plus large-buffer reclamation, repeated churn, 64
simultaneous partial connections, prewarm exhaustion, and every allocation
failure point in the socket-free WorkerState/NonBlockingBase prewarm fixture.
They also cover mock rejection outcomes and the shared accept-work budget,
barrier-held active/queued callbacks and post-callback tails during teardown,
a real later callback-buffer allocation failure and a simulated thread-spawn
failure after one worker reaches its condition-wait boundary, and mock listener
configuration/bind/listen, worker-array, pipe, worker-init and thread-handoff
failures. Mock startup checks exactly-once descriptor closes, join-before-worker
destruction, and full allocator reclamation. These are targeted fixtures, not a
claim that every real startup syscall/failure has been exercised.

Completion tests exercise the shared production predicate protocol, including a
stopper held between its completion check and condition wait while completion
attempts to take the same mutex, normal waiting completion, completion before
stop entry, idle/repeated stop, startup error/spawn-reservation completion, reset
on a new run and spurious startup notifications. Scheduling uses mutexes,
conditions and gates, with no timing sleeps. Actual OS thread-spawn failure in
the outer listener and live listener startup/shutdown are not executed.

Three handshake ownership tests (22 bounded tests total) use the production
callback tail, dispatch and timeout-retirement helpers with mock parsing,
rearm and descriptor close operations. Gates hold an expired incomplete callback
before handoff and after rearm/pending publication while the manager lock is
held. Checks cover queued-past-deadline ownership, timeout and immediate-readiness
exclusion, deterministic timeout/readiness winners (including established
readiness), exactly-once close and handshake-state return, immediate record reuse
while the old callback stack remains alive, and parse/closed/rearm failure cleanup.
Debug and ReleaseSafe pass without sockets or timing sleeps. These tests do not
execute socket reads, actual event-loop readiness or live-network timeout races.

The full production listener/accept/reject path is compiled but never executed.
No socket, network, E2E tests or server startup are performed; scheduling fairness
is checked only through the shared per-turn work budget, not live networking.
Tests start ordinary threads but mock all connection/event-loop descriptor
operations. Live-network shutdown and blocked slow-peer behavior are not tested.
