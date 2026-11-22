//! std I/O transport; gameplay crosses a stable, bounded tick mailbox.
const ws = std.http.Server.WebSocket;
const wire = @import("shared").wire;
const p = @import("shared").protocol;
const application = @import("app.zig");
pub const App = application.App;
const sessions = @import("sessions.zig");
const std = @import("std");
const auth = @import("ws_auth.zig");
const config = @import("ws_config.zig");
const ticks = @import("tick_mailbox.zig");
const tick = @import("shared").tick;
pub const Deadline = std.Io.Clock.Timestamp;

pub fn freshDeadline(io: std.Io) Deadline {
    return Deadline.fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake });
}
pub fn checkDeadline(io: std.Io, deadline: Deadline) !void {
    if (Deadline.now(io, deadline.clock).compare(.gte, deadline)) return error.DeadlineExpired;
}

/// Validate framing omitted by std; bytes, masking and messages belong to std.
pub const FrameInput = struct {
    source: *std.Io.Reader,
    remaining: usize = 0,
    interface: std.Io.Reader,

    pub fn init(source: *std.Io.Reader, buffer: []u8) FrameInput {
        return .{ .source = source, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }
    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *FrameInput = @fieldParentPtr("interface", r);
        if (limit == .nothing) return 0;
        if (self.remaining == 0) {
            const head = (try self.source.peekArray(2)).*;
            const h0: ws.Header0 = @bitCast(head[0]);
            const h1: ws.Header1 = @bitCast(head[1]);
            if (h0.rsv1 != 0 or h0.rsv2 != 0 or h0.rsv3 != 0 or !h0.fin or !h1.mask) return error.ReadFailed;
            const control = switch (h0.opcode) {
                .text, .binary => false,
                .ping, .pong, .connection_close => true,
                else => return error.ReadFailed,
            };
            var header_len: usize = 2;
            const length: u64 = switch (h1.payload_len) {
                .len16 => blk: {
                    const bytes = try self.source.peekArray(4);
                    const n = std.mem.readInt(u16, bytes[2..4], .big);
                    if (n < 126) return error.ReadFailed;
                    header_len = 4;
                    break :blk n;
                },
                // Canonical 64-bit lengths exceed the fixed payload cap.
                .len64 => return error.ReadFailed,
                else => @backingInt(h1.payload_len),
            };
            if (length > config.max_payload or (control and length > 125) or (h0.opcode == .connection_close and length == 1)) return error.ReadFailed;
            self.remaining = header_len + 4 + @as(usize, @intCast(length));
        }
        const n = try self.source.stream(w, limit.min(.limited(self.remaining)));
        self.remaining -= n;
        return n;
    }
};

pub fn validateUpgrade(request: *std.http.Server.Request, key: *[24]u8) !void {
    const head = request.head;
    if (head.method != .GET or head.version != .@"HTTP/1.1" or !std.mem.eql(u8, head.target, "/")) return error.InvalidUpgrade;
    var upgrade = false;
    var connection = false;
    var version = false;
    var found_key = false;
    var found_host = false;
    var count: usize = 0;
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        count += 1;
        if (count > config.max_headers) return error.InvalidUpgrade;
        const name = header.name;
        const value = header.value;
        if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            if (upgrade or !std.ascii.eqlIgnoreCase(value, "websocket")) return error.InvalidUpgrade;
            upgrade = true;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (connection) return error.InvalidUpgrade;
            var tokens = std.mem.splitScalar(u8, value, ',');
            while (tokens.next()) |token| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), "upgrade")) connection = true;
            }
            if (!connection) return error.InvalidUpgrade;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) {
            if (version or !std.mem.eql(u8, value, "13")) return error.InvalidUpgrade;
            version = true;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
            if (found_key or value.len != key.len) return error.InvalidUpgrade;
            var decoded: [16]u8 = undefined;
            if ((std.base64.standard.Decoder.calcSizeForSlice(value) catch return error.InvalidUpgrade) != decoded.len) return error.InvalidUpgrade;
            std.base64.standard.Decoder.decode(&decoded, value) catch return error.InvalidUpgrade;
            @memcpy(key, value);
            found_key = true;
        } else if (std.ascii.eqlIgnoreCase(name, "host")) {
            if (found_host) return error.InvalidUpgrade;
            found_host = true;
        } else if (std.ascii.eqlIgnoreCase(name, "expect") or std.ascii.eqlIgnoreCase(name, "content-length") or std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return error.InvalidUpgrade;
    }
    if (!upgrade or !connection or !version or !found_key) return error.InvalidUpgrade;
}

