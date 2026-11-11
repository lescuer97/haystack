//! Camera state, input-driven movement, the Raylib transform, and the
//! temporary view calculated from it.
//!
//! Persistent camera state is ours (`Camera`). `rl.Camera2D` is only a
//! world→screen matrix built fresh each frame. The visible chunk range is also
//! temporary: it is derived from the camera and the window size, handed to the
//! world for streaming, then discarded.

const std = @import("std");
const rl = @import("raylib");

const input = @import("input.zig");
const world = @import("world.zig");

// ── coordinate validation ────────────────────────────────────────────────────

/// Every world pixel and view corner we convert must fit in an i32. The
/// positive edge is exclusive: the largest f32 below 2^31 is 2147483520, but
/// `@as(f32, @floatFromInt(maxInt(i32)))` rounds to 2147483648, so a naive f32
/// comparison would accept a value that `@intFromFloat` rejects. Compare
/// widened in f64 instead. NaN and infinities are rejected by this range check.
const MIN_WORLD_PX: f64 = -2147483648.0;
const MAX_WORLD_PX_EXCLUSIVE: f64 = 2147483648.0;

fn pixelInI32Bounds(v: f32) bool {
    const wide: f64 = @as(f64, v);
    return wide >= MIN_WORLD_PX and wide < MAX_WORLD_PX_EXCLUSIVE;
}

// ── camera state ─────────────────────────────────────────────────────────────

/// True when a drag step (already in whole tiles) can be converted to `i32`.
/// NaN fails both comparisons; infinities fail the range.
fn deltaFitsI32(v: f64) bool {
    const min: f64 = @floatFromInt(std.math.minInt(i32));
    const max: f64 = @floatFromInt(std.math.maxInt(i32));
    return v >= min and v <= max;
}

/// True when the tile's center pixel (`tile * TILE_PX + TILE_PX/2`) fits the
/// i32 world-pixel contract. `tile` is i64 so the product cannot overflow.
fn tileCenterFitsI32(tile: i64) bool {
    const px = tile * @as(i64, world.TILE_PX) + world.TILE_PX / 2;
    return px >= std.math.minInt(i32) and px <= std.math.maxInt(i32);
}

pub const Camera = struct {
    /// Authoritative position in whole world tiles, not pixels.
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
        var dx: i32 = 0;
        var dy: i32 = 0;

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
            if (!deltaFitsI32(step_x) or !deltaFitsI32(step_y))
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
        if (!tileCenterFitsI32(target_x) or !tileCenterFitsI32(target_y))
            return error.CoordinateOutOfBounds;

        self.tile_x = @intCast(target_x);
        self.tile_y = @intCast(target_y);
        self.drag_remainder_x = remainder_x;
        self.drag_remainder_y = remainder_y;
    }

    /// Forget a partially accumulated drag. A modal menu consumes the frames
    /// that would otherwise release the gesture, so the update boundary calls
    /// this instead of letting the remainder replay after the menu closes.
    pub fn resetDrag(self: *Camera) void {
        self.drag_remainder_x = 0;
        self.drag_remainder_y = 0;
    }

    /// Build the Raylib transform for this camera and window size. The target
    /// is the tile's center pixel (`tile * TILE_PX + TILE_PX/2`), widened to
    /// i64 before the f32 conversion.
    ///
    /// ponytail: tile coordinates are exact, but the Raylib target is f32, so
    /// adjacent tile steps far from the origin can round to the same pixel. The
    /// upgrade, if that becomes visible, is origin rebasing (render relative to
    /// a nearby chunk while keeping absolute tile coordinates authoritative);
    /// it is not implemented.
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
    /// World→screen transform handed to `beginMode2D`.
    transform: rl.Camera2D,
    /// Chunks intersecting the window, including prefetch validation.
    chunks: world.ChunkRange,
};

pub fn calculate(cam: Camera, vw: f32, vh: f32) world.CoordinateError!View {
    const transform = cam.raylib(vw, vh);
    return .{
        .transform = transform,
        .chunks = try visibleRange(transform, vw, vh),
    };
}

