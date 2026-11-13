# The frame loop — start here

This is the shortest map of the code. If you are new to the project, read this
before `world.md`, `camera.md`, or `memory.md`. The modal menu has its own short
guide in `menu.md`.

The demo is a chunk-streaming viewer: the camera pans over an endless,
deterministically generated tile world, and only the chunks near the view are
kept in memory. It does not simulate characters or talk to a server yet.
`Esc` toggles the demonstration menu; see `menu.md` for its controls and
extension points.

## Where things live

| File | Job | Talks to Raylib? |
|---|---|---|
| `src/main.zig` | allocator, window, the explicit per-frame loop or browser callback, teardown, screenshot hook | yes |
| `src/input.zig` | polls keyboard/mouse/gamepad 0 and paces held directions into a plain `FrameInput` value; also collects pointer, clicks, viewport size, and bounded typed text | yes |
| `src/game.zig` | `GameState` owns the world, camera, menu, and debug settings; applies input | indirectly |
| `src/menu.zig` | menu page/item data, pure layout, bounded text fields, and runtime menu state | **no** |
| `src/onboarding.zig` | platform-neutral onboarding model, modal input, effects, and layout | **no** |
| `src/onboarding_native.zig` | native wallet startup and completion adapter | **no** |
| `src/camera.zig` | camera movement, world→screen transform, visible chunk range, bounds checks | yes |
| `src/world.zig` | tiles, chunks, deterministic generation, residency, streaming, stats | **no** |
| `src/rendering.zig` | draws world, marker, HUD, minimap, menu, and optional onboarding overlay from read-only state | yes |

`world.zig` and `menu.zig` are intentionally Raylib-free. That keeps them
headless-testable and ready for a future server or simulation.

## One frame, in order

`main` makes every stage visible. Nothing hides behind a single `tick()` call.

```zig
while (!rl.windowShouldClose()) {
    const vw = screen width;
    const vh = screen height;

    // 1. collect input
    const blocking = if (model) |m| m.isBlocking() else false;
    const frame = input_reader.read(rl.getFrameTime(), game_state.menu.opened or blocking);

    // 2. update persistent state
    const effect = try routeFrame(&game_state, model, frame);
    // routeFrame gives onboarding first refusal; otherwise GameState updates.
    // Persist settings if they changed.

    // 3. calculate a temporary view
    const view = try camera.calculate(game_state.camera, vw, vh);

    // 4. prepare resident chunks for that view
    try game_state.streamChunks(view.chunks);

    // 5. render read-only state
    rl.beginDrawing();
    rendering.draw(&game_state, view, vw, vh, model);
    // Capture a requested screenshot only if onboarding did not block this frame.
    rl.endDrawing();
    // Native loop handles onboarding effects and adapter events after the frame.
}
```

Why this order:

1. **Input first.** `input.zig` is the only place that calls `isKeyDown`,
   `isKeyPressed`, `isMouseButtonDown`, `getMouseDelta`, `getCharPressed`, or the
   gamepad functions. `main` owns one `input.Reader` outside the loop; it polls
   the devices and turns held directions into at most one one-tile request per
   axis on a shared 10 steps/s cadence used by both the camera and the menu. The
   same value carries the screen-space pointer, click/escape/confirm/backspace
   edges, viewport size, and a bounded array of typed codepoints. It does not
   change the game.
2. **Update second.** An optional onboarding model receives input first and
   consumes it while blocking, including transition frames. Otherwise
   `GameState.update` applies that one input value to the
   persistent camera, menu, and debug settings. The menu is modal: while it is
   open, and on the frame that opens or closes it, the update returns before the
   camera and toggles see the frame. Camera moves are whole-tile and validated;
   an unrepresentable move returns `error.CoordinateOutOfBounds` before any
   toggle is applied. This is one of only two places that mutate persistent
   state.
3. **View third.** The camera may have moved in step 2, so the view is
   calculated afterwards and therefore uses the new position this same frame.
   The view is derived data, not state.
4. **Stream fourth.** `streamChunks` is the other mutation site, but it only
   changes *which chunks are resident*. Generated world content is unchanged.
5. **Render last.** Rendering receives `*const GameState`, a `View`, the
   viewport size, and an optional read-only onboarding model. It cannot move the camera or collect input, and its functions
   take read-only pointers, so the compiler helps prevent accidental mutation.
   When the menu is open it is drawn after the world, HUD, and minimap, so its
   dim backdrop covers them. A blocking onboarding overlay is drawn last.

Screenshot mode (`HAYSTACK_SHOT=/path.png`) runs a few frames, then captures
**inside the drawing pass before `endDrawing` presents**, so the rendered world
and HUD are included rather than a cleared black back buffer.
If native onboarding is blocking at the start of the capture frame, the capture
is skipped and the screenshot budget is consumed; no PNG is written. A model
that is blocking at capture time also prevents capture. This also
protects completion-transition frames that started with recovery words visible.

