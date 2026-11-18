//! Pure game rules and typed service boundary.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const world = shared.world;
const WorldState = @import("world_state.zig").WorldState;

pub fn cutRule(state: p.State) p.CutResult {
    if (state.cut) return .{ .failure = .{ .code = .already_cut, .current = state } };
    if (state.terrain != .grass and state.terrain != .tree) return .{ .failure = .{ .code = .not_cuttable } };
    var next = state;
    next.cut = true;
    return .{ .success = next };
}

pub fn validateArea(r: world.ChunkRange) ?p.ErrorCode {
    if (r.cx0 > r.cx1 or r.cy0 > r.cy1) return .invalid_area;
    if (r.cx0 < p.min_chunk or r.cy0 < p.min_chunk or r.cx1 > p.max_chunk or r.cy1 > p.max_chunk) return .out_of_bounds;
    const cols = @as(i64, r.cx1) - r.cx0 + 1;
    const rows = @as(i64, r.cy1) - r.cy0 + 1;
    if (cols * rows > p.max_area_chunks) return .area_too_large;
    return null;
}

pub fn handle(state: *WorldState, snapshot: *p.Snapshot, req: p.Request) p.Response {
    const result: @FieldType(p.Response, "result") = switch (req.operation) {
        .update_location => .{ .failure = .{ .code = .invalid_request } },
        .cut => blk: {
            const outcome = state.cut(req) catch break :blk .{ .failure = .{ .code = .server_busy } };
            break :blk switch (outcome) {
                .success => |s| .{ .cut = s },
                .failure => |f| .{ .failure = f },
            };
        },
        .read_area => |area| blk: {
            if (validateArea(area)) |code| break :blk .{ .failure = .{ .code = code } };
            state.readArea(area, snapshot) catch unreachable;
            break :blk .{ .snapshot = snapshot };
        },
    };
    return .{ .request_id = req.request_id, .result = result };
}

test "pure cut rules preserve terrain and reject rock dirt and already cut" {
    for ([_]world.Tile{ .grass, .tree, .rock, .dirt }) |terrain| {
        const state = p.State{ .x = -1, .y = 5, .terrain = terrain, .cut = false };
        const result = cutRule(state);
        if (terrain == .grass or terrain == .tree) {
            try std.testing.expect(result.success.cut);
            try std.testing.expectEqual(terrain, result.success.terrain);
            const again = cutRule(result.success);
            try std.testing.expectEqual(p.ErrorCode.already_cut, again.failure.code);
            try std.testing.expectEqualDeep(result.success, again.failure.current.?);
        } else try std.testing.expectEqual(p.ErrorCode.not_cuttable, result.failure.code);
    }
}
test "area validation uses tile not pixel bounds and overflow safe counts" {
    try std.testing.expectEqual(@as(?p.ErrorCode, null), validateArea(.{ .cx0 = p.min_chunk, .cy0 = p.max_chunk, .cx1 = p.min_chunk, .cy1 = p.max_chunk }));
    try std.testing.expectEqual(p.ErrorCode.invalid_area, validateArea(.{ .cx0 = 1, .cy0 = 0, .cx1 = 0, .cy1 = 0 }).?);
    try std.testing.expectEqual(p.ErrorCode.area_too_large, validateArea(.{ .cx0 = p.min_chunk, .cy0 = p.min_chunk, .cx1 = p.max_chunk, .cy1 = p.max_chunk }).?);
    try std.testing.expectEqual(p.ErrorCode.out_of_bounds, validateArea(.{ .cx0 = std.math.minInt(i32), .cy0 = 0, .cx1 = std.math.maxInt(i32), .cy1 = 0 }).?);
    try std.testing.expectEqual(@as(?p.ErrorCode, null), validateArea(.{ .cx0 = -8, .cy0 = -8, .cx1 = -1, .cy1 = -1 }));
}
