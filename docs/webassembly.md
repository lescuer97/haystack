# Browser WebAssembly: initial investigation and porting plan

> **Superseded compilation status:** the repository now has an experimental full
> browser bundle using its shared wallet and Spilman code. The Chromium suite now
> runs 221 passing checks and reports 3 failed known recovery scenarios; it exits
> nonzero because of those discovered defects. See
> [current build/run instructions and limitations](browser-wallet.md).
> The initial verdict and staged assessment below are retained as historical
> context, not a statement that the new browser crate fails to compile.
> Build orchestration has since been separated further: use `zig build` for
> desktop or `zig build -Dplatform=wasm` for the complete browser application.
> See [current build instructions](build.md), not the historical commands below.

## Initial verdict (before the browser adapter)

**The graphical demo builds and runs in a browser. The wallet does not compile
for browser WebAssembly yet.** The web build deliberately excludes the Rust
wallet, its C bindings, and all native libraries. It displays a red warning;
there are no fake wallet implementations or successful no-op wallet operations.

A separate Athenut-style browser frontend has now been compiled with our pinned
CDK **0.18.3** in an isolated experiment (see the reference implementation below).
CDK itself is therefore not the compilation blocker. This does not port or
validate our native wrapper: a working equivalent needs the changes and
validation below; changing the compiler target alone cannot do it.

## Build and run the version available now

> **Historical commands:** the `-Dtarget=wasm32-emscripten` commands below no
> longer select the browser graph. Current builds require
> `zig build -Dplatform=wasm`; `-Dtarget` alone now fails with an explanation.
> The `zig-out/web` paths and `web`/`emrun` steps below are retained as historical
> context only. See [current build instructions](build.md).

Prerequisites: Zig 0.17.0, Python 3, internet access for the initial dependency and
SDK downloads, and a browser with WebGL. Rust is **not** used by this web build.
The pinned raylib build helper manages Emscripten automatically. Its SDK helper
currently selects **4.0.19**, even though the emsdk package URL is tagged 4.0.9.
The browser build now replaces its unconditional `emsdk update` step with an
install-once version check; do not assume the initial SDK download is offline.
No shell startup changes are needed.

```sh
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall
python3 -m http.server 8000 --bind 127.0.0.1 --directory zig-out/web
```

Open <http://127.0.0.1:8000>. Serve the **whole** `zig-out/web` directory, not just
the `.wasm` file: `index.html` and `index.js` load `index.wasm`. Do not use a
`file://` URL. Debug builds also emit a source map.

Other supported commands:

```sh
zig build -Dtarget=wasm32-emscripten                 # Debug
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSafe
zig build web -Dtarget=wasm32-emscripten            # explicit web step
zig build run -Dtarget=wasm32-emscripten            # Emscripten's emrun
```

`src/main.zig` shares drawing between native and browser builds. The browser
exports a C-compatible `main(argc, argv)` and registers a frame callback with
`emscripten_set_main_loop`; it does not block the browser in a desktop loop.
`build.zig` creates static Wasm archives and lets Emscripten do the final link,
with the matching full UBSan runtime in safety-enabled builds.

## Verification performed

Local validation on Linux with Zig 0.17.0, Rust stable 1.99.0, Emscripten 4.0.19,
and Chromium 155:

| Check | Result |
| --- | --- |
| Browser Debug compilation | PASS |
| Browser ReleaseSafe compilation | PASS |
| Browser ReleaseSmall compilation | PASS |
| Debug and ReleaseSmall browser execution | PASS: 800×450 WebGL canvas renders demo and wallet warning |
| `zig build` (native) | PASS |
| `zig build test` (native) | PASS: one application test; executable test runner also succeeds |
| `zig build wallet-wasm-check` | FAIL: `mio` rejects the browser target |

The runtime smoke test used headless Chromium with SwiftShader, a local HTTP
server, and a five-second virtual-time budget. It checked the rendered screenshot
and startup console. This is not wallet testing, browser interoperability testing,
or a financial safety claim. The wallet suites were not rerun for this UI/build-only
change.

### Reproduce the wallet failure

```sh
rustup target add wasm32-unknown-unknown --toolchain stable
zig build wallet-wasm-check
```

The build step executes the real compilation command:

```sh
cargo +stable build --release --locked --lib \
  --target wasm32-unknown-unknown \
  --manifest-path vendor/cdk-wallet-ffi/Cargo.toml
```

