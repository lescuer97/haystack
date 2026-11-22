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

pub const ToolbarLayout = struct {
    bounds: menu.Rect,
    hoe: menu.Rect,
};

pub fn toolbarLayout(viewport_w: f32, viewport_h: f32) ?ToolbarLayout {
    const width = 80;
    const height = 48;
    const margin = 8;
    const padding = 6;
    if (viewport_w < width + 2 * margin or viewport_h < height + 2 * margin) return null;

    const x = (viewport_w - width) / 2;
    const y = viewport_h - height - margin;
    return .{
        .bounds = .{ .x = x, .y = y, .width = width, .height = height },
        .hoe = .{ .x = x + padding, .y = y + padding, .width = width - 2 * padding, .height = height - 2 * padding },
    };
}

pub fn walletBadgeBounds(vw: f32, vh: f32) ?menu.Rect {
    const margin = 8;
    const width = 220;
    const height = 48;
    if (vw < width + 2 * margin) return null;

    var y = vh - height - margin;
    if (toolbarLayout(vw, vh)) |toolbar| {
        if (width + 2 * margin > toolbar.bounds.x) y = toolbar.bounds.y - margin - height;
    }
    if (y < margin) return null;
    return .{ .x = margin, .y = y, .width = width, .height = height };
}

pub const GameState = struct {
    world: world.World,
    camera: camera.Camera,
    player_pos: Location = movement.spawn,
    player_animation: player.Animation = .{},
    player_walking: bool = false,
    selected_tool: player.Tool = .hoe,
    ui_press_held: bool = false,
    menu: menu.Menu,
    settings: Settings,
    music_enabled: bool = true,
    music_unavailable: bool = false,
    show_debug_minimap: bool = false,
    show_debug_hud: bool = true,

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
        const initial_ring = world.residencyRange(initial_view.chunks, if (initial_view.minimap) |map| map.chunks else null);
        try world.validateChunkRange(initial_ring, 0);
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
    /// or closes it, neither the camera nor the gameplay hotkeys see the frame.
    /// Any half-finished drag is discarded so it cannot replay when the menu
    /// closes.
    pub fn update(self: *GameState, frame: input.FrameInput) world.CoordinateError!void {
        if (self.menu.applyInput(frame)) {
            if (self.menu.option_toggle) |action| {
                self.menu.option_toggle = null;
                switch (action) {
                    .toggle_music => self.music_enabled = !self.music_enabled,
                    .toggle_grid => self.settings.debug.tile_grid = !self.settings.debug.tile_grid,
                    .toggle_borders => self.settings.debug.chunk_borders = !self.settings.debug.chunk_borders,
                    .toggle_debug_minimap => self.show_debug_minimap = !self.show_debug_minimap,
                    .toggle_hud => self.show_debug_hud = !self.show_debug_hud,
                    else => unreachable,
                }
            }
            self.ui_press_held = frame.dragging;
            self.camera.resetDrag();
            return;
        }

        if (!frame.dragging or frame.clicked) self.ui_press_held = false;
        if (frame.clicked) {
            if (walletBadgeBounds(frame.viewport_w, frame.viewport_h)) |bounds| {
                if (bounds.contains(frame.pointer_x, frame.pointer_y)) {
                    self.menu.openWallet();
                    self.ui_press_held = frame.dragging;
                    self.camera.resetDrag();
                    return;
                }
            }
            if (toolbarLayout(frame.viewport_w, frame.viewport_h)) |layout| {
                self.ui_press_held = frame.dragging and layout.bounds.contains(frame.pointer_x, frame.pointer_y);
                if (layout.hoe.contains(frame.pointer_x, frame.pointer_y)) self.selected_tool = .hoe;
            }
        }

        var facing_dx: i8 = 0;
        var facing_dy: i8 = 0;
        if (frame.dragging) {
            if (self.ui_press_held) self.camera.resetDrag() else try self.camera.applyInput(frame);
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
    pub fn streamChunks(self: *GameState, view: camera.View) world.StreamError!void {
        const was_under_pressure = self.world.underMemoryPressure();
        self.world.streamWithMinimap(view.chunks, if (view.minimap) |map| map.chunks else null) catch |err| switch (err) {
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

test "wallet badge opens Wallet directly and consumes gameplay input" {
    for ([_]f32{ 320, 1000 }) |width| {
        var game = try GameState.init(std.testing.allocator, width, 640);
        defer game.deinit();
        const initial_camera = game.camera;
        const initial_pos = game.player_pos;
        const bounds = walletBadgeBounds(width, 640).?;
        var frame = input.FrameInput{
            .viewport_w = width,
            .pointer_x = bounds.x + 1,
            .pointer_y = bounds.y + 1,
        };
        try game.update(frame);
        try std.testing.expect(!game.menu.opened);

        frame.clicked = true;
        frame.confirm = true;
        frame.dragging = true;
        frame.drag_x = world.TILE_PX;
        frame.action = .hoe;
        frame.toggle_grid = true;
        const grid_before = game.settings.debug.tile_grid;
        try game.update(frame);
        try std.testing.expect(game.menu.opened and game.menu.currentPage == .Wallet);
        try std.testing.expect(game.menu.wallet.balance_dirty);
        try std.testing.expectEqual(@as(usize, 0), game.menu.selected_index);
        try std.testing.expectEqual(grid_before, game.settings.debug.tile_grid);
        try std.testing.expectEqual(@as(?player.Action, null), game.player_animation.action);
        try std.testing.expectEqualDeep(initial_pos, game.player_pos);
        try std.testing.expectEqualDeep(initial_camera, game.camera);

        try game.update(.{ .escape_clicked = true, .dragging = true });
        try game.update(.{ .dragging = true, .drag_x = world.TILE_PX });
        try std.testing.expect(!game.menu.opened);
        try std.testing.expectEqualDeep(initial_camera, game.camera);
    }
}

test "hoe starts selected and a toolbar press does not swing or pan" {
    var game = try GameState.init(std.testing.allocator, 1000, 640);
    defer game.deinit();
    try std.testing.expectEqual(player.Tool.hoe, game.selected_tool);
    const initial_camera_x = game.camera.tile_x;
    const layout = toolbarLayout(1000, 640).?;
    try std.testing.expectEqual(@as(f32, 500), layout.bounds.x + layout.bounds.width / 2);
    try std.testing.expectEqual(@as(f32, 632), layout.bounds.y + layout.bounds.height);

    try game.update(.{ .clicked = true, .dragging = true, .pointer_x = layout.hoe.x + 1, .pointer_y = layout.hoe.y + 1, .drag_x = world.TILE_PX });
    try std.testing.expect(game.ui_press_held);
    try game.update(.{ .dragging = true, .pointer_x = 20, .pointer_y = 20, .drag_x = world.TILE_PX });
    try std.testing.expectEqual(initial_camera_x, game.camera.tile_x);
    try std.testing.expectEqual(player.Tool.hoe, game.selected_tool);
    try std.testing.expectEqual(@as(?player.Action, null), game.player_animation.action);

    try game.update(.{});
    try game.update(.{ .clicked = true, .dragging = true, .pointer_x = 20, .pointer_y = 20, .drag_x = world.TILE_PX });
    try std.testing.expectEqual(initial_camera_x - 1, game.camera.tile_x);
    // A world drag crossing the toolbar is still a world drag.
    try game.update(.{ .dragging = true, .pointer_x = layout.hoe.x + 1, .pointer_y = layout.hoe.y + 1, .drag_x = world.TILE_PX });
    try std.testing.expectEqual(initial_camera_x - 2, game.camera.tile_x);
}

test "streaming covers the fixed minimap while panning across chunk boundaries" {
    var game_state = try GameState.init(std.testing.allocator, 1600, 400);
    defer game_state.deinit();
    for ([_]i32{ -17, -16, -1, 0, 15, 16 }) |x| {
        game_state.camera.tile_x = x;
        const view = try camera.calculate(game_state.camera, 1600, 400);
        const map = view.minimap.?.chunks;
        const prefetch = view.chunks.expanded(world.PREFETCH_MARGIN_CHUNKS);
        try std.testing.expect(map.cy0 < prefetch.cy0 and map.cy1 > prefetch.cy1);
        try game_state.streamChunks(view);
        var cy = map.cy0;
        while (cy <= map.cy1) : (cy += 1) {
            var cx = map.cx0;
            while (cx <= map.cx1) : (cx += 1) try std.testing.expect(game_state.world.get(cx, cy) != null);
        }
    }
}

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

test "Settings music checkbox toggles and keeps its value when the menu closes" {
    var game = try GameState.init(std.testing.allocator, 1000, 640);
    defer game.deinit();
    try std.testing.expect(game.music_enabled);

    try game.update(.{ .escape_clicked = true });
    try game.update(.{ .down = true });
    try game.update(.{ .down = true });
    try game.update(.{ .confirm = true });
    try std.testing.expectEqual(menu.MenuPage.Settings, game.menu.currentPage);
    try game.update(.{ .confirm = true });
    try std.testing.expect(!game.music_enabled);
    try game.update(.{ .escape_clicked = true });
    try std.testing.expect(!game.music_enabled);

    try game.update(.{ .escape_clicked = true });
    const settings_row = menu.calculateLayout(.Main, 1000, 640).items[2];
    try game.update(.{ .clicked = true, .pointer_x = settings_row.centerX(), .pointer_y = settings_row.centerY() });
    const music_row = menu.calculateLayout(.Settings, 1000, 640).items[0];
    try game.update(.{ .clicked = true, .pointer_x = music_row.centerX(), .pointer_y = music_row.centerY() });
    try std.testing.expect(game.music_enabled);
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

    // Wrap past Exit Game, then navigate to Resume. The drag remainder is
    // discarded so it cannot replay after the menu closes.
    try game_state.update(.{ .up = true });
    try game_state.update(.{
        .up = true,
        .dragging = true,
        .drag_x = -32,
        .toggle_borders = true,
    });
    const selected = game_state.menu.items()[game_state.menu.selected_index];
    try std.testing.expect(selected == .action and selected.action == .close_menu);
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

test "debug menu toggles overlays independently by keyboard and pointer" {
    var game_state = try GameState.init(std.testing.allocator, 1000, 640);
    defer game_state.deinit();

    const initial = game_state.settings.debug;
    const initial_minimap = game_state.show_debug_minimap;
    const initial_hud = game_state.show_debug_hud;
    try game_state.update(.{ .escape_clicked = true });
    try game_state.update(.{ .down = true, .confirm = true });
    try std.testing.expectEqual(menu.MenuPage.Debug, game_state.menu.currentPage);

    try game_state.update(.{ .confirm = true });
    try game_state.update(.{ .down = true, .confirm = true });
    try std.testing.expectEqual(!initial.tile_grid, game_state.settings.debug.tile_grid);
    try std.testing.expectEqual(!initial.chunk_borders, game_state.settings.debug.chunk_borders);

    try game_state.update(.{ .down = true, .confirm = true });
    try std.testing.expectEqual(!initial_minimap, game_state.show_debug_minimap);
    try std.testing.expectEqual(initial_hud, game_state.show_debug_hud);
    const hud = game_state.menu.layoutFor(1000, 640).items[3];
    try game_state.update(.{ .clicked = true, .pointer_x = hud.centerX(), .pointer_y = hud.centerY() });
    try std.testing.expectEqual(!initial_minimap, game_state.show_debug_minimap);
    try std.testing.expectEqual(!initial_hud, game_state.show_debug_hud);
    try game_state.update(.{ .confirm = true });
    try game_state.update(.{ .escape_clicked = true });
    try std.testing.expect(!game_state.menu.opened);
    try std.testing.expectEqual(!initial_minimap, game_state.show_debug_minimap);
    try std.testing.expectEqual(initial_hud, game_state.show_debug_hud);
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
