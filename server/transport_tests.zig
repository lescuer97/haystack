//! Production admission/cleanup and location helper, deliberately no socket use.
const std = @import("std");
const ws = std.http.Server.WebSocket;
const transport = @import("transport.zig");
const shared = @import("shared");
const p = shared.protocol;
const Handler = @import("transport.zig").Handler;
const Fixture = @import("fixture.zig").Fixture;
const sessions = @import("sessions.zig");
const c = @import("storage.zig").c;
const upgrade_headers = "Upgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n";
const many_headers = blk: {
    var bytes: [29 * 6]u8 = undefined;
    for (0..29) |i| @memcpy(bytes[i * 6 ..][0..6], "X: y\r\n");
    break :blk bytes;
};

test "strict std HTTP upgrade rejects ambiguous headers methods paths and bodies" {
    for ([_][]const u8{
        "POST / HTTP/1.1\r\n" ++ upgrade_headers ++ "\r\n",
        "GET / HTTP/1.0\r\n" ++ upgrade_headers ++ "\r\n",
        "GET /? HTTP/1.1\r\n" ++ upgrade_headers ++ "\r\n",
        "GET /# HTTP/1.1\r\n" ++ upgrade_headers ++ "\r\n",
        "GET /other HTTP/1.1\r\n" ++ upgrade_headers ++ "\r\n",
        "GET / HTTP/1.1\r\n" ++ upgrade_headers ++ "Upgrade: websocket\r\n\r\n",
        "GET / HTTP/1.1\r\n" ++ upgrade_headers ++ "Connection: upgrade\r\n\r\n",
        "GET / HTTP/1.1\r\n" ++ upgrade_headers ++ "Host: localhost\r\nHost: other\r\n\r\n",
        "GET / HTTP/1.1\r\n" ++ upgrade_headers ++ "Sec-WebSocket-Version: 13\r\n\r\n",
        "GET / HTTP/1.1\r\n" ++ upgrade_headers ++ "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
        "GET / HTTP/1.1\r\n" ++ upgrade_headers ++ "Content-Length: 0\r\n\r\n",
        "GET / HTTP/1.1\r\n" ++ upgrade_headers ++ "Transfer-Encoding: chunked\r\n\r\n",
        "GET / HTTP/1.1\r\n" ++ upgrade_headers ++ "Expect: 100-continue\r\n\r\n",
        "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Version: 12\r\nSec-WebSocket-Key: invalid\r\n\r\n",
        "GET / HTTP/1.1\r\n" ++ upgrade_headers ++ many_headers ++ "\r\n",
    }) |bytes| {
        var input = std.Io.Reader.fixed(bytes);
        var output_buffer: [512]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        var http = std.http.Server.init(&input, &output);
        var request = try http.receiveHead();
        var key: [24]u8 = undefined;
        try std.testing.expectError(error.InvalidUpgrade, transport.validateUpgrade(&request, &key));
        try std.testing.expectEqual(@as(usize, 0), output.buffered().len);
    }
    for ([_][]const u8{
        "",
        "Upgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Version: 13\r\n",
        "Upgrade: websocket\r\nConnection: xupgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
        "Upgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: !!!!!!!!!!!!!!!!!!!!!!==\r\n",
    }) |headers| {
        var bytes: [512]u8 = undefined;
        const head = try std.fmt.bufPrint(&bytes, "GET / HTTP/1.1\r\n{s}\r\n", .{headers});
        var input = std.Io.Reader.fixed(head);
        var output = std.Io.Writer.failing;
        var http = std.http.Server.init(&input, &output);
        var request = try http.receiveHead();
        var key: [24]u8 = undefined;
        try std.testing.expectError(error.InvalidUpgrade, transport.validateUpgrade(&request, &key));
    }
}

