# Separate desktop and Wasm builds

The root `build.zig` selects **one** application platform graph. Native
configurations also expose the independent server graph in `build/server.zig`;
the default install/run remains desktop-only. Normal application builds do
not run a Python application builder, invoke another `zig build`, or configure
the other platform. The graph-isolation test queries each configuration's help
menu, without building the other application; server-only regressions verify that
a selected missing Rust toolchain fails the server build without provisioning it.

| Command | Output / action |
| --- | --- |
| `zig build setup` | Provision the selected desktop Rust toolchain/target and validate native prerequisites; no application compilation |
| `zig build` | Desktop application: `zig-out/desktop/bin/haystack_game`, assets in `zig-out/desktop/bin/assets`, shared raylib in `zig-out/desktop/lib` (Linux or macOS Apple Silicon) |
| `zig build -Dplatform=wasm` | Complete browser bundle: game shell at `zig-out/wasm/renderer/index.html` (root `zig-out/wasm/index.html` redirects), Rust wallet, JS bindings and Zig renderer |
| `zig build run` | Build, install, then run the installed desktop binary next to its installed raylib |
| `zig build run -Dplatform=wasm` | Build/serve the browser application at `http://127.0.0.1:8000` |
| `zig build test` | Desktop application tests |
| `zig build server -Dgame=false` | Build/install only `zig-out/bin/haystack_server`; requires the native Rust/CDK toolchain, C ABI and native target policy, but no Raylib or browser checks (see [server prerequisites](server.md)) |
| `zig build run-server -Dgame=false -- ...` | Explicitly run the standalone local server |
| `zig build test-server -Dgame=false` | Socket-free server core (including real-wallet ownership and volatile world), shared, native-storage helpers and bounded WebSocket memory tests |
| `zig build test-wallet` | Native Rust suite, C-header check, Zig wallet/Spilman ABI tests |
| `zig build test -Dplatform=wasm` | Isolated browser fixture, database conformance and Node tests, ephemeral fake mint and Chromium tests; exits nonzero for three known send/swap recovery assertions |
| `zig build test-storage -Dplatform=wasm` | Node-only settings/content bridge tests against an in-memory IndexedDB (no Chromium) |
| `zig build test-wallet -Dplatform=wasm` | Browser database conformance tests on the host |
| `zig build test-mint -Dplatform=wasm` | Build/serve the browser app with a localhost-only fake mint at port 18787 |
| `zig build wallet-fixture -Dplatform=wasm` | Build the isolated local-mint fixture wallet under `zig-out/wasm-test` |
| `zig build browser-fixture -Dplatform=wasm` | Build the isolated browser fixture application under `zig-out/wasm-test` |
| `zig build test-onboarding -Dplatform=wasm` | Linux-only onboarding suite with a fake mint and fresh Chromium incognito contexts |
| `zig build test-wallet-ui -Dplatform=wasm -Doffline` | Functional game wallet deposits, complete-invoice clipboard, exactly-once payment, closed-menu settlement and persisted history/selection/reload; gated ephemeral fake mint and isolated Chromium, no image checks |
| `zig build test-withdrawal-ui -Dplatform=wasm -Doffline` | Functional real-renderer withdrawal Review/Cancel/explicit payment, long clipboard invoice, Pending/reload/recovery and local history; fresh isolated fake mint and Chromium, no image checks |
| `zig build test-qr-portability -Doffline` | C encoder object checks for Linux x86_64/aarch64 and macOS 15 ARM64; not ARM64 application/runtime verification |
| `zig build setup -Dplatform=wasm` | Provision Rust + Wasm target, local wasm-bindgen and Emscripten without building the application |
| `zig build test-build` | Test graph isolation, explicit setup/check contracts, the native target matrix and the upstream Emscripten adapter |
| `zig build test-package -Dplatform=wasm -Doffline` | Explicit offline Zig-filtered source-package regression, including server-only build/tests and production browser (warmed dependencies/tools required; also available in the desktop graph) |

`zig build -Dtarget=wasm32-emscripten` **does not** select the Wasm graph. Browser
builds require the explicit platform flag: `zig build -Dplatform=wasm` (optionally
with `-Dtarget=wasm32-emscripten`). A Wasm target alone, including `wasm64-*` or
WASI, fails during configuration with an explanation before any tool setup. For
deliberate renderer-only development use `zig build renderer -Dplatform=wasm`.
The old `zig build browser` command now needs `-Dplatform=wasm`; prefer the
unambiguous commands above. The misleading native `wallet-wasm-check` step has
been removed; the browser has its own Rust package.

## What stays separate

`-Dgame=false` configures the shared UI-free `build/native_wallet.zig` graph and
applies its native CDK target policy before returning without invoking either
the desktop game or browser helper. Desktop and server share this native wallet
graph; provision server-only tools with `zig build setup -Dgame=false`. The flag
is invalid with `-Dplatform=wasm`, which has no server steps. Server steps remain
available in ordinary native desktop configurations without an additional opt-in,
but only explicit server steps install or run server artifacts. See
[server.md](server.md) for prerequisites.

`build/shared.zig` creates the dependency-free terrain/protocol module for each
consumer's target and optimization. Desktop creates it after macOS deployment
target normalization, importing it into both application roots and testing it
explicitly. The Wasm renderer imports its own Wasm-targeted instance; no native
server world module enters either client graph. Server tests also explicitly
run the shared tests. Client residency remains separate from server persistence.

