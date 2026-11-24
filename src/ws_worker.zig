//! Desktop-only connection owner. The frame thread exchanges bounded state
//! and bounded command mailboxes with the worker; it never performs socket I/O or signing.
const std = @import("std");
const ws = @import("websocket");
const shared = @import("shared");
const wire = shared.wire;
const protocol = shared.protocol;
const wallet = @import("wallet.zig");
const ws_auth = @import("ws_auth.zig");
const OwnedCutReply = @import("paid_cut.zig").OwnedReply;

const poll_ms = 20;
const max_ws_response_bytes = @max(protocol.max_response_bytes, protocol.max_channel_status_reply_bytes, wire.max_auth_reply_bytes, wire.channel_settled_bytes, wire.max_prize_notice_bytes);
const endpoint = "127.0.0.1";
const port = 9224;
const authority = std.fmt.comptimePrint("{s}:{d}", .{ endpoint, port });
pub const endpoint_url = "ws://" ++ authority ++ "/";

const sync = @import("ws_sync.zig");
const Status = sync.Status;
const Snapshot = sync.Snapshot;
pub const HoeChannel = sync.ToolChannel;
pub const HoeLogin = sync.ToolLogin;
const Restored = sync.AuthRestore;

pub const ChannelStatusOutcome = union(enum) {
    ok: struct {
        capacity_msat: u64,
        balance_msat: u64,
        phase: protocol.ChannelPhase,
        len: usize = 0,
        bytes: [protocol.max_sender_change_proofs_bytes]u8 = undefined,
    },
    failed: protocol.ChannelStatusFailure,

    fn init(decoded: protocol.Outcome(.channel_status)) ChannelStatusOutcome {
        switch (decoded) {
            .failed => |failure| return .{ .failed = failure },
            .ok => |status| {
                var result: ChannelStatusOutcome = .{ .ok = .{
                    .capacity_msat = status.capacity_msat,
                    .balance_msat = status.balance_msat,
                    .phase = status.phase,
                } };
                if (status.sender_proofs) |bytes| {
                    result.ok.len = bytes.len;
                    @memcpy(result.ok.bytes[0..bytes.len], bytes);
                }
                return result;
            },
        }
    }

    /// The proof slice, if present, borrows only this instance's storage.
    pub fn view(self: *const ChannelStatusOutcome) protocol.Outcome(.channel_status) {
        return switch (self.*) {
            .ok => |*status| .{ .ok = .{
                .capacity_msat = status.capacity_msat,
                .balance_msat = status.balance_msat,
                .phase = status.phase,
                .sender_proofs = if (status.len == 0) null else status.bytes[0..status.len],
            } },
            .failed => |failure| .{ .failed = failure },
        };
    }
};

pub const ChannelCompletion = struct {
    request_id: protocol.Id,
    outcome: Outcome,

    pub const Outcome = union(enum) {
        channel_requirements: protocol.Outcome(.channel_requirements),
        channel_open: protocol.Outcome(.channel_open),
        channel_close: protocol.Outcome(.channel_close),
        channel_status: ChannelStatusOutcome,
    };
};

const ChannelRequest = struct {
    session: u64,
    id: protocol.Id,
    kind: protocol.Kind,
    len: usize,

    fn decode(self: ChannelRequest, bytes: []const u8, scratch: *protocol.Snapshot) !ChannelCompletion {
        const outcome: ChannelCompletion.Outcome = switch (self.kind) {
            inline .channel_requirements, .channel_open, .channel_close => |kind| @unionInit(ChannelCompletion.Outcome, @tagName(kind), try wire.decodeReply(bytes, kind, self.id, scratch)),
            .channel_status => .{ .channel_status = .init(try wire.decodeReply(bytes, .channel_status, self.id, scratch)) },
            else => unreachable,
        };
        return .{ .request_id = self.id, .outcome = outcome };
    }
};

const ChannelMailbox = union(enum) { idle, queued: ChannelRequest, waiting: ChannelRequest, received: ChannelCompletion };
const CutRequest = struct {
    session: u64,
    command: protocol.RequestFor(.cut),

    fn encode(self: CutRequest, out: []u8) ![]const u8 {
        return wire.encodeRequest(out, .cut, self.command);
    }
};
const CutMailbox = union(enum) {
    idle,
    queued: CutRequest,
    waiting: protocol.Id,
    received: struct { id: protocol.Id, reply: OwnedCutReply },
};
const Operation = union(enum) { play: sync.PlayRequest.Operation, channel: ChannelRequest, cut: CutRequest };
const PendingRequest = union(enum) { play: sync.PlayRequest, channel: ChannelRequest, cut: CutRequest };

