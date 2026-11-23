//! Nonblocking browser connection state. JS owns the socket and opaque
//! wallet signer; only committed locations enter this protocol state machine.
const std = @import("std");
const shared = @import("shared");
const protocol = shared.protocol;
const wire = shared.wire;
const sync = @import("ws_sync.zig");

const Callback = *const fn (u32, c_int, [*c]const u8, u32) callconv(.c) void;
extern "c" fn haystack_ws_prepare(token: u32, wallet_generation: u32, callback: Callback) void;
extern "c" fn haystack_ws_open(token: u32, callback: Callback) void;
extern "c" fn haystack_ws_close(token: u32) void;
extern "c" fn haystack_ws_clear_signer() void;
extern "c" fn haystack_ws_send(token: u32, ptr: [*]const u8, len: u32) c_int;
extern "c" fn haystack_ws_sign(token: u32, nonce: *const [32]u8) void;
extern "c" fn haystack_ws_now() f64;

const Stage = enum { idle, preparing, opening, challenge, signing, auth_reply, play };
const Event = enum(c_int) { prepared = 1, opened, message, closed, proof, wallet_error };
var owner: ?*Worker = null;
var next_token: u32 = 0;

// Match ws_worker without pulling desktop socket or wallet dependencies into Wasm.
pub const HoeChannel = struct {
    id: [32]u8,
    capacity_msats: u64,
    balance_msats: u64,
    player: [33]u8,
};
pub const HoeLogin = struct { player: [33]u8, channel: ?HoeChannel };

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

    /// Proofs, if present, borrow only this instance's storage.
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
const CutRequest = protocol.RequestFor(.cut);
const PendingRequest = union(enum) { play: sync.PlayRequest, channel: ChannelRequest, cut: CutRequest };
const ChannelMailbox = union(enum) { idle, queued: ChannelRequest, waiting, received: ChannelCompletion };
const CutMailbox = union(enum) {
    idle,
    queued: CutRequest,
    waiting,
    received: struct { id: protocol.Id, outcome: protocol.Outcome(.cut) },
};