| | Desktop | Wasm |
| --- | --- | --- |
| Build implementation | `build/desktop.zig` | `build/wasm.zig` |
| Rust package | `vendor/cdk-wallet-ffi` | `browser/wallet` |
| Rust target | `platform.zig` policy: exact native Linux gnu/musl triple or `aarch64-apple-darwin` | `wasm32-unknown-unknown` |
| Rust build cache | `vendor/cdk-wallet-ffi/target` | `browser/wallet/target` |
| Zig/raylib target | Native Linux or `aarch64-macos`, dynamic raylib | `wasm32-emscripten`, static archives linked by emcc |
| Wallet boundary | Translated C header and static archive | Async JS bindings generated by wasm-bindgen |
| Native libraries | Linux: unwind, pthread, dl, rt, util, m. macOS: System, m; the pinned raylib build adds its own frameworks. | Never linked |
| Runtime/storage | Tokio runtime, SQLite, Unix files | LocalSet/browser async executor, IndexedDB/Web Locks |
| Tools checked by normal builds | Pinned Rust host compiler/target against Zig's host OS/arch; desktop also checks the native C compiler/linker; macOS runs an arm64/OS/SDK/clang preflight | Pinned Rust + Wasm target, local wasm-bindgen, Emscripten |
| Tools installed by `setup` | Missing selected Rust toolchain/target; desktop validates native prerequisites | Missing selected Rust + Wasm target, wasm-bindgen and Emscripten |
| Deployment target | Linux host ABI; fixed macOS 15.0 | Emscripten/browser defaults |

The shared wallet-policy and cryptographic **source** is deliberately reused;
compiled artifacts and platform dependencies are not. A normal browser build
does not compile the native wallet crate, native tests, or desktop executable.
A normal desktop build does not construct browser tools or compile the browser
wallet. Browser **tests** explicitly need a native fake-mint executable;
that helper has its own `browser/wallet/target/test-mint` cache and is never linked
into or shipped with the browser bundle.

Production browser artifacts install under `zig-out/wasm`; fixture artifacts use
the separate `zig-out/wasm-test` graph and output. Browser `test` and `test-mint`
use the fixture, including ReleaseSafe tests. Its `local-mint-fixture` policy
permits only a same-origin root loopback mint, so tests do not contact the public
mint. On macOS the fixture build and Node/host tests passed; the Chromium suite
was not run there. Historical browser results below predate v2 onboarding and
do not establish end-to-end verification of the new flow.

Desktop support is native Linux (x86_64/aarch64) and native **Apple Silicon**
macOS (arm64). A foreign desktop target, macOS Intel and universal binaries are
rejected rather than silently linking a host Rust archive into them. The macOS
preflight also verifies native arm64 execution, the running macOS version, Xcode
Command Line Tools, SDKROOT consistency and a usable SDK/clang. The browser target
is explicitly wasm32-emscripten; conflicting platform/target options fail during
configuration.

## Native target matrix

One shared resolver (`build/platform.zig`) validates Zig's detected host and the
resolved target, then returns the Rust target triple, Zig target, native library
set and rpath that the desktop and server graphs consume. Validation happens before preflight,
Rust tool checks or compilation.

| Host / target | Result |
| --- | --- |
| Linux x86_64 or aarch64, exact glibc ABI (`gnu`) | Accepted; Rust `<arch>-unknown-linux-gnu` |
| Linux x86_64 or aarch64, exact musl ABI | Accepted; Rust `<arch>-unknown-linux-musl`; requires a musl-capable C compiler. If the selected Rust compiler host triple is different (for example GNU), an explicit effective `CC`-family setting is required; runtime remains unverified on this Linux/glibc checkout |
| Apple Silicon macOS 15.0+ (`aarch64-macos`, native ABI) | Accepted; Rust `aarch64-apple-darwin`, deployment target 15.0 |
| Any foreign OS/architecture/ABI, including macOS Intel | Rejected as unsupported cross-compilation |
| macOS deployment target below 15.0 | Rejected |
| `wasm32`/`wasm64` target without `-Dplatform=wasm` | Rejected with `WasmRequiresPlatform` |
| `-Dplatform=wasm -Dtarget` other than `wasm32-emscripten` | Rejected with `UnsupportedBrowserTarget` |

A non-musl Linux ABI is never silently treated as GNU. Same-architecture CPU
feature selection with `-Dcpu` remains allowed; it does not broaden the supported
OS/architecture/ABI matrix.

## Explicit setup vs checked builds

Install the host prerequisites once: **Zig 0.17.0**, **Python 3**, and **Rustup**
with its Cargo shim on `PATH`, plus a working native C linker and Clang/LLVM for
Rust dependencies that compile C code. Linux desktop additionally needs the
normal raylib/X11/OpenGL development libraries and libunwind. A musl Linux build
also needs a musl-capable C compiler; if the selected rustc host triple differs
from the musl output target, set the effective CC-family variable explicitly as
described below. macOS desktop requires a native arm64 shell on macOS 15.0 or
newer, Xcode Command Line Tools and the macOS SDK. Browser tests require
**Node 22+** and **Chromium** (`CHROMIUM=/path/to/browser` is supported). The
build never uses sudo or attempts to install OS packages or the browser.

