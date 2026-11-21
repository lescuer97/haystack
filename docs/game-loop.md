# The frame loop — start here

This is the shortest map of the code. If you are new to the project, read this
before `world.md`, `camera.md`, or `memory.md`. The modal menu has its own short
guide in `menu.md`.

The demo is a chunk-streaming viewer: the camera pans over an endless,
deterministically generated tile world, and only the chunks near the view are
kept in memory. The player moves one tile at a time against generated terrain,
and the camera follows accepted steps. Dragging pans the view without moving the
player. The standalone server uses the same terrain rule, but the client does
not connect to it yet.
`Esc` toggles the demonstration menu; see `menu.md` for its controls and
extension points.

## Player sprites

WASD, arrows, and controller directions attempt a step. Accepted steps play
the walk animation; blocked attempts face the requested direction without
walking. Releasing movement returns to idle. Mouse drag only pans the view. Press `Space` for the sword swing, `1` for pickaxe, `2` for axe, `3` for
hoe, `4` for watering can, or `5` to preview the collapse. These play once and
do not affect terrain, health, or inventory.

Oaks and the player are drawn back to front using the tree roots and the
player's feet. An oak in front of the player fades to 40% opacity if its art
would cover the player, and stays in front while faded. Other oaks stay opaque.

The local asset pack supplies both files in `assets/Player/`. Rows below are
zero-based; each source rectangle starts at `(column × cell size, row × cell
size)`. Left-facing frames mirror the right-facing ones.

| File | Cell | Animation | Rows (down / right / up) | Columns |
|---|---|---|---|---|
| `Player.png` (192×320) | 32×32 | Idle | 0 / 1 / 2 | 0–5 |
| | | Walk | 3 / 4 / 5 | 0–5 |
| | | Sword | 6 / 7 / 8 | 0–3 |
| | | Collapse | 9 (side only) | 0–3 |
| `Player_Actions.png` (96×576) | 48×48 | Pickaxe | 1 / 0 / 2 | 0–1 |
| | | Axe | 4 / 3 / 5 | 0–1 |
| | | Hoe | 7 / 6 / 8 | 0–1 |
| | | Water | 9 / 11 / 10 | 0–1 |

## Where things live

| File | Job | Talks to Raylib? |
|---|---|---|
| `src/main.zig` | allocator, window, the explicit per-frame loop or browser callback, teardown, screenshot hook | yes |
| `src/input.zig` | raw device polling, bounded text, and a device-free tick-count direction repeater | yes |
| `src/frame_loop.zig` | shared schedule adapter, ordered bounded queue, modal routing, immediate effects, cached view/viewport | no device polling |
| `src/game.zig` | `GameState` owns the world, camera, player animation, menu, and debug settings; applies input | indirectly |
| `src/player.zig` | sprite-sheet frame coordinates and playback timing | **no** |
| `src/menu.zig` | menu page/item data, pure layout, bounded text fields, and runtime menu state | **no** |
| `src/onboarding.zig` | platform-neutral onboarding model, modal input, effects, and layout | **no** |
| `src/onboarding_native.zig` | native wallet startup and completion adapter | **no** |
| `src/camera.zig` | camera movement, world→screen transform, visible chunk range, bounds checks | yes |
| `shared/world.zig` | tile/chunk types and deterministic terrain generation, shared with the standalone server | **no** |
| `src/world.zig` | client resident cache, drawable bounds, streaming, stats, and unused private-yield primitive | **no** |
| `src/rendering.zig` | draws world, player, HUD, minimap, menu, and optional onboarding overlay from read-only state | yes |

`world.zig` and `menu.zig` are intentionally Raylib-free. That keeps them
headless-testable. The standalone [server](server.md) already uses shared terrain
and owns RAM cuts/replay separately; this client does not connect to it or apply deltas.
The client's pixel-safe drawable chunk bounds intentionally differ from the
server's full tile-coordinate bounds.

## One frame, in order

Both platforms update game/UI input at **20 Hz (50 ms)** and draw the latest
state without interpolation: native targets 120 FPS; the browser uses rAF.
`frame_loop.Driver` belongs to native `main` or the heap-owned `BrowserContext`,
never `GameState`. The shared `tick.Schedule` grants an immediate first update,
preserves phase, and skips missed deadlines without catch-up. Raylib seconds are
converted to nanoseconds only after finite, nonnegative, exclusive-bound checks;
invalid clocks do not advance simulation. A safe initial view can still be
prepared without consuming input.

```zig
while (!rl.windowShouldClose()) {
    // Latch screenshot blocking BEFORE asynchronous completions can erase words.
    // Service wallet/auth/clipboard completions and real-time deadlines.
    // Invalidate stale queued input for accepted external target replacements.
    // Observe routing identity, then poll hardware ONCE and enqueue raw input.
    // If due: drain records in order, dispatch each effect immediately,
    // calculate/cache view+viewport, stream once, then skipPast a fresh clock.
    // Persist changed settings; draw cached state on EVERY display frame.
    // Screenshot only if onboarding never blocked anywhere in this outer frame.
}
```

