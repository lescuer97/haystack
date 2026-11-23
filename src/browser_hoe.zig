//! Browser paid hoe. The wallet owns all durable state; this runtime owns only
//! one authenticated exchange and one wallet request at a time.
const std = @import("std");
const protocol = @import("shared").protocol;
const paid_cut = @import("paid_cut.zig");
const ws = @import("browser_ws.zig");
const Snapshot = @import("ws_sync.zig").Snapshot;
const game_mod = @import("game.zig");
const Game = game_mod.GameState;

const scope = "ws://127.0.0.1:9224/";
const price = protocol.hoe_price_msat;
const open_remaining_seconds = 300;
const payment_remaining_seconds = 120;
const max_debit_msats = 55; // Wallet enforces the selected mint's cap (50 in fixtures).
const Op = enum(c_int) { inspect = 1, quote, fund, open_payload, bind, prepare_cut, resolve_cut, finalize, resume_quote, resume_funding };
const Callback = *const fn (c_int, u32, u32, [*c]const u8, u32) callconv(.c) void;
extern fn haystack_hoe_request(u32, u32, c_int, [*]const u8, u32, Callback) void;
extern "c" fn getentropy([*]u8, usize) c_int;

var owner: ?*Runtime = null;
var next_serial: u32 = 0;

const Record = struct {
    id: [32]u8,
    capacity: u64,
    refund: u64,
    accepted: u64,
    admitted: bool,

    fn canReopen(self: Record, has_login_channel: bool, now: ?u64) bool {
        return !has_login_channel and !self.admitted and self.accepted == 0 and
            now != null and self.refund -| now.? >= open_remaining_seconds;
    }

    fn canPay(self: Record, now: ?u64) bool {
        return now != null and self.refund -| now.? > payment_remaining_seconds;
    }
};
const Terms = struct {
    server: protocol.SpillmanChannelRequirementsRes,
    player: [33]u8,

    fn acceptsFresh(self: Terms, fresh: protocol.SpillmanChannelRequirementsRes, player: [33]u8) bool {
        // The server computes a rolling absolute expiry; never substitute it
        // for the absolute expiry that was actually quoted by the wallet.
        return fresh.amount == self.server.amount and std.meta.eql(fresh.pubkey, self.server.pubkey) and
            fresh.refundTime >= self.server.refundTime and std.meta.eql(player, self.player);
    }
};
const Offer = struct {
    id: [36]u8,
    capacity: u64,
    debit: u64,
    expires: u64,
    resume_funding: ?struct { channel: [32]u8, receiver: [33]u8, refund: u64 } = null,
};
const Verdict = enum { charged, already_cut, not_sent };
const Cut = struct { id: protocol.Id, tile: protocol.Location, verdict: ?Verdict = null, cancelled: bool = false };
const Phase = enum {
    inspect,
    unfunded,
    quote_terms,
    quoting,
    offer,
    confirm_terms,
    funding,
    opening,
    query,
    binding,
    active,
    depleted,
    closing,
    finalizing,
    settlement_retry,
    resume_available,
    recovery,
};
const Job = struct { session: u64, serial: u32, op: Op, started: f64 };

