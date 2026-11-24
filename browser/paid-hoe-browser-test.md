# Chromium + native paid-tool integration test (Linux)

The default scenario drives the production Wasm wallet and game signer over
Chromium's real WebSocket to the native game server, without the canvas or Zig
browser client. `--renderer-only` and `--renderer-funding-resume` drive the
actual game canvas after bootstrapping with the direct wallet and socket. All
scenarios use the repository's loopback mint as their only fake service.

It authenticates a real player and updates only that player row while the
server is offline to avoid random spawn. Both fixture grass tiles, `(0,1)` and
`(1,0)`, are within reach of `(0,0)`. The test then verifies:

1. A 10-msat deposit funds a two-cut channel. The quote neither swaps nor
   debits, and consent submits exactly one browser mint swap. A separate
   5-msat deposit is issued after funding and kept for a replacement channel.
2. The native server accepts the first cut, but the test does not resolve it
   in the wallet. After a Chromium reload and new socket authentication, the
   local accepted amount is still 0 msat and the pending cut blocks another
   payment. A bind at 10 msat is rejected; binding the exact 5 msat reported
   by native channel status succeeds and persists. The cut tile remains cut,
   with no additional cut frame, mint swap or wallet debit during recovery.
3. A duplicate cut is rejected without a charge. Cutting the second grass
   tile brings the first channel to 10/10 msat (depleted). The test sends
   close once and reads native status until it reports settled. With no sender
   change due, wallet finalization releases the slot without credit or a
   browser swap. The reserved 5 msat then funds and admits a distinct channel
   at 0/5 msat. There are exactly two browser mint swaps overall.

## Axe and pickaxe (`--tools`)

This mode uses the production browser wallet's `tool_request` API and a real
Chromium WebSocket to the native server. The offline player position `(80,11)`
(grass), tree `(80,10)`, and rock `(80,12)` were selected by sampling terrain v2
with `sampleTile(public_seed, x, y)` from `shared/world.zig`. Both targets are
cardinal neighbors in chunk `(5,0)`.

- Fetch native terms and quote one use each at 2 msat (axe) and 10 msat
  (pickaxe), with no swap or debit until consent. Separate exact deposits fund
  two distinct channels; each open and successful cut carries its tool TLV.
  The wallet shares a whole-second funding timestamp across tools, so the
  fixture waits for the next second before funding the pickaxe.
- Send a valid pickaxe payment to the tree with the pickaxe tool, then send a
  pickaxe payment to the tree with the axe tool. Both fail; wallet journals,
  native channel status, and the area bitmap confirm neither charged nor cut.
- Harvest the tree with the axe, depleting only the axe channel. Move onto the
  harvested tree (blocked before harvest), then reload Chromium and authenticate
  again. Auth reports the moved position and both original tool channels with
  their independent balances. Harvest the rock using the restored active
  pickaxe binding, verify both channels are depleted, and move onto the rock
  (also blocked before harvest).
- Close and settle both depleted channels. Finalizing the axe releases its
  funding slot without touching the pickaxe journal.

The runner expects two browser swaps, two opens, and four cut frames total.
This mode covers direct wallet/socket integration, not the renderer, refunds,
or server restart after harvest.

Build the native fixture into its own prefix. Reuse `zig-out/wasm-test` if it
already has the current browser wallet with `tool_request`:

```sh
zig build server -Dapp-fixture-mint=http://127.0.0.1:18787 -Doffline \
  -p zig-out/paid-tools-check

timeout -k 15s 120s unshare --map-root-user --net sh -c 'ip link set lo up && exec node "$@"' sh \
  browser/paid-hoe-browser-test.mjs \
  vendor/cdk-wallet-ffi/target/debug/examples/browser-test-mint \
  zig-out/paid-tools-check/bin/haystack_server zig-out/wasm-test --tools
```

