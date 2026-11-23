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
        if ((terrain == .grass) == cuttable) return .{ .x = tx, .y = ty };
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

test "full replay history evicts oldest admission without refreshing hits or conflicts" {
    var s = WorldState{};
    const pos = tile(true, 0, 0);
    const first = request(0, pos.x, pos.y);
    const original = try s.cut(first);
    const bad = tile(false, 0, 0);
    for (1..WorldState.capacity) |i| {
        try t.expect((try s.cut(request(i, bad.x, bad.y))).failed == .not_cuttable);
    }
    try t.expectEqualDeep(original, try s.cut(first));
    try t.expect((try s.cut(request(0, bad.x, bad.y))).failed == .request_id_conflict);

    const fresh = tile(true, 1, 0);
    try t.expect((try s.cut(request(WorldState.capacity, fresh.x, fresh.y))) == .ok);
    try t.expectEqual(WorldState.capacity, s.replay_count);
    try t.expect((try s.cut(request(1, pos.x, pos.y))).failed == .request_id_conflict);
    try t.expectEqualDeep(original.ok, (try s.cut(first)).failed.already_cut);
    try t.expect((try s.cut(request(1, pos.x, pos.y))).failed == .already_cut);
    try t.expectEqual(@as(usize, 2), s.chunk_count);
}

test "chunk space precheck rejects without consuming ID and terminal failure needs no chunk" {
    var s = WorldState{};
    // Equal production capacities require a direct setup to isolate this boundary.
    for (&s.chunks, 0..) |*chunk, i| chunk.* = .{ .address = .{ .cx = @intCast(i), .cy = 100 }, .cuts = @splat(0) };
    s.chunk_count = WorldState.capacity;
    const pos = tile(true, 0, 0);
    try t.expectError(error.CapacityExceeded, s.cut(request(7, pos.x, pos.y)));
    try t.expectEqual(@as(usize, 0), s.replay_count);
    const bad = tile(false, 0, 0);
    try t.expect((try s.cut(request(7, bad.x, bad.y))).failed == .not_cuttable);
    const existing = tile(true, 0, 100);
    try t.expect((try s.cut(request(8, existing.x, existing.y))) == .ok);
    try t.expectEqual(WorldState.capacity, s.chunk_count);
    for (9..WorldState.capacity + 7) |id| _ = try s.cut(request(id, bad.x, bad.y));
    try t.expectEqual(WorldState.capacity, s.replay_count);
    const before = s;
    try t.expectError(error.CapacityExceeded, s.cut(request(9999, pos.x, pos.y)));
    try t.expectEqualDeep(before, s);
}

fn readChunk(s: *const WorldState, cx: i32, cy: i32) ![32]u8 {
    var out: p.Snapshot = undefined;
    try s.readArea(.{ .cx0 = cx, .cy0 = cy, .cx1 = cx, .cy1 = cy }, &out);
    return out.chunks[0];
}

test "persistent cache starts empty and installs bitmaps once per address" {
    var s = try WorldState.initPersistent(t.allocator);
    defer s.deinit(t.allocator);
    const zeros: [32]u8 = @splat(0);
    const loaded: [32]u8 = @splat(0xa5);
    try t.expectEqual(@as(usize, 0), s.chunk_count);
    try t.expect(!s.pin(.{ .cx = -1, .cy = 0 }));
    try t.expectEqual(zeros, try readChunk(&s, -1, 0));
    const pos = tile(true, -1, 0);
    const req = request(1, pos.x, pos.y);
    try t.expectEqual(p.CutFailure.server_busy, @import("actions.zig").handleCut(&s, req).failed);
    try t.expectEqual(@as(usize, 0), s.replay_count);

    try t.expect(s.installPinned(.{ .cx = -1, .cy = 0 }, loaded, &.{}));
    try t.expect(s.installPinned(.{ .cx = -1, .cy = 0 }, zeros, &.{}));
    try t.expectEqual(loaded, try readChunk(&s, -1, 0));
    try t.expect(s.installPinned(.{ .cx = 0, .cy = -1 }, zeros, &.{}));
    s.unpin(.{ .cx = 0, .cy = -1 });
    try t.expect(s.pin(.{ .cx = 0, .cy = -1 })); // A cached zero row is a hit, unlike an absent row.
    s.unpin(.{ .cx = 0, .cy = -1 });
    s.unpin(.{ .cx = -1, .cy = 0 });
    s.unpin(.{ .cx = -1, .cy = 0 });
    try t.expectEqual(@as(usize, 2), s.chunk_count);
    var cursor: usize = 0;
    try t.expect(s.nextDirty(&cursor) == null);
}