pub const Worker = struct {
    paths: wallet.Paths,
    io: std.Io,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    stopping: bool = false,
    enabled: bool = false,
    generation: u64 = 0,
    state: Snapshot = .{},
    auth_tool_channels: sync.ToolChannels = @splat(null),
    auth_player: ?[33]u8 = null,
    outbox: ?protocol.Location = null,
    area: sync.AreaMailbox = .idle,
    channel: ChannelMailbox = .idle,
    channel_bytes: [protocol.max_request_bytes]u8 = undefined,
    cut: CutMailbox = .idle,
    settled_ids: [8][32]u8 = undefined,
    settled_count: usize = 0,
    prize_inbox: sync.PrizeInbox = .{},
    prize_ack: ?protocol.Location = null,

    pub const area_limit = protocol.max_area_chunks;

    // The frame thread owns this value at a fixed address until stop joins it.
    pub fn start(self: *Worker) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.auth_tool_channels = @splat(null);
        self.auth_player = null;
        self.channel = .idle;
        self.cut = .idle;
        self.settled_count = 0;
        self.prize_inbox.clear();
        self.prize_ack = null;
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    pub fn setEnabled(self: *Worker, enabled: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (enabled == self.enabled) return;
        self.enabled = enabled;
        self.resetConnectionLocked();
    }

    /// Invalidate a session with an ambiguous cut outcome and fetch a fresh
    /// authenticated balance. Never retry the old command.
    pub fn refreshAuth(self: *Worker, session: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.readyLocked(session)) self.resetConnectionLocked();
    }

    fn resetConnectionLocked(self: *Worker) void {
        self.generation +%= 1;
        self.state.status = if (self.enabled) .connecting else .disabled;
        self.auth_tool_channels = @splat(null);
        self.auth_player = null;
        self.state.pending = false;
        self.outbox = null;
        self.area = .idle;
        self.channel = .idle;
        self.cut = .idle;
        self.settled_count = 0;
        self.prize_inbox.clear();
        self.prize_ack = null;
    }

    pub fn snapshot(self: *Worker) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state;
    }

    /// The identity and optional channel come from the same authenticated login.
    pub fn hoeLogin(self: *Worker, session: u64) ?HoeLogin {
        return self.toolLogin(session, .hoe);
    }

    pub fn hoeChannel(self: *Worker, session: u64) ?HoeChannel {
        return self.toolChannel(session, .hoe);
    }

    pub fn toolLogin(self: *Worker, session: u64, tool: protocol.tool) ?HoeLogin {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.readyLocked(session)) return null;
        return .{ .player = self.auth_player orelse return null, .channel = self.auth_tool_channels[@backingInt(tool)] };
    }

    /// Channel from login with any acknowledged payments applied. Scoped to this session.
    pub fn toolChannel(self: *Worker, session: u64, tool: protocol.tool) ?HoeChannel {
        return (self.toolLogin(session, tool) orelse return null).channel;
    }

    pub fn submit(self: *Worker, session: u64, destination: protocol.Location) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state.status != .ready or self.state.session != session or self.state.pending) return false;
        self.outbox = destination;
        self.state.pending = true;
        return true;
    }

    pub fn requestArea(self: *Worker, session: u64, range: shared.world.ChunkRange) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state.status != .ready or self.state.session != session) return false;
        return self.area.request(range);
    }

    pub fn takeArea(self: *Worker, session: u64, dest: *protocol.Snapshot) ?sync.AreaCompletion {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state.status != .ready or self.state.session != session) return null;
        return self.area.take(dest);
    }

    /// Queues a caller-assigned request ID. False means the session isn't ready
    /// or the channel slot is occupied; encoding errors leave the slot idle.
    /// All payload bytes are copied before returning. Requests are never replayed.
    pub fn submitChannel(self: *Worker, session: u64, comptime kind: protocol.Kind, request: protocol.RequestFor(kind)) !bool {
        comptime if (!protocol.isChannel(kind)) @compileError("expected a channel command");
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.readyLocked(session) or self.channel != .idle) return false;
        const bytes = try wire.encodeRequest(&self.channel_bytes, kind, request);
        self.channel = .{ .queued = .{ .session = session, .id = request.request_id, .kind = kind, .len = bytes.len } };
        return true;
    }

    /// Consumes only the matching reply, leaving other coordinators' replies untouched.
    /// A lost session discards the slot without implying server rejection.
    pub fn takeChannelFor(self: *Worker, session: u64, id: protocol.Id) ?ChannelCompletion {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.readyLocked(session) or self.channel != .received or
            !std.meta.eql(self.channel.received.request_id, id)) return null;
        const completion = self.channel.received;
        self.channel = .idle;
        return completion;
    }

    /// Consumes one settlement hint for this session. Query channel_status for
    /// authoritative state: notices may be missed on overflow or disconnect.
    pub fn takeChannelSettled(self: *Worker, session: u64) ?[32]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.readyLocked(session) or self.settled_count == 0) return null;
        const id = self.settled_ids[0];
        self.settled_count -= 1;
        std.mem.copyForwards([32]u8, self.settled_ids[0..self.settled_count], self.settled_ids[1 .. self.settled_count + 1]);
        return id;
    }

    fn recordChannelSettled(self: *Worker, generation: u64, id: [32]u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.activeLocked(generation) or self.state.status != .ready or self.settled_count == self.settled_ids.len) return;
        self.settled_ids[self.settled_count] = id;
        self.settled_count += 1;
    }

    /// Queues one already-signed cut by value. False means it was not queued:
    /// the payment is missing, the session isn't ready, or the cut slot is occupied.
    pub fn submitCut(self: *Worker, session: u64, command: protocol.RequestFor(.cut)) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (command.payload.payment == null or !self.readyLocked(session) or self.cut != .idle) return false;
        self.cut = .{ .queued = .{ .session = session, .command = command } };
        return true;
    }

    /// Consumes only the matching reply. A lost session drops the slot without
    /// replaying the cut; a missing reply is not proof that it wasn't charged.
    pub fn takeCut(self: *Worker, session: u64, request_id: protocol.Id) ?OwnedCutReply {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.readyLocked(session) or self.cut != .received) return null;
        const result = self.cut.received;
        if (!std.mem.eql(u8, &result.id, &request_id)) return null;
        self.cut = .idle;
        return result.reply;
    }

    pub fn takePrizeNotice(self: *Worker, session: u64) ?@import("wallet_ui.zig").PrizeNotice {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.readyLocked(session)) return null;
        return self.prize_inbox.take();
    }

    pub fn takeDeferredPrizes(self: *Worker, session: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.readyLocked(session) and self.prize_inbox.takeDeferred();
    }

    pub fn ackPrize(self: *Worker, session: u64, player: [33]u8, tile: protocol.Location) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.readyLocked(session) or self.prize_ack != null or
            !std.meta.eql(self.auth_player, @as(?[33]u8, player))) return false;
        self.prize_ack = tile;
        return true;
    }

    fn takePrizeAck(self: *Worker, generation: u64) ?protocol.Location {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.activeLocked(generation) or self.state.status != .ready) return null;
        const tile = self.prize_ack;
        self.prize_ack = null;
        return tile;
    }

    fn readyLocked(self: *const Worker, session: u64) bool {
        return !self.stopping and self.state.status == .ready and self.state.session == session;
    }

    fn takeOperation(self: *Worker, generation: u64, out: *[protocol.max_request_bytes]u8) ?Operation {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.activeLocked(generation)) return null;
        if (self.outbox) |move| {
            self.outbox = null;
            return .{ .play = .{ .move = move } };
        }
        if (self.channel == .queued) {
            const request = self.channel.queued;
            @memcpy(out[0..request.len], self.channel_bytes[0..request.len]);
            self.channel = .{ .waiting = request };
            return .{ .channel = request };
        }
        if (self.cut == .queued) {
            const request = self.cut.queued;
            self.cut = .{ .waiting = request.command.request_id };
            return .{ .cut = request };
        }
        const range = self.area.start() orelse return null;
        return .{ .play = .{ .area = range } };
    }

    fn finishChannel(self: *Worker, generation: u64, request: ChannelRequest, completion: ChannelCompletion) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.activeLocked(generation) or !self.readyLocked(request.session)) return;
        if (self.channel != .waiting or !std.meta.eql(self.channel.waiting, request)) return;
        self.channel = .{ .received = completion };
    }

    fn finishCut(self: *Worker, generation: u64, request: CutRequest, bytes: []const u8, scratch: *protocol.Snapshot) !void {
        const id = request.command.request_id;
        const outcome = try wire.decodeReply(bytes, .cut, id, scratch);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.activeLocked(generation) or !self.readyLocked(request.session)) return;
        if (self.cut != .waiting or !std.mem.eql(u8, &self.cut.waiting, &id)) return;
        sync.applyCutBalance(&self.auth_tool_channels, request.command.payload, outcome);
        self.cut = .{ .received = .{ .id = id, .reply = .init(outcome) } };
    }

    fn finishArea(self: *Worker, generation: u64, result: sync.AreaCompletion, reply: *const protocol.Snapshot) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.activeLocked(generation)) self.area.complete(result, reply);
    }

    fn activeLocked(self: *const Worker, generation: u64) bool {
        return self.enabled and !self.stopping and self.generation == generation;
    }

    fn active(self: *Worker, generation: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.activeLocked(generation);
    }

    fn status(self: *Worker, generation: u64, value: Status, restored: ?Restored) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.activeLocked(generation)) return;
        self.state.status = value;
        self.state.pending = false;
        self.outbox = null;
        self.area = .idle;
        self.channel = .idle;
        self.cut = .idle;
        self.settled_count = 0;
        self.prize_inbox.clear();
        self.prize_ack = null;
        self.auth_tool_channels = if (restored) |success| success.channels else @splat(null);
        self.auth_player = if (restored) |success| success.player else null;
        if (restored) |success| {
            self.state.session +%= 1;
            self.state.confirmed = success.location;
        }
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
            self.status(generation, .connecting, null);
            self.runSession(io, generation, &retry_ms, &signer) catch |err| {
                if (!self.active(generation)) return;
                std.log.debug("game connection will retry: {s}", .{@errorName(err)});
                self.status(generation, switch (err) {
                    error.WalletSigningFailed => .wallet_error,
                    error.CredentialsRejected => .credentials_rejected,
                    else => .retrying,
                }, null);
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
            .max_size = max_ws_response_bytes,
            .connect_timeout_ms = 1000,
        });
        defer client.deinit();
        try client.handshake("/", .{ .timeout_ms = 1500, .headers = "Host: " ++ authority ++ "\r\n" });
        try client.writeTimeout(1000);
        try client.readTimeout(poll_ms);
        self.status(generation, .authenticating, null);
        const auth_until = deadline(io, 4000);
        const challenge = try self.auth(io, generation, &client, auth_until, .challenge);
        if (!self.active(generation)) return;
        const proof = signer.sign(io, challenge.challenge) catch return error.WalletSigningFailed;
        if (expired(io, auth_until)) return error.AuthTimeout;
        var out: [protocol.max_request_bytes]u8 = undefined;
        try send(&client, &out, try wire.encodeAuth(&out, .{ .proof = .{ .pubkey = proof.pubkey, .signature = proof.signature } }));
        const reply = (try self.auth(io, generation, &client, auth_until, .reply)).reply;
        const restored = Restored.fromReply(reply, proof.pubkey) orelse return switch (reply.failed) {
            .invalid_credentials => error.CredentialsRejected,
            .unavailable => error.SessionUnavailable,
        };
        retry_ms.* = 250;
        self.status(generation, .ready, restored);

        var pending: ?struct { request: PendingRequest, until: std.Io.Clock.Timestamp } = null;
        while (self.active(generation)) {
            if (self.takePrizeAck(generation)) |tile| {
                var frame: [wire.prize_ack_bytes]u8 = undefined;
                try send(&client, &frame, try wire.encodePrizeAck(&frame, tile));
            }
            if (pending) |active_request| {
                if (expired(io, active_request.until)) return error.RequestTimeout;
            } else if (self.takeOperation(generation, &out)) |operation| {
                const until = deadline(io, if (operation == .channel) 5000 else 2500);
                const request: PendingRequest = switch (operation) {
                    .play => |play| blk: {
                        var request: sync.PlayRequest = .{ .id = undefined, .operation = play };
                        io.random(&request.id);
                        try send(&client, &out, try request.encode(&out));
                        break :blk .{ .play = request };
                    },
                    .channel => |channel| blk: {
                        try client.writeBin(out[0..channel.len]);
                        break :blk .{ .channel = channel };
                    },
                    .cut => |cut| blk: {
                        try send(&client, &out, try cut.encode(&out));
                        break :blk .{ .cut = cut };
                    },
                };
                pending = .{ .request = request, .until = until };
            }
            const msg = try client.read() orelse continue;
            defer client.done(msg);
            if (try control(&client, msg)) continue;
            if (pending) |active_request| {
                if (expired(io, active_request.until)) return error.RequestTimeout;
            }
            if (try self.receivePlay(generation, if (pending) |p| p.request else null, msg.data)) pending = null;
        }
    }

    // Returns true only when the pending request was answered.
    fn receivePlay(self: *Worker, generation: u64, pending: ?PendingRequest, bytes: []const u8) !bool {
        if (wire.decodePrizeNotice(bytes, true)) |notice| {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.activeLocked(generation) and self.state.status == .ready and self.auth_player != null)
                try self.prize_inbox.push(notice.tile, notice.token);
            return false;
        } else |_| {}
        if (wire.decodeChannelSettled(bytes, true)) |id| {
            self.recordChannelSettled(generation, id);
            return false;
        } else |_| {}

        var scratch: protocol.Snapshot = undefined;
        switch (pending orelse return error.UnexpectedReply) {
            .play => |play| switch (try play.decode(bytes, &scratch)) {
                .move => |pos| self.finishMove(generation, pos),
                .area => |result| self.finishArea(generation, result, &scratch),
            },
            .channel => |channel| self.finishChannel(generation, channel, try channel.decode(bytes, &scratch)),
            .cut => |cut| try self.finishCut(generation, cut, bytes, &scratch),
        }
        return true;
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

