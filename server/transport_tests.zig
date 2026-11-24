//! Production framing, authentication, and request routing without sockets.
const std = @import("std");
const ws = std.http.Server.WebSocket;
const transport = @import("transport.zig");
const shared = @import("shared");
const p = shared.protocol;
const spawn = shared.movement.spawn;
const east: p.Location = .{ .x = 1, .y = 0 };
const wire = shared.wire;
const config = @import("ws_config.zig");
const Handler = @import("transport.zig").Handler;
const Fixture = @import("fixture.zig").Fixture;
const sessions = @import("sessions.zig");
const ticks = @import("tick_mailbox.zig");
const GameDb = @import("game_db.zig").GameDb;
const Persistence = @import("persistence.zig").Persistence;
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
    var buffer: [config.max_payload]u8 = undefined;
    var guard = transport.FrameInput.init(&input, &buffer);
    websocket.input = &guard.interface;
    const message = try websocket.readSmallMessage();
    try std.testing.expectEqual(ws.Opcode.binary, message.opcode);
    try std.testing.expectEqualSlices(u8, &.{0xf1}, message.data);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", websocket.key);
}

test "thin frame guard rejects RSV mask FIN opcode noncanonical control and oversize including skipped pongs" {
    var oversize_header = [_]u8{ 0x82, 0xfe, 0, 0 };
    std.mem.writeInt(u16, oversize_header[2..4], config.max_payload + 1, .big);
    for ([_][]const u8{
        "\xc2\x80",         "\xa2\x80",                                 "\x92\x80",                                 "\x82\x00",                                 "\x02\x80",       "\x80\x80",         "\x83\x80",
        "\x82\xfe\x00\x7d", "\x82\xff\x00\x00\x00\x00\x00\x00\x00\x80", "\x82\xff\x80\x00\x00\x00\x00\x00\x00\x00", "\x82\xff\x00\x00\x00\x00\x00\x01\x00\x00", &oversize_header, "\x89\xfe\x00\x7e", "\x8a\xfe\x00\x7e",
        "\x88\x81",         "\x8a\x80\x00\x00\x00\x00\xc2\x80",         "\xca\x80",                                 "\x0a\x80",                                 "\x82\xff",
    }) |bytes| {
        var input = std.Io.Reader.fixed(bytes);
        var buffer: [config.max_payload]u8 = undefined;
        var guard = transport.FrameInput.init(&input, &buffer);
        var output = std.Io.Writer.failing;
        var websocket = ws{ .input = &guard.interface, .output = &output, .key = "" };
        try std.testing.expectError(error.ReadFailed, websocket.readSmallMessage());
    }
    try std.testing.expectEqual(p.max_channel_open_with_params_bytes, config.max_payload);
    try std.testing.expectEqual(@as(usize, 256), p.max_gameplay_request_bytes);
    for ([_]usize{ 0, 125, 126, p.max_gameplay_request_bytes, p.max_gameplay_request_bytes + 1, config.max_payload }) |length| {
        var bytes: [config.max_payload + 8]u8 = @splat(0);
        bytes[0] = 0x82;
        const header: usize = if (length < 126) 2 else 4;
        bytes[1] = if (length < 126) 0x80 | @as(u8, @intCast(length)) else 0xfe;
        if (header == 4) std.mem.writeInt(u16, bytes[2..4], @intCast(length), .big);
        var input = std.Io.Reader.fixed(bytes[0 .. header + 4 + length]);
        var buffer: [config.max_payload]u8 = undefined;
        var guard = transport.FrameInput.init(&input, &buffer);
        var output = std.Io.Writer.failing;
        var websocket = ws{ .input = &guard.interface, .output = &output, .key = "" };
        try std.testing.expectEqual(length, (try websocket.readSmallMessage()).data.len);
    }
}

test "frame guard zero limits and partial forwarding preserve exact bytes and boundaries" {
    const bytes = "\x82\x81\x01\x02\x03\x04\xf0\x89\x80\x00\x00\x00\x00";
    var input = std.Io.Reader.fixed(bytes);
    var buffer: [config.max_payload]u8 = undefined;
    var guard = transport.FrameInput.init(&input, &buffer);
    var storage: [bytes.len]u8 = undefined;
    var output = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(usize, 0), try guard.interface.stream(&output, .nothing));
    try std.testing.expectEqual(@as(usize, 0), input.seek);
    for (0..bytes.len) |_| try std.testing.expectEqual(@as(usize, 1), try guard.interface.stream(&output, .limited(1)));
    try std.testing.expectEqual(@as(usize, 0), guard.remaining);
    try std.testing.expectEqualSlices(u8, bytes, output.buffered());
}

const protocol_error_frame = "\x82\x04\xff\x00\x00\x7e";
const auth_ack_frame = "\x82\x0f\xf2\x0b\x00\x03\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x7e";
const test_pubkey_hex = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
const test_signature_hex = "49eacfb328fa4897cd34d70e114b33f3f1964f0a0d36ecf0ef5719488358b61eabd2b684bff67111333304d960ff5a1dc83d9aa3a632c4b27e329fc4e47acf20";

