# Memory ownership and rendering

The active debug world lives in `src/render/chunk_debug.zig`.

## Ownership

- `main` passes a free-capable allocator (`std.heap.c_allocator`). There is no
  outer scene arena retaining old hash-map and scratch-list buffers.
- `World` owns its chunk pool, resident hash map, and reusable unload-key list.
  `run` defers `world.deinit()` before closing the Raylib window.
- The pool starts with at least 64 slots, or the initial viewport's prefetch
  ring if larger. The map and unload list are reserved alongside it.
- Unloading returns slots to the pool. Pool, map, and scratch capacity retain
  their high-water marks until world teardown; resizing smaller does not imply
  releasing those buffers. This avoids allocation churn during panning.

Chunks contain two `i32` coordinates and 256 one-byte tile IDs (264 bytes on
the current target). Tile positions are implicit in the row-major array.

## Frame lifetime

1. Update the camera and compute the visible range and two-chunk prefetch ring.
2. Collect and unload chunks outside the ring. The unload list always has
   enough capacity for all residents, so eviction cannot fail to allocate.
3. Load visible chunks first, then reserve and load the remaining prefetch ring.
4. Draw visible chunks into Raylib's own CPU batch buffers. Raylib does not
   retain chunk pointers or HUD text pointers.
5. `endMode2D` flushes world geometry; `endDrawing` flushes the UI and presents.

Allocation failures propagate from streaming. The render loop logs once per
pressure episode, marks the HUD as incomplete, draws available chunks, and
retries next frame. A failed load returns its chunk slot to the pool. There
is no fixed memory budget: residency follows the requested ring.

## HUD accounting

- **Loaded / wanted:** actual residents versus the requested ring size.
- **Resident:** loaded count times the chunk's size.
- **Pool backing:** the pool arena's actual buffer capacity, including unused
  slots and slack, excluding arena headers and backing-allocator overhead.
  Resident bytes are part of this number, not additional memory.
- **Map:** retained hash-table slots, not bytes or resident chunks.
- **Unload scratch:** retained key capacity and its buffer size in KiB.

These are world-container measurements, not process RSS. Raylib, graphics
drivers, fonts, framebuffers, and allocator overhead are separate.