test "area mailbox rejects stale sessions and serializes with moves" {
    const t = std.testing;
    var worker: Worker = .{ .io = t.io, .paths = undefined };
    var out: [protocol.max_request_bytes]u8 = undefined;
    const area: shared.world.ChunkRange = .{ .cx0 = -4, .cy0 = 2, .cx1 = -4, .cy1 = 2 };
    const pos = shared.movement.spawn;
    worker.setEnabled(true);
    try t.expect(!worker.requestArea(0, area));
    worker.status(1, .ready, .{ .location = pos });
    try t.expect(worker.requestArea(1, area));
    try t.expect(!worker.requestArea(1, area));
    try t.expect(worker.submit(1, pos));
    try t.expectEqual(pos, worker.takeOperation(1, &out).?.play.move);
    worker.finishMove(1, pos);
    try t.expectEqual(area, worker.takeOperation(1, &out).?.play.area);
    var dest: protocol.Snapshot = undefined;
    worker.finishArea(1, .server_busy, &dest);
    try t.expect(!worker.requestArea(1, area));
    try t.expectEqual(sync.AreaCompletion.server_busy, worker.takeArea(1, &dest).?);
    try t.expect(worker.requestArea(1, area));
    try t.expectEqual(area, worker.takeOperation(1, &out).?.play.area);
    const reply: protocol.Snapshot = .{ .area = area, .count = 1 };
    worker.finishArea(1, .snapshot, &reply);
    try t.expect(worker.takeArea(0, &dest) == null);
    try t.expectEqual(sync.AreaCompletion.snapshot, worker.takeArea(1, &dest).?);
    try t.expectEqualDeep(reply, dest);
    try t.expect(worker.requestArea(1, area));
    worker.status(1, .retrying, null);
    worker.status(1, .ready, .{ .location = pos });
    try t.expect(worker.takeOperation(1, &out) == null);
    try t.expect(!worker.requestArea(1, area));
    try t.expect(worker.requestArea(2, area));
}