test "persistent pinned axe cut clears a tree for movement and survives reopen" {
    try expectPersistentToolCut(.{ .x = 20, .y = 0, .tool = .axe }, .tree, .pickaxe);
}

test "persistent pinned pickaxe cut clears a rock for movement and survives reopen" {
    try expectPersistentToolCut(.{ .x = 0, .y = -19, .tool = .pickaxe }, .rock, .axe);
}

fn expectPersistentToolCut(cut: p.Cut, terrain: world.Tile, wrong_tool: p.tool) !void {
    const GameDb = @import("game_db.zig").GameDb;
    const Persistence = @import("persistence.zig").Persistence;
    const Registry = @import("sessions.zig").Registry;
    const movement = shared.movement;
    const from: p.Location = .{ .x = cut.x - 1, .y = cut.y };
    const to: p.Location = .{ .x = cut.x, .y = cut.y };
    const expected: p.State = .{ .x = cut.x, .y = cut.y, .terrain = terrain, .cut = true };
    try t.expectEqual(terrain, world.sampleTile(world.public_seed, to.x, to.y));
    const approach = world.sampleTile(world.public_seed, from.x, from.y);
    try t.expect(approach == .grass or approach == .dirt);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(t.allocator, "{s}/game.sqlite3", .{dir}, 0);
    defer t.allocator.free(path);

    for ([_]bool{ false, true }) |reopened| {
        var db = try GameDb.open(path);
        defer db.close();
        var s: WorldState = undefined;
        var registry: Registry = .{ .io = t.io };
        var persistence = try Persistence.init(t.io, t.allocator, &db, &s, &registry);
        defer persistence.deinit(t.allocator);
        {
            var pins = try persistence.prepare(.{ .request_id = @splat(0), .operation = .{ .cut = cut } });
            defer persistence.release(&pins);
            try t.expectEqual(@as(usize, 1), pins.len);

            if (!reopened) {
                try t.expect(!movement.canStepWith(from, to, &s));
                var mismatch = cut;
                mismatch.tool = wrong_tool;
                const rejected = s.prepareToolCut(mismatch);
                try t.expect(rejected == .failed);
                try t.expectEqual(.not_cuttable, rejected.failed);

                const prepared = s.prepareToolCut(cut);
                try t.expect(prepared == .ready);
                try t.expect(!movement.canStepWith(from, to, &s));
                try t.expectEqualDeep(expected, prepared.ready.apply());
            }

            try t.expect(movement.canStepWith(from, to, &s));
            const repeated = s.prepareToolCut(cut);
            try t.expect(repeated == .failed);
            try t.expectEqualDeep(p.CutFailure{ .already_cut = expected }, repeated.failed);
        }
        if (!reopened) try persistence.flush();
    }
}

test "persistent saves claim detached bitmaps, retain newer cuts and can retry failures" {
    var s = try WorldState.initPersistent(t.allocator);
    defer s.deinit(t.allocator);
    const req = request(0, 0, 0);
    const next = request(1, 1, 0);
    try t.expect(s.installPinned(.{ .cx = 0, .cy = 0 }, @splat(0), &.{}));
    const original = try s.cut(req);
    try t.expect(original == .ok);
    var cursor: usize = 0;
    const first = s.nextDirty(&cursor).?;
    try t.expectEqual(@as(u8, 1), first.bits[0]);
    cursor = 0;
    try t.expect(s.nextDirty(&cursor) == null);
    try t.expect((try s.cut(next)) == .ok);
    try t.expect(s.installPinned(.{ .cx = 0, .cy = 0 }, first.bits, &.{}));
    s.unpin(.{ .cx = 0, .cy = 0 });
    try t.expect(!s.markSaved(first));
    s.unpin(.{ .cx = 0, .cy = 0 });
    try t.expectEqualDeep(original, try s.cut(req));
    try t.expectError(error.CapacityExceeded, s.cut(request(2, 2, 0)));

    cursor = 0;
    const newer = s.nextDirty(&cursor).?;
    try t.expect(newer.revision > first.revision);
    try t.expectEqual(@as(u8, 3), newer.bits[0]);
    try t.expectEqual(@as(u8, 1), first.bits[0]);
    s.markSaveFailed(newer);
    cursor = 0;
    const retry = s.nextDirty(&cursor).?;
    try t.expectEqual(newer.revision, retry.revision);
    try t.expect(!s.markSaved(newer));
    try t.expect(s.markSaved(retry));
    cursor = 0;
    try t.expect(s.nextDirty(&cursor) == null);

    try t.expect(s.pin(.{ .cx = 0, .cy = 0 }));
    defer s.unpin(.{ .cx = 0, .cy = 0 });
    try t.expect((try s.cut(request(3, 0, 0))).failed == .already_cut);
    cursor = 0;
    try t.expect(s.nextDirty(&cursor) == null);
}