fn writeClientFrame(out: *std.Io.Writer, payload: []const u8) !void {
    try out.writeByte(0x82);
    if (payload.len < 126) {
        try out.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else {
        try out.writeByte(0xfe);
        var length: [2]u8 = undefined;
        std.mem.writeInt(u16, &length, @intCast(payload.len), .big);
        try out.writeAll(&length);
    }
    const mask = [4]u8{ 1, 2, 3, 4 };
    try out.writeAll(&mask);
    for (payload, 0..) |byte, i| try out.writeByte(byte ^ mask[i % mask.len]);
}

fn handleNextFrame(handler: *Handler) !void {
    const message = try handler.conn.readSmallMessage();
    try handler.clientMessage(message.data, message.opcode);
}

fn expectAuthFailure(frame: []const u8, failure: p.AuthFailure) !void {
    try std.testing.expectEqualSlices(u8, "\x82\x09", frame[0..2]);
    try std.testing.expectEqualDeep(p.AuthOutcome{ .failed = failure }, (try wire.decodeAuth(frame[2..], true, .reply)).reply);
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
    const challenge_frame = "\x82\x27\xf0\x23\x00\x10\x20\x00" ++ @as([32]u8, @splat(7)) ++ "\x7e";
    try std.testing.expectEqualSlices(u8, challenge_frame, output.buffered());
    var key: [33]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, test_pubkey_hex);
    var signature: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&signature, test_signature_hex);
    var proof: [107]u8 = undefined;
    try std.testing.expectEqual(proof.len, (try wire.encodeAuth(&proof, .{ .proof = .{ .pubkey = key, .signature = signature } })).len);

    // A well-framed proof with a bad signature gets a typed failure and terminates.
    var rejected = try Handler.init(&websocket, &fixture.application);
    defer rejected.close();
    rejected.nonce = handler.nonce;
    rejected.deadline = handler.deadline;
    proof[proof.len - 2] ^= 1;
    try std.testing.expectError(error.AuthenticationRejected, rejected.clientMessage(&proof, .binary));
    try expectAuthFailure(output.buffered()[challenge_frame.len..], .invalid_credentials);
    try std.testing.expect(!rejected.authenticated and rejected.session == null);
    proof[proof.len - 2] ^= 1;
    output.end = challenge_frame.len;

    const before_proof = handler.deadline;
    try handler.clientMessage(&proof, .text);
    try std.testing.expectEqualSlices(u8, protocol_error_frame, output.buffered()[challenge_frame.len..]);
    try std.testing.expectEqualDeep(before_proof, handler.deadline);
    try std.testing.expect(!handler.authenticated and handler.session == null);
    const ack_start = output.buffered().len;
    var frame_bytes: [6 + proof.len]u8 = undefined;
    var frame_writer = std.Io.Writer.fixed(&frame_bytes);
    try writeClientFrame(&frame_writer, &proof);
    var frame_reader = std.Io.Reader.fixed(&frame_bytes);
    var frame_buffer: [config.max_payload]u8 = undefined;
    var guard = transport.FrameInput.init(&frame_reader, &frame_buffer);
    websocket.input = &guard.interface;
    try handleNextFrame(&handler);
    try std.testing.expect(!handler.authenticated);
    try handler.completeAuthentication();
    try std.testing.expect(handler.authenticated);
    try std.testing.expectEqualDeep(key, fixture.application.registry.get(handler.session.?).?.pubkey);
    const ack = output.buffered()[ack_start..];
    try std.testing.expectEqualSlices(u8, auth_ack_frame, ack);
    try std.testing.expectEqualDeep(p.AuthOutcome{ .ok = spawn }, (try wire.decodeAuth(ack[2..], true, .reply)).reply);
    const session = handler.session.?;
    for ([_][]const u8{ &proof, challenge_frame[2..], auth_ack_frame[2..], "\x00" }, [_]ws.Opcode{ .binary, .binary, .binary, .text }) |data, opcode| {
        const start = output.buffered().len;
        try handler.clientMessage(data, opcode);
        try std.testing.expectEqualSlices(u8, protocol_error_frame, output.buffered()[start..]);
        try std.testing.expect(handler.authenticated);
        try std.testing.expectEqualDeep(session, handler.session.?);
    }
    var duplicate = try Handler.init(&websocket, &fixture.application);
    defer duplicate.close();
    duplicate.nonce = handler.nonce;
    duplicate.deadline = handler.deadline;
    const failure_start = output.buffered().len;
    try std.testing.expectError(error.AuthenticationRejected, duplicate.clientMessage(&proof, .binary));
    try expectAuthFailure(output.buffered()[failure_start..], .unavailable);
    try std.testing.expect(!duplicate.authenticated and duplicate.session == null);
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
    try std.testing.expectEqualSlices(u8, auth_ack_frame, expiring.writer.buffered());
    try std.testing.expect(!handler.authenticated and handler.session == null);
    for (fixture.application.registry.slots) |slot| try std.testing.expect(!slot.occupied);
    // The new auth window is independent of an expired accept/HTTP timestamp.
    const auth_deadline = transport.freshDeadline(std.testing.io);
    try std.testing.expect(auth_deadline.compare(.gt, handler.deadline));
    try transport.checkDeadline(std.testing.io, auth_deadline);
}
test "durable auth ACK stays provisional until the outer deadline check passes" {
    const t = std.testing;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    var db = try GameDb.open(":memory:");
    defer db.close();
    var persistence = try Persistence.init(t.io, t.allocator, &db, &app.context.state, app.registry);
    defer persistence.deinit(t.allocator);
    app.persistence = &persistence;

    var input = std.Io.Reader.fixed("");
    var bytes: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var websocket = ws{ .input = &input, .output = &output, .key = "" };
    var handler = try Handler.init(&websocket, app);
    defer handler.close();
    handler.nonce = @splat(7);
    var key: sessions.Pubkey = undefined;
    _ = try std.fmt.hexToBytes(&key, test_pubkey_hex);
    var signature: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&signature, test_signature_hex);
    var proof_bytes: [107]u8 = undefined;
    const proof = try wire.encodeAuth(&proof_bytes, .{ .proof = .{ .pubkey = key, .signature = signature } });

    handler.deadline = transport.freshDeadline(t.io);
    try handler.clientMessage(proof, .binary);
    try t.expect(!handler.authenticated and handler.session != null);
    try t.expect((try wire.decodeAuth(output.buffered()[2..], true, .reply)).reply == .ok);
    var pending: [1]sessions.UserSnapshot = undefined;
    try t.expectEqual(@as(usize, 0), app.registry.snapshotUsers(&pending));
    const Confirm = struct {
        fn run(h: *Handler, result: *anyerror!void) void {
            result.* = h.completeAuthentication();
        }
    };
    var result: anyerror!void = undefined;
    const worker = start: {
        app.registry.mutex.lockUncancelable(t.io);
        errdefer app.registry.mutex.unlock(t.io);
        handler.deadline = .fromNow(t.io, .{ .raw = .fromMilliseconds(500), .clock = .awake });
        break :start try std.Thread.spawn(.{}, Confirm.run, .{ &handler, &result });
    };
    {
        defer worker.join();
        defer app.registry.mutex.unlock(t.io);
        // Observe confirmation waiting for the mutex before letting the deadline expire.
        while (app.registry.mutex.state.load(.acquire) != .contended) {
            try transport.checkDeadline(t.io, handler.deadline);
            try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
        }
        try transport.checkDeadline(t.io, handler.deadline);
        try handler.deadline.wait(t.io);
    }
    try t.expectError(error.DeadlineExpired, result);
    try t.expect(!handler.authenticated);
    try t.expectEqual(@as(usize, 0), app.registry.snapshotUsers(&pending));
    handler.close();
    try persistence.flush();
    try t.expect((try db.loadUser(key)) == null);

    output.end = 0;
    handler.deadline = transport.freshDeadline(t.io);
    try handler.clientMessage(proof, .binary);
    try handler.completeAuthentication();
    try t.expect(handler.authenticated);
    try persistence.flush();
    try t.expect((try db.loadUser(key)) != null);
}

