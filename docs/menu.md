# Menu — modal UI and bounded text input

The native and browser game share a modal wallet UI. Production (including
Debug) selects only `https://testnut.cashu.space/`: experimental test funds only.
The generic wallet bridge remains multi-mint; the application does not refresh
old mints automatically or rewrite their quotes, proofs, or balances.

Open it with `Esc` on the keyboard or the Start button on controller 0. Opening
always shows the **Main** page with its first row selected. While the menu is
open, world movement, mouse dragging, and the `G`/`B` debug toggles are ignored.
The frame that opens or closes the menu is modal too, so the click that closes
it cannot move the world.

## Controls

| Input | Effect |
|---|---|
| `Esc` / gamepad Start | toggle the menu; opening returns to Main and selects row 0 |
| `Up` / `Left`, D-pad up/left, left stick up/left | select the previous row (wraps to the last) |
| `Down` / `Right`, D-pad down/right, left stick down/right | select the next row (wraps to the first) |
| `Enter` / keypad Enter / gamepad bottom face (A/Cross) | activate the selected row |
| mouse movement | select the row under the pointer |
| left click on a row | select and activate that row |
| left click outside every row | blur the focused field (the highlight stays) |
| printable text | append to the focused field |
| Backspace | delete the last codepoint in the focused field |

`WASD` is **not** a menu direction: typing never moves the highlight. Amounts
are validated separately as positive decimal integer millisats. Held directions step on
the first eligible 20 Hz tick and then every two executed ticks (10 steps/s),
using the same repeat allowance as the camera. `Space` types a
space; it is not a confirm key. Arrow keys, D-pad, and stick
share the vertical list: up/left mean previous, down/right mean next, and at
most one directional row step occurs per tick, across all queued records.
Opposing held requests in one sample cancel. Edges/text/drag records still route
in order, even after the direction allowance is spent. Modal WASD filtering is
done at consumption, so queued Escape followed by typing cannot navigate.

Devices poll every display frame into a bounded 64-sample queue. Overflow drops
the newest whole record, but a separate text/edge/delta-free snapshot reconciles
held releases. Adjacent unchanged quiet samples may coalesce. This is not an
unbounded lossless queue. External accepted result/content/focus replacements
invalidate stale queued input before capture; ordinary queued modal transitions
do not. Browser clipboard work retains its trusted synchronous gesture handler,
and wallet timers/results are real-time, outside the game clock.

The highlight is persistent UI state (`Menu.selected_index`), not a transient
hover: it moves only when a direction steps or the pointer actually moves onto
another row. A stationary pointer never overrides a keyboard or controller
selection, and a direction wins if both change on the same frame. Moving the
selection away from an editable field blurs it, so typing cannot land in the
field that was previously focused; the caret appears only after activation.

Pages and rows:

- **Main**: `Wallet`, `Debug Settings`, `Settings`, and `Resume` (close the menu).
  Desktop also offers `Exit Game`, which stops accepting input and runs normal
  shutdown without a confirmation screen. Shutdown waits for any in-flight
  wallet work before closing the wallet handle.
- **Settings**: `Music` checkbox and `Back to Main`. The choice is session-only
  and defaults to enabled. Playback starts only once wallet onboarding is
  complete and the server connection is ready, when the game menu and controls
  become available. The browser fetches the current track on demand and may
  require a click, tap, or Play activation before audio can start. Unchecking
  pauses playback; checking resumes it. If the soundtrack is unavailable,
  uncheck and recheck `Music` to retry.
- **Wallet**: selected-mint msat balance, `Deposit`, `Withdraw`,
  `History`, `Back to Main`.
- **Deposit**: custom positive integer millisats, presets 21000/42000/100000/500000, `Deposit`, `Back`.
- **Invoice**: cached QR, bounded invoice preview, actual quote state,
  `Copy invoice`, new `Deposit`, `Back`.
- **History**: eight saved mint/melt quotes per page, `Previous`, `Next`, `Back`.
  Rows show UTC creation time (or `Time unknown`), direction, amount/unit,
  persisted state and mint identity. Legacy mints are marked `not refreshed`;
  unknown melt owners stay unknown. Paid deposits are not completed deposits.
  Rows are selectable by pointer, keyboard, and gamepad; activation opens the saved
  deposit invoice or read-only withdrawal detail for this mint. Previous appears only with an earlier page, Next only with a later page;
  a single page shows neither.

Deposit navigation and the Deposit amount action use green text and rectangular
outlines, never filled backgrounds or pills. Withdraw uses red rectangular outlines.