test "persistent cache saturation protects dirty and multiply pinned rows until save or unpin" {
    var s = try WorldState.initPersistent(t.allocator);
    defer s.deinit(t.allocator);
    const base = WorldState.cache_base_capacity;
    const cap = WorldState.cache_capacity;
    const zeros: [32]u8 = @splat(0);
    for (0..base) |i| try t.expect(s.installPinned(.{ .cx = @intCast(i), .cy = 0 }, zeros, &.{}));
    try t.expectEqual(@as(usize, 5184), s.chunk_count);
    const req = request(1, 0, 0);
    const original = try s.cut(req);
    try t.expect(original == .ok);
    s.unpin(.{ .cx = 0, .cy = 0 }); // The only unpinned row is dirty, so use overflow.
    try t.expect(s.installPinned(.{ .cx = @intCast(base), .cy = 0 }, zeros, &.{}));
    try t.expectEqual(base + 1, s.chunk_count);

    // Even above base, replace an eligible clean row rather than grow again.
    s.unpin(.{ .cx = 1, .cy = 0 });
    try t.expect(s.installPinned(.{ .cx = -2, .cy = 0 }, zeros, &.{}));
    try t.expect(!s.pin(.{ .cx = 1, .cy = 0 }));
    try t.expectEqual(base + 1, s.chunk_count);
    for (base + 1..cap) |i| try t.expect(s.installPinned(.{ .cx = @intCast(i), .cy = 0 }, zeros, &.{}));
    try t.expectEqual(@as(usize, 5184 + 512), s.chunk_count);
    try t.expect(s.pin(.{ .cx = -2, .cy = 0 }));
    s.unpin(.{ .cx = -2, .cy = 0 });
    try t.expect(!s.installPinned(.{ .cx = -1, .cy = 0 }, zeros, &.{}));
    try t.expect(!s.pin(.{ .cx = -1, .cy = 0 }));

    var cursor: usize = 0;
    const stale = s.nextDirty(&cursor).?;
    try t.expect(!s.installPinned(.{ .cx = -1, .cy = 0 }, zeros, &.{}));
    try t.expect(s.installPinned(.{ .cx = 0, .cy = 0 }, zeros, &.{}));
    try t.expect((try s.cut(request(2, 1, 0))) == .ok);
    s.unpin(.{ .cx = 0, .cy = 0 });
    try t.expect(!s.markSaved(stale));
    try t.expect(!s.installPinned(.{ .cx = -1, .cy = 0 }, zeros, &.{}));
    try t.expectEqual(@as(u8, 1), stale.bits[0]);
    cursor = 0;
    const snapshot = s.nextDirty(&cursor).?;
    try t.expectEqual(@as(u8, 3), snapshot.bits[0]);
    try t.expect(s.markSaved(snapshot));
    try t.expect(s.installPinned(.{ .cx = -1, .cy = 0 }, zeros, &.{}));
    try t.expect(!s.pin(.{ .cx = 0, .cy = 0 }));
    try t.expectEqual(zeros, try readChunk(&s, 0, 0));
    try t.expectEqualDeep(original, try s.cut(req));
    s.unpin(.{ .cx = -2, .cy = 0 });
    try t.expect(s.installPinned(.{ .cx = 0, .cy = 0 }, snapshot.bits, &.{}));
    try t.expectEqual(snapshot.bits, try readChunk(&s, 0, 0));
    try t.expect(!s.markSaved(snapshot));
    for (2..cap) |i| s.unpin(.{ .cx = @intCast(i), .cy = 0 });
    s.unpin(.{ .cx = -1, .cy = 0 });
    s.unpin(.{ .cx = 0, .cy = 0 });
}

