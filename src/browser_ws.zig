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
    pending: ?struct { id: protocol.Id, pos: protocol.Location } = null,

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
        return self.snapshot();
    }

    fn snapshot(self: *const Worker) sync.Snapshot {
        var state = self.state;
        state.pending = self.pending != null;
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

    pub fn submit(self: *Worker, session: u64, pos: protocol.Location) bool {
        if (self.stage != .play or self.state.session != session or self.pending != null) return false;
        self.serial +%= 1;
        var id: protocol.Id = @splat(0);
        std.mem.writeInt(u64, id[0..8], self.serial, .little);
        var out: [protocol.max_gameplay_request_bytes]u8 = undefined;
        const bytes = wire.encodeRequest(&out, .update_location, .{ .request_id = id, .payload = pos }) catch unreachable;
        const now = haystack_ws_now();
        if (!self.send(bytes)) {
            self.fail(.retrying, now);
            return false;
        }
        self.pending = .{ .id = id, .pos = pos };
        self.deadline = now + 2.5;
        return true;
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
                        .ok => {
                            self.stage = .play;
                            self.state.status = .ready;
                            self.backoff = 0.25;
                            self.state.session +%= 1;
                            self.state.confirmed = shared.movement.spawn;
                        },
                        .failed => |failure| self.fail(if (failure == .invalid_credentials) .credentials_rejected else .retrying, now),
                    }
                },
                .play => {
                    const move = self.pending orelse return error.UnexpectedReply;
                    var scratch: protocol.Snapshot = undefined;
                    if (try wire.decodeReply(bytes, .update_location, move.id, &scratch) == .ok) self.state.confirmed = move.pos;
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
    if (len > protocol.max_gameplay_request_bytes or (len != 0 and ptr == null)) {
        self.fail(.retrying, now);
        return;
    }
    self.receive(token, event, if (len == 0) "" else ptr[0..len], now) catch self.fail(.retrying, now);
}