test "movement mailbox waits for auth and holds only one move per session" {
    const t = std.testing;
    var worker: Worker = .{ .io = t.io, .paths = undefined };
    var out: [protocol.max_request_bytes]u8 = undefined;
    const pos: protocol.Location = .{ .x = 1, .y = 0 };
    try t.expect(!worker.submit(0, pos));
    worker.setEnabled(true);
    worker.status(1, .authenticating, null);
    try t.expect(!worker.submit(0, pos));
    const restored: protocol.Location = .{ .x = -38, .y = 211 };
    const channel: HoeChannel = .{ .id = @splat(0x42), .capacity_msats = 100, .balance_msats = 15, .player = @splat(7) };
    worker.status(1, .ready, .{ .location = restored, .channels = .{ null, channel, null }, .player = channel.player });
    try t.expectEqual(channel, worker.hoeChannel(worker.snapshot().session).?);
    try t.expect(worker.hoeChannel(0) == null);
    try t.expect(worker.submit(1, pos));
    try t.expectEqual(pos, worker.takeOperation(1, &out).?.play.move);
    try t.expect(!worker.submit(1, pos));
    worker.finishMove(1, null);
    try t.expectEqual(restored, worker.snapshot().confirmed);
    try t.expect(worker.submit(1, pos));
    worker.finishMove(1, pos);
    try t.expectEqual(pos, worker.snapshot().confirmed);
    worker.status(1, .retrying, null);
    try t.expect(!worker.submit(1, pos));
    try t.expect(worker.hoeChannel(1) == null);
    worker.status(1, .ready, .{ .location = restored });
    try t.expect(worker.hoeChannel(2) == null);
    try t.expectEqual(restored, worker.snapshot().confirmed);
    try t.expect(!worker.submit(1, pos));
    try t.expect(worker.submit(2, pos));
    worker.setEnabled(false);
    worker.status(1, .ready, .{ .location = restored, .channels = .{ null, channel, null }, .player = channel.player });
    try t.expect(worker.hoeChannel(2) == null);
    try t.expectEqual(Status.disabled, worker.snapshot().status);
    try t.expect(!worker.snapshot().pending);
}