test "persistent eviction prefers farthest from nearest player and survives sustained replacement" {
    var allocator = t.FailingAllocator.init(t.allocator, .{});
    var s = try WorldState.initPersistent(allocator.allocator());
    defer s.deinit(allocator.allocator());
    allocator.fail_index = allocator.alloc_index;
    const base = WorldState.cache_base_capacity;
    const bits: [32]u8 = @splat(0xff);
    // Only the first three rows are candidates. The row at x=200 is near
    // the second player, so x=100 loses rather than x=200.
    for (0..base) |i| {
        const cx: i32 = @intCast(if (i < 3) i * 100 else i + 200);
        try t.expect(s.installPinned(.{ .cx = cx, .cy = 0 }, bits, &.{}));
        if (i < 3) s.unpin(.{ .cx = cx, .cy = 0 });
    }
    const players = [_]p.Location{ .{ .x = 0, .y = 0 }, .{ .x = 16 * 200, .y = 0 } };
    try t.expect(s.installPinned(.{ .cx = -1000, .cy = 0 }, bits, &players));
    try t.expect(!s.pin(.{ .cx = 100, .cy = 0 }));
    try t.expectEqual(bits, try readChunk(&s, 0, 0));
    try t.expectEqual(bits, try readChunk(&s, 200, 0));
    s.unpin(.{ .cx = -1000, .cy = 0 });

    var prev_x: i32 = -1000;
    var prev_y: i32 = 0;
    for (0..base) |i| {
        const cx = prev_x - 1;
        const cy: i32 = @intCast(i % 2);
        try t.expect(s.installPinned(.{ .cx = cx, .cy = cy }, bits, &players));
        try t.expect(!s.pin(.{ .cx = prev_x, .cy = prev_y }));
        s.unpin(.{ .cx = cx, .cy = cy });
        prev_x = cx;
        prev_y = cy;
    }
    try t.expectEqual(base, s.chunk_count);
    try t.expectEqual(bits, try readChunk(&s, 200, 0));
    for (3..base) |i| s.unpin(.{ .cx = @intCast(i + 200), .cy = 0 });
    try t.expect(!allocator.has_induced_failure);
}

test "persistent overflow drains ranked victims into reusable slots without allocating" {
    var allocator = t.FailingAllocator.init(t.allocator, .{});
    var s = try WorldState.initPersistent(allocator.allocator());
    defer s.deinit(allocator.allocator());
    allocator.fail_index = allocator.alloc_index;
    const base = WorldState.cache_base_capacity;
    const bits: [32]u8 = @splat(0xa5);
    for (0..base + 2) |i| try t.expect(s.installPinned(.{ .cx = @intCast(i), .cy = 0 }, bits, &.{}));

    // Nearest-player distances for the four candidates are 0, 100, 200, 0 chunks.
    const players = [_]p.Location{ .{ .x = 0, .y = 0 }, .{ .x = 16 * 500, .y = 0 } };
    for ([_]i32{ 0, 100, 200, 500 }) |cx| s.unpin(.{ .cx = cx, .cy = 0 });
    s.trimOverflow(&players);
    try t.expectEqual(base, s.chunk_count);
    for ([_]i32{ 100, 200 }) |cx| try t.expect(!s.pin(.{ .cx = cx, .cy = 0 }));
    for ([_]i32{ 0, 500 }) |cx| {
        try t.expect(s.pin(.{ .cx = cx, .cy = 0 }));
        try t.expectEqual(bits, try readChunk(&s, cx, 0));
    }

    // With all survivors pinned, overflow can use both freed slots again.
    for ([_]i32{ 100, 200 }) |cx| try t.expect(s.installPinned(.{ .cx = cx, .cy = 0 }, @splat(0), &players));
    try t.expectEqual(base + 2, s.chunk_count);
    for ([_]i32{ 100, 200 }) |cx| try t.expectEqual(@as([32]u8, @splat(0)), try readChunk(&s, cx, 0));
    try t.expect(!allocator.has_induced_failure);
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
