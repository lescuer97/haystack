# Camera

Status: **implemented** in `src/camera.zig` for the current chunk-streaming demo.
Sections marked **planned** describe future gameplay work that is not in the
code yet.

---

## 1. Two pieces

| Piece | Owns | Lives in |
|---|---|---|
| `Camera` (ours) | tile position, keyboard/pad/drag movement | `src/camera.zig` |
| `rl.Camera2D` | the world→screen matrix | cached by the loop with its viewport until the next 20 Hz tick |

Raylib's camera is only a **transform**. It does not follow anything, does not
cull, and is not the source of truth. We keep our own camera state so it can be
logged, replayed, or driven by a spectator mode later.

The current demo has no player; holding WASD/arrows, the pad D-pad, or the left
stick steps the camera one tile on a shared 10 steps/s cadence, and left-button
dragging pans it. Holding two directions steps diagonally, one tile on each
axis. A follow camera with a dead zone, zoom, or clamping is **planned**, not
implemented.

---

## 2. The transform

The camera keeps its absolute world tile as the frame's origin. For each axis,
the renderer widens the tile coordinate, subtracts that origin, and only then
converts the local offset to pixels:

```
local_px = (i64(world_tile) - camera_tile) * TILE_PX
screen = (local_px - target) * zoom + offset
```

Raylib's target is the center of the local origin tile `(16,16)` and its offset
is the screen center. Everything inside `beginMode2D` is drawn in
**camera-relative pixels**; everything outside uses **screen pixels**. Chunk
addresses, player positions, and terrain lookups stay absolute. A tile three
tiles away stays exactly 96 pixels away even near the limits of the world.

---

## 3. Our camera (implemented)

```zig
pub const Camera = struct {
    tile_x: i32 = 0,           // authoritative world tile
    tile_y: i32 = 0,
    drag_remainder_x: f64 = 0, // sub-tile drag pixels
    drag_remainder_y: f64 = 0,

    pub fn applyInput(self: *Camera, frame: input.FrameInput) world.CoordinateError!void {
        // Drag wins; one tile per emitted direction request. See behaviour below.
    }

    pub fn raylib(_: Camera, vw: f32, vh: f32) rl.Camera2D {
        return .{
            .offset = .{ .x = vw / 2, .y = vh / 2 },
            .target = .{ .x = world.TILE_PX / 2, .y = world.TILE_PX / 2 },
            .rotation = 0,
            .zoom = 1,
        };
    }
};
```

Facts about the current behaviour:

- `tile_x`/`tile_y` store the view target, separate from `GameState.player_pos`.
  The camera never stores a fractional or pixel camera position.
- Keyboard, D-pad, and left-stick directions are raw held flags. The loop-owned
  `input.Repeater` turns them into one-tile requests on a shared 10 steps/s
  cadence: a new vector steps on its first eligible tick, then every two
  executed 50 ms ticks. At most one direction step is emitted per tick across
  all queued records; after a stall missed steps are discarded. The OS keyboard
  auto-repeat rate is not used, so holding two directions keeps both axes on the
  same cadence.
- Controller support is controller index 0 only, using its D-pad or left analog
  stick. Each stick axis has an independent `0.25` deadzone (`stick_deadzone`
  in `input.zig`, the tuning knob); non-finite axis values and a disconnected
  controller are neutral.
- Directions are independent flags. Opposing requests on one axis cancel, and
  holding both axes requests a diagonal player step. Duplicate bindings
  (say, key and D-pad both right) never multiply a step.
- Holding the left mouse button overrides keyboard and controller for that
  frame. Negative raw deltas accumulate in `f64`; whole `TILE_PX` steps become
  tile moves and the sub-tile remainder carries to later frames. A large drag
  can pan several tiles at once without changing the player tile.
- Any non-drag record resets both remainders, so one gesture cannot leak into the
  next. Ordered queued drag/release records preserve that boundary. A world drag
  or neutral record resets repeat; world dragging suppresses directions that tick.
- There is no movement speed or fractional camera position: movement is
  discrete. Presentation `dt` is never used to pace held steps. Both axes are
  validated and committed together. Non-finite drags and moves that would leave
  the signed `i32` tile world are rejected without changing the camera. Gameplay
  treats such input as a blocked step or pan, not a fatal frame error.
- `input.zig` supplies the `FrameInput`; camera movement never polls devices.

