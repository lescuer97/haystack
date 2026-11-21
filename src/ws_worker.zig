//! Desktop-only connection owner. The frame thread exchanges bounded state
//! and one move with the worker; it never performs socket I/O or signing.
const std = @import("std");
const ws = @import("websocket");
const shared = @import("shared");
const wire = shared.wire;
const protocol = shared.protocol;
const wallet = @import("wallet.zig");
const ws_auth = @import("ws_auth.zig");

const poll_ms = 20;
const endpoint = "127.0.0.1";
const port = 9224;

pub const Status = enum { disabled, connecting, authenticating, ready, retrying, wallet_error, credentials_rejected };
pub const Snapshot = struct {
    status: Status = .disabled,
    session: u64 = 0,
    confirmed: protocol.Location = shared.movement.spawn,
    pending: bool = false,
};

pub const Worker = struct {
    paths: wallet.Paths,
    io: std.Io,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    stopping: bool = false,
    enabled: bool = false,
    generation: u64 = 0,
    state: Snapshot = .{},
    outbox: ?protocol.Location = null,

    // The frame thread owns this value at a fixed address until stop joins it.
    pub fn start(self: *Worker) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    pub fn setEnabled(self: *Worker, enabled: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (enabled == self.enabled) return;
        self.enabled = enabled;
        self.generation +%= 1;
        self.state.status = if (enabled) .connecting else .disabled;
        self.state.pending = false;
        self.outbox = null;
    }

    pub fn snapshot(self: *Worker) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state;
    }

    pub fn submit(self: *Worker, session: u64, destination: protocol.Location) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state.status != .ready or self.state.session != session or self.state.pending) return false;
        self.outbox = destination;
        self.state.pending = true;
        return true;
    }

    fn activeLocked(self: *const Worker, generation: u64) bool {
        return self.enabled and !self.stopping and self.generation == generation;
    }

    fn active(self: *Worker, generation: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.activeLocked(generation);
    }

    fn status(self: *Worker, generation: u64, value: Status) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.activeLocked(generation)) return;
        self.state.status = value;
        self.state.pending = false;
        self.outbox = null;
        if (value == .ready) {
            self.state.session +%= 1;
            self.state.confirmed = shared.movement.spawn;
        }
    }

    fn takeMove(self: *Worker, generation: u64) ?protocol.Location {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.activeLocked(generation)) return null;
        const move = self.outbox;
        self.outbox = null;
        return move;
    }

    fn finishMove(self: *Worker, generation: u64, confirmed: ?protocol.Location) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.activeLocked(generation)) return;
        if (confirmed) |pos| self.state.confirmed = pos;
        self.state.pending = false;
    }

    fn run(self: *Worker) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const io = threaded.io();
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const stopping = self.stopping;
            const generation = if (self.enabled) self.generation else null;
            self.mutex.unlock(self.io);
            if (stopping) return;
            if (generation) |current| self.runEnabled(io, current) else sleep(io);
        }
    }

    fn runEnabled(self: *Worker, io: std.Io, generation: u64) void {
        // The same key survives transport retries, but leaving this generation
        // (disable, re-enable or stop) always wipes it before the worker proceeds.
        var signer: ws_auth.Signer = .{};
        defer signer.deinit();
        var retry_ms: i64 = 250;
        while (self.active(generation)) {
            self.status(generation, .connecting);
            self.runSession(io, generation, &retry_ms, &signer) catch |err| {
                if (!self.active(generation)) return;
                std.log.debug("game connection will retry: {s}", .{@errorName(err)});
                self.status(generation, switch (err) {
                    error.WalletSigningFailed => .wallet_error,
                    error.CredentialsRejected => .credentials_rejected,
                    else => .retrying,
                });
                const until = deadline(io, retry_ms);
                while (self.active(generation) and !expired(io, until)) sleep(io);
                retry_ms = @min(retry_ms * 2, 4000);
            };
        }
    }

    fn runSession(self: *Worker, io: std.Io, generation: u64, retry_ms: *i64, signer: *ws_auth.Signer) !void {
        if (!self.active(generation)) return;
        // Load the wallet before connecting so BIP-39 work is not charged to
        // the server's challenge deadline. Reconnects reuse the loaded key.
        signer.load(io, self.paths) catch return error.WalletSigningFailed;
        if (!self.active(generation)) return;
        var client = try ws.Client.init(io, std.heap.page_allocator, .{
            .host = endpoint,
            .port = port,
            .max_size = protocol.max_gameplay_request_bytes,
            .connect_timeout_ms = 1000,
        });
        defer client.deinit();
        try client.handshake("/", .{ .timeout_ms = 1500, .headers = "Host: 127.0.0.1:9224\r\n" });
        try client.writeTimeout(1000);
        try client.readTimeout(poll_ms);
        self.status(generation, .authenticating);
        const auth_until = deadline(io, 4000);
        const challenge = try self.auth(io, generation, &client, auth_until, .challenge);
        if (!self.active(generation)) return;
        const proof = signer.sign(io, challenge.challenge) catch return error.WalletSigningFailed;
        if (expired(io, auth_until)) return error.AuthTimeout;
        var out: [protocol.max_gameplay_request_bytes]u8 = undefined;
        try send(&client, &out, try wire.encodeAuth(&out, .{ .proof = .{ .pubkey = proof.pubkey, .signature = proof.signature } }));
        const reply = (try self.auth(io, generation, &client, auth_until, .reply)).reply;
        switch (reply) {
            .ok => {},
            .failed => |failure| return switch (failure) {
                .invalid_credentials => error.CredentialsRejected,
                .unavailable => error.SessionUnavailable,
            },
        }
        retry_ms.* = 250;
        self.status(generation, .ready);

        var pending: ?struct { id: protocol.Id, destination: protocol.Location, until: std.Io.Clock.Timestamp } = null;
        while (self.active(generation)) {
            if (pending) |move| {
                if (expired(io, move.until)) return error.MoveTimeout;
            } else if (self.takeMove(generation)) |pos| {
                var id: protocol.Id = undefined;
                io.random(&id);
                const until = deadline(io, 2500);
                try send(&client, &out, try wire.encodeRequest(&out, .update_location, .{ .request_id = id, .payload = pos }));
                pending = .{ .id = id, .destination = pos, .until = until };
            }
            const msg = try client.read() orelse continue;
            defer client.done(msg);
            if (try control(&client, msg)) continue;
            const move = pending orelse return error.UnexpectedReply;
            if (expired(io, move.until)) return error.MoveTimeout;
            var scratch: protocol.Snapshot = undefined;
            const outcome = try wire.decodeReply(msg.data, .update_location, move.id, &scratch);
            self.finishMove(generation, if (outcome == .ok) move.destination else null);
            pending = null;
        }
    }

    fn auth(self: *Worker, io: std.Io, generation: u64, client: *ws.Client, until: std.Io.Clock.Timestamp, kind: protocol.AuthKind) !protocol.AuthMessage {
        while (self.active(generation) and !expired(io, until)) {
            const msg = try client.read() orelse continue;
            defer client.done(msg);
            if (expired(io, until)) return error.AuthTimeout;
            if (try control(client, msg)) continue;
            return wire.decodeAuth(msg.data, true, kind);
        }
        return error.AuthTimeout;
    }
};