pub const Worker = struct {
    state: sync.Snapshot = .{},
    stage: Stage = .idle,
    token: ?u32 = null,
    wallet_generation: ?u32 = null,
    deadline: f64 = 0,
    retry_at: f64 = 0,
    backoff: f64 = 0.25,
    serial: u64 = 0,
    pending: ?PendingRequest = null,
    move_outbox: ?protocol.Location = null,
    area: sync.AreaMailbox = .idle,
    auth_player: ?[33]u8 = null,
    auth_hoe_channel: ?HoeChannel = null,
    channel: ChannelMailbox = .idle,
    channel_bytes: [max_outbound_bytes]u8 = undefined,
    cut: CutMailbox = .idle,
    settled_ids: [8][32]u8 = undefined,
    settled_count: usize = 0,

    // Keep the bridge limits in sync with browser/game-ws.js. Larger paid
    // channel messages do not change the existing movement/area budget.
    const max_outbound_bytes = protocol.max_channel_open_with_params_bytes;
    const max_inbound_bytes = protocol.max_channel_status_reply_bytes;
    const play_frame_bytes = 256;
    pub const area_limit = @min(protocol.max_area_chunks, (play_frame_bytes - protocol.area_response_overhead) / protocol.chunk_bytes);

    pub fn step(self: *Worker, generation: ?u32) sync.Snapshot {
        if (self.wallet_generation != generation) {
            self.stop();
            self.wallet_generation = generation;
        }
        const wallet = generation orelse return self.snapshot();
        owner = self;
        const now = haystack_ws_now();
        _ = self.expire(now);
        if (self.stage == .idle and now >= self.retry_at) {
            next_token +%= 1;
            self.token = next_token;
            self.stage = .preparing;
            self.state.status = .connecting;
            self.deadline = now + 10;
            haystack_ws_prepare(next_token, wallet, deliver);
        }
        if (self.stage == .play and self.pending == null) self.pump(now) catch self.fail(.retrying, now);
        return self.snapshot();
    }

    fn snapshot(self: *const Worker) sync.Snapshot {
        var state = self.state;
        state.pending = self.movePending();
        return state;
    }

    fn expire(self: *Worker, now: f64) bool {
        if (self.stage == .idle or (self.stage == .play and self.pending == null) or now < self.deadline) return false;
        self.fail(if (self.stage == .preparing or self.stage == .signing) .wallet_error else .retrying, now);
        return true;
    }

    pub fn stop(self: *Worker) void {
        if (owner == self) {
            owner = null;
            self.close();
            haystack_ws_clear_signer();
        }
        const session = self.state.session;
        self.* = .{};
        self.state.session = session;
    }

    fn close(self: *Worker) void {
        const token = self.token;
        self.token = null;
        self.stage = .idle;
        self.pending = null;
        self.move_outbox = null;
        self.area = .idle;
        self.auth_player = null;
        self.auth_hoe_channel = null;
        self.channel = .idle;
        self.cut = .idle;
        self.settled_count = 0;
        if (token) |id| haystack_ws_close(id);
    }

    fn fail(self: *Worker, status: sync.Status, now: f64) void {
        self.close();
        self.state.status = status;
        self.retry_at = now + self.backoff;
        self.backoff = @min(self.backoff * 2, 4);
    }

    fn send(self: *const Worker, payload: []const u8) bool {
        return haystack_ws_send(self.token orelse return false, payload.ptr, @intCast(payload.len)) == 1;
    }

    fn movePending(self: *const Worker) bool {
        return self.move_outbox != null or (if (self.pending) |request| request == .play and request.play.operation == .move else false);
    }

    fn ready(self: *const Worker, session: u64) bool {
        return self.stage == .play and self.state.session == session;
    }

    pub fn hoeLogin(self: *const Worker, session: u64) ?HoeLogin {
        if (!self.ready(session)) return null;
        return .{ .player = self.auth_player orelse return null, .channel = self.auth_hoe_channel };
    }

    /// The balance is from login, not a live channel query.
    pub fn hoeChannel(self: *const Worker, session: u64) ?HoeChannel {
        return (self.hoeLogin(session) orelse return null).channel;
    }

    /// Drop all queued work and get a fresh authenticated balance. Never replay a command.
    pub fn reauthenticate(self: *Worker, session: u64) void {
        if (!self.ready(session)) return;
        self.close();
        self.state.status = .connecting;
        self.retry_at = 0;
    }

    pub const refreshAuth = reauthenticate;

    pub fn submit(self: *Worker, session: u64, pos: protocol.Location) bool {
        if (!self.ready(session) or self.movePending()) return false;
        self.move_outbox = pos;
        return true;
    }

    pub fn requestArea(self: *Worker, session: u64, range: shared.world.ChunkRange) bool {
        if (!self.ready(session)) return false;
        return self.area.request(range);
    }

    pub fn takeArea(self: *Worker, session: u64, dest: *protocol.Snapshot) ?sync.AreaCompletion {
        if (!self.ready(session)) return null;
        return self.area.take(dest);
    }

    /// Encode into owned storage before returning; false means the slot is busy or stale.
    pub fn submitChannel(self: *Worker, session: u64, comptime kind: protocol.Kind, request: protocol.RequestFor(kind)) !bool {
        comptime if (!protocol.isChannel(kind)) @compileError("expected a channel command");
        if (!self.ready(session) or self.channel != .idle) return false;
        const bytes = try wire.encodeRequest(&self.channel_bytes, kind, request);
        self.channel = .{ .queued = .{ .id = request.request_id, .kind = kind, .len = bytes.len } };
        return true;
    }

    pub fn takeChannelFor(self: *Worker, session: u64, id: protocol.Id) ?ChannelCompletion {
        if (!self.ready(session) or self.channel != .received or
            !std.mem.eql(u8, &self.channel.received.request_id, &id)) return null;
        const completion = self.channel.received;
        self.channel = .idle;
        return completion;
    }

    /// Settlement notifications are hints; query channel_status for authoritative state.
    pub fn takeChannelSettled(self: *Worker, session: u64) ?[32]u8 {
        if (!self.ready(session) or self.settled_count == 0) return null;
        const id = self.settled_ids[0];
        self.settled_count -= 1;
        std.mem.copyForwards([32]u8, self.settled_ids[0..self.settled_count], self.settled_ids[1 .. self.settled_count + 1]);
        return id;
    }

    pub fn submitCut(self: *Worker, session: u64, command: CutRequest) bool {
        if (command.payload.payment == null or !self.ready(session) or self.cut != .idle) return false;
        self.cut = .{ .queued = command };
        return true;
    }

    pub fn takeCut(self: *Worker, session: u64, request_id: protocol.Id) ?protocol.Outcome(.cut) {
        if (!self.ready(session) or self.cut != .received or
            !std.mem.eql(u8, &self.cut.received.id, &request_id)) return null;
        const outcome = self.cut.received.outcome;
        self.cut = .idle;
        return outcome;
    }

    fn nextRequest(self: *Worker) ?PendingRequest {
        const operation: sync.PlayRequest.Operation = blk: {
            if (self.move_outbox) |move| {
                self.move_outbox = null;
                break :blk .{ .move = move };
            }
            if (self.channel == .queued) {
                const request = self.channel.queued;
                self.channel = .waiting;
                return .{ .channel = request };
            }
            if (self.cut == .queued) {
                const request = self.cut.queued;
                self.cut = .waiting;
                return .{ .cut = request };
            }
            break :blk .{ .area = self.area.start() orelse return null };
        };
        self.serial +%= 1;
        var request: sync.PlayRequest = .{ .id = @splat(0), .operation = operation };
        std.mem.writeInt(u64, request.id[0..8], self.serial, .little);
        return .{ .play = request };
    }

    fn pump(self: *Worker, now: f64) !void {
        const request = self.nextRequest() orelse return;
        var out: [protocol.max_gameplay_request_bytes]u8 = undefined;
        const payload = switch (request) {
            .play => |play| try play.encode(&out),
            .cut => |cut| try wire.encodeRequest(&out, .cut, cut),
            .channel => |channel| self.channel_bytes[0..channel.len],
        };
        if (!self.send(payload)) return error.SendFailed;
        self.pending = request;
        self.deadline = now + if (request == .channel) @as(f64, 5) else 2.5;
    }

    fn receive(self: *Worker, token: u32, event: Event, bytes: []const u8, now: f64) !void {
        if (self.expire(now)) return;
        switch (event) {
            .closed => self.fail(.retrying, now),
            .wallet_error => if (self.stage == .preparing or self.stage == .signing) self.fail(.wallet_error, now),
            .prepared => if (self.stage == .preparing) {
                self.stage = .opening;
                self.deadline = now + 4;
                haystack_ws_open(token, deliver);
            },
            .opened => if (self.stage == .opening) {
                self.stage = .challenge;
                self.state.status = .authenticating;
                self.deadline = now + 4;
            },
            .proof => if (self.stage == .signing) {
                if (bytes.len != 97) return error.InvalidProof;
                const proof: protocol.AuthProof = .{ .pubkey = bytes[0..33].*, .signature = bytes[33..97].* };
                var frame: [protocol.max_gameplay_request_bytes]u8 = undefined;
                if (!self.send(try wire.encodeAuth(&frame, .{ .proof = proof }))) return error.SendFailed;
                self.auth_player = proof.pubkey;
                self.stage = .auth_reply;
            },
            .message => switch (self.stage) {
                .challenge => {
                    const challenge = try wire.decodeAuth(bytes, true, .challenge);
                    self.stage = .signing;
                    haystack_ws_sign(token, &challenge.challenge);
                },
                .auth_reply => {
                    const reply = (try wire.decodeAuth(bytes, true, .reply)).reply;
                    if (reply == .failed) return self.fail(if (reply.failed == .invalid_credentials) .credentials_rejected else .retrying, now);
                    try self.restoreLogin(reply);
                },
                .play => try self.receivePlay(bytes),
                else => return error.UnexpectedReply,
            },
        }
    }

    fn restoreLogin(self: *Worker, reply: protocol.AuthOutcome) !void {
        const player = self.auth_player orelse return error.UnexpectedReply;
        self.auth_hoe_channel = null;
        self.state.confirmed = switch (reply) {
            .ok => |location| location,
            .ok_with_hoe_channel => |success| blk: {
                self.auth_hoe_channel = .{
                    .id = success.hoe_channel_id,
                    .capacity_msats = success.hoe_channel_capacity_msat,
                    .balance_msats = success.hoe_channel_balance_msat,
                    .player = player,
                };
                break :blk success.location;
            },
            .failed => unreachable,
        };
        self.stage = .play;
        self.state.status = .ready;
        self.backoff = 0.25;
        self.state.session +%= 1;
    }

    fn receivePlay(self: *Worker, bytes: []const u8) !void {
        if (wire.decodeChannelSettled(bytes, true)) |id| {
            if (self.settled_count < self.settled_ids.len) {
                self.settled_ids[self.settled_count] = id;
                self.settled_count += 1;
            }
            return;
        } else |_| {}

        const request = self.pending orelse return error.UnexpectedReply;
        var scratch: protocol.Snapshot = undefined;
        switch (request) {
            .play => |play| {
                if (bytes.len > play_frame_bytes) return error.MessageTooLarge;
                switch (try play.decode(bytes, &scratch)) {
                    .move => |pos| if (pos) |confirmed| {
                        self.state.confirmed = confirmed;
                    },
                    .area => |result| self.area.complete(result, &scratch),
                }
            },
            .channel => |channel| self.channel = .{ .received = try channel.decode(bytes, &scratch) },
            .cut => |cut| {
                const outcome = try wire.decodeReply(bytes, .cut, cut.request_id, &scratch);
                self.cut = .{ .received = .{ .id = cut.request_id, .outcome = outcome } };
            },
        }
        self.pending = null;
    }
};