## Native wallet startup

After the window and world are initialized, the first frame displays a blocking
loading overlay. Native wallet inspection and, when needed, provisioning run
synchronously after that frame. A valid legacy wallet proceeds directly to the
game. A newly provisioned or pending wallet displays its recovery words and
requires the player to acknowledge saving them before continuing. Completion
must be persisted successfully; otherwise the player can retry. Invalid or
unavailable wallet storage blocks startup without repairing existing data.
Copying is optional and exposes the words to other applications and clipboard
history; the clipboard is not automatically cleared. Browser startup and its
separate wallet provisioning policy are unchanged.

## Browser loop

The five stages are factored into one `stepFrame` helper and run unchanged on
both platforms. Native `main` calls it from the blocking `while` loop above. The
browser build exports a C `main` instead. It does **not** create a window or a
main loop: it starts an async disposable-wallet gate and returns immediately.
Only when the JS bridge has generated a mnemonic, opened and verified an empty
wallet, closed/freed it and removed its storage key does it invoke one
single-shot Zig C continuation. That continuation creates the heap-owned
`BrowserContext` (the `GameState` plus the persistent `input.Reader`) and hands
an Emscripten callback to `emscripten_set_main_loop(browserFrame, 0, 0)`, so the
page is never blocked. The context outlives the entry function; Emscripten never
receives a pointer to a returned stack frame. A wallet import, initialization,
storage or cleanup failure shows the generic `Unable to start game.` message and
creates no game context or frame loop.

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
context first, cancels the main loop, deinitializes `GameState`, destroys the
context, and closes the window. A callback that finds no context returns
immediately, so no stage touches freed state after cleanup. Initialization
failures log, run the same cleanup, call the generic error UI and never register
a loop. Both entry points disable Raylib's Escape quit key so Escape toggles the
menu. The browser exposes no game snapshot or test-only `Module` status API;
startup state is internal to the single-shot wallet gate.

## Four kinds of data

| Kind | Example | Lifetime | Who mutates it |
|---|---|---|---|
| Persistent state | `GameState.world`, `.camera`, `.menu`, `.settings.debug` | until shutdown | `update`, `streamChunks` |
| Persistent input timing | `input.Reader` (`last_dx`, `last_dy`, `elapsed` direction cadence) | until shutdown | `Reader.read` |
| Per-frame input | `FrameInput` (`right`, `down`, `confirm`, `dragging`, `pointer_x`, `characters`, …) | one frame, then dropped | `Reader.read` |
| Calculated view | `camera.View` (`transform`, `chunks`) | one frame, then dropped | nobody; derived from state + window size |

`GameState` does **not** store the view or the input. That separation is the
point: tests can feed a `FrameInput` directly, and a future replay or network
source can do the same without a window.

The menu's runtime UI values (open page, selected row, focused field, wallet-name
text, last pointer position) are persistent state because they must survive
frames. Page and item definitions are static data in `menu.zig`.

The world itself is authoritative but its *residency* is a cache. A non-resident
chunk still exists conceptually; the deterministic generator can recreate it.
`World.get` returns `null` only because the cache does not contain it yet.

## A concrete trace: press and hold D

1. `input_reader.read(dt, game_state.menu.opened)` sees D held (or controller
   0's D-pad/left stick on the same direction) and emits
   `FrameInput{ .right = true }`. The first
   frame of a new direction steps immediately; while it stays held the same
   request repeats every 0.1 s, so movement is 10 steps per second during normal
   frame rates. At most one step is emitted per frame, so below 10 FPS or after a
   stall missed whole steps are dropped. The OS keyboard auto-repeat is not
   used.
2. `GameState.update` calls `Camera.applyInput`. Each request moves the camera
   exactly one tile on that axis. Opposing inputs cancel, and a held diagonal
   (for example D plus S) moves one tile on both axes per step. A held left
   mouse button takes precedence over keys and controller and resets the step
   cadence. Here `tile_x` increases by 1, and the Raylib target becomes
   `(tile_x * 32 + 16, tile_y * 32 + 16)` pixels.
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
6. Next frame starts over. There is no event queue and no fixed timestep; input
   is sampled once per frame, and `input.Reader` uses the frame delta only to
   pace held directional steps.

## Memory ownership

- `main` picks the allocator: `DebugAllocator` in Debug and ReleaseSafe (leak
  reporting), `c_allocator` in ReleaseFast and ReleaseSmall. The browser entry
  uses `c_allocator` for its heap-owned `BrowserContext`.
- `main` owns `GameState`; `GameState` owns `World`, `Camera`, `Menu`, and
  `Settings`. In the browser, `BrowserContext` owns both `GameState` and
  `input.Reader`.
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
  `memory_pressure`, warns once per episode, and retries next frame. A
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