pub const Runtime = struct {
    generation: ?u32 = null,
    session: ?u64 = null,
    phase: Phase = .inspect,
    record: ?Record = null,
    server: ?u64 = null,
    terms: ?Terms = null,
    offer: ?Offer = null,
    consent: bool = false,
    quote_failed: bool = false,
    settled: bool = false,
    notice: bool = false,
    refresh_after_bind: bool = false,
    query_at: f64 = 0,
    query_delay: f64 = 1,
    open_delay: f64 = 1,
    request: ?protocol.Id = null,
    cut: ?Cut = null,
    job: ?Job = null,
    response: ?struct { ok: bool, len: usize } = null,
    bytes: [64 * 1024]u8 = undefined,

    pub fn stop(self: *Runtime) void {
        if (owner == self) owner = null;
        self.clearResponse();
        self.job = null;
    }

    pub fn cutPending(self: *const Runtime) bool {
        return self.cut != null;
    }

    pub fn update(self: *Runtime, connection: *ws.Worker, network: Snapshot, generation: ?u32, game: *Game, now: ?u64, clock: f64, area_pending: bool) bool {
        const before = game.paid_hoe.view;
        const funding_before = game.hoe_funding.status;
        if (generation) |gen| {
            if (self.generation != gen) {
                self.stop();
                self.generation = gen;
                self.session = null;
                self.settled = false;
            }
            owner = self;
        }
        const login = if (generation != null) connection.hoeLogin(network.session) else null;
        const session = if (login != null) network.session else null;
        if (session != self.session) {
            self.session = session;
            self.restartQuery();
            self.phase = .inspect;
            self.record = null;
            self.server = null;
            self.terms = null;
            self.offer = null;
            self.consent = false;
            self.quote_failed = false;
            self.notice = false;
            self.refresh_after_bind = false;
            self.open_delay = 1;
            self.cut = null;
        }
        self.advance(connection, network, login, game, now, clock, area_pending) catch |err| {
            std.log.debug("browser hoe blocked: {s}", .{@errorName(err)});
            self.phase = .recovery;
            self.cut = null;
        };
        self.publish(game, now, clock);
        const changed = !std.meta.eql(before, game.paid_hoe.view) or funding_before != game.hoe_funding.status;
        if (changed) {
            game.paid_hoe.refill_presented = false;
            game.paid_hoe.click_origin = null;
        }
        return changed;
    }

    fn advance(self: *Runtime, connection: *ws.Worker, network: Snapshot, login_opt: ?ws.HoeLogin, game: *Game, now: ?u64, clock: f64, area_pending: bool) !void {
        if (self.job) |job| {
            const reply = self.response orelse return;
            self.job = null;
            if (job.op == .fund or job.op == .resume_funding or job.op == .finalize) {
                game.menu.wallet.balance_dirty = true;
                game.menu.wallet.history_dirty = true;
            }
            // Do not let an old wallet completion authorize an action on a
            // new socket. A fresh inspect will see any durable side effects.
            if (self.session != job.session) {
                self.clearResponse();
                return;
            }
            if (clock >= job.started + 30) {
                self.clearResponse();
                connection.refreshAuth(job.session);
                return;
            }
            if (!reply.ok) {
                self.clearResponse();
                if (self.retryWalletJob(job.op)) return;
                return error.WalletBridge;
            }
            const parsed = blk: {
                defer self.clearResponse();
                break :blk try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, self.bytes[0..reply.len], .{ .allocate = .alloc_always });
            };
            defer parsed.deinit();
            const fields = successful(parsed.value) catch |err| {
                if (parsed.value == .object and self.walletRejection(job.op, parsed.value.object, login_opt.?)) return;
                if (self.retryWalletJob(job.op)) return;
                return err;
            };
            try self.walletResult(job.op, fields, connection, network, login_opt.?, game, now, clock);
            return;
        }
        const login = login_opt orelse return;
        while (connection.takeChannelSettled(network.session)) |id| {
            if (self.record) |record| if (std.meta.eql(record.id, id)) {
                self.notice = true;
            };
        }
        if (self.cut) |cut| {
            // Apply the cut only after earlier queued area data has been consumed.
            if (area_pending) return;
            const outcome = connection.takeCut(network.session, cut.id) orelse return;
            const verdict = classify(cut.tile, outcome) orelse {
                self.cut = null;
                self.phase = .recovery;
                connection.refreshAuth(network.session);
                return;
            };
            try self.resolve(cut, verdict, clock);
            return;
        }
        if (self.request) |id| {
            const done = connection.takeChannelFor(network.session, id) orelse return;
            self.request = null;
            try self.channelResult(done.outcome, login, game, now, clock);
            return;
        }
        if (self.notice and (self.phase == .active or self.phase == .depleted or self.phase == .recovery or self.phase == .query)) {
            self.notice = false;
            self.restartQuery();
        }
        switch (self.phase) {
            .inspect => try self.send(.inspect, &.{scope}, clock),
            .query => if (clock >= self.query_at) {
                try self.channel(connection, .channel_status, .{ .id = self.record.?.id });
            },
            .offer => if (!self.offerUsable(now) or game.menu.opened) self.discardOffer(),
            else => {},
        }
    }

    fn discardOffer(self: *Runtime) void {
        self.phase = if (self.offer != null and self.offer.?.resume_funding != null) .resume_available else .unfunded;
        self.offer = null;
    }

    fn walletRejection(self: *Runtime, op: Op, fields: std.json.ObjectMap, login: ws.HoeLogin) bool {
        const message = text(fields, "error") catch return false;
        if (op == .inspect and login.channel == null and
            std.mem.eql(u8, message, "hoe funding is pending; resume the saved swap"))
        {
            self.offer = null;
            self.phase = .resume_available;
            return true;
        }
        if (op == .finalize and (std.mem.startsWith(u8, message, "hoe_settlement_preflight: ") or
            std.mem.startsWith(u8, message, "hoe_settlement_release_pending: ")))
        {
            self.phase = .settlement_retry;
            return true;
        }
        return false;
    }

    fn retryWalletJob(self: *Runtime, op: Op) bool {
        switch (op) {
            .quote => {
                self.offer = null;
                self.phase = .unfunded;
                self.quote_failed = true;
            },
            // An error may have happened after mint submission. Inspect may
            // restore the saved swap, but never starts another one.
            .fund, .resume_funding => self.phase = .inspect,
            else => return false,
        }
        return true;
    }

    pub fn click(self: *Runtime, connection: *ws.Worker, network: Snapshot, game: *Game, now: ?u64, clock: f64) void {
        const refill = game.paid_hoe.refill_requested;
        const tile = game.paid_hoe.target;
        game.paid_hoe.refill_requested = false;
        game.paid_hoe.target = null;
        if (game.menu.opened) {
            self.consent = false;
            if (self.job != null and self.job.?.op == .prepare_cut) {
                if (self.cut) |*cut| cut.cancelled = true;
            }
            if (self.phase == .offer) {
                self.discardOffer();
                self.publish(game, now, clock);
            }
            return;
        }
        const session = self.session orelse return;
        if (self.job != null or self.request != null or self.cut != null or connection.hoeLogin(session) == null) return;
        self.act(connection, network, game, refill, tile, now, clock) catch {
            self.phase = .recovery;
            self.cut = null;
        };
        self.publish(game, now, clock);
    }

    fn act(self: *Runtime, connection: *ws.Worker, network: Snapshot, game: *Game, refill: bool, tile_opt: ?protocol.Location, now: ?u64, clock: f64) !void {
        if (refill) {
            switch (self.phase) {
                .unfunded => {
                    self.quote_failed = false;
                    try self.channel(connection, .channel_requirements, .{ .tool = .hoe });
                    self.phase = .quote_terms;
                },
                .offer => {
                    if (!self.offerUsable(now)) return;
                    try self.channel(connection, .channel_requirements, .{ .tool = .hoe });
                    self.consent = true;
                    self.phase = .confirm_terms;
                },
                .resume_available => {
                    try self.send(.resume_quote, &.{scope}, clock);
                    self.phase = .quoting;
                },
                .settlement_retry => self.restartQuery(),
                .depleted => {
                    if (!self.canClose(now)) return;
                    try self.channel(connection, .channel_close, .{ .id = self.record.?.id });
                    self.phase = .closing;
                },
                else => {},
            }
            return;
        }
        const tile = tile_opt orelse return;
        if (game.paid_hoe.view.status != .ready or !canCut(network, tile)) return;
        const record = self.record.?;
        if (!record.canPay(now)) return;
        const id = try requestId();
        try self.send(.prepare_cut, &.{ scope, &std.fmt.bytesToHex(record.id, .lower), &std.fmt.bytesToHex(id, .lower) }, clock);
        self.cut = .{ .id = id, .tile = tile };
    }

    fn channelResult(self: *Runtime, outcome: ws.ChannelCompletion.Outcome, login: ws.HoeLogin, game: *Game, now: ?u64, clock: f64) !void {
        switch (outcome) {
            .channel_requirements => |response| {
                const confirming = self.phase == .confirm_terms;
                defer self.consent = false;
                if (response != .ok or now == null or response.ok.amount != price or response.ok.refundTime <= now.?) {
                    self.discardOffer();
                    self.quote_failed = true;
                    return;
                }
                if (self.record != null or login.channel != null) return error.ChannelExists;
                if (confirming) {
                    if (!self.consent or game.menu.opened or !self.offerUsable(now)) {
                        self.discardOffer();
                        return;
                    }
                    if (self.offer.?.resume_funding) |saved| {
                        if (!std.meta.eql(saved.receiver, response.ok.pubkey) or saved.refund > response.ok.refundTime) return error.ResumeTermsChanged;
                        const debit = decimal(self.offer.?.debit);
                        try self.send(.resume_funding, &.{ scope, &self.offer.?.id, debit.slice() }, clock);
                        self.phase = .funding;
                        return;
                    }
                    if (!self.terms.?.acceptsFresh(response.ok, login.player)) {
                        self.discardOffer();
                        return;
                    }
                } else {
                    self.terms = .{ .server = response.ok, .player = login.player };
                }
                const terms = self.terms.?;
                const receiver = std.fmt.bytesToHex(terms.server.pubkey, .lower);
                const player = std.fmt.bytesToHex(terms.player, .lower);
                const amount = decimal(terms.server.amount);
                const refund = decimal(terms.server.refundTime);
                const args = [_]?[]const u8{ scope, &receiver, amount.slice(), refund.slice(), &player };
                if (confirming) {
                    try self.send(.fund, &([_]?[]const u8{&self.offer.?.id} ++ args), clock);
                    self.phase = .funding;
                } else {
                    try self.send(.quote, &args, clock);
                    self.phase = .quoting;
                }
            },
            .channel_open => |response| switch (response) {
                .ok => {
                    self.refresh_after_bind = true;
                    try self.bind(0, clock);
                },
                .failed => |why| switch (why) {
                    // A link may have failed after admission. Query again
                    // before retrying the exact saved Open, never fund again.
                    .server_busy, .unavailable => {
                        self.restartQuery();
                        self.query_at = clock + self.open_delay;
                        self.open_delay = @min(self.open_delay * 2, 30);
                    },
                    .invalid_request, .invalid_proof => return error.OpenRejected,
                },
            },
            .channel_close => {
                // No close response, including an error, proves settlement.
                self.restartQuery();
            },
            .channel_status => |response| switch (response.view()) {
                .failed => |why| switch (why) {
                    .server_busy, .unavailable => self.retryQuery(clock),
                    .not_found => try self.reopen(login, now, clock),
                    .invalid_request => return error.StatusRejected,
                },
                .ok => |status| {
                    const record = self.record.?;
                    if (status.capacity_msat != record.capacity or !validBalance(record.capacity, status.balance_msat)) return error.BadStatus;
                    self.server = status.balance_msat;
                    switch (status.phase) {
                        .active => if (login.channel == null) {
                            if (status.balance_msat != 0) return error.UnlinkedBalance;
                            try self.reopen(login, now, clock);
                        } else {
                            if (status.balance_msat >= record.capacity) return error.BadStatus;
                            try self.bind(status.balance_msat, clock);
                        },
                        .depleted => {
                            if (status.balance_msat != record.capacity) return error.BadStatus;
                            try self.bind(status.balance_msat, clock);
                        },
                        .settlement_pending => self.retryQuery(clock),
                        .settled => {
                            const capacity = decimal(record.capacity);
                            const accepted = decimal(status.balance_msat);
                            try self.send(.finalize, &.{ scope, &std.fmt.bytesToHex(record.id, .lower), capacity.slice(), accepted.slice(), status.sender_proofs }, clock);
                            self.phase = .finalizing;
                        },
                        .sender_refund_required => return error.SenderRefundRequired,
                    }
                },
            },
        }
    }

    fn walletResult(self: *Runtime, op: Op, result: std.json.ObjectMap, connection: *ws.Worker, network: Snapshot, login: ws.HoeLogin, game: *Game, now: ?u64, clock: f64) !void {
        switch (op) {
            .inspect => {
                const value = result.get("channel_id") orelse return error.BadInspect;
                if (value == .null) {
                    if (login.channel != null) return error.MissingLocalChannel;
                    self.phase = .unfunded;
                    return;
                }
                const record: Record = .{
                    .id = try hexField(32, result, "channel_id"),
                    .capacity = try number(result, "capacity_msats"),
                    .refund = try number(result, "refund_time"),
                    .accepted = try number(result, "balance_msats"),
                    .admitted = blk: {
                        const admitted = result.get("admitted") orelse return error.BadInspect;
                        if (admitted != .bool) return error.BadInspect;
                        break :blk admitted.bool;
                    },
                };
                if (record.refund == 0 or !protocol.validHoeCapacity(record.capacity) or !validBalance(record.capacity, record.accepted)) return error.BadInspect;
                if (login.channel) |live| {
                    if (!std.meta.eql(live.id, record.id) or live.capacity_msats != record.capacity or !validBalance(record.capacity, live.balance_msats)) return error.LoginMismatch;
                }
                self.record = record;
                self.restartQuery();
            },
            .quote => {
                const offer = parseOffer(result, self.terms.?) catch {
                    self.phase = .unfunded;
                    self.quote_failed = true;
                    return;
                };
                self.offer = offer;
                self.phase = .offer;
            },
            .resume_quote => {
                if (login.channel != null or game.menu.opened) {
                    self.phase = .resume_available;
                    return;
                }
                self.offer = try parseResumeOffer(result);
                self.phase = .offer;
            },
            .fund, .resume_funding, .open_payload => {
                // Only the journaled channel material is forwarded; Zig never
                // swaps, rebuilds or substitutes funding proofs on retries.
                const id = try hexField(32, result, "channel_id");
                const capacity = try number(result, "capacity_msats");
                const refund = try number(result, "refund_time");
                if (op == .fund or op == .resume_funding) {
                    const offer = self.offer.?;
                    if (capacity != offer.capacity) return error.FundingMismatch;
                    if (op == .resume_funding) {
                        const saved = offer.resume_funding.?;
                        if (!std.meta.eql(id, saved.channel) or refund != saved.refund) return error.FundingMismatch;
                    } else if (refund != self.terms.?.server.refundTime) return error.FundingMismatch;
                    self.record = .{ .id = id, .capacity = capacity, .refund = refund, .accepted = 0, .admitted = false };
                } else {
                    const record = self.record.?;
                    if (!std.meta.eql(record.id, id) or capacity != record.capacity or refund != record.refund) return error.FundingMismatch;
                }
                if (!self.record.?.canReopen(login.channel != null, now)) return error.StaleOpen;
                try self.channel(connection, .channel_open, .{ .id = id, .proof = try text(result, "funding_proofs_json"), .params = try text(result, "params_json") });
                self.phase = .opening;
            },
            .bind => {
                const balance = try number(result, "balance_msats");
                if (self.server != balance) return error.BindMismatch;
                const record = &self.record.?;
                record.admitted = true;
                record.accepted = balance;
                if (self.refresh_after_bind) {
                    self.refresh_after_bind = false;
                    self.phase = .inspect;
                    connection.refreshAuth(network.session);
                } else self.phase = if (balance == record.capacity) .depleted else .active;
            },
            .prepare_cut => {
                const cut = self.cut.?;
                const record = self.record.?;
                const signature = try hexField(64, result, "signature");
                const next = record.accepted + price;
                if (try number(result, "balance_msats") != next or next > record.capacity) return error.PrepareMismatch;
                // Preparation is durable, but submitting false guarantees it
                // never reached the pending queue. Only that case can roll back.
                if (!record.canPay(now) or cut.cancelled or game.menu.opened or !canCut(network, cut.tile) or
                    !connection.submitCut(network.session, .{ .request_id = cut.id, .payload = .{
                        .x = cut.tile.x,
                        .y = cut.tile.y,
                        .payment = .{ .id = record.id, .amount = next, .signature = signature },
                    } })) try self.resolve(cut, .not_sent, clock);
            },
            .resolve_cut => {
                const cut = self.cut.?;
                const verdict = cut.verdict.?;
                const record = &self.record.?;
                const accepted = record.accepted + (if (verdict == .charged) price else 0);
                if (try number(result, "balance_msats") != accepted) return error.ResolveMismatch;
                self.server = accepted;
                record.accepted = accepted;
                self.cut = null;
                if (verdict != .not_sent) game.applyHoeCut(cut.tile);
                if (verdict == .charged) {
                    game.cut_feedback.confirm(.{ .tile = cut.tile, .refill_needed = accepted == record.capacity });
                    game.player_animation.update(0, direction(cut.tile.x, game.player_pos.x), direction(cut.tile.y, game.player_pos.y), false, .hoe);
                }
                if (accepted == record.capacity) self.restartQuery();
            },
            .finalize => {
                self.settled = true;
                self.phase = .inspect;
                connection.refreshAuth(network.session);
            },
        }
    }

    fn resolve(self: *Runtime, cut: Cut, verdict: Verdict, clock: f64) !void {
        try self.send(.resolve_cut, &.{ scope, &std.fmt.bytesToHex(self.record.?.id, .lower), &std.fmt.bytesToHex(cut.id, .lower), if (verdict == .charged) "charged" else "not_charged" }, clock);
        self.cut.?.verdict = verdict;
    }

    fn reopen(self: *Runtime, login: ws.HoeLogin, now: ?u64, clock: f64) !void {
        const record = self.record.?;
        if (!record.canReopen(login.channel != null, now)) return error.UnsafeReopen;
        try self.send(.open_payload, &.{ scope, &std.fmt.bytesToHex(record.id, .lower) }, clock);
        self.phase = .opening;
    }

    fn bind(self: *Runtime, accepted: u64, clock: f64) !void {
        const record = self.record.?;
        const capacity = decimal(record.capacity);
        const balance = decimal(accepted);
        try self.send(.bind, &.{ scope, &std.fmt.bytesToHex(record.id, .lower), capacity.slice(), balance.slice() }, clock);
        self.server = accepted;
        self.phase = .binding;
    }

    fn restartQuery(self: *Runtime) void {
        self.phase = .query;
        self.request = null;
        self.query_at = 0;
        self.query_delay = 1;
    }

    fn retryQuery(self: *Runtime, clock: f64) void {
        self.query_at = clock + self.query_delay;
        self.query_delay = @min(self.query_delay * 2, 30);
    }

    fn canClose(self: *const Runtime, now: ?u64) bool {
        const record = self.record orelse return false;
        return now != null and now.? < record.refund and record.admitted and
            record.accepted == record.capacity and self.server == record.capacity;
    }

    fn offerUsable(self: *const Runtime, now: ?u64) bool {
        const offer = self.offer orelse return false;
        return now != null and now.? < offer.expires;
    }

    fn channel(self: *Runtime, connection: *ws.Worker, comptime kind: protocol.Kind, payload: protocol.Payload(kind)) !void {
        const id = try requestId();
        if (!try connection.submitChannel(self.session.?, kind, .{ .request_id = id, .payload = payload })) return error.ChannelBusy;
        self.request = id;
    }

    fn send(self: *Runtime, op: Op, args: []const ?[]const u8, clock: f64) !void {
        std.debug.assert(self.job == null and self.response == null);
        const allocator = std.heap.c_allocator;
        const json = try std.json.Stringify.valueAlloc(allocator, args, .{});
        defer {
            std.crypto.secureZero(u8, json);
            allocator.free(json);
        }
        next_serial +%= 1;
        self.job = .{ .session = self.session.?, .serial = next_serial, .op = op, .started = clock };
        haystack_hoe_request(self.generation.?, next_serial, @backingInt(op), json.ptr, @intCast(json.len), deliver);
    }

    fn clearResponse(self: *Runtime) void {
        if (self.response) |response| std.crypto.secureZero(u8, self.bytes[0..response.len]);
        self.response = null;
    }

    fn publish(self: *const Runtime, game: *Game, now: ?u64, clock: f64) void {
        var view: game_mod.HoeView = .{};
        var funding: ?game_mod.HoeFundingUi.Status = null;
        if (self.session != null) {
            if (self.record) |record| {
                view.client = .{ .capacity = record.capacity, .accepted = record.accepted, .stale = self.phase == .recovery };
                if (self.server) |accepted| view.server = .{ .capacity = record.capacity, .accepted = accepted, .stale = self.cut != null or self.phase == .recovery };
                if (self.phase == .active or self.phase == .depleted) view.cuts_left = (record.capacity - record.accepted) / price;
            }
            view.payment_pending = self.cut != null;
            view.status = if (self.cut != null) .pending else switch (self.phase) {
                .inspect, .quote_terms, .quoting, .confirm_terms, .funding, .opening, .binding => .checking,
                .unfunded, .offer => if (self.settled or self.phase == .offer) .settled else .unavailable,
                .query => if (self.query_delay > 1) .settling else .checking,
                .closing, .finalizing => .settling,
                .active => if (self.record.?.canPay(now)) .ready else .recovery,
                .depleted => if (self.canClose(now)) .empty else .recovery,
                .recovery, .settlement_retry, .resume_available => .recovery,
            };
            funding = switch (self.phase) {
                .unfunded => if (self.quote_failed) .quote_failed else null,
                .funding => .funding,
                .opening => .opening,
                else => null,
            };
            if (self.phase == .offer and self.offerUsable(now)) {
                const offer = self.offer.?;
                view.offer = .{ .cuts = offer.capacity / price, .debit = offer.debit, .resume_funding = offer.resume_funding != null };
            }
            view.close_first = self.phase == .depleted and self.canClose(now);
            view.recovery_action = switch (self.phase) {
                .resume_available => .review_funding,
                .settlement_retry => .retry_settlement,
                else => null,
            };
            view.can_refill = self.job == null and (self.phase == .unfunded or view.offer != null or view.close_first or view.recovery_action != null);
            // A missing callback must not free the mutation slot for another
            // attempt. A late result is recovered through a fresh login.
            if (self.job) |job| if (clock >= job.started + 30) {
                view.status = .recovery;
                funding = null;
            };
        }
        game.paid_hoe.view = view;
        _ = game.hoe_funding.publish(funding);
    }
};

