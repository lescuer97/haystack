# CDK wallet bindings — desktop and browser

Separate builds, coordinated entirely by Zig:

```sh
zig build                       # native desktop: Linux x86_64/aarch64 or macOS Apple Silicon
zig build -Dplatform=wasm        # complete browser application
```

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

Browser tests require Node 22+ and Chromium. They start and stop their own
localhost-only fake mint. The browser wallet is **experimental: test funds only**.

- [Build graphs, automatic tooling, optimization and offline builds](docs/build.md)
- [Browser wallet, runtime verification and remaining limitations](docs/browser-wallet.md)
- [Desktop C-ABI consumer guide](docs/cdk-wallet-ffi.md)
