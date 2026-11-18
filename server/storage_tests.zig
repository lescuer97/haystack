const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const world = shared.world;
const storage = @import("storage.zig");
const c = storage.c;
const request = storage.request;
const Fixture = @import("fixture.zig").Fixture;
const App = @import("app.zig").App;
const Context = @import("app.zig").Context;
fn find(terrain: world.Tile) p.Cut {
    for (0..256) |iy| for (0..256) |ix| {
        const x: i32 = @as(i32, @intCast(ix)) - 128;
        const y: i32 = @as(i32, @intCast(iy)) - 128;
        if (world.sampleTile(world.public_seed, x, y) == terrain) return .{ .x = x, .y = y };
    };
    unreachable;
}
test "BLOB id persistence replays original successes terminal errors conflicts and zero ID" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const db = &fixture.application.contexts[0].db;
    const terrains = [_]world.Tile{ .grass, .tree, .rock, .dirt, .water };
    var original: [terrains.len]p.CutResult = undefined;
    var requests: [terrains.len]p.Request = undefined;
    var before_water: p.Snapshot = undefined;
    var after_water: p.Snapshot = undefined;
    for (terrains, 0..) |terrain, i| {
        const tile = find(terrain);
        if (terrain == .water) try db.readArea(tileArea(tile), &before_water);
        requests[i] = request(i, tile.x, tile.y);
        original[i] = try db.cut(requests[i]);
        if (terrain == .grass or terrain == .tree) {
            try std.testing.expect(original[i].success.cut);
            try std.testing.expectEqual(terrain, original[i].success.terrain);
        } else try std.testing.expectEqual(p.ErrorCode.not_cuttable, original[i].failure.code);
        if (terrain == .water) {
            try db.readArea(tileArea(tile), &after_water);
            try std.testing.expectEqualDeep(before_water, after_water);
        }
    }
    const tile = find(.grass);
    const already = try db.cut(request(100, tile.x, tile.y));
    try std.testing.expectEqual(p.ErrorCode.already_cut, already.failure.code);
    fixture.application.deinit();
    fixture.application = try App.init(fixture.io, fixture.path, fixture.buffers);
    const reopened = &fixture.application.contexts[0].db;
    for (original, requests) |result, req| try std.testing.expectEqualDeep(result, try reopened.cut(req));
    try reopened.readArea(tileArea(find(.water)), &after_water);
    try std.testing.expectEqualDeep(before_water, after_water);
    try std.testing.expectEqualDeep(already, try reopened.cut(request(100, tile.x, tile.y)));
    try std.testing.expectEqual(p.ErrorCode.request_id_conflict, (try reopened.cut(request(0, tile.x + 1, tile.y))).failure.code);
    var changed = requests[0];
    changed.version = 2;
    try std.testing.expectEqual(p.ErrorCode.request_id_conflict, (try reopened.cut(changed)).failure.code);
}
test "bitmap negative coordinates order empty full boundaries complete rectangle and extremes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const db = &fixture.application.contexts[0].db;
    try db.exec("BEGIN; INSERT INTO chunk_state VALUES(-1,-1,x'0100000000000000000000000000000000000000000000000000000000000080'),(0,-1,x'0100000000000000000000000000000000000000000000000000000000000000'),(-1,0,x'0100000000000000000000000000000000000000000000000000000000000000'),(0,0,x'0000000000000000000000000000000000000000000000000000000000000080'); COMMIT;");
    var snapshot: p.Snapshot = undefined;
    try db.readArea(.{ .cx0 = -1, .cy0 = -1, .cx1 = 0, .cy1 = 0 }, &snapshot);
    try std.testing.expectEqual(@as(u16, 4), snapshot.count);
    try std.testing.expectEqual(@as(u8, 1), snapshot.chunks[0][0]);
    try std.testing.expectEqual(@as(u8, 128), snapshot.chunks[0][31]);
    try std.testing.expectEqual(@as(u8, 1), snapshot.chunks[1][0]);
    try std.testing.expectEqual(@as(u8, 1), snapshot.chunks[2][0]);
    try std.testing.expectEqual(@as(u8, 128), snapshot.chunks[3][31]);
    try db.readArea(.{ .cx0 = 10, .cy0 = 10, .cx1 = 17, .cy1 = 17 }, &snapshot);
    try std.testing.expectEqual(@as(u16, 64), snapshot.count);
    for (snapshot.chunks) |chunk| try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &chunk);
    try db.exec("INSERT INTO chunk_state VALUES(2,2,x'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff')");
    try db.readArea(.{ .cx0 = 2, .cy0 = 2, .cx1 = 2, .cy1 = 2 }, &snapshot);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(255)), &snapshot.chunks[0]);
    for ([_]i32{ std.math.minInt(i32), std.math.maxInt(i32) }, 0..) |x, i| {
        const result = try db.cut(request(800 + i, x, x));
        const cx = @divFloor(x, 16);
        try db.readArea(.{ .cx0 = cx, .cy0 = cx, .cx1 = cx, .cy1 = cx }, &snapshot);
        var count: usize = 0;
        for (snapshot.chunks[0]) |byte| count += @popCount(byte);
        try std.testing.expectEqual(@as(usize, if (result == .success) 1 else 0), count);
    }
}
// Locate the actual cached production SELECT without depending on enum indices
// or exposing a test-only Storage API.
fn areaStatement(db: *storage.Storage) !*c.sqlite3_stmt {
    var stmt = c.sqlite3_next_stmt(db.db, null);
    while (stmt) |s| : (stmt = c.sqlite3_next_stmt(db.db, s)) {
        if (std.mem.startsWith(u8, std.mem.span(c.sqlite3_sql(s)), "SELECT cx,cy,cuts FROM chunk_state WHERE cx")) return s;
    }
    return error.MissingAreaStatement;
}
test "area bindings refresh all widths heights signs and permitted extremes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const db = &fixture.application.contexts[0].db;
    var snapshot: p.Snapshot = undefined;
    const areas = [_]world.ChunkRange{
        .{ .cx0 = -4, .cy0 = -64, .cx1 = -4, .cy1 = -1 },
        .{ .cx0 = -8, .cy0 = -8, .cx1 = -1, .cy1 = -1 },
        .{ .cx0 = 20, .cy0 = -12, .cx1 = 27, .cy1 = -12 },
        .{ .cx0 = 10, .cy0 = 12, .cx1 = 73, .cy1 = 12 },
        .{ .cx0 = -134217728, .cy0 = -134217728, .cx1 = -134217665, .cy1 = -134217728 },
        .{ .cx0 = 134217727, .cy0 = 134217664, .cx1 = 134217727, .cy1 = 134217727 },
        .{ .cx0 = -2, .cy0 = 7, .cx1 = -2, .cy1 = 7 },
    };
    for (areas) |area| {
        try db.exec("DELETE FROM chunk_state");
        try db.readArea(area, &snapshot);
        for (snapshot.chunks[0..snapshot.count]) |chunk| try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &chunk);
        const cols = @as(i64, area.cx1) - area.cx0 + 1;
        const count = cols * (@as(i64, area.cy1) - area.cy0 + 1);
        var sql_buffer: [512]u8 = undefined;
        const sql = try std.fmt.bufPrintSentinel(&sql_buffer, "WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<{d}) INSERT INTO chunk_state SELECT {d}+i%{d},{d}+i/{d},x'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' FROM n", .{ count - 1, area.cx0, cols, area.cy0, cols }, 0);
        try db.exec(sql);
        try db.readArea(area, &snapshot);
        try std.testing.expectEqual(@as(u16, @intCast(count)), snapshot.count);
        for (snapshot.chunks[0..snapshot.count]) |chunk| try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(255)), &chunk);
        // Back-to-back disjoint reads must clear both column and row bindings,
        // and must not leak old full bitmaps into empty chunks.
        try db.readArea(.{ .cx0 = 1000, .cy0 = 1000, .cx1 = 1007, .cy1 = 1007 }, &snapshot);
        for (snapshot.chunks) |chunk| try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &chunk);
        try db.readArea(area, &snapshot);
        for (snapshot.chunks[0..snapshot.count]) |chunk| try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(255)), &chunk);
        // Count raw rows too: OR-ing duplicate rows would hide duplicates.
        const stmt = try areaStatement(db);
        _ = c.sqlite3_stmt_status(stmt, c.SQLITE_STMTSTATUS_VM_STEP, 1);
        for (0..64) |i| try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(stmt, @intCast(i + 1), @as(i64, area.cx0) + if (i < cols) @as(i64, @intCast(i)) else 0));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(stmt, 65, area.cy0));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(stmt, 66, area.cy1));
        var rows: usize = 0;
        var rc = c.sqlite3_step(stmt);
        while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(stmt)) rows += 1;
        try std.testing.expectEqual(c.SQLITE_DONE, rc);
        try std.testing.expectEqual(@as(usize, @intCast(count)), rows);
        try std.testing.expect(c.sqlite3_stmt_status(stmt, c.SQLITE_STMTSTATUS_VM_STEP, 1) < 2000);
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_reset(stmt));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_clear_bindings(stmt));
    }
}
test "production area query bounds VM work despite growing out of range history" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const db = &fixture.application.contexts[0].db;
    const stmt = try areaStatement(db);
    try db.exec("INSERT INTO chunk_state VALUES(0,0,x'0100000000000000000000000000000000000000000000000000000000000000'),(7,7,x'0100000000000000000000000000000000000000000000000000000000000000')");
    var snapshot: p.Snapshot = undefined;
    for ([_]usize{ 10000, 100000 }) |outside| {
        var sql_buffer: [512]u8 = undefined;
        const sql = try std.fmt.bufPrintSentinel(&sql_buffer, "BEGIN IMMEDIATE; WITH RECURSIVE n(i) AS (VALUES({d}) UNION ALL SELECT i+1 FROM n WHERE i<{d}) INSERT INTO chunk_state SELECT i%8,100+i/8,zeroblob(32) FROM n; COMMIT;", .{ if (outside == 10000) @as(usize, 0) else 10000, outside - 1 }, 0);
        try db.exec(sql);
        _ = c.sqlite3_stmt_status(stmt, c.SQLITE_STMTSTATUS_VM_STEP, 1);
        try db.readArea(.{ .cx0 = 0, .cy0 = 0, .cx1 = 7, .cy1 = 7 }, &snapshot);
        const steps = c.sqlite3_stmt_status(stmt, c.SQLITE_STMTSTATUS_VM_STEP, 1);
        std.debug.print("AREA_QUERY,outside={d},vm_steps={d}\n", .{ outside, steps });
        // Old cx BETWEEN query performs >60k / >600k steps here. Do not use
        // FULLSCAN_STEP: an unbounded index range scan need not increment it.
        try std.testing.expect(steps < 2000);
        try std.testing.expectEqual(@as(u8, 1), snapshot.chunks[0][0]);
        try std.testing.expectEqual(@as(u8, 1), snapshot.chunks[63][0]);
        var bits: usize = 0;
        for (snapshot.chunks) |chunk| for (chunk) |byte| {
            bits += @popCount(byte);
        };
        try std.testing.expectEqual(@as(usize, 2), bits);
    }
    var explain_buffer: [1024]u8 = undefined;
    const explain_sql = try std.fmt.bufPrintSentinel(&explain_buffer, "EXPLAIN QUERY PLAN {s}", .{c.sqlite3_sql(stmt)}, 0);
    var explain: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db.db, explain_sql, -1, &explain, null));
    defer _ = c.sqlite3_finalize(explain);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(explain));
    const plan = std.mem.span(c.sqlite3_column_text(explain, 3));
    std.debug.print("AREA_QUERY,plan={s}\n", .{plan});
    try std.testing.expect(std.mem.indexOf(u8, plan, "USING PRIMARY KEY (cx=? AND cy>? AND cy<?)") != null);
}
test "four cached area SELECTs simultaneously active fit unchanged SQLite heap" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.application.contexts[0].db.exec("WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<63) INSERT INTO chunk_state SELECT i,0,zeroblob(32) FROM n");
    var statements: [4]*c.sqlite3_stmt = undefined;
    var active: usize = 0;
    defer for (statements[0..active]) |stmt| {
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
    };
    _ = c.sqlite3_memory_highwater(1);
    for (fixture.application.contexts, &statements) |*context, *s| {
        s.* = try areaStatement(&context.db);
        active += 1;
        try std.testing.expectEqual(@as(c_int, 66), c.sqlite3_bind_parameter_count(s.*));
        for (0..64) |i| try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(s.*, @intCast(i + 1), @intCast(i)));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(s.*, 65, 0));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(s.*, 66, 0));
        // SQLITE_ROW keeps each statement's temporary IN B-tree alive.
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(s.*));
    }
    std.debug.print("AREA_ACTIVE,current={d},highwater={d},ceiling={d}\n", .{ c.sqlite3_memory_used(), fixture.runtime.highWater(), fixture.heap.len });
    try std.testing.expect(fixture.runtime.highWater() < fixture.heap.len / 2);
    for (statements) |stmt| {
        var rows: usize = 1;
        var rc = c.sqlite3_step(stmt);
        while (rc == c.SQLITE_ROW) : (rc = c.sqlite3_step(stmt)) rows += 1;
        try std.testing.expectEqual(c.SQLITE_DONE, rc);
        try std.testing.expectEqual(@as(usize, 64), rows);
    }
}
test "trigger rollback transient busy and no mutation before a healthy lease" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const db = &fixture.application.contexts[0].db;
    const tile = find(.grass);
    const req = request(44, tile.x, tile.y);
    try db.exec("CREATE TRIGGER fail_result BEFORE INSERT ON action_results BEGIN SELECT RAISE(ABORT,'injected'); END");
    try std.testing.expectError(error.DatabaseFailure, db.cut(req));
    try std.testing.expect(c.sqlite3_get_autocommit(db.db) != 0);
    try std.testing.expect(!db.poisoned);
    try db.exec("DROP TRIGGER fail_result");
    const other = &fixture.application.contexts[1].db;
    try other.exec("BEGIN IMMEDIATE");
    try std.testing.expectError(error.DatabaseBusy, db.cut(req));
    try other.exec("ROLLBACK");
    try std.testing.expect((try db.cut(req)) == .success);
    var leases: [4]*Context = undefined;
    for (&leases) |*lease| lease.* = fixture.application.lease().?;
    try std.testing.expect(fixture.application.lease() == null);
    var error_storage: [33]u8 = undefined;
    const bytes = shared.wire.encode(&error_storage, shared.wire.failure(req.request_id, .database_busy));
    try std.testing.expectEqualSlices(u8, &.{ 12, 0, 0 }, bytes[20..]);
    for (leases) |lease| fixture.application.release(lease);
    // Explicit quarantine rebuild: no action replay and the connection is replaced in-pool.
    const lease = fixture.application.lease().?;
    lease.db.poisoned = true;
    fixture.application.release(lease);
    try std.testing.expect(!lease.db.poisoned);
}
test "two independently leased writer threads one tile exactly one winner" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const tile = find(.grass);
    const Worker = struct {
        app: *App,
        req: p.Request,
        result: ?p.CutResult = null,
        fn run(self: *@This()) void {
            const context = self.app.lease() orelse @panic("no lease");
            defer self.app.release(context);
            self.result = context.db.cut(self.req) catch @panic("DB failed");
        }
    };
    var a = Worker{ .app = &fixture.application, .req = request(1, tile.x, tile.y) };
    var b = Worker{ .app = &fixture.application, .req = request(2, tile.x, tile.y) };
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{&a});
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{&b});
    t1.join();
    t2.join();
    try std.testing.expectEqual(@as(u8, 1), @as(u8, @intFromBool(a.result.? == .success)) + @as(u8, @intFromBool(b.result.? == .success)));
    const loser = if (a.result.? == .failure) a.result.? else b.result.?;
    try std.testing.expectEqual(p.ErrorCode.already_cut, loser.failure.code);
}
test "SQLite heap OOM rolls back and startup budgets fail closed" {
    try std.testing.expectError(error.InvalidSqliteBudget, Fixture.initBudget(1024));
    // The minimum heap initializes SQLite but cannot admit four prepared contexts.
    if (Fixture.initBudget(65536)) |value| {
        var f = value;
        f.deinit();
        return error.ExpectedStartupFailure;
    } else |_| {}
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try std.testing.expectEqual(@as(c_int, 3054000), c.sqlite3_libversion_number());
    for ([_][*:0]const u8{ "ENABLE_MEMSYS5", "ZERO_MALLOC", "OMIT_AUTOINIT", "THREADSAFE=1" }) |option| try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_compileoption_used(option));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_compileoption_used("SYSTEM_MALLOC"));
    var short: [1]u8 align(@alignOf(@import("app.zig").Layout)) = undefined;
    try std.testing.expectError(error.InsufficientApplicationBudget, App.init(fixture.io, fixture.path, &short));
    const context = fixture.application.lease().?;
    defer fixture.application.release(context);
    const tile = find(.grass);
    // A real memsys5 exhaustion after inserting the tile: no upstream malloc fallback.
    try std.testing.expect(c.sqlite3_malloc64(@intCast(fixture.heap.len * 2)) == null);
    try context.db.exec("CREATE TRIGGER oom_result BEFORE INSERT ON action_results BEGIN SELECT length(randomblob(67108864)); END");
    const outcome = context.db.cut(request(9, tile.x, tile.y));
    try std.testing.expectError(error.SqliteOutOfMemory, outcome);
    try std.testing.expect(c.sqlite3_get_autocommit(context.db.db) != 0 or context.db.poisoned);
    if (!context.db.poisoned) {
        try context.db.exec("DROP TRIGGER oom_result");
        try std.testing.expect((try context.db.cut(request(9, tile.x, tile.y))) == .success);
    }
}
test "failed rollback quarantines context and rebuild never repeats the action" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const context = fixture.application.lease().?;
    const tile = find(.grass);
    try context.db.exec("CREATE TRIGGER fail_result BEFORE INSERT ON action_results BEGIN SELECT RAISE(ABORT,'injected'); END");
    const Authorizer = struct {
        fn auth(_: ?*anyopaque, action: c_int, a: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
            if (action == c.SQLITE_TRANSACTION and a != null and std.mem.eql(u8, std.mem.span(a), "ROLLBACK")) return c.SQLITE_DENY;
            return c.SQLITE_OK;
        }
    };
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(context.db.db, Authorizer.auth, null));
    var observer = FakeObserver{};
    try std.testing.expectError(error.DatabaseFailure, context.db.cutObserved(request(300, tile.x, tile.y), &observer));
    try observer.expect(&.{ .begin, .replay, .rules, .chunk_upsert, .result_insert, .cleanup }, error.DatabaseFailure);
    try std.testing.expect(context.db.poisoned);
    fixture.application.release(context);
    try std.testing.expect(!context.db.poisoned);
    var snapshot: p.Snapshot = undefined;
    const cx = @divFloor(tile.x, 16);
    const cy = @divFloor(tile.y, 16);
    try context.db.readArea(.{ .cx0 = cx, .cy0 = cy, .cx1 = cx, .cy1 = cy }, &snapshot);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &snapshot.chunks[0]);
    try context.db.exec("DROP TRIGGER fail_result");
    try std.testing.expect((try context.db.cut(request(300, tile.x, tile.y))) == .success);
}
test "no healthy contexts returns fixed binary busy and in-pool rebuild can recover later" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    for (fixture.application.contexts) |*context| context.db.poisoned = true;
    _ = c.sqlite3_hard_heap_limit64(1);
    defer _ = c.sqlite3_hard_heap_limit64(0);
    try std.testing.expect(fixture.application.lease() == null);
    for (fixture.application.contexts) |*context| try std.testing.expect(context.db.poisoned);
    var bytes: [33]u8 = undefined;
    const busy = shared.wire.encode(&bytes, shared.wire.failure(@as(p.Id, @splat(0)), .database_busy));
    try std.testing.expectEqualSlices(u8, &.{ 12, 0, 0 }, busy[20..]);
    _ = c.sqlite3_hard_heap_limit64(0);
    // This call rebuilds unavailable contexts, but never executes the rejected action.
    try std.testing.expect(fixture.application.lease() == null);
    const recovered = fixture.application.lease().?;
    fixture.application.release(recovered);
}
test "one SELECT snapshot remains consistent during atomic concurrent rectangle replacement" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const Writer = struct {
        db: *storage.Storage,
        fn run(self: *@This()) void {
            for (0..16) |_| {
                self.db.exec("BEGIN IMMEDIATE; WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<63) INSERT INTO chunk_state SELECT i%8,i/8,x'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' FROM n; COMMIT;") catch @panic("insert failed");
                self.db.exec("BEGIN IMMEDIATE; DELETE FROM chunk_state; COMMIT;") catch @panic("delete failed");
            }
        }
    };
    var writer = Writer{ .db = &fixture.application.contexts[1].db };
    const thread = try std.Thread.spawn(.{}, Writer.run, .{&writer});
    defer thread.join();
    var snapshot: p.Snapshot = undefined;
    for (0..256) |_| {
        try fixture.application.contexts[0].db.readArea(.{ .cx0 = 0, .cy0 = 0, .cx1 = 7, .cy1 = 7 }, &snapshot);
        var count: usize = 0;
        for (snapshot.chunks) |chunk| for (chunk) |byte| {
            count += @popCount(byte);
        };
        try std.testing.expect(count == 0 or count == 64 * 256);
    }
}
test "post-ready codec rules storage have no upstream allocator capability" {
    const Guard = struct {
        frozen: bool = false,
        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.frozen) @panic("upstream allocation after ready");
            return std.testing.allocator.rawAlloc(len, alignment, ret);
        }
        fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.frozen) @panic("upstream free after ready");
            std.testing.allocator.rawFree(bytes, alignment, ret);
        }
    };
    var guard = Guard{};
    const allocator = std.mem.Allocator{ .ptr = &guard, .vtable = &.{ .alloc = Guard.alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = Guard.free } };
    var fixture = try Fixture.initWith(allocator, std.testing.io, @import("sqlite_runtime.zig").default_budget);
    defer {
        guard.frozen = false;
        fixture.deinit();
    }
    guard.frozen = true;
    // Freeze the actual fixture startup allocator. SQLite is checked separately:
    // a Zig allocator trap cannot instrument C's internal allocation calls.
    var buf: [36]u8 = undefined;
    for (0..512) |i| {
        const req = request(i, @intCast(i), -8);
        const decoded = shared.wire.decode(shared.wire.encodeRequest(&buf, req)).request;
        const context = fixture.application.lease().?;
        const bytes = context.handle(decoded);
        try std.testing.expect(bytes.len == 30 or bytes.len == 23 or bytes.len == 33);
        fixture.application.release(context);
    }
    const context = fixture.application.lease().?;
    defer fixture.application.release(context);
    const area = p.Request{ .request_id = @splat(0), .operation = .{ .read_area = .{ .cx0 = -4, .cy0 = -4, .cx1 = 3, .cy1 = 3 } } };
    for (0..64) |_| try std.testing.expectEqual(@as(usize, 2122), context.handle(area).len);
    std.debug.print("BUDGET,sqlite_highwater={d},app_context_bytes={d}\n", .{ fixture.runtime.highWater(), @sizeOf([4]Context) });
}

