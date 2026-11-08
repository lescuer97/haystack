# CDK wallet bindings — desktop and browser

Separate builds, coordinated entirely by Zig:

```sh
zig build                       # native Linux desktop
zig build -Dplatform=wasm        # complete browser application
```

Outputs are isolated under `zig-out/desktop` and `zig-out/wasm`. Zig provisions
the selected platform's pinned Rust/toolchain components; Wasm additionally gets
a locally cached wasm-bindgen and Emscripten. Host prerequisites are Zig 0.17.0,
Python 3 and Rustup/Cargo, plus native development libraries for desktop.

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
