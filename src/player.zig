//! Frame coordinates and playback for the Cute Fantasy player sheets.
const std = @import("std");
const ProtocolTool = @import("shared").protocol.tool;

pub const Tool = enum {
    pickaxe,
    axe,
    hoe,

    pub const slots = [_]Tool{ .pickaxe, .axe, .hoe };

    pub fn protocolTool(self: Tool) ProtocolTool {
        return switch (self) {
            .pickaxe => .pickaxe,
            .axe => .axe,
            .hoe => .hoe,
        };
    }

    pub fn fromProtocol(tool: ProtocolTool) Tool {
        return switch (tool) {
            .pickaxe => .pickaxe,
            .axe => .axe,
            .hoe => .hoe,
        };
    }

    pub fn animation(self: Tool) Action {
        return switch (self) {
            .pickaxe => .pickaxe,
            .axe => .axe,
            .hoe => .hoe,
        };
    }

    pub fn label(self: Tool) [:0]const u8 {
        return switch (self) {
            .pickaxe => "Pickaxe",
            .axe => "Axe",
            .hoe => "Hoe",
        };
    }
};
pub const Action = enum { sword, pickaxe, axe, hoe, water, collapse };
const Facing = enum {
    down,
    right,
    up,
    left,

    fn fromInput(dx: i8, dy: i8) ?Facing {
        return if (dx < 0) .left else if (dx > 0) .right else if (dy < 0) .up else if (dy > 0) .down else null;
    }
};

pub const Sheet = enum { character, tools };
pub const Frame = struct {
    sheet: Sheet,
    x: i32,
    y: i32,
    size: i32,
    flip_x: bool,
};

const Clip = struct {
    sheet: Sheet = .character,
    row: i32,
    count: i32,
    frame_seconds: f64,
    flip_x: bool,
};

fn clip(facing: Facing, walking: bool, action: ?Action) Clip {
    const direction: i32 = switch (facing) {
        .down => 0,
        .left, .right => 1,
        .up => 2,
    };
    const flip = facing == .left;
    return if (action) |a| switch (a) {
        .sword => .{ .row = 6 + direction, .count = 4, .frame_seconds = 0.10, .flip_x = flip },
        .collapse => .{ .row = 9, .count = 4, .frame_seconds = 0.16, .flip_x = flip },
        .pickaxe, .axe, .hoe, .water => .{
            .sheet = .tools,
            // Rows indexed by the character sheet's down, right, up order.
            .row = (switch (a) {
                .pickaxe => [3]i32{ 1, 0, 2 },
                .axe => [3]i32{ 4, 3, 5 },
                .hoe => [3]i32{ 7, 6, 8 },
                .water => [3]i32{ 9, 11, 10 },
                else => unreachable,
            })[@intCast(direction)],
            .count = 2,
            .frame_seconds = 0.18,
            .flip_x = flip,
        },
    } else .{
        .row = direction + @as(i32, if (walking) 3 else 0),
        .count = 6,
        .frame_seconds = if (walking) 0.10 else 0.18,
        .flip_x = flip,
    };
}

pub const Animation = struct {
    facing: Facing = .down,
    walking: bool = false,
    action: ?Action = null,
    elapsed: f64 = 0,

    pub fn faces(self: Animation, dx: i8, dy: i8) bool {
        return Facing.fromInput(dx, dy) == self.facing;
    }

    pub fn update(self: *Animation, dt: f32, dx: i8, dy: i8, walking: bool, requested: ?Action) void {
        const seconds: f64 = if (std.math.isFinite(dt) and dt > 0) dt else 0;
        const was_playing = self.action != null;
        if (was_playing) {
            const current = clip(self.facing, self.walking, self.action);
            self.elapsed += seconds;
            if (self.elapsed < current.frame_seconds * @as(f64, @floatFromInt(current.count))) return;
        }

        const facing = Facing.fromInput(dx, dy) orelse self.facing;
        if (was_playing or requested != null or walking != self.walking or facing != self.facing) {
            self.elapsed = 0;
        } else {
            const current = clip(facing, walking, null);
            self.elapsed = @mod(self.elapsed + seconds, current.frame_seconds * @as(f64, @floatFromInt(current.count)));
        }
        self.facing = facing;
        self.walking = walking;
        self.action = requested;
    }

    pub fn frame(self: Animation) Frame {
        const current = clip(self.facing, self.walking, self.action);
        const size: i32 = if (current.sheet == .character) 32 else 48;
        const column: i32 = @intFromFloat(self.elapsed / current.frame_seconds);
        return .{
            .sheet = current.sheet,
            .x = @min(column, current.count - 1) * size,
            .y = current.row * size,
            .size = size,
            .flip_x = current.flip_x,
        };
    }
};

test "toolbar order maps to protocol tools and existing swing clips" {
    const protocol_tools = [_]ProtocolTool{ .pickaxe, .axe, .hoe };
    const swings = [_]Action{ .pickaxe, .axe, .hoe };
    for (Tool.slots, protocol_tools, swings) |tool, protocol_tool, swing| {
        try std.testing.expectEqual(protocol_tool, tool.protocolTool());
        try std.testing.expectEqual(tool, Tool.fromProtocol(protocol_tool));
        try std.testing.expectEqual(swing, tool.animation());
    }
}

test "sheet coordinates match the measured direction rows" {
    const directions = [_]Facing{ .down, .right, .up, .left };
    const actions = [_]?Action{ null, .sword, .collapse, .pickaxe, .axe, .hoe, .water };
    const rows = [actions.len][directions.len]i32{
        .{ 0, 1, 2, 1 }, .{ 6, 7, 8, 7 }, .{ 9, 9, 9, 9 },    .{ 1, 0, 2, 0 },
        .{ 4, 3, 5, 3 }, .{ 7, 6, 8, 6 }, .{ 9, 11, 10, 11 },
    };
    for (actions, rows, 0..) |action, expected, i| {
        for (directions, expected) |facing, row| {
            const state = Animation{ .facing = facing, .action = action };
            const sample = state.frame();
            const size: i32 = if (i < 3) 32 else 48;
            try std.testing.expectEqualDeep(Frame{
                .sheet = if (i < 3) .character else .tools,
                .x = 0,
                .y = row * size,
                .size = size,
                .flip_x = facing == .left,
            }, sample);
        }
    }
}

test "locomotion loops while held, and a one-shot holds facing until it ends" {
    var state = Animation{};
    state.update(0, -1, -1, true, null);
    try std.testing.expectEqualDeep(Frame{ .sheet = .character, .x = 0, .y = 128, .size = 32, .flip_x = true }, state.frame());
    state.update(0.75, -1, -1, true, null);
    try std.testing.expectEqual(@as(i32, 32), state.frame().x);
    state.update(0, 0, 0, false, .water);
    try std.testing.expectEqual(@as(i32, 0), state.frame().x);
    state.update(0.20, 1, 0, true, .sword);
    try std.testing.expectEqualDeep(Frame{ .sheet = .tools, .x = 48, .y = 528, .size = 48, .flip_x = true }, state.frame());
    state.update(0.20, 0, 0, false, null);
    try std.testing.expectEqualDeep(Frame{ .sheet = .character, .x = 0, .y = 32, .size = 32, .flip_x = true }, state.frame());
}