test "plain authenticated login exposes the player without a channel" {
    const t = std.testing;
    var worker: Worker = .{ .io = t.io, .paths = undefined };
    const player: [33]u8 = @splat(2);
    worker.setEnabled(true);
    worker.status(1, .ready, .{ .location = shared.movement.spawn, .player = player });
    try t.expectEqual(player, worker.hoeLogin(1).?.player);
    try t.expect(worker.hoeLogin(1).?.channel == null);
    try t.expect(worker.hoeLogin(0) == null);
    worker.refreshAuth(1);
    try t.expect(worker.hoeLogin(1) == null);
}

test "prize ACK mailbox rejects stale sessions and clears across logins" {
    const t = std.testing;
    var worker: Worker = .{ .io = t.io, .paths = undefined };
    const player: [33]u8 = @splat(2);
    const other: [33]u8 = @splat(3);
    const tile: protocol.Location = .{ .x = -2, .y = 4 };
    worker.setEnabled(true);
    worker.status(1, .ready, .{ .location = shared.movement.spawn, .player = player });
    try t.expect(!worker.ackPrize(0, player, tile));
    try t.expect(!worker.ackPrize(1, other, tile));
    try t.expect(worker.ackPrize(1, player, tile));
    try t.expect(!worker.ackPrize(1, player, tile));
    try t.expectEqual(tile, worker.takePrizeAck(1).?);
    try t.expect(worker.ackPrize(1, player, tile));
    worker.status(1, .retrying, null);
    worker.status(1, .ready, .{ .location = shared.movement.spawn, .player = other });
    try t.expect(worker.takePrizeAck(1) == null);
    try t.expect(!worker.ackPrize(2, player, tile));
}

test "channel open queues owned bytes without changing movement or area mailboxes" {
    const t = std.testing;
    var worker: Worker = .{ .io = t.io, .paths = undefined };
    var out: [protocol.max_request_bytes]u8 = undefined;
    const pos = shared.movement.spawn;
    const area: shared.world.ChunkRange = .{ .cx0 = 0, .cy0 = 0, .cx1 = 0, .cy1 = 0 };
    const expected_proof: [protocol.max_channel_proof_bytes]u8 = @splat(0x41);
    var proof = expected_proof;
    const expected_params: [protocol.max_channel_params_bytes]u8 = @splat(0x42);
    var params = expected_params;
    const open: protocol.RequestFor(.channel_open) = .{
        .request_id = @splat(1),
        .payload = .{ .id = @splat(2), .proof = &proof, .params = &params, .tool = .pickaxe },
    };

    worker.setEnabled(true);
    try t.expect(!try worker.submitChannel(0, .channel_open, open));
    worker.status(1, .ready, .{ .location = pos });
    try t.expect(!try worker.submitChannel(0, .channel_open, open));
    try t.expect(try worker.submitChannel(1, .channel_open, open));
    @memset(&proof, 0);
    @memset(&params, 0);
    try t.expect(!try worker.submitChannel(1, .channel_open, open));
    try t.expect(worker.takeChannelFor(1, open.request_id) == null);
    try t.expect(worker.requestArea(1, area));
    try t.expect(worker.submit(1, pos));
    try t.expectEqual(pos, worker.takeOperation(1, &out).?.play.move);
    worker.finishMove(1, pos);

    const request = worker.takeOperation(1, &out).?.channel;
    try t.expect(!try worker.submitChannel(1, .channel_open, open));
    const decoded = try wire.decodeMessage(out[0..request.len], true);
    try t.expectEqual(open.request_id, decoded.request_id);
    try t.expectEqual(open.payload.id, decoded.operation.channel_open.id);
    try t.expectEqual(open.payload.tool, decoded.operation.channel_open.tool);
    try t.expectEqual(protocol.max_channel_open_with_params_bytes, request.len);
    try t.expectEqualSlices(u8, &expected_proof, decoded.operation.channel_open.proof);
    try t.expectEqualSlices(u8, &expected_params, decoded.operation.channel_open.params);

    const reply = try wire.encodeReply(&out, .channel_open, open, .{ .failed = .invalid_proof });
    var scratch: protocol.Snapshot = undefined;
    worker.finishChannel(1, request, try request.decode(reply, &scratch));
    try t.expect(!try worker.submitChannel(1, .channel_open, open));
    try t.expect(worker.takeChannelFor(0, open.request_id) == null);
    const completion = worker.takeChannelFor(1, open.request_id).?;
    try t.expectEqual(open.request_id, completion.request_id);
    try t.expectEqual(protocol.ChannelOpenFailure.invalid_proof, completion.outcome.channel_open.failed);
    try t.expect(worker.takeChannelFor(1, open.request_id) == null);
    try t.expectEqual(area, worker.takeOperation(1, &out).?.play.area);
}

