const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const world = shared.world;
const state = @import("world_state.zig");
const WorldState = state.WorldState;
const request = state.request;
const t = std.testing;

fn tile(cuttable: bool, cx: i32, cy: i32) p.Cut {
    return findTile(cuttable, cx, cy) orelse @panic("fixture chunk lacks requested terrain");
}

fn findTile(cuttable: bool, cx: i32, cy: i32) ?p.Cut {
    for (0..16) |y| for (0..16) |x| {
        const tx = cx * 16 + @as(i32, @intCast(x));
        const ty = cy * 16 + @as(i32, @intCast(y));
        const terrain = world.sampleTile(world.public_seed, tx, ty);
        if ((terrain == .grass or terrain == .tree) == cuttable) return .{ .x = tx, .y = ty };
    };
    return null;
}

test "original success and terminal errors replay with opaque full IDs and binding conflicts" {
    var s = WorldState{};
    const pos = tile(true, -1, 0);
    var req = request(0, pos.x, pos.y);
    const original = try s.cut(req);
    try t.expect(original == .ok);
    try t.expectEqualDeep(original, try s.cut(req));
    for (0..16) |byte| {
        var distinct = req;
        distinct.request_id[byte] = 1;
        const result = try s.cut(distinct);
        try t.expectEqualDeep(original.ok, result.failed.already_cut);
        try t.expectEqualDeep(result, try s.cut(distinct));
    }
    req.payload.x += 1;
    try t.expect((try s.cut(req)).failed == .request_id_conflict);
    req = request(0, pos.x, pos.y + 1);
    try t.expect((try s.cut(req)).failed == .request_id_conflict);
    const rock = tile(false, 0, 0);
    const bad = request(999, rock.x, rock.y);
    const failure = try s.cut(bad);
    try t.expect(failure.failed == .not_cuttable);
    try t.expectEqualDeep(failure, try s.cut(bad));
    try t.expectEqual(@as(usize, 18), s.replay_count);
}

test "water cuts replay not_cuttable without changing snapshots" {
    var s = WorldState{};
    const x = 26;
    const y = 0;
    try t.expectEqual(.water, world.sampleTile(world.public_seed, x, y));
    const area: world.ChunkRange = .{ .cx0 = 1, .cy0 = 0, .cx1 = 1, .cy1 = 0 };
    var before: p.Snapshot = undefined;
    var after: p.Snapshot = undefined;
    try s.readArea(area, &before);
    const req = request(0, x, y);
    const result = try s.cut(req);
    try t.expect(result.failed == .not_cuttable);
    try t.expectEqualDeep(result, try s.cut(req));
    try s.readArea(area, &after);
    try t.expectEqualDeep(before, after);
}

test "negative chunk edges and full signed coordinate domain use floor and modulo" {
    var s = WorldState{};
    const values = [_]i32{ std.math.minInt(i32), -17, -16, -1, 0, 15, 16, std.math.maxInt(i32) };
    var id: u128 = 0;
    for (values) |x| for (values) |y| {
        const result = try s.cut(request(id, x, y));
        id += 1;
        var snapshot: p.Snapshot = undefined;
        const cx = @divFloor(x, 16);
        const cy = @divFloor(y, 16);
        try s.readArea(.{ .cx0 = cx, .cy0 = cy, .cx1 = cx, .cy1 = cy }, &snapshot);
        const bit: usize = @intCast(@mod(y, 16) * 16 + @mod(x, 16));
        const marked = snapshot.chunks[0][bit / 8] & (@as(u8, 1) << @as(u3, @intCast(bit % 8))) != 0;
        try t.expectEqual(result == .ok, marked);
    };
}

test "snapshots are complete row major zero filled bounded and clear reused scratch" {
    var s = WorldState{};
    var snapshot: p.Snapshot = undefined;
    try s.readArea(.{ .cx0 = -4, .cy0 = -4, .cx1 = 3, .cy1 = 3 }, &snapshot);
    try t.expectEqual(@as(u16, 64), snapshot.count);
    try t.expectEqualDeep(@as([64][32]u8, @splat(@splat(0))), snapshot.chunks);
    for (0..8) |y| for (0..8) |x| {
        if ((x + y) % 2 == 0) continue;
        const pos = tile(true, @as(i32, @intCast(x)) - 4, @as(i32, @intCast(y)) - 4);
        _ = try s.cut(request(y * 8 + x, pos.x, pos.y));
    };
    try s.readArea(.{ .cx0 = -4, .cy0 = -4, .cx1 = 3, .cy1 = 3 }, &snapshot);
    for (0..8) |y| for (0..8) |x| {
        var bits: u32 = 0;
        for (snapshot.chunks[y * 8 + x]) |b| bits += @popCount(b);
        try t.expectEqual(@as(u32, @intCast((x + y) % 2)), bits);
    };
    try s.readArea(.{ .cx0 = 100, .cy0 = 100, .cx1 = 100, .cy1 = 100 }, &snapshot);
    try t.expectEqual(@as(u16, 1), snapshot.count);
    try t.expectEqualDeep(@as([64][32]u8, @splat(@splat(0))), snapshot.chunks);
    const before = snapshot;
    for ([_]world.ChunkRange{
        .{ .cx0 = 1, .cy0 = 0, .cx1 = 0, .cy1 = 0 },
        .{ .cx0 = 0, .cy0 = 0, .cx1 = 8, .cy1 = 7 },
        .{ .cx0 = std.math.minInt(i32), .cy0 = 0, .cx1 = 0, .cy1 = 0 },
    }) |area| try t.expectError(error.InvalidArea, s.readArea(area, &snapshot));
    try t.expectEqualDeep(before, snapshot);
}