Observed primary diagnostic (`mio` 1.2.4):

```text
This wasm target is unsupported by mio. If using Tokio, disable the net feature.
```

Cargo exits 101; the Zig step fails too. Subsequent missing `Selector`, `tcp`, and
`udp` errors are consequences, not dozens of independent bugs. A missing Rust
target instead means setup is incomplete, not that the wallet has been tested.

## Blockers: observed versus identified by source inspection

Only the `mio` failure is a compiler-confirmed first blocker. Compilation stops
there; the other issues below were identified in source and must be checked as
the port progresses.

| Blocker | Evidence | Required change |
| --- | --- | --- |
| Native networking/runtime features | `vendor/cdk-wallet-ffi/Cargo.toml` enables Tokio `net` and `rt-multi-thread`; `wallet.rs::runtime` builds a multithreaded runtime | Separate native and browser dependencies/execution; audit additive transitive features too |
| Native database implementation | `cdk-sqlite` 0.18.3 itself enables `rt-multi-thread` and bundled `rusqlite`; wrapper directly uses `rusqlite` | Browser-persistent implementation of CDK's database interfaces, not just removing the wrapper's Tokio flags |
| Unix filesystem contract | `wallet.rs` unconditionally imports `std::os::unix::fs`, checks permissions/inodes, uses `O_NOFOLLOW`, and retains a locked `File` | Replace paths, file permissions, and file locks with explicit browser storage/ownership policies |
| Synchronous ABI | `api.rs`/`spilman.rs` wallet operations drive futures using `runtime().block_on(...)` | Asynchronous browser API; browser I/O cannot complete while its event loop is blocked |
| Panic contract | `lib.rs` explicitly rejects `cfg(panic = "abort")`; ordinary browser Rust builds default to abort | Validate a supported unwind configuration or define a separate fail-closed Wasm-instance failure contract |
| Native archive/linker assumptions | Existing native build names `target/release/libcdk_wallet_ffi.a` and links `unwind`, `pthread`, `dl`, `rt`, `util`, `m` | Keep these exclusively native; a host archive is not a Wasm artifact |
| Module/toolchain boundary | Raylib uses Emscripten; CDK's browser transport uses `wasm-bindgen` and JS browser objects | Prefer separate modules coordinated by JS rather than blindly linking the two ABIs |

Relevant upstream sources in the pinned crates:

- `cdk/src/wallet` and target-specific dependencies in `cdk/Cargo.toml`.
- `cdk-http-client/src/backends/wasm_backend.rs`: Fetch-based transport.
- `cdk-http-client/src/ws/wasm.rs`: browser WebSockets.
- `cdk-common/src/database/wallet/mod.rs`: Wasm `async_trait(?Send)` interface.
- `cdk-sqlite/Cargo.toml`: unconditional multithreaded runtime dependency.

## Athenut reference implementation