test "channel commands check bounds, reply kind and ID, and discard stale sessions" {
    const t = std.testing;
    var worker: Worker = .{ .io = t.io, .paths = undefined };
    var out: [protocol.max_request_bytes]u8 = undefined;
    var scratch: protocol.Snapshot = undefined;
    const pos = shared.movement.spawn;
    worker.setEnabled(true);
    worker.status(1, .ready, .{ .location = pos });

    const id: protocol.Id = @splat(1);
    const channel_id: [32]u8 = @splat(2);
    const too_large: [protocol.max_request_bytes]u8 = @splat(3);
    try t.expectError(error.InvalidProofLength, worker.submitChannel(1, .channel_open, .{
        .request_id = id,
        .payload = .{ .id = channel_id, .proof = &too_large, .params = "params" },
    }));
    try t.expectError(error.InvalidParamsLength, worker.submitChannel(1, .channel_open, .{
        .request_id = id,
        .payload = .{ .id = channel_id, .proof = "proof", .params = &too_large },
    }));
    const requirements: protocol.RequestFor(.channel_requirements) = .{ .request_id = id, .payload = .{ .tool = .hoe } };
    try t.expect(try worker.submitChannel(1, .channel_requirements, requirements));
    const request = worker.takeOperation(1, &out).?.channel;
    try t.expectEqualDeep(requirements.payload, (try wire.decodeMessage(out[0..request.len], true)).operation.channel_requirements);

    const terms: protocol.SpillmanChannelRequirementsRes = .{ .pubkey = @splat(3), .amount = 42, .refundTime = 1000 };
    const wrong_id = try wire.encodeReply(&out, .channel_requirements, .{ .request_id = @splat(0), .payload = requirements.payload }, .{ .ok = terms });
    try t.expectError(error.UnexpectedRequestId, request.decode(wrong_id, &scratch));
    const close: protocol.RequestFor(.channel_close) = .{ .request_id = id, .payload = .{ .id = channel_id } };
    const wrong_kind = try wire.encodeReply(&out, .channel_close, close, .{ .ok = {} });
    try t.expectError(error.UnexpectedMessageType, request.decode(wrong_kind, &scratch));
    try t.expect(worker.takeChannelFor(1, id) == null);
    const reply = try wire.encodeReply(&out, .channel_requirements, requirements, .{ .ok = terms });
    const completion = try request.decode(reply, &scratch);
    try t.expectEqualDeep(terms, completion.outcome.channel_requirements.ok);

    // A transport retry stays in the same enable generation but starts a new session.
    worker.status(1, .retrying, null);
    worker.status(1, .ready, .{ .location = pos });
    try t.expect(worker.takeOperation(1, &out) == null);
    try t.expect(!try worker.submitChannel(1, .channel_close, close));
    try t.expect(try worker.submitChannel(2, .channel_requirements, requirements));
    const new_request = worker.takeOperation(1, &out).?.channel;
    worker.finishChannel(1, request, completion);
    try t.expect(worker.takeChannelFor(2, id) == null);
    worker.finishChannel(1, new_request, completion);
    try t.expectEqualDeep(completion, worker.takeChannelFor(2, id).?);

    for ([_]protocol.Outcome(.channel_close){ .{ .ok = {} }, .{ .failed = .settlement_pending } }) |outcome| {
        try t.expect(try worker.submitChannel(2, .channel_close, close));
        const pending = worker.takeOperation(1, &out).?.channel;
        const decoded = try wire.decodeMessage(out[0..pending.len], true);
        try t.expectEqualDeep(close.payload, decoded.operation.channel_close);
        const bytes = try wire.encodeReply(&out, .channel_close, close, outcome);
        worker.finishChannel(1, pending, try pending.decode(bytes, &scratch));
        try t.expectEqualDeep(outcome, worker.takeChannelFor(2, id).?.outcome.channel_close);
    }

    try t.expect(try worker.submitChannel(2, .channel_close, close));
    worker.setEnabled(false);
    worker.setEnabled(true);
    worker.status(3, .ready, .{ .location = pos });
    try t.expect(worker.takeOperation(3, &out) == null);
    try t.expect(worker.takeChannelFor(2, id) == null);
    worker.stop();
    try t.expect(!try worker.submitChannel(3, .channel_close, close));
}