fn deliver(token: u32, kind: c_int, ptr: [*c]const u8, len: u32) callconv(.c) void {
    const self = owner orelse return;
    if (self.token != token) return;
    const now = haystack_ws_now();
    const event = std.enums.fromInt(Event, kind) orelse return;
    if (len > Worker.max_inbound_bytes or (len != 0 and ptr == null)) {
        self.fail(.retrying, now);
        return;
    }
    self.receive(token, event, if (len == 0) "" else ptr[0..len], now) catch self.fail(.retrying, now);
}

test "browser queues settlement notices without losing a pending move" {
    const t = std.testing;
    var worker: Worker = .{ .stage = .play, .state = .{ .status = .ready, .session = 1 }, .deadline = 42 };
    var frame: [Worker.play_frame_bytes]u8 = undefined;
    const notice = try wire.encodeChannelSettled(&frame, @splat(1));
    try worker.receivePlay(notice);
    try t.expectError(error.UnexpectedReply, worker.receivePlay(notice[0 .. notice.len - 1]));

    const pos: protocol.Location = .{ .x = 1, .y = 2 };
    const request: sync.PlayRequest = .{ .id = @splat(2), .operation = .{ .move = pos } };
    worker.pending = .{ .play = request };
    try worker.receivePlay(notice);
    try t.expect(worker.takeChannelSettled(0) == null);
    try t.expectEqual(@as([32]u8, @splat(1)), worker.takeChannelSettled(1).?);
    try t.expectEqual(@as([32]u8, @splat(1)), worker.takeChannelSettled(1).?);
    try t.expect(worker.takeChannelSettled(1) == null);
    try t.expectEqualDeep(request, worker.pending.?.play);
    try t.expectEqual(@as(f64, 42), worker.deadline);
    const reply = try wire.encodeReply(&frame, .update_location, .{ .request_id = request.id, .payload = pos }, .{ .ok = {} });
    try worker.receivePlay(reply);
    try t.expect(worker.pending == null);
    try t.expectEqual(pos, worker.state.confirmed);
}