test "replay capacity filled by successes rejects atomically and retains replays conflicts and reads" {
    var s = WorldState{};
    var first: p.RequestFor(.cut) = undefined;
    var original: p.Outcome(.cut) = undefined;
    var cx: i32 = 0;
    for (0..WorldState.capacity) |i| {
        while (findTile(true, cx, 0) == null) : (cx += 1) {}
        const pos = tile(true, cx, 0);
        cx += 1;
        const req = request(i, pos.x, pos.y);
        const result = try s.cut(req);
        try t.expect(result == .ok);
        if (i == 0) {
            first = req;
            original = result;
        }
    }
    try t.expectEqual(WorldState.capacity, s.chunk_count);
    const before = s;
    const new_pos = tile(true, 1000, 0);
    try t.expectError(error.CapacityExceeded, s.cut(request(9999, new_pos.x, new_pos.y)));
    try t.expectError(error.CapacityExceeded, s.cut(request(9999, first.payload.x, first.payload.y)));
    try t.expectEqualDeep(before, s);
    try t.expectEqualDeep(original, try s.cut(first));
    first.payload.x += 1;
    try t.expect((try s.cut(first)).failed == .request_id_conflict);
    var snapshot: p.Snapshot = undefined;
    try s.readArea(.{ .cx0 = 0, .cy0 = 0, .cx1 = 7, .cy1 = 7 }, &snapshot);
    try t.expectEqual(@as(u16, 64), snapshot.count);
}

test "terminal errors consume replay space and full history never mutates new or existing chunks" {
    var s = WorldState{};
    const pos = tile(true, 0, 0);
    _ = try s.cut(request(0, pos.x, pos.y));
    const bad = tile(false, 0, 0);
    for (1..WorldState.capacity) |i| {
        const result = try s.cut(request(i, bad.x, bad.y));
        try t.expect(result.failed == .not_cuttable);
    }
    const before = s.chunks[0];
    try t.expectError(error.CapacityExceeded, s.cut(request(9999, pos.x, pos.y)));
    try t.expectError(error.CapacityExceeded, s.cut(request(9999, bad.x, bad.y)));
    const fresh = tile(true, 1, 0);
    try t.expectError(error.CapacityExceeded, s.cut(request(9999, fresh.x, fresh.y)));
    // An uncut cuttable tile in an existing chunk must not be published either.
    for (0..256) |i| {
        const x: i32 = @intCast(i % 16);
        const y: i32 = @intCast(i / 16);
        const terrain = world.sampleTile(world.public_seed, x, y);
        if ((x != pos.x or y != pos.y) and (terrain == .grass or terrain == .tree)) {
            try t.expectError(error.CapacityExceeded, s.cut(request(9999, x, y)));
            break;
        }
    }
    try t.expectEqualDeep(before, s.chunks[0]);
    try t.expectEqual(@as(usize, 1), s.chunk_count);
    try t.expectEqual(WorldState.capacity, s.replay_count);
    try t.expect((try s.cut(request(1, bad.x, bad.y))).failed == .not_cuttable);
    const outcome = @import("actions.zig").handleCut(&s, request(9999, pos.x, pos.y));
    try t.expect(outcome.failed == .server_busy);
}

test "chunk space precheck rejects without consuming ID and terminal failure needs no chunk" {
    var s = WorldState{};
    // Equal production capacities require a direct setup to isolate this boundary.
    for (&s.chunks, 0..) |*chunk, i| chunk.* = .{ .cx = @intCast(i), .cy = 100, .cuts = @splat(0) };
    s.chunk_count = WorldState.capacity;
    const pos = tile(true, 0, 0);
    try t.expectError(error.CapacityExceeded, s.cut(request(7, pos.x, pos.y)));
    try t.expectEqual(@as(usize, 0), s.replay_count);
    const bad = tile(false, 0, 0);
    try t.expect((try s.cut(request(7, bad.x, bad.y))).failed == .not_cuttable);
    const existing = tile(true, 0, 100);
    try t.expect((try s.cut(request(8, existing.x, existing.y))) == .ok);
    try t.expectEqual(WorldState.capacity, s.chunk_count);
}

test "application default layout fresh restart global session replay and cross thread exclusive lease" {
    const app = @import("app.zig");
    const Fixture = @import("fixture.zig").Fixture;
    comptime std.debug.assert(@sizeOf(app.Layout) <= app.default_budget);
    try t.expectError(error.InsufficientApplicationBudget, Fixture.initWith(t.allocator, t.io, @sizeOf(app.Layout) - 1));
    var f = try Fixture.init();
    defer f.deinit();
    const pos = tile(true, 0, 0);
    const req = request(0, pos.x, pos.y);
    const a = try f.application.registry.claim(@splat(1));
    const held = f.application.lease().?;
    const original = try held.state.cut(req);
    const Worker = struct {
        fn run(application: *app.App) void {
            std.debug.assert(application.lease() == null);
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&f.application});
    thread.join();
    f.application.release(held);
    f.application.registry.release(a);
    const b = try f.application.registry.claim(@splat(2));
    defer f.application.registry.release(b);
    const next = f.application.lease().?;
    try t.expectEqualDeep(original, try next.state.cut(req));
    f.application.release(next);
    f.application.deinit();
    f.application = try app.App.init(t.io, f.buffers);
    try t.expectEqual(@as(usize, 0), f.application.context.state.chunk_count);
    try t.expectEqual(@as(usize, 0), f.application.context.state.replay_count);
    try t.expect((try f.application.context.state.cut(req)) == .ok);
}
