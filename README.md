# Haystack Game

Haystack is a desktop and browser game that explores what happens when a game
can charge tiny amounts for actions and pay prizes back as **Cashu ecash**.
Players explore a shared world and use an axe, a hoe, or a pickaxe to clear
terrain. The client sends what the player wants to do; the server decides what
happens and sends back the result.

**Experimental: use test funds and disposable recovery phrases only.** The game
server runs locally by default; the browser client is not configured for a
remote deployment.

## How a paid action works

1. **Fund a tool.** After setting up a wallet, the player funds a Spilman payment
   channel for the tool. Prices are in millisatoshis (`msat`): an axe costs 2,
   a hoe 4, and a pickaxe 8 per use. One satoshi is 1,000 msat.
2. **Send an action.** The client sends the tool, target tile, and a signed update
   to the channel's running payment total. Funding and settlement involve the
   mint, but each tool use doesn't need its own mint transaction. Movement and
   requests for nearby tiles don't use the payment channel.
3. **Apply the change.** The server checks the action and the payment. If it
   accepts both, it clears the tile and sends back the updated state.
4. **Pay a prize.** Some successful paid actions win a prize. If the server's
   own wallet can pay it, the server returns a regular Cashu bearer token that
   the client imports into the player's wallet. A prize is not channel credit.
   If the server can't issue the token, it records what it owes instead.

Both clients use the **same binary wire protocol over WebSockets** for
movement, world updates, paid actions, channel messages, and prizes. The format
is TLV (type, length, value), defined by [`shared/protocol.zig`](shared/protocol.zig)
and [`shared/wire.zig`](shared/wire.zig). It's Haystack's own protocol, not a
Cashu or Spilman standard. WebSockets carry the messages; Spilman channels
handle the payments.

## Stack and bindings

| Layer | Tools |
| --- | --- |
| Game and server | **Zig** for gameplay, rendering code, the server, and the shared wire protocol. **raylib** for graphics and audio; **SQLite** for server persistence. |
| Wallet and payments | **Rust** and the **Cashu Development Kit (CDK v0.18.1)** for wallet and mint operations, with **Spilman channels (v0.2.0)** for pay-per-use tools. |
| Desktop and server bindings | [`vendor/cdk-wallet-ffi`](vendor/cdk-wallet-ffi/README.md) uses **SaferFFI** to expose Rust wallet and channel functions through a C interface. Zig consumes the generated C header. Native wallets use SQLite. |
| Browser bindings | **Emscripten** builds the Zig/raylib game for WebAssembly. The separate Rust wallet in [`browser/wallet`](browser/wallet/Cargo.toml) exposes CDK and Spilman through **wasm-bindgen** and JavaScript, and stores wallet data in **IndexedDB**. It doesn't load the native SaferFFI library. |
| Build and test tools | `zig build` coordinates the builds, **Cargo/Rustup** handle Rust, and **Python** supports setup and local serving. Browser tests use **Node.js and Chromium**. |

The two wallet bindings let desktop and browser use the same Cashu and Spilman
libraries and talk to the same server without requiring the same runtime.

## Run locally

Install Zig 0.17.0, Python 3, Rustup/Cargo, and a native C toolchain. See the
[build guide](docs/build.md) for Linux system libraries and macOS Apple Silicon
requirements. Run commands from the repository root.

```sh
zig build setup                  # once for the native server and desktop client
zig build setup -Dplatform=wasm  # also run this once if playing in a browser
zig build run-server -Dgame=false # leave running in its own terminal
```

In another terminal, choose a client:

```sh
zig build run                   # desktop
zig build run -Dplatform=wasm    # browser: open http://127.0.0.1:8000/
```

Both clients connect to `ws://127.0.0.1:9224/` after wallet onboarding. Open
**Tools** to fund a channel and see how many uses remain. To try prize payouts,
follow the [server wallet stocking guide](docs/server.md#paid-cut-prizes-test-funds-only).

## More details

- [Builds, tool setup, and tests](docs/build.md)
- [Server, wire format, and channel messages](docs/server.md)
- [Native CDK C interface](docs/cdk-wallet-ffi.md) and [browser wallet](docs/browser-wallet.md)
- [Optional soundtrack and asset credits](assets/music/CREDITS.md)