test "browser area batches fit the bridge and an in-flight area does not block a queued move" {
    const t = std.testing;
    const area: shared.world.ChunkRange = .{ .cx0 = -4, .cy0 = 2, .cx1 = -4 + Worker.area_limit - 1, .cy1 = 2 };
    const request: sync.PlayRequest = .{ .id = @splat(1), .operation = .{ .area = area } };
    const reply: protocol.Snapshot = .{ .area = area, .count = Worker.area_limit };
    var out: [protocol.max_response_bytes]u8 = undefined;
    const bytes = try wire.encodeReply(&out, .read_area, .{ .request_id = request.id, .payload = area }, .{ .ok = &reply });
    try t.expect(bytes.len <= Worker.play_frame_bytes);
    try t.expect(bytes.len + protocol.chunk_bytes > Worker.play_frame_bytes);

    var worker: Worker = .{ .stage = .play, .state = .{ .status = .ready, .session = 8 } };
    try t.expect(!worker.requestArea(7, area));
    try t.expect(worker.requestArea(8, area));
    try t.expect(!worker.requestArea(8, area));
    var dest: protocol.Snapshot = undefined;
    try t.expect(worker.takeArea(8, &dest) == null);
    try t.expectEqual(area, worker.area.start().?);
    try t.expect(worker.area.start() == null);
    try t.expect(worker.takeArea(8, &dest) == null);
    worker.pending = .{ .play = request };
    try t.expect(!worker.snapshot().pending);
    try t.expect(worker.submit(8, .{ .x = 1, .y = 0 }));
    try t.expect(worker.snapshot().pending);
    worker.area.complete(.snapshot, &reply);
    try t.expect(!worker.requestArea(8, area));
    try t.expect(worker.takeArea(7, &dest) == null);
    try t.expectEqual(sync.AreaCompletion.snapshot, worker.takeArea(8, &dest).?);
    try t.expectEqualDeep(reply, dest);
    try t.expect(worker.requestArea(8, area));
    try t.expectEqual(area, worker.area.start().?);
    worker.area.complete(.server_busy, &dest);
    try t.expectEqual(sync.AreaCompletion.server_busy, worker.takeArea(8, &dest).?);
    try t.expectEqualDeep(reply, dest);
    try t.expect(worker.takeArea(8, &dest) == null);
    try t.expect(worker.requestArea(8, area));
}