The camera recenters when the player makes an accepted step; it stays where it
was on idle, blocked steps, or in-place actions. A future follow mode could use
a dead zone or lerp:

```zig
// NOT IMPLEMENTED — future idea from the original design notes.
// `px`/`py` would be a target tile coordinate derived from a player.
if (px > self.tile_x + self.dead_zone) self.tile_x = px - self.dead_zone;
if (px < self.tile_x - self.dead_zone) self.tile_x = px + self.dead_zone;
```

Keep zoom an integer for pixel art if it is added (1, 2, 3…). Fractional zoom
plus a non-snapped target makes tiles blurry/shimmer.

---

## 4. Culling from the camera (implemented)

The camera is also how we decide which chunks to load and draw. `camera.calculate`
returns a temporary `View`:

```zig
pub const View = struct {
    transform: rl.Camera2D,
    chunks: world.ChunkRange, // absolute, inclusive
    tiles: TileRange, // absolute, half-open i64 bounds
    minimap: ?MinimapView,
};

pub fn calculate(cam: Camera, vw: f32, vh: f32) world.CoordinateError!View
```

The camera converts viewport edges to local tile offsets using the inverse of
its unrotated, zoom-1 transform. It then adds the absolute camera tile and clips
the result to the world. Floor the near edge and ceil the far edge to get
half-open tile bounds; a tile touching only the far edge is not visible.

- The demo loads a **2-chunk prefetch ring** around the visible range and clips
  it at the world edge. `World.stream` unloads outside the residency range and
  loads visible chunks first.
- The minimap uses an absolute tile window around the camera and clips the
  chunks it needs at the same boundary.
- Validation of the viewport and residency range happens before streaming
  changes the cache.
- The view is derived once per tick and cached with the viewport in the loop,
  not in `GameState`. Rendering stays native 120 FPS/browser rAF, with no
  interpolation. The minimap and menu use the same cached viewport.

---

## 5. Mouse → tile

`camera.screenToTile` uses the same inverse transform as visibility: floor the
local tile offset, then add the absolute camera origin. It returns `null` for
points beyond the world edge or non-finite coordinates. On desktop, a world
click uses this tile to aim the hoe. If the tile is out of reach, the click
selects the neighboring tile in that direction, including diagonals, regardless
of player facing. `Space` still aims at the tile the player faces.

---

## 6. Frame order (implemented)

Actual order in `src/main.zig`:

```zig
// Every display frame: real-time completions, invalidate stale input, raw poll.
// Due at 20 Hz: route ordered records, immediate effects, prepare view/stream.
// Every display frame: draw latest state with cached view AND viewport.
```

`input_reader` only polls hardware. `frame_loop.Driver` owns the bounded queue,
repeater, schedule and cached view; native `main` or `BrowserContext` owns it.
`FrameInput` remains the routed contract passed to `GameState.update`.

`rendering.draw` uses `view.transform` for `beginMode2D` and `view.chunks` for
iteration. The renderer neither reads input nor mutates the camera or world.

---

## 7. Gotchas

1. **Draw UI outside `beginMode2D`.** Otherwise the HUD and minimap would pan
   with the world.
2. **`getMousePosition()` is screen space.** Use `camera.screenToTile` if an
   interaction needs an absolute world tile.
3. **Move in whole tiles and use integer zoom** or 32 px tiles shimmer. The
   client currently uses zoom 1 and targets the local tile's center.
4. **Culling still needs the world rect.** The camera does not cull for you; it
   only gives you the rect cheaply.
5. **Chunks are drawn relative to the camera**, not the global world origin.
   Use `camera.relativePixel` before converting the result to `f32`.
6. **Camera state is ours, not Raylib's.** Never read `target` back out of
   `rl.Camera2D` to make gameplay decisions.
7. **Rendering is read-only.** It borrows `*const GameState`; do not add input
   polling or state mutation to `rendering.zig`.

---

## 8. Coordinate bounds (implemented)

Tiles span the full signed `i32` range (`-2147483648` to `2147483647`) on each
axis. The 16-tile chunks span `-134217728` to `134217727`, matching the protocol.
`TileRange` uses `i64` endpoints so the exclusive upper bound `2147483648` is
representable. The viewport, minimap, and prefetch clip at these boundaries;
they do not wrap to the opposite edge. The renderer never needs an absolute
pixel coordinate. `src/world.zig` still validates the size of a requested
residency range before allocating or streaming.
