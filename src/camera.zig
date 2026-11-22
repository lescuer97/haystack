//! Camera state, input-driven movement, the Raylib transform, and the
//! temporary view calculated from it.
//!
//! Persistent camera state is ours (`Camera`). `rl.Camera2D` is only a
//! camera-local→screen matrix derived each tick. The loop caches it and the visible
//! chunk range with the viewport; neither belongs to persistent GameState.

const std = @import("std");
const rl = @import("raylib");
const protocol = @import("shared").protocol;

const input = @import("input.zig");
const world = @import("world.zig");

const min_tile: i64 = std.math.minInt(i32);
const max_tile: i64 = std.math.maxInt(i32);
const end_tile = max_tile + 1;
const half_tile_px = world.TILE_PX / 2;

/// Camera-local pixel edge for an absolute tile coordinate. Subtract before
/// converting to f32 so adjacent tiles remain distinct near the camera.
pub fn relativePixel(tile: i64, origin: i32) i64 {
    return (tile - origin) * world.TILE_PX;
}

pub fn relativeTileCenter(tile_x: i32, tile_y: i32, origin_x: i32, origin_y: i32) rl.Vector2 {
    return .{
        .x = @floatFromInt(relativePixel(tile_x, origin_x) + half_tile_px),
        .y = @floatFromInt(relativePixel(tile_y, origin_y) + half_tile_px),
    };
}

pub const Camera = struct {
    /// Absolute tile at the view target, and origin of the local pixel transform.
    tile_x: i32 = 0,
    tile_y: i32 = 0,

    /// Sub-tile mouse-drag remainder in pixels. Only used while dragging and
    /// reset on release, so one gesture cannot leak into the next.
    drag_remainder_x: f64 = 0,
    drag_remainder_y: f64 = 0,

    /// Apply one frame of already-collected input. Mouse drag overrides the
    /// keyboard and controller. Each emitted direction request moves exactly
    /// one tile on its axis; opposing requests cancel, so a diagonal request
    /// moves one tile on both axes. Drag pixels accumulate until they make
    /// whole `TILE_PX` steps, and a large drag can move several tiles. Both
    /// axes are validated and committed together or not at all.
    pub fn applyInput(self: *Camera, frame: input.FrameInput) world.CoordinateError!void {
        var dx: i64 = 0;
        var dy: i64 = 0;

        var remainder_x = self.drag_remainder_x;
        var remainder_y = self.drag_remainder_y;

        if (frame.dragging) {
            // Drag to pan: the world follows the cursor, so the camera
            // moves by the negative mouse delta.
            const delta_x: f64 = -@as(f64, frame.drag_x);
            const delta_y: f64 = -@as(f64, frame.drag_y);
            if (!std.math.isFinite(delta_x) or !std.math.isFinite(delta_y))
                return error.CoordinateOutOfBounds;

            remainder_x += delta_x;
            remainder_y += delta_y;
            if (!std.math.isFinite(remainder_x) or !std.math.isFinite(remainder_y))
                return error.CoordinateOutOfBounds;

            // Whole tiles only; the sub-tile part is kept for later frames.
            const tile_px: f64 = @floatFromInt(world.TILE_PX);
            const step_x = @trunc(remainder_x / tile_px);
            const step_y = @trunc(remainder_y / tile_px);
            // Even a legal move can cross more than maxInt(i32) tiles.
            const max_step: f64 = @floatFromInt(max_tile - min_tile);
            if (@abs(step_x) > max_step or @abs(step_y) > max_step)
                return error.CoordinateOutOfBounds;

            dx = @intFromFloat(step_x);
            dy = @intFromFloat(step_y);
            remainder_x -= step_x * tile_px;
            remainder_y -= step_y * tile_px;
        } else {
            // A released gesture must not leave a sub-tile remainder behind.
            remainder_x = 0;
            remainder_y = 0;

            if (frame.left) dx -= 1;
            if (frame.right) dx += 1;
            if (frame.up) dy -= 1;
            if (frame.down) dy += 1;
        }

        // Validate in i64 before committing either axis so a failed move
        // cannot leave the camera half-updated.
        const target_x = @as(i64, self.tile_x) + dx;
        const target_y = @as(i64, self.tile_y) + dy;
        try self.setTarget(target_x, target_y);
        self.drag_remainder_x = remainder_x;
        self.drag_remainder_y = remainder_y;
    }

    pub fn setTarget(self: *Camera, x: i64, y: i64) world.CoordinateError!void {
        if (x < min_tile or x > max_tile or y < min_tile or y > max_tile)
            return error.CoordinateOutOfBounds;
        self.tile_x = @intCast(x);
        self.tile_y = @intCast(y);
    }

    /// Forget a partially accumulated drag. A modal menu consumes the frames
    /// that would otherwise release the gesture, so the update boundary calls
    /// this instead of letting the remainder replay after the menu closes.
    pub fn resetDrag(self: *Camera) void {
        self.drag_remainder_x = 0;
        self.drag_remainder_y = 0;
    }

    /// Draw positions relative to `tile_x/y`. The local origin tile starts at
    /// (0, 0); its center is the target at every absolute camera position.
    pub fn raylib(_: Camera, vw: f32, vh: f32) rl.Camera2D {
        return .{
            .offset = .{ .x = vw / 2, .y = vh / 2 },
            .target = .{ .x = half_tile_px, .y = half_tile_px },
            .rotation = 0,
            .zoom = 1,
        };
    }

    /// Chunk under the camera target. Movement has already validated the tile
    /// coordinate, so this division cannot overflow.
    pub fn chunkX(self: Camera) i32 {
        return @divFloor(self.tile_x, world.CHUNK_TILES);
    }

    pub fn chunkY(self: Camera) i32 {
        return @divFloor(self.tile_y, world.CHUNK_TILES);
    }
};

