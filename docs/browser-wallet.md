# Experimental browser wallet: compiled and runtime-tested

The complete browser bundle now builds and runs: CDK **0.18.3**, this repository's
shared wallet-policy implementation, the vendored Spilman bindings, and the
Zig/raylib renderer. **Use test funds only.** This is a working experimental port,
not a production-security or full fault-recovery certification.

## Build

Host prerequisites: Zig 0.17.0, Python 3 and Rustup/Cargo. For browser tests,
Node 22+ and Chromium are also required. See
[separate platform build graphs and options](build.md) for the full contract.

Provision the browser tools once. This is the only step that installs the Rust
**1.99.0** Wasm target, local wasm-bindgen CLI **0.2.130** and Emscripten
**4.0.19**:

```sh
zig build setup -Dplatform=wasm
```

Then build normally:

```sh
zig build -Dplatform=wasm
```

Ordinary builds, tests, `run`, `wallet` and `renderer` only check installed
tools; they never install or update Rust components, wasm-bindgen or Emscripten.
A missing item fails with the setup command above. `zig build setup
-Dplatform=wasm -Doffline` only checks and reports what is missing.

An existing matching CLI can optionally override the managed one:

```sh
zig build -Dplatform=wasm -Dwasm-bindgen=/absolute/path/to/wasm-bindgen
```

Output: **`zig-out/wasm/renderer/index.html`** (the game), **`zig-out/wasm/index.html`**
(a minimal redirect to the game that preserves query/hash), the Rust wallet under
`zig-out/wasm/wallet`, and the renderer's JS/Wasm. The Rust wallet uses
wasm-bindgen; the renderer uses Emscripten and a game-only full-viewport shell.
Subsequent builds check the installed SDK version instead of running upstream's
unconditional `emsdk update` (which caused a 502 failure and a hung build during
testing). The pinned upstream activation step is detached and verified at
configuration time; if that upstream graph changes, configuration fails instead
of running an installer.

Serve the entire directory, not just a `.wasm` file:

```sh
zig build run -Dplatform=wasm
```

Open <http://127.0.0.1:8000>. The default page is the game. A non-interactive
wallet test fixture is only installed for test targets, at `/wallet-test.html`.
Use HTTPS for deployment; localhost HTTP is sufficient for local testing. Web
Crypto, WebAssembly, localStorage, and Web Locks are required. Opening is
refused when locking/storage cannot be established.

The browser graph is selected only by `-Dplatform=wasm`. A Wasm `-Dtarget` alone
(including `wasm32-emscripten`, `wasm64-*` or WASI) is rejected; use the explicit
platform flag, optionally with `-Dtarget=wasm32-emscripten`. Renderer-only work is
explicit: `zig build renderer -Dplatform=wasm`. The native-crate Wasm probe is no
longer a project build step.

## Run the local end-to-end tests

One command builds everything, starts its own **local-only fake mint** on a free
port, runs Chromium plus database conformance tests, and stops the fixture:

```sh
zig build test -Dplatform=wasm
```

For manual interaction or browser MCP, start a persistent fake-mint server with
`zig build test-mint -Dplatform=wasm`. It binds **127.0.0.1:18787**.
`BROWSER_TEST_PORT` can override the port;
use `0` to allocate an available port and read the printed address. It never
connects to Lightning or holds real funds. `/test-token` dispenses 100 fake sats
from its finite in-memory test setup. Do not deploy this test server publicly.

With that manually started server, the Node runner can also run independently:

```sh
node browser/test.mjs
```

For a different port/browser:

```sh
CHROMIUM=/path/to/chromium node browser/test.mjs http://127.0.0.1:PORT/?smoke
```

You can also visit <http://127.0.0.1:18787/wallet-test.html?smoke> manually. The
default `/` is the game, so the Node runner rewrites the fake mint's `/?smoke`
URL to the non-interactive `/wallet-test.html?smoke` fixture and leaves the
Python mint URL detection unchanged. The fixture reports its browser checks; the
Node runner additionally tests actual separate tabs, document reload, and
document destruction after interrupted send/receive operations. It uses a fresh
Chromium profile and removes only generated test-wallet keys. Deterministic
cryptographic vectors are public fixtures, and network test seeds are random so
repeated runs do not reuse mint outputs. Fault injection is a test-only wrapper
around `fetch` that matches one armed same-origin `POST /v1/swap` at a time and
never logs request bodies.

