# Camera

Status: **implemented** in `src/camera.zig` for the current chunk-streaming demo.
Sections marked **planned** describe future gameplay work that is not in the
code yet.

---

## 1. Two pieces

| Piece | Owns | Lives in |
|---|---|---|
| `Camera` (ours) | pan position, keyboard/drag movement, speed | `src/camera.zig` |
| `rl.Camera2D` | the world→screen matrix | built fresh each frame |

Raylib's camera is only a **transform**. It does not follow anything, does not
cull, and is not the source of truth. We keep our own camera state so it can be
logged, replayed, or driven by a spectator mode later.

The current demo has no player; WASD/arrows and left-button dragging move the
camera directly. A follow camera with a dead zone, zoom, or clamping is
**planned**, not implemented.

---

## 2. The transform

Raylib maps world pixels to screen pixels as:

```
screen = (world - target) * zoom + offset
```

With `offset = screen_center` and `target = camera position`, the camera target
is always drawn in the middle of the window.

Three coordinate spaces, in order:

```
world tile (x,y)      world px (x*32, y*32)      screen px (sx, sy)
    i32                     f32                       f32
        ─── × TILE_PX ───►        ─── Camera2D ───►
```

Everything inside `beginMode2D` is drawn in **world px**. Everything outside is
**screen px**.

---

## 3. Our camera (implemented)

```zig
pub const Camera = struct {
    x: f32 = 0,
    y: f32 = 0,
    speed: f32 = 420,

    pub fn applyInput(self: *Camera, frame: input.FrameInput, dt: f32) void {
        if (frame.dragging) {
            self.x -= frame.drag_x;   // mouse drag wins
            self.y -= frame.drag_y;
        } else {
            if (frame.pan_left) self.x -= self.speed * dt;
            if (frame.pan_right) self.x += self.speed * dt;
            if (frame.pan_up) self.y -= self.speed * dt;
            if (frame.pan_down) self.y += self.speed * dt;
        }

        self.x = @round(self.x);      // pixel-art snapping
        self.y = @round(self.y);
    }

    pub fn raylib(self: Camera, vw: f32, vh: f32) rl.Camera2D {
        return .{
            .offset = .{ .x = vw / 2, .y = vh / 2 },
            .target = .{ .x = self.x, .y = self.y },
            .rotation = 0,
            .zoom = 1,
        };
    }
};
```

Facts about the current behaviour:

- Keyboard speed is 420 px/s; there is no diagonal normalisation.
- Directions are independent flags applied in the original order (left
  subtract, right add, up subtract, down add). Simultaneous opposing keys
  therefore keep the original sequential f32 rounding instead of collapsing to
  zero movement.
- Holding the left mouse button overrides the keyboard for that frame and
  subtracts the raw mouse delta.
- The position is snapped to whole pixels every frame, even when no input moves
  it, so the tile grid does not shimmer.
- `input.zig` supplies the `FrameInput`; camera movement never polls devices.

**Planned follow camera:** a future player-follow could replace the direct pan
with a dead zone or lerp:

```zig
// NOT IMPLEMENTED — future idea from the original design notes.
if (px > self.x + self.dead_zone) self.x = px - self.dead_zone;
if (px < self.x - self.dead_zone) self.x = px + self.dead_zone;
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
    chunks: world.ChunkRange,
};

pub fn calculate(cam: Camera, vw: f32, vh: f32) world.CoordinateError!View
```

Inside `visibleRange`:

```zig
const tl = rl.getScreenToWorld2D(.{ .x = 0, .y = 0 }, rc);
const br = rl.getScreenToWorld2D(.{ .x = vw, .y = vh }, rc);

const tx0 = @divFloor(@as(i32, @intFromFloat(@floor(tl.x))), world.TILE_PX);
const ty0 = @divFloor(@as(i32, @intFromFloat(@floor(tl.y))), world.TILE_PX);
const tx1 = @divFloor(@as(i32, @intFromFloat(@ceil(br.x))), world.TILE_PX);
const ty1 = @divFloor(@as(i32, @intFromFloat(@ceil(br.y))), world.TILE_PX);

const range = world.ChunkRange{
    .cx0 = @divFloor(tx0, world.CHUNK_TILES),
    .cy0 = @divFloor(ty0, world.CHUNK_TILES),
    .cx1 = @divFloor(tx1, world.CHUNK_TILES),
    .cy1 = @divFloor(ty1, world.CHUNK_TILES),
};
try world.validateChunkRange(range, world.PREFETCH_MARGIN_CHUNKS);
```

