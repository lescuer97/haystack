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

pub const Camera = struct {
    x: f32 = 0,
    y: f32 = 0,
    speed: f32 = 420,

    /// Apply one frame of already-collected input. Mouse drag overrides the
    /// keyboard; directions are applied one at a time in the original order so
    /// opposing keys keep the original sequential f32 rounding. There is no
    /// diagonal speed normalisation. Snapping happens every frame so the tile
    /// grid does not shimmer.
    pub fn applyInput(self: *Camera, frame: input.FrameInput, dt: f32) void {
        if (frame.dragging) {
            // Drag to pan: the world follows the cursor, so the camera
            // moves by the negative mouse delta.
            self.x -= frame.drag_x;
            self.y -= frame.drag_y;
        } else {
            if (frame.pan_left) self.x -= self.speed * dt;
            if (frame.pan_right) self.x += self.speed * dt;
            if (frame.pan_up) self.y -= self.speed * dt;
            if (frame.pan_down) self.y += self.speed * dt;
        }

        // Pixel art: whole-pixel camera, otherwise the tile grid shimmers.
        self.x = @round(self.x);
        self.y = @round(self.y);
    }

    /// Build the Raylib transform for this camera and window size.
    pub fn raylib(self: Camera, vw: f32, vh: f32) rl.Camera2D {
        return .{
            .offset = .{ .x = vw / 2, .y = vh / 2 },
            .target = .{ .x = self.x, .y = self.y },
            .rotation = 0,
            .zoom = 1,
        };
    }

    /// Chunk under the camera target. `visibleRange` has already validated the
    /// target, so this conversion is safe whenever a frame has a `View`.
    pub fn chunkX(self: Camera) i32 {
        return @divFloor(@as(i32, @intFromFloat(self.x)), world.CHUNK_PX);
    }

    pub fn chunkY(self: Camera) i32 {
        return @divFloor(@as(i32, @intFromFloat(self.y)), world.CHUNK_PX);
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
    // The camera target is converted to i32 directly by the HUD and minimap,
    // so reject non-finite / out-of-i32 targets even before transforming.
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

test "opposing pan keys keep original sequential f32 order at large coordinates" {
    // 2^26, where the f32 spacing is 8 px. A collapsed axis would report no
    // movement; the original loop ran the subtract then the add separately.
    const boundary: f32 = -67108864;
    const dt: f32 = 1.0 / 120.0;

    var sequential = Camera{ .x = boundary, .y = boundary };
    sequential.applyInput(.{
        .pan_left = true,
        .pan_right = true,
        .pan_up = true,
        .pan_down = true,
    }, dt);

    // Original order: x -= step; x += step; y -= step; y += step; then round.
    // At this magnitude the pair rounds to boundary + 4 on both axes.
    try std.testing.expectEqual(@as(f32, -67108860), sequential.x);
    try std.testing.expectEqual(@as(f32, -67108860), sequential.y);

    // No requests, by contrast, leave the camera at the boundary.
    var idle = Camera{ .x = boundary, .y = boundary };
    idle.applyInput(.{}, dt);
    try std.testing.expectEqual(boundary, idle.x);
    try std.testing.expectEqual(boundary, idle.y);
}