Wallet UI tests do not verify rendered pixels, QR decoding or OCR. Native tests
retain QR encoding unit checks; `test-qr-portability` checks C compilation only,
not rendering or ARM64 runtime behavior. Production QR quiet-zone behavior is
described in [menu.md](menu.md).

Provision the selected platform explicitly, once:

```sh
zig build setup                  # desktop
zig build setup -Dplatform=wasm  # browser
```

`setup` is the **only** path that may install or update a missing Rust
toolchain/target, wasm-bindgen CLI or Emscripten. It does not compile the
application. `zig build setup -Doffline` performs the same checks without
installing anything and fails with the exact missing item. Zig/Python/Rustup
themselves are external prerequisites; `setup` is configurable and runnable while
Rust or the browser SDK is still absent.

Every ordinary build, `run`, `wallet`, `renderer`, `header-check` and test step
only **checks** its required installed tools before compiling. It never installs
or updates a Rust toolchain, Rust target, wasm-bindgen CLI or Emscripten. A
missing or incompatible item fails immediately with the correct command:

| Missing tool in a normal build | Remediation |
| --- | --- |
| Desktop Rust toolchain/target | `zig build setup` (`-Drust-toolchain=...` is appended when a non-default toolchain was selected) |
| Native C compiler/toolchain | Externally installed OS prerequisite; `zig build setup` only validates the selected compiler and never installs OS packages |
| Wasm Rust toolchain/target or wasm-bindgen | `zig build setup -Dplatform=wasm` (`-Drust-toolchain=...` is appended for a non-default toolchain) |
| Emscripten SDK | `zig build setup -Dplatform=wasm` |

With a non-default `-Drust-toolchain=...`, the printed setup hint preserves the
platform flag and appends the selected override, for example
`zig build setup -Drust-toolchain=nightly` or
`zig build setup -Dplatform=wasm -Drust-toolchain=nightly`.

Normal checks validate:

1. Rust **1.99.0** is installed for the explicitly selected (`-Drust-toolchain`)
   toolchain, and the selected target is installed. `setup` adds only the
   missing minimal toolchain/target; no global default Rust toolchain changes.
2. The selected compiler is inspected with `rustc -vV`. Its host OS/architecture
   must match Zig's detected host; a foreign or Rosetta compiler is rejected.
   Host ABI and output ABI are deliberately compared separately (a GNU-hosted
   compiler may build a musl target when that target is installed).
3. For desktop, the native compiler is resolved exactly as the pinned **cc-rs
   1.11.0** does: most-specific `CC_<target>`, `CC_<target_with_underscores>`,
   `HOST_CC`/`TARGET_CC`, then `CC`. The `HOST`/`TARGET` kind is derived from
   the selected Rust compiler host versus the output Rust target. For a native
   build where those triples match and no CC-family variable is set, validate
   cc-rs' actual default `cc`; gcc/clang are never substituted silently. If the
   Rust compiler host differs from the output target (for example a GNU-hosted
   rustc building a musl target), cc-rs would choose a prefixed target compiler,
   not `cc`; this build requires an explicit effective CC-family setting and
   fails early with an actionable error otherwise. Known cc-rs wrappers are
   accepted, but the underlying compiler and its arguments are still validated
   as argv (no shell). An explicit `CARGO_TARGET_*_LINKER` must be a single
   program name or path (including a real wrapper script), not a command string;
   extra linker arguments belong in `RUSTFLAGS` (for example
   `-C link-arg=-fuse-ld=lld`). The macOS preflight is part of this check and
   also gates the setup step.
4. For Wasm, `wasm32-unknown-unknown` must be installed. A normal browser build
   does not require the native desktop C-toolchain/X11 checks.
5. For Wasm, wasm-bindgen CLI **0.2.130** must already exist under
   `.zig-cache/tools/wasm-bindgen-0.2.130` (or pass a validated
   `-Dwasm-bindgen=...` override). `setup` installs it with a locked Cargo
   command, never into `~/.cargo/bin`.
6. For Wasm, Emscripten **4.0.19** is checked before raylib/renderer
   compilation. `setup` installs/activates it once; subsequent setup runs and
   all normal builds only run `emcc --version` and never `emsdk update`.

Cargo is invoked as `rustup run <toolchain> cargo`, not `cargo +<toolchain>`.
The `+toolchain` shorthand is equivalent to `rustup run --install`, so it could
implicitly install a missing toolchain after the check. `rustup run` is
non-installing and pins the nested rustc/rustdoc invocations through
`RUSTUP_TOOLCHAIN`; the build also sets `RUSTUP_AUTO_INSTALL=0`. No global default
Rust toolchain is changed.

The pinned upstream raylib build attaches an unconditional `Activate EMSDK` step
that runs `emsdk update`/`install`/`activate`. `build/emsdk_compat.zig` removes
exactly that step and fails configuration if the pinned upstream graph no longer
has exactly one such step. The browser graph then attaches the pinned
check/provision step above; no upstream installer is reachable from the normal
renderer or wallet graph. The native desktop graph never constructs the
Emscripten dependency.