Inspected [thesimplekid/athenut](https://github.com/thesimplekid/athenut) at
commit `efff62aa76113033e53b1a1e5a7773aefdff4a04`. Its frontend already implements
a browser wallet. The published history has an initial application commit and
an agent-guidelines commit, not a separately reviewable browser-port patch series.

### How it avoids the native blockers

- [`athenut-frontend/Cargo.toml`](https://github.com/thesimplekid/athenut/blob/efff62aa76113033e53b1a1e5a7773aefdff4a04/athenut-frontend/Cargo.toml)
  uses published CDK **0.17.0**, `default-features = false`, `features = ["wallet"]`.
  It has no production dependency on `cdk-sqlite`, safer-ffi, or direct Tokio
  networking. Tokio appears in its dev-dependencies for native tests.
- [`wallet.rs`](https://github.com/thesimplekid/athenut/blob/efff62aa76113033e53b1a1e5a7773aefdff4a04/athenut-frontend/src/wallet.rs#L89-L93)
  constructs CDK's `Wallet` directly with a BIP-39-derived seed and its own database.
  It does not port a synchronous native C ABI.
- [`main.rs`](https://github.com/thesimplekid/athenut/blob/efff62aa76113033e53b1a1e5a7773aefdff4a04/athenut-frontend/src/main.rs#L29-L36)
  and page handlers use async `spawn_local` tasks, not a multithreaded runtime or
  `block_on`. Its renderer is Leptos CSR; Trunk bundles the browser module.
- [`db.rs`](https://github.com/thesimplekid/athenut/blob/efff62aa76113033e53b1a1e5a7773aefdff4a04/athenut-frontend/src/db.rs)
  implements `WalletDatabase` over **localStorage, not IndexedDB**. One serialized
  store holds proofs, keysets, counters, quotes, transactions, sagas, KV entries,
  and P2PK keys. Writes re-read/update/save under a cross-tab Web Lock; the trait
  implementation uses `async_trait(?Send)` on Wasm.
- The native mint/server remains a separate package and serves the frontend and
  APIs from one origin. That avoids cross-origin deployment issues for its normal
  configured mint, not for arbitrary external mints.

The target-specific dependency command below reports nothing to print: **Mio is
not in the frontend's normal browser dependency graph**, even though it exists in
the workspace lockfile for other targets/packages. No Mio patch/replacement is
needed for this architecture.

```sh
cargo +stable tree --locked -p athenut-frontend \
  --target wasm32-unknown-unknown -e normal -i mio
```

### What we should reuse, and what we should not copy unchanged

The reusable pattern is a separate async browser entry point plus a browser
`WalletDatabase`, retaining CDK for wallet/protocol logic. **IndexedDB and Web
Workers are design choices, not prerequisites for compilation**: Athenut uses
main-thread browser tasks and localStorage. Our renderer can remain Zig/raylib;
there is no need to migrate it to Leptos to adopt this wallet architecture.

The database is not a drop-in for our pinned **0.18.3** trait. An isolated compile
check of the same frontend against 0.18.3 reached application code and reported
exactly two errors:

1. Missing `WalletDatabase::increment_derivation_counter`. A compatible backend
   needs a separate persisted namespace-to-counter map and atomic increments.
2. `CurrencyUnit::Custom` now takes `Arc<str>` rather than `String`.
   `CurrencyUnit::custom(UNIT)` is the current constructor. Our Sat-only backend
   would not need Athenut's custom `xsr` unit at all.

Compare behavior as well as method names, particularly proof release and operation
ownership. Its application is a custom-unit search wallet, not our Sat-only,
multi-mint C ABI or Spilman channel integration.

The unmodified project was successfully compiled with Rust stable 1.99.0:

```sh
cargo +stable build --release --locked -p athenut-frontend \
  --target wasm32-unknown-unknown
```

Its output `target/wasm32-unknown-unknown/release/athenut-frontend.wasm` was also
validated with Node's `WebAssembly.validate`. This verifies compilation, not mint
interoperability or financial correctness. Trunk/wasm-bindgen browser bundling and
live wallet operation were not exercised in this reference-project check.

An isolated copy was then built with CDK/cdk-common 0.18.3 and the two source
adaptations above. The new counter uses a serde-defaulted separate map and checked
addition under the existing write lock. **The full release Wasm build succeeded**;
its output also passes `WebAssembly.validate`, and its normal browser dependency
graph contains no Mio. This is a compilation experiment, not a hardened port: it
retains the reference implementation's storage and recovery caveats below.

| Reference check | Result |
| --- | --- |
| Original Athenut, locked release Wasm build, CDK 0.17.0 | PASS |
| Original Athenut, `cargo +stable test --locked -p athenut-frontend` | PASS: 46 tests |
| Isolated Athenut-style frontend with CDK 0.18.3, before source adaptation | FAIL: two application API errors, no Mio error |
| Isolated CDK 0.18.3 frontend after counter/custom-unit adaptations, release Wasm build | PASS |
| Node `WebAssembly.validate` on both compiled modules | PASS |
| Live browser wallet operations / browser fault-injection tests | NOT RUN |

The unmodified checkout and isolated probe are under
`/tmp/opencode/athenut-browser-review` and `/tmp/opencode/athenut-cdk018-probe` on
this machine. The probe is not part of this repository's production build.
Rebuild it with:

```sh
cargo +stable build --release --locked --target wasm32-unknown-unknown \
  --manifest-path /tmp/opencode/athenut-cdk018-probe/Cargo.toml
```

For this repository, the next concrete implementation is therefore a small
browser-specific Rust crate using CDK 0.18.3 and an adapted browser database,
exposing async JS operations alongside the existing Emscripten renderer. Keep
the native safer-ffi/SQLite crate intact; extract shared wallet policy as needed.
Do not downgrade CDK or patch Mio. Preserve mint approvals, seed/store identity,
deadlines, full recovery, and Spilman behavior before claiming functional parity.

Source-level caveats relevant to our existing safety requirements (not a complete
security audit):

1. `db.rs::save` logs persistence failure but returns no error; `write` returns
   the mutation result regardless. Database methods can therefore report success
   after a quota/disabled-storage failure. Our backend must propagate failure.
2. `db.rs::with_lock` proceeds unlocked if Web Locks are unavailable. Our backend
   must fail closed or enforce another tested exclusive-ownership mechanism.
3. `wallet.rs::seed_phrase` stores the mnemonic as plaintext under `seed` and
   ignores the result of saving it. That is not equivalent to native secret
   storage, and failed seed persistence must not allow normal wallet operation.
4. `pages/search.rs::perform_search` returns a proof to unspent on a network
   error, assuming the server never saw it. A lost response does not establish
   that; preserve our uncertain-outcome/recovery rules instead.
5. Startup invokes legacy migration and pending-search-proof reclamation. There
   is no explicit `recover_incomplete_sagas` invocation in the frontend sources;
   this is not evidence of parity with our all-saga, fail-closed recovery policy.
6. Its native conformance tests use in-memory storage. They do not establish
   browser quota handling, cross-tab locking, crash durability, or XSS resistance.

Consequently, Athenut makes the architecture much more concrete, but copying its
storage/recovery implementation unchanged would weaken this wrapper's contract.

## Ordered wallet implementation plan

Do not implement all of this before testing the foundation. Each stage has an
explicit gate; if a gate fails, fix it or stop and revise the design.

### 1. Establish the API and module boundary

Keep the current native crate/C ABI intact. Add a separate browser Rust crate
targeting `wasm32-unknown-unknown`, producing a `cdylib` with `wasm-bindgen` glue.
Do not make the native wrapper appear portable by compiling out its safety checks.

Use two independent Wasm modules: Emscripten for rendering, Rust for the wallet.
JS coordinates them. A dedicated wallet Web Worker owns wallet state; commands
and results cross a message boundary, not raw pointers between linear memories.

Inventory all 47 existing exports. Map each to a browser operation, ownership
rule, and test, or explicitly mark it unsupported. Represent `u64` sats as BigInt
or validated decimal strings, not imprecise JS Numbers.

**Gate:** written API mapping; a worker round-trip initializes a minimal Rust
module and returns structured success/error without linking any native archive.

### 2. Prove the smallest CDK browser dependency graph

Add pinned CDK 0.18.3 with only wallet features to the new crate. Do not include
`cdk-sqlite`, direct `rusqlite`, native `libc`, Tokio networking, header generation,
or the native safer-ffi wrapper. Audit `cargo tree -e features --target
wasm32-unknown-unknown`; removing a direct feature does not remove an identical
feature enabled transitively. The current graph also includes `cdk-sql-common`,
`cdk-signatory`, and tonic, so inspect those feature paths rather than assuming
all native features originate in the wrapper.

Prove the browser crypto/RNG setup using the exact locked dependency versions.
Build and run an offline CDK operation; then add the vendored Spilman primitives
and run the existing channel/token fixtures through the browser module. If
necessary, split pure primitives from wallet-backed helpers.

**Gate:** a real Rust `.wasm` plus generated JS loads in a browser; deterministic
fixtures match native results; browser CSPRNG works and fails closed when absent.
If upstream patches are required, isolate and document them before proceeding.

### 3. Resolve panic behavior before accepting wallet state

Test whether the chosen Rust/wasm-bindgen/browser combination supports the unwind
semantics needed by the wrapper. This requires an injected-panic runtime test,
not merely a compiler flag. Do not simply delete `lib.rs`'s abort guard.

If reliable containment is not available, use a separately documented browser
contract: a trap kills the wallet worker/instance; reject outstanding requests,
never reuse its in-memory state, and reopen from durable storage with recovery
before allowing another mutation. Preserve the native unwind/poisoning behavior.

**Gate:** injected panic cannot produce apparent success or reuse poisoned state;
restart/recovery behavior is tested. If exact native panic semantics are mandatory
and cannot be demonstrated, stop: that requirement is not satisfied.

### 4. Implement durable storage and exclusive ownership

Evaluate a compatible IndexedDB-backed database implementation first; otherwise
implement the pinned `WalletDatabase` and KV interfaces. An in-memory database is
acceptable only for stage-2 experiments, never as the production wallet backend.
Do not assume an existing implementation covers sagas and all wrapper KV needs.

Preserve marker/version and seed-fingerprint checks **before** migrations or
mutations, explicit mint approvals, proof/counter/saga persistence, pending-token
retrieval, and the required atomicity. A successful storage call must correspond
to a completed durable transaction before network mutation or success is exposed.

Replace Unix locks with exclusive browser ownership, for example Web Locks held
for the wallet lifetime, plus serialized worker commands. Feature-detect support
and fail closed rather than silently allowing two tabs to mutate one wallet.
Handle quota failures, denied persistence, storage eviction, and schema upgrades.

**Gate:** reopen retains state; wrong-seed/foreign-storage rejection causes no
mutation; two tabs cannot own the same wallet; injected failures preserve proof,
counter, marker, and saga invariants. Do not promise persistence against deliberate
browser data clearing; require and explain backup.

### 5. Add asynchronous networking and browser deadlines

Use CDK's existing browser Fetch transport. Replace blocking `block_on` exports
with async operations/Promises; keep one ordered command queue per wallet. Keep
the mint URL validation and normalized allowlist, including rejecting userinfo,
query strings, and fragments before any request.

Replace Tokio-driven wrapper deadlines with browser-compatible timers/cancellation.
Preserve the existing 60-second network and 120-second recovery policy unless a
documented change is approved. Timeout during a mutation means uncertain outcome:
block further mutations and recover, never blindly retry. Aborting Fetch does not
prove the mint did not commit. Test response-loss and cancellation after commit.

**Gate:** a CORS-enabled test mint supports approve/read/send/receive; blocked CORS,
redirects, malformed URLs, hung requests, and lost responses fail correctly without
freezing rendering or leaking tokens into logs.

### 6. Reproduce startup and interrupted-operation recovery

Run recovery for every approved wallet/mint on open. Preserve pending tokens and
operation IDs. Keep mutations blocked while recovery has skipped or failed work.
Do not treat pending-send enumeration as complete recovery: receive and other saga
types also require their persisted recovery data.

**Gate:** kill/reload the worker or page around each persistence/network boundary,
including after a mint commits but before the response arrives. On restart,
balances/proofs are consistent, tokens remain retrievable, and unresolved work
cannot be spent again. Reuse native fake-mint scenarios where possible, exposed
through a CORS-enabled test server.

### 7. Integrate the renderer and review browser-specific security

Connect wallet worker messages to the Emscripten UI without pretending the modules
share memory. Copy only required inputs/results, validate lengths, and scrub
temporary secret buffers where possible. JS strings/GC cannot offer the same
zeroization guarantees as owned native byte buffers; state that limitation.

Define seed import/backup/storage policy. Do not place seed material or bearer
tokens in URLs, analytics, console output, or unprotected localStorage. Treat XSS
and third-party scripts as wallet compromise; restrict deployed scripts/CSP and
review origin, HTTPS, and supply-chain requirements. A worker is not a security
boundary against malicious same-origin application code.

**Gate:** UI remains responsive during I/O; errors propagate truthfully; no secret
logging; native/browser fixture parity and a browser-specific security review pass.

### 8. Make compilation and behavior continuous acceptance tests

Pin compatible Rust, Zig, Emscripten, and wasm-bindgen tooling. Add CI for the
renderer build, browser wallet build, native regression suites, and headless
browser integration/recovery tests. Exercise Chromium and Firefox plus any other
supported browser; distinguish required tests from optional capabilities.

**Gate:** clean builds and fault-injection tests pass without native artifacts or
developer-machine dependencies. Only then replace the UI's wallet-unavailable
warning and describe the browser version as a functioning wallet.

## What is not possible unchanged

- A browser cannot load the Linux Rust archive or provide real Unix paths,
  permissions, advisory file locks, or arbitrary native TCP sockets.
- A target flag cannot preserve this blocking native wallet API on the browser
  event loop. Moving the same blocking code into a worker alone is not a fix:
  browser async work still needs that worker's event loop to progress.
- A browser cannot bypass a mint's CORS policy. The mint must permit the deployed
  origin, or an explicitly designed relay is needed, changing the trust model.
- Browser storage and origin isolation cannot offer identical OS-level secret
  storage guarantees or guaranteed retention after user data clearing/eviction.

If *unchanged synchronous ABI plus identical Unix security semantics* is a hard
requirement, the answer is **no for a normal browser**. Keep the wallet in a native
application/service instead; that is a different deployment, not an in-browser
wallet. If browser-specific async/storage/security contracts are acceptable, the
staged port above is plausible, but its success is not yet verified.