/// A calculated frame view. Not persistent state: rebuild it from the camera
/// and window size every frame.
pub const View = struct {
    /// Camera-local→screen transform handed to `beginMode2D`.
    transform: rl.Camera2D,
    /// Absolute chunks intersecting the visible tiles.
    chunks: world.ChunkRange,
    tiles: TileRange,
    minimap: ?MinimapView,
};

pub const MinimapView = struct {
    size_px: f32,
    radius_tiles: i32,
    chunks: world.ChunkRange,
};

fn minimapView(cam: Camera, vw: f32, vh: f32) ?MinimapView {
    const size = @floor(@min(192, vw / 3, vh / 3));
    if (size < 32) return null;
    // Cover the longer viewport axis plus room for partial chunks and prefetch.
    const extra_tiles = (world.PREFETCH_MARGIN_CHUNKS + 1) * world.CHUNK_TILES;
    const radius_tiles = @ceil(@as(f64, @max(vw, vh)) / (2 * world.TILE_PX)) + extra_tiles;
    // Oversized maps will fail residency validation. Bound the conversion first.
    const radius: i32 = @intFromFloat(@min(radius_tiles, max_tile));
    const center = TileRange{
        .x0 = cam.tile_x,
        .y0 = cam.tile_y,
        .x1 = @as(i64, cam.tile_x) + 1,
        .y1 = @as(i64, cam.tile_y) + 1,
    };
    return .{ .size_px = size, .radius_tiles = radius, .chunks = center.expanded(radius).chunks() };
}

/// Absolute, half-open tile bounds. The final tile ends at maxInt(i32) + 1.
pub const TileRange = struct {
    x0: i64,
    y0: i64,
    x1: i64,
    y1: i64,

    pub fn expanded(self: TileRange, padding: i32) TileRange {
        std.debug.assert(padding >= 0);
        return .{
            .x0 = @max(min_tile, self.x0 - padding),
            .y0 = @max(min_tile, self.y0 - padding),
            .x1 = @min(end_tile, self.x1 + padding),
            .y1 = @min(end_tile, self.y1 + padding),
        };
    }

    fn chunks(self: TileRange) world.ChunkRange {
        return .{
            .cx0 = @intCast(@divFloor(self.x0, world.CHUNK_TILES)),
            .cy0 = @intCast(@divFloor(self.y0, world.CHUNK_TILES)),
            .cx1 = @intCast(@divFloor(self.x1 - 1, world.CHUNK_TILES)),
            .cy1 = @intCast(@divFloor(self.y1 - 1, world.CHUNK_TILES)),
        };
    }
};