The small scripts in `build-support/` handle check/provision modes, explicit
regressions and the test-server lifecycle. `--check` is used by normal builds and can never fall
through to an installer; `--provision` is used only by `setup` and still reuses
an already matching tool without updating it. Zig owns the Rust build, generated
bindings, renderer compilation/linking, dependency ordering, caching and
installation directly. Cargo still owns its dependency/incremental cache and is
invoked each build so edits to the shared Rust sources cannot leave Zig linking
a stale archive. The wasm-bindgen output is a generated Zig build artifact and is
cached when the Rust `.wasm` and tool are unchanged. Static assets have their own
install steps.

## Source-package regression

After `zig build setup -Dplatform=wasm` and an ordinary complete browser build
have warmed Zig/Cargo dependency caches, run:

```sh
zig build test-package -Dplatform=wasm -Doffline
```

This is a source `.paths` filter check, **not** signed desktop packaging, an
asset-pack check or a graphical desktop test. It is available in either graph,
but never runs automatically from a normal build or `test-build`. Its script is
deliberately not named `test_*.py`: packaged unittest discovery cannot recurse
into another complete package build. Small fixture tests do exercise real Zig
filtering, including a deliberately omitted onboarding bridge.

Zig 0.17's local-directory fetch copies everything before filtering, so the
checker first writes a temporary tar of the **current working tree**, including
uncommitted/untracked sources and any genuine assets. A fixed exclusion list,
independent of `.paths`, prunes Git metadata, Cargo targets, tool/build caches,
local repros, profiles, logs, wallet databases and common secret files. It rejects
remaining symlinks/special files rather than dereferencing external inputs. This
preprocessing is not the package filter: actual `zig fetch` applies `.paths` to
that tar in an isolated global package cache. The resulting `p/<hash>.tar.gz` is
checked for required runtime/test/document inputs and forbidden artifacts before
extraction into a disposable writable workspace. No original source directory
is linked back into that workspace. The checker queries native and Wasm help,
runs `test-build`, Node-only Wasm `test-storage`, and builds the **production**
`browser` step there. It never runs a mint or installs tools.

Prerequisites are Node, the selected Rust toolchain/Wasm target (default pinned
1.99.0; `-Drust-toolchain` is forwarded), warmed Cargo registry/Git dependencies,
and the provisioned Emscripten SDK in the existing `zig-pkg` dependency cache
(`ZIG_LOCAL_PKG_DIR` is honored). Builds reuse that cache with Zig's `--system`
no-fetch mode and Cargo offline mode. Managed wasm-bindgen 0.2.130 must exist in
the invoking build's local cache; the checker forwards its absolute binary path
instead of packaging it. The check assumes the managed CLI, not a custom
`-Dwasm-bindgen` override. Only compiler-cache directories (`b/h/o/z`), never the
global package cache (`p`), are shared with the isolated fetch. No shared package
cache is modified to repair missing source inputs.

Temporary tar/fetch/workspace data is cleaned on success or failure, under
`/tmp/opencode` when available (system temporary directory otherwise). Commands
have finite timeouts and identify failing stages. A fresh Rust compilation in
the disposable workspace can take several minutes and multiple GiB of disk;
compiled checkout targets are intentionally neither copied nor packaged.

## macOS Apple Silicon desktop

macOS desktop support is native Apple Silicon (`aarch64-apple-darwin`) only.
Intel Macs, Rosetta/x86_64 shells, universal binaries, signing, packaging, `.app`
bundles and DMGs are out of scope.

Prerequisites (the build never runs sudo or installs system packages):

```sh
xcode-select --install                 # only if Command Line Tools are missing
xcode-select -p                        # verify the active developer directory
xcrun --sdk macosx --show-sdk-path     # verify the macOS SDK
xcrun --sdk macosx --show-sdk-version
sw_vers -productVersion                # must be 15.0 or newer
uname -m                               # must print arm64
```

If Command Line Tools are installed but not selected, point `xcode-select` at
`/Library/Developer/CommandLineTools` (or an Xcode installation) manually. The
desktop graph runs `build-support/macos-preflight.py` before any Rust or C
compilation. It validates the running macOS version, native arm64 execution, the
selected developer directory, the SDK, and that the SDK clang actually runs. It
never installs anything or invokes sudo. The preflight is not part of the Wasm
graph.

If `SDKROOT` is set, it must resolve to the same SDK that
`xcrun --sdk macosx --show-sdk-path` selects; a nonexistent or conflicting
`SDKROOT` is rejected rather than validating one SDK while Rust/clang compiles
against another. The preflight also resolves the same cc-rs 1.11.0 compiler
precedence for the native `aarch64-apple-darwin` host/target. The selected
CC-family compiler must resolve to the clang selected by xcrun (known wrappers
are accepted, but their underlying compiler is checked; Apple's `/usr/bin/cc`
and `/usr/bin/clang` xcrun shims are accepted when xcrun reports an Xcode
toolchain path). Effective `CFLAGS`
forms (`CFLAGS`, `HOST_CFLAGS`/`TARGET_CFLAGS`,
`CFLAGS_aarch64_apple_darwin`, `CFLAGS_aarch64-apple-darwin`) and CC compiler
arguments are scanned for
`-isysroot PATH`, `-isysrootPATH`, `--sysroot PATH` and `--sysroot=PATH`.
Matching canonical SDK paths are accepted; conflicting paths between settings,
multiple distinct SDKs, relative paths and missing/empty values are rejected
clearly. Unset these overrides to use the validated default SDK.