/// Chunks intersecting the camera view. Returns
/// `error.CoordinateOutOfBounds` before any f32→i32 conversion that would
/// trap or before a chunk range whose prefetch ring cannot be represented.
pub fn visibleRange(cam: rl.Camera2D, vw: f32, vh: f32) world.CoordinateError!world.ChunkRange {
    // The camera target is converted to i32 by the visible-range math, so
    // reject non-finite / out-of-i32 targets even before transforming.
    if (!pixelInI32Bounds(cam.target.x) or !pixelInI32Bounds(cam.target.y))
        return error.CoordinateOutOfBounds;

    const tl = rl.getScreenToWorld2D(.{ .x = 0, .y = 0 }, cam);
    const br = rl.getScreenToWorld2D(.{ .x = vw, .y = vh }, cam);

    const tl_x = @floor(tl.x);
    const tl_y = @floor(tl.y);
    const br_x = @ceil(br.x);
    const br_y = @ceil(br.y);
    if (!pixelInI32Bounds(tl_x) or !pixelInI32Bounds(tl_y) or
        !pixelInI32Bounds(br_x) or !pixelInI32Bounds(br_y))
        return error.CoordinateOutOfBounds;

    const tx0 = @divFloor(@as(i32, @intFromFloat(tl_x)), world.TILE_PX);
    const ty0 = @divFloor(@as(i32, @intFromFloat(tl_y)), world.TILE_PX);
    const tx1 = @divFloor(@as(i32, @intFromFloat(br_x)), world.TILE_PX);
    const ty1 = @divFloor(@as(i32, @intFromFloat(br_y)), world.TILE_PX);

    const range = world.ChunkRange{
        .cx0 = @divFloor(tx0, world.CHUNK_TILES),
        .cy0 = @divFloor(ty0, world.CHUNK_TILES),
        .cx1 = @divFloor(tx1, world.CHUNK_TILES),
        .cy1 = @divFloor(ty1, world.CHUNK_TILES),
    };

    // The prefetch ring is loaded and generated too, so it must stay within
    // the drawable chunk extent; this also makes `expanded()` safe.
    try world.validateChunkRange(range, world.PREFETCH_MARGIN_CHUNKS);
    return range;
}

// ── tests ────────────────────────────────────────────────────────────────────

// A camera shaped like `Camera.raylib`, so tests exercise the same transform as
// the frame loop without initializing a raylib window.
fn testCamera(x: f32, y: f32, vw: f32, vh: f32) rl.Camera2D {
    return .{
        .offset = .{ .x = vw / 2, .y = vh / 2 },
        .target = .{ .x = x, .y = y },
        .rotation = 0,
        .zoom = 1,
    };
}

test "pixel bounds reject non-finite and f32 rounding at the i32 edges" {
    // NaN fails both comparisons; infinities fail the half-open range.
    try std.testing.expect(!pixelInI32Bounds(std.math.nan(f32)));
    try std.testing.expect(!pixelInI32Bounds(std.math.inf(f32)));
    try std.testing.expect(!pixelInI32Bounds(-std.math.inf(f32)));

    // Largest f32 below 2^31 is representable and converts to i32.
    try std.testing.expect(pixelInI32Bounds(2147483520));
    // 2^31 exactly is not: this is the rounding trap that a naive f32
    // comparison against `@floatFromInt(maxInt(i32))` would accept.
    try std.testing.expect(!pixelInI32Bounds(2147483648));
    // i32 min is valid and exactly representable; the next f32 below is not.
    try std.testing.expect(pixelInI32Bounds(-2147483648));
    try std.testing.expect(!pixelInI32Bounds(-2147483904));
}

test "visibleRange rejects non-finite camera targets on both axes" {
    const invalid = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };
    for (invalid) |value| {
        try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(value, 0, 1000, 640), 1000, 640));
        try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(0, value, 1000, 640), 1000, 640));
    }
}

test "visibleRange rejects the reproduced i32 overflow boundaries" {
    // These are the values from the Debug reproduction. 2147483008 fits in
    // i32 and its transformed corner (2147483520) still fits, but the chunk it
    // maps to has a full +CHUNK_PX extent past i32; 2147483648 already rounds
    // past the i32 conversion.
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(2147483008, 0, 1000, 640), 1000, 640));
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(-2147483008, 0, 1000, 640), 1000, 640));
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(2147483648, 0, 1000, 640), 1000, 640));
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(-2147483648, 0, 1000, 640), 1000, 640));

    // Same boundaries on Y, independently.
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(0, 2147483008, 1000, 640), 1000, 640));
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(0, -2147483008, 1000, 640), 1000, 640));
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(0, 2147483648, 1000, 640), 1000, 640));
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(0, -2147483648, 1000, 640), 1000, 640));
}