test "fresh database has schema 4 generator 2 and public zero seed" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const db = &fixture.application.contexts[0].db;
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db.db, "SELECT id,schema_version,generator_version,public_seed FROM metadata", -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(stmt, 0));
    try std.testing.expectEqual(@as(i64, 4), c.sqlite3_column_int64(stmt, 1));
    try std.testing.expectEqual(@as(i64, 2), c.sqlite3_column_int64(stmt, 2));
    try std.testing.expectEqual(@as(c_int, 32), c.sqlite3_column_bytes(stmt, 3));
    const seed: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 3).?);
    try std.testing.expectEqualSlices(u8, &world.public_seed, seed[0..32]);
    try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(stmt));
}

test "old and independently mismatched versions reject while retaining metadata chunks and IDs" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const db = &fixture.application.contexts[0].db;
    const tile = find(.grass);
    const req = request(88, tile.x, tile.y);
    try std.testing.expect((try db.cut(req)) == .success);
    const versions = [_][2]i32{ .{ 3, 1 }, .{ 4, 1 }, .{ 3, 2 }, .{ 4, 3 }, .{ 5, 2 } };
    for (versions) |version| {
        var sql_buffer: [128]u8 = undefined;
        try db.exec(try std.fmt.bufPrintSentinel(&sql_buffer, "UPDATE metadata SET schema_version={d},generator_version={d}", .{ version[0], version[1] }, 0));
        var reopened = try storage.Storage.open(fixture.path);
        defer reopened.close();
        try std.testing.expectError(error.IncompatibleDatabase, reopened.initialize());
        var stmt: ?*c.sqlite3_stmt = null;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db.db, "SELECT schema_version,generator_version,(SELECT count(*) FROM chunk_state),(SELECT count(*) FROM action_results),cuts FROM metadata,chunk_state", -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
        try std.testing.expectEqual(@as(i64, version[0]), c.sqlite3_column_int64(stmt, 0));
        try std.testing.expectEqual(@as(i64, version[1]), c.sqlite3_column_int64(stmt, 1));
        try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(stmt, 2));
        try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(stmt, 3));
        const bitmap: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 4).?);
        var expected: [32]u8 = @splat(0);
        const bit: usize = @intCast(@mod(tile.y, 16) * 16 + @mod(tile.x, 16));
        expected[bit / 8] |= @as(u8, 1) << @as(u3, @intCast(bit % 8));
        try std.testing.expectEqual(@as(c_int, 32), c.sqlite3_column_bytes(stmt, 4));
        try std.testing.expectEqualSlices(u8, &expected, bitmap[0..32]);
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(stmt));
        try std.testing.expect((try db.cut(req)) == .success);
    }
}