If the Wasm assets are stale, rebuild with the command below and pass
`zig-out/paid-tools-check/wasm-test` instead. See [Build and run](#build-and-run)
for tooling and mint setup.

```sh
zig build browser-fixture -Dplatform=wasm -Doffline -p zig-out/paid-tools-check
```

## Lost funding response (`--funding-recovery`)

After the 10-msat deposit, the test quotes a refill and consents to one raw swap.
CDP intercepts at the response stage and drops the fake mint's HTTP 200 before
Chromium delivers it to the wallet. The wallet reports recovery pending, and
the reserved inputs are no longer spendable. The test reloads the page and
calls `inspect`, which checks input state via NUT-07 (`/v1/checkstate`) and
restores the saved outputs via NUT-09 (`/v1/restore`). The recovered 10-msat
channel is opened on the native server and bound at 0 msat accepted. The test
checks for exactly one swap POST across both pages and no cut frames. It
observes HTTP status and endpoint names without reading the response body.

## Lost funding response with change (`--funding-change-recovery`)

The setup fills the wallet's small-denomination inventory so a second deposit
issues one 64-msat proof. It sets aside the smaller proofs with exact sends
that do not swap. With only the 64-msat proof spendable, the quote offers ten
cuts (`"10"`) for a maximum debit of 50 msat. CDP drops the successful swap
response. While the operation is pending, the input is reserved and no change
is spendable. After reload, `inspect` uses NUT-07 and NUT-09 to restore the
funding and change from the same swap. The test verifies that one IndexedDB
revision marks the input spent, makes the funded channel available, and credits
exactly 14 msat of unconditioned, unspent wallet proofs. It opens and binds the
50-msat channel at zero accepted, then reloads again to verify the change and
binding persist without another swap, restore, or open request. The wallet
then sends all 14 msat as an ordinary token without a fee or a new swap.

## Swap dropped before the mint (`--funding-resume`)

CDP pauses the first swap at the request stage and fails it before dispatch.
The interrupted tab is closed and a new tab opens on the same Chromium profile.
`inspect([scope])` returns `RecoveryPending` for the original operation after a
NUT-07 state check. It does not write wallet state or submit a swap. The test
reads `resume_quote([scope])`, checks the original operation ID, terms and
10-msat maximum debit, and verifies that the quote itself makes no mint recovery
request. Only then does it explicitly call
`resume([scope, operation_id, max_debit_msats])`. The wallet rechecks the input
state, submits the saved swap, and returns the quoted channel for native open
and bind at zero accepted. The test counts two browser swap attempts (one
blocked before dispatch), one successful mint swap response, one native open
frame, no restore and no cuts.

## Resume a saved refill on the canvas (`--renderer-funding-resume`)

The direct wallet bootstrap drops the first swap before dispatch as above,
then closes the interrupted tab. A new tab on the same Chromium profile loads
`/renderer/index.html`. The production renderer finds the pending operation.
A right-click on the Hoe slot opens **TOOLS**. Clicking **Review refill**
retrieves the original two-cut quote with a 10-msat maximum debit. Neither
startup inspect nor review sends a new swap POST or opens a channel. A second
click at the same position, now **+2**, fetches fresh native requirements and
resumes the saved swap. The test checks two input-state reads (inspect and resume), no restore,
one successful mint swap after the blocked attempt, one native open, and no
cuts. A readback after leaving the canvas verifies that the quoted channel is
active on the native server and durably bound in the wallet at zero accepted.

## Renderer scenario (`--renderer-only`)

The same bootstrap prepares a ready wallet with 10 msat and positions its
player offline. Chromium then loads `/renderer/index.html`, selects the axe by
clicking the hotbar, and uses `1` and `3` to select the pickaxe and hoe. It then
right-clicks the Hoe slot to open **TOOLS**, clicks for a quote, and clicks
again to consent to refill. After closing the menu it drags on grass and clicks the player's own tile, neither of which
should prepare a payment. Finally it clicks four tiles down and one tile right
and expects one 5-msat cut on the adjacent grass at `(0,1)`. The quote must not
swap before consent, and refill must use exactly one swap. The renderer uses
the unmodified production WebSocket.
The test observes wallet operation numbers and allowlisted result booleans,
never wallet proofs or signatures. After leaving the game page it checks the
saved wallet balance before re-authenticating, then verifies native channel
status and the cut tile from a real area snapshot.

## Sender-change preflight

[`hoe-settlement-browser-test.mjs`](hoe-settlement-browser-test.mjs) isolates
wallet finalization with real mint proofs. It checks that an active withdrawal
review rejects settlement without a swap or an IndexedDB write. After canceling
that review, the identical settlement credits change once and releases the slot.
This case does not exercise the native server's construction of sender proofs.

With the installed browser fixture and `browser-test-mint` executable from the
build below, use the standard runner to allocate an ephemeral mint port:

```sh
python3 build-support/run-browser-tests.py \
  --mint vendor/cdk-wallet-ffi/target/debug/examples/browser-test-mint \
  --directory zig-out/paid-hoe-check/wasm-test \
  --runner browser/hoe-settlement-browser-test.mjs
```

## Build and run

Use Node 22.13+ (`node:sqlite` and `WebSocket`), Chromium (or set `CHROMIUM`),
`unshare`, and `ip`. Linux user/network namespaces must be available. From the
repo root, with the pinned toolchains and dependencies already provisioned:

```sh
rustup run 1.99.0 cargo build --locked --offline \
  --manifest-path vendor/cdk-wallet-ffi/Cargo.toml --example browser-test-mint
zig build server -Dapp-fixture-mint=http://127.0.0.1:18787 -Doffline \
  -p zig-out/paid-hoe-check
zig build browser-fixture -Dplatform=wasm -Doffline -p zig-out/paid-hoe-check

timeout -k 15s 120s unshare --map-root-user --net sh -c 'ip link set lo up && exec node "$@"' sh \
  browser/paid-hoe-browser-test.mjs \
  vendor/cdk-wallet-ffi/target/debug/examples/browser-test-mint \
  zig-out/paid-hoe-check/bin/haystack_server zig-out/paid-hoe-check/wasm-test
```

Append one scenario flag to run it instead of the default direct wallet/socket
regression: `--funding-recovery`, `--funding-change-recovery`, `--funding-resume`,
`--renderer-funding-resume`, `--renderer-only`, `--renderer-large-refill`, or
`--tools`. The large refill renderer scenario clicks **+20**, confirms a
100-msat hoe quote, and verifies the new channel's capacity in both the
wallet and the server after one cut. `--partial-close` exercises the wallet and
wire without the Tools UI: it rejects stale close balances, verifies a late
cut cannot charge after an exact partial close, then reconnects, redeems sender
change, and funds a distinct replacement. `--renderer-top-up` exercises one
**+20** click that carries one remaining use into a 21-use channel.
`--renderer-top-up-resume` drops the page after sender credit commits, then
verifies the replacement opens without another click or credit.

The private namespace has only loopback; the fixed game and mint ports cannot
collide with host services. Do not stop a host listener to run the test. The
runner makes a fresh Chromium profile and native HOME/XDG directories and stops
only its own child processes. The entry point refuses a visible non-loopback
interface or either fixture port already in use.

The dedicated `-p` keeps the installed fixtures separate from `zig-out/wasm-test`.
These builds reuse the normal Zig and Cargo caches. If another fixture build is
already running in the checkout, let it finish before rebuilding; do not clear
shared caches. The runner serves the exact Wasm directory passed on its command
line, so rebuild into that prefix when wallet code changes.

The runner has a 100-second integration deadline plus cleanup time. On failure
it reports the stage, numeric wallet status or native wire code when available,
and counts for browser swap attempts, observed mint successes in the interrupted
funding modes, and outgoing open and cut frames. Wallet messages are shown only
when they exactly match an allowlisted constant. It does not print raw wallet
replies, exception details, request or response bodies, or child logs.

The Wasm build requires the pinned `wasm-bindgen` 0.2.130. If it is missing,
provision via `zig build setup -Dplatform=wasm` or use the build's
`-Dwasm-bindgen=/absolute/path/to/wasm-bindgen` override for that version. An
older fixture wallet without `hoe_request` cannot pass the full test. Append
`--smoke-only` to the runner invocation to check real deposit/IndexedDB, native
authentication, requirements and area transport on a pre-paid-hoe fixture that
already exports `open_game_signer`. Smoke mode does not fund or cut and reports
that distinction on success.
