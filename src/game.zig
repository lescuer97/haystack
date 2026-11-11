//! Persistent game state and the rules that apply one frame of input to it.
//!
//! `GameState` owns everything that survives a frame: the world cache, the
//! camera, and debug settings. Nothing here polls hardware. `main` collects a
//! `FrameInput` and hands it in, so the same update logic can be driven by a
//! test, a replay, or a future network source without a window.

const std = @import("std");
const builtin = @import("builtin");

const camera = @import("camera.zig");
const input = @import("input.zig");
const world = @import("world.zig");

/// Debug view toggles. Tiles are never filled with colour; only the grid lines
/// and chunk borders are drawn. On by default in Debug builds.
pub const DebugSettings = struct {
    tile_grid: bool = builtin.mode == .debug,
    chunk_borders: bool = builtin.mode == .debug,
};

pub const GameState = struct {
    world: world.World,
    camera: camera.Camera,
    debug: DebugSettings,

    /// Build the persistent state and size the world cache for the initial
    /// window. The view is calculated from the starting camera, then discarded;
    /// only its chunk count is needed here.
    pub fn init(alloc: std.mem.Allocator, initial_vw: f32, initial_vh: f32) !GameState {
        const cam = camera.Camera{};
        const initial_view = try camera.calculate(cam, initial_vw, initial_vh);
        const initial_ring = initial_view.chunks.expanded(world.PREFETCH_MARGIN_CHUNKS);
        const initial_capacity = @max(
            world.MIN_PREHEATED_CHUNKS,
            @as(usize, @intCast(initial_ring.count())),
        );

        return .{
            .world = try world.World.init(alloc, initial_capacity),
            .camera = cam,
            .debug = .{},
        };
    }

    /// Release every world buffer. `main` calls this before closing the window.
    pub fn deinit(self: *GameState) void {
        self.world.deinit();
    }

    /// Apply one frame of already-collected input to persistent state.
    /// Camera movement is in `camera.zig`; debug toggles are edge-triggered
    /// requests carried by `FrameInput`. A coordinate error propagates without
    /// applying the toggles.
    pub fn update(self: *GameState, frame: input.FrameInput) world.CoordinateError!void {
        try self.camera.applyInput(frame);

        if (frame.toggle_grid) self.debug.tile_grid = !self.debug.tile_grid;
        if (frame.toggle_borders) self.debug.chunk_borders = !self.debug.chunk_borders;
    }

    /// Load visible chunks first, then prefetch; keep whatever is available on
    /// allocation failure and retry next frame. A coordinate error is a program
    /// invariant, so it propagates instead of being retried.
    pub fn streamChunks(self: *GameState, view: world.ChunkRange) world.StreamError!void {
        const was_under_pressure = self.world.underMemoryPressure();
        self.world.stream(view) catch |err| switch (err) {
            error.OutOfMemory => {
                // Log once per pressure episode rather than flooding at 120 Hz.
                if (!was_under_pressure) {
                    std.log.warn(
                        "Chunk streaming incomplete: {s}; prioritizing visible chunks",
                        .{@errorName(err)},
                    );
                }
            },
            error.CoordinateOutOfBounds => return err,
        };
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

test "supplied input moves the camera by tiles, drag wins, and toggles flip" {
    var game_state = try GameState.init(std.testing.allocator, 1000, 640);
    defer game_state.deinit();

    try game_state.update(.{ .pan_right = true });
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, 0), game_state.camera.tile_y);

    try game_state.update(.{ .pan_up = true });
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, -1), game_state.camera.tile_y);

    // Holding the mouse overrides the direction sources for this frame. A 32 px
    // left drag moves the camera one tile right; the pan request is ignored.
    try game_state.update(.{
        .pan_right = true,
        .pan_down = true,
        .dragging = true,
        .drag_x = -32,
        .drag_y = 0,
    });
    try std.testing.expectEqual(@as(i32, 2), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, -1), game_state.camera.tile_y);

    // No input leaves the camera in place.
    try game_state.update(.{});
    try std.testing.expectEqual(@as(i32, 2), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, -1), game_state.camera.tile_y);

    const grid_before = game_state.debug.tile_grid;
    const borders_before = game_state.debug.chunk_borders;
    try game_state.update(.{ .toggle_grid = true, .toggle_borders = true });
    try std.testing.expectEqual(!grid_before, game_state.debug.tile_grid);
    try std.testing.expectEqual(!borders_before, game_state.debug.chunk_borders);
}
