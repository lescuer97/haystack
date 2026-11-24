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
    slots: [player.Tool.slots.len]menu.Rect,
};

pub fn toolbarLayout(viewport_w: f32, viewport_h: f32) ?ToolbarLayout {
    const slot_width = 84;
    const height = 48;
    const margin = 8;
    const padding = 6;
    const width = player.Tool.slots.len * slot_width + (player.Tool.slots.len + 1) * padding;
    if (viewport_w < width + 2 * margin or viewport_h < height + 2 * margin) return null;

    const x = (viewport_w - width) / 2;
    const y = viewport_h - height - margin;
    var layout: ToolbarLayout = .{ .bounds = .{ .x = x, .y = y, .width = width, .height = height }, .slots = undefined };
    for (&layout.slots, 0..) |*slot, i| {
        slot.* = .{ .x = x + padding + @as(f32, @floatFromInt(i * (slot_width + padding))), .y = y + padding, .width = slot_width, .height = height - 2 * padding };
    }
    return layout;
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

pub const ToolMenuRow = struct { bounds: menu.Rect, name: menu.Rect, increase: menu.Rect, close: menu.Rect };

pub fn toolMenuRow(content: menu.Rect, index: usize) ToolMenuRow {
    const step = content.height * 0.26;
    const y = content.y + (@as(f32, @floatFromInt(index)) + 0.075) * step;
    const height = step * 0.75;
    const w = content.width;
    return .{
        .bounds = .{ .x = content.x, .y = y, .width = w, .height = height },
        .name = .{ .x = content.x, .y = y, .width = w * 0.33, .height = height },
        .increase = .{ .x = content.x + w * 0.33, .y = y, .width = w * 0.32, .height = height },
        .close = .{ .x = content.x + w * 0.65, .y = y, .width = w * 0.35, .height = height },
    };
}

pub const HoeFundingUi = struct {
    pub const Status = enum {
        checking,
        quote_failed,
        funding,
        opening,
        unavailable,
        recovery,

        pub fn text(self: Status) [:0]const u8 {
            return switch (self) {
                .checking => "Checking wallet and server...",
                .quote_failed => "Check wallet or mint",
                .funding => "Refilling...",
                .opening => "Opening channel...",
                .unavailable => "Refill unavailable",
                .recovery => "Recovery required",
            };
        }
    };

    pub const Controller = struct {
        status: ?Status = null,

        pub fn publish(self: *Controller, status: ?Status) bool {
            if (self.status == status) return false;
            self.status = status;
            return true;
        }

        pub fn canStart(self: Controller) bool {
            return switch (self.status orelse return true) {
                .quote_failed, .unavailable => true,
                else => false,
            };
        }
    };

    pub fn cutsText(cuts_left: ?u64, buf: *[64]u8) [:0]const u8 {
        return if (cuts_left) |count|
            std.mem.printSentinel(buf, "Cuts left: {d}", .{count}, 0) catch unreachable
        else
            "Cuts left: unknown";
    }
};

pub const HoeBalance = struct { capacity: u64, accepted: u64, stale: bool = false };

pub const HoeView = struct {
    status: enum { hidden, unavailable, checking, ready, pending, recovery, empty, settling, settled } = .hidden,
    cuts_left: ?u64 = null,
    server: ?HoeBalance = null,
    client: ?HoeBalance = null,
    payment_pending: bool = false,
    can_refill: bool = false,
    close_first: bool = false,
    top_up: ?struct { remaining: u64, fee_limit: u64 } = null,
    recovery_action: ?enum { review_funding, retry_settlement } = null,
    offer: ?struct { cuts: u64, debit: u64, resume_funding: bool = false } = null,
};

pub const ToolStates = [player.Tool.slots.len]struct {
    uses_left: ?u64 = null,
    has_channel: bool = false,
    refill_fee_limit: ?u64 = null,
};

pub const GameState = struct {
    world: world.World,
    camera: camera.Camera,
    player_pos: Location = movement.spawn,
    player_animation: player.Animation = .{},
    cut_feedback: @import("cut_feedback.zig").Feedback = .{},
    paid_hoe: struct {
        target: ?Location = null,
        click_origin: ?struct { x: f32, y: f32 } = null,
        refill_requested: bool = false,
        refill_large: bool = false,
        close_requested: bool = false,
        view: HoeView = .{},
    } = .{},
    player_walking: bool = false,
    selected_tool: player.Tool = .hoe,
    tool_states: ToolStates = @splat(.{}),
    hoe_funding: HoeFundingUi.Controller = .{},
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
        self.menu.wallet.clearPendingPrizes();
        self.world.deinit();
    }

    /// Apply one frame of already-collected input to persistent state.
    /// A direction request turns the player in place if they aren't already
    /// facing that way. Accepted steps move the player and camera together.
    /// A drag pans only the view, within the world bounds.
    ///
    /// Menu input is modal. While the menu is open, and on the frame that opens
    /// or closes it, neither the camera nor the gameplay hotkeys see the frame.
    /// Any half-finished drag is discarded so it cannot replay when the menu
    /// closes.
    pub fn update(self: *GameState, frame: input.FrameInput) world.CoordinateError!void {
        self.paid_hoe.target = null;
        self.prepareToolMenuControls(frame);
        if (self.menu.applyInput(frame)) {
            if (self.menu.tool_activation) |control| {
                self.menu.tool_activation = null;
                self.activateToolControl(control);
            }
            self.paid_hoe.click_origin = null;
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
        if (frame.right_clicked) if (toolbarLayout(frame.viewport_w, frame.viewport_h)) |layout| {
            for (layout.slots, player.Tool.slots) |slot, tool| {
                if (!slot.contains(frame.pointer_x, frame.pointer_y)) continue;
                self.selectTool(tool);
                self.menu.openTools();
                self.paid_hoe.click_origin = null;
                self.ui_press_held = frame.dragging;
                self.player_walking = false;
                self.camera.resetDrag();
                return;
            }
        };
        var aim_pointer = false;
        if (frame.clicked) {
            self.paid_hoe.click_origin = null;
            if (walletBadgeBounds(frame.viewport_w, frame.viewport_h)) |bounds| {
                if (bounds.contains(frame.pointer_x, frame.pointer_y)) {
                    self.menu.openWallet();
                    self.ui_press_held = frame.dragging;
                    self.camera.resetDrag();
                    return;
                }
            }
            if (toolbarLayout(frame.viewport_w, frame.viewport_h)) |layout| {
                if (layout.bounds.contains(frame.pointer_x, frame.pointer_y)) {
                    for (layout.slots, player.Tool.slots) |slot, tool| {
                        if (slot.contains(frame.pointer_x, frame.pointer_y)) self.selectTool(tool);
                    }
                    self.ui_press_held = frame.dragging;
                    self.player_walking = false;
                    self.camera.resetDrag();
                    return;
                }
            }
            if (!frame.right_clicked) {
                if (!frame.dragging) {
                    aim_pointer = true;
                } else if (frame.drag_x == 0 and frame.drag_y == 0) {
                    // Browser left press may become a camera pan. Only a
                    // stationary release may turn it into a paid action.
                    self.paid_hoe.click_origin = .{ .x = frame.pointer_x, .y = frame.pointer_y };
                }
            }
        }
        if (frame.select_tool) |tool| self.selectTool(tool);
        if (self.paid_hoe.click_origin) |origin| {
            if (frame.drag_x != 0 or frame.drag_y != 0 or frame.right_clicked or
                @abs(frame.pointer_x - origin.x) > 3 or @abs(frame.pointer_y - origin.y) > 3)
                self.paid_hoe.click_origin = null;
            if (!frame.dragging) {
                if (frame.released and self.paid_hoe.click_origin != null) aim_pointer = true;
                self.paid_hoe.click_origin = null;
            }
        }

        var facing_dx: i8 = 0;
        var facing_dy: i8 = 0;
        if (frame.dragging) {
            if (self.ui_press_held) {
                self.camera.resetDrag();
            } else {
                self.camera.applyInput(frame) catch self.camera.resetDrag();
            }
            self.player_walking = false;
        } else {
            const dx = @as(i8, @intFromBool(frame.right)) - @as(i8, @intFromBool(frame.left));
            const dy = @as(i8, @intFromBool(frame.down)) - @as(i8, @intFromBool(frame.up));
            if (dx != 0 or dy != 0) {
                facing_dx = dx;
                facing_dy = dy;
                self.player_walking = false;
                if (self.player_animation.faces(dx, dy)) {
                    var next_camera = self.camera;
                    if (next_camera.setTarget(@as(i64, self.player_pos.x) + dx, @as(i64, self.player_pos.y) + dy)) |_| {
                        const next: Location = .{ .x = next_camera.tile_x, .y = next_camera.tile_y };
                        self.player_walking = movement.canStepWith(self.player_pos, next, self);
                        if (self.player_walking) {
                            self.player_pos = next;
                            self.camera = next_camera;
                        }
                    } else |_| {}
                }
            } else if (frame.held_dx == 0 and frame.held_dy == 0) {
                self.player_walking = false;
            }
            self.camera.resetDrag();
        }
        self.player_animation.update(frame.dt, facing_dx, facing_dy, self.player_walking, null);
        if (aim_pointer) self.paid_hoe.target = self.pointerToolTarget(frame);
        if (frame.use_tool and !frame.dragging and self.paid_hoe.target == null) {
            self.paid_hoe.target = self.facingToolTarget();
        }

        if (frame.toggle_grid) self.settings.debug.tile_grid = !self.settings.debug.tile_grid;
        if (frame.toggle_borders) self.settings.debug.chunk_borders = !self.settings.debug.chunk_borders;
    }

    fn selectTool(self: *GameState, tool: player.Tool) void {
        if (self.selected_tool == tool) return;
        self.selected_tool = tool;
        self.paid_hoe.view = .{ .status = .checking };
    }

    fn pointerToolTarget(self: *const GameState, frame: input.FrameInput) ?Location {
        if (!(frame.pointer_x >= 0 and frame.pointer_x < frame.viewport_w and
            frame.pointer_y >= 0 and frame.pointer_y < frame.viewport_h)) return null;
        const center = camera.relativeTileCenter(self.player_pos.x, self.player_pos.y, self.camera.tile_x, self.camera.tile_y);
        const half_tile: f32 = world.TILE_PX / 2;
        const dx = frame.pointer_x - (frame.viewport_w / 2 + center.x - half_tile);
        const dy = frame.pointer_y - (frame.viewport_h / 2 + center.y - half_tile);
        if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return null;
        if (dx >= -half_tile and dx < half_tile and dy >= -half_tile and dy < half_tile) return null;
        // Aim along the dominant axis, regardless of distance or player facing.
        return self.adjacentToolTarget(if (@abs(dx) >= @abs(dy))
            .{ .x = if (dx < 0) -1 else 1, .y = 0 }
        else
            .{ .x = 0, .y = if (dy < 0) -1 else 1 });
    }

    fn facingToolTarget(self: *const GameState) ?Location {
        const offset: Location = switch (self.player_animation.facing) {
            .up => .{ .x = 0, .y = -1 },
            .down => .{ .x = 0, .y = 1 },
            .left => .{ .x = -1, .y = 0 },
            .right => .{ .x = 1, .y = 0 },
        };
        return self.adjacentToolTarget(offset);
    }

    fn adjacentToolTarget(self: *const GameState, offset: Location) ?Location {
        const tile: Location = .{
            .x = std.math.add(i32, self.player_pos.x, offset.x) catch return null,
            .y = std.math.add(i32, self.player_pos.y, offset.y) catch return null,
        };
        const addr = cutAddress(tile);
        const chunk = self.world.get(addr.area.cx0, addr.area.cy0) orelse return null;
        if (!chunk.cutsSynced() or chunk.tiles[addr.index] != self.selected_tool.protocolTool().terrain() or chunk.isCut(addr.index)) return null;
        return tile;
    }

    /// Cached visuals can survive invalidation; collision needs a current snapshot.
    pub fn isCleared(self: *const GameState, tile: Location) bool {
        const addr = cutAddress(tile);
        const chunk = self.world.get(addr.area.cx0, addr.area.cy0) orelse return false;
        return chunk.cutsSynced() and chunk.isCut(addr.index);
    }

    /// Legacy runtime entry point for a confirmed clear by any tool.
    pub fn applyHoeCut(self: *GameState, tile: Location) void {
        const addr = cutAddress(tile);
        const chunk = self.world.get(addr.area.cx0, addr.area.cy0) orelse return;
        // A cut confirmation cannot make a stale or newly loaded bitmap current.
        if (!chunk.cutsSynced()) return;
        const bits = chunk.cuts.?;
        var snapshot: shared.protocol.Snapshot = .{ .area = addr.area, .count = 1 };
        snapshot.chunks[0] = bits;
        snapshot.chunks[0][addr.index / 8] |= @as(u8, 1) << @as(u3, @intCast(addr.index % 8));
        self.world.applyCuts(&snapshot);
    }

    fn cutAddress(tile: Location) struct { area: world.ChunkRange, index: usize } {
        const cx = @divFloor(tile.x, world.CHUNK_TILES);
        const cy = @divFloor(tile.y, world.CHUNK_TILES);
        return .{
            .area = .{ .cx0 = cx, .cx1 = cx, .cy0 = cy, .cy1 = cy },
            .index = @intCast(@mod(tile.y, world.CHUNK_TILES) * world.CHUNK_TILES + @mod(tile.x, world.CHUNK_TILES)),
        };
    }

    fn affordableToolUses(self: *const GameState, tool: player.Tool) ?u64 {
        const balance = self.menu.wallet.balance_msat orelse return null;
        const state = self.tool_states[@backingInt(tool.protocolTool())];
        return (balance -| (state.refill_fee_limit orelse 0)) / tool.protocolTool().priceMsat();
    }

    pub fn reconcileSelectedToolUses(self: *GameState) void {
        const view = self.paid_hoe.view;
        const state = &self.tool_states[@backingInt(self.selected_tool.protocolTool())];
        if (view.payment_pending) {
            state.uses_left = null;
        } else if (view.cuts_left) |uses| {
            state.uses_left = uses;
        } else switch (view.status) {
            .unavailable, .empty, .settled => state.uses_left = 0,
            else => {},
        }
    }

    pub const TopUpPlan = struct { added: u64, capacity: u64, max_debit: u64 };

    pub fn topUpPlan(self: *const GameState, tool: player.Tool, large: bool) ?TopUpPlan {
        if (tool != self.selected_tool) return null;
        const preview = self.paid_hoe.view.top_up orelse return null;
        const wallet_balance = self.menu.wallet.balance_msat orelse return null;
        const added = if (large) shared.protocol.large_tool_refill_cuts else shared.protocol.hoe_refill_cuts;
        const total = preview.remaining + added;
        if (total > shared.protocol.max_tool_channel_cuts) return null;
        const price = tool.protocolTool().priceMsat();
        const capacity = total * price;
        const limit = capacity + preview.fee_limit;
        if (wallet_balance < added * price + preview.fee_limit) return null;
        return .{ .added = added, .capacity = capacity, .max_debit = limit };
    }

    pub fn toolIncreaseLimit(self: *const GameState, tool: player.Tool) ?u64 {
        if (tool == self.selected_tool) {
            if (self.paid_hoe.view.top_up != null) return if (self.topUpPlan(tool, false)) |plan| plan.added else 0;
            if (self.paid_hoe.view.offer) |offer| return offer.cuts;
        }
        const affordable = self.affordableToolUses(tool) orelse return null;
        return @min(shared.protocol.hoe_refill_cuts, affordable);
    }

    pub fn showLargeRefill(self: *const GameState, tool: player.Tool) bool {
        if (self.hasToolChannel(tool)) return self.topUpPlan(tool, true) != null;
        if (tool == self.selected_tool and (self.paid_hoe.view.offer != null or self.paid_hoe.view.recovery_action != null)) return false;
        return (self.affordableToolUses(tool) orelse 0) >= shared.protocol.large_tool_refill_cuts;
    }

    pub fn canIncreaseTool(self: *const GameState, tool: player.Tool) bool {
        if (tool != self.selected_tool or !self.hoe_funding.canStart()) return false;
        const view = self.paid_hoe.view;
        if (view.top_up != null) return self.topUpPlan(tool, false) != null or self.topUpPlan(tool, true) != null;
        return view.can_refill and !view.close_first and
            (view.recovery_action != null or (self.toolIncreaseLimit(tool) orelse 1) != 0);
    }

    pub fn hasToolChannel(self: *const GameState, tool: player.Tool) bool {
        return self.tool_states[@backingInt(tool.protocolTool())].has_channel;
    }

    pub fn canCloseTool(self: *const GameState, tool: player.Tool) bool {
        return self.hasToolChannel(tool) and tool == self.selected_tool and self.hoe_funding.canStart() and
            self.paid_hoe.view.can_refill and self.paid_hoe.view.close_first;
    }

    pub fn toolsOpen(self: *const GameState) bool {
        return self.menu.opened and self.menu.currentPage == .Tools;
    }

    fn prepareToolMenuControls(self: *GameState, frame: input.FrameInput) void {
        self.menu.tool_control_count = 0;
        if (!self.toolsOpen()) return;
        const content = self.menu.layoutFor(frame.viewport_w, frame.viewport_h).content;
        for (player.Tool.slots, 0..) |tool, index| {
            const row = toolMenuRow(content, index);
            const rects = [_]menu.Rect{ row.name, row.increase, row.close };
            for (rects, 0..) |rect, column| {
                if (column == 2 and !self.hasToolChannel(tool) and !self.showLargeRefill(tool)) continue;
                self.menu.tool_controls[self.menu.tool_control_count] = .{ .id = index * rects.len + column, .rect = rect };
                self.menu.tool_control_count += 1;
            }
        }
    }

    fn activateToolControl(self: *GameState, control: usize) void {
        const tool = player.Tool.slots[control / 3];
        const column = control % 3;
        if (tool != self.selected_tool) {
            self.selectTool(tool);
        } else if (column == 2 and self.canCloseTool(tool)) {
            self.paid_hoe.close_requested = true;
        } else if (self.canIncreaseTool(tool) and (column == 1 or (column == 2 and self.showLargeRefill(tool)))) {
            self.paid_hoe.refill_requested = true;
            self.paid_hoe.refill_large = column == 2;
        }
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

test "mouse aims one cardinal tile regardless of click distance, camera pan, or facing" {
    const t = std.testing;
    var game = try GameState.init(t.allocator, 1000, 640);
    defer game.deinit();
    const area: world.ChunkRange = .{ .cx0 = -2, .cx1 = -2, .cy0 = -2, .cy1 = -2 };
    try game.world.stream(area);
    const chunk = game.world.get(-2, -2).?;
    const index = std.mem.indexOfScalar(world.Tile, &chunk.tiles, .grass).?;
    const tile: Location = .{ .x = -32 + @as(i32, @intCast(index % world.CT)), .y = -32 + @as(i32, @intCast(index / world.CT)) };
    try game.camera.setTarget(tile.x, tile.y);
    game.player_pos = .{ .x = tile.x - 1, .y = tile.y };
    game.player_animation.facing = .left;
    const click: input.FrameInput = .{ .clicked = true, .pointer_x = 500, .pointer_y = 320 };
    try game.update(click);
    try t.expect(game.paid_hoe.target == null);

    var snapshot: shared.protocol.Snapshot = .{ .area = area, .count = 1 };
    const neighbor = (index + 1) % (world.CT * world.CT);
    snapshot.chunks[0][neighbor / 8] |= @as(u8, 1) << @as(u3, @intCast(neighbor % 8));
    game.world.applyCuts(&snapshot);
    const directions = [_]Location{
        .{ .x = -1, .y = 0 }, .{ .x = 1, .y = 0 },
        .{ .x = 0, .y = -1 }, .{ .x = 0, .y = 1 },
    };
    for (directions) |dir| {
        game.player_pos = .{ .x = tile.x - dir.x, .y = tile.y - dir.y };
        try game.update(click);
        try t.expectEqual(tile, game.paid_hoe.target.?);

        var far_click = click;
        far_click.pointer_x += @floatFromInt(world.TILE_PX * (3 * dir.x + dir.y));
        far_click.pointer_y += @floatFromInt(world.TILE_PX * (3 * dir.y + dir.x));
        try game.update(far_click);
        try t.expectEqual(tile, game.paid_hoe.target.?);
    }
    game.player_pos = tile;
    try game.update(click);
    try t.expect(game.paid_hoe.target == null);
    try game.update(.{ .clicked = true, .pointer_x = 505, .pointer_y = 315 });
    try t.expect(game.paid_hoe.target == null);
    game.player_pos = .{ .x = tile.x - 1, .y = tile.y };
    try game.update(.{ .clicked = true, .pointer_x = 500, .pointer_y = 352 });
    try t.expectEqual(tile, game.paid_hoe.target.?); // Exact diagonal ties go horizontal.
    try t.expect(!chunk.isCut(index));

    var press = click;
    press.dragging = true;
    const release: input.FrameInput = .{ .released = true, .pointer_x = 500, .pointer_y = 320 };
    try game.update(press);
    try t.expect(game.paid_hoe.target == null);
    try game.update(release);
    try t.expectEqual(tile, game.paid_hoe.target.?);
    try game.update(release);
    try t.expect(game.paid_hoe.target == null);
    try game.update(press);
    try game.update(.{ .dragging = true, .drag_x = 5, .pointer_x = 505, .pointer_y = 320 });
    try game.update(release);
    try t.expect(game.paid_hoe.target == null);

    try game.update(.{ .clicked = true, .pointer_x = 500, .pointer_y = 608 });
    try t.expect(game.paid_hoe.target == null);
    game.menu.openWallet();
    try game.update(click);
    try t.expect(game.paid_hoe.target == null);
    game.menu.opened = false;

    game.applyHoeCut(tile);
    try t.expect(chunk.isCut(index) and chunk.isCut(neighbor));
    try game.update(click);
    try t.expect(game.paid_hoe.target == null);
}

test "Space targets grass in front of the player only during gameplay" {
    const t = std.testing;
    var game = try GameState.init(t.allocator, 1000, 640);
    defer game.deinit();
    const area: world.ChunkRange = .{ .cx0 = -2, .cx1 = -2, .cy0 = -2, .cy1 = -2 };
    try game.world.stream(area);
    const chunk = game.world.get(-2, -2).?;
    const index = std.mem.indexOfScalar(world.Tile, &chunk.tiles, .grass).?;
    const tile: Location = .{ .x = -32 + @as(i32, @intCast(index % world.CT)), .y = -32 + @as(i32, @intCast(index / world.CT)) };
    game.player_pos = .{ .x = tile.x - 1, .y = tile.y };
    game.player_animation.facing = .right;
    const space: input.FrameInput = .{ .use_tool = true };
    try game.update(space);
    try t.expect(game.paid_hoe.target == null);

    var snapshot: shared.protocol.Snapshot = .{ .area = area, .count = 1 };
    game.world.applyCuts(&snapshot);
    try game.update(space);
    try t.expectEqual(tile, game.paid_hoe.target.?);
    try t.expect(!chunk.isCut(index));

    game.world.invalidateCuts();
    try game.update(space);
    try t.expect(game.paid_hoe.target == null);
    game.applyHoeCut(tile);
    try t.expect(!chunk.cutsSynced());
    game.world.applyCuts(&snapshot);
    try game.update(space);
    try t.expectEqual(tile, game.paid_hoe.target.?);

    game.menu.openWallet();
    try game.update(space);
    try t.expect(game.paid_hoe.target == null);
    game.menu.opened = false;
    game.applyHoeCut(tile);
    try game.update(space);
    try t.expect(game.paid_hoe.target == null);
}

test "axe and pickaxe target matching synced terrain and open it for movement" {
    const t = std.testing;
    const terrain = shared.world;
    var game = try GameState.init(t.allocator, 1000, 640);
    defer game.deinit();
    try game.world.stream(.{ .cx0 = -2, .cx1 = 2, .cy0 = -2, .cy1 = 2 });

    for ([_]player.Tool{ .axe, .pickaxe }) |tool| {
        const tile = find: {
            for (0..80) |row| {
                const y = @as(i32, @intCast(row)) - 32;
                for (1..80) |col| {
                    const x = @as(i32, @intCast(col)) - 32;
                    if (terrain.sampleTile(terrain.public_seed, x, y) != tool.protocolTool().terrain()) continue;
                    const west = terrain.sampleTile(terrain.public_seed, x - 1, y);
                    if (west == .grass or west == .dirt) break :find Location{ .x = x, .y = y };
                }
            }
            return error.TestUnexpectedResult;
        };
        const from: Location = .{ .x = tile.x - 1, .y = tile.y };
        game.player_pos = from;
        try game.camera.setTarget(from.x, from.y);
        game.player_animation.facing = .right;
        const step: input.FrameInput = .{ .right = true };
        const click: input.FrameInput = .{ .clicked = true, .pointer_x = 600, .pointer_y = 320 };
        const addr = GameState.cutAddress(tile);
        const snapshot: shared.protocol.Snapshot = .{ .area = addr.area, .count = 1 };

        game.world.invalidateCuts();
        try game.update(.{ .select_tool = tool, .use_tool = true });
        try t.expect(game.paid_hoe.target == null);
        try game.update(step);
        try t.expectEqual(from, game.player_pos);

        game.world.applyCuts(&snapshot);
        try game.update(.{ .select_tool = .hoe, .use_tool = true });
        try t.expect(game.paid_hoe.target == null);
        try game.update(.{ .select_tool = tool, .use_tool = true });
        try t.expectEqual(tile, game.paid_hoe.target.?);
        try game.update(click);
        try t.expectEqual(tile, game.paid_hoe.target.?);
        try t.expectEqual(@as(?player.Action, null), game.player_animation.action);

        // A confirmation sets the bit, but stale bits are not safe to predict against.
        game.applyHoeCut(tile);
        try game.update(.{ .use_tool = true });
        try t.expect(game.paid_hoe.target == null);
        game.world.invalidateCuts();
        try game.update(step);
        try t.expectEqual(from, game.player_pos);
        game.world.applyCuts(&snapshot);
        game.applyHoeCut(tile);
        try game.update(step);
        try t.expectEqual(tile, game.player_pos);
        try t.expect(game.player_walking);
    }
}

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
        frame.select_tool = .axe;
        frame.toggle_grid = true;
        const grid_before = game.settings.debug.tile_grid;
        try game.update(frame);
        try std.testing.expect(game.menu.opened and game.menu.currentPage == .Wallet);
        try std.testing.expect(game.menu.wallet.balance_dirty);
        try std.testing.expectEqual(@as(usize, 0), game.menu.selected_index);
        try std.testing.expectEqual(grid_before, game.settings.debug.tile_grid);
        try std.testing.expectEqual(player.Tool.hoe, game.selected_tool);
        try std.testing.expectEqual(@as(?player.Action, null), game.player_animation.action);
        try std.testing.expectEqualDeep(initial_pos, game.player_pos);
        try std.testing.expectEqualDeep(initial_camera, game.camera);

        try game.update(.{ .escape_clicked = true, .dragging = true });
        try game.update(.{ .dragging = true, .drag_x = world.TILE_PX });
        try std.testing.expect(!game.menu.opened);
        try std.testing.expectEqualDeep(initial_camera, game.camera);
    }
}

test "right click opens Tools and only enabled controls submit channel actions" {
    const t = std.testing;
    var game = try GameState.init(t.allocator, 320, 640);
    defer game.deinit();
    const axe = toolbarLayout(320, 640).?.slots[1];
    try game.update(.{ .viewport_w = 320, .right_clicked = true, .pointer_x = axe.centerX(), .pointer_y = axe.centerY(), .use_tool = true });
    try t.expect(game.menu.opened and game.menu.currentPage == .Tools and game.selected_tool == .axe);
    try t.expectEqual(null, game.paid_hoe.target);

    game.menu.wallet.balance_msat = 27;
    try t.expectEqual(@as(?u64, 10), game.toolIncreaseLimit(.axe));
    try t.expectEqual(@as(?u64, 2), game.toolIncreaseLimit(.pickaxe));
    const row = toolMenuRow(game.menu.layoutFor(320, 640).content, 1);
    const increase: input.FrameInput = .{ .viewport_w = 320, .clicked = true, .pointer_x = row.increase.centerX(), .pointer_y = row.increase.centerY() };
    try game.update(increase);
    try t.expect(!game.paid_hoe.refill_requested);
    game.paid_hoe.view = .{ .status = .unavailable, .can_refill = true };
    try game.update(increase);
    try t.expect(game.paid_hoe.refill_requested and !game.paid_hoe.refill_large);

    game.paid_hoe.refill_requested = false;
    try t.expect(!game.showLargeRefill(.axe));
    game.menu.wallet.balance_msat = 40;
    const axe_state = &game.tool_states[@backingInt(shared.protocol.tool.axe)];
    axe_state.refill_fee_limit = 5;
    try t.expect(!game.showLargeRefill(.axe));
    game.menu.wallet.balance_msat = 45;
    try t.expect(game.showLargeRefill(.axe));
    try game.update(.{ .viewport_w = 320, .clicked = true, .pointer_x = row.close.centerX(), .pointer_y = row.close.centerY() });
    try t.expect(game.paid_hoe.refill_requested and game.paid_hoe.refill_large);
    game.paid_hoe.refill_large = false;
    game.menu.wallet.balance_msat = 27;

    game.paid_hoe.refill_requested = false;
    game.paid_hoe.view = .{ .status = .empty, .can_refill = true, .close_first = true };
    try game.update(increase);
    try t.expect(!game.paid_hoe.refill_requested);
    const close: input.FrameInput = .{ .viewport_w = 320, .clicked = true, .pointer_x = row.close.centerX(), .pointer_y = row.close.centerY() };
    try game.update(close);
    try t.expect(!game.paid_hoe.close_requested);
    game.tool_states[@backingInt(shared.protocol.tool.axe)].has_channel = true;
    try game.update(close);
    try t.expect(game.paid_hoe.close_requested and !game.paid_hoe.refill_requested);
}

test "Tools controls support menu navigation and keep acknowledged uses while checking" {
    const t = std.testing;
    var game = try GameState.init(t.allocator, 1000, 640);
    defer game.deinit();
    game.menu.openTools();
    try game.update(.{ .confirm = true });
    try t.expectEqual(player.Tool.pickaxe, game.selected_tool);
    const state = &game.tool_states[@backingInt(shared.protocol.tool.pickaxe)];
    state.uses_left = 3;
    game.reconcileSelectedToolUses();
    try t.expectEqual(@as(?u64, 3), state.uses_left);
    game.paid_hoe.view = .{ .status = .pending, .payment_pending = true };
    game.reconcileSelectedToolUses();
    try t.expectEqual(@as(?u64, null), state.uses_left);

    game.paid_hoe.view = .{ .status = .unavailable, .can_refill = true };
    try game.update(.{ .down = true });
    try game.update(.{ .confirm = true });
    try t.expect(game.paid_hoe.refill_requested);
}

test "input at the world edge cannot move or pan beyond it" {
    var game = try GameState.init(std.testing.allocator, 1000, 640);
    defer game.deinit();
    const corner: Location = .{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32) };
    game.player_pos = corner;
    try game.camera.setTarget(corner.x, corner.y);
    game.player_animation.facing = .right;
    try game.update(.{ .right = true, .up = true });
    try std.testing.expectEqual(corner, game.player_pos);
    try std.testing.expect(!game.player_walking);
    try game.update(.{ .dragging = true, .drag_x = -world.TILE_PX, .drag_y = world.TILE_PX });
    try std.testing.expectEqual(corner.x, game.camera.tile_x);
    try std.testing.expectEqual(corner.y, game.camera.tile_y);
    try game.update(.{ .dragging = true, .drag_x = world.TILE_PX, .drag_y = -world.TILE_PX });
    try std.testing.expectEqual(corner.x - 1, game.camera.tile_x);
    try std.testing.expectEqual(corner.y + 1, game.camera.tile_y);
}

