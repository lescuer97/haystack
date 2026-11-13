# Linux browser onboarding review

This guide covers the current Wasm onboarding and recovery diff. Run commands
from the repository root on Linux. The browser wallet is experimental: **do not
use real funds or a real recovery phrase** for these checks.

## Prerequisites and setup

Install Zig 0.17+, Rustup/Rust and Cargo, Python 3, Node 22+, Chromium, and a
working native C linker and Clang/LLVM. Chromium must be on `PATH` as `chromium`,
or set its executable explicitly for the browser test commands:

```sh
export CHROMIUM=/absolute/path/to/chromium
```

Provision the pinned Wasm tools once (this step may need network access):

```sh
zig build setup -Dplatform=wasm
```

Subsequent commands below use `-Doffline` optionally, assuming setup and the
required dependencies are already cached. Remove it if dependencies still need
to be fetched. Ordinary build/test steps check tools rather than installing them.
See [build details](../docs/build.md) and the
[browser wallet guide](../docs/browser-wallet.md).

## What to review

- `src/onboarding.zig` and `src/rendering.zig`: shared onboarding state and UI.
- `src/main.zig` and `src/browser_onboarding.zig`: browser frame integration,
  asynchronous mailbox and clipboard interaction.
- `browser/game-onboarding.js`: Emscripten bridge for browser onboarding.
- `browser/wallet/src/browser_onboarding.rs`: recovery service;
  `browser_db.rs`, `browser_platform.rs`, `mint_policy.rs` and
  `browser/wallet/platform.js`: IndexedDB v2, Web Locks, compare-and-swap
  (CAS), mint restrictions and the retained retired stage.
- `build/wasm.zig`: separation of production and fixture builds.
- `browser/onboarding-test.js` and `browser/onboarding-browser-test.mjs`:
  onboarding checks and Chromium runner; also review the existing wallet smoke
  and recovery tests under `browser/`.

## Safety and isolation

The production bundle, `zig-out/wasm`, uses the fixed Minibits mint URL. The
separate `zig-out/wasm-test` fixture is restricted to the local fake mint. Do
not manually run tests from the production bundle. Production startup is no
longer a disposable smoke test; disposable wallets and fixtures remain
test-only. Never delete or reset a real user's wallet to perform this review.

The browser needs Web Crypto, IndexedDB and Web Locks; clipboard access needs a
secure context (localhost qualifies). Recovery phrases are stored in plaintext
by product choice. Denial of `storage.persist()` is nonblocking; this change
adds no storage warning or relay.

## Automated checks

```sh
zig build browser-fixture -Dplatform=wasm -Doffline
zig build test-storage -Dplatform=wasm -Doffline
zig build test-onboarding -Dplatform=wasm -Doffline
zig build test-onboarding -Dplatform=wasm -Doptimize=ReleaseSafe -Doffline
```

Expect the fixture build and Node-only storage/bridge tests to pass. Both
onboarding runs should pass on Linux if the implementation is correct; they
start an ephemeral local fake mint and use fresh disposable Chromium contexts.
The ReleaseSafe run checks that fixture isolation also holds in that mode.

Optional host database conformance tests:

```sh
cargo test --manifest-path browser/wallet/Cargo.toml --offline --test database
```

Expect these to pass when the required Cargo dependencies are cached.

Run the broader suite as well, but **expect a nonzero exit**, not a clean pass:

```sh
zig build test -Dplatform=wasm -Doffline
```

Three known send/swap recovery defects remain as failures, documented by the
FIXME in `browser/wallet/src/lib.rs`. Inspect the output for those and for any
additional failures; do not reclassify the known failures or the overall suite
as passing. The suite also includes the onboarding, storage and database checks.

If onboarding fails, report the failing check label and sanitized output, the
origin and build mode. Never include a seed phrase, clipboard contents, or
other secrets in logs or reports.

## Manual browser checks

In a terminal, start the fixture server (it blocks until stopped with Ctrl-C):

```sh
zig build test-mint -Dplatform=wasm -Doffline
```

It serves the fixture and fake mint at `127.0.0.1:18787` by default. In a
fresh Chromium incognito context, open <http://127.0.0.1:18787/> or
<http://127.0.0.1:18787/renderer/index.html> for the actual game. Keep the
server running. Use only disposable fixture phrases and data.

For the separate noninteractive test-only page, first run `test-onboarding`
above to install its assets, then open
<http://127.0.0.1:18787/onboarding-test.html?flow=create>. This page is not the
game and is not installed by `test-mint` alone.

Check the following in the game, using fresh disposable incognito contexts as
needed rather than touching an existing wallet:

1. On first launch, verify the choice to create or recover a wallet.
2. For creation, check the 12-word backup, individual-word and whole-phrase
   copy actions, and success feedback only when copying succeeds. Continue must
   remain gated until the backup confirmation checkbox is checked.
3. Reload during backup and confirm it persists; complete it and confirm the
   wallet reaches ready state.
4. In a fresh context, try typed and pasted invalid recovery phrases. They must
   be rejected without mutating wallet state.
5. For recovery failure, load the page first, then use DevTools Network Offline
   to interrupt the same-origin fake mint. A failed restore should offer Retry
   only; re-enable networking before reloading, verify the stage survives with
   Retry only, then click Retry.
   Check the completion report's zero/pending/spent information: Generate new
   is safe only for a clean zero result, and the retired stage remains retained.
   With funded/nonzero recovery, expect Continue rather than Generate new.
6. While one tab owns the wallet, check that a concurrent second tab is blocked.
   Malformed records must fail closed without automatic repair. Confirm no
   secrets appear in console or application logs.

The previous macOS host did **not** execute Chromium tests, and final security
review was unavailable. Please run the Linux browser checks and obtain an
independent security review before trusting these changes.