test "schema 2 is rejected without rewriting existing data" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const db = &fixture.application.contexts[0].db;
    // Controlled old-version fixture; initialization must not migrate or delete it.
    try db.exec("DROP TABLE chunk_state; CREATE TABLE cuts(x INTEGER,y INTEGER); INSERT INTO cuts VALUES(7,-9); UPDATE metadata SET schema_version=2");
    var reopened = try storage.Storage.open(fixture.path);
    defer reopened.close();
    try std.testing.expectError(error.IncompatibleDatabase, reopened.initialize());
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db.db, "SELECT schema_version,x,y FROM metadata,cuts", -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 2), c.sqlite3_column_int64(stmt, 0));
    try std.testing.expectEqual(@as(i64, 7), c.sqlite3_column_int64(stmt, 1));
    try std.testing.expectEqual(@as(i64, -9), c.sqlite3_column_int64(stmt, 2));
    try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(stmt));
}

test "corrupt bitmap lengths types and coordinate types fail closed" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const db = &fixture.application.contexts[0].db;
    var snapshot: p.Snapshot = undefined;
    const area = world.ChunkRange{ .cx0 = 0, .cy0 = 0, .cx1 = 0, .cy1 = 0 };
    try db.exec("PRAGMA ignore_check_constraints=ON; INSERT INTO chunk_state VALUES(0,0,zeroblob(31))");
    try std.testing.expectError(error.DatabaseFailure, db.readArea(area, &snapshot));
    try std.testing.expectError(error.DatabaseFailure, db.cut(request(1, 0, 0)));
    try db.exec("UPDATE chunk_state SET cuts=zeroblob(33)");
    try std.testing.expectError(error.DatabaseFailure, db.readArea(area, &snapshot));
    try std.testing.expectError(error.DatabaseFailure, db.cut(request(1, 0, 0)));
    try db.exec("DELETE FROM chunk_state; INSERT INTO chunk_state VALUES(134217728,0,zeroblob(32)); PRAGMA ignore_check_constraints=OFF");
    try std.testing.expectError(error.InvalidArea, db.readArea(.{ .cx0 = 134217728, .cy0 = 0, .cx1 = 134217728, .cy1 = 0 }, &snapshot));
    // STRICT rejects non-BLOB/non-INTEGER writes. Test runtime defenses with a
    // deliberately replaced local fixture view, never a production bypass.
    try db.exec("DROP TABLE chunk_state; CREATE VIEW chunk_state AS SELECT 0 AS cx,0 AS cy,'00000000000000000000000000000000' AS cuts");
    try std.testing.expectError(error.DatabaseFailure, db.readArea(area, &snapshot));
    try std.testing.expectError(error.DatabaseFailure, db.cut(request(1, 0, 0)));
    try db.exec("DROP VIEW chunk_state; CREATE VIEW chunk_state AS SELECT 0.0 AS cx,0 AS cy,zeroblob(32) AS cuts");
    try std.testing.expectError(error.DatabaseFailure, db.readArea(area, &snapshot));
    try db.exec("DROP VIEW chunk_state; CREATE VIEW chunk_state AS SELECT 0 AS cx,0.0 AS cy,zeroblob(32) AS cuts");
    try std.testing.expectError(error.DatabaseFailure, db.readArea(area, &snapshot));
    try std.testing.expect(!db.poisoned);
}