pub fn calculate(cam: Camera, vw: f32, vh: f32) world.CoordinateError!View {
    const tiles = try visibleTiles(cam, vw, vh);
    const chunks = tiles.chunks();
    const minimap = minimapView(cam, vw, vh);
    try world.validateChunkRange(world.residencyRange(chunks, if (minimap) |map| map.chunks else null), 0);
    return .{ .transform = cam.raylib(vw, vh), .chunks = chunks, .tiles = tiles, .minimap = minimap };
}

/// Absolute chunks intersecting the view, with a streamable clipped prefetch ring.
pub fn visibleRange(cam: Camera, vw: f32, vh: f32) world.CoordinateError!world.ChunkRange {
    const chunks = (try visibleTiles(cam, vw, vh)).chunks();
    try world.validateChunkRange(chunks, world.PREFETCH_MARGIN_CHUNKS);
    return chunks;
}

fn validViewport(vw: f32, vh: f32) bool {
    return std.math.isFinite(vw) and std.math.isFinite(vh) and vw >= 0 and vh >= 0;
}

// Inverse of the unrotated zoom-1 Camera.raylib transform, in local tiles.
fn localTileAt(pixel: f32, extent: f32) f64 {
    return (@as(f64, pixel) + (half_tile_px - @as(f64, extent) / 2)) / world.TILE_PX;
}

fn clampedTile(origin: i32, offset: f64) i64 {
    const tile = @as(f64, @floatFromInt(origin)) + offset;
    return @intFromFloat(std.math.clamp(tile, @as(f64, @floatFromInt(min_tile)), @as(f64, @floatFromInt(end_tile))));
}

fn visibleTiles(cam: Camera, vw: f32, vh: f32) world.CoordinateError!TileRange {
    if (!validViewport(vw, vh)) return error.CoordinateOutOfBounds;
    return .{
        .x0 = clampedTile(cam.tile_x, @floor(localTileAt(0, vw))),
        .y0 = clampedTile(cam.tile_y, @floor(localTileAt(0, vh))),
        .x1 = clampedTile(cam.tile_x, @ceil(localTileAt(vw, vw))),
        .y1 = clampedTile(cam.tile_y, @ceil(localTileAt(vh, vh))),
    };
}

/// Convert a screen point into an absolute tile. Points outside the tile world
/// or with non-finite coordinates have no tile.
pub fn screenToTile(cam: Camera, vw: f32, vh: f32, point: rl.Vector2) ?protocol.Location {
    if (!validViewport(vw, vh)) return null;
    const x = @as(f64, @floatFromInt(cam.tile_x)) + @floor(localTileAt(point.x, vw));
    const y = @as(f64, @floatFromInt(cam.tile_y)) + @floor(localTileAt(point.y, vh));
    if (!(x >= min_tile and x < end_tile and y >= min_tile and y < end_tile)) return null;
    return .{ .x = @intFromFloat(x), .y = @intFromFloat(y) };
}

// ── tests ────────────────────────────────────────────────────────────────────

test "visible tiles and chunks exclude exact far edges" {
    const cam = Camera{ .tile_x = -1, .tile_y = 0 };
    const exact = try calculate(cam, 32, 32);
    try std.testing.expectEqual(TileRange{ .x0 = -1, .y0 = 0, .x1 = 0, .y1 = 1 }, exact.tiles);
    try std.testing.expectEqual(world.ChunkRange{ .cx0 = -1, .cy0 = 0, .cx1 = -1, .cy1 = 0 }, exact.chunks);
    try std.testing.expectEqual(TileRange{ .x0 = -2, .y0 = -1, .x1 = 1, .y1 = 2 }, (try calculate(cam, 33, 33)).tiles);
}