Notes:

- The demo loads a **2-chunk prefetch ring** around the visible range, not a
  one-tile slack border. `World.stream` unloads outside that ring, then loads
  visible chunks first and the rest of the ring second.
- `getScreenToWorld2D` is used instead of hand-rolled math, so this keeps
  working if zoom is added later.
- Validation happens before any world mutation, including the full prefetch
  ring and its count.
- The view is derived per frame and is not stored in `GameState`.

---

## 5. Mouse → tile (**planned**)

Not implemented; this is for future targeting, hover highlight, and the hoe
preview:

```zig
const m = rl.getScreenToWorld2D(rl.getMousePosition(), rc);
const tx = @divFloor(@as(i32, @intFromFloat(m.x)), world.TILE_PX);
const ty = @divFloor(@as(i32, @intFromFloat(m.y)), world.TILE_PX);
```

Use `@divFloor` — truncating division breaks on negative coordinates. Today the
mouse only pans the camera, so there is no world-space cursor yet.

---

## 6. Frame order (implemented)

Actual order in `src/main.zig`:

```zig
const frame = input.read();                          // devices -> data
game_state.update(frame, rl.getFrameTime());          // persistent state
const view = try camera.calculate(game_state.camera, vw, vh);
try game_state.streamChunks(view.chunks);            // residency only

rl.beginDrawing();
rendering.draw(&game_state, view);                   // read-only
rl.endDrawing();
```

`rendering.draw` uses `view.transform` for `beginMode2D` and `view.chunks` for
iteration. The renderer neither reads input nor mutates the camera or world.

---

## 7. Gotchas

1. **Draw UI outside `beginMode2D`.** Otherwise the HUD and minimap would pan
   with the world.
2. **`getMousePosition()` is screen space.** Convert with
   `getScreenToWorld2D` before comparing to world coords.
3. **Snap the camera target and use integer zoom** or 32 px tiles shimmer.
4. **Culling still needs the world rect.** The camera does not cull for you; it
   only gives you the rect cheaply.
5. **Chunks are drawn at world coordinates** (`cx * CHUNK_PX`), never in
   chunk-local coordinates, while `beginMode2D` is active.
6. **Camera state is ours, not Raylib's.** Never read `target` back out of
   `rl.Camera2D` to make gameplay decisions.
7. **Rendering is read-only.** It borrows `*const GameState`; do not add input
   polling or state mutation to `rendering.zig`.

---

## 8. Coordinate bounds (implemented)

World pixels and the transformed viewport corners must stay representable as
`i32`, and a chunk must stay drawable once its full `CHUNK_PX` extent is added:

```
world px:    -2147483648 .. 2147483647        (exclusive upper bound 2^31)
chunk index: -4194304 .. 4194302               (512 px chunks)
chunk px:     cx * CHUNK_PX  and  cx * CHUNK_PX + CHUNK_PX
```

Pixel validation lives in `src/camera.zig`; chunk-extent validation lives in
`src/world.zig`. Validate `f32` coordinates in `f64` with a **half-open** upper
bound. The largest `f32` below `2^31` is `2147483520`;
`@as(f32, @floatFromInt(maxInt(i32)))` rounds to `2147483648`, so an `f32`
comparison would accept a value that `@intFromFloat` rejects. NaN and ±Infinity
fail the same check.

The chunk check includes the prefetch ring: the visible range plus
`PREFETCH_MARGIN_CHUNKS` must fit the drawable chunk extent. This keeps
`range.expanded()`, chunk generation (`cx * CHUNK_TILES`), and rendering
(`cx * CHUNK_PX + CHUNK_PX`) overflow-free.

Violations return `error.CoordinateOutOfBounds` before any conversion,
streaming mutation, or draw. The error is **not** allocation pressure: only
`error.OutOfMemory` may be retried, while coordinate errors propagate out of the
frame loop rather than clamping or wrapping the camera silently.