Native browser-database conformance and original bridge regression suites:

```sh
zig build test-wallet -Dplatform=wasm
zig build test-wallet
zig build test
```

### Results verified on this machine

| Check | Result |
| --- | --- |
| Complete Wasm bundle with managed pinned tooling | PASS |
| Chromium end-to-end runner | **220 passing checks; 3 failed known wallet-recovery scenarios**; zero uncaught exceptions, command exits nonzero |
| Browser database against pinned CDK conformance suite | **55 tests passed** |
| Original Rust bridge suite | **60 tests passed** |
| Original Zig wallet/Spilman integration suites (`zig build test-wallet`) | **26 tests passed**, header check passed |

The macOS CI job additionally compiles and runs four macOS-only extended-ACL
regression tests; they are compiled out on Linux and were not executed here.

Browser checks include:

- BIP-39 generation/derivation, invalid input rejection, cryptographic keygen.
- Cashu token encoding/decoding and native Spilman vectors: deterministic funding,
  DLEQ verification, signed and unsigned balance updates, 70/30 close, and expiry
  refund. These execute the existing native binding implementations, not JS crypto.
- Native negative Spilman coverage: changed signatures, valid-length wrong channel
  ids, balances above capacity, close with a wrong sender signature/unrelated
  receiver key/over-capacity, and cloned close responses with a corrupted `C_`,
  missing signature, changed amount, or flipped DLEQ challenge. Malformed hex,
  JSON, junk tokens, wrong digest/tweak lengths, the exact-expiry refund boundary,
  and unrelated sender keys are rejected with the expected status codes. Required
  `null` arguments return `NullArgument`; adapter-level missing/non-string/NUL
  arguments throw separately. Error bodies are checked not to echo secrets.
- Live Spilman channels against the running fake mint: active and by-id keyset
  agreement, a real `/test-token` funding swap (the token is never received before
  funding), 70/30 cooperative close, redemption into both wallets with live
  balances, and a separate post-expiry refund channel whose 100 sats are redeemed,
  survive reopen, and remain unchanged across two explicit recoveries.
- Test-only `/v1/swap` fault injection (same-origin POST only, one armed request,
  no request-body logging): malformed response after mint commit, generic network
  rejection after commit, and a held response that exercises the real 60-second
  network deadline. Receive cases assert `NetworkError`/nonzero, no premature
  balance, `RecoveryPending` gating for send/receive/post_swap, exactly-once
  recovery, clean reports, repeated-recovery stability, and full-balance
  spendability (the entire recovered amount is sent and redeemed into a fresh
  wallet, with source/recipient totals and repeated recovery checked). The
  send-after-commit case asserts `SendUncertain`, no success token, gating, and
  fault-once; its failing balance invariant is recorded as a structured failure
  (see known defects below), not as a passing check, and spendability is only
  attempted if the balance invariant holds.
- Actual document destruction without a graceful close: send and receive held
  before any mint request, send and receive held after mint commit, and a successful
  local send whose JS result is never delivered. The last case verifies the pending
  bearer token survives reload, is redeemable exactly once, and disappears from the
  pending list after recovery. Reloaded receive scenarios prove the full recovered
  balance is spendable. Send-interruption scenarios with failing invariants are
  collected in `failures` while the independent receive/pending scenarios continue
  and clean up.
- Wrong-seed rejection without changing storage, quota-write failure propagation,
  mint URL/approval checks, and opening the shared core offline.
- Partial, truncated or incompatible v1 storage is rejected without rewriting the
  raw record (missing `proofs`, `counters`, `sagas`, etc.), while a complete
  record still loads; the same strictness is tested natively and in Chromium.
- Browser Fetch to a real local CDK fake-mint HTTP server: receive 100 fake sats,
  send 40, persist/retrieve the outgoing token, redeem in another wallet, recover,
  and confirm the claimed token leaves the pending list.
- Balance/mint persistence across reopen, exclusive locking across separate tabs,
  handoff between tabs, and persistence across Wasm-instance destruction/reload.