test "browser authenticated login binds the player and optional hoe channel to a session" {
    const t = std.testing;
    const player: [33]u8 = @splat(2);
    const pos: protocol.Location = .{ .x = -2, .y = 7 };
    var worker: Worker = .{ .stage = .auth_reply, .auth_player = player };
    try t.expect(worker.hoeLogin(0) == null);
    try worker.restoreLogin(.{ .ok = pos });
    try t.expectEqualDeep(HoeLogin{ .player = player, .channel = null }, worker.hoeLogin(1).?);
    try t.expectEqual(pos, worker.snapshot().confirmed);

    var frame: [wire.max_auth_reply_bytes]u8 = undefined;
    const bytes = try wire.encodeAuth(&frame, .{ .reply = .{ .ok_with_hoe_channel = .{
        .location = pos,
        .hoe_channel_id = @splat(3),
        .hoe_channel_capacity_msat = 50,
        .hoe_channel_balance_msat = 5,
    } } });
    try worker.restoreLogin((try wire.decodeAuth(bytes, true, .reply)).reply);
    try t.expect(worker.hoeLogin(1) == null);
    try t.expectEqualDeep(HoeChannel{ .id = @splat(3), .capacity_msats = 50, .balance_msats = 5, .player = player }, worker.hoeChannel(2).?);
}