fn sameChunkTiles() [2]p.Cut {
    for (0..8) |cy| for (0..8) |cx| {
        var grass: ?p.Cut = null;
        var tree: ?p.Cut = null;
        for (0..16) |y| for (0..16) |x| {
            const tile = p.Cut{ .x = @as(i32, @intCast(cx * 16 + x)) - 128, .y = @as(i32, @intCast(cy * 16 + y)) - 128 };
            switch (world.sampleTile(world.public_seed, tile.x, tile.y)) {
                .grass => grass = tile,
                .tree => tree = tile,
                else => {},
            }
        };
        if (grass != null and tree != null) return .{ grass.?, tree.? };
    };
    unreachable;
}
fn tileArea(tile: p.Cut) world.ChunkRange {
    const cx = @divFloor(tile.x, 16);
    const cy = @divFloor(tile.y, 16);
    return .{ .cx0 = cx, .cy0 = cy, .cx1 = cx, .cy1 = cy };
}

test "independent writers preserve different grass and tree bits in the same chunk and replay IDs" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const tiles = sameChunkTiles();
    const Worker = struct {
        db: *storage.Storage,
        req: p.Request,
        result: ?p.CutResult = null,
        fn run(self: *@This()) void {
            self.result = self.db.cut(self.req) catch @panic("writer failed");
        }
    };
    var a = Worker{ .db = &fixture.application.contexts[0].db, .req = request(0, tiles[0].x, tiles[0].y) };
    var b = Worker{ .db = &fixture.application.contexts[1].db, .req = request(1, tiles[1].x, tiles[1].y) };
    const ta = try std.Thread.spawn(.{}, Worker.run, .{&a});
    const tb = try std.Thread.spawn(.{}, Worker.run, .{&b});
    ta.join();
    tb.join();
    try std.testing.expect(a.result.? == .success and b.result.? == .success);
    try std.testing.expectEqualDeep(a.result.?, try b.db.cut(a.req));
    try std.testing.expectEqualDeep(b.result.?, try a.db.cut(b.req));
    var snapshot: p.Snapshot = undefined;
    try a.db.readArea(tileArea(tiles[0]), &snapshot);
    var expected: [32]u8 = @splat(0);
    for (tiles) |tile| {
        const bit: usize = @intCast(@mod(tile.y, 16) * 16 + @mod(tile.x, 16));
        expected[bit / 8] |= @as(u8, 1) << @as(u3, @intCast(bit % 8));
    }
    try std.testing.expectEqualSlices(u8, &expected, &snapshot.chunks[0]);
}