pub const Handler = struct {
    conn: *ws,
    app: *App,
    nonce: [32]u8,
    deadline: Deadline,
    session: ?sessions.Handle = null,
    authenticated: bool = false,
    reported_decode_error: bool = false,
    dispatch: ?*ticks.Dispatcher = null,
    mailbox: ?*ticks.Mailbox = null,
    pub fn init(conn: *ws, app: *App) !Handler {
        var nonce: [32]u8 = undefined;
        try app.registry.io.randomSecure(&nonce);
        return .{ .conn = conn, .app = app, .nonce = nonce, .deadline = undefined };
    }
    pub fn sendChallenge(self: *Handler) !void {
        try checkDeadline(self.app.registry.io, self.deadline);
        var challenge: [39]u8 = undefined;
        try self.conn.writeMessage(try wire.encodeAuth(&challenge, .{ .challenge = self.nonce }), .binary);
    }
    pub fn close(self: *Handler) void {
        if (self.dispatch) |dispatch| dispatch.cleanup(self.mailbox.?);
        if (self.session) |session| self.app.registry.release(session);
        self.session = null;
        self.authenticated = false;
    }
    fn sendAuthReply(self: *Handler, outcome: p.AuthOutcome) !void {
        const io = self.app.registry.io;
        try checkDeadline(io, self.deadline);
        var reply: [15]u8 = undefined;
        try self.conn.writeMessage(try wire.encodeAuth(&reply, .{ .reply = outcome }), .binary);
        try checkDeadline(io, self.deadline);
    }
    fn rejectAuth(self: *Handler, failure: p.AuthFailure) !void {
        try self.sendAuthReply(.{ .failed = failure });
        return error.AuthenticationRejected;
    }
    fn sendProtocolError(self: *Handler, err: wire.DecodeError) !void {
        if (!self.reported_decode_error) {
            std.log.scoped(.wire).debug("rejected client message: {s}", .{@errorName(err)});
            self.reported_decode_error = true;
        }
        try self.conn.writeMessage(&wire.protocol_error, .binary);
    }
    pub fn clientMessage(self: *Handler, data: []const u8, tpe: ws.Opcode) !void {
        if (!self.authenticated) {
            std.debug.assert(self.session == null);
            const io = self.app.registry.io;
            try checkDeadline(io, self.deadline);
            const message = (if (data.len > p.max_gameplay_request_bytes)
                error.MessageTooLarge
            else
                wire.decodeAuth(data, tpe == .binary, .proof)) catch |err| {
                try self.sendProtocolError(err);
                return checkDeadline(io, self.deadline);
            };
            const proof = message.proof;
            const key = auth.verifyAuth(proof.pubkey, self.nonce, proof.signature) catch
                return self.rejectAuth(.invalid_credentials);
            try checkDeadline(io, self.deadline);
            self.session = (if (self.app.persistence) |storage|
                storage.claim(key, self.deadline)
            else
                self.app.registry.claimBefore(key, self.deadline)) catch |err| switch (err) {
                error.DeadlineExpired, error.Canceled => return err,
                else => return self.rejectAuth(.unavailable),
            };
            errdefer self.close();
            const location = self.app.registry.get(self.session.?).?.location.?;
            try self.sendAuthReply(.{ .ok = location });
            return;
        }
        const req = wire.decodeMessage(data, tpe == .binary) catch |err|
            return self.sendProtocolError(err);
        if (p.isChannel(std.meta.activeTag(req.operation))) return self.rejectChannel(req);

        const dispatch = self.dispatch orelse return error.MissingTickDispatcher;
        const box = self.mailbox.?;
        const storage = self.app.persistence;
        var replay = try self.app.retainedCut(req);
        var pins: @import("persistence.zig").Pins = .{};
        if (storage) |store| {
            if (replay == null) pins = store.prepare(req) catch |err| blk: {
                if (err == error.Canceled) return err;
                // Another connection may have admitted this ID while prepare ran.
                replay = try self.app.retainedCut(req);
                if (replay != null) break :blk .{};
                var reply: [p.max_response_bytes]u8 = undefined;
                return self.conn.writeMessage(application.encodeCommonFailure(&reply, req, .server_busy), .binary);
            };
        }
        defer if (storage) |store| store.release(&pins);
        dispatch.publishPrepared(box, self.session.?, req, replay) catch |err| switch (err) {
            error.NotGameplayRequest => unreachable,
            error.RequestPending, error.ServerStopping, error.GenerationExhausted => {
                // A rejected publish owns no generation and must not touch the box.
                if (storage) |store| store.release(&pins);
                var reply: [p.max_response_bytes]u8 = undefined;
                try self.conn.writeMessage(application.encodeCommonFailure(&reply, req, .server_busy), .binary);
                if (err != error.RequestPending) return err;
                return;
            },
        };
        try self.finishPreparedReply(&pins);
    }
    /// Called only after proof/ACK work has joined successfully.
    pub fn completeAuthentication(self: *Handler) !void {
        try self.app.registry.confirmBefore(self.session.?, self.deadline);
        self.authenticated = true;
    }
    fn rejectChannel(self: *Handler, req: p.Request) !void {
        // Open proof bytes borrow the receive buffer until the next WebSocket read.
        // Keep this route synchronous and never publish a channel request to the tick.
        // No channel service or durable ledger is configured; the wallet alone is not one.
        var reply: [28]u8 = undefined; // Envelope, ID TLV, and two-byte failure TLV.
        const bytes = switch (req.operation) {
            inline .channel_requirements, .channel_open, .channel_payment, .channel_close => |payload, kind| try wire.encodeReply(&reply, kind, .{ .request_id = req.request_id, .payload = payload }, .{ .failed = .unavailable }),
            .cut, .read_area, .update_location => unreachable,
        };
        try self.conn.writeMessage(bytes, .binary);
    }
    pub fn finishReply(self: *Handler) !void {
        var pins = @import("persistence.zig").Pins{};
        return self.finishPreparedReply(&pins);
    }
    fn finishPreparedReply(self: *Handler, pins: *@import("persistence.zig").Pins) !void {
        const box = self.mailbox.?;
        defer self.dispatch.?.cleanup(box);
        try box.completion.wait(self.app.registry.io);
        if (self.app.persistence) |storage| storage.release(pins);
        try self.conn.writeMessage(box.reply[0..box.len], .binary);
        if (box.close_after_reply) return error.StaleSession;
    }
};