fn stateCount(f: *Fixture) usize {
    const state = &f.application.context.state;
    return state.chunk_count + state.replay_count;
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
test "production location helper bypasses sole leased world with no replay state" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    const before = stateCount(&fixture);
    const held = app.lease().?;
    const handle = try app.registry.claim(@splat(0));
    var buf: [p.max_response_bytes]u8 = undefined;
    var snapshot: p.Snapshot = undefined;
    const far: p.Location = .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32) };
    for ([_]p.Location{ east, far, spawn }, 0..) |location, i| {
        const req = p.RequestFor(.update_location){ .request_id = @splat(0), .payload = location };
        const ack = app.handleLocation(handle, req);
        const bytes = try wire.encodeReply(&buf, .update_location, req, ack);
        try std.testing.expectEqualDeep(ack, try wire.decodeReply(bytes, .update_location, req.request_id, &snapshot));
        if (i == 1) {
            try std.testing.expectEqual(p.LocationFailure.invalid_request, ack.failed);
            try std.testing.expectEqualDeep(east, app.registry.get(handle).?.location.?);
        } else {
            try std.testing.expect(ack == .ok);
            try std.testing.expectEqualDeep(location, app.registry.get(handle).?.location.?);
        }
        try std.testing.expect(app.lease() == null);
    }
    app.release(held);
    const reused = app.lease().?;
    app.release(reused);
    try std.testing.expectEqual(before, stateCount(&fixture));
    const loc = p.RequestFor(.update_location){ .request_id = @splat(0), .payload = .{ .x = 1, .y = 2 } };
    app.registry.release(handle);
    const failure = app.handleLocation(handle, loc);
    try std.testing.expectEqual(p.LocationFailure.invalid_request, failure.failed);
    const bytes = try wire.encodeReply(&buf, .update_location, loc, failure);
    try std.testing.expectEqualDeep(failure, try wire.decodeReply(bytes, .update_location, loc.request_id, &snapshot));
    try std.testing.expectEqual(before, stateCount(&fixture));
}
test "production proof codec rejects malformed first messages without gameplay or claims" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const before = stateCount(&fixture);
    var input = std.Io.Reader.fixed("");
    var storage: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&storage);
    var websocket = ws{ .input = &input, .output = &output, .key = "" };
    var handler = try Handler.init(&websocket, &fixture.application);
    defer handler.close();
    handler.deadline = transport.freshDeadline(std.testing.io);
    const deadline = handler.deadline;
    var challenge: [39]u8 = undefined;
    _ = try wire.encodeAuth(&challenge, .{ .challenge = @splat(0) });
    var proof: [p.max_request_bytes]u8 = @splat(0);
    const proof_len = (try wire.encodeAuth(&proof, .{ .proof = .{ .pubkey = @splat(0), .signature = @splat(0) } })).len;
    for ([_][]const u8{ &challenge, auth_ack_frame[2..], "", proof[0..1], proof[0..20], proof[0 .. proof_len - 1], proof[0 .. proof_len + 1], proof[0 .. p.max_gameplay_request_bytes + 1], &proof }) |malformed| {
        const start = output.buffered().len;
        try handler.clientMessage(malformed, .binary);
        try std.testing.expectEqualSlices(u8, protocol_error_frame, output.buffered()[start..]);
        try std.testing.expect(!handler.authenticated and handler.session == null);
        try std.testing.expectEqualDeep(deadline, handler.deadline);
    }
    // A structurally valid but unusable compressed key is a credential failure.
    const start = output.buffered().len;
    try std.testing.expectError(error.AuthenticationRejected, handler.clientMessage(proof[0..proof_len], .binary));
    try expectAuthFailure(output.buffered()[start..], .invalid_credentials);
    for (fixture.application.registry.slots) |slot| try std.testing.expect(!slot.occupied);
    try std.testing.expectEqual(before, stateCount(&fixture));
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
fn expectChannelUnavailable(handler: *Handler, output: *std.Io.Writer, comptime kind: p.Kind, id: p.Id, reply_tag: u8) !void {
    const start = output.buffered().len;
    try handleNextFrame(handler);
    const reply = output.buffered()[start..];
    try std.testing.expect(reply.len >= 3 and reply.len <= 127);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, @intCast(reply.len - 2), reply_tag }, reply[0..3]);
    var snapshot: p.Snapshot = undefined;
    try std.testing.expectEqualDeep(p.Outcome(kind){ .failed = .unavailable }, try wire.decodeReply(reply[2..], kind, id, &snapshot));
}

test "Spilman messages require authentication and reject without touching tick or world state" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const before = stateCount(&fixture);
    var slots: [1]transport.Slot = .{.{}};
    const slot = &slots[0];
    var dispatch: ticks.Dispatcher = .{ .io = std.testing.io, .stopping = true };
    var frame_storage: [2 * config.max_payload + 4096]u8 = undefined;
    var frames = std.Io.Writer.fixed(&frame_storage);
    var request_storage: [config.max_payload]u8 = undefined;

    const close_request: p.RequestFor(.channel_close) = .{ .request_id = @splat(0x23), .payload = .{ .id = @splat(3) } };
    try writeClientFrame(&frames, try wire.encodeRequest(&request_storage, .channel_close, close_request)); // before authentication

    var key: [33]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, test_pubkey_hex);
    var signature: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&signature, test_signature_hex);
    try writeClientFrame(&frames, try wire.encodeAuth(&request_storage, .{ .proof = .{ .pubkey = key, .signature = signature } }));

    const open_id: p.Id = @splat(0x22);
    const vectors = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @embedFile("spilman_vectors.json"), .{});
    defer vectors.deinit();
    const funding_json = vectors.value.object.get("funding_proofs_json").?.string;

    const open = try wire.encodeRequest(&request_storage, .channel_open, .{
        .request_id = open_id,
        .payload = .{ .id = @splat(3), .proof = funding_json, .params = "{}" },
    });
    try std.testing.expectEqual(@as(u8, 0x24), open[0]);
    try std.testing.expectEqual(funding_json.len + 66, open.len);
    try std.testing.expect(open.len > p.max_gameplay_request_bytes);
    try writeClientFrame(&frames, open[0 .. open.len - 1]); // missing envelope terminator
    try writeClientFrame(&frames, open);
    const modern_open_id: p.Id = @splat(0x25);
    const modern = try wire.encodeRequest(&request_storage, .channel_open, .{
        .request_id = modern_open_id,
        .payload = .{ .id = @splat(3), .proof = &@as([p.max_channel_proof_bytes]u8, @splat('p')), .params = &@as([p.max_channel_params_bytes]u8, @splat('a')), .tool = .pickaxe },
    });
    try std.testing.expectEqual(config.max_payload, modern.len);
    try writeClientFrame(&frames, modern);

    const requirements_id: p.Id = @splat(0x21);
    const requirements = try wire.encodeRequest(&request_storage, .channel_requirements, .{
        .request_id = requirements_id,
        .payload = .{ .tool = .hoe },
    });
    try std.testing.expectEqual(@as(u8, 0x21), requirements[0]);
    try writeClientFrame(&frames, requirements);
    const close = try wire.encodeRequest(&request_storage, .channel_close, close_request);
    try std.testing.expectEqual(@as(u8, 0x23), close[0]);
    try writeClientFrame(&frames, close);
    const location: p.RequestFor(.update_location) = .{ .request_id = @splat(3), .payload = east };
    try writeClientFrame(&frames, try wire.encodeRequest(&request_storage, .update_location, location));

    var input = std.Io.Reader.fixed(frames.buffered());
    var guard = transport.FrameInput.init(&input, &slot.ws_buffer);
    var output = std.Io.Writer.fixed(&slot.output_buffer);
    var websocket = ws{ .input = &guard.interface, .output = &output, .key = "" };
    var handler = try Handler.init(&websocket, &fixture.application);
    defer handler.close();
    handler.nonce = @splat(7);
    handler.deadline = transport.freshDeadline(std.testing.io);
    handler.dispatch = &dispatch;
    handler.mailbox = &slot.mailbox;

    try handleNextFrame(&handler);
    try std.testing.expectEqualSlices(u8, protocol_error_frame, output.buffered());
    try std.testing.expect(!handler.authenticated and handler.session == null);
    output.end = 0;
    try handleNextFrame(&handler);
    try std.testing.expectEqualSlices(u8, auth_ack_frame, output.buffered());
    try handler.completeAuthentication();
    const session = handler.session.?;
    output.end = 0;
    try handleNextFrame(&handler);
    try std.testing.expectEqualSlices(u8, protocol_error_frame, output.buffered());
    try expectChannelUnavailable(&handler, &output, .channel_open, open_id, 0xa2);
    try expectChannelUnavailable(&handler, &output, .channel_open, modern_open_id, 0xa2);
    try expectChannelUnavailable(&handler, &output, .channel_requirements, requirements_id, 0xa1);
    try expectChannelUnavailable(&handler, &output, .channel_close, close_request.request_id, 0xa3);

    try std.testing.expect(handler.authenticated);
    try std.testing.expectEqualDeep(session, handler.session.?);
    try std.testing.expectEqual(key, fixture.application.registry.get(session).?.pubkey);
    try std.testing.expectEqual(@as(u64, 0), slot.mailbox.generation);
    try std.testing.expect(slot.mailbox.state == .idle);
    try std.testing.expectEqual(before, stateCount(&fixture));
    try std.testing.expectEqualDeep(spawn, fixture.application.registry.get(session).?.location.?);

    var harvest_snapshot: p.Snapshot = undefined;
    for ([_]p.tool{ .axe, .pickaxe }) |tool| {
        var x: i32 = -128;
        while (shared.world.sampleTile(shared.world.public_seed, x, 0) != tool.terrain()) : (x += 1) {
            if (x == 127) return error.NoHarvestTile;
        }
        // Neither the explicit tool nor the legacy hoe encoding may clear this tile for free.
        for ([_]p.tool{ tool, .hoe }) |selected| {
            output.end = 0;
            const cut: p.RequestFor(.cut) = .{ .request_id = @splat(44), .payload = .{ .x = x, .y = 0, .tool = selected } };
            try handler.clientMessage(try wire.encodeRequest(&request_storage, .cut, cut), .binary);
            const result = try wire.decodeReply(output.buffered()[2..], .cut, cut.request_id, &harvest_snapshot);
            try std.testing.expect(result == .failed and result.failed == .invalid_request);
            try std.testing.expectEqual(@as(u64, 0), slot.mailbox.generation);
        }
    }

    // A normal gameplay request on the same connection still reaches the tick.
    dispatch.stopping = false;
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    try group.concurrent(std.testing.io, runOneTickRequest, .{ &dispatch, &fixture.application, &slots });
    output.end = 0;
    try handleNextFrame(&handler);
    var snapshot: p.Snapshot = undefined;
    try std.testing.expectEqualDeep(p.Outcome(.update_location){ .ok = {} }, try wire.decodeReply(output.buffered()[2..], .update_location, location.request_id, &snapshot));
    try std.testing.expectEqualDeep(location.payload, fixture.application.registry.get(session).?.location.?);
}