test "failed result insert rolls back existing chunk upsert and does not cache failed ID" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const db = &fixture.application.contexts[0].db;
    const tiles = sameChunkTiles();
    _ = try db.cut(request(0, tiles[0].x, tiles[0].y));
    var before: p.Snapshot = undefined;
    var after: p.Snapshot = undefined;
    const area = tileArea(tiles[0]);
    try db.readArea(area, &before);
    try db.exec("CREATE TRIGGER fail_result BEFORE INSERT ON action_results BEGIN SELECT RAISE(ABORT,'injected'); END");
    const req = request(1, tiles[1].x, tiles[1].y);
    try std.testing.expectError(error.DatabaseFailure, db.cut(req));
    try db.readArea(area, &after);
    try std.testing.expectEqualDeep(before, after);
    try db.exec("DROP TRIGGER fail_result");
    // Reusing the failed ID for a different payload must not conflict.
    try std.testing.expectEqual(p.ErrorCode.already_cut, (try db.cut(request(1, tiles[0].x, tiles[0].y))).failure.code);
    try std.testing.expect((try db.cut(request(2, tiles[1].x, tiles[1].y))) == .success);
}

test "negative chunk writes cover bit and byte boundaries without changing terrain rules" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const db = &fixture.application.contexts[0].db;
    var expected: [32]u8 = @splat(0);
    for (0..256) |bit| {
        const x = @as(i32, @intCast(bit % 16)) - 16;
        const y = @as(i32, @intCast(bit / 16)) - 16;
        const terrain = world.sampleTile(world.public_seed, x, y);
        const result = try db.cut(request(bit, x, y));
        if (terrain == .grass or terrain == .tree) {
            try std.testing.expect(result == .success);
            expected[bit / 8] |= @as(u8, 1) << @as(u3, @intCast(bit % 8));
        } else try std.testing.expectEqual(p.ErrorCode.not_cuttable, result.failure.code);
    }
    var snapshot: p.Snapshot = undefined;
    try db.readArea(.{ .cx0 = -1, .cy0 = -1, .cx1 = -1, .cy1 = -1 }, &snapshot);
    try std.testing.expectEqualSlices(u8, &expected, &snapshot.chunks[0]);
}