The desktop graph pins **macOS 15.0** as the deployment target:

- Rust receives `MACOSX_DEPLOYMENT_TARGET=15.0` and uses
  `aarch64-apple-darwin`. Rust's Tier 1 target starts at macOS 11, but this
  project deliberately requires 15.0: `F_OFD_SETLK` is public in macOS 14+ SDK
  headers (verified in `xnu-10002.1.13`), and 15.0 is the oldest OS the CI
  runner can exercise. macOS 11-14 support is neither claimed nor tested.
- Zig applies the same minimum to the application and to raylib's C/Objective-C
  sources through the resolved `aarch64-macos.15.0` target.
- The emitted executable and `libraylib.dylib` are expected to record
  `minos 15.0`. This is a build target, not a claim that every macOS 15 API path
  has been exercised; macOS execution still needs real hardware/CI validation.

raylib is built as a shared `libraylib.dylib` in `zig-out/desktop/lib` (or the
selected prefix). Its install name is `@rpath/libraylib.dylib`; the executable
uses the single relative rpath `@loader_path/../lib` and no build-cache rpath,
so the installed `desktop` tree is relocatable. The pinned raylib build
(`raylib` 6.x as fetched by `raylib_zig`) still unconditionally calls
`linkMacOS`, which adds the `Frameworks`, `include` and `lib` paths from its
pinned lazy `xcode_frameworks` dependency. Those are upstream cross-compilation
stubs, not the locally installed Xcode SDK; this project does not claim they are
byte-identical to it or compare their versions. The native preflight validates
the actual local SDK/clang used by Rust and Cargo's C dependencies, and rejects
a conflicting `SDKROOT`/`CC`, so the validated native compiler and SDK are the
ones the C dependencies use. Zig links the raylib frameworks (Foundation,
CoreServices, CoreGraphics, AppKit, IOKit, QuartzCore) through raylib's pinned
link settings; the Rust staticlib adds `System` and `m` and keeps
`panic = "unwind"`. Do not add Linux-only `rt`, `util`, `dl` or `pthread` on
macOS.

This remains a source-only policy on this Linux checkout: the pinned stub
content is fetched only for macOS builds, so its compatibility with a particular
local SDK is validated by the macOS CI/hardware run, not asserted here. If the
stubs ever conflict with the native SDK, the correct fix is to update/override
the pinned raylib dependency rather than silently mixing framework sources.

The macOS path is **implemented but not yet executed here**: this checkout is on
Linux, so the macOS build, Xcode/SDK preflight and Mach-O checks are covered by
source/unit contracts and a macOS CI job only. A graphical desktop smoke test
(opening a window, rendering and closing it) remains a manual macOS step; CI does
not pretend to automate it.

## Options and offline builds

```sh
zig build -Dplatform=wasm -Doptimize=ReleaseSafe
zig build -Dplatform=wasm --prefix /path/to/output
zig build -Dplatform=wasm -Doffline
zig build -Doffline
```

Outputs remain separated under `<prefix>/desktop`, `<prefix>/wasm` and the test
fixture's `<prefix>/wasm-test`.
Changing the install prefix does not force a second renderer build or copy a
whole nested build directory into the result. Old `zig-out/bin`, `zig-out/browser`
and `zig-out/web` products from the previous build layout are not deleted.

The desktop graph installs the checkout-level `assets` directory into
`<prefix>/desktop/bin/assets`, next to the executable. That directory is
deliberately gitignored and is not part of a clean checkout; a local desktop
install therefore requires the asset source directory to exist. A missing
`assets` directory fails the install step rather than silently skipping the
assets. The current renderer loads no external assets, so local builds may use an
empty `assets` directory; a real asset pack is optional, local-only content. The
CI desktop jobs create an empty `assets` fixture before their first desktop
install. That fixture only exercises the existing install and relocation
packaging path: it is not a real asset pack, does not validate asset loading or
production content, and CI never fetches or downloads assets. The browser
renderer currently loads no assets; assets are not installed into the Wasm
bundle.

Default optimization is **Debug for desktop**, **ReleaseSmall for Wasm**.
An unqualified `--release` selects ReleaseSafe on desktop and ReleaseSmall on Wasm.
`-Doptimize=Debug` uses Cargo's debug profile; the release modes use Cargo release
with matching opt-level (`2`, `3`, `s` for safe/fast/small). ReleaseSafe enables
Rust overflow checks. The native panic strategy remains unwind; browser panic
limitations remain documented in [browser-wallet.md](browser-wallet.md).

`-Doffline` on a normal build keeps its check-only behavior and adds
`--offline --locked` to Cargo. Missing tools fail with the setup command instead
of fetching silently; normal builds never install a project tool, whether or not
`-Doffline` is set. `zig build setup -Doffline` is a pure check: it reuses
matching installed tools and fails if anything must be downloaded. Run the
online setup first, then build normally or with `-Doffline`.

