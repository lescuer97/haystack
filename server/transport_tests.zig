//! Production admission/cleanup and location helper, deliberately no socket use.
const std = @import("std");
const ws = @import("websocket");
const shared = @import("shared");
const p = shared.protocol;
const Handler = @import("transport.zig").Handler;
const Fixture = @import("fixture.zig").Fixture;
const sessions = @import("sessions.zig");
const c = @import("storage.zig").c;
fn handshake(url: []const u8) ws.Handshake {
    var result: ws.Handshake = undefined;
    result.url = url;
    return result;
}
fn rows(f: *Fixture) !i64 {
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(f.application.contexts[0].db.db, "SELECT (SELECT count(*) FROM action_results)+(SELECT count(*) FROM chunk_state)", -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    return c.sqlite3_column_int64(stmt, 0);
}
test "production admission close failed-upgrade cleanup fresh reconnect and stable App copy" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var dummy: ws.Conn = undefined; // init/close must never inspect or write this connection.
    var bad = handshake("/");
    try std.testing.expectError(error.InvalidPubkey, Handler.init(&bad, &dummy, &fixture.application));
    var hs = handshake("/?pubkey=" ++ @as([66]u8, @splat('a')));
    var original = try Handler.init(&hs, &dummy, &fixture.application);
    try std.testing.expect(fixture.application.registry.get(original.session).?.location == null);
    hs.url = "/?pubkey=" ++ @as([66]u8, @splat('A'));
    try std.testing.expectError(error.DuplicatePubkey, Handler.init(&hs, &dummy, &fixture.application));
    var copied = fixture.application;
    try std.testing.expectEqual(fixture.application.registry, copied.registry);
    try copied.registry.update(original.session, .{ .x = 0, .y = 0 });
    try std.testing.expect(fixture.application.registry.get(original.session).?.location != null);
    // Vendor cleanup invokes this same hook after handler assignment if HTTP101 write fails.
    original.close();
    var fresh = try Handler.init(&hs, &dummy, &fixture.application);
    try std.testing.expect(fixture.application.registry.get(fresh.session).?.location == null);
    original.close();
    try std.testing.expect(fixture.application.registry.get(fresh.session) != null);
    fresh.close();
    fresh.close();
    for (fixture.application.registry.slots) |slot| try std.testing.expect(!slot.occupied);
    var shutdown = try Handler.init(&hs, &dummy, &fixture.application);
    try fixture.application.registry.update(shutdown.session, .{ .x = 3, .y = 4 });
    shutdown.close(); // callbacks drained before App.deinit
    fixture.application.deinit();
    for (fixture.application.registry.slots) |slot| {
        try std.testing.expect(!slot.occupied and slot.location == null);
    }
    // Restore the fixture's owning App so its standard teardown remains valid.
    fixture.application = try @import("app.zig").App.init(fixture.io, fixture.path, fixture.buffers);
}
test "production location helper bypasses all leased databases no replay cache or durable state" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    const before = try rows(&fixture);
    var leases: [4]*@import("app.zig").Context = undefined;
    for (&leases) |*lease| lease.* = app.lease().?;
    const handle = try app.registry.claim(@splat(0));
    var buf: [33]u8 = undefined;
    var snapshot: p.Snapshot = undefined;
    for ([_]p.Location{ .{ .x = 0, .y = 0 }, .{ .x = -1, .y = -2 }, .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32) } }) |location| {
        const req = p.Request{ .request_id = @splat(0), .operation = .{ .update_location = location } };
        const ack = app.handleLocation(handle, req);
        const bytes = shared.wire.encode(&buf, ack);
        try std.testing.expectEqual(@as(usize, 20), bytes.len);
        try std.testing.expectEqualDeep(ack, try shared.wire.decodeResponse(bytes, &snapshot));
        try std.testing.expectEqualDeep(@as(?p.Location, location), app.registry.get(handle).?.location);
        try std.testing.expect(app.lease() == null);
    }
    for (leases) |lease| app.release(lease);
    try std.testing.expectEqual(before, try rows(&fixture));
    const wrong = p.Request{ .request_id = @splat(0), .operation = .{ .cut = .{ .x = 0, .y = 0 } } };
    try std.testing.expectEqual(p.ErrorCode.invalid_request, app.handleLocation(handle, wrong).result.failure.code);
    const loc = p.Request{ .request_id = @splat(0), .operation = .{ .update_location = .{ .x = 1, .y = 2 } } };
    // Accidental DB dispatch must reject without touching even undefined DB/snapshot storage.
    var db: @import("storage.zig").Storage = undefined;
    try std.testing.expectEqual(p.ErrorCode.invalid_request, @import("actions.zig").handle(&db, &snapshot, loc).result.failure.code);
    app.registry.release(handle);
    try std.testing.expectEqual(p.ErrorCode.invalid_request, app.handleLocation(handle, loc).result.failure.code);
    try std.testing.expectEqual(before, try rows(&fixture));
}
test "frozen startup allocator admits updates reads and releases all 64 sessions" {
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
    var handles: [64]sessions.Handle = undefined;
    for (&handles, 0..) |*handle, i| {
        handle.* = try fixture.application.registry.claim(@splat(@intCast(i)));
        try std.testing.expect(fixture.application.registry.get(handle.*).?.location == null);
        const req = p.Request{ .request_id = @splat(0), .operation = .{ .update_location = .{ .x = @intCast(i), .y = -1 } } };
        try std.testing.expect(fixture.application.handleLocation(handle.*, req).result == .location_updated);
        try std.testing.expectEqual(@as(i32, @intCast(i)), fixture.application.registry.get(handle.*).?.location.?.x);
        var snapshot: p.Snapshot = undefined;
        try fixture.application.contexts[0].db.readArea(.{ .cx0 = 0, .cy0 = 0, .cx1 = 7, .cy1 = 7 }, &snapshot);
    }
    for (handles) |handle| fixture.application.registry.release(handle);
    try std.testing.expect(@sizeOf(@import("app.zig").Layout) <= @import("app.zig").default_budget);
    std.debug.print("BUDGET,app_layout_bytes={d},session_registry_bytes={d},sqlite_highwater={d}\n", .{ @sizeOf(@import("app.zig").Layout), @sizeOf(sessions.Registry), fixture.runtime.highWater() });
}