test "visible range accepts ordinary and negative views" {
    const origin = try visibleRange(.{}, 1000, 640);
    try std.testing.expectEqual(world.ChunkRange{ .cx0 = -1, .cy0 = -1, .cx1 = 1, .cy1 = 0 }, origin);
    const negative = try visibleRange(.{ .tile_x = -313, .tile_y = -625 }, 800, 600);
    try std.testing.expectEqual(world.ChunkRange{ .cx0 = -21, .cy0 = -40, .cx1 = -19, .cy1 = -39 }, negative);
}

test "views and minimaps clip at both tile-world corners" {
    var cam: Camera = .{};
    try cam.setTarget(min_tile, max_tile);
    const view = try calculate(cam, 1000, 640);
    try std.testing.expectEqual(TileRange{ .x0 = min_tile, .y0 = max_tile - 10, .x1 = min_tile + 17, .y1 = end_tile }, view.tiles);
    try std.testing.expectEqual(world.ChunkRange{
        .cx0 = protocol.min_chunk,
        .cy0 = protocol.max_chunk,
        .cx1 = protocol.min_chunk + 1,
        .cy1 = protocol.max_chunk,
    }, view.chunks);
    const map = view.minimap.?;
    try std.testing.expectEqual(@as(i32, 64), map.radius_tiles);
    try std.testing.expectEqual(world.ChunkRange{
        .cx0 = protocol.min_chunk,
        .cy0 = protocol.max_chunk - 4,
        .cx1 = protocol.min_chunk + 4,
        .cy1 = protocol.max_chunk,
    }, map.chunks);

    try cam.setTarget(max_tile, min_tile);
    const odd = try calculate(cam, 999, 639);
    try std.testing.expectEqual(end_tile, odd.tiles.x1);
    try std.testing.expectEqual(min_tile, odd.tiles.y0);
    try std.testing.expectEqual(protocol.max_chunk, odd.minimap.?.chunks.cx1);
    try std.testing.expectEqual(protocol.min_chunk, odd.minimap.?.chunks.cy0);
    const padded = odd.tiles.expanded(3);
    try std.testing.expectEqual(end_tile, padded.x1);
    try std.testing.expectEqual(min_tile, padded.y0);
}

test "view validation rejects invalid dimensions and unstreamable ranges" {
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |value| {
        try std.testing.expectError(error.CoordinateOutOfBounds, calculate(.{}, value, 640));
        try std.testing.expectError(error.CoordinateOutOfBounds, calculate(.{}, 1000, value));
    }
    const huge = std.math.floatMax(f32);
    const cam: Camera = .{ .tile_x = @intCast(min_tile), .tile_y = @intCast(max_tile) };
    try std.testing.expectEqual(TileRange{ .x0 = min_tile, .y0 = min_tile, .x1 = end_tile, .y1 = end_tile }, try visibleTiles(cam, huge, huge));
    try std.testing.expectError(error.CoordinateOutOfBounds, calculate(cam, huge, huge));
    // The visible strip fits on its own, but its square minimap does not.
    const wide = 100_000_000;
    _ = try visibleRange(cam, wide, 100);
    try std.testing.expectError(error.CoordinateOutOfBounds, calculate(cam, wide, 100));
}

