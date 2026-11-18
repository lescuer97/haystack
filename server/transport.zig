//! std I/O transport; the leased application context lives through synchronous writes.
const ws = std.http.Server.WebSocket;
const wire = @import("shared").wire;
const p = @import("shared").protocol;
pub const App = @import("app.zig").App;
const sessions = @import("sessions.zig");
const std = @import("std");
const auth = @import("ws_auth.zig");
const config = @import("ws_config.zig");
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
                // ponytail: canonical 64-bit lengths exceed the fixed 128-byte cap.
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
    pub fn init(conn: *ws, app: *App) !Handler {
        var nonce: [32]u8 = undefined;
        try app.registry.io.randomSecure(&nonce);
        return .{ .conn = conn, .app = app, .nonce = nonce, .deadline = undefined };
    }
    pub fn sendChallenge(self: *Handler) !void {
        try checkDeadline(self.app.registry.io, self.deadline);
        var challenge: [33]u8 = undefined;
        try self.conn.writeMessage(wire.encodeAuth(&challenge, .{ .challenge = self.nonce }), .binary);
    }
    pub fn close(self: *Handler) void {
        if (self.session) |session| self.app.registry.release(session);
        self.session = null;
        self.authenticated = false;
    }
    pub fn clientMessage(self: *Handler, data: []u8, tpe: ws.Opcode) !void {
        if (!self.authenticated) {
            const io = self.app.registry.io;
            try checkDeadline(io, self.deadline);
            const proof = switch (try wire.decodeAuth(data, tpe == .binary)) {
                .proof => |proof| proof,
                else => return error.InvalidAuthentication,
            };
            const key = try auth.verifyAuth(proof.pubkey, self.nonce, proof.signature);
            try checkDeadline(io, self.deadline);
            self.session = try self.app.registry.claimBefore(key, self.deadline);
            errdefer self.close();
            var ack: [1]u8 = undefined;
            try checkDeadline(io, self.deadline);
            try self.conn.writeMessage(wire.encodeAuth(&ack, .authenticated), .binary);
            try checkDeadline(io, self.deadline);
            self.authenticated = true;
            return;
        }
        if (data.len > 0 and data[0] == @backingInt(p.AuthKind.proof)) return error.RepeatedAuthentication;
        var error_storage: [33]u8 = undefined;
        switch (wire.decodeMessage(data, tpe == .binary)) {
            .failure => |f| try self.conn.writeMessage(wire.encode(&error_storage, f), .binary),
            .request => |req| {
                if (req.operation == .update_location) {
                    const response = self.app.handleLocation(self.session.?, req);
                    try self.conn.writeMessage(wire.encode(&error_storage, response), .binary);
                    if (response.result == .failure) return error.StaleSession;
                    return;
                }
                const context = self.app.lease() orelse {
                    try self.conn.writeMessage(wire.encode(&error_storage, wire.failure(req.request_id, .server_busy)), .binary);
                    return;
                };
                defer self.app.release(context);
                try self.conn.writeMessage(context.handle(req), .binary);
            },
        }
    }
};

pub const Slot = struct {
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

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !Server {
        const slots = try allocator.alloc(Slot, config.max_connections);
        for (slots) |*slot| slot.* = .{};
        return .{ .io = io, .allocator = allocator, .slots = slots };
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
        slot.occupied.store(false, .release);
    }
    pub fn listen(self: *Server, app: *App) !void {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", config.port);
        var listener = try address.listen(self.io, .{ .reuse_address = true });
        defer listener.deinit(self.io);
        var group: std.Io.Group = .init;
        defer group.cancel(self.io); // joins before app/slots can be freed
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
        serveConnection(self.io, slot, app) catch {};
    }
};

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
        while (true) {
            const message = try self.websocket.readSmallMessage();
            try checkDeadline(self.io, self.handler.deadline);
            if (message.opcode == .ping) {
                try self.websocket.writeMessage(message.data, .pong);
                continue;
            }
            try self.handler.clientMessage(message.data, message.opcode);
            return;
        }
    }
};

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

fn serveConnection(io: std.Io, slot: *Slot, app: *App) !void {
    var reader = slot.stream.reader(io, &slot.http_buffer);
    var writer = slot.stream.writer(io, &slot.output_buffer);
    var guard = FrameInput.init(&reader.interface, &slot.ws_buffer);
    var connection = Connection{ .io = io, .slot = slot, .http = .init(&reader.interface, &writer.interface), .guard = &guard };
    try race(io, slot.deadline, Connection.receive, .{&connection});
    connection.handler = try Handler.init(&connection.websocket, app);
    defer connection.handler.close();
    // Separate absolute auth window: preparation and HTTP time do not consume it.
    connection.handler.deadline = freshDeadline(io);
    try race(io, connection.handler.deadline, Connection.authenticate, .{&connection});
    try checkDeadline(io, connection.handler.deadline);
    while (true) {
        const message = try connection.websocket.readSmallMessage();
        if (message.opcode == .ping) {
            try connection.websocket.writeMessage(message.data, .pong);
        } else try connection.handler.clientMessage(message.data, message.opcode);
    }
}