fn deliver(ok: c_int, generation: u32, serial: u32, ptr: [*c]const u8, len: u32) callconv(.c) void {
    const self = owner orelse return;
    const job = self.job orelse return;
    if (generation != self.generation or serial != job.serial or self.response != null) return;
    if (ok != 1 or len == 0 or len > self.bytes.len or ptr == null) {
        self.response = .{ .ok = false, .len = 0 };
        return;
    }
    @memcpy(self.bytes[0..len], ptr[0..len]);
    self.response = .{ .ok = true, .len = len };
}

fn successful(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.BadResult;
    const status = value.object.get("status") orelse return error.BadResult;
    if (status != .integer or status.integer != 0) return error.WalletStatus;
    return value.object;
}

fn text(result: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const field = result.get(key) orelse return error.MissingField;
    if (field != .string or field.string.len == 0) return error.BadField;
    return field.string;
}

fn number(result: std.json.ObjectMap, key: []const u8) !u64 {
    const s = try text(result, key);
    for (s) |c| if (c < '0' or c > '9') return error.BadNumber;
    return std.fmt.parseInt(u64, s, 10);
}

fn hexField(comptime len: usize, result: std.json.ObjectMap, key: []const u8) ![len]u8 {
    const value = try text(result, key);
    if (value.len != 2 * len) return error.BadHex;
    var decoded: [len]u8 = undefined;
    _ = try std.fmt.hexToBytes(&decoded, value);
    return decoded;
}