test "hoe starts selected and a toolbar press does not swing or pan" {
    var game = try GameState.init(std.testing.allocator, 1000, 640);
    defer game.deinit();
    try std.testing.expectEqual(player.Tool.hoe, game.selected_tool);
    const initial_camera_x = game.camera.tile_x;
    const layout = toolbarLayout(1000, 640).?;
    try std.testing.expectEqual(@as(f32, 500), layout.bounds.x + layout.bounds.width / 2);
    try std.testing.expectEqual(@as(f32, 632), layout.bounds.y + layout.bounds.height);

    for (layout.slots, player.Tool.slots) |slot, tool| {
        try game.update(.{ .clicked = true, .dragging = true, .pointer_x = slot.x + 1, .pointer_y = slot.y + 1, .drag_x = world.TILE_PX });
        try std.testing.expect(game.ui_press_held);
        try game.update(.{ .dragging = true, .pointer_x = 20, .pointer_y = 20, .drag_x = world.TILE_PX });
        try std.testing.expectEqual(initial_camera_x, game.camera.tile_x);
        try std.testing.expectEqual(tool, game.selected_tool);
        try std.testing.expectEqual(@as(?player.Action, null), game.player_animation.action);
        try game.update(.{ .released = true, .pointer_x = slot.x + 1, .pointer_y = slot.y + 1 });
        try std.testing.expect(game.paid_hoe.target == null);
    }

    try game.update(.{});
    try game.update(.{ .clicked = true, .dragging = true, .pointer_x = 20, .pointer_y = 20, .drag_x = world.TILE_PX });
    try std.testing.expectEqual(initial_camera_x - 1, game.camera.tile_x);
    // A world drag crossing the toolbar is still a world drag.
    try game.update(.{ .dragging = true, .pointer_x = layout.slots[2].x + 1, .pointer_y = layout.slots[2].y + 1, .drag_x = world.TILE_PX });
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

test "camera follows steps but does not follow turns; drag only pans the view" {
    var game_state = try GameState.init(std.testing.allocator, 1000, 640);
    defer game_state.deinit();

    try game_state.update(.{ .right = true });
    try std.testing.expectEqualDeep(Location{ .x = 0, .y = 0 }, game_state.player_pos);
    try std.testing.expect(game_state.camera.tile_x == 0 and game_state.camera.tile_y == 0);
    try std.testing.expect(game_state.player_animation.facing == .right);
    try std.testing.expect(!game_state.player_animation.walking);

    try game_state.update(.{ .right = true });
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, 0), game_state.camera.tile_y);

    try game_state.update(.{ .up = true });
    try std.testing.expectEqualDeep(Location{ .x = 1, .y = 0 }, game_state.player_pos);
    try std.testing.expect(game_state.player_animation.facing == .up);
    try std.testing.expect(!game_state.player_animation.walking);
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

    // Selecting a tool doesn't pull a panned camera back to the player.
    try game_state.update(.{ .select_tool = .axe });
    try std.testing.expectEqual(@as(i32, 2), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, -1), game_state.camera.tile_y);
    try std.testing.expectEqualDeep(before_drag, game_state.player_pos);

    // Turning leaves the camera panned; the step starts at the player.
    try game_state.update(.{ .right = true });
    try std.testing.expect(game_state.camera.tile_x == 2 and game_state.camera.tile_y == -1);
    try std.testing.expectEqualDeep(before_drag, game_state.player_pos);
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