test "std upgrade preserves already buffered frame bytes and stable key" {
    var input = std.Io.Reader.fixed("GET / HTTP/1.1\r\n" ++ upgrade_headers ++ "\r\n\x82\x81\x01\x02\x03\x04\xf0");
    var output_buffer: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var http = std.http.Server.init(&input, &output);
    var request = try http.receiveHead();
    var key: [24]u8 = undefined;
    try transport.validateUpgrade(&request, &key);
    var websocket = try request.respondWebSocket(.{ .key = &key });
    var buffer: [128]u8 = undefined;
    var guard = transport.FrameInput.init(&input, &buffer);
    websocket.input = &guard.interface;
    const message = try websocket.readSmallMessage();
    try std.testing.expectEqual(ws.Opcode.binary, message.opcode);
    try std.testing.expectEqualSlices(u8, &.{0xf1}, message.data);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", websocket.key);
}

test "thin frame guard rejects RSV mask FIN opcode noncanonical control and oversize including skipped pongs" {
    for ([_][]const u8{
        "\xc2\x80",         "\xa2\x80",                                 "\x92\x80",                                 "\x82\x00",                                 "\x02\x80",         "\x80\x80",         "\x83\x80",
        "\x82\xfe\x00\x7d", "\x82\xff\x00\x00\x00\x00\x00\x00\x00\x80", "\x82\xff\x80\x00\x00\x00\x00\x00\x00\x00", "\x82\xff\x00\x00\x00\x00\x00\x01\x00\x00", "\x82\xfe\x00\x81", "\x89\xfe\x00\x7e", "\x8a\xfe\x00\x7e",
        "\x88\x81",         "\x8a\x80\x00\x00\x00\x00\xc2\x80",         "\xca\x80",                                 "\x0a\x80",                                 "\x82\xff",
    }) |bytes| {
        var input = std.Io.Reader.fixed(bytes);
        var buffer: [128]u8 = undefined;
        var guard = transport.FrameInput.init(&input, &buffer);
        var output = std.Io.Writer.failing;
        var websocket = ws{ .input = &guard.interface, .output = &output, .key = "" };
        try std.testing.expectError(error.ReadFailed, websocket.readSmallMessage());
    }
    for ([_]usize{ 0, 125, 126, 128 }) |length| {
        var bytes: [136]u8 = @splat(0);
        bytes[0] = 0x82;
        const header: usize = if (length < 126) 2 else 4;
        bytes[1] = if (length < 126) 0x80 | @as(u8, @intCast(length)) else 0xfe;
        if (header == 4) std.mem.writeInt(u16, bytes[2..4], @intCast(length), .big);
        var input = std.Io.Reader.fixed(bytes[0 .. header + 4 + length]);
        var buffer: [128]u8 = undefined;
        var guard = transport.FrameInput.init(&input, &buffer);
        var output = std.Io.Writer.failing;
        var websocket = ws{ .input = &guard.interface, .output = &output, .key = "" };
        try std.testing.expectEqual(length, (try websocket.readSmallMessage()).data.len);
    }
}

test "frame guard zero limits and partial forwarding preserve exact bytes and boundaries" {
    const bytes = "\x82\x81\x01\x02\x03\x04\xf0\x89\x80\x00\x00\x00\x00";
    var input = std.Io.Reader.fixed(bytes);
    var buffer: [128]u8 = undefined;
    var guard = transport.FrameInput.init(&input, &buffer);
    var storage: [bytes.len]u8 = undefined;
    var output = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(usize, 0), try guard.interface.stream(&output, .nothing));
    try std.testing.expectEqual(@as(usize, 0), input.seek);
    for (0..bytes.len) |_| try std.testing.expectEqual(@as(usize, 1), try guard.interface.stream(&output, .limited(1)));
    try std.testing.expectEqual(@as(usize, 0), guard.remaining);
    try std.testing.expectEqualSlices(u8, bytes, output.buffered());
}