**Withdraw** accepts one complete, amount-bearing Lightning BOLT11 invoice (4096
UTF-8 bytes maximum). Focus the large wrapped field to type or use Ctrl+V / Paste;
oversized or control-containing paste is refused atomically. Clear and Back erase
the draft; drafts do not survive restart. Amountless invoices, BOLT12 and scanning
are not supported. Review obtains a CDK quote and reserves funds, but does not
submit a payment. It shows amount, routing reserve, Cashu swap/input fees, expiry
and estimated total; the estimate is **not a guaranteed cap**. Only the explicit
red Withdraw action consumes the single-use prepared operation. An expired review
cannot be confirmed. Cancel, Back or closing cancels unsubmitted preparation,
including one whose reply arrives after closing. Cancellation failure warns that
funds may remain reserved and pauses conflicting work; it does not claim success.

Prepared review pauses deposit and withdrawal recovery/mutations. Once submitted,
CDK checks continue with the menu closed and after restart. A pending payment is
not declared expired merely because its deadline passed. Outgoing History opens
local CDK detail, never a new quote or payment. Review again is available only when
CDK permits it: it prefills the invoice but still requires a fresh Review click.
All displayed amounts come from CDK decimal strings; balances/history are reread
after every withdrawal mutation, including failures, not calculated by the UI.

Deposit disables duplicate requests until the persisted quote returns. Payment
checks run serially, about two seconds after the previous completion, backing
off after errors. A paid invoice must actually mint through CDK's saga before
success; the displayed balance is reread, never incremented by the requested
amount. A remote Issued response without CDK's completed local issuance is not
reported as success. Unfinished invoices survive reload, including expired paid
quotes. Opening automatically selects the newest non-expired unfinished deposit,
ordered by saved creation time (unknown is zero), then descending quote id.
There is no invoice-cycling button. Background monitoring continues while the
menu is closed: displayed-invoice checks and saved-deposit sweeps alternate
poll slots; without a displayed eligible invoice every slot sweeps one quote.

Only UNPAID quotes with a nonzero expiry strictly before the current Unix time
are expired: their checks are local-only and sweeps/resume skip them. Zero means
no expiry. PAID and remotely ISSUED but locally unconfirmed deposits remain
recoverable after expiry. An invoice that expires while displayed shows EXPIRED,
hides its QR, and stops unpaid polling. Deposit returns to amount entry; no
replacement invoice is created automatically.
Automatic CDK recovery continues even when no eligible saved quotes remain; an
expired UNPAID selection neither triggers an expired-quote GET nor blocks that
recovery. Recovery outcomes invalidate balance and history so both are reread
from the wallet library, never calculated in the UI from requested amounts.

Creation intents record the original amount/mint/method and pre-request quote
identities. A known saved result is reconciled and returned instead of creating
another invoice. Definitive CDK rejections permit retry; timeouts/network/unknown
outcomes remain blocked unless exact saved evidence resolves them. Optional
creation-time metadata failure leaves a usable invoice with unknown time, not a
permanent creation lock. Automatic reconciliation only checks local evidence,
with bounded automatic retry/backoff on transient read failures; there is no
manual recovery row. It never POSTs an invoice or blindly resets an unknown intent. Legacy `pending`
intents cannot be associated with arbitrary old quotes and remain explicitly
`legacy_unknown`. Saved invoices, balances and backups remain intact.

Opening/balance responses are small and independent of history size. History is
source-paginated in globally sorted pages of eight; resume returns one saved
invoice without a cursor. An oversized newest invoice reports an explicit error
and is retained, rather than silently falling through to an older invoice.
The 128 KiB transport bound is unchanged. No quotes are silently dropped or
financial fields truncated. History/resume errors do not disable the wallet.
Browser history reads load one validated Store with all creation metadata,
rather than reparsing it for every quote. Unchanged UNPAID polls fetch neither
balance nor history; confirmed issuance rereads balance, and dirty history is
fetched only while its page is active. History reads never contact a mint or
mutate payments. No schema, persistent history index or global cache is added.
Opening a history row reads its saved quote locally. The previous invoice and
copy action are unavailable while that selection loads, including after an
error, so selecting B cannot expose or copy stale invoice A.

One native worker owns open/read/quote/claim/close; rendering never waits for its
network requests. Browser calls use one asynchronous service queue and derive
seeds in Rust only. Both owners survive menu close. Native shutdown joins its
worker; browser service teardown drains the queue before closing handles.

The QR encoder is the same vendored, pinned Nayuki C implementation on both
platforms (see `vendor/qrcodegen/README.md`). It encodes once per invoice and
renders integer pixels with four quiet-zone modules; oversized invoices or
undersized viewports show an explicit QR-unavailable message. Copy transfers the
complete invoice, not its bounded preview.

## Module responsibilities