test "settlement notices leave status pending and status proofs survive frame reuse and copying" {
    const t = std.testing;
    var worker: Worker = .{ .io = t.io, .paths = undefined };
    var out: [protocol.max_request_bytes]u8 = undefined;
    var frame: [max_ws_response_bytes]u8 = undefined;
    const command: protocol.RequestFor(.channel_status) = .{ .request_id = @splat(1), .payload = .{ .id = @splat(2) } };
    const idle_id: [32]u8 = @splat(3);
    const proofs: [protocol.max_sender_change_proofs_bytes]u8 = @splat('p');
    const status: protocol.Outcome(.channel_status) = .{ .ok = .{
        .capacity_msat = 100,
        .balance_msat = 50,
        .phase = .settled,
        .sender_proofs = &proofs,
    } };

    worker.setEnabled(true);
    worker.status(1, .ready, .{ .location = shared.movement.spawn });
    try t.expect(!try worker.receivePlay(1, null, try wire.encodeChannelSettled(&frame, idle_id)));
    try t.expect(try worker.submitChannel(1, .channel_status, command));
    const pending: PendingRequest = .{ .channel = worker.takeOperation(1, &out).?.channel };
    const notice = try wire.encodeChannelSettled(&frame, command.payload.id);
    try t.expect(!try worker.receivePlay(1, pending, notice));
    try t.expect(worker.takeChannelFor(1, command.request_id) == null);
    try t.expect(worker.takeChannelSettled(0) == null);
    try t.expectEqual(idle_id, worker.takeChannelSettled(1).?);
    try t.expectEqual(command.payload.id, worker.takeChannelSettled(1).?);
    try t.expect(worker.takeChannelSettled(1) == null);

    const reply = try wire.encodeReply(&frame, .channel_status, command, status);
    try t.expectEqual(protocol.max_channel_status_reply_bytes, reply.len);
    try t.expect(try worker.receivePlay(1, pending, reply));
    @memset(frame[0..reply.len], 0);
    try t.expect(worker.takeChannelFor(1, @splat(9)) == null);
    try t.expect(worker.takeChannelFor(0, command.request_id) == null);
    var completion = worker.takeChannelFor(1, command.request_id).?;
    const copy = completion;
    completion.outcome.channel_status.ok.bytes[0] = 'x';
    try t.expectEqual(@as(u8, 'x'), completion.outcome.channel_status.view().ok.sender_proofs.?[0]);
    try t.expectEqualDeep(status, copy.outcome.channel_status.view());

    try t.expect(try worker.submitChannel(1, .channel_status, command));
    const next: PendingRequest = .{ .channel = worker.takeOperation(1, &out).?.channel };
    const failure: protocol.Outcome(.channel_status) = .{ .failed = .not_found };
    try t.expect(try worker.receivePlay(1, next, try wire.encodeReply(&frame, .channel_status, command, failure)));
    const failed = worker.takeChannelFor(1, command.request_id).?;
    try t.expectEqualDeep(failure, failed.outcome.channel_status.view());

    try t.expect(!try worker.receivePlay(1, null, try wire.encodeChannelSettled(&frame, idle_id)));
    worker.status(1, .retrying, null);
    worker.status(1, .ready, .{ .location = shared.movement.spawn });
    try t.expect(worker.takeChannelSettled(1) == null);
    try t.expect(worker.takeChannelSettled(2) == null);
}

const test_cut: protocol.RequestFor(.cut) = .{
    .request_id = @splat(1),
    .payload = .{ .x = -4, .y = 5, .payment = .{ .id = @splat(2), .amount = 5, .signature = @splat(3) } },
};

test "signed cut queues alongside play and channel and yields only a matched reply" {
    const t = std.testing;
    var worker: Worker = .{ .io = t.io, .paths = undefined };
    var out: [protocol.max_request_bytes]u8 = undefined;
    var scratch: protocol.Snapshot = undefined;
    const pos = shared.movement.spawn;
    const area: shared.world.ChunkRange = .{ .cx0 = 0, .cy0 = 0, .cx1 = 0, .cy1 = 0 };
    const close: protocol.RequestFor(.channel_close) = .{ .request_id = test_cut.request_id, .payload = .{ .id = @splat(2) } };

    worker.setEnabled(true);
    try t.expect(!worker.submitCut(0, test_cut));
    worker.status(1, .ready, .{ .location = pos });
    try t.expect(!worker.submitCut(0, test_cut));
    var command = test_cut;
    command.payload.payment = null;
    try t.expect(!worker.submitCut(1, command));
    command = test_cut;
    try t.expect(worker.submitCut(1, command));
    command.payload.payment.?.signature = @splat(0);
    try t.expect(!worker.submitCut(1, command));
    try t.expect(worker.takeCut(1, command.request_id) == null);

    try t.expect(worker.requestArea(1, area));
    try t.expect(worker.submit(1, pos));
    try t.expect(try worker.submitChannel(1, .channel_close, close));
    try t.expectEqual(pos, worker.takeOperation(1, &out).?.play.move);
    worker.finishMove(1, pos);
    const channel = worker.takeOperation(1, &out).?.channel;
    const close_reply = try wire.encodeReply(&out, .channel_close, close, .{ .ok = {} });
    worker.finishChannel(1, channel, try channel.decode(close_reply, &scratch));

    const cut = worker.takeOperation(1, &out).?.cut;
    try t.expect(!worker.submitCut(1, test_cut));
    const decoded = try wire.decodeMessage(try cut.encode(&out), true);
    try t.expectEqual(test_cut.request_id, decoded.request_id);
    try t.expectEqualDeep(test_cut.payload, decoded.operation.cut);

    const wrong_kind = try wire.encodeReply(&out, .channel_close, close, .{ .ok = {} });
    try t.expectError(error.UnexpectedMessageType, worker.finishCut(1, cut, wrong_kind, &scratch));
    command.request_id = @splat(0);
    const wrong_id = try wire.encodeReply(&out, .cut, command, .{ .failed = .not_cuttable });
    try t.expectError(error.UnexpectedRequestId, worker.finishCut(1, cut, wrong_id, &scratch));
    try t.expect(worker.takeCut(1, test_cut.request_id) == null);

    const tile: protocol.State = .{ .x = test_cut.payload.x, .y = test_cut.payload.y, .terrain = .grass, .cut = true };
    var response: [protocol.max_response_bytes]u8 = undefined;
    var with_prize = tile;
    with_prize.prize_token = "cashuBtest";
    const reply = try wire.encodeReply(&response, .cut, test_cut, .{ .ok = with_prize });
    try worker.finishCut(1, cut, reply, &scratch);
    @memset(&response, 0);
    try t.expect(!worker.submitCut(1, test_cut));
    try t.expect(worker.takeCut(0, test_cut.request_id) == null);
    try t.expect(worker.takeCut(1, command.request_id) == null);
    const owned = worker.takeCut(1, test_cut.request_id).?;
    try t.expectEqualDeep(tile, owned.outcome.ok);
    try t.expectEqualStrings("cashuBtest", owned.prize.slice());
    try t.expect(worker.takeCut(1, test_cut.request_id) == null);
    const completion = worker.takeChannelFor(1, close.request_id).?;
    try t.expect(completion.outcome.channel_close == .ok);
    try t.expectEqual(area, worker.takeOperation(1, &out).?.play.area);
}