fn parseOffer(result: std.json.ObjectMap, terms: Terms) !Offer {
    const id = try text(result, "quote_id");
    const capacity = try number(result, "capacity_msats");
    const debit = try number(result, "max_debit_msats");
    const expires = try number(result, "expires_at");
    if (id.len != 36 or !validDebit(capacity, debit) or try number(result, "cuts") != capacity / price or expires == 0 or expires >= terms.server.refundTime or
        try number(result, "refund_time") != terms.server.refundTime or try number(result, "price_msats") != terms.server.amount or
        !std.meta.eql(try hexField(33, result, "receiver_pubkey"), terms.server.pubkey) or !std.mem.eql(u8, try text(result, "scope"), scope)) return error.BadOffer;
    return .{ .id = id[0..36].*, .capacity = capacity, .debit = debit, .expires = expires };
}

fn validDebit(capacity: u64, debit: u64) bool {
    return protocol.validHoeCapacity(capacity) and debit >= capacity and debit <= max_debit_msats;
}

fn parseResumeOffer(result: std.json.ObjectMap) !Offer {
    const id = try text(result, "operation_id");
    const capacity = try number(result, "capacity_msats");
    const debit = try number(result, "max_debit_msats");
    const refund = try number(result, "refund_time");
    if (id.len != 36 or !validDebit(capacity, debit) or try number(result, "cuts") != capacity / price or
        refund <= open_remaining_seconds or !std.mem.eql(u8, try text(result, "scope"), scope)) return error.BadOffer;
    return .{
        .id = id[0..36].*,
        .capacity = capacity,
        .debit = debit,
        .expires = refund - open_remaining_seconds,
        .resume_funding = .{ .channel = try hexField(32, result, "channel_id"), .receiver = try hexField(33, result, "receiver_pubkey"), .refund = refund },
    };
}