| File | Job |
|---|---|
| `src/input.zig` | polls raw samples with separate WASD/navigation vectors; device-free tick repeater produces routed directions |
| `src/frame_loop.zig` | queues 64 ordered samples, filters WASD against current mode, routes input/effects, caches view/viewport at 20 Hz |
| `src/menu.zig` | page/item data, pure layout maths, `TextField`, and the runtime `Menu` state (page, selected row, focus, text buffers, last pointer) |
| `src/game.zig` | `GameState.update` gives the menu first refusal; a consumed frame never reaches the camera or debug toggles |
| `src/rendering.zig` | reads menu state and draws the modal last, over the world, HUD, and minimap |
| `src/main.zig` | calls `setExitKey(.null)` so `Esc` is a menu key, then passes the viewport size to `rendering.draw` |
| `src/wallet_ui.zig` | Raylib-free request/state/polling model, checked amounts, bounded history pages |
| `src/wallet_service.zig` | native single-owner worker and one-slot mailbox |
| `browser/game-onboarding.js` | existing lifetime service queue, wallet adapter and trusted clipboard handling |

`menu.zig` does not import Raylib. `FrameInput` defaults describe a 1000×640
viewport, so tests can drive the whole menu without a window.

## Adding a page, action, or field

Page content is a list of tagged unions. The switches are exhaustive, so the
compiler points at every place that needs a decision.

```zig
pub const MenuItem = union(enum) {
    navigate: MenuPage,      // open another page
    action: Action,          // run a local action
    text_input: InputField,  // focus an editable field
};
```

1. **New page**: add a variant to `MenuPage`, add a `const foo_items` array, add
   it to `pageTitle` and `pageItems`, and keep it within `max_items_per_page`.
   Do not add storage for a page: `currentPage` already selects it.
2. **New action**: add a variant to `Action`, handle it in `Menu.activate`, and
   give it a label in `itemLabel`. Actions should only mutate local `Menu`
   state unless a real system is deliberately added.
3. **New field**: add a variant to `InputField`, add its `TextField` storage to
   `Menu`, add it to `textField`/`textFieldConst`, and place a `.text_input` row
   on a page. The renderer draws any field generically through
   `textFieldConst` and `isFocused`.

The deposit `TextField` remains fixed at 128 UTF-8 bytes; the separate withdrawal
field uses 4096. Neither allocates. Appends work on
whole Unicode codepoints, reject controls and surrogate halves, and stop at
capacity; backspace removes one whole codepoint. Rendering scrolls the value so
the caret stays visible, and scissors it to the input box.

## Layout and tests

`Menu.layoutFor(viewport_w, viewport_h)` (and the static-page wrapper
`menu.calculateLayout(page, viewport_w, viewport_h)`) is the single source of
rectangles for both hit testing and drawing. It centres the panel, then scales
padding, title height, gaps, and row height down with it, so every title and
item rectangle stays inside the panel even at tiny viewport sizes. There is no
scrolling system.

Headless tests in `menu.zig`, `input.zig`, and `game.zig` cover layout centring
and hit geometry, escape/navigation/action transitions, selection start and
reset, direction wrapping and cancellation, confirm activation, mouse selection versus
a stationary pointer, focus blurring, Unicode editing and capacity,
preservation of UI fields through `Reader.repeat`, the shared direction cadence,
WASD filtering while the menu is open, and modal input blocking the camera and
debug toggles.

Wallet verification:

```sh
zig build test test-wallet header-check test-build -Doffline
zig build test-wallet-ui -Dplatform=wasm -Doptimize=Debug -Doffline
zig build test-wallet-ui -Dplatform=wasm -Doptimize=ReleaseSafe -Doffline
node browser/game-onboarding-test.mjs
zig build -Doffline
zig build -Dplatform=wasm -Doffline
zig fmt --check src/wallet_ui.zig src/menu.zig src/rendering.zig src/wallet_service.zig
git diff --check
```

The browser UI command uses an
ephemeral loopback fake mint with a deterministic payment gate and a disposable
Chromium context. It drives functional wallet navigation through the actual
game, verifies complete-invoice clipboard contents, exactly-once issuance,
persisted history/selection/reload, and multiple deposits settling with the menu
closed without replacing the selected invoice. It does not check rendered
pixels, decode QR images or use OCR. QR encoding unit tests remain in the native
test suite. Native architecture C compile checks are
`zig build test-qr-portability -Doffline`; these do not verify rendering, and
ARM64 Linux/macOS runtime validation still requires those actual platforms.

For isolated native application fixtures, explicitly build with
`-Dapp-fixture-mint=http://127.0.0.1:PORT`; optimization never selects a mint.
Use isolated HOME/XDG directories when running that binary. New native recovery
markers are mint-bearing v3. Legacy ambiguous v2 recovery markers/stages remain
byte-for-byte preserved and blocked; ordinary v1 backup/complete wallets still
work. A mismatched v3 mint is rejected before opening its recovery stage.