test "player walks between tile steps and the menu consumes tool selection" {
    var game_state = try GameState.init(std.testing.allocator, 1000, 640);
    defer game_state.deinit();

    game_state.player_animation.facing = .right;
    try game_state.update(.{ .right = true, .held_dx = 1 });
    try game_state.update(.{ .held_dx = 1, .dt = 0.11 });
    try std.testing.expectEqual(@as(i32, 1), game_state.camera.tile_x);
    try std.testing.expectEqual(@as(i32, 32), game_state.player_animation.frame().x);

    const before = game_state.player_animation.frame();
    try game_state.update(.{ .escape_clicked = true, .select_tool = .pickaxe });
    try game_state.update(.{ .select_tool = .axe, .dt = 0.25 });
    try game_state.update(.{ .escape_clicked = true, .select_tool = .pickaxe });
    try std.testing.expectEqualDeep(before, game_state.player_animation.frame());
    try std.testing.expectEqual(player.Tool.hoe, game_state.selected_tool);

    try game_state.update(.{ .select_tool = .axe });
    try std.testing.expectEqual(player.Tool.axe, game_state.selected_tool);
    try std.testing.expectEqual(player.Sheet.character, game_state.player_animation.frame().sheet);
}

test "blocked steps leave player and panned camera in place without walking" {
    var game_state = try GameState.init(std.testing.allocator, 1000, 640);
    defer game_state.deinit();
    game_state.player_pos = .{ .x = 19, .y = 0 };
    try game_state.camera.setTarget(16, 0);
    game_state.player_animation.facing = .right;

    try game_state.update(.{ .right = true, .held_dx = 1 });
    try game_state.update(.{ .held_dx = 1, .dt = 0.05 });
    try std.testing.expectEqualDeep(Location{ .x = 19, .y = 0 }, game_state.player_pos);
    try std.testing.expectEqual(@as(i32, 16), game_state.camera.tile_x);
    try std.testing.expect(!game_state.player_animation.walking);
    try std.testing.expectEqual(@as(i32, 32), game_state.player_animation.frame().y);

    try game_state.update(.{ .down = true });
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
    try std.testing.expect(game_state.player_animation.facing == .right);
    try std.testing.expectEqual(@as(i32, 0), game_state.camera.tile_x);
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
    try std.testing.expect(game_state.player_animation.facing == .right);
    try std.testing.expectEqual(@as(i32, 0), game_state.camera.tile_x);
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
