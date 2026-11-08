# Camera

How the view follows the player and turns world coordinates into screen pixels.

---

## 1. Two pieces

| Piece | Owns | Lives in |
|---|---|---|
| `Camera` (ours) | follow logic, dead zone, zoom, clamping | `src/game/camera.zig` |
| `rl.Camera2D` | the world→screen matrix | created fresh each frame |

raylib's camera is only a **transform**. It does not follow anything, does not cull, and is not the source of truth. We keep our own camera state so it can be logged, replayed, or driven by a spectator mode later.

---

## 2. The transform

raylib maps world pixels to screen pixels as:

```
screen = (world - target) * zoom + offset
```

With `offset = screen_center` and `target = player`, the player is always drawn in the middle of the window.

Three coordinate spaces, in order:

```
world tile (x,y)      world px (x*32, y*32)      screen px (sx, sy)
    i32                     f32                       f32
        ─── × TILE_PX ───►        ─── Camera2D ───►
```

Everything inside `beginMode2D` is drawn in **world px**. Everything outside is **screen px**.

---

## 3. Our camera

```zig
pub const Camera = struct {
    x: f32,                  // world px at screen center
    y: f32,
    zoom: f32 = 1,
    dead_zone: f32 = 80,     // player may move this far before scrolling

    pub fn update(self: *Camera, px: f32, py: f32) void {
        // dead zone: only move when the player leaves the box
        if (px > self.x + self.dead_zone) self.x = px - self.dead_zone;
        if (px < self.x - self.dead_zone) self.x = px + self.dead_zone;
        if (py > self.y + self.dead_zone) self.y = py - self.dead_zone;
        if (py < self.y - self.dead_zone) self.y = py + self.dead_zone;

        // pixel-art: snap to whole pixels so tiles do not shimmer
        self.x = @round(self.x);
        self.y = @round(self.y);
    }

    pub fn toRaylib(self: Camera, sw: f32, sh: f32) rl.Camera2D {
        return .{
            .target = .{ .x = self.x, .y = self.y },
            .offset = .{ .x = sw / 2, .y = sh / 2 },
            .rotation = 0,
            .zoom = self.zoom,
        };
    }
};
```

- Replace the dead-zone block with a lerp if you want smooth follow instead of a hard box.
- Keep `zoom` an **integer** for pixel art (1, 2, 3…). Fractional zoom + non-snapped target = blurry/shimmering tiles.

---

## 4. Culling from the camera

The camera is also how we decide which chunks to load and draw:

```zig
const rc = cam.toRaylib(sw, sh);

const tl = rl.getScreenToWorld2D(.{ .x = 0, .y = 0 }, rc);
const br = rl.getScreenToWorld2D(.{ .x = sw, .y = sh }, rc);

const tx0 = @divFloor(@as(i32, @intFromFloat(tl.x)), TILE_PX);
const tx1 = @divFloor(@as(i32, @intFromFloat(br.x)), TILE_PX);
const ty0 = @divFloor(@as(i32, @intFromFloat(tl.y)), TILE_PX);
const ty1 = @divFloor(@as(i32, @intFromFloat(br.y)), TILE_PX);

const cx0 = chunkOf(tx0 - 1);   // 1 tile of slack: partial chunks on the edge
const cx1 = chunkOf(tx1 + 1);
const cy0 = chunkOf(ty0 - 1);
const cy1 = chunkOf(ty1 + 1);
```

Works unchanged under zoom, which is the reason to use `getScreenToWorld2D` instead of hand-rolled math.

---

## 5. Mouse → tile

Needed for targeting, hover highlight, and the hoe preview:

```zig
const m = rl.getScreenToWorld2D(rl.getMousePosition(), rc);
const tx = @divFloor(@as(i32, @intFromFloat(m.x)), TILE_PX);
const ty = @divFloor(@as(i32, @intFromFloat(m.y)), TILE_PX);
```

Again, `@divFloor` — truncating division breaks on negative coordinates.

---

## 6. Frame order

```zig
cam.update(player_px.x, player_px.y);
const rc = cam.toRaylib(sw, sh);

const view = cullChunks(rc, sw, sh);   // load + evict chunks
processInput(rc);                      // mouse -> tile

rl.beginMode2D(rc);
drawChunks(view);                      // world px
drawActors();                          // world px, y-sorted
rl.endMode2D();

drawUi();                              // screen px
drawNameTags(rc);                      // getWorldToScreen2D for each actor
```

---

## 7. Gotchas

1. **Draw UI outside `beginMode2D`.** Otherwise the inventory scrolls with the world.
2. **`getMousePosition()` is screen space.** Always convert with `getScreenToWorld2D` before comparing to world coords.
3. **Snap the camera target and use integer zoom** or 32 px tiles shimmer.
4. **Culling still needs the world rect.** The camera does not cull for you; it only gives you the rect cheaply.
5. **Chunk textures are blitted in world coords** (`cx * CHUNK_PX`), never in chunk-local coords, once `beginMode2D` is active.
6. **Camera state is ours, not raylib's.** Never read `target` back out of `rl.Camera2D` to make gameplay decisions.

---

## 8. Coordinate bounds

World pixels and the transformed viewport corners must stay representable as
`i32`, and a chunk must stay drawable once its full `CHUNK_PX` extent is added:

```
world px:    -2147483648 .. 2147483647        (exclusive upper bound 2^31)
chunk index: -4194304 .. 4194302               (512 px chunks)
chunk px:     cx * CHUNK_PX  and  cx * CHUNK_PX + CHUNK_PX
```

Validate `f32` coordinates in `f64` with a **half-open** upper bound. The
largest `f32` below `2^31` is `2147483520`; `@as(f32, @floatFromInt(maxInt(i32)))`
rounds to `2147483648`, so an `f32` comparison would accept a value that
`@intFromFloat` rejects. NaN and ±Infinity fail the same check.

The chunk check includes the prefetch ring: the visible range plus
`PREFETCH_MARGIN_CHUNKS` must fit the drawable chunk extent. This keeps
`range.expanded()`, chunk generation (`cx * CHUNK_TILES`), and rendering
(`cx * CHUNK_PX + CHUNK_PX`) overflow-free.

Violations return `error.CoordinateOutOfBounds` before any conversion,
streaming mutation, or draw. The error is **not** allocation pressure: only
`error.OutOfMemory` may be retried, while coordinate errors propagate out of the
frame loop rather than clamping or wrapping the camera silently.

