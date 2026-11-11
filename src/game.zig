//! Persistent game state and the rules that apply one frame of input to it.
//!
//! `GameState` owns everything that survives a frame: the world cache, the
//! camera, and settings. Nothing here polls hardware. `main` collects a
//! `FrameInput` and hands it in, so the same update logic can be driven by a
//! test, a replay, or a future network source without a window.

const std = @import("std");
const builtin = @import("builtin");

const camera = @import("camera.zig");
const input = @import("input.zig");
const world = @import("world.zig");
const menu = @import("menu.zig");

/// Debug view toggles. Tiles are never filled with colour; only the grid lines
/// and chunk borders are drawn. On by default in Debug builds.
pub const DebugSettings = struct {
    tile_grid: bool = builtin.mode == .debug,
    chunk_borders: bool = builtin.mode == .debug,
};

/// Player-configurable settings. Debug view toggles live under `.debug`.
pub const Settings = struct { debug: DebugSettings = .{} };

pub const GameState = struct {
    world: world.World,
    camera: camera.Camera,
    menu: menu.Menu,
    settings: Settings,

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
            .menu = .{ .opened = false, .currentPage = .Main },
            .settings = .{ .debug = .{} },
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
    ///
    /// Menu input is modal. While the menu is open, and on the frame that opens
    /// or closes it, neither the camera nor the debug toggles see the frame.
    /// Any half-finished drag is discarded so it cannot replay when the menu
    /// closes.
    pub fn update(self: *GameState, frame: input.FrameInput) world.CoordinateError!void {
        if (self.menu.applyInput(frame)) {
            self.camera.resetDrag();
            return;
        }

        try self.camera.applyInput(frame);

        if (frame.toggle_grid) self.settings.debug.tile_grid = !self.settings.debug.tile_grid;
        if (frame.toggle_borders) self.settings.debug.chunk_borders = !self.settings.debug.chunk_borders;
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

    try game_state.update(.{ .right = true });
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, 0), game_state.camera.tile_y);

    try game_state.update(.{ .up = true });
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, -1), game_state.camera.tile_y);

    // Holding the mouse overrides the direction sources for this frame. A 32 px
    // left drag moves the camera one tile right; the pan request is ignored.
    try game_state.update(.{
        .right = true,
        .down = true,
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

    const grid_before = game_state.settings.debug.tile_grid;
    const borders_before = game_state.settings.debug.chunk_borders;
    try game_state.update(.{ .toggle_grid = true, .toggle_borders = true });
    try std.testing.expectEqual(!grid_before, game_state.settings.debug.tile_grid);
    try std.testing.expectEqual(!borders_before, game_state.settings.debug.chunk_borders);
}

test "settings default to nested debug defaults" {
    const settings = Settings{};
    try std.testing.expectEqual(builtin.mode == .debug, settings.debug.tile_grid);
    try std.testing.expectEqual(builtin.mode == .debug, settings.debug.chunk_borders);

    var game_state = try GameState.init(std.testing.allocator, 1000, 640);
    defer game_state.deinit();
    try std.testing.expectEqual(builtin.mode == .debug, game_state.settings.debug.tile_grid);
    try std.testing.expectEqual(builtin.mode == .debug, game_state.settings.debug.chunk_borders);
}

test "debug toggles flip independently and idle frames preserve them" {
    var game_state = try GameState.init(std.testing.allocator, 1000, 640);
    defer game_state.deinit();

    const grid_before = game_state.settings.debug.tile_grid;
    const borders_before = game_state.settings.debug.chunk_borders;

    // Turning the grid on leaves the chunk border toggle untouched.
    try game_state.update(.{ .toggle_grid = true });
    try std.testing.expectEqual(!grid_before, game_state.settings.debug.tile_grid);
    try std.testing.expectEqual(borders_before, game_state.settings.debug.chunk_borders);

    // An idle frame preserves both toggles.
    try game_state.update(.{});
    try std.testing.expectEqual(!grid_before, game_state.settings.debug.tile_grid);
    try std.testing.expectEqual(borders_before, game_state.settings.debug.chunk_borders);

    // Turning the border toggle on leaves the already-flipped grid untouched.
    try game_state.update(.{ .toggle_borders = true });
    try std.testing.expectEqual(!grid_before, game_state.settings.debug.tile_grid);
    try std.testing.expectEqual(!borders_before, game_state.settings.debug.chunk_borders);
}

test "menu input blocks camera and debug toggles, including transition frames" {
    var game_state = try GameState.init(std.testing.allocator, 1000, 640);
    defer game_state.deinit();

    const grid_before = game_state.settings.debug.tile_grid;
    const borders_before = game_state.settings.debug.chunk_borders;

    // The frame that opens the menu cannot also pan, drag, or toggle.
    try game_state.update(.{
        .escape_clicked = true,
        .right = true,
        .dragging = true,
        .drag_x = -32,
        .toggle_grid = true,
        .toggle_borders = true,
    });
    try std.testing.expect(game_state.menu.opened);
    try std.testing.expectEqual(@as(i32, 0), game_state.camera.tile_x);
    try std.testing.expectEqual(grid_before, game_state.settings.debug.tile_grid);
    try std.testing.expectEqual(borders_before, game_state.settings.debug.chunk_borders);
    try std.testing.expectEqual(@as(f64, 0), game_state.camera.drag_remainder_x);

    // While open, world input and toggles are ignored.
    try game_state.update(.{ .left = true, .toggle_grid = true, .toggle_borders = true });
    try std.testing.expectEqual(@as(i32, 0), game_state.camera.tile_x);
    try std.testing.expectEqual(grid_before, game_state.settings.debug.tile_grid);
    try std.testing.expectEqual(borders_before, game_state.settings.debug.chunk_borders);

    // The closing frame is still modal: the escape edge and any leftover drag
    // or direction must not leak into the world.
    try game_state.update(.{
        .escape_clicked = true,
        .right = true,
        .dragging = true,
        .drag_x = -64,
        .toggle_grid = true,
        .toggle_borders = true,
    });
    try std.testing.expect(!game_state.menu.opened);
    try std.testing.expectEqual(@as(i32, 0), game_state.camera.tile_x);
    try std.testing.expectEqual(grid_before, game_state.settings.debug.tile_grid);
    try std.testing.expectEqual(borders_before, game_state.settings.debug.chunk_borders);
    try std.testing.expectEqual(@as(f64, 0), game_state.camera.drag_remainder_x);

    // The next ordinary frame works again.
    try game_state.update(.{ .right = true, .toggle_grid = true });
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_x);
    try std.testing.expectEqual(!grid_before, game_state.settings.debug.tile_grid);
}