const Decimal = struct {
    bytes: [20]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const Decimal) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn decimal(n: u64) Decimal {
    var out: Decimal = .{};
    out.len = (std.fmt.bufPrint(&out.bytes, "{d}", .{n}) catch unreachable).len;
    return out;
}

fn requestId() !protocol.Id {
    var id: protocol.Id = undefined;
    if (getentropy(&id, id.len) != 0) return error.EntropyUnavailable;
    return id;
}

fn validBalance(capacity: u64, accepted: u64) bool {
    return accepted <= capacity and accepted % price == 0;
}

fn canCut(network: Snapshot, tile: protocol.Location) bool {
    return network.status == .ready and !network.pending and
        paid_cut.withinReach(tile, network.confirmed);
}

fn direction(target: i32, origin: i32) i8 {
    return if (target < origin) -1 else if (target > origin) 1 else 0;
}

fn classify(tile: protocol.Location, outcome: protocol.Outcome(.cut)) ?Verdict {
    return switch (paid_cut.classify(tile, outcome) orelse return null) {
        .charged => .charged,
        .already_cut => .already_cut,
    };
}

test "browser hoe quotes bind to original terms and expose the wallet's maximum debit" {
    const t = std.testing;
    const terms: Terms = .{ .player = @splat(2), .server = .{ .pubkey = @splat(3), .amount = price, .refundTime = 120 } };
    const receiver = std.fmt.bytesToHex(terms.server.pubkey, .lower);
    const json = try std.json.Stringify.valueAlloc(t.allocator, .{
        .status = 0,
        .quote_id = "01234567-89ab-cdef-0123-456789abcdef",
        .scope = scope,
        .receiver_pubkey = @as([]const u8, &receiver),
        .price_msats = "5",
        .cuts = "10",
        .refund_time = "120",
        .capacity_msats = "50",
        .max_debit_msats = "53",
        .expires_at = "100",
    }, .{});
    defer t.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, json, .{});
    defer parsed.deinit();
    const fields = try successful(parsed.value);
    const offer = try parseOffer(fields, terms);
    try t.expectEqual(@as(u64, 53), offer.debit);
    var fresh = terms.server;
    fresh.refundTime += 5;
    try t.expect(terms.acceptsFresh(fresh, terms.player));
    try t.expectError(error.BadOffer, parseOffer(fields, .{ .server = fresh, .player = terms.player }));
    fresh.refundTime = 119;
    try t.expect(!terms.acceptsFresh(fresh, terms.player));
    fresh.refundTime = 120;
    fresh.pubkey[0] ^= 1;
    try t.expect(!terms.acceptsFresh(fresh, terms.player));
}