Why this order:

1. **Input first.** `input.zig` is the only place that calls `isKeyDown`,
   `isKeyPressed`, `isMouseButtonDown`, `getMouseDelta`, `getCharPressed`, or the
   gamepad functions. `main` owns one `input.Reader` outside the loop; it polls
   the devices without timing or modal filtering. The
   same value carries the screen-space pointer, click/escape/confirm/backspace
   edges, viewport size, and a bounded array of typed codepoints. It does not
   change the game.
2. **Update second.** An optional onboarding model receives input first and
   consumes each queued record while blocking, including transition records. Otherwise
   `GameState.update` applies that one input value to the
   persistent player, camera, menu, and debug settings. The menu is modal: while it is
   open, and on the frame that opens or closes it, the update returns before the
   camera and gameplay hotkeys see the frame. Camera moves are whole-tile and validated;
   an unrepresentable move returns `error.CoordinateOutOfBounds` before any
   toggle is applied. This is one of only two places that mutate persistent
   state.
3. **View third.** The camera may have moved in step 2, so the view is
   calculated once after the batch. The loop caches derived view and viewport
   together until the next tick; resize layout can lag by up to 50 ms.
4. **Stream fourth.** `streamChunks` is the other mutation site, but it only
   changes *which chunks are resident*. Generated world content is unchanged.
5. **Render last.** Rendering receives `*const GameState`, a `View`, the
   viewport size, and an optional read-only onboarding model. It cannot move the camera or collect input, and its functions
   take read-only pointers, so the compiler helps prevent accidental mutation.
   Open **Debug Settings** from the pause menu to toggle the tile grid, chunk
   borders, chunk minimap, and debug HUD. The minimap and HUD start hidden and
   their visibility lasts for the current session. When the menu is open, it is
   drawn over the world and any enabled overlays. A blocking onboarding overlay
   is drawn last.

Screenshot mode (`HAYSTACK_SHOT=/path.png`) runs a few frames, then captures
**inside the drawing pass before `endDrawing` presents**, so the rendered world
and any enabled overlays are included rather than a cleared black back buffer.
If native onboarding is blocking at the start of the capture frame, the capture
is skipped and the screenshot budget is consumed; no PNG is written. A model
that is blocking at capture time also prevents capture. This also
protects completion-transition frames that started with recovery words visible.
The guard is captured before the real-time prelude and latched at every routed
record, before and after immediate effects, even when a tick is skipped.

### Input queue and cadence

The queue holds **64 raw samples**, preserving separate WASD and combined
arrow/controller held vectors. Adjacent records coalesce only when both are
edge/text-free, have zero drag deltas, and identical held/drag state; latest
pointer and viewport replace the old values. Edges are never ORed together.
Overflow drops the **newest whole sample**. This is bounded best effort, not an
unbounded lossless promise. A separate continuous snapshot always updates, so
dropped releases reconcile without replaying dropped clicks, text, or deltas.
Queued recovery text is securely scrubbed on consumption, discard, overflow,
and teardown; the continuous snapshot never contains text.

At consumption, current menu/onboarding mode filters WASD, so an earlier Escape
affects later queued letters. Non-direction records still run in order after
the direction allowance is used. A nonneutral vector steps on its first eligible
tick, then every two executed ticks (10 steps/s). At most one direction step
per tick covers all records, taps and direction changes; diagonals share it.
Neutral resets repeat, and world dragging resets/suppresses it. Short taps can
survive release before the tick; latest held state governs subsequent ticks.
Neither presentation frequency nor a long stall creates a movement burst.

Effects execute at their originating input, before later records: restore
copies/serializes its phrase immediately and native paste completes before later
typing. Effects do not flush the rest of the batch. External accepted onboarding
and wallet results, clipboard content replacement and trusted withdrawal-focus
replacement explicitly invalidate old input/reset repeat. Phase/attempt/menu
page/focus and actionable copy/confirm identity provide a before-capture
backstop, also on skipped ticks. Idle/stale wallet polls do not flush input.
Trusted browser clipboard operations remain synchronous in the original gesture
handler, outside the game clock. Wallet expiry, Unix time and worker dispatch
also remain real-time. Player animation time advances once per tick with
`tick.dt_seconds`, not once per queued input or draw.

## Native wallet startup