// The codec returns const slices; the vendored client masks the owned buffer
// in place. Passing its mutable prefix avoids casting away constness.
fn send(client: *ws.Client, out: []u8, encoded: []const u8) !void {
    try client.writeBin(out[0..encoded.len]);
}

fn control(client: *ws.Client, msg: ws.Message) !bool {
    switch (msg.type) {
        .binary => return false,
        .ping => try client.writePong(msg.data),
        .pong => {},
        .close => {
            client.close(.{}) catch {};
            return error.Closed;
        },
        .text => return error.UnexpectedText,
    }
    return true;
}

fn deadline(io: std.Io, ms: i64) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(ms) });
}

fn expired(io: std.Io, until: std.Io.Clock.Timestamp) bool {
    return std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, until);
}

fn sleep(io: std.Io) void {
    io.sleep(.fromMilliseconds(poll_ms), .awake) catch {};
}

test "movement mailbox waits for auth and holds only one move per session" {
    const t = std.testing;
    var worker: Worker = .{ .io = t.io, .paths = undefined };
    const pos: protocol.Location = .{ .x = 1, .y = 0 };
    try t.expect(!worker.submit(0, pos));
    worker.setEnabled(true);
    worker.status(1, .authenticating);
    try t.expect(!worker.submit(0, pos));
    worker.status(1, .ready);
    try t.expect(worker.submit(1, pos));
    try t.expectEqual(pos, worker.takeMove(1).?);
    try t.expect(!worker.submit(1, pos));
    worker.finishMove(1, null);
    try t.expectEqual(shared.movement.spawn, worker.snapshot().confirmed);
    try t.expect(worker.submit(1, pos));
    worker.finishMove(1, pos);
    try t.expectEqual(pos, worker.snapshot().confirmed);
    worker.status(1, .retrying);
    try t.expect(!worker.submit(1, pos));
    worker.status(1, .ready);
    try t.expectEqual(shared.movement.spawn, worker.snapshot().confirmed);
    try t.expect(!worker.submit(1, pos));
    try t.expect(worker.submit(2, pos));
    worker.setEnabled(false);
    worker.status(1, .ready);
    try t.expectEqual(Status.disabled, worker.snapshot().status);
    try t.expect(!worker.snapshot().pending);
}
