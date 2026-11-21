//! Persistent game state and the rules that apply one frame of input to it.
//!
//! `GameState` owns everything that survives a frame: the world cache, the
//! camera, player position and animation, and settings. Nothing here polls hardware. `main` collects a
//! `FrameInput` and hands it in, so the same update logic can be driven by a
//! test, a replay, or a future network source without a window.

const std = @import("std");
const builtin = @import("builtin");

const shared = @import("shared");
const Location = shared.protocol.Location;
const movement = shared.movement;
const camera = @import("camera.zig");
const input = @import("input.zig");
const world = @import("world.zig");
const menu = @import("menu.zig");
const player = @import("player.zig");
const settings_mod = @import("settings.zig");

pub const DebugSettings = settings_mod.DebugSettings;
pub const Settings = settings_mod.Settings;

pub const GameState = struct {
    world: world.World,
    camera: camera.Camera,
    player_pos: Location = movement.spawn,
    player_animation: player.Animation = .{},
    player_walking: bool = false,
    menu: menu.Menu,
    settings: Settings,

    /// Build the persistent state and size the world cache for the initial
    /// window. The view is calculated from the starting camera, then discarded;
    /// only its chunk count is needed here.
    pub fn init(alloc: std.mem.Allocator, initial_vw: f32, initial_vh: f32) !GameState {
        return initWithSettings(alloc, initial_vw, initial_vh, .{});
    }

    /// Build persistent state with settings loaded from disk or browser
    /// storage. `init` is the all-defaults convenience wrapper used by tests
    /// and by callers that have no configuration source.
    pub fn initWithSettings(
        alloc: std.mem.Allocator,
        initial_vw: f32,
        initial_vh: f32,
        settings: Settings,
    ) !GameState {
        const cam = camera.Camera{ .tile_x = movement.spawn.x, .tile_y = movement.spawn.y };
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
            .settings = settings,
        };
    }

    /// Release every world buffer. `main` calls this before closing the window.
    pub fn deinit(self: *GameState) void {
        self.world.deinit();
    }

    /// Apply one frame of already-collected input to persistent state.
    /// Step requests are checked before moving the player and following with the
    /// camera. A drag pans only the view. A coordinate error propagates without
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

        var facing_dx: i8 = 0;
        var facing_dy: i8 = 0;
        if (frame.dragging) {
            try self.camera.applyInput(frame);
            self.player_walking = false;
        } else {
            const dx = @as(i8, @intFromBool(frame.right)) - @as(i8, @intFromBool(frame.left));
            const dy = @as(i8, @intFromBool(frame.down)) - @as(i8, @intFromBool(frame.up));
            if (dx != 0 or dy != 0) {
                facing_dx = dx;
                facing_dy = dy;
                var next_camera = self.camera;
                try next_camera.setTarget(@as(i64, self.player_pos.x) + dx, @as(i64, self.player_pos.y) + dy);
                const next: Location = .{ .x = next_camera.tile_x, .y = next_camera.tile_y };
                self.player_walking = movement.canStep(self.player_pos, next);
                if (self.player_walking) {
                    self.player_pos = next;
                    self.camera = next_camera;
                }
            } else {
                facing_dx = frame.held_dx;
                facing_dy = frame.held_dy;
                if (facing_dx == 0 and facing_dy == 0) self.player_walking = false;
            }
            self.camera.resetDrag();
        }
        self.player_animation.update(frame.dt, facing_dx, facing_dy, self.player_walking, frame.action);

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

test "camera follows accepted player steps but drag only pans the view" {
    var game_state = try GameState.init(std.testing.allocator, 1000, 640);
    defer game_state.deinit();

    try game_state.update(.{ .right = true });
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, 0), game_state.camera.tile_y);

    try game_state.update(.{ .up = true });
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, -1), game_state.camera.tile_y);

    const before_drag = game_state.player_pos;
    // Holding the mouse overrides movement. A 32 px left drag pans right.
    try game_state.update(.{
        .right = true,
        .down = true,
        .dragging = true,
        .drag_x = -32,
        .drag_y = 0,
    });
    try std.testing.expectEqual(@as(i32, 2), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, -1), game_state.camera.tile_y);

    try std.testing.expectEqualDeep(before_drag, game_state.player_pos);

    // An in-place action doesn't pull a panned camera back to the player.
    try game_state.update(.{ .action = .axe });
    try std.testing.expectEqual(@as(i32, 2), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, -1), game_state.camera.tile_y);
    try std.testing.expectEqualDeep(before_drag, game_state.player_pos);

    // The next step starts at the player, not the panned camera.
    try game_state.update(.{ .right = true });
    try std.testing.expectEqualDeep(Location{ .x = 2, .y = -1 }, game_state.player_pos);
    try std.testing.expectEqual(game_state.player_pos.x, game_state.camera.tile_x);
    try std.testing.expectEqual(game_state.player_pos.y, game_state.camera.tile_y);

    const grid_before = game_state.settings.debug.tile_grid;
    const borders_before = game_state.settings.debug.chunk_borders;
    try game_state.update(.{ .toggle_grid = true, .toggle_borders = true });
    try std.testing.expectEqual(!grid_before, game_state.settings.debug.tile_grid);
    try std.testing.expectEqual(!borders_before, game_state.settings.debug.chunk_borders);
}

test "player walks between tile steps and the menu consumes action input" {
    var game_state = try GameState.init(std.testing.allocator, 1000, 640);
    defer game_state.deinit();

    try game_state.update(.{ .right = true, .held_dx = 1 });
    try game_state.update(.{ .held_dx = 1, .dt = 0.11 });
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, 32), game_state.player_animation.frame().x);

    const before = game_state.player_animation.frame();
    try game_state.update(.{ .escape_clicked = true, .action = .sword });
    try game_state.update(.{ .action = .axe, .dt = 0.25 });
    try game_state.update(.{ .escape_clicked = true, .action = .hoe });
    try std.testing.expectEqualDeep(before, game_state.player_animation.frame());

    try game_state.update(.{ .action = .water });
    try std.testing.expectEqual(player.Sheet.tools, game_state.player_animation.frame().sheet);
}

test "blocked steps leave player and panned camera in place without walking" {
    var game_state = try GameState.init(std.testing.allocator, 1000, 640);
    defer game_state.deinit();
    game_state.player_pos = .{ .x = 19, .y = 0 };
    try game_state.camera.setTarget(16, 0);

    try game_state.update(.{ .right = true, .held_dx = 1 });
    try game_state.update(.{ .held_dx = 1, .dt = 0.05 });
    try std.testing.expectEqualDeep(Location{ .x = 19, .y = 0 }, game_state.player_pos);
    try std.testing.expectEqual(@as(i32, 16), game_state.camera.tile_x);
    try std.testing.expect(!game_state.player_animation.walking);
    try std.testing.expectEqual(@as(i32, 32), game_state.player_animation.frame().y);

    try game_state.update(.{ .down = true });
    try std.testing.expectEqualDeep(Location{ .x = 19, .y = 1 }, game_state.player_pos);
    try std.testing.expectEqual(@as(i32, 19), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_y);
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