const FakeObserver = struct {
    starts: usize = 0,
    finishes: usize = 0,
    stages: [8]storage.WriteStage = undefined,
    count: usize = 0,
    err: ?anyerror = null,
    result: ?p.CutResult = null,
    pub fn start(self: *@This()) void {
        self.starts += 1;
    }
    pub fn stage(self: *@This(), value: storage.WriteStage) void {
        self.stages[self.count] = value;
        self.count += 1;
    }
    pub fn finish(self: *@This(), err: ?anyerror, result: ?p.CutResult) void {
        self.finishes += 1;
        self.err = err;
        self.result = result;
    }
    fn expect(self: *@This(), stages: []const storage.WriteStage, err: ?anyerror) !void {
        try std.testing.expectEqual(@as(usize, 1), self.starts);
        try std.testing.expectEqual(@as(usize, 1), self.finishes);
        try std.testing.expectEqualSlices(storage.WriteStage, stages, self.stages[0..self.count]);
        try std.testing.expectEqual(err, self.err);
        try std.testing.expect((err == null) == (self.result != null));
    }
};

test "write observer stages finalize exactly once for success replay conflict busy rule and injected errors" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const db = &fixture.application.contexts[0].db;
    const tiles = sameChunkTiles();
    const req = request(0, tiles[0].x, tiles[0].y);
    var observer = FakeObserver{};
    const original = try db.cutObserved(req, &observer);
    try observer.expect(&.{ .begin, .replay, .rules, .chunk_upsert, .result_insert, .commit, .cleanup }, null);
    try std.testing.expectEqualDeep(original, observer.result.?);
    observer = .{};
    try std.testing.expectEqualDeep(original, try db.cutObserved(req, &observer));
    try observer.expect(&.{ .begin, .replay, .commit, .cleanup }, null);
    observer = .{};
    try std.testing.expectEqual(p.ErrorCode.request_id_conflict, (try db.cutObserved(request(0, tiles[1].x, tiles[1].y), &observer)).failure.code);
    try observer.expect(&.{ .begin, .replay, .commit, .cleanup }, null);
    observer = .{};
    try std.testing.expectEqual(p.ErrorCode.already_cut, (try db.cutObserved(request(1, tiles[0].x, tiles[0].y), &observer)).failure.code);
    try observer.expect(&.{ .begin, .replay, .rules, .result_insert, .commit, .cleanup }, null);
    const other = &fixture.application.contexts[1].db;
    try other.exec("BEGIN IMMEDIATE");
    observer = .{};
    try std.testing.expectError(error.DatabaseBusy, db.cutObserved(req, &observer));
    try observer.expect(&.{ .begin, .cleanup }, error.DatabaseBusy);
    try other.exec("ROLLBACK");
    try db.exec("CREATE TRIGGER fail_result BEFORE INSERT ON action_results BEGIN SELECT RAISE(ABORT,'injected'); END");
    observer = .{};
    const next = request(2, tiles[1].x, tiles[1].y);
    try std.testing.expectError(error.DatabaseFailure, db.cutObserved(next, &observer));
    try observer.expect(&.{ .begin, .replay, .rules, .chunk_upsert, .result_insert, .cleanup }, error.DatabaseFailure);
    try std.testing.expect(c.sqlite3_get_autocommit(db.db) != 0);
    try db.exec("DROP TRIGGER fail_result");
    const Authorizer = struct {
        fn auth(_: ?*anyopaque, action: c_int, a: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
            if (action == c.SQLITE_TRANSACTION and a != null and std.mem.eql(u8, std.mem.span(a), "COMMIT")) return c.SQLITE_DENY;
            return c.SQLITE_OK;
        }
    };
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(db.db, Authorizer.auth, null));
    observer = .{};
    try std.testing.expectError(error.DatabaseFailure, db.cutObserved(next, &observer));
    try observer.expect(&.{ .begin, .replay, .rules, .chunk_upsert, .result_insert, .commit, .cleanup }, error.DatabaseFailure);
    try std.testing.expect(c.sqlite3_get_autocommit(db.db) != 0);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(db.db, null, null));
    try std.testing.expect((try db.cut(next)) == .success);
    db.poisoned = true;
    observer = .{};
    try std.testing.expectError(error.PoisonedConnection, db.cutObserved(req, &observer));
    try observer.expect(&.{.cleanup}, error.PoisonedConnection);
}
