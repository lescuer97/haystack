# The frame loop — start here

This is the shortest map of the code. If you are new to the project, read this
before `world.md`, `camera.md`, or `memory.md`.

The demo is a chunk-streaming viewer: the camera pans over an endless,
deterministically generated tile world, and only the chunks near the view are
kept in memory. It does not simulate characters or talk to a server yet.

## Where things live

| File | Job | Talks to Raylib? |
|---|---|---|
| `src/main.zig` | allocator, window, the explicit per-frame loop, teardown, screenshot hook | yes |
| `src/input.zig` | reads devices once per frame into a plain `FrameInput` value | yes |
| `src/game.zig` | `GameState` owns the world, camera, and debug settings; applies input | indirectly |
| `src/camera.zig` | camera movement, world→screen transform, visible chunk range, bounds checks | yes |
| `src/world.zig` | tiles, chunks, deterministic generation, residency, streaming, stats | **no** |
| `src/rendering.zig` | draws world, marker, HUD, minimap from read-only state | yes |

`world.zig` is intentionally Raylib-free. That keeps it headless-testable and
ready for a future server or simulation.

## One frame, in order

`main` makes every stage visible. Nothing hides behind a single `tick()` call.

```zig
while (!rl.windowShouldClose()) {
    const vw = screen width;
    const vh = screen height;

    // 1. collect input
    const frame = input.read();

    // 2. update persistent state
    game_state.update(frame, rl.getFrameTime());

    // 3. calculate a temporary view
    const view = try camera.calculate(game_state.camera, vw, vh);

    // 4. prepare resident chunks for that view
    try game_state.streamChunks(view.chunks);

    // 5. render read-only state
    rl.beginDrawing();
    rendering.draw(&game_state, view);
    rl.endDrawing();
}
```

Why this order:

1. **Input first.** `input.zig` is the only place that calls `isKeyDown`,
   `isMouseButtonDown`, `getMouseDelta`, or `isKeyPressed`. It turns devices into
   data; it does not change the game.
2. **Update second.** `GameState.update` applies that one input value to the
   persistent camera and debug settings. This is one of only two places that
   mutate persistent state.
3. **View third.** The camera may have moved in step 2, so the view is
   calculated afterwards and therefore uses the new position this same frame.
   The view is derived data, not state.
4. **Stream fourth.** `streamChunks` is the other mutation site, but it only
   changes *which chunks are resident*. Generated world content is unchanged.
5. **Render last.** Rendering receives `*const GameState` and a `View`. It
   cannot move the camera or collect input, and its functions take read-only
   pointers, so the compiler helps prevent accidental mutation.

Screenshot mode (`HAYSTACK_SHOT=/path.png`) runs a few frames, then captures
**after** `endDrawing` has presented the frame, so the HUD is included.

## Three kinds of data

| Kind | Example | Lifetime | Who mutates it |
|---|---|---|---|
| Persistent state | `GameState.world`, `.camera`, `.debug` | until shutdown | `update`, `streamChunks` |
| Per-frame input | `FrameInput` (`pan_right`, `dragging`, `toggle_grid`, …) | one frame, then dropped | `input.read` |
| Calculated view | `camera.View` (`transform`, `chunks`) | one frame, then dropped | nobody; derived from state + window size |

`GameState` does **not** store the view or the input. That separation is the
point: tests can feed a `FrameInput` directly, and a future replay or network
source can do the same without a window.

The world itself is authoritative but its *residency* is a cache. A non-resident
chunk still exists conceptually; the deterministic generator can recreate it.
`World.get` returns `null` only because the cache does not contain it yet.

## A concrete trace: press D

At 120 FPS, `dt` is about 0.00833 s.

1. `input.read()` sees D held and returns `FrameInput{ .pan_right = true }`.
2. `GameState.update` calls `Camera.applyInput`. Keyboard speed is 420 px/s, so
   `x += 420 * dt ≈ 3.5`, then the camera snaps to a whole pixel with `@round`.
   Opposing directions are independent flags applied in the original order
   (left subtract, right add, up subtract, down add), so simultaneous keys keep
   the original sequential f32 rounding. If the left mouse button is also held,
   `dragging` is true and the raw mouse delta wins; the keyboard pan is ignored
   for that frame.
3. `camera.calculate` builds the Raylib transform centered on the new camera
   position, converts the window corners to world pixels, floors them to chunks,
   validates the chunk range plus the 2-chunk prefetch ring, and returns a
   `View`.
4. `GameState.streamChunks` unloads chunks outside the ring, loads visible
   chunks first, then loads the rest of the prefetch ring. It mutates only the
   resident chunk pool/map, never tile contents.
5. `rendering.draw` draws grid/borders for resident visible chunks, the camera
   marker, the HUD, and the minimap. It reads `GameState` and `View` only.
6. Next frame starts over. There is no event queue and no fixed timestep; `dt`
   comes from Raylib and input is sampled once per frame.

## Memory ownership

- `main` picks the allocator: `DebugAllocator` in Debug and ReleaseSafe (leak
  reporting), `c_allocator` in ReleaseFast and ReleaseSmall.
- `main` owns `GameState`; `GameState` owns `World`, `Camera`, `DebugSettings`.
- `World` owns its chunk pool, resident hash map, and reusable unload-key list.
  `GameState.deinit` releases all of them.
- Teardown is defer-ordered: `GameState.deinit` runs before `closeWindow`, and
  the debug allocator check runs last.
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
local devices ──► input.read() ───────────┐
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