The runner writes `cdk-browser-test.json` and `cdk-browser-test.png` into a
unique `mkdtemp` directory under the operating system's temporary directory and
prints that directory in its output. The JSON carries passing `checks`, a
structured `failures` array, and separate `count`/`failureCount` values. Recorded
known defects set `ok=false` and make the command exit nonzero even though the
remaining independent scenarios finished. Progress/screenshot diagnostics and
Chromium shutdown are bounded (SIGTERM then SIGKILL escalation); CDP disconnect
rejects pending requests, and the JSON artifact is written even when the
screenshot or connection fails. A test-only `BROWSER_TEST_KILL_MS` hook kills the
browser mid-run to verify this bounded path.
Conformance tests use an in-memory substitute for the browser storage calls;
actual localStorage, locking and injected quota failures run in Chromium.

## Implementation and API

`browser/wallet` is a separate Cargo package. It imports these sources directly:

- `vendor/cdk-wallet-ffi/src/wallet.rs`: send/receive, amounts/fees, approvals,
  deadlines, pending tokens, startup/explicit recovery, and wallet-backed Spilman
  helpers. Only opening/storage/timeout primitives are selected by platform.
- `vendor/cdk-wallet-ffi/src/api.rs`: mnemonic and memory-scrubbing helpers.
- `vendor/cdk-wallet-ffi/src/spilman.rs`: all 23 pure channel/token functions.

The original synchronous wallet C exports remain native-only. All **41 functional
operations** (15 wallet lifecycle/network helpers, 3 mnemonic helpers, and 23 pure
Spilman/token helpers) have browser adapters. The 6 C deallocation functions are
internal ownership details, not JavaScript operations. This is **not a binary-
compatible C ABI**: callers use async JS methods and owned JSON results.

The most important runtime adaptation discovered by actually running the app:
CDK's persistent rate limiter uses `tokio::task::spawn_local`, which traps without
a Tokio task context even though compilation succeeds. Each browser wallet now
owns a **`LocalSet`**, cooperatively polled through the browser's future executor.
This preserves the limiter without a multithreaded runtime, Tokio networking,
Mio, an upstream CDK fork, or blocking the browser with `block_on`.

The database implements the complete pinned `WalletDatabase` trait over one
versioned localStorage record per named wallet. It persists seed identity (a
domain-separated fingerprint, **not the seed**), counters, quotes, proofs,
operation ownership, sagas, KV entries, and P2PK metadata. A lifetime Web Lock
protects each wallet. Errors are propagated, corrupt state is not replaced with
an empty wallet, and all mutations read/check/save the current record. CDK's
conformance suite caught a derivation-index upsert issue; the implementation now
preserves the old index when reconstructed proof metadata omits it.

For programmatic usage, import `walletApp` from `app.js`, or the low-level
generated `wallet/cdk_wallet_browser.js` module. The UI uses a serialized queue:

```js
await walletApp.ready;
await walletApp.open(seed64Uint8Array, "my-wallet");
const approved = await walletApp.call("add_mint", ["https://mint.example"]);
const balances = await walletApp.call("list_balances");
const sent = await walletApp.call("send", ["https://mint.example", "100", "5"]);
await walletApp.close();
```

Check `status === 0` before using a result. Amounts, fees, and other `u64` values
are **decimal strings**, never JS Numbers. Arguments are positional and match
the existing native function order (without the handle). Remove the `cdk_wallet_`
prefix for wallet commands, and the `cdk_` prefix for pure commands. Use
`walletApp.pure("mnemonic_to_seed", [phrase])`, for example. Its returned `hex`
field is secret material; never log it. Generated TypeScript declarations expose
`open_wallet`, `BrowserWallet`, and `call_pure`.

## Boundaries and remaining validation

- This is experimental software for **test funds**, not a reviewed production
  browser wallet. Chromium/Linux is verified; Firefox/Safari and mobile are not.
- Browser state is plaintext origin storage. Seeds are not automatically saved,
  but proofs/tokens are bearer secrets. XSS or malicious same-origin scripts can
  compromise them. Browser clearing/eviction can destroy storage. A mnemonic alone
  does not replace the pending-token/database recovery requirements.