test "headless wallet exposes owned spendable and depleted channels and quotes unit price" {
    const t = std.testing;
    const native = @import("native_storage");
    const wallet_service = native.wallet_service;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const wallet_path = try std.fs.path.joinZ(a, &.{ dir, "wallet.sqlite" });
    const channel_path = try std.fs.path.joinZ(a, &.{ dir, "hoe.sqlite" });
    var wallet = try wallet_service.Headless.testing.openWithLedger(t.io, t.allocator, wallet_path, channel_path);
    defer wallet.close() catch {};
    const channel_sql = try native.sqlite.Db.open(channel_path, .read_write_no_follow, false);
    defer channel_sql.close();
    const week = 7 * 24 * 60 * 60;

    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    const game_path = try std.fs.path.joinZ(a, &.{ dir, "game.sqlite" });
    var db = try GameDb.open(game_path);
    defer db.close();
    const game_sql = try native.sqlite.Db.open(game_path, .read_write_no_mutex, false);
    defer game_sql.close();
    var persistence = try Persistence.init(t.io, t.allocator, &db, &app.context.state, app.registry);
    defer persistence.deinit(t.allocator);
    app.persistence = &persistence;
    try t.expect(app.wallet == null);
    app.wallet = &wallet;

    var key: [33]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, test_pubkey_hex);
    var signature: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&signature, test_signature_hex);
    var proof_buffer: [107]u8 = undefined;
    const proof = try wire.encodeAuth(&proof_buffer, .{ .proof = .{ .pubkey = key, .signature = signature } });
    const location = spawn;
    const now: u64 = @intCast(std.Io.Clock.real.now(t.io).toSeconds());
    const before = stateCount(&fixture);
    var input = std.Io.Reader.fixed("");
    var bytes: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var socket = ws{ .input = &input, .output = &output, .key = "" };

    // Valid, sufficiently funded capacities reach proof validation; invalid
    // capacities and underfunding are rejected before proof validation or mint I/O.
    {
        const channels = wallet.tryAcquire() orelse return error.TestWalletBusy;
        defer channels.release();
        const receiver_hex = std.fmt.bytesToHex(wallet.receiverPubkey(week).?, .lower);
        const price = p.hoe_price_msat;
        const rejected = [_]struct { capacity: u64, funding: u64 }{
            .{ .capacity = 0, .funding = 64 },
            .{ .capacity = price - 1, .funding = 64 },
            .{ .capacity = price + 1, .funding = 64 },
            .{ .capacity = p.max_tool_channel_cuts * price + price, .funding = 256 },
            .{ .capacity = 2 * price, .funding = price },
        };
        for (0..p.max_tool_channel_cuts + rejected.len) |i| {
            const valid = i < p.max_tool_channel_cuts;
            const invalid = if (valid) null else rejected[i - p.max_tool_channel_cuts];
            const params_json = try std.json.Stringify.valueAlloc(a, .{
                .capacity = if (invalid) |row| row.capacity else (i + 1) * price,
                .expiry_timestamp = now + 3600,
                .funding_token_amount = if (invalid) |row| row.funding else 256,
                .input_fee_ppk = 0,
                .keyset_id = "test",
                .maximum_amount = 256,
                .mint = "https://mint.example.com",
                .receiver_pubkey = receiver_hex[0..],
                .sender_pubkey = test_pubkey_hex,
                .setup_timestamp = now,
                .unit = "msat",
            }, .{});
            try t.expectError(if (valid) error.InvalidFundingProof else error.InvalidChannelParameters, channels.acceptFunded(key, .{
                .id = @splat(88),
                .params_json = params_json,
                .funding_proofs_json = "[]",
            }, now));
            try t.expectEqual(null, try channels.lookup(key, @splat(88), now));
        }
    }

    // Seed trusted ledger metadata directly so these transport tests need no mint.
    // No mint calls are needed to exercise exact open and close retries or read saved receipts.
    const ChannelId = @FieldType(p.SpillmanChannelOpen, "id");
    const active: ChannelId = @splat(1);
    const settled: ChannelId = @splat(6);
    const orphan: ChannelId = @splat(8);
    const exhausted: ChannelId = @splat(9);
    const dust: ChannelId = @splat(10);
    const unredeemed: ChannelId = @splat(11);
    const exhausted_in_cutoff: ChannelId = @splat(12);
    const expired_exhausted: ChannelId = @splat(13);
    const active_capacity = 3 * p.hoe_price_msat;
    const active_balance = 2 * p.hoe_price_msat;
    const exhausted_capacity = p.hoe_price_msat;
    const open_proofs = "[{\"trusted_fixture_proof\":true}]";
    const sender_proofs = "[{\"sender\":true}]";
    const cases = [_]struct { id: ChannelId, owner: [33]u8, expiry: u64, phase: wallet_service.ChannelPhase }{
        .{ .id = active, .owner = key, .expiry = now + 3600, .phase = .active },
        .{ .id = @splat(2), .owner = key, .expiry = now, .phase = .expired },
        .{ .id = @splat(3), .owner = key, .expiry = now + 120, .phase = .closing_window },
        .{ .id = @splat(4), .owner = @splat(0x02), .expiry = now + 3600, .phase = .active },
        .{ .id = @splat(5), .owner = key, .expiry = now + 3600, .phase = .settlement_pending },
        .{ .id = settled, .owner = key, .expiry = now + 3600, .phase = .settled },
        .{ .id = orphan, .owner = key, .expiry = now + 3600, .phase = .active },
        .{ .id = exhausted, .owner = key, .expiry = now + 3600, .phase = .depleted },
        .{ .id = dust, .owner = key, .expiry = now + 3600, .phase = .active },
        .{ .id = unredeemed, .owner = key, .expiry = now + 3600, .phase = .settled },
        .{ .id = exhausted_in_cutoff, .owner = key, .expiry = now + 60, .phase = .depleted },
        .{ .id = expired_exhausted, .owner = key, .expiry = now, .phase = .expired },
    };
    var active_params: ?[]const u8 = null;
    var orphan_params: ?[]const u8 = null;
    for (cases) |row| {
        const single_cut = std.meta.eql(row.id, exhausted) or std.meta.eql(row.id, settled) or
            std.meta.eql(row.id, exhausted_in_cutoff) or std.meta.eql(row.id, expired_exhausted);
        const capacity: u64 = if (single_cut) exhausted_capacity else if (std.meta.eql(row.id, active)) active_capacity else if (row.phase == .settled) p.hoe_capacity_msat else if (std.meta.eql(row.id, dust)) 14 else 100;
        const params_json = try std.json.Stringify.valueAlloc(a, .{
            .sender_pubkey = test_pubkey_hex,
            .expiry_timestamp = row.expiry,
            .capacity = capacity,
        }, .{});
        // Exact open retries must send the same bytes as the seeded funding row.
        if (std.meta.eql(row.id, active)) active_params = params_json;
        if (std.meta.eql(row.id, orphan)) orphan_params = params_json;
        {
            const stmt = try channel_sql.prepare("INSERT INTO receiver_channels (id,owner,wallet_net_msat) VALUES (?1,?2,?3)");
            defer stmt.finalize();
            try stmt.bindBlob(1, &row.id);
            try stmt.bindBlob(2, &row.owner);
            if (row.phase == .settled and !std.meta.eql(row.id, unredeemed)) try stmt.bindUInt(3, 5);
            try stmt.finish();
        }
        const terminal = row.phase == .settlement_pending or row.phase == .settled;
        const balance: u64 = if (single_cut or row.phase == .settled) capacity else if (std.meta.eql(row.id, active)) active_balance else if (std.meta.eql(row.id, dust)) 10 else if (terminal) 5 else 0;
        {
            const stmt = try channel_sql.prepare(
                \\INSERT INTO spilman_channels (channel_id,funding_json,balance,signature,state,closed_json)
                \\VALUES(lower(hex(?1)),json_object('params_json',CAST(?2 AS TEXT),'keyset_info_json','{}','funding_proofs_json',CAST(?3 AS TEXT)),
                \\  ?4,lower(hex(?5)),CAST(?6 AS TEXT),CAST(?7 AS TEXT))
            );
            defer stmt.finalize();
            try stmt.bindBlob(1, &row.id);
            try stmt.bindBlob(2, params_json);
            try stmt.bindBlob(3, open_proofs);
            try stmt.bindUInt(4, balance);
            if (balance != 0) try stmt.bindBlob(5, &signature);
            try stmt.bindBlob(6, switch (row.phase) {
                .settlement_pending => "Closing",
                .settled => "Closed",
                else => "Open",
            });
            if (row.phase == .settled) try stmt.bindBlob(7, "{\"receiver_sum\":5,\"sender_sum\":95,\"receiver_proofs_json\":\"[{\\\"receiver\\\":true}]\",\"sender_proofs_json\":\"[{\\\"sender\\\":true}]\"}");
            try stmt.finish();
        }
        if (row.phase == .settlement_pending) {
            const stmt = try channel_sql.prepare("INSERT INTO spilman_close_journals VALUES(lower(hex(?1)), 'journal')");
            defer stmt.finalize();
            try stmt.bindBlob(1, &row.id);
            try stmt.finish();
        }
    }

    const active_open: p.SpillmanChannelOpen = .{ .id = active, .proof = open_proofs, .params = active_params.? };
    const orphan_open: p.SpillmanChannelOpen = .{ .id = orphan, .proof = open_proofs, .params = orphan_params.? };
    for ([_]?ChannelId{ active, @splat(2), @splat(3), @splat(4), @splat(5), @splat(6), @splat(7), null, active, active, exhausted, exhausted_in_cutoff, expired_exhausted }, 0..) |id, i| {
        try db.saveUser(key, .{ .location = location, .hoe_channel_id = id });
        output.end = 0;
        var handler = try Handler.init(&socket, app);
        defer handler.close();
        handler.nonce = @splat(7);
        handler.deadline = transport.freshDeadline(t.io);
        // Model settlement holding the wallet lock during mint I/O.
        const busy = i == 8;
        {
            const held = if (busy) wallet.tryAcquire() orelse return error.TestWalletBusy else null;
            defer if (held) |channels| channels.release();
            if (i == 9) try channel_sql.exec("UPDATE spilman_channels SET state='offline' WHERE state='Open'");
            defer if (i == 9) channel_sql.exec("UPDATE spilman_channels SET state='Open' WHERE state='offline'") catch unreachable;
            if (busy or i == 9) {
                try t.expectError(error.AuthenticationRejected, handler.clientMessage(proof, .binary));
                try expectAuthFailure(output.buffered(), .unavailable);
                try t.expect(handler.session == null and !handler.authenticated);
                try t.expectEqual(id, (try db.loadUser(key)).?.hoe_channel_id);
                continue;
            }
            try handler.clientMessage(proof, .binary);
        }
        try handler.completeAuthentication();
        const ack = output.buffered();
        const depleted = std.meta.eql(id, @as(?ChannelId, exhausted)) or std.meta.eql(id, @as(?ChannelId, exhausted_in_cutoff));
        const spendable = std.meta.eql(id, @as(?ChannelId, active));
        const with_channel = spendable or depleted;
        try t.expectEqualSlices(u8, &.{ 0x82, if (with_channel) 72 else 15 }, ack[0..2]);
        const expected: p.AuthOutcome = if (with_channel) .{ .ok_with_hoe_channel = .{
            .location = location,
            .hoe_channel_id = id.?,
            .hoe_channel_capacity_msat = if (depleted) exhausted_capacity else active_capacity,
            .hoe_channel_balance_msat = if (depleted) exhausted_capacity else active_balance,
        } } else .{ .ok = location };
        try t.expectEqualDeep(expected, (try wire.decodeAuth(ack[2..], true, .reply)).reply);
        try t.expectEqual(id, (try db.loadUser(key)).?.hoe_channel_id);

        try t.expectEqual(spendable, app.registry.hoeChannel(handler.session.?) != null);
        var req_bytes: [p.max_request_bytes]u8 = undefined;
        var snapshot: p.Snapshot = undefined;
        const req_id: p.Id = @splat(0x21);
        if (depleted) {
            output.end = 0;
            try handler.clientMessage(try wire.encodeRequest(&req_bytes, .channel_status, .{ .request_id = req_id, .payload = .{ .id = id.? } }), .binary);
            try t.expectEqualDeep(p.Outcome(.channel_status){ .ok = .{
                .phase = .depleted,
                .capacity_msat = exhausted_capacity,
                .balance_msat = exhausted_capacity,
            } }, try wire.decodeReply(output.buffered()[2..], .channel_status, req_id, &snapshot));
            try expectOpen(&handler, &output, orphan_open, .{ .failed = .invalid_request });
            try t.expectEqual(id, (try db.loadUser(key)).?.hoe_channel_id);
        }
        if (!spendable) continue;
        for ([_]p.tool{ .hoe, .axe, .pickaxe }) |tool| {
            output.end = 0;
            const request = try wire.encodeRequest(&req_bytes, .channel_requirements, .{ .request_id = req_id, .payload = .{ .tool = tool } });
            const quote_before: u64 = @intCast(std.Io.Clock.real.now(t.io).toSeconds());
            try handler.clientMessage(request, .binary);
            const quote_after: u64 = @intCast(std.Io.Clock.real.now(t.io).toSeconds());
            const outcome = try wire.decodeReply(output.buffered()[2..], .channel_requirements, req_id, &snapshot);
            try t.expect(outcome == .ok);
            try t.expectEqual(wallet.receiverPubkey(week).?, outcome.ok.pubkey);
            try t.expectEqual(tool.priceMsat(), outcome.ok.amount);
            try t.expect(outcome.ok.refundTime >= quote_before + week and outcome.ok.refundTime <= quote_after + week);
        }

        try expectOpen(&handler, &output, .{ .id = active, .proof = "[]", .params = active_open.params }, .{ .failed = .invalid_proof });
        try expectOpen(&handler, &output, orphan_open, .{ .failed = .invalid_request });
        try expectOpen(&handler, &output, active_open, .{ .ok = {} });
        try t.expectEqual(@as(?ChannelId, active), (try db.loadUser(key)).?.hoe_channel_id);

        const closes = [_]struct { id: ChannelId, outcome: p.Outcome(.channel_close) }{
            .{ .id = active, .outcome = .{ .failed = .close_rejected } }, // one cut remaining
            .{ .id = dust, .outcome = .{ .failed = .close_rejected } }, // less than one unit, but not zero
            .{ .id = @splat(4), .outcome = .{ .failed = .close_rejected } }, // foreign
            .{ .id = @splat(7), .outcome = .{ .failed = .close_rejected } }, // missing
            .{ .id = @splat(2), .outcome = .{ .failed = .close_rejected } }, // expired, zero earned
            .{ .id = settled, .outcome = .ok }, // settled one-cut channel, different profile link
            .{ .id = settled, .outcome = .ok }, // lost ACK retry
        };
        for (closes) |close| {
            output.end = 0;
            try handler.clientMessage(try wire.encodeRequest(&req_bytes, .channel_close, .{ .request_id = req_id, .payload = .{ .id = close.id } }), .binary);
            try t.expectEqualDeep(close.outcome, try wire.decodeReply(output.buffered()[2..], .channel_close, req_id, &snapshot));
        }
        // The sender reads the receipt via status, even after retrying close.
        const statuses = [_]struct { id: ChannelId, outcome: p.Outcome(.channel_status) }{
            .{ .id = active, .outcome = .{ .ok = .{ .phase = .active, .capacity_msat = active_capacity, .balance_msat = active_balance } } },
            .{ .id = exhausted, .outcome = .{ .ok = .{ .phase = .depleted, .capacity_msat = exhausted_capacity, .balance_msat = exhausted_capacity } } },
            .{ .id = expired_exhausted, .outcome = .{ .ok = .{ .phase = .settlement_pending, .capacity_msat = exhausted_capacity, .balance_msat = exhausted_capacity } } },
            .{ .id = @splat(2), .outcome = .{ .ok = .{ .phase = .sender_refund_required, .capacity_msat = 100, .balance_msat = 0 } } },
            .{ .id = @splat(4), .outcome = .{ .failed = .not_found } }, // foreign
            .{ .id = @splat(5), .outcome = .{ .ok = .{ .phase = .settlement_pending, .capacity_msat = 100, .balance_msat = 5 } } },
            .{ .id = settled, .outcome = .{ .ok = .{ .phase = .settled, .capacity_msat = exhausted_capacity, .balance_msat = exhausted_capacity, .sender_proofs = sender_proofs } } },
            .{ .id = @splat(7), .outcome = .{ .failed = .not_found } }, // missing
            .{ .id = unredeemed, .outcome = .{ .ok = .{ .phase = .settlement_pending, .capacity_msat = 50, .balance_msat = 50 } } },
        };
        for (statuses) |status| {
            output.end = 0;
            try handler.clientMessage(try wire.encodeRequest(&req_bytes, .channel_status, .{ .request_id = req_id, .payload = .{ .id = status.id } }), .binary);
            try t.expectEqualDeep(status.outcome, try wire.decodeReply(output.buffered()[2..], .channel_status, req_id, &snapshot));
        }

        try t.expect(app.registry.hoeChannel(handler.session.?) != null);
        const channels = wallet.tryAcquire() orelse return error.TestWalletBusy;
        defer channels.release();
        try t.expectEqual(wallet_service.ChannelPhase.expired, (try channels.lookup(key, @splat(2), now)).?.phase);
        try t.expectEqual(wallet_service.ChannelPhase.depleted, (try channels.lookup(key, exhausted, now)).?.phase);
        try t.expectEqual(wallet_service.ChannelPhase.depleted, (try channels.lookup(key, exhausted_in_cutoff, now)).?.phase);
        try t.expectEqual(@as(?ChannelId, active), (try db.loadUser(key)).?.hoe_channel_id);
    }
    // The orphan models a committed admission with no committed profile link.
    // Force a profile write failure, then retry from a fresh authenticated session.
    const expired: ChannelId = @splat(2);
    try db.saveUser(key, .{ .location = location, .hoe_channel_id = expired });

    for (0..3) |i| {
        output.end = 0;
        var handler = try Handler.init(&socket, app);
        defer handler.close();
        handler.nonce = @splat(7);
        handler.deadline = transport.freshDeadline(t.io);
        try handler.clientMessage(proof, .binary);
        try handler.completeAuthentication();
        const handle = handler.session.?;
        if (i == 2) {
            try t.expectEqualDeep(p.AuthOutcome{ .ok_with_hoe_channel = .{
                .location = east,
                .hoe_channel_id = orphan,
                .hoe_channel_capacity_msat = 100,
                .hoe_channel_balance_msat = 0,
            } }, (try wire.decodeAuth(output.buffered()[2..], true, .reply)).reply);
            break;
        }
        if (i == 0) {
            try expectOpen(&handler, &output, .{ .id = exhausted, .proof = open_proofs, .params = "{}" }, .{ .failed = .invalid_proof });
            try game_sql.exec("CREATE TRIGGER reject_link BEFORE UPDATE OF hoe_channel_id ON game_users BEGIN SELECT raise(ABORT, 'test write failure'); END");
            try expectOpen(&handler, &output, orphan_open, .{ .failed = .unavailable });
            try game_sql.exec("DROP TRIGGER reject_link");
            try t.expectEqual(@as(?ChannelId, expired), app.registry.get(handle).?.hoe_channel_id);
            try t.expectEqual(@as(?ChannelId, expired), (try db.loadUser(key)).?.hoe_channel_id);
        } else {
            try app.registry.update(handle, east);
            try expectOpen(&handler, &output, orphan_open, .{ .ok = {} });
            try expectOpen(&handler, &output, orphan_open, .{ .ok = {} });
            try t.expectEqualDeep(@as(?p.Location, east), app.registry.get(handle).?.location);
            try t.expectEqual(@as(?ChannelId, orphan), app.registry.get(handle).?.hoe_channel_id);
            try t.expectEqualDeep(@import("game_db.zig").User{ .location = east, .hoe_channel_id = orphan }, (try db.loadUser(key)).?);
        }
    }
    {
        var handler = try Handler.init(&socket, app);
        defer handler.close();
        handler.nonce = @splat(7);
        handler.deadline = transport.freshDeadline(t.io);
        output.end = 0;
        try handler.clientMessage(proof, .binary);
        try handler.completeAuthentication();
        // The already-funded hoe channel cannot be reused for either tool.
        for ([_]p.tool{ .axe, .pickaxe }) |tool| {
            var reuse = active_open;
            reuse.tool = tool;
            try expectOpen(&handler, &output, reuse, .{ .failed = .invalid_proof });
            const id: ChannelId = @splat(@backingInt(tool) + 20);
            const capacity = tool.priceMsat() * 2;
            const params = try std.json.Stringify.valueAlloc(a, .{ .capacity = capacity, .expiry_timestamp = now + 3600, .sender_pubkey = test_pubkey_hex }, .{});
            const insert = try channel_sql.prepare("INSERT INTO receiver_channels (id,owner,price_msat) VALUES (?1,?2,?3)");
            defer insert.finalize();
            try insert.bindBlob(1, &id);
            try insert.bindBlob(2, &key);
            try insert.bindUInt(3, tool.priceMsat());
            try insert.finish();
            const fund = try channel_sql.prepare(
                \\INSERT INTO spilman_channels (channel_id,funding_json,balance,state)
                \\VALUES(lower(hex(?1)),json_object('params_json',CAST(?2 AS TEXT),'keyset_info_json','{}','funding_proofs_json',CAST(?3 AS TEXT)),0,'Open')
            );
            defer fund.finalize();
            try fund.bindBlob(1, &id);
            try fund.bindBlob(2, params);
            try fund.bindBlob(3, open_proofs);
            try fund.finish();
            try expectOpen(&handler, &output, .{ .id = id, .proof = open_proofs, .params = params, .tool = tool }, .{ .ok = {} });
            try t.expectEqual(id, (try db.loadUser(key)).?.channelId(tool).?);
        }
    }
    {
        var handler = try Handler.init(&socket, app);
        defer handler.close();
        handler.nonce = @splat(7);
        handler.deadline = transport.freshDeadline(t.io);
        output.end = 0;
        try handler.clientMessage(proof, .binary);
        try handler.completeAuthentication();
        const ack = output.buffered();
        try t.expectEqual(@as(u8, 126), ack[1]);
        const restored = (try wire.decodeAuth(ack[4..], true, .reply)).reply.ok_with_tool_channels;
        try t.expectEqualDeep(east, restored.location);
        try t.expectEqual(orphan, restored.channels[@backingInt(p.tool.hoe)].?.id);
        for ([_]p.tool{ .axe, .pickaxe }) |tool| {
            const id: ChannelId = @splat(@backingInt(tool) + 20);
            try t.expectEqualDeep(p.ToolChannel{ .id = id, .capacity_msat = tool.priceMsat() * 2, .balance_msat = 0 }, restored.channels[@backingInt(tool)].?);
            try t.expectEqual(id, app.registry.toolChannel(handler.session.?, tool).?.id);
        }
    }
    const channels = wallet.tryAcquire() orelse return error.TestWalletBusy;
    defer channels.release();
    try t.expectEqual(active_balance, (try channels.lookup(key, active, now)).?.balance_msat);
    try t.expectEqual(before, stateCount(&fixture));
}