Tool provisioning and dependency fetching are separate concerns: `-Doffline`
does not override Zig's package-fetch controls, and a normal `-Doffline` build
still requires the pinned Zig dependencies (and on macOS the pinned raylib
`xcode_frameworks` lazy dependency) to be cached already. Use Zig's own
dependency-fetch controls when prepopulating a fully offline machine.
Cargo's `--offline` likewise governs Cargo dependency resolution, not tool
installation. A plain online build or `zig build setup` is the normal way to
populate those caches.

Optional advanced overrides:

- `-Drust-toolchain=...` changes the explicitly selected Rustup toolchain.
- `-Dwasm-bindgen=/path/to/wasm-bindgen` bypasses the local install **only** after
  validating version 0.2.130; this option is not part of the desktop graph.
- `-Dport=9000` changes the plain browser development-server port.
- `BROWSER_TEST_PORT=0 zig build test-mint -Dplatform=wasm` allocates an available
  fake-mint port. Automated browser tests always choose their own ephemeral port.

Normal `run -Dplatform=wasm` only serves static assets; it never starts a fake
mint or creates funds. Fake mint behavior is explicit and test-only.

## Dependency provenance: CDK `v0.18.1` and Spilman `v0.2.0`

Both Cargo roots — `vendor/cdk-wallet-ffi` (native C ABI) and `browser/wallet`
(Wasm) — declare the same direct CDK packages as Git dependencies, not registry
versions:

| Package | Source | Selector |
| --- | --- | --- |
| `cdk`, `cdk-common`, `cdk-sqlite`, `cashu` (transitive) | `https://github.com/cashubtc/cdk.git` | tag `v0.18.1` → commit `a056e0f0f69e94f431b1aeb90d883f18c61ea4c6` |
| `cdk-axum`, `cdk-fake-wallet` (native dev/test only) | same | same tag and commit |
| `cdk-spilman` | `https://github.com/SatsAndSports/cashu_spilman_channels` | rev `8a5350dfd4d7c2902dc15c726a91dbfb2c793d43` (release `v0.2.0`) |

Each direct CDK dependency also carries `version = "=0.18.1"` as a version guard.
The lockfiles and provenance check additionally guard the source and commit,
including a moved tag that still reports the same version. Identity is checked by **source URL, selector and resolved
commit**, not by version string alone: a registry copy that happened to report
`0.18.1` would still be rejected. There is no Cargo workspace merge, no
`[patch]` section, no fork and no local crate copy: `vendor/cdk-spilman` was
removed once the upstream Git dependency compiled and the equivalence tests
passed.

Verify the resolved graph explicitly, after provisioning tools:

```sh
python3 build-support/check_dependency_pins.py              # add --offline to forbid Cargo network access
```

The checker runs `rustup run 1.99.0 cargo metadata --locked --format-version 1
--all-features --filter-platform …` for both manifests (host triple for the native
graph; both `wasm32-unknown-unknown` and the host triple for the browser graph).
This includes dev/test dependencies and the browser's local-mint fixture feature. It
fails when a CDK/Cashu package comes from anywhere else, when a version,
selector or commit differs, when a package is resolved from two sources, when
Spilman is not the pinned rev, or when the two roots disagree about a shared
package's identity. It is a **check only**: it never provisions tools, and a
normal `zig build` never runs it. CI runs it once per job after the job's own
tool-provisioning step.

**Offline Git cache priming is separate from setup.** `zig build setup` installs
toolchains, targets, wasm-bindgen and Emscripten; it never fetches Cargo
dependencies. Publishing the pinned Git sources requires an ordinary online
`cargo fetch`/`cargo metadata` (or any normal build) in both roots to populate
`~/.cargo/git`; only then do `-Doffline` builds and the checker's `--offline`
flag work. No step installs tools implicitly.

### Why `0.18.3` → `0.18.1` (deliberate, not equivalent)

Upstream Spilman `v0.2.0` pins CDK `v0.18.1`. Rather than mix a published
Spilman crate with a registry CDK and risk two CDK resolutions across native,
browser and tests, this repository moved **all** CDK/Cashu dependencies to the
single `v0.18.1` source. This is a deliberate downgrade from the `0.18.3`
registry crates this project used before, and it is **not** a claim that the two
releases are equivalent, nor a production certification.

### Current wallet status

On **2026-11-15**, the maintainer confirmed that **no production wallets
currently exist**. There is therefore no current production-wallet migration need:
unverified funded-wallet backward compatibility is not a blocker for this
pre-production migration. The CDK `v0.18.1` pairing with upstream Spilman
`v0.2.0` is intentional, and its known risks are accepted in this current
pre-production context. This does not imply that there are no deployments or
funded test wallets; agents should not treat the lack of funded-wallet downgrade
validation as an existing production incident.

This is dated context, not a permanent waiver or a claim that missing fixes are
resolved. Known transaction/recovery bugs remain, the documented send/swap
recovery test failures remain failures, and use is still **test funds only**.
Before allowing production funds, revisit the dependency fixes, recovery
validation and wallet-data upgrade policy. The source-review findings and
empty-wallet evidence below retain their original limits.

Source review of upstream `v0.18.1…v0.18.3` for the paths this ABI uses:

- all 168 SQL migration files (62 wallet, 79 mint, 7 mint-auth, 20 supabase) are
  byte-identical, so the stored schema is unchanged;
- `wallet/send`, `wallet/receive`, `wallet/swap` and `wallet/saga` are
  unchanged;