test "visibleRange validates transformed corners, not just the target" {
    // Target and top-left corner fit i32, but the far corner does not.
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(2000000000, 0, 1000000000, 0), 1000000000, 0));
    // Mirror: target and far corner fit, but the near corner is below i32 min.
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(-2000000000, 0, 1000000000, 0), 1000000000, 0));
}

test "visibleRange accepts ordinary and negative views" {
    const origin = try visibleRange(testCamera(0, 0, 1000, 640), 1000, 640);
    try std.testing.expectEqual(world.ChunkRange{ .cx0 = -1, .cy0 = -1, .cx1 = 0, .cy1 = 0 }, origin);

    // -10000 +/- 400 px and -20000 +/- 300 px, floor-divided per tile/chunk.
    const negative = try visibleRange(testCamera(-10000, -20000, 800, 600), 800, 600);
    try std.testing.expectEqual(world.ChunkRange{ .cx0 = -21, .cy0 = -40, .cx1 = -19, .cy1 = -39 }, negative);
}

test "visibleRange accepts the furthest prefetch-safe chunk edges" {
    // Visible chunk 4194300 leaves exactly the 2-chunk margin up to 4194302.
    const max_cam: f32 = @floatFromInt(4194300 * world.CHUNK_PX);
    const max_view = try visibleRange(testCamera(max_cam, 0, 0, 0), 0, 0);
    try std.testing.expectEqual(@as(i32, 4194300), max_view.cx0);
    try std.testing.expectEqual(@as(i32, 4194300), max_view.cx1);

    const too_far_pos: f32 = @floatFromInt(4194301 * world.CHUNK_PX);
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(too_far_pos, 0, 0, 0), 0, 0));

    // Mirror on the negative side.
    const min_cam: f32 = @floatFromInt(-4194302 * world.CHUNK_PX);
    const min_view = try visibleRange(testCamera(0, min_cam, 0, 0), 0, 0);
    try std.testing.expectEqual(@as(i32, -4194302), min_view.cy0);
    try std.testing.expectEqual(@as(i32, -4194302), min_view.cy1);

    const too_far_neg: f32 = @floatFromInt(-4194303 * world.CHUNK_PX);
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(0, too_far_neg, 0, 0), 0, 0));
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

    // One tile right moves the target by exactly TILE_PX.
    const stepped = cam.raylib(800, 600);
    try std.testing.expectEqual(@as(f32, 48), stepped.target.x);
    try std.testing.expectEqual(@as(f32, 16), stepped.target.y);

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

    // Regression: the real Camera → View path targets the tile center, not the
    // pixel-only test helper above.
    cam.tile_x = -17;
    cam.tile_y = -33;
    const view = try calculate(cam, 0, 0);
    const expected_x: f32 = @floatFromInt(-17 * world.TILE_PX + world.TILE_PX / 2);
    const expected_y: f32 = @floatFromInt(-33 * world.TILE_PX + world.TILE_PX / 2);
    try std.testing.expectEqual(expected_x, view.transform.target.x);
    try std.testing.expectEqual(expected_y, view.transform.target.y);
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

test "tile coordinates stay exact for large one-tile steps" {
    // 2^25 tiles is 2^30 px, where an f32 can no longer represent every 32 px
    // step. The authoritative tile coordinate still advances exactly.
    const big: i32 = 1 << 25;
    var cam = Camera{ .tile_x = big, .tile_y = -big };

    try cam.applyInput(.{ .right = true, .down = true });
    try std.testing.expectEqual(big + 1, cam.tile_x);
    try std.testing.expectEqual(-big + 1, cam.tile_y);

    try cam.applyInput(.{ .left = true, .up = true });
    try std.testing.expectEqual(big, cam.tile_x);
    try std.testing.expectEqual(-big, cam.tile_y);
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

    // Finite, but far more tiles than an i32 delta can hold.
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
    var edge = Camera{ .tile_x = 67108863, .tile_y = 0 };
    try std.testing.expectError(error.CoordinateOutOfBounds, edge.applyInput(.{ .right = true, .down = true }));
    try std.testing.expectEqual(@as(i32, 67108863), edge.tile_x);
    try std.testing.expectEqual(@as(i32, 0), edge.tile_y);

    // i32 min tile center is exactly representable; one past it is not.
    var low = Camera{ .tile_x = -67108864, .tile_y = 0 };
    try std.testing.expectError(error.CoordinateOutOfBounds, low.applyInput(.{ .left = true }));
    try std.testing.expectEqual(@as(i32, -67108864), low.tile_x);
}