test "acknowledged cut advances only the matching tool balance before rebinding" {
    const t = std.testing;
    const player: [33]u8 = @splat(3);
    const hoe: HoeChannel = .{ .id = @splat(2), .capacity_msats = 15, .balance_msats = 5, .player = player };
    const axe: HoeChannel = .{ .id = @splat(4), .capacity_msats = 4, .balance_msats = 0, .player = player };
    var worker: Worker = .{ .io = t.io, .paths = undefined };
    worker.setEnabled(true);
    worker.status(1, .ready, .{ .location = shared.movement.spawn, .player = player, .channels = .{ axe, hoe, null } });

    var command = test_cut;
    command.payload.payment.?.amount = 10;
    const tile: protocol.State = .{ .x = command.payload.x, .y = command.payload.y, .terrain = .grass, .cut = true };
    var out: [protocol.max_request_bytes]u8 = undefined;
    var scratch: protocol.Snapshot = undefined;
    for ([_]protocol.Outcome(.cut){ .{ .failed = .{ .already_cut = tile } }, .{ .ok = tile } }, 0..) |outcome, i| {
        command.request_id[0] = @intCast(i);
        try t.expect(worker.submitCut(1, command));
        const request = worker.takeOperation(1, &out).?.cut;
        const reply = try wire.encodeReply(&out, .cut, command, outcome);
        try worker.finishCut(1, request, reply, &scratch);
        try t.expectEqualDeep(outcome, worker.takeCut(1, command.request_id).?.outcome);
        try t.expectEqual(if (i == 0) @as(u64, 5) else 10, worker.toolLogin(1, .hoe).?.channel.?.balance_msats);
        try t.expectEqual(axe, worker.toolChannel(1, .axe).?);
        try t.expect(worker.toolChannel(1, .pickaxe) == null);
    }
}

test "signed cut is not replayed and stale completions cannot replace the current result" {
    const t = std.testing;
    var worker: Worker = .{ .io = t.io, .paths = undefined };
    var out: [protocol.max_request_bytes]u8 = undefined;
    var scratch: protocol.Snapshot = undefined;
    const pos = shared.movement.spawn;
    const id = test_cut.request_id;
    worker.setEnabled(true);
    worker.status(1, .ready, .{ .location = pos });
    try t.expect(worker.submitCut(1, test_cut));
    const stale = worker.takeOperation(1, &out).?.cut;

    worker.status(1, .retrying, null);
    worker.status(1, .ready, .{ .location = pos });
    try t.expect(worker.takeOperation(1, &out) == null);
    try t.expect(!worker.submitCut(1, test_cut));
    try t.expect(worker.submitCut(2, test_cut));
    const current = worker.takeOperation(1, &out).?.cut;
    const outcome: protocol.Outcome(.cut) = .{ .failed = .not_cuttable };
    const reply = try wire.encodeReply(&out, .cut, test_cut, outcome);
    try worker.finishCut(1, stale, reply, &scratch);
    try worker.finishCut(0, current, reply, &scratch);
    try t.expect(worker.takeCut(2, id) == null);
    try worker.finishCut(1, current, reply, &scratch);
    try t.expectEqualDeep(outcome, worker.takeCut(2, id).?.outcome);

    try t.expect(worker.submitCut(2, test_cut));
    worker.refreshAuth(1);
    try t.expectEqual(Status.ready, worker.snapshot().status);
    worker.refreshAuth(2);
    try t.expectEqual(Status.connecting, worker.snapshot().status);
    try t.expect(worker.hoeChannel(2) == null);
    try t.expect(!worker.submitCut(2, test_cut));
    worker.status(2, .ready, .{ .location = pos });
    try t.expect(worker.takeOperation(2, &out) == null);
    try t.expect(worker.submitCut(3, test_cut));
    const last = worker.takeOperation(2, &out).?.cut;
    try worker.finishCut(2, last, reply, &scratch);
    worker.stop();
    try t.expect(worker.takeCut(3, id) == null);
    try t.expect(!worker.submitCut(3, test_cut));
}

test "login restores each tool independently and invalidates every slot on reconnect" {
    const t = std.testing;
    var worker: Worker = .{ .io = t.io, .paths = undefined };
    const player: [33]u8 = @splat(2);
    const axe: protocol.ToolChannel = .{ .id = @splat(3), .capacity_msat = 20, .balance_msat = 2 };
    const pickaxe: protocol.ToolChannel = .{ .id = @splat(4), .capacity_msat = 100, .balance_msat = 50 };
    const ack: protocol.AuthOutcome = .{ .ok_with_tool_channels = .{ .location = shared.movement.spawn, .channels = .{ axe, null, pickaxe } } };
    worker.setEnabled(true);
    worker.status(1, .ready, Restored.fromReply(ack, player));
    try t.expectEqual(axe.id, worker.toolChannel(1, .axe).?.id);
    try t.expectEqual(pickaxe.balance_msat, worker.toolChannel(1, .pickaxe).?.balance_msats);
    try t.expectEqual(player, worker.toolLogin(1, .pickaxe).?.player);
    try t.expect(worker.hoeChannel(1) == null);
    worker.refreshAuth(1);
    for (protocol.tools) |tool| try t.expect(worker.toolLogin(1, tool) == null);
}