test "browser hoe accepts only a matching authoritative grass reply for a cut" {
    const t = std.testing;
    const tile: protocol.Location = .{ .x = 5, .y = -2 };
    const grass: protocol.State = .{ .x = 5, .y = -2, .terrain = .grass, .cut = true };
    try t.expectEqual(Verdict.charged, classify(tile, .{ .ok = grass }).?);
    try t.expectEqual(Verdict.already_cut, classify(tile, .{ .failed = .{ .already_cut = grass } }).?);
    try t.expect(classify(tile, .{ .failed = .server_busy }) == null);
    try t.expect(classify(.{ .x = 6, .y = -2 }, .{ .ok = grass }) == null);
    var network: Snapshot = .{ .status = .ready, .confirmed = .{ .x = 4, .y = -1 } };
    try t.expect(canCut(network, tile));
    network.pending = true;
    try t.expect(!canCut(network, tile));
}

test "browser hoe gates saved admission and explicit close on authoritative state" {
    const t = std.testing;
    var runtime: Runtime = .{ .record = .{ .id = @splat(1), .capacity = 10, .accepted = 0, .refund = 400, .admitted = false } };
    const record = &runtime.record.?;
    try t.expect(record.canReopen(false, 100));
    try t.expect(!record.canReopen(false, 101));
    try t.expect(!record.canReopen(true, 90));
    try t.expect(record.canPay(279));
    try t.expect(!record.canPay(280));
    record.admitted = true;
    try t.expect(!record.canReopen(false, 90));
    try t.expect(!runtime.canClose(90));
    record.accepted = 10;
    try t.expect(!runtime.canClose(90));
    runtime.server = 10;
    try t.expect(runtime.canClose(90));
}

test "browser hoe callback owns its bytes and drops stale or duplicate results" {
    const t = std.testing;
    var runtime: Runtime = .{ .generation = 4, .job = .{ .op = .inspect, .session = 1, .serial = 7, .started = 0 } };
    owner = &runtime;
    defer runtime.stop();
    var payload = "{}".*;
    deliver(1, 3, 7, &payload, payload.len);
    deliver(1, 4, 6, &payload, payload.len);
    try t.expect(runtime.response == null);
    deliver(1, 4, 7, &payload, payload.len);
    payload[0] = 'x';
    deliver(0, 4, 7, null, 0);
    try t.expect(runtime.response.?.ok);
    try t.expectEqualStrings("{}", runtime.bytes[0..runtime.response.?.len]);
    runtime.stop();
    deliver(1, 4, 7, &payload, payload.len);
    try t.expect(runtime.response == null);
}