- The native panic-unwind guarantee does **not** carry across unchanged. Rust
  panics can abort the Wasm instance. The page rejects further queued operations
  on a runtime trap and requires reload/recovery; this is not proven equivalent
  to native panic containment. Full injected-panic/crash recovery is still needed.
- Fault injection covers one faulted `/v1/swap` request at a time: malformed,
  rejected, and held responses after a real mint commit, plus before-request holds
  destroyed by navigation. It does not claim a complete crash/cancellation matrix:
  CORS denial, page-process crashes, panics, other endpoints, concurrent faults,
  and browser-specific timing permutations remain unexercised.
- Live Spilman cooperative close and post-expiry refund now run against the
  running fake mint and their proofs are redeemed. Wallet network helpers are
  compiled; not every signing-key/raw-swap combination has browser end-to-end
  coverage.
- The renderer and wallet remain separate Wasm modules with separate linear
  memories. The game itself starts a disposable wallet bridge through
  `browser/game-wallet.js` *before* creating its window or main loop: an
  Emscripten JS library dynamically imports the async wallet adapter, generates
  a fresh mnemonic, derives its 64-byte seed, opens a fresh uniquely named
  browser wallet, verifies empty startup reports and balances, closes/frees it,
  and removes only the storage key it created. No mint or network call is
  involved. A single-shot Zig continuation starts the game only on success; any
  import, initialization, storage or cleanup failure shows `Unable to start
  game.` and never creates a game context or frame loop. The game exposes no
  public `Module` snapshot or status API; startup state is internal. Wallet
  controls remain in the wallet module and are exercised only by the
  non-interactive `/wallet-test.html` test fixture.
- LocalStorage rewrites the whole record and blocks briefly while serializing.
  An IndexedDB backend may be appropriate for larger wallets. Do not silently
  swap to a weaker locking or persistence model when platform features are absent.

### Known recovery defects reported by browser tests

These are real limitations of the pinned CDK recovery path reached through the
wrapper. The browser tests do **not** assert them as correct behavior: the runner
records structured `failures` entries (`scenario`, `expected`, `actual`,
`message`), continues the remaining independent scenarios, emits the JSON and
screenshot artifacts, sets `ok=false`, and exits nonzero. They are not
production-safety claims.

- **Nested send-swap recovery over-counts value.** When a send requires an online
  swap, CDK persists that swap as a separate `Swap` saga with
  `ProofReservation::Skip`; the swap saga owns no input proofs. If the mint commits
  the swap and the response is lost, recovery restores the swap outputs but cannot
  mark the swap inputs spent. The parent `Send(ProofsReserved)` saga is then
  compensated and releases those same already-spent inputs as unspent.
  Reproduction in `browser/fault-scenarios.js` and `browser/recovery.js`: fund
  100 sats, spend the four 1-sat refill proofs locally so a 37-sat send cannot be
  composed from the remaining even denominations, then drop the committed
  `/v1/swap` response. The required post-recovery balance is 96 sats; the observed
  value is 130 sats (the in-page and document-destruction scenarios each record a
  failure). The 34-sat difference is an observation of the stale inputs, not an
  expected contract. The tests do not assert that the over-counted proofs are
  spendable. No production fix is applied yet.
- **A send interrupted before its swap request leaves the mint gated.** The send
  reservation is compensated (the 96-sat balance is preserved), but the orphaned
  nested `Swap` saga owns no input proofs, so recovery tries `/restore`; an empty
  restore response is treated as an incomplete response and reported as `failed`,
  leaving the mint blocked. The expected invariants are clean startup/explicit
  recovery and send status 0; the observed startup and retry reports have
  `failed=1`, and a subsequent send returns `RecoveryPending` (19). This is
  recorded as one structured failure.

Run `zig build test -Dplatform=wasm -Doffline` to reproduce. It writes
`cdk-browser-test.json` and `cdk-browser-test.png`, reports the three failed
scenarios in `failures`, and exits nonzero because of these defects.

The earlier [WebAssembly investigation](webassembly.md) is retained as historical
context and a remaining-hardening plan; its initial compilation verdict is now
superseded by this implementation and runtime evidence.