After the window and world are initialized, the first frame displays a blocking
loading overlay. Native wallet inspection and, when needed, provisioning run
on a joined background worker after that frame. A validated existing wallet proceeds directly to
the game. A newly provisioned or pending wallet displays its recovery words and
requires the player to acknowledge saving them before continuing. Completion
must be persisted successfully; otherwise the player can retry. Invalid or
unavailable wallet storage blocks startup without repairing existing data.
Copying is optional and exposes the words to other applications and clipboard
history; the clipboard is not automatically cleared. The desktop wallet is
persistent: `seed-words.txt` and `wallet.sqlite` live in a Haystack-owned wallet
directory with owner-only permissions. The mnemonic is plaintext, so filesystem
access exposes it; see [cdk-wallet-ffi.md](cdk-wallet-ffi.md) for the native
storage and ACL rules. Browser startup uses the same shared onboarding model but
a persistent IndexedDB wallet, described below.

## Browser loop

The five stages are factored into one `stepFrame` helper and run unchanged on
both platforms. Native `main` calls it from the blocking `while` loop above. The
browser build exports a C `main` instead. It does **not** create a window or a
main loop itself: it starts the asynchronous settings gate and returns. That gate
takes the lifetime Web Lock and loads IndexedDB settings. A lock conflict or a
failure creating the window or renderer context is a startup failure: it shows
the generic `Unable to start game.` message and creates no frame loop. Malformed
or unavailable settings do not fail startup; they are preserved with autosave
disabled or replaced with built-in settings, as described in
[browser-storage.md](browser-storage.md).

Once the settings gate succeeds, its continuation creates the heap-owned
`BrowserContext` (the `GameState`, `input.Reader`, loop driver, and shared onboarding
model), starts the asynchronous `BrowserOnboarding` inspection, and hands an
Emscripten callback to `emscripten_set_main_loop(browserFrame, 0, 0)`. The context
outlives the entry function; Emscripten never receives a pointer to a returned
stack frame. The page is never blocked.

Wallet inspection and onboarding continue asynchronously and are delivered to
the shared onboarding model. Until that model reports ready, it is blocking, so
the frame loop keeps running but gameplay input is gated and the onboarding
modal (initially a loading state) is drawn on the canvas. A wallet inspection,
creation, recovery or storage failure appears as that blocked modal, not as the
generic startup message. Ready means the persistent `haystack-user` records were
provisioned and validated; the JS wallet is not retained as an open
`BrowserWallet`, and there is no gameplay wallet-operation or spending bridge, so
completing onboarding is not end-to-end in-game spending verification. See
[browser-wallet.md](browser-wallet.md) for the IndexedDB records and their
limitations.

`browser/game-shell.html` is the game-only shell: one full-viewport canvas with
no border, margin or scroll, a temporary non-interactive startup line, and
`Module.canvas` before the Emscripten script. It has no wallet form, iframe,
Emscripten logo, controls or log textarea. Raylib's web backend already resizes
the canvas and renderbuffer from `window.innerWidth`/`innerHeight`; the Zig side
also initializes using the current canvas CSS size instead of a fixed
`1000x640`. There is no competing JS resize code. The shell focuses the canvas
after startup and on pointer interaction, scopes its key listener to the focused
canvas, and cancels only non-printable navigation/scroll keys (arrows,
Backspace, Tab, Enter, Escape). Printable WASD/G/B/space keys are never
cancelled, so GLFW's keypress path can still type into menu fields; Ctrl/Meta/Alt
shortcuts are left alone.

The browser callback deliberately does **not** call `rl.windowShouldClose()`.
The pinned web backend implements it with a blocking `emscripten_sleep`, which
is forbidden inside `emscripten_set_main_loop` and aborts when asyncify is
disabled. The browser page/main loop owns lifetime instead, and `EndDrawing`
still polls input and timing normally. The browser also sets raylib's target FPS
to zero so `requestAnimationFrame`, not a raylib sleep, controls pacing.

Browser teardown is explicit and idempotent: `stopBrowser` clears the global
context first, unbinds the onboarding callbacks, closes the onboarding bridge,
cancels the main loop, deinitializes the onboarding model and `GameState`,
destroys the context, and closes the window. A callback that finds no context
returns immediately, so no stage touches freed state after cleanup. Settings-gate
or renderer-initialization failures log, run the same cleanup, call the generic
error UI and never register a loop. Wallet/onboarding failures after startup keep
the loop running behind the blocked modal instead. Both entry points disable
Raylib's Escape quit key so Escape toggles the menu. The browser exposes no game
snapshot or test-only `Module` status API; startup state is internal to the
shared onboarding model and its asynchronous bridge.

## Four kinds of data

| Kind | Example | Lifetime | Who mutates it |
|---|---|---|---|
| Persistent state | `GameState.world`, `.camera`, `.menu`, `.settings.debug` | until shutdown | `update`, `streamChunks` |
| Loop state | `frame_loop.Driver` schedule, queue, repeater | until shutdown | input capture and due ticks |
| Raw input | `RawSample` (separate held vectors, edges, text, drag, pointer, viewport) | bounded queue, then scrubbed | `Reader.read` |
| Routed input | `FrameInput` | one ordered consumption | repeater and current modal filter |
| Calculated view | cached `camera.View` and viewport | until next tick | derived from camera + viewport |