test "browser serializes move, owned channel open, signed cut and area" {
    const t = std.testing;
    var worker: Worker = .{ .stage = .play, .state = .{ .status = .ready, .session = 1 } };
    const area: shared.world.ChunkRange = .{ .cx0 = 0, .cy0 = 0, .cx1 = 0, .cy1 = 0 };
    const pos: protocol.Location = .{ .x = 1, .y = 0 };
    var proof: [protocol.max_channel_proof_bytes + 1]u8 = @splat(0x11);
    var params: [protocol.max_channel_params_bytes]u8 = @splat(0x22);
    var open: protocol.RequestFor(.channel_open) = .{ .request_id = @splat(1), .payload = .{ .id = @splat(2), .proof = &proof, .params = &params } };
    var cut: CutRequest = .{ .request_id = @splat(3), .payload = .{ .x = 2, .y = 3 } };
    try t.expectError(error.InvalidProofLength, worker.submitChannel(1, .channel_open, open));
    open.payload.proof = proof[0..protocol.max_channel_proof_bytes];
    try t.expect(!try worker.submitChannel(0, .channel_open, open));
    try t.expect(try worker.submitChannel(1, .channel_open, open));
    try t.expect(!try worker.submitChannel(1, .channel_open, open));
    @memset(&proof, 0);
    @memset(&params, 0);
    try t.expect(!worker.submitCut(1, cut));
    cut.payload.payment = .{ .id = open.payload.id, .amount = 5, .signature = @splat(0x33) };
    try t.expect(!worker.submitCut(0, cut));
    try t.expect(worker.submitCut(1, cut));
    try t.expect(!worker.submitCut(1, cut));
    cut.payload.payment.?.signature[0] = 0;
    try t.expect(worker.requestArea(1, area));
    try t.expect(!worker.snapshot().pending);
    try t.expect(worker.submit(1, pos));

    var frame: [Worker.play_frame_bytes]u8 = undefined;
    worker.pending = worker.nextRequest();
    const move = worker.pending.?.play;
    try t.expectEqual(pos, move.operation.move);
    try worker.receivePlay(try wire.encodeReply(&frame, .update_location, .{ .request_id = move.id, .payload = pos }, .{ .ok = {} }));

    worker.pending = worker.nextRequest();
    try t.expect(!worker.snapshot().pending);
    const channel = worker.pending.?.channel;
    try t.expectEqual(@as(usize, 7232), channel.len);
    const sent = try wire.decodeMessage(worker.channel_bytes[0..channel.len], true);
    try t.expectEqual(open.request_id, sent.request_id);
    try t.expectEqualSlices(u8, &(@as([protocol.max_channel_proof_bytes]u8, @splat(0x11))), sent.operation.channel_open.proof);
    try t.expectEqualSlices(u8, &(@as([protocol.max_channel_params_bytes]u8, @splat(0x22))), sent.operation.channel_open.params);
    try worker.receivePlay(try wire.encodeReply(&frame, .channel_open, open, .{ .ok = {} }));
    try t.expect(worker.takeChannelFor(1, cut.request_id) == null);
    try t.expectEqual(.ok, worker.takeChannelFor(1, open.request_id).?.outcome.channel_open);

    worker.pending = worker.nextRequest();
    try t.expectEqual(@as(u8, 0x33), worker.pending.?.cut.payload.payment.?.signature[0]);
    var reply_cut = cut;
    reply_cut.request_id = @splat(4);
    const failed: protocol.Outcome(.cut) = .{ .failed = .{ .server_busy = {} } };
    try t.expectError(error.UnexpectedRequestId, worker.receivePlay(try wire.encodeReply(&frame, .cut, reply_cut, failed)));
    try worker.receivePlay(try wire.encodeReply(&frame, .cut, cut, failed));
    try t.expect(worker.takeCut(0, cut.request_id) == null);
    try t.expect(worker.takeCut(1, reply_cut.request_id) == null);
    try t.expectEqualDeep(failed, worker.takeCut(1, cut.request_id).?);
    try t.expect(worker.takeCut(1, cut.request_id) == null);
    try t.expectEqual(area, worker.nextRequest().?.play.operation.area);
}

test "browser correlates max-size status replies and owns proofs after callback reuse" {
    const t = std.testing;
    var worker: Worker = .{ .stage = .play, .state = .{ .status = .ready, .session = 1 }, .deadline = 5 };
    const req: protocol.RequestFor(.channel_status) = .{ .request_id = @splat(1), .payload = .{ .id = @splat(2) } };
    try t.expect(try worker.submitChannel(1, .channel_status, req));
    worker.pending = worker.nextRequest();
    var frame: [Worker.max_inbound_bytes + 1]u8 = undefined;
    try worker.receivePlay(try wire.encodeChannelSettled(&frame, req.payload.id));
    try t.expectEqual(req.payload.id, worker.takeChannelSettled(1).?);
    try t.expectEqual(@as(f64, 5), worker.deadline);
    try t.expectError(error.UnexpectedMessageType, worker.receivePlay(try wire.encodeReply(&frame, .channel_close, .{
        .request_id = req.request_id,
        .payload = req.payload,
    }, .{ .ok = {} })));
    const proofs: [protocol.max_sender_change_proofs_bytes]u8 = @splat(0x11);
    const reply = try wire.encodeReply(&frame, .channel_status, req, .{ .ok = .{
        .capacity_msat = 50,
        .balance_msat = 5,
        .phase = .settled,
        .sender_proofs = &proofs,
    } });
    try t.expectEqual(@as(usize, 61483), reply.len);
    try t.expectError(error.MessageTooLarge, worker.receivePlay(&frame));
    try worker.receivePlay(reply);
    @memset(&frame, 0);
    try t.expect(worker.takeChannelFor(0, req.request_id) == null);
    const done = worker.takeChannelFor(1, req.request_id).?;
    try t.expect(try worker.submitChannel(1, .channel_status, req));
    const status = done.outcome.channel_status.view().ok;
    try t.expectEqual(protocol.ChannelPhase.settled, status.phase);
    try t.expectEqualSlices(u8, &proofs, status.sender_proofs.?);
}
