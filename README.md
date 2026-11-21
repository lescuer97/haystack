# CDK wallet bindings — desktop and browser

Separate builds, coordinated entirely by Zig:

```sh
zig build                       # native desktop: Linux x86_64/aarch64 or macOS Apple Silicon
zig build -Dplatform=wasm        # complete browser application
```

The independent [local server](docs/server.md) builds with
`zig build server -Dgame=false` and has socket-free tests via `test-server`.
It requires the native Rust/CDK toolchain and initializes a separate headless
`haystack-server` wallet before listening; operators must back up its seed and DB.
The server is not part of the default client install. For local play, run
`zig build run-server` in one terminal and either `zig build run` (desktop) or
`zig build run -Dplatform=wasm` (browser) in another. Both clients authenticate to
`ws://127.0.0.1:9224/` after wallet onboarding and sync movement. If the server is
unavailable, they show a disconnected screen and retry. The browser endpoint is
loopback; it is not a remote deployment or `wss://` configuration.

The browser graph is selected **only** by `-Dplatform=wasm`. A Wasm
`-Dtarget` alone (including `-Dtarget=wasm32-emscripten`, `wasm64-*` or WASI)
is rejected with an explanation; it never infers the browser build. An explicit
`-Dplatform=wasm -Dtarget=wasm32-emscripten` remains valid. Desktop builds are
native only: foreign OS/architecture/ABI targets and macOS Intel are rejected
before tool provisioning.

Outputs are isolated under `zig-out/desktop` and `zig-out/wasm`. The desktop
build installs `zig-out/desktop/bin/haystack_game` and a shared raylib library
(`libraylib.so` on Linux, `libraylib.dylib` on macOS) under
`zig-out/desktop/lib`. The executable records only a relative
`$ORIGIN/../lib` (Linux) or `@loader_path/../lib` (macOS) lookup, so the
installed `desktop` directory can be moved outside the repository.

On Linux and macOS the desktop binary creates its window and world first, then
runs native wallet startup inspection. A validated existing wallet proceeds to
server authentication. A new or pending wallet shows a blocking onboarding
overlay that requires saving and acknowledging the recovery words (or recovering
an existing wallet) before gameplay. The desktop wallet is persistent: a plaintext BIP-39
mnemonic (`seed-words.txt`) and a CDK SQLite database (`wallet.sqlite`) live in a
Haystack-owned wallet directory with owner-only permissions; macOS extended ACLs
are rejected. Startup inspection is local and makes no mint request. Invalid or
unavailable storage blocks startup rather than repairing or replacing existing
records. This remains an experimental, test-funds-only wallet, not a production
key store. See [game-loop.md](docs/game-loop.md#native-wallet-startup) and
[cdk-wallet-ffi.md](docs/cdk-wallet-ffi.md) for the native startup and storage
contracts.

The browser application is the game only: `/` redirects to `renderer/index.html`,
where a blocking shared Zig modal handles persistent `haystack-user` wallet
creation, backup and recovery. The renderer runs while asynchronous wallet
inspection completes; gameplay remains gated until onboarding succeeds. Missing
modules or invalid storage block setup rather than replacing wallet records. The
browser wallet regression suites use a separate non-interactive test fixture at
`wallet-test.html`, installed only for `test`/`test-mint`.

Host prerequisites are Zig 0.17.0, Python 3, Rustup/Cargo and a native C
toolchain. Linux additionally needs the normal raylib/X11/OpenGL development
libraries and libunwind. macOS requires **native Apple Silicon (arm64)**,
macOS 15.0 or newer, Xcode Command Line Tools and a macOS SDK; `zig build` runs
an actionable preflight and never uses sudo or installs system packages. macOS
Intel, universal binaries, packaging, signing and `.app`/DMG output are not
supported.

Provision the selected platform once. This is the only path that installs Rust
components, wasm-bindgen or Emscripten:

```sh
zig build setup                  # desktop Rust toolchain/target + native checks
zig build setup -Dplatform=wasm  # Wasm target, local wasm-bindgen, Emscripten
```

Normal builds, tests, `run`, `header-check`, `wallet` and `renderer` only
**check** the selected installed tools, then build. They never install or update
Rust toolchains/targets, wasm-bindgen or Emscripten; a missing tool fails with
the required setup command. `zig build setup -Doffline` only checks and explains
what is missing. Online dependency fetching by Cargo or Zig is separate from
tool installation. The macOS desktop graph fixes the deployment target at macOS
15.0 for Zig, raylib and Rust, requires the running OS to be 15.0+ and rejects
conflicting `SDKROOT`, CC-family compiler or effective `CFLAGS` sysroot
overrides. The macOS path is implemented but has not been executed on real macOS
hardware or in CI; `.github/workflows/ci.yml` contains the Apple Silicon job that
must provide that validation. This Linux checkout verifies only the source/unit
contracts. See [build.md](docs/build.md) for the exact scope and remaining
validation limits.

```sh
zig build run -Dplatform=wasm    # build and serve at localhost:8000
zig build test-wallet           # native Rust + Zig C-ABI regression suites
zig build test -Dplatform=wasm   # browser database + fake-mint/Chromium tests
```

## Dependencies

Both Cargo roots (`vendor/cdk-wallet-ffi` for the native C ABI, `browser/wallet`
for the Wasm module) resolve **one** CDK source: Git tag `v0.18.1` of
`https://github.com/cashubtc/cdk.git` (commit
`a056e0f0f69e94f431b1aeb90d883f18c61ea4c6`), with `version = "=0.18.1"` guards.
Spilman comes from `https://github.com/SatsAndSports/cashu_spilman_channels` at
rev `8a5350dfd4d7c2902dc15c726a91dbfb2c793d43` (`v0.2.0`). There is no Cargo
workspace merge, `[patch]`, fork or local Spilman crate copy.

This is a deliberate step from the registry `0.18.3` crates to `v0.18.1`,
because upstream Spilman `v0.2.0` itself pins `v0.18.1`. It is **not** a claim
that the releases are equivalent and not a production certification; the wallet
SQL schema is identical between them. As confirmed by the maintainer on
2026-11-15, no production wallets currently exist, so funded-wallet downgrade
validation is not a blocker for this pre-production migration; the CDK pairing
and its risks are accepted for now, for **test funds only**. See the
[current wallet status](docs/build.md#current-wallet-status) for when to revisit
this decision. Any funded test wallets (and future production wallets) should
be backed up before switching builds. Details, the reviewed upstream differences
and the limits of the empty-wallet reopen evidence are in
[build.md](docs/build.md#dependency-provenance-cdk-v0181-and-spilman-v020).

Verify the resolved graph after provisioning tools (check-only; never installs):

```sh
python3 build-support/check_dependency_pins.py           # --offline to forbid Cargo network
```

Browser tests require Node 22+ and Chromium. They start and stop their own
localhost-only fake mint. The browser wallet is **experimental: test funds only**.

- [Build graphs, automatic tooling, optimization and offline builds](docs/build.md)
- [Browser wallet, runtime verification and remaining limitations](docs/browser-wallet.md)
- [Desktop C-ABI consumer guide](docs/cdk-wallet-ffi.md)
