//! Pure game rules and typed service boundary.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const world = shared.world;
const WorldState = @import("world_state.zig").WorldState;

pub fn cutRule(state: p.State, tool: p.tool) p.Outcome(.cut) {
    if (state.terrain != tool.terrain()) return .{ .failed = .not_cuttable };
    if (state.cut) return .{ .failed = .{ .already_cut = state } };
    var next = state;
    next.cut = true;
    return .{ .ok = next };
}

pub fn validateArea(r: world.ChunkRange) ?p.AreaFailure {
    _ = p.areaGeometry(r) catch |err| return switch (err) {
        error.InvalidArea => .invalid_area,
        error.OutOfBounds => .out_of_bounds,
        error.AreaTooLarge => .area_too_large,
    };
    return null;
}

pub fn handleCut(state: *WorldState, req: p.RequestFor(.cut)) p.Outcome(.cut) {
    return state.cut(req) catch .{ .failed = .server_busy };
}

pub fn handleReadArea(state: *const WorldState, snapshot: *p.Snapshot, req: p.RequestFor(.read_area)) p.Outcome(.read_area) {
    if (validateArea(req.payload)) |failure| return .{ .failed = failure };
    state.readArea(req.payload, snapshot) catch unreachable;
    return .{ .ok = snapshot };
}

test "each tool clears only its matching terrain and preserves the base tile" {
    for (p.tools) |tool| {
        for ([_]world.Tile{ .grass, .tree, .rock, .dirt, .water }) |terrain| {
            const state = p.State{ .x = -1, .y = 5, .terrain = terrain, .cut = false };
            const result = cutRule(state, tool);
            if (terrain == tool.terrain()) {
                try std.testing.expect(result.ok.cut);
                try std.testing.expectEqual(terrain, result.ok.terrain);
                const again = cutRule(result.ok, tool);
                try std.testing.expectEqualDeep(result.ok, again.failed.already_cut);
            } else try std.testing.expect(result.failed == .not_cuttable);
        }
    }
}
test "area validation uses tile not pixel bounds and overflow safe counts" {
    try std.testing.expectEqual(@as(?p.AreaFailure, null), validateArea(.{ .cx0 = p.min_chunk, .cy0 = p.max_chunk, .cx1 = p.min_chunk, .cy1 = p.max_chunk }));
    try std.testing.expectEqual(p.AreaFailure.invalid_area, validateArea(.{ .cx0 = 1, .cy0 = 0, .cx1 = 0, .cy1 = 0 }).?);
    try std.testing.expectEqual(p.AreaFailure.area_too_large, validateArea(.{ .cx0 = p.min_chunk, .cy0 = p.min_chunk, .cx1 = p.max_chunk, .cy1 = p.max_chunk }).?);
    try std.testing.expectEqual(p.AreaFailure.out_of_bounds, validateArea(.{ .cx0 = std.math.minInt(i32), .cy0 = 0, .cx1 = std.math.maxInt(i32), .cy1 = 0 }).?);
    try std.testing.expectEqual(@as(?p.AreaFailure, null), validateArea(.{ .cx0 = -8, .cy0 = -8, .cx1 = -1, .cy1 = -1 }));
}