fn expectOpen(handler: *Handler, output: *std.Io.Writer, payload: p.SpillmanChannelOpen, expected: p.Outcome(.channel_open)) !void {
    const request_id: p.Id = @splat(0x22);
    var bytes: [config.max_payload]u8 = undefined;
    output.end = 0;
    try handler.clientMessage(try wire.encodeRequest(&bytes, .channel_open, .{ .request_id = request_id, .payload = payload }), .binary);
    var snapshot: p.Snapshot = undefined;
    try std.testing.expectEqualDeep(expected, try wire.decodeReply(output.buffered()[2..], .channel_open, request_id, &snapshot));
}

fn runOneTickRequest(dispatch: *ticks.Dispatcher, app: *transport.App, slots: *[1]transport.Slot) void {
    defer dispatch.stop(slots);
    const deadline = transport.freshDeadline(dispatch.io);
    while (true) {
        transport.checkDeadline(dispatch.io, deadline) catch return;
        var batch = dispatch.beginBatch(slots, 0);
        if (dispatch.claimNext(slots, &batch, 0)) |work| {
            dispatch.execute(app, &slots[0].mailbox, work);
            return;
        }
        std.Io.sleep(dispatch.io, .fromMilliseconds(1), .awake) catch return;
    }
}

test "retained cut replay and conflict reach the tick when chunk preparation would fail" {
    const t = std.testing;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    const state = &app.context.state;
    var db = try GameDb.open(":memory:");
    defer db.close();
    var persistence = try Persistence.init(t.io, t.allocator, &db, state, app.registry);
    defer persistence.deinit(t.allocator);
    app.persistence = &persistence;

    const cut: p.RequestFor(.cut) = .{ .request_id = @splat(0x42), .payload = .{ .x = 0, .y = 0 } };
    const original: p.Request = .{ .request_id = cut.request_id, .operation = .{ .cut = cut.payload } };
    var pins = try persistence.prepare(original);
    defer persistence.release(&pins);
    const outcome = try state.cut(cut);
    try t.expect(outcome == .ok);
    persistence.release(&pins);
    try persistence.flush();

    // Replace the saved chunk with pinned rows so neither requested chunk can be loaded.
    const capacity = @import("world_state.zig").WorldState.cache_capacity;
    for (1..capacity + 1) |cx| try t.expect(state.installPinned(.{ .cx = @intCast(cx), .cy = 0 }, @splat(0), &.{}));
    try t.expectError(error.ChunkCacheBusy, persistence.prepare(original));
    const conflict: p.Cut = .{ .x = -16, .y = 0 };
    try t.expectError(error.ChunkCacheBusy, persistence.prepare(.{ .request_id = cut.request_id, .operation = .{ .cut = conflict } }));

    var input = std.Io.Reader.fixed("");
    var bytes: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var websocket = ws{ .input = &input, .output = &output, .key = "" };
    var dispatch: ticks.Dispatcher = .{ .io = t.io };
    var slots: [1]transport.Slot = @splat(.{});
    var handler = try Handler.init(&websocket, app);
    handler.session = try app.registry.claim(@splat(9));
    handler.authenticated = true;
    handler.dispatch = &dispatch;
    handler.mailbox = &slots[0].mailbox;
    defer handler.close();

    for ([_]p.Cut{ cut.payload, conflict }, [_]p.Outcome(.cut){ outcome, .{ .failed = .request_id_conflict } }) |tile, expected| {
        dispatch.stopping = false;
        output.end = 0;
        var group: std.Io.Group = .init;
        defer group.cancel(t.io);
        try group.concurrent(t.io, runOneTickRequest, .{ &dispatch, app, &slots });
        var request_bytes: [p.max_request_bytes]u8 = undefined;
        const request = try wire.encodeRequest(&request_bytes, .cut, .{ .request_id = cut.request_id, .payload = tile });
        try handler.clientMessage(request, .binary);
        var snapshot: p.Snapshot = undefined;
        try t.expectEqualDeep(expected, try wire.decodeReply(output.buffered()[2..], .cut, cut.request_id, &snapshot));
    }
    try t.expectEqual(@as(u64, 2), slots[0].mailbox.generation);
    try t.expectEqual(@as(usize, 1), state.replay_count);
}