test "screen picking floors negative offsets and rejects positions beyond the world" {
    const ordinary: Camera = .{ .tile_x = -17, .tile_y = -16 };
    try std.testing.expectEqual(protocol.Location{ .x = -18, .y = -17 }, screenToTile(ordinary, 801, 601, .{ .x = 384, .y = 284 }).?);
    try std.testing.expectEqual(protocol.Location{ .x = -17, .y = -16 }, screenToTile(ordinary, 801, 601, .{ .x = 384.5, .y = 284.5 }).?);

    const corner: Camera = .{ .tile_x = @intCast(min_tile), .tile_y = @intCast(max_tile) };
    try std.testing.expectEqual(protocol.Location{ .x = @intCast(min_tile), .y = @intCast(max_tile) }, screenToTile(corner, 1000, 640, .{ .x = 484, .y = 335.99 }).?);
    try std.testing.expectEqual(protocol.Location{ .x = @intCast(min_tile + 1), .y = @intCast(max_tile - 1) }, screenToTile(corner, 1000, 640, .{ .x = 516, .y = 303.99 }).?);
    for ([_]rl.Vector2{
        .{ .x = 483.99, .y = 320 },
        .{ .x = 500, .y = 336 },
        .{ .x = std.math.nan(f32), .y = 320 },
        .{ .x = 500, .y = std.math.floatMax(f32) },
    }) |point| try std.testing.expect(screenToTile(corner, 1000, 640, point) == null);
    try std.testing.expect(screenToTile(corner, 1000, std.math.inf(f32), .{ .x = 500, .y = 320 }) == null);
}

test "direction requests move one tile and cancel opposites" {
    var cam = Camera{};

    // Startup target is the center of tile (0,0).
    const start = cam.raylib(800, 600);
    try std.testing.expectEqual(@as(f32, 16), start.target.x);
    try std.testing.expectEqual(@as(f32, 16), start.target.y);

    try cam.applyInput(.{ .right = true });
    try std.testing.expectEqual(@as(i32, 1), cam.tile_x);
    try std.testing.expectEqual(@as(i32, 0), cam.tile_y);

    // The local target is unchanged; the previous tile is now one tile left.
    const stepped = cam.raylib(800, 600);
    try std.testing.expectEqual(start.target, stepped.target);
    try std.testing.expectEqual(@as(i64, -world.TILE_PX), relativePixel(0, cam.tile_x));

    try cam.applyInput(.{ .up = true });
    try std.testing.expectEqual(@as(i32, 1), cam.tile_x);
    try std.testing.expectEqual(@as(i32, -1), cam.tile_y);

    // A diagonal request moves one tile on each axis.
    try cam.applyInput(.{ .right = true, .down = true });
    try std.testing.expectEqual(@as(i32, 2), cam.tile_x);
    try std.testing.expectEqual(@as(i32, 0), cam.tile_y);

    // Opposing requests on an axis cancel; no input is a no-op.
    try cam.applyInput(.{ .left = true, .right = true, .up = true, .down = true });
    try std.testing.expectEqual(@as(i32, 2), cam.tile_x);
    try std.testing.expectEqual(@as(i32, 0), cam.tile_y);
    try cam.applyInput(.{});
    try std.testing.expectEqual(@as(i32, 2), cam.tile_x);
    try std.testing.expectEqual(@as(i32, 0), cam.tile_y);

    // Any non-drag frame also clears a stale drag remainder.
    cam.drag_remainder_x = 17;
    cam.drag_remainder_y = -9;
    try cam.applyInput(.{ .left = true });
    try std.testing.expectEqual(@as(f64, 0), cam.drag_remainder_x);
    try std.testing.expectEqual(@as(f64, 0), cam.drag_remainder_y);
    try std.testing.expectEqual(@as(i32, 1), cam.tile_x);

    // A held direction arrives as a one-tile request on repeated frames (the
    // input reader paces them): each one steps a whole tile, and a frame with
    // no request leaves the camera where it is.
    try cam.applyInput(.{ .right = true });
    try std.testing.expectEqual(@as(i32, 2), cam.tile_x);
    try cam.applyInput(.{ .right = true });
    try std.testing.expectEqual(@as(i32, 3), cam.tile_x);
    try cam.applyInput(.{});
    try std.testing.expectEqual(@as(i32, 3), cam.tile_x);
    try std.testing.expectEqual(@as(i32, 0), cam.tile_y);
}