test "fixed buffer authentication challenge proof ACK claims and failure cleanup" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var input = std.Io.Reader.fixed("");
    var storage: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&storage);
    var websocket = ws{ .input = &input, .output = &output, .key = "" };
    var handler = try Handler.init(&websocket, &fixture.application);
    defer handler.close();
    handler.nonce = @splat(7);
    handler.deadline = transport.freshDeadline(std.testing.io);
    try handler.sendChallenge();
    try std.testing.expectEqualSlices(u8, "\x82\x21\xf0" ++ @as([32]u8, @splat(7)), output.buffered());
    var key: [33]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798");
    var signature: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&signature, "49eacfb328fa4897cd34d70e114b33f3f1964f0a0d36ecf0ef5719488358b61eabd2b684bff67111333304d960ff5a1dc83d9aa3a632c4b27e329fc4e47acf20");
    var proof: [98]u8 = undefined;
    _ = shared.wire.encodeAuth(&proof, .{ .proof = .{ .pubkey = key, .signature = signature } });
    proof[50] ^= 1;
    try std.testing.expectError(error.InvalidAuthentication, handler.clientMessage(&proof, .binary));
    try std.testing.expect(handler.session == null);
    proof[50] ^= 1;
    const frame = "\x82\xe2\x00\x00\x00\x00" ++ @as([98]u8, @splat(0));
    var frame_bytes = frame.*;
    @memcpy(frame_bytes[6..], &proof);
    var frame_reader = std.Io.Reader.fixed(&frame_bytes);
    var frame_buffer: [128]u8 = undefined;
    var guard = transport.FrameInput.init(&frame_reader, &frame_buffer);
    websocket.input = &guard.interface;
    const message = try websocket.readSmallMessage();
    try handler.clientMessage(message.data, message.opcode);
    try std.testing.expect(handler.authenticated);
    try std.testing.expectEqualDeep(key, fixture.application.registry.get(handler.session.?).?.pubkey);
    try std.testing.expectEqualSlices(u8, "\x82\x01\xf2", output.buffered()[35..]);
    try std.testing.expectError(error.RepeatedAuthentication, handler.clientMessage(&proof, .binary));
    var ordinary = [_]u8{0xf0};
    for ([_]ws.Opcode{ .text, .binary }) |opcode| {
        const start = output.buffered().len;
        try handler.clientMessage(&ordinary, opcode);
        var snapshot: p.Snapshot = undefined;
        const response = try shared.wire.decodeResponse(output.buffered()[start + 2 ..], &snapshot);
        try std.testing.expectEqual(if (opcode == .text) p.ErrorCode.unsupported_message else p.ErrorCode.invalid_request, response.result.failure.code);
    }
    ordinary[0] = 0xf2;
    const start = output.buffered().len;
    try handler.clientMessage(&ordinary, .binary);
    var snapshot: p.Snapshot = undefined;
    try std.testing.expectEqual(p.ErrorCode.invalid_request, (try shared.wire.decodeResponse(output.buffered()[start + 2 ..], &snapshot)).result.failure.code);
    var duplicate = try Handler.init(&websocket, &fixture.application);
    duplicate.nonce = handler.nonce;
    duplicate.deadline = handler.deadline;
    try std.testing.expectError(error.DuplicatePubkey, duplicate.clientMessage(&proof, .binary));
    try std.testing.expect(duplicate.session == null);
    handler.close();
    handler.close();
    handler.deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake };
    try std.testing.expectError(error.DeadlineExpired, handler.clientMessage(&proof, .binary));
    try std.testing.expectError(error.DeadlineExpired, fixture.application.registry.claimBefore(key, handler.deadline));
    handler.deadline = transport.freshDeadline(std.testing.io);
    var failing = std.Io.Writer.failing;
    websocket.output = &failing;
    try std.testing.expectError(error.WriteFailed, handler.clientMessage(&proof, .binary));
    try std.testing.expect(!handler.authenticated and handler.session == null);
    const ExpiringWriter = struct {
        handler: *Handler,
        writer: std.Io.Writer,
        fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *@This() = @fieldParentPtr("writer", writer);
            self.handler.deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake };
        }
    };
    // F2 may have reached the peer when expiry wins; it must not publish auth.
    var expiring = ExpiringWriter{ .handler = &handler, .writer = .{
        .buffer = &storage,
        .vtable = &.{ .drain = std.Io.Writer.fixedDrain, .flush = ExpiringWriter.flush },
    } };
    websocket.output = &expiring.writer;
    handler.deadline = transport.freshDeadline(std.testing.io);
    try std.testing.expectError(error.DeadlineExpired, handler.clientMessage(&proof, .binary));
    try std.testing.expectEqualSlices(u8, "\x82\x01\xf2", expiring.writer.buffered());
    try std.testing.expect(!handler.authenticated and handler.session == null);
    for (fixture.application.registry.slots) |slot| try std.testing.expect(!slot.occupied);
    // The new auth window is independent of an expired accept/HTTP timestamp.
    const auth_deadline = transport.freshDeadline(std.testing.io);
    try std.testing.expect(auth_deadline.compare(.gt, handler.deadline));
    try transport.checkDeadline(std.testing.io, auth_deadline);
}
fn rows(f: *Fixture) !i64 {
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(f.application.contexts[0].db.db, "SELECT (SELECT count(*) FROM action_results)+(SELECT count(*) FROM chunk_state)", -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    return c.sqlite3_column_int64(stmt, 0);
}
test "production nonce initialization reserves no identity and cleanup is idempotent" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var dummy: ws = undefined; // init/close must never inspect or write this connection.
    var original = try Handler.init(&dummy, &fixture.application);
    try std.testing.expect(original.session == null and !original.authenticated);
    // Connection cleanup uses this hook after HTTP101/challenge or proof failure.
    original.close();
    var fresh = try Handler.init(&dummy, &fixture.application);
    try std.testing.expect(!std.mem.eql(u8, &fresh.nonce, &original.nonce));
    original.close();
    fresh.close();
    fresh.close();
    for (fixture.application.registry.slots) |slot| try std.testing.expect(!slot.occupied);
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
test "production proof codec rejects malformed first messages without gameplay or claims" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const before = try rows(&fixture);
    var dummy: ws = undefined;
    var handler = try Handler.init(&dummy, &fixture.application);
    handler.deadline = transport.freshDeadline(std.testing.io);
    var challenge: [33]u8 = .{0xf0} ++ @as([32]u8, @splat(0));
    var ack = [_]u8{0xf2};
    try std.testing.expectError(error.InvalidAuthentication, handler.clientMessage(&challenge, .binary));
    try std.testing.expectError(error.InvalidAuthentication, handler.clientMessage(&ack, .binary));
    var proof: [129]u8 = @splat(0);
    for ([_]usize{ 0, 1, 20, 97, 99, 128, 129 }) |length| {
        try std.testing.expectError(error.InvalidAuthentication, handler.clientMessage(proof[0..length], .binary));
    }
    proof[0] = 0xf1;
    try std.testing.expectError(error.InvalidAuthentication, handler.clientMessage(proof[0..98], .text));
    // Invalid compressed prefix/point, no
    // connection lifecycle access, no wallet, no DB work or identity admission.
    try std.testing.expectError(error.InvalidAuthentication, handler.clientMessage(proof[0..98], .binary));
    proof[1] = 2;
    @memset(proof[2..34], 0xff);
    try std.testing.expectError(error.InvalidAuthentication, handler.clientMessage(proof[0..98], .binary));
    for (fixture.application.registry.slots) |slot| try std.testing.expect(!slot.occupied);
    try std.testing.expectEqual(before, try rows(&fixture));
    // Failure after provisional admission (e.g. ACK write/expiry) uses the
    // ordinary close hook and clears exactly once; stale close cannot evict.
    handler.session = try fixture.application.registry.claim(@splat(2));
    const old = handler.session.?;
    handler.close();
    const fresh = try fixture.application.registry.claim(@splat(2));
    handler.close();
    try std.testing.expect(fixture.application.registry.get(old) == null);
    try std.testing.expect(fixture.application.registry.get(fresh) != null);
    fixture.application.registry.release(fresh);
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