test "tick admission replies typed busy without taking ownership of a mailbox generation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var input = std.Io.Reader.fixed("");
    var storage: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&storage);
    var websocket = ws{ .input = &input, .output = &output, .key = "" };
    var dispatch: @import("tick_mailbox.zig").Dispatcher = .{ .io = std.testing.io };
    var box: @import("tick_mailbox.zig").Mailbox = .{};
    var handler = try Handler.init(&websocket, &fixture.application);
    handler.dispatch = &dispatch;
    handler.mailbox = &box;
    defer handler.close();
    const req = p.RequestFor(.update_location){ .request_id = @splat(0x42), .payload = .{ .x = 1, .y = 2 } };
    var request_storage: [p.max_request_bytes]u8 = undefined;
    const request = try wire.encodeRequest(&request_storage, .update_location, req);
    handler.deadline = transport.freshDeadline(std.testing.io);
    try handler.clientMessage(request, .binary);
    try std.testing.expectEqualSlices(u8, protocol_error_frame, output.buffered());
    try std.testing.expect(!handler.authenticated and handler.session == null);

    const session = try fixture.application.registry.claim(@splat(3));
    handler.session = session;
    handler.authenticated = true;
    const pending_id: p.Id = @splat(0x17);
    try dispatch.publish(&box, session, .{ .request_id = pending_id, .operation = .{ .update_location = req.payload } });
    box.reply[0] = 0xa5;
    box.len = 1;
    const busy = p.Outcome(.update_location){ .failed = .server_busy };
    var snapshot: p.Snapshot = undefined;
    output.end = 0;
    try handler.clientMessage(request, .binary);
    try std.testing.expectEqualDeep(busy, try wire.decodeReply(output.buffered()[2..], .update_location, req.request_id, &snapshot));
    try std.testing.expect(box.state == .queued);
    try std.testing.expectEqual(@as(u64, 1), box.generation);
    try std.testing.expectEqual(pending_id, box.request.request_id);
    try std.testing.expectEqualSlices(u8, &.{0xa5}, box.reply[0..box.len]);
    try std.testing.expect(handler.authenticated);

    dispatch.cleanup(&box);
    box.generation = std.math.maxInt(u64);
    output.end = 0;
    try std.testing.expectError(error.GenerationExhausted, handler.clientMessage(request, .binary));
    try std.testing.expectEqualDeep(busy, try wire.decodeReply(output.buffered()[2..], .update_location, req.request_id, &snapshot));
    try std.testing.expect(box.state == .idle);
    try std.testing.expectEqual(std.math.maxInt(u64), box.generation);

    dispatch.stopping = true;
    output.end = 0;
    try std.testing.expectError(error.ServerStopping, handler.clientMessage(request, .binary));
    try std.testing.expectEqualDeep(busy, try wire.decodeReply(output.buffered()[2..], .update_location, req.request_id, &snapshot));
    try std.testing.expectEqualDeep(spawn, fixture.application.registry.get(session).?.location.?);
}