test "tile steps cross negative chunk boundaries with floor division" {
    var cam = Camera{ .tile_x = -16, .tile_y = -16 };
    try std.testing.expectEqual(@as(i32, -1), cam.chunkX());
    try std.testing.expectEqual(@as(i32, -1), cam.chunkY());

    try cam.applyInput(.{ .left = true, .up = true });
    try std.testing.expectEqual(@as(i32, -2), cam.chunkX());
    try std.testing.expectEqual(@as(i32, -2), cam.chunkY());

    try cam.applyInput(.{ .right = true, .down = true });
    try std.testing.expectEqual(@as(i32, -1), cam.chunkX());
    try std.testing.expectEqual(@as(i32, -1), cam.chunkY());

    cam.tile_x = -17;
    cam.tile_y = -33;
    const view = try calculate(cam, 0, 0);
    try std.testing.expectEqual(rl.Vector2{ .x = 16, .y = 16 }, view.transform.target);
    try std.testing.expectEqual(
        world.ChunkRange{ .cx0 = -2, .cy0 = -3, .cx1 = -2, .cy1 = -3 },
        view.chunks,
    );
}

test "drag accumulates sub-tile pixels and moves whole tiles" {
    var cam = Camera{};

    // A 20 px right drag moves the camera 20 px left: no whole tile yet.
    try cam.applyInput(.{ .dragging = true, .drag_x = 20 });
    try std.testing.expectEqual(@as(i32, 0), cam.tile_x);
    try std.testing.expectEqual(@as(f64, -20), cam.drag_remainder_x);

    // Another 20 px completes a -40 px move: one tile with -8 px left over.
    try cam.applyInput(.{ .dragging = true, .drag_x = 20 });
    try std.testing.expectEqual(@as(i32, -1), cam.tile_x);
    try std.testing.expectEqual(@as(f64, -8), cam.drag_remainder_x);

    // Reversing 40 px cancels the remainder and steps back one tile.
    try cam.applyInput(.{ .dragging = true, .drag_x = -40 });
    try std.testing.expectEqual(@as(i32, 0), cam.tile_x);
    try std.testing.expectEqual(@as(f64, 0), cam.drag_remainder_x);

    // A large drag moves several tiles at once, symmetrically.
    try cam.applyInput(.{ .dragging = true, .drag_x = -100 });
    try std.testing.expectEqual(@as(i32, 3), cam.tile_x);
    try std.testing.expectEqual(@as(f64, 4), cam.drag_remainder_x);
    try cam.applyInput(.{ .dragging = true, .drag_x = 100 });
    try std.testing.expectEqual(@as(i32, 0), cam.tile_x);
    try std.testing.expectEqual(@as(f64, 0), cam.drag_remainder_x);
}

test "drag resets between gestures and wins over the keyboard" {
    var cam = Camera{};

    // Leave a sub-tile remainder, then release the mouse.
    try cam.applyInput(.{ .dragging = true, .drag_x = 10 });
    try std.testing.expectEqual(@as(f64, -10), cam.drag_remainder_x);
    try cam.applyInput(.{});
    try std.testing.expectEqual(@as(f64, 0), cam.drag_remainder_x);

    // The next gesture starts from zero: 20 px alone is still sub-tile.
    try cam.applyInput(.{ .dragging = true, .drag_x = 20 });
    try std.testing.expectEqual(@as(i32, 0), cam.tile_x);

    // Dragging overrides the keyboard for the same frame.
    var override = Camera{};
    try override.applyInput(.{
        .right = true,
        .down = true,
        .dragging = true,
        .drag_x = 32,
    });
    try std.testing.expectEqual(@as(i32, -1), override.tile_x);
    try std.testing.expectEqual(@as(i32, 0), override.tile_y);
}