pub const Slot = struct {
    mailbox: ticks.Mailbox = .{},
    occupied: std.atomic.Value(bool) = .init(false),
    stream: std.Io.net.Stream = undefined,
    deadline: Deadline = undefined,
    http_buffer: [config.http_head_size]u8 = undefined,
    ws_buffer: [config.max_payload]u8 = undefined,
    output_buffer: [512]u8 = undefined,
    key: [24]u8 = undefined,
};

const AcceptAction = enum { retry, backoff, stop };
fn acceptAction(err: std.Io.net.Server.AcceptError) AcceptAction {
    return switch (err) {
        error.ConnectionAborted, error.ProtocolFailure, error.BlockedByFirewall => .retry,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources, error.WouldBlock => .backoff,
        else => .stop,
    };
}

test "accept errors retry connection failures back off resource failures and preserve fatal errors" {
    for ([_]std.Io.net.Server.AcceptError{ error.ConnectionAborted, error.ProtocolFailure, error.BlockedByFirewall }) |err|
        try std.testing.expectEqual(AcceptAction.retry, acceptAction(err));
    for ([_]std.Io.net.Server.AcceptError{ error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources, error.WouldBlock }) |err|
        try std.testing.expectEqual(AcceptAction.backoff, acceptAction(err));
    for ([_]std.Io.net.Server.AcceptError{ error.Canceled, error.SocketNotListening, error.NetworkDown, error.Unexpected }) |err|
        try std.testing.expectEqual(AcceptAction.stop, acceptAction(err));
}