test "menu navigation and confirm frames stay modal through Resume" {
    var game_state = try GameState.init(std.testing.allocator, 1000, 640);
    defer game_state.deinit();

    const grid_before = game_state.settings.debug.tile_grid;
    const borders_before = game_state.settings.debug.chunk_borders;

    // The opening frame consumes the held arrow too, so the selection stays on
    // the first row and the camera does not pan.
    try game_state.update(.{
        .escape_clicked = true,
        .down = true,
        .right = true,
        .toggle_grid = true,
    });
    try std.testing.expect(game_state.menu.opened);
    try std.testing.expectEqual(@as(usize, 0), game_state.menu.selected_index);
    try std.testing.expectEqual(@as(i32, 0), game_state.camera.tile_x);
    try std.testing.expectEqual(grid_before, game_state.settings.debug.tile_grid);

    // Navigating to Resume cannot pan, drag, or toggle. The drag remainder is
    // discarded so it cannot replay after the menu closes.
    try game_state.update(.{
        .down = true,
        .dragging = true,
        .drag_x = -32,
        .toggle_borders = true,
    });
    try std.testing.expectEqual(@as(usize, 1), game_state.menu.selected_index);
    try std.testing.expectEqual(@as(i32, 0), game_state.camera.tile_y);
    try std.testing.expectEqual(@as(f64, 0), game_state.camera.drag_remainder_x);
    try std.testing.expectEqual(borders_before, game_state.settings.debug.chunk_borders);

    // Confirming Resume closes the menu, and that closing frame is modal too.
    try game_state.update(.{
        .confirm = true,
        .dragging = true,
        .drag_x = -64,
        .toggle_grid = true,
    });
    try std.testing.expect(!game_state.menu.opened);
    try std.testing.expectEqual(@as(i32, 0), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, 0), game_state.camera.tile_y);
    try std.testing.expectEqual(@as(f64, 0), game_state.camera.drag_remainder_x);
    try std.testing.expectEqual(grid_before, game_state.settings.debug.tile_grid);

    // The next ordinary frame works again.
    try game_state.update(.{ .right = true });
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_x);
}

test "the same direction field drives the camera or the menu by mode" {
    var game_state = try GameState.init(std.testing.allocator, 1000, 640);
    defer game_state.deinit();

    // Closed menu: Down pans the world and leaves the highlight alone.
    try game_state.update(.{ .down = true });
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_y);
    try std.testing.expectEqual(@as(usize, 0), game_state.menu.selected_index);

    // The opening frame is modal, so its direction is consumed by the menu.
    try game_state.update(.{ .escape_clicked = true, .down = true });
    try std.testing.expect(game_state.menu.opened);
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_y);
    try std.testing.expectEqual(@as(usize, 0), game_state.menu.selected_index);

    // The same field now moves the highlight instead of the camera.
    try game_state.update(.{ .down = true });
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_y);
    try std.testing.expectEqual(@as(usize, 1), game_state.menu.selected_index);
}