test "one-tile steps and draw positions stay exact at both extremes" {
    var cam: Camera = .{ .tile_x = @intCast(max_tile), .tile_y = @intCast(min_tile) };
    const target = cam.raylib(800, 600).target;
    try std.testing.expectEqual(rl.Vector2{ .x = 16, .y = 16 }, target);
    try std.testing.expectEqual(target, relativeTileCenter(cam.tile_x, cam.tile_y, cam.tile_x, cam.tile_y));
    try std.testing.expectEqual(@as(i64, world.TILE_PX), relativePixel(end_tile, cam.tile_x));
    try std.testing.expectEqual(@as(i64, 1 << 37), relativePixel(end_tile, cam.tile_y));

    try cam.applyInput(.{ .left = true, .down = true });
    try std.testing.expectEqual(@as(i32, @intCast(max_tile - 1)), cam.tile_x);
    try std.testing.expectEqual(@as(i32, @intCast(min_tile + 1)), cam.tile_y);
    try std.testing.expectEqual(rl.Vector2{ .x = 48, .y = -16 }, relativeTileCenter(@intCast(max_tile), @intCast(min_tile), cam.tile_x, cam.tile_y));

    try cam.applyInput(.{ .right = true, .up = true });
    try std.testing.expectEqual(@as(i32, @intCast(max_tile)), cam.tile_x);
    try std.testing.expectEqual(@as(i32, @intCast(min_tile)), cam.tile_y);
}

test "drag can cross more than an i32 delta without overflowing" {
    var cam: Camera = .{ .tile_x = @intCast(min_tile), .tile_y = @intCast(max_tile) };
    const pixels: f32 = @floatFromInt(end_tile * world.TILE_PX);
    try cam.applyInput(.{ .dragging = true, .drag_x = -pixels, .drag_y = pixels });
    try std.testing.expectEqual(@as(i32, 0), cam.tile_x);
    try std.testing.expectEqual(@as(i32, -1), cam.tile_y);
    try std.testing.expectEqual(@as(f64, 0), cam.drag_remainder_x);
    try std.testing.expectEqual(@as(f64, 0), cam.drag_remainder_y);
}

test "invalid or unrepresentable movement is rejected without partial mutation" {
    const initial = Camera{
        .tile_x = 5,
        .tile_y = -7,
        .drag_remainder_x = 3,
        .drag_remainder_y = -4,
    };
    var cam = initial;

    // NaN and infinity in the raw drag.
    try std.testing.expectError(error.CoordinateOutOfBounds, cam.applyInput(.{ .dragging = true, .drag_x = std.math.nan(f32) }));
    try std.testing.expectError(error.CoordinateOutOfBounds, cam.applyInput(.{ .dragging = true, .drag_y = std.math.inf(f32) }));

    // Finite, but far more than the width of the tile world.
    try std.testing.expectError(error.CoordinateOutOfBounds, cam.applyInput(.{
        .dragging = true,
        .drag_x = -std.math.floatMax(f32),
    }));

    // Every rejection leaves both axes and both remainders untouched.
    try std.testing.expectEqual(initial.tile_x, cam.tile_x);
    try std.testing.expectEqual(initial.tile_y, cam.tile_y);
    try std.testing.expectEqual(initial.drag_remainder_x, cam.drag_remainder_x);
    try std.testing.expectEqual(initial.drag_remainder_y, cam.drag_remainder_y);

    // One axis overflowing rejects the whole move: y must not advance.
    const bounds = Camera{ .tile_x = @intCast(max_tile), .tile_y = @intCast(min_tile), .drag_remainder_x = 1 };
    var edge = bounds;
    try std.testing.expectError(error.CoordinateOutOfBounds, edge.applyInput(.{ .right = true, .down = true }));
    try std.testing.expectError(error.CoordinateOutOfBounds, edge.applyInput(.{ .dragging = true, .drag_x = 32, .drag_y = 32 }));
    try std.testing.expectError(error.CoordinateOutOfBounds, edge.setTarget(end_tile, 0));
    try std.testing.expectError(error.CoordinateOutOfBounds, edge.setTarget(0, min_tile - 1));
    try std.testing.expectEqual(bounds, edge);
}