pub const Server = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    slots: []Slot,
    dispatch: ticks.Dispatcher,
    schedule: tick.Schedule = .{},

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !Server {
        const slots = try allocator.alloc(Slot, config.max_connections);
        for (slots) |*slot| slot.* = .{};
        return .{ .io = io, .allocator = allocator, .slots = slots, .dispatch = .{ .io = io } };
    }
    pub fn deinit(self: *Server) void {
        self.allocator.free(self.slots);
    }
    pub fn reserve(self: *Server) ?*Slot {
        for (self.slots) |*slot| {
            if (slot.occupied.cmpxchgStrong(false, true, .acquire, .monotonic) == null) return slot;
        }
        return null;
    }
    pub fn release(_: *Server, slot: *Slot) void {
        std.debug.assert(slot.mailbox.state == .idle);
        slot.occupied.store(false, .release);
    }
    pub fn listen(self: *Server, app: *App) !void {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", config.port);
        var listener = try address.listen(self.io, .{ .reuse_address = true });
        defer listener.deinit(self.io);
        var group: std.Io.Group = .init;
        defer group.cancel(self.io); // joins before app/slots can be freed
        try group.concurrent(self.io, tickTask, .{ self, app });
        if (app.persistence) |storage| try group.concurrent(self.io, @import("persistence.zig").Persistence.saveLoop, .{storage});
        while (true) {
            const stream = listener.accept(self.io) catch |err| switch (acceptAction(err)) {
                .retry => continue,
                .backoff => {
                    try self.io.sleep(.fromMilliseconds(100), .awake);
                    continue;
                },
                .stop => return err,
            };
            const deadline = freshDeadline(self.io);
            const slot = self.reserve() orelse {
                stream.close(self.io);
                continue;
            };
            slot.stream = stream;
            slot.deadline = deadline;
            group.concurrent(self.io, serve, .{ self, slot, app }) catch {
                stream.close(self.io);
                self.release(slot);
            };
        }
    }
    fn serve(self: *Server, slot: *Slot, app: *App) void {
        defer self.release(slot);
        defer slot.stream.close(self.io);
        serveConnection(self, slot, app) catch {};
    }

    fn now(self: *Server) i128 {
        return Deadline.now(self.io, .awake).raw.nanoseconds;
    }
    fn tickTask(self: *Server, app: *App) void {
        defer self.dispatch.stop(self.slots);
        self.tickLoop(app) catch |err| switch (err) {
            error.Canceled => {},
        };
    }
    fn tickLoop(self: *Server, app: *App) std.Io.Cancelable!void {
        while (true) {
            try self.io.checkCancel();
            if (self.schedule.poll(self.now())) {
                var batch = self.dispatch.beginBatch(self.slots, self.now());
                while (true) {
                    try self.io.checkCancel();
                    const work = self.dispatch.claimNext(self.slots, &batch, self.now()) orelse break;
                    self.dispatch.execute(app, &self.slots[work.record.index].mailbox, work);
                }
                self.schedule.skipPast(self.now());
            }
            const next = self.schedule.nextDeadline() orelse return;
            // Timestamp storage is narrower than the shared scheduler. Fail
            // closed (and wake queued connections) rather than overflow or spin.
            const ns = std.math.cast(i96, next) orelse return;
            try (Deadline{ .raw = .{ .nanoseconds = ns }, .clock = .awake }).wait(self.io);
        }
    }
};

test "production tick owner executes queued work and group cancellation joins its absolute wait" {
    var fixture = try @import("fixture.zig").Fixture.init();
    defer fixture.deinit();
    var server = try Server.init(std.testing.io, std.testing.allocator);
    defer server.deinit();
    const slot = server.reserve().?;
    defer server.release(slot);
    const session = try fixture.application.registry.claim(@splat(19));
    try server.dispatch.publish(&slot.mailbox, session, .{
        .request_id = @splat(0),
        .operation = .{ .update_location = .{ .x = 1, .y = 0 } },
    });
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    try group.concurrent(std.testing.io, Server.tickTask, .{ &server, &fixture.application });
    try slot.mailbox.completion.wait(std.testing.io);
    group.cancel(std.testing.io);
    try std.testing.expect(server.dispatch.stopping);
    try std.testing.expectEqual(@as(i32, 1), fixture.application.registry.get(session).?.location.?.x);
    server.dispatch.cleanup(&slot.mailbox);
}

const Connection = struct {
    io: std.Io,
    slot: *Slot,
    http: std.http.Server,
    request: std.http.Server.Request = undefined,
    guard: *FrameInput,
    websocket: ws = undefined,
    handler: Handler = undefined,

    fn receive(self: *Connection) !void {
        try checkDeadline(self.io, self.slot.deadline);
        self.request = try self.http.receiveHead();
        try validateUpgrade(&self.request, &self.slot.key);
        try checkDeadline(self.io, self.slot.deadline);
    }
    fn authenticate(self: *Connection) !void {
        try checkDeadline(self.io, self.handler.deadline);
        self.websocket = try self.request.respondWebSocket(.{ .key = &self.slot.key });
        self.websocket.input = &self.guard.interface;
        try self.handler.sendChallenge(); // flushes HTTP101 and challenge together
        while (self.handler.session == null) {
            const message = try self.websocket.readSmallMessage();
            try checkDeadline(self.io, self.handler.deadline);
            if (message.opcode == .ping) {
                try self.websocket.writeMessage(message.data, .pong);
                continue;
            }
            try self.handler.clientMessage(message.data, message.opcode);
        }
    }
};

