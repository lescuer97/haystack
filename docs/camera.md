# Camera

Status: **implemented** in `src/camera.zig` for the current chunk-streaming demo.
Sections marked **planned** describe future gameplay work that is not in the
code yet.

---

## 1. Two pieces

| Piece | Owns | Lives in |
|---|---|---|
| `Camera` (ours) | tile position, keyboard/pad/drag movement | `src/camera.zig` |
| `rl.Camera2D` | the world→screen matrix | built fresh each frame |

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

Raylib maps world pixels to screen pixels as:

```
screen = (world - target) * zoom + offset
```

With `offset = screen_center` and `target = camera position`, the camera target
is always drawn in the middle of the window.

Three coordinate spaces, in order:

```
world tile (x,y)    world px (x*32 + 16, y*32 + 16)   screen px (sx, sy)
    i32                     f32                       f32
        ─── × TILE_PX ───►        ─── Camera2D ───►
```

Everything inside `beginMode2D` is drawn in **world px**. Everything outside is
**screen px**. Our camera stores tile coordinates (`i32`); `Camera.raylib`
widens `tile * TILE_PX + TILE_PX/2` to `i64` before converting the target to
`f32` pixels. The target is the tile's center pixel.

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

    pub fn raylib(self: Camera, vw: f32, vh: f32) rl.Camera2D {
        return .{
            .offset = .{ .x = vw / 2, .y = vh / 2 },
            .target = .{
                .x = @floatFromInt(@as(i64, self.tile_x) * world.TILE_PX + world.TILE_PX / 2),
                .y = @floatFromInt(@as(i64, self.tile_y) * world.TILE_PX + world.TILE_PX / 2),
            },
            .rotation = 0,
            .zoom = 1,
        };
    }
};
```

Facts about the current behaviour:

- `tile_x`/`tile_y` are the only persistent position. The camera never stores a
  fractional or pixel camera position.
- Keyboard, D-pad, and left-stick directions are all held flags. `input.Reader`
  turns them into one-tile requests on a single shared 10 steps/s cadence: a new
  direction steps immediately, and holding it steps again every 0.1 s during
  normal frame rates. At most one step is emitted per frame, so below 10 FPS or
  after a stall missed whole steps are discarded, not replayed. The OS keyboard
  auto-repeat rate is not used, so holding two directions keeps both axes on the
  same cadence.
- Controller support is controller index 0 only, using its D-pad or left analog
  stick. Each stick axis has an independent `0.25` deadzone (`stick_deadzone`
  in `input.zig`, the tuning knob); non-finite axis values and a disconnected
  controller are neutral.
- Directions are independent flags. Opposing requests on one axis cancel, and
  holding both axes moves one tile diagonally on each axis. Duplicate bindings
  (say, key and D-pad both right) never multiply a step.
- Holding the left mouse button overrides keyboard and controller for that
  frame. Negative raw deltas accumulate in `f64`; whole `TILE_PX` steps become
  tile moves and the sub-tile remainder carries to later frames. A large drag
  can move several tiles at once, symmetrically in both directions.
- Any non-drag frame resets both remainders, so one gesture cannot leak into the
  next. A drag or a neutral frame also resets the held-direction cadence.
- There is no movement speed or fractional camera position: movement is
  discrete. `input.Reader` uses frame `dt` only to pace held steps. Both axes are
  validated and committed together. Non-finite drags and moves whose tile-center
  pixel cannot fit the `i32` world-pixel contract return
  `error.CoordinateOutOfBounds` without changing state.
- `input.zig` supplies the `FrameInput`; camera movement never polls devices.

**Planned follow camera:** a future player-follow could replace the direct pan
with a dead zone or lerp:

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
const frame = input_reader.read(rl.getFrameTime());  // devices -> data
try game_state.update(frame);                       // persistent state
const view = try camera.calculate(game_state.camera, vw, vh);
try game_state.streamChunks(view.chunks);           // residency only

rl.beginDrawing();
rendering.draw(&game_state, view);                  // read-only
rl.endDrawing();
```

`input_reader` is a long-lived `input.Reader` owned by `main`, outside the loop.
It keeps the held-direction cadence across frames; `FrameInput` itself is still
per-frame data passed to `GameState.update`.

`rendering.draw` uses `view.transform` for `beginMode2D` and `view.chunks` for
iteration. The renderer neither reads input nor mutates the camera or world.

---

## 7. Gotchas

1. **Draw UI outside `beginMode2D`.** Otherwise the HUD and minimap would pan
   with the world.
2. **`getMousePosition()` is screen space.** Convert with
   `getScreenToWorld2D` before comparing to world coords.
3. **Move in whole tiles and use integer zoom** or 32 px tiles shimmer. The
   camera target is always `tile * TILE_PX + TILE_PX/2`; there is no fractional
   pixel position to snap.
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

`Camera.applyInput` validates a candidate move before committing either axis:
the drag step is checked in `f64` before conversion, and the resulting tile
coordinate is checked in `i64` so `tile * TILE_PX + TILE_PX/2` cannot overflow. A
move whose tile-center pixel falls outside the `i32` range returns
`error.CoordinateOutOfBounds` atomically.

Tile coordinates stay exact within the supported world-pixel bounds, but the
Raylib transform is `f32`. Far from the origin, adjacent 32 px steps can round
to the same rendered pixel. That is the existing `f32` ceiling, not a tile-
movement bug. Origin rebasing (render relative to a nearby chunk while keeping
absolute tile coordinates authoritative) is the upgrade if it becomes visible;
it is not implemented.

The chunk check includes the prefetch ring: the visible range plus
`PREFETCH_MARGIN_CHUNKS` must fit the drawable chunk extent. This keeps
`range.expanded()`, chunk generation (`cx * CHUNK_TILES`), and rendering
(`cx * CHUNK_PX + CHUNK_PX`) overflow-free.

Violations return `error.CoordinateOutOfBounds` before any conversion,
streaming mutation, or draw. The error is **not** allocation pressure: only
`error.OutOfMemory` may be retried, while coordinate errors propagate out of the
frame loop rather than clamping or wrapping the camera silently.