- the wallet files that do differ are `wallet/issue`, `wallet/melt`,
  `npubcash`, `wallet_trait` and `test_utils`, plus SQL transaction
  cleanup/pool and in-memory database handling outside the wallet module.
  Even when this ABI does not call a changed wallet operation directly, shared
  database transaction cleanup can affect the operations it does call.

Relevant fixes that are therefore **not** included, and their scope:

- `f1cbc3031fb1e80309091f17f9e6926e1d2737f1` — hardens SQL transaction cleanup
  (`sqlx`/`rusqlite` transaction helpers). This ABI's own writes go through its
  wrapper and upstream saga code; the fix still concerns transaction teardown,
  so its absence is a real (if narrow) difference.
- `c64d253e54ecf5bba9e6aba09924fb656c51ef2e` — fail on a lost in-memory database.
- `322fe0b09c8c634497ef3fdf3c41b69830105cfd` — recover mint quote signing
  keys from the seed. Not used by this small ABI.

This adapter is not the upstream `cdk-ffi` crate: it has its own panic/poison
guard, so upstream `cdk-ffi`-only fixes are not evidence about this wrapper
either way.

Schema-level evidence is limited to a disposable fixture: a pristine, empty
0.18.3 SQLite wallet produced by the wrapper (dummy seed, 40 migrations, 36-byte
wrapper marker, no funds and no mints) was reopened through a copy under 0.18.1.
That proves the empty, unfunded schema reopens; it does **not** prove a funded
wallet or full history compatibility. Treat any funded test wallets and future
production wallets conservatively: back up the wallet directory before
switching builds, and remember this is an experimental, test-funds-only wallet. See
[browser-wallet.md](browser-wallet.md#boundaries-and-remaining-validation) for
the browser-side limits.

## Verification

### Dependency migration validation (2026-11-15, Linux x86_64)

With Zig 0.17.0 and pinned Rust 1.99.0, using warmed caches and `-Doffline`:

- Dependency guard: **36 unit tests passed**; real locked, all-feature metadata
  passed for native, browser Wasm and browser host/dev/fixture graphs.
- `zig build test-build -Doffline`: **180 Python tests passed** and both Zig
  graph-contract test artifacts succeeded.
- Native Cargo check and browser Wasm Cargo check (including the local-mint
  fixture feature) passed. Native Rust suites passed **74 tests**, up from the
  pre-migration baseline of 69, in both Debug and ReleaseSafe.
- Native `header-check`, `test-spilman`, `test-wallet` and application `test`
  passed; the native Zig suites reported **193 passed, 2 skipped**, also in
  ReleaseSafe. The checked-in header and Spilman JSON vectors are unchanged.
- Desktop and production Wasm bundles built in both default and ReleaseSafe
  profiles. Browser host tests passed **62 database tests plus 1 mint-policy
  test** in both invocations (the existing browser graph runs these host tests
  in Cargo's unoptimized test profile). Default and ReleaseSafe browser integration each
  reproduced **237 passing checks and only the same 3 documented send/swap
  recovery failures**; each command exited **1**, not success, with no uncaught
  exceptions or cleanup failure. Both ran all 59 onboarding checks and 8 negative
  regression cases successfully. The separate current Node storage run passed
  23 game-storage, 36 wallet-storage, 10 IndexedDB fixture and 15 CDP-helper
  checks, plus onboarding transport/input tests; concurrent browser hardening
  work was preserved rather than included in the migration implementation.
- The disposable 0.18.3 empty-wallet copy reopened under 0.18.1 with unchanged
  schema, applied migrations, marker and logical row counts; the pristine
  snapshot hash remained unchanged. This is not funded-wallet certification.

Logs: `/tmp/opencode/spilman-completion-20261115-logs`; earlier downgrade-probe
logs: `/tmp/opencode/spilman-migration-20261115-143423/logs/22…24-*`.
macOS ARM verification remains CI-only; it was not run on this Linux host.

### Historical build-tooling checks

Historical checks before the 2026-11-15 dependency migration, on this Linux
machine (Zig 0.17.0, Rust 1.99.0); these counts are not post-migration results:

- `zig build test-build`: **141** Python setup/check/graph-isolation/CI-workflow
  tests and **15** Zig tests (11 native-platform-matrix plus 4 upstream Emscripten
  adapter tests) passed. Coverage includes installed/missing/partial Rust
  toolchain+target states, wasm-bindgen and Emscripten check/provision/offline
  modes, exact `emcc` banner-version parsing (rejecting `4.0.190`, `4.0.19x` and
  arbitrary text), installer-call assertions, the synthetic GNU/musl/
  Apple-Silicon/Intel/foreign-host cases, Rust compiler host validation, cc-rs
  target-specific compiler precedence, cross-host explicit-CC requirements,
  literal linker-program validation, wrapper/argument validation, target-specific
  CFLAGS/SDK override checks, macOS running-version/SDKROOT/clang preflight
  contracts, and normal-build failures for a misspelled toolchain that point at
  the correct setup command (including the selected `-Drust-toolchain` override)
  without installing it.
- `zig build setup` and `zig build setup -Dplatform=wasm` succeeded with already
  installed tools; repeated runs reused the toolchain/target, local
  wasm-bindgen and Emscripten without updates. `setup -Doffline` succeeded as a
  pure check for both platforms.
- `zig build test-wallet -Doffline`: **60** Rust tests, **26** Zig C-ABI tests and
  the header freshness check passed. `-Doptimize=ReleaseSafe -Doffline` reran the
  same suites with `cargo test --release` and
  `CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS=true`; verbose output showed
  `rustup run 1.99.0 cargo ...`, never `cargo +1.99.0`.
- `zig build -Doffline --prefix <fresh>` and
  `zig build -Doptimize=ReleaseSafe -Doffline --prefix <fresh>` installed desktop
  binaries whose only RUNPATH is `$ORIGIN/../lib`; `ldd` resolved the adjacent
  `desktop/lib/libraylib.so` rather than a build-cache copy.
- A warmed-cache `zig build -Doffline --prefix <fresh>` produced a relocatable
  `desktop` tree; after copying it outside the repository, `ldd` still resolved
  the adjacent raylib.
- `zig build -Dplatform=wasm -Doffline --prefix <fresh>` produced only the Wasm
  bundle; cached renderer/bindings steps were reused and the build summary showed
  only `check Emscripten 4.0.19`, not an upstream `Activate EMSDK` step.
- `zig build renderer -Dplatform=wasm -Doffline --prefix <fresh>` succeeded with
  only the Emscripten check; it did not require Rust, wasm-bindgen or the wallet.
- `zig build test-wallet -Dplatform=wasm -Doffline`: **55** browser database
  tests passed.
- `zig build test -Dplatform=wasm -Doffline` reproduced the known CDK recovery
  defects: **220** checks ran and **3** failed (dropped send after mint commit
  restored 130 instead of 96 sats; send interrupted before request reported a
  failed mint; send interrupted after mint commit restored 130 instead of 96).
  The command exits nonzero as intended, and the fake mint's ephemeral port was
  closed afterwards. These failures are not masked.
- Conflicting native/Wasm and macOS Intel target selections failed during
  configuration, before any application compilation. `zig build
  -Dtarget=wasm32-emscripten` (and `wasm64`/WASI variants) now fails with
  `WasmRequiresPlatform`; `-Dplatform=wasm -Dtarget=wasm32-emscripten` still
  completes configuration. No tool provisioning or network access occurs for
  those rejected configurations.

The macOS-only extended-ACL regression tests are compiled and run only by the
macOS CI job; they were **not** executed on this Linux machine.

Earlier runs also exercised Debug browser builds with `-Doffline` and a fresh
prefix, and cache hits when changing the install prefix. Normal Wasm builds now
only check the managed wasm-bindgen and Rust Wasm target; the explicit
`zig build setup -Dplatform=wasm` path provisions them.

**macOS status:** the Apple Silicon desktop path, preflight, deployment target,
Mach-O install-name/rpath design and CI job are implemented, but the macOS build
and runtime were **not** executed in this Linux environment. A real macOS CI run
and the manual graphical smoke test remain outstanding; nothing in this document
claims otherwise.

## Continuous integration

`.github/workflows/ci.yml` runs three independent jobs. Both desktop jobs create
an empty `assets/` fixture before their first desktop install: the checkout-level
asset directory is gitignored, the current renderer loads no external assets, and
the empty fixture only exercises the existing install/relocation packaging path.
It is not a real asset pack, is not validation of asset loading and is never
fetched or downloaded.

- **Linux desktop**: installs the pinned Zig plus raylib/X11/OpenGL
  prerequisites, runs `zig build setup` to provision the selected Rust
  toolchain, then runs `test-build`, Debug and ReleaseSafe builds, and both
  `test` and `test-wallet` in **both** profiles. It checks architecture, the
  only RUNPATH (`$ORIGIN/../lib`), and `ldd` resolution for both prefixes, then
  performs a warmed-cache `-Doffline` build into a fresh prefix and rechecks the
  relocated artifact.
- **macOS Apple Silicon**: runs on the `macos-15` arm64 image, asserts
  `uname -m`/non-Rosetta, verifies Xcode CLT and the SDK, runs `zig build setup`
  (including the desktop preflight), then runs the same Debug/ReleaseSafe tests.
  It checks both prefixes for arm64 Mach-O files, the
  `@rpath/libraylib.dylib` install name, the sole `@loader_path/../lib` rpath,
  `minos 15.0`, and a relocated warmed-cache `-Doffline` build.
- **Linux browser (Wasm)**: installs Node 22 and Chrome for Testing, runs
  `zig build setup -Dplatform=wasm` to provision the Wasm toolchain, local
  wasm-bindgen and Emscripten, then runs the complete Wasm build, browser
  database tests, the offline filtered-package regression, and finally the
  fake-mint/Chromium suite (whose known failures remain failures). It is independent of both
  desktop jobs.

The workflow installs Zig 0.17.0 through `build-support/install-zig.py`, which
pins the exact Linux x86_64 and macOS arm64 tarball SHA-256 digests and refuses
unsupported versions/platforms instead of consulting the live download index.
Rust is pinned to 1.99.0 and installed by the explicit setup step rather than a
separate `rustup toolchain install`. GitHub Actions are pinned to full commit
SHAs and every checkout disables persisted credentials. The macOS graphical
smoke test is deliberately manual.