test "connection authentication reads past malformed messages under the original deadline" {
    var fixture = try @import("fixture.zig").Fixture.init();
    defer fixture.deinit();
    const head = "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    const malformed_frame = "\x82\x80\x00\x00\x00\x00";
    const proof_header = "\x82\xeb\x00\x00\x00\x00";
    var input_bytes: [head.len + malformed_frame.len + proof_header.len + 107]u8 = undefined;
    const prefix = head ++ malformed_frame ++ proof_header;
    @memcpy(input_bytes[0..prefix.len], prefix);
    _ = try wire.encodeAuth(input_bytes[prefix.len..], .{ .proof = .{ .pubkey = @splat(0), .signature = @splat(0) } });
    var input = std.Io.Reader.fixed(&input_bytes);
    var slot: Slot = .{};
    slot.deadline = freshDeadline(std.testing.io);
    var output = std.Io.Writer.fixed(&slot.output_buffer);
    var guard = FrameInput.init(&input, &slot.ws_buffer);
    var connection = Connection{ .io = std.testing.io, .slot = &slot, .http = .init(&input, &output), .guard = &guard };
    try connection.receive();
    connection.handler = try Handler.init(&connection.websocket, &fixture.application);
    defer connection.handler.close();
    const deadline = freshDeadline(std.testing.io);
    connection.handler.deadline = deadline;
    try std.testing.expectError(error.AuthenticationRejected, connection.authenticate());
    const reply_frames = "\x82\x04\xff\x00\x00\x7e" ++ "\x82\x09\xf2\x05\x00\x04\x02\x00\x01\x00\x7e";
    try std.testing.expect(std.mem.endsWith(u8, output.buffered(), reply_frames));
    try std.testing.expectEqualDeep(deadline, connection.handler.deadline);
    try std.testing.expect(!connection.handler.authenticated and connection.handler.session == null);
}

fn race(io: std.Io, deadline: Deadline, comptime work: anytype, args: anytype) !void {
    const Result = union(enum) { work: anyerror!void, timer: std.Io.Cancelable!void };
    var results: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &results);
    defer select.cancelDiscard(); // unconditional cancel + JOIN, even on partial launch
    try select.concurrent(.work, work, args);
    try select.concurrent(.timer, Deadline.wait, .{ deadline, io });
    switch (try select.await()) {
        .work => |result| try result,
        .timer => |result| {
            try result;
            return error.DeadlineExpired;
        },
    }
    try checkDeadline(io, deadline);
}

test "deadline race joins cancelled work before returning without sockets" {
    const Work = struct {
        finished: std.atomic.Value(bool) = .init(false),
        fn wait(self: *@This(), io: std.Io) anyerror!void {
            defer self.finished.store(true, .release);
            try freshDeadline(io).wait(io);
        }
    };
    var work = Work{};
    const expired: Deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake };
    try std.testing.expectError(error.DeadlineExpired, race(std.testing.io, expired, Work.wait, .{ &work, std.testing.io }));
    try std.testing.expect(work.finished.load(.acquire));
}

fn serveConnection(server: *Server, slot: *Slot, app: *App) !void {
    const io = server.io;
    var reader = slot.stream.reader(io, &slot.http_buffer);
    var writer = slot.stream.writer(io, &slot.output_buffer);
    var guard = FrameInput.init(&reader.interface, &slot.ws_buffer);
    var connection = Connection{ .io = io, .slot = slot, .http = .init(&reader.interface, &writer.interface), .guard = &guard };
    try race(io, slot.deadline, Connection.receive, .{&connection});
    connection.handler = try Handler.init(&connection.websocket, app);
    connection.handler.dispatch = &server.dispatch;
    connection.handler.mailbox = &slot.mailbox;
    defer connection.handler.close();
    // Separate absolute auth window: preparation and HTTP time do not consume it.
    connection.handler.deadline = freshDeadline(io);
    try race(io, connection.handler.deadline, Connection.authenticate, .{&connection});
    try connection.handler.completeAuthentication();
    while (true) {
        const message = try connection.websocket.readSmallMessage();
        if (message.opcode == .ping) {
            try connection.websocket.writeMessage(message.data, .pong);
        } else try connection.handler.clientMessage(message.data, message.opcode);
    }
}