`GameState` does **not** store the view or the input. That separation is the
point: tests can feed a `FrameInput` directly, and a future replay or network
source can do the same without a window.

The menu's runtime UI values (open page, selected row, focused field, wallet-name
text, last pointer position) are persistent state because they must survive
frames. Page and item definitions are static data in `menu.zig`.

Shared terrain defines the generated world, while client *residency* is only a
cache. A non-resident chunk still exists conceptually; the deterministic generator can recreate it.
`World.get` returns `null` only because the cache does not contain it yet.

## A concrete trace: press and hold D

1. `input_reader.read()` sees D held and queues a separate WASD vector. At the
   next due tick, if no menu/onboarding blocks it, the repeater emits
   `FrameInput{ .right = true }`. Stable holds repeat every two executed ticks;
   missed ticks are dropped, not replayed. OS direction auto-repeat is unused.
2. `GameState.update` checks the proposed tile with `shared.movement.canStep`.
   If accepted, the player moves one tile and the camera follows. A diagonal
   also needs both side tiles clear. A held left mouse button takes precedence,
   resets the step cadence, and pans only the camera.
3. `camera.calculate` builds the Raylib transform centered on the new camera
   position, converts the window corners to world pixels, floors them to chunks,
   validates the chunk range plus the 2-chunk prefetch ring, and returns a
   `View`.
4. `GameState.streamChunks` unloads chunks outside the ring, loads visible
   chunks first, then loads the rest of the prefetch ring. It mutates only the
   resident chunk pool/map, never tile contents.
5. `rendering.draw` draws grid/borders for resident visible chunks, the camera
   marker, the HUD, and the minimap. If the menu is open it draws that last, in
   screen space, followed by any blocking onboarding overlay. It reads
   `GameState`, `View`, the viewport size, and the optional model only.
6. The next display frame polls again and draws the cached latest state. Only
   the next due tick consumes its queued input and refreshes the view.

## Memory ownership

- `main` picks the allocator: `DebugAllocator` in Debug and ReleaseSafe (leak
  reporting), `c_allocator` in ReleaseFast and ReleaseSmall. The browser entry
  uses `c_allocator` for its heap-owned `BrowserContext`.
- `main` owns `GameState`; `GameState` owns `World`, `Camera`, `Menu`, and
  `Settings`. In the browser, `BrowserContext` owns both `GameState` and
  `input.Reader` and `frame_loop.Driver`; driver teardown scrubs its queue.
- `Menu` and its `TextField` buffers are fixed-size values: no allocation, no
  separate teardown.
- `World` owns its chunk pool, resident hash map, and reusable unload-key list.
  `GameState.deinit` releases all of them.
- Teardown is defer-ordered on native: `GameState.deinit` runs before
  `closeWindow`, and the debug allocator check runs last. Browser teardown runs
  the same order explicitly (cancel loop, deinit state, destroy context, close
  window) and cannot run twice.
- Steady-state panning reuses released pool slots and pre-reserved map/scratch
  capacity, so normal frames do not allocate. There is no per-frame snapshot of
  the world.
- Allocation failure during streaming keeps whatever loaded, sets
  `memory_pressure`, warns once per episode, and retries next tick. A
  coordinate error is a program invariant and propagates out of the loop.
- See `memory.md` for the HUD accounting details.

## Future: incoming server messages (not implemented)

There is **no networking code today**. The following is the planned shape, not
a protocol.

A future WebSocket client is an independent input source alongside the local
keyboard/mouse:

```text
local devices ──► input_reader.read() ────┐
                                          ├─► update boundary ─► GameState
server socket ──► drain messages (nonblocking) ─┘
```

Rules for when that is added:

1. **Collect without waiting.** Drain whatever server messages are already
   available; never block the frame loop waiting for the next one.
2. **Callbacks only enqueue.** A network callback must not mutate `GameState`,
   `World`, or a resident chunk. It copies plain data into a queue.
3. **Apply at the update boundary, server changes first, then local actions.**
   Server-authoritative changes are applied, then the local `FrameInput` action
   is applied for this frame. Messages that arrive after the collection point
   wait for the next frame.
4. **Never mutate a resident `Chunk` as the source of truth.** Resident chunks
   can be evicted at any time. Gameplay changes must live in an authoritative
   state/resync layer (for example, per-tile deltas keyed by world coordinates,
   owned by the server) and be reapplied when a chunk is regenerated. That
   design is described in `world.md` as planned work; it is not implemented and
   no wire format should be invented here.

Until those pieces exist, keep gameplay code dependent on `GameState` and
`World`, not on Raylib or on transient chunk pointers.
