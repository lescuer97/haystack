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

pub const Worker = struct {
    state: sync.Snapshot = .{},
    stage: Stage = .idle,
    token: ?u32 = null,
    wallet_generation: ?u32 = null,
    deadline: f64 = 0,
    retry_at: f64 = 0,
    backoff: f64 = 0.25,
    serial: u64 = 0,
    pending: ?sync.PlayRequest = null,
    move_outbox: ?protocol.Location = null,
    area: sync.AreaMailbox = .idle,

    // browser/game-ws.js caps incoming frames at 256 bytes. Batch within it.
    const bridge_frame_bytes = 256;
    pub const area_limit = @min(protocol.max_area_chunks, (bridge_frame_bytes - protocol.area_response_overhead) / protocol.chunk_bytes);

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
        return self.move_outbox != null or (if (self.pending) |request| request.operation == .move else false);
    }

    pub fn submit(self: *Worker, session: u64, pos: protocol.Location) bool {
        if (self.stage != .play or self.state.session != session or self.movePending()) return false;
        self.move_outbox = pos;
        return true;
    }

    pub fn requestArea(self: *Worker, session: u64, range: shared.world.ChunkRange) bool {
        if (self.stage != .play or self.state.session != session) return false;
        return self.area.request(range);
    }

    pub fn takeArea(self: *Worker, session: u64, dest: *protocol.Snapshot) ?sync.AreaCompletion {
        if (self.stage != .play or self.state.session != session) return null;
        return self.area.take(dest);
    }

    fn pump(self: *Worker, now: f64) !void {
        const operation: sync.PlayRequest.Operation = if (self.move_outbox) |move| blk: {
            self.move_outbox = null;
            break :blk .{ .move = move };
        } else if (self.area.start()) |range| .{ .area = range } else return;
        self.serial +%= 1;
        var request: sync.PlayRequest = .{ .id = @splat(0), .operation = operation };
        std.mem.writeInt(u64, request.id[0..8], self.serial, .little);
        var out: [protocol.max_gameplay_request_bytes]u8 = undefined;
        if (!self.send(try request.encode(&out))) return error.SendFailed;
        self.pending = request;
        self.deadline = now + 2.5;
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
                    switch (reply) {
                        .ok => |pos| {
                            self.stage = .play;
                            self.state.status = .ready;
                            self.backoff = 0.25;
                            self.state.session +%= 1;
                            self.state.confirmed = pos;
                        },
                        .failed => |failure| self.fail(if (failure == .invalid_credentials) .credentials_rejected else .retrying, now),
                    }
                },
                .play => {
                    const request = self.pending orelse return error.UnexpectedReply;
                    var scratch: protocol.Snapshot = undefined;
                    switch (try request.decode(bytes, &scratch)) {
                        .move => |pos| if (pos) |confirmed| {
                            self.state.confirmed = confirmed;
                        },
                        .area => |result| self.area.complete(result, &scratch),
                    }
                    self.pending = null;
                },
                else => return error.UnexpectedReply,
            },
        }
    }
};

fn deliver(token: u32, kind: c_int, ptr: [*c]const u8, len: u32) callconv(.c) void {
    const self = owner orelse return;
    if (self.token != token) return;
    const now = haystack_ws_now();
    const event = std.enums.fromInt(Event, kind) orelse return;
    if (len > Worker.bridge_frame_bytes or (len != 0 and ptr == null)) {
        self.fail(.retrying, now);
        return;
    }
    self.receive(token, event, if (len == 0) "" else ptr[0..len], now) catch self.fail(.retrying, now);
}

test "browser area batches fit the bridge and an in-flight area does not block a queued move" {
    const t = std.testing;
    const area: shared.world.ChunkRange = .{ .cx0 = -4, .cy0 = 2, .cx1 = -4 + Worker.area_limit - 1, .cy1 = 2 };
    const request: sync.PlayRequest = .{ .id = @splat(1), .operation = .{ .area = area } };
    const reply: protocol.Snapshot = .{ .area = area, .count = Worker.area_limit };
    var out: [protocol.max_response_bytes]u8 = undefined;
    const bytes = try wire.encodeReply(&out, .read_area, .{ .request_id = request.id, .payload = area }, .{ .ok = &reply });
    try t.expect(bytes.len <= Worker.bridge_frame_bytes);
    try t.expect(bytes.len + protocol.chunk_bytes > Worker.bridge_frame_bytes);

    var worker: Worker = .{ .stage = .play, .state = .{ .status = .ready, .session = 8 } };
    try t.expect(!worker.requestArea(7, area));
    try t.expect(worker.requestArea(8, area));
    try t.expect(!worker.requestArea(8, area));
    var dest: protocol.Snapshot = undefined;
    try t.expect(worker.takeArea(8, &dest) == null);
    try t.expectEqual(area, worker.area.start().?);
    try t.expect(worker.area.start() == null);
    try t.expect(worker.takeArea(8, &dest) == null);
    worker.pending = request;
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
