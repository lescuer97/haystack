# Experimental browser wallet: compiled and runtime-tested

The complete browser bundle now builds and runs: CDK **0.18.3**, this repository's
shared wallet-policy implementation, the vendored Spilman bindings, and the
Zig/raylib renderer. **Use test funds only.** This is a working experimental port,
not a production-security or full fault-recovery certification.

## Build

Host prerequisites: Zig 0.17.0, Python 3 and Rustup/Cargo. Zig automatically
provisions Rust **1.99.0**, its Wasm target, local wasm-bindgen CLI **0.2.130**,
and Emscripten **4.0.19**. For browser tests, Node 22+ and Chromium are required.
See [separate platform build graphs and options](build.md) for the full contract.

```sh
zig build -Dplatform=wasm
```

An existing matching CLI can optionally override the automatically managed one:

```sh
zig build -Dplatform=wasm -Dwasm-bindgen=/absolute/path/to/wasm-bindgen
```

Output: **`zig-out/wasm/index.html`** plus two independent Wasm modules and
their JavaScript loaders. The Rust wallet uses wasm-bindgen; the renderer uses
Emscripten. The first renderer build downloads SDK 4.0.19. Subsequent builds
check the installed version instead of executing upstream's unconditional
`emsdk update` (which caused a 502 failure and a hung build during testing).

Serve the entire directory, not just a `.wasm` file:

```sh
zig build run -Dplatform=wasm
```

Open <http://127.0.0.1:8000>. Use HTTPS for deployment; localhost HTTP is sufficient
for local testing. Web Crypto, WebAssembly, localStorage, and Web Locks are
required. Opening is refused when locking/storage cannot be established.

`zig build -Dtarget=wasm32-emscripten` also builds the **complete** browser bundle.
Renderer-only work is explicit: `zig build renderer -Dplatform=wasm`.
The native-crate Wasm probe is no longer a project build step.

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

You can also visit <http://127.0.0.1:18787/?smoke> manually. The page reports its
browser checks; the Node runner additionally tests actual separate tabs and
document reload. It uses a fresh Chromium profile and removes only generated
test-wallet keys. Deterministic cryptographic vectors are public fixtures, and
network test seeds are random so repeated runs do not reuse mint outputs.

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
| Chromium end-to-end runner | **42 checks passed**, zero uncaught exceptions |
| Browser database against pinned CDK conformance suite | **51 tests passed** |
| Original Rust bridge suite | **51 tests passed** |
| Original Zig wallet/Spilman integration suites (`zig build test-wallet`) | **26 tests passed**, header check passed |

Browser checks include:

- BIP-39 generation/derivation, invalid input rejection, cryptographic keygen.
- Cashu token encoding/decoding and native Spilman vectors: deterministic funding,
  DLEQ verification, signed and unsigned balance updates, 70/30 close, and expiry
  refund. These execute the existing native binding implementations, not JS crypto.
- Wrong-seed rejection without changing storage, quota-write failure propagation,
  mint URL/approval checks, and opening the shared core offline.
- Browser Fetch to a real local CDK fake-mint HTTP server: receive 100 fake sats,
  send 40, persist/retrieve the outgoing token, redeem in another wallet, recover,
  and confirm the claimed token leaves the pending list.
- Balance/mint persistence across reopen, exclusive locking across separate tabs,
  handoff between tabs, and persistence across Wasm-instance destruction/reload.
- The independent Zig/raylib Wasm renderer initializes in the same browser page.

The runner writes `/tmp/opencode/cdk-browser-test.json` and
`/tmp/opencode/cdk-browser-test.png` with the result and rendered screenshot.
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
- Fault cases such as reload exactly after mint commit, hung requests, CORS denial,
  dropped responses, and every browser send/cancel/receive boundary are not all
  exercised here. Native fault-injection tests pass and the browser reuses that
  policy, but that is not a substitute for a browser-specific fault matrix.
- Pure Spilman flows replay signed fixture responses; they are not live
  cooperative-close/refund transactions against the running fake mint. Wallet
  network helpers are compiled; not every signing-key/raw-swap combination has
  browser end-to-end coverage.
- The renderer and wallet are separate modules. The supplied browser page connects
  wallet controls alongside the renderer; Zig itself does not call the async JS
  wallet or share its linear memory yet.
- LocalStorage rewrites the whole record and blocks briefly while serializing.
  An IndexedDB backend may be appropriate for larger wallets. Do not silently
  swap to a weaker locking or persistence model when platform features are absent.

The earlier [WebAssembly investigation](webassembly.md) is retained as historical
context and a remaining-hardening plan; its initial compilation verdict is now
superseded by this implementation and runtime evidence.
