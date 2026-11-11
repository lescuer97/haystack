# Memory ownership and streaming

The authoritative world model lives in `src/world.zig`. `src/game.zig` owns it
as part of `GameState`. Read `game-loop.md` first for the frame order.

## Ownership

- `main` picks the allocator: `std.heap.DebugAllocator` in Debug and
  ReleaseSafe (so leaks are reported), `std.heap.c_allocator` in ReleaseFast and
  ReleaseSmall. There is no outer scene arena retaining old hash-map and
  scratch-list buffers.
- `GameState` owns `World`, `Camera`, and `DebugSettings`. `main` defers
  `game_state.deinit()`; `World.deinit` releases the chunk pool, resident hash
  map, and reusable unload-key list.
- Defers run in reverse order: the world is released before `closeWindow`, and
  the debug allocator's leak check runs last.
- The pool starts with at least 64 slots, or the initial viewport's prefetch
  ring if larger. The map and unload list are reserved alongside it.
- Unloading returns slots to the pool. Pool, map, and scratch capacity retain
  their high-water marks until world teardown; resizing smaller does not imply
  releasing those buffers. This avoids allocation churn during panning.

Chunks contain two `i32` coordinates and 256 one-byte tile IDs. Tile positions
are implicit in the row-major array. `world.zig` does not import Raylib, so the
same storage works headlessly.

## Frame lifetime

1. `input.Reader.read(dt)` collects devices and paces held directions into a
   temporary `FrameInput`. It does not touch the world.
2. `GameState.update` mutates persistent camera/debug state. It does not
   allocate.
3. `camera.calculate` derives a temporary `View` (Raylib transform + validated
   chunk range). It does not allocate.
4. `GameState.streamChunks` -> `World.stream` unloads chunks outside the
   two-chunk prefetch ring, loads visible chunks first, then loads/reserves the
   rest of the ring. It mutates residency only. The unload list always has
   enough capacity for all residents, so eviction cannot fail to allocate.
   Normal steady-state frames reuse existing capacity; allocation can occur
   only when the world grows.
5. `rendering.draw` borrows `*const GameState` and a `View` and draws into
   Raylib's own CPU batch buffers. Raylib does not retain chunk pointers or HUD
   text pointers. Rendering never collects input or mutates game state.
6. `endMode2D` flushes world geometry; `endDrawing` flushes the UI and presents.
   The optional screenshot is taken after that presentation.

Allocation failures from streaming are handled in `GameState.streamChunks`: it
logs once per pressure episode, marks the HUD as incomplete, draws the chunks
that are available, and retries next frame. A failed load returns its chunk slot
to the pool. A coordinate error is not memory pressure and propagates out of the
frame loop. There is no fixed memory budget: residency follows the requested
ring.

## HUD accounting

- **Loaded / wanted:** actual residents versus the requested ring size.
- **Resident:** loaded count times the chunk's size.
- **Pool backing:** the pool arena's actual buffer capacity, including unused
  slots and slack, excluding arena headers and backing-allocator overhead.
  Resident bytes are part of this number, not additional memory.
- **Map:** retained hash-table slots, not bytes or resident chunks.
- **Unload scratch:** retained key capacity and its buffer size in KiB.
- **Stream:** `ok`, or the out-of-memory episode marker.

These are world-container measurements, not process RSS. Raylib, graphics
drivers, fonts, framebuffers, and allocator overhead are separate.