test "rejected tick admission releases prepared pins before flushing the busy reply" {
    const t = std.testing;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    const state = &app.context.state;
    var db = try GameDb.open(":memory:");
    defer db.close();
    var persistence = try Persistence.init(t.io, t.allocator, &db, state, app.registry);
    defer persistence.deinit(t.allocator);
    app.persistence = &persistence;

    const address = @import("chunk_address.zig").ChunkAddress.fromTile(0, 0);
    try t.expect(state.installPinned(address, @splat(0), &.{}));
    state.unpin(address);
    const PinObserver = struct {
        pins: *const usize,
        pins_at_flush: ?usize = null,
        writer: std.Io.Writer,
        fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *@This() = @fieldParentPtr("writer", writer);
            self.pins_at_flush = self.pins.*;
        }
    };
    var bytes: [128]u8 = undefined;
    var output = PinObserver{ .pins = &state.cache.?.rows[0].pins, .writer = .{
        .buffer = &bytes,
        .vtable = &.{ .drain = std.Io.Writer.fixedDrain, .flush = PinObserver.flush },
    } };
    var input = std.Io.Reader.fixed("");
    var websocket = ws{ .input = &input, .output = &output.writer, .key = "" };
    var dispatch: ticks.Dispatcher = .{ .io = t.io, .stopping = true };
    var box: ticks.Mailbox = .{};
    var handler = try Handler.init(&websocket, app);
    handler.session = try app.registry.claim(@splat(3));
    handler.authenticated = true;
    handler.dispatch = &dispatch;
    handler.mailbox = &box;
    defer handler.close();

    const cut: p.RequestFor(.cut) = .{ .request_id = @splat(0x42), .payload = .{ .x = 0, .y = 0 } };
    var request_bytes: [p.max_request_bytes]u8 = undefined;
    const request = try wire.encodeRequest(&request_bytes, .cut, cut);
    try t.expectError(error.ServerStopping, handler.clientMessage(request, .binary));
    try t.expectEqual(@as(?usize, 0), output.pins_at_flush);
    var snapshot: p.Snapshot = undefined;
    try t.expectEqualDeep(p.Outcome(.cut){ .failed = .server_busy }, try wire.decodeReply(output.writer.buffered()[2..], .cut, cut.request_id, &snapshot));
    try t.expectEqual(@as(u64, 0), box.generation);
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
    var fixture = try Fixture.initWith(allocator, std.testing.io, @import("app.zig").default_budget);
    defer {
        guard.frozen = false;
        fixture.deinit();
    }
    guard.frozen = true;
    var handles: [64]sessions.Handle = undefined;
    for (&handles, 0..) |*handle, i| {
        handle.* = try fixture.application.registry.claim(@splat(@intCast(i)));
        try std.testing.expectEqualDeep(spawn, fixture.application.registry.get(handle.*).?.location.?);
        const req = p.RequestFor(.update_location){ .request_id = @splat(0), .payload = east };
        try std.testing.expect(fixture.application.handleLocation(handle.*, req) == .ok);
        try std.testing.expectEqualDeep(east, fixture.application.registry.get(handle.*).?.location.?);
        var snapshot: p.Snapshot = undefined;
        _ = try fixture.application.context.state.cut(@import("world_state.zig").request(i, @intCast(i), -1));
        try fixture.application.context.state.readArea(.{ .cx0 = 0, .cy0 = 0, .cx1 = 7, .cy1 = 7 }, &snapshot);
    }
    for (handles) |handle| fixture.application.registry.release(handle);
    try std.testing.expect(@sizeOf(@import("app.zig").Layout) <= @import("app.zig").default_budget);
    std.debug.print("BUDGET,app_layout_bytes={d},session_registry_bytes={d},world_state_bytes={d},context_bytes={d}\n", .{ @sizeOf(@import("app.zig").Layout), @sizeOf(sessions.Registry), @sizeOf(@import("world_state.zig").WorldState), @sizeOf(@import("app.zig").Context) });
}
