//! Desktop hoe play and refill coordinators. The wallet worker handles signing
//! and durable operations; these runtimes correlate replies and update the UI.
const std = @import("std");

const protocol = @import("shared").protocol;
const paid_cut = @import("paid_cut.zig");
const game_mod = @import("game.zig");
const ws = @import("ws_worker.zig");
const wallet = @import("wallet_service.zig");
const hoe = @import("wallet_commands.zig");
const Network = @import("ws_sync.zig").Snapshot;
const Game = game_mod.GameState;
const funding_ops = @import("hoe_funding.zig");
const ui = game_mod.HoeFundingUi;
const app_mint = @import("wallet.zig").cdk.app_mint;
pub const refill_debit_limit = hoe.refillDebitLimit(app_mint);

pub const enabled = hoe.enabled(app_mint, ws.endpoint_url);

pub const Runtime = struct {
    session: ?u64 = null,
    phase: union(enum) {
        checking,
        requirements: protocol.Id,
        bind: hoe.BindPlay,
        unfunded,
        active,
        depleted,
        reopen,
        query: Query,
        closing: protocol.Id,
        finalize: ?hoe.SenderProofs,
        recovery,
    } = .checking,
    job: ?struct { session: u64, kind: enum { bind, mark, finalize } } = null,
    confirmation_needed: bool = false,
    live: ?hoe.Live = null,
    local: ?hoe.PlayView = null,
    balance_id: ?[32]u8 = null,
    server: ?game_mod.HoeBalance = null,
    client: ?game_mod.HoeBalance = null,
    payment_pending: bool = false,
    cut: ?Cut = null,
    settled: bool = false,
    refill: ?struct { player: [33]u8, receiver: [33]u8, expires: u64 } = null,

    const Query = struct {
        request: ?protocol.Id = null,
        retry_at: u64 = 0,
        delay: u64 = 2,
    };

    const Cut = struct {
        session: u64,
        id: protocol.Id,
        tile: protocol.Location,
        phase: union(enum) { signing, sent, resolve: Verdict, resolving: Verdict } = .signing,
    };

    pub fn update(self: *Runtime, connection: *ws.Worker, network: Network, worker: ?*wallet.Worker, game: *Game, area_pending: bool, now: ?u64) void {
        defer game.paid_hoe.view = self.view(now);
        if (self.refill) |intent| if ((now orelse intent.expires) >= intent.expires) {
            self.refill = null;
        };
        const session = if (network.status == .ready) network.session else null;
        if (self.session != session) {
            self.session = session;
            self.phase = .checking;
            self.live = null;
            self.local = null;
            self.confirmation_needed = false;
            self.markStale();
            // A sent cut is never replayed. Leave its wallet reservation for
            // the next authoritative login or settlement to reconcile.
            if (self.cut != null and self.cut.?.phase == .sent) {
                self.cut = null;
                self.payment_pending = true;
            }
        }
        const w = worker orelse return;
        if (self.job) |job| {
            const result = w.takeHoe() orelse return;
            self.job = null;
            if (job.kind == .finalize and result == .settlement_finalized) {
                game.menu.wallet.balance_dirty = true;
                game.menu.wallet.history_dirty = true;
            }
            if (session == job.session) switch (job.kind) {
                .bind => {
                    if (result == .play_bound) self.applyBinding(result.play_bound) else self.phase = failed(result);
                },
                .mark => {
                    self.confirmation_needed = false;
                    if (result == .admission_marked and self.local != null and
                        std.meta.eql(result.admission_marked, self.local.?.id))
                    {
                        self.local.?.confirmed = true;
                    } else self.phase = failed(result);
                },
                .finalize => if (result == .settlement_finalized and self.local != null and
                    std.meta.eql(result.settlement_finalized.id, self.local.?.id))
                {
                    self.settled = true;
                    self.payment_pending = false;
                    self.useBalanceId(null);
                    self.phase = .checking;
                    // Refresh rather than letting the old login snapshot re-bind
                    // a released channel. Only a fresh bind may unlock funding.
                    connection.refreshAuth(job.session);
                    return;
                } else {
                    self.phase = failed(result);
                },
            };
        }
        if (self.cut != null) return self.updateCut(connection, w, game, area_pending, now);
        const current = session orelse return;
        if (self.confirmation_needed) {
            if (w.submitHoe(.{ .mark_admitted = .{ .session = current, .id = self.local.?.id } })) {
                self.job = .{ .session = current, .kind = .mark };
            }
            return;
        }
        if (self.local) |local| {
            while (connection.takeChannelSettled(current)) |id| {
                if (!std.meta.eql(id, local.id)) continue;
                switch (self.phase) {
                    .query => if (self.phase.query.request == null) {
                        self.phase.query.retry_at = 0;
                    },
                    .closing, .finalize => {},
                    else => self.startQuery(),
                }
            }
        }
        switch (self.phase) {
            .checking => {
                const login = connection.hoeLogin(current) orelse return;
                if (login.channel) |channel| {
                    self.useBalanceId(channel.id);
                    self.server = .{ .capacity = channel.capacity_msats, .accepted = channel.balance_msats };
                }
                const id = requestId(connection.io);
                if (connection.submitChannel(current, .channel_requirements, .{ .request_id = id, .payload = .{ .tool = .hoe } }) catch {
                    self.phase = .recovery;
                    return;
                }) self.phase = .{ .requirements = id };
            },
            .requirements => |id| if (connection.takeChannelFor(current, id)) |done| {
                if (done.outcome != .channel_requirements or done.outcome.channel_requirements != .ok) {
                    self.phase = .recovery;
                    return;
                }
                const login = connection.hoeLogin(current) orelse return;
                const terms = done.outcome.channel_requirements.ok;
                var server: hoe.Endpoint = .{};
                if (!server.set(ws.endpoint_url)) unreachable;
                self.live = .{ .server = server, .session = current, .requirements = terms };
                self.phase = .{ .bind = .{
                    .session = current,
                    .scope = .{ .server = server, .receiver = terms.pubkey, .player = login.player },
                    .active = if (login.channel) |channel| .{
                        .id = channel.id,
                        .capacity_msats = channel.capacity_msats,
                        .balance_msats = channel.balance_msats,
                    } else null,
                } };
            },
            .bind => |bind| if (w.submitHoe(.{ .bind_play = bind })) {
                self.job = .{ .session = current, .kind = .bind };
            },
            .query => self.updateStatus(connection, current, now orelse 0),
            .closing => |id| if (connection.takeChannelFor(current, id)) |done| {
                if (done.outcome != .channel_close) {
                    self.phase = .recovery;
                    return;
                }
                // A close click is single-use. Only read-only status can
                // confirm settlement and provide proofs.
                self.startQuery();
                if (done.outcome.channel_close == .failed) {
                    self.phase.query.retry_at = (now orelse 0) +| self.phase.query.delay;
                }
            },
            .finalize => |proofs| if (w.submitHoe(.{ .finalize_settled = .{
                .session = current,
                .id = self.local.?.id,
                .sender_proofs = proofs,
            } })) {
                self.job = .{ .session = current, .kind = .finalize };
            },
            else => {},
        }
    }

    fn useBalanceId(self: *Runtime, id: ?[32]u8) void {
        if (std.meta.eql(self.balance_id, id)) return;
        self.balance_id = id;
        self.server = null;
        self.client = null;
    }

    fn markStale(self: *Runtime) void {
        if (self.server) |*balance| balance.stale = true;
        if (self.client) |*balance| balance.stale = true;
    }

    fn applyBinding(self: *Runtime, local: ?hoe.PlayView) void {
        self.local = local;
        const bound = local orelse {
            self.useBalanceId(null);
            self.payment_pending = false;
            self.phase = .unfunded;
            return;
        };
        self.settled = false;
        self.useBalanceId(bound.id);
        if (bound.server_active) {
            self.applyActive(bound);
            if (bound.cuts_left == 0) self.startQuery();
        } else {
            self.client = .{ .capacity = bound.capacity_msats, .accepted = bound.confirmed_balance_msats };
            self.payment_pending = bound.payment_pending;
            self.startQuery();
        }
    }

    fn applyActive(self: *Runtime, active: hoe.PlayView) void {
        self.useBalanceId(active.id);
        self.local = active;
        self.client = .{ .capacity = active.capacity_msats, .accepted = active.confirmed_balance_msats };
        self.server = self.client;
        self.payment_pending = false;
        self.phase = if (active.cuts_left == 0) .depleted else .active;
    }

    fn startQuery(self: *Runtime) void {
        if (self.server) |*balance| balance.stale = true;
        self.phase = .{ .query = .{} };
    }

    fn updateStatus(self: *Runtime, connection: *ws.Worker, session: u64, now: u64) void {
        const local = self.local.?;
        const query = &self.phase.query;
        if (query.request) |id| {
            const done = connection.takeChannelFor(session, id) orelse return;
            if (done.outcome != .channel_status) {
                self.phase = .recovery;
                return;
            }
            switch (done.outcome.channel_status.view()) {
                .failed => |failure| switch (failure) {
                    .server_busy, .unavailable => self.retryStatus(now),
                    .not_found => {
                        self.server = null;
                        self.phase = if (!local.server_active and !local.confirmed and !self.payment_pending) .reopen else .recovery;
                    },
                    .invalid_request => self.phase = .recovery,
                },
                .ok => |status| {
                    if (status.capacity_msat != local.capacity_msats or status.balance_msat > status.capacity_msat) {
                        self.phase = .recovery;
                        return;
                    }
                    self.server = .{ .capacity = status.capacity_msat, .accepted = status.balance_msat };
                    switch (status.phase) {
                        .active => if (local.server_active) {
                            if (local.confirmed_balance_msats == status.balance_msat and local.cuts_left > 0) {
                                self.phase = .active;
                            } else {
                                self.phase = .recovery;
                                connection.refreshAuth(session);
                            }
                        } else {
                            // The ledger may have admitted the exact open but
                            // lost its profile link before acknowledging it.
                            self.phase = if (!local.confirmed and !self.payment_pending and status.balance_msat == 0) .reopen else .recovery;
                        },
                        .depleted => {
                            // The close did not start settlement. Let the player retry.
                            self.refill = null;
                            self.phase = if (status.balance_msat == status.capacity_msat) .depleted else .recovery;
                        },
                        .settlement_pending => self.retryStatus(now),
                        .settled => self.acceptSettlement(status.sender_proofs),
                        .sender_refund_required => self.phase = .recovery,
                    }
                    // A zero-balance orphan must still be eligible for the
                    // exact Open retry that repairs its server profile link.
                    self.confirmation_needed = !local.confirmed and self.phase != .reopen and self.phase != .finalize;
                },
            }
            return;
        }
        if (now < query.retry_at) return;
        const id = requestId(connection.io);
        if (connection.submitChannel(session, .channel_status, .{ .request_id = id, .payload = .{ .id = local.id } }) catch {
            self.phase = .recovery;
            return;
        }) query.request = id;
    }

    fn retryStatus(self: *Runtime, now: u64) void {
        const query = &self.phase.query;
        query.request = null;
        query.retry_at = now +| query.delay;
        query.delay = @min(query.delay * 2, 30);
    }

    fn acceptSettlement(self: *Runtime, proofs: ?[]const u8) void {
        var owned: hoe.SenderProofs = .{};
        if (proofs) |bytes| if (!owned.set(bytes)) {
            self.phase = .recovery;
            return;
        };
        self.phase = .{ .finalize = if (proofs != null) owned else null };
    }

    pub fn fundingLive(self: *const Runtime, session: u64) ?hoe.Live {
        return if (self.session == session and (self.phase == .unfunded or self.phase == .reopen)) self.live else null;
    }

    pub fn reopenId(self: *const Runtime) ?[32]u8 {
        return if (self.phase == .reopen) self.local.?.id else null;
    }

    fn canClose(self: *const Runtime) bool {
        const server = self.server orelse return false;
        const local = self.local orelse return false;
        return self.session != null and self.phase == .depleted and self.cut == null and !self.confirmation_needed and
            !server.stale and server.capacity == local.capacity_msats and server.capacity != 0 and
            server.accepted == server.capacity;
    }

    fn canRefill(self: *const Runtime) bool {
        return self.refill == null and self.live != null and (self.canClose() or self.phase == .unfunded);
    }

    /// Hand authorization to the funding runtime only after authoritative
    /// settlement and a fresh bind (or when there was no channel to close).
    pub fn takeRefill(self: *Runtime, connection: *ws.Worker, live: hoe.Live, now: ?u64) ?u64 {
        if (self.phase != .unfunded or self.session != live.session) return null;
        const intent = self.refill orelse return null;
        self.refill = null;
        const login = connection.hoeLogin(live.session) orelse return null;
        if (login.channel != null or (now orelse return null) >= intent.expires or
            !std.meta.eql(login.player, intent.player) or !std.meta.eql(live.requirements.pubkey, intent.receiver)) return null;
        return intent.expires;
    }

    pub fn click(self: *Runtime, connection: *ws.Worker, worker: ?*wallet.Worker, game: *Game, now: ?u64) void {
        if (game.paid_hoe.refill_requested) {
            game.paid_hoe.refill_requested = false;
            game.paid_hoe.target = null;
            defer game.paid_hoe.view = self.view(now);
            if (worker == null or !self.canRefill() or refill_debit_limit == 0) return;
            const current = self.session orelse return;
            const live = self.live orelse return;
            const login = connection.hoeLogin(current) orelse return;
            const timestamp = now orelse return;
            if (self.canClose()) {
                const id = requestId(connection.io);
                if (!(connection.submitChannel(current, .channel_close, .{
                    .request_id = id,
                    .payload = .{ .id = self.local.?.id },
                }) catch return)) return;
                self.phase = .{ .closing = id };
            } else if (login.channel != null) return;
            self.refill = .{ .player = login.player, .receiver = live.requirements.pubkey, .expires = timestamp +| 300 };
            return;
        }
        const tile = game.paid_hoe.target orelse return;
        game.paid_hoe.target = null;
        defer game.paid_hoe.view = self.view(now);
        if (self.view(now).status != .ready) return;
        const w = worker orelse return;
        const cut: Cut = .{ .session = self.session.?, .id = requestId(connection.io), .tile = tile };
        if (!canSend(connection.snapshot(), cut)) return;
        if (w.submitHoe(.{ .prepare_cut = .{ .session = cut.session, .id = cut.id, .tile = tile } })) self.cut = cut;
    }

    fn updateCut(self: *Runtime, connection: *ws.Worker, worker: *wallet.Worker, game: *Game, area_pending: bool, now: ?u64) void {
        const cut = &self.cut.?;
        const current = self.session == cut.session;
        switch (cut.phase) {
            .signing => {
                const result = worker.takeHoe() orelse return;
                if (result != .cut_prepared) {
                    if (current) self.phase = failed(result);
                    self.cut = null;
                    return;
                }
                const request = result.cut_prepared;
                // A signed request may outlive the connection, reach or expiry.
                // False from submitCut also guarantees it wasn't queued.
                cut.phase = if (current and self.phase == .active and canSend(connection.snapshot(), cut.*) and
                    now != null and now.? < self.local.?.refund_time and connection.submitCut(cut.session, request))
                    .sent
                else
                    .{ .resolve = .not_sent };
            },
            .sent => {
                // First consume any queued area snapshot that might predate the cut.
                if (area_pending) return;
                const outcome = connection.takeCut(cut.session, cut.id) orelse return;
                const verdict = classify(cut.tile, outcome);
                if (verdict == .uncertain) {
                    self.payment_pending = true;
                    self.markStale();
                    connection.refreshAuth(cut.session);
                    self.phase = .recovery;
                    self.cut = null;
                } else {
                    if (verdict == .charged) self.server.?.accepted += protocol.hoe_price_msat;
                    cut.phase = .{ .resolve = verdict };
                }
            },
            .resolve => |verdict| if (worker.submitHoe(.{ .resolve_cut = .{
                .session = cut.session,
                .id = cut.id,
                .resolution = if (verdict == .charged) .charged else .not_charged,
            } })) {
                cut.phase = .{ .resolving = verdict };
            },
            .resolving => |verdict| {
                if (current and verdict != .not_sent and area_pending) return;
                const result = worker.takeHoe() orelse return;
                const tile = cut.tile;
                const session = cut.session;
                self.cut = null;
                if (!current) return;
                if (result != .cut_resolved) {
                    self.payment_pending = verdict != .not_sent;
                    self.markStale();
                    self.phase = failed(result);
                    connection.refreshAuth(session);
                    return;
                }
                self.applyActive(result.cut_resolved);
                if (verdict == .not_sent) return;
                game.applyHoeCut(tile);
                if (verdict == .charged) {
                    game.cut_feedback.confirm(.{ .tile = tile, .refill_needed = result.cut_resolved.cuts_left == 0 });
                    const dx = direction(tile.x, game.player_pos.x);
                    const dy = direction(tile.y, game.player_pos.y);
                    game.player_animation.update(0, dx, dy, false, .hoe);
                }
            },
        }
    }

    fn view(self: *const Runtime, now: ?u64) game_mod.HoeView {
        var out: game_mod.HoeView = .{
            .server = self.server,
            .client = self.client,
            .payment_pending = self.payment_pending or self.cut != null,
            .can_refill = self.canRefill(),
        };
        if (self.session == null) {
            if (out.server != null or out.client != null or out.payment_pending) out.status = .checking;
            return out;
        }
        if (self.local) |local| {
            if (local.server_active) out.cuts_left = local.cuts_left;
        }
        if (self.server) |server| {
            if (!server.stale and server.accepted == server.capacity) out.cuts_left = 0;
        }
        if (self.cut != null) {
            out.status = .pending;
            if (self.cut.?.phase == .sent) {
                if (out.server) |*balance| balance.stale = true;
            }
            return out;
        }
        out.status = switch (self.phase) {
            .checking, .requirements, .bind => .checking,
            .unfunded => if (self.settled) .settled else .unavailable,
            .reopen => .checking,
            .query => if (self.phase.query.delay > 2) .settling else .checking,
            .closing, .finalize => .settling,
            .recovery => .recovery,
            .depleted => .empty,
            .active => if (now == null or now.? >= self.local.?.refund_time) .recovery else .ready,
        };
        return out;
    }
};

fn failed(result: hoe.Result) @FieldType(Runtime, "phase") {
    if (result == .failed) std.log.debug("paid hoe unavailable: {s}", .{@errorName(result.failed)});
    return .recovery;
}

fn requestId(io: std.Io) protocol.Id {
    var id: protocol.Id = undefined;
    io.random(&id);
    return id;
}

fn canSend(network: Network, cut: Runtime.Cut) bool {
    // Reach is checked against the server-confirmed position, not prediction.
    return network.status == .ready and network.session == cut.session and !network.pending and
        paid_cut.withinReach(cut.tile, network.confirmed);
}

fn direction(target: i32, origin: i32) i8 {
    return if (target < origin) -1 else if (target > origin) 1 else 0;
}

const Verdict = enum { charged, already_cut, uncertain, not_sent };

fn classify(tile: protocol.Location, outcome: protocol.Outcome(.cut)) Verdict {
    return switch (paid_cut.classify(tile, outcome) orelse return .uncertain) {
        .charged => .charged,
        .already_cut => .already_cut,
    };
}

/// Coordinates refill authorization and admission separately from cut and settlement state.
pub const FundingRuntime = struct {
    session: ?u64 = null,
    live: ?hoe.Live = null,
    phase: Phase = .idle,
    job: ?Job = null,

    reopen_id: ?[32]u8 = null,
    opening: ?Opening = null,
    retry_open: ?struct { channel: [32]u8, at: u64 } = null,
    wallet_dirty: bool = false,
    authorized_until: u64 = 0,

    const Continuation = struct { operation_id: funding_ops.OperationId, refund_time: ?u64 };
    const Phase = union(enum) {
        idle,
        requested,
        requirements: protocol.Id,
        inspecting,
        quote_failed,
        quoting,
        offer: hoe.Offer,
        funding: hoe.Offer,
        continuing: Continuation,

        funded: hoe.Open,
        opening,
        marking: [32]u8,
        unavailable,
        recovery,
    };
    const Job = struct {
        session: u64,
        mutates_wallet: bool,
    };
    const Opening = struct { session: u64, request: protocol.Id, channel: [32]u8 };

    pub fn update(self: *FundingRuntime, connection: *ws.Worker, network: Network, native: *Runtime, worker: ?*wallet.Worker, controller: *ui.Controller, now: ?u64) bool {
        const live = if (network.status == .ready) native.fundingLive(network.session) else null;
        const session = if (live) |terms| terms.session else null;
        const reopen_id = if (live != null) native.reopenId() else null;
        var reset = false;
        if (session != self.session or !std.meta.eql(reopen_id, self.reopen_id)) {
            self.session = session;
            self.live = live;
            self.reopen_id = reopen_id;
            self.phase = if (reopen_id != null) .inspecting else .idle;
            // The wallet's new play binding revokes the old offer.
            self.authorized_until = 0;
            reset = controller.publish(null);
        }
        if (self.opening) |pending| {
            // Still drain our request if a notice moved native out of reopen
            // without changing the transport session.
            if (network.status != .ready or network.session != pending.session) {
                self.opening = null;
            } else if (connection.takeChannelFor(pending.session, pending.request)) |done| {
                self.opening = null;
                if (session == pending.session and self.phase == .opening) {
                    if (done.outcome == .channel_open and done.outcome.channel_open == .ok) {
                        self.phase = .{ .marking = pending.channel };
                    } else {
                        self.hold(error.AdmissionNotConfirmed);
                        if (done.outcome == .channel_open and done.outcome.channel_open == .failed and
                            (done.outcome.channel_open.failed == .server_busy or done.outcome.channel_open.failed == .unavailable))
                        {
                            connection.refreshAuth(pending.session);
                            return controller.publish(null) or reset;
                        }
                    }
                } else if (done.outcome == .channel_open and done.outcome.channel_open == .ok) {
                    connection.refreshAuth(pending.session);
                    return controller.publish(null) or reset;
                }
            }
        }
        if (self.job) |job| {
            if (worker) |w| if (w.takeHoe()) |result| {
                self.job = null;
                self.wallet_dirty = self.wallet_dirty or job.mutates_wallet;
                if (session == job.session) {
                    self.completeWallet(connection, job.session, result, now);
                } else if (result == .admission_marked) {
                    connection.refreshAuth(job.session);
                }
            };
        }
        const current = session orelse return controller.publish(null) or reset;
        if (!stillUnfunded(connection, current)) return controller.publish(null) or reset;
        if (controller.canStart() and self.job == null) {
            if (native.takeRefill(connection, self.live.?, now)) |expires| {
                self.authorized_until = expires;
                self.phase = .requested;
            }
        }
        switch (self.phase) {
            .requested => {
                const id = requestId(connection.io);
                if (connection.submitChannel(current, .channel_requirements, .{
                    .request_id = id,
                    .payload = .{ .tool = .hoe },
                }) catch {
                    self.phase = .unavailable;
                    return controller.publish(.unavailable) or reset;
                }) self.phase = .{ .requirements = id };
            },
            .requirements => |id| if (connection.takeChannelFor(current, id)) |done| {
                const live_terms = &self.live.?.requirements;
                if (done.outcome == .channel_requirements and done.outcome.channel_requirements == .ok) {
                    const fresh = done.outcome.channel_requirements.ok;
                    if (std.meta.eql(live_terms.pubkey, fresh.pubkey) and fresh.amount == funding_ops.price_msats and usableExpiry(now, fresh.refundTime)) {
                        live_terms.* = fresh;
                        self.phase = .inspecting;
                        return controller.publish(self.status()) or reset;
                    }
                }
                self.phase = .unavailable;
            },
            .inspecting => if (self.job == null) {
                if (worker) |w| {
                    _ = self.submit(w, current, .{ .inspect = self.live.? });
                } else self.phase = .unavailable;
            },
            .quoting => if (self.job == null) {
                if (worker) |w| {
                    _ = self.submit(w, current, .{ .quote = self.live.? });
                } else self.phase = .unavailable;
            },
            .continuing => |pending| if (self.job == null) {
                if (worker) |w| {
                    _ = self.submit(w, current, if (pending.refund_time != null)
                        .{ .resume_funding = .{ .live = self.live.?, .operation_id = pending.operation_id } }
                    else
                        .{ .recover_funding = .{ .live = self.live.?, .operation_id = pending.operation_id } });
                } else self.phase = .recovery;
            },
            .marking => |id| if (self.job == null) {
                if (worker) |w| {
                    _ = self.submit(w, current, .{ .mark_admitted = .{ .session = current, .id = id } });
                } else self.phase = .recovery;
            },
            .offer => |offer| {
                if (self.consentRequest(offer, now)) |request| {
                    if (worker) |w| {
                        if (self.submit(w, current, request)) {
                            self.authorized_until = 0;
                            self.phase = .{ .funding = offer };
                        }
                    } else self.phase = .unavailable;
                } else self.phase = .quote_failed;
            },
            .funded => self.open(connection, current, &self.phase.funded, now),
            else => {},
        }
        return controller.publish(self.status()) or reset;
    }

    fn consentRequest(self: *const FundingRuntime, offer: hoe.Offer, now: ?u64) ?hoe.Request {
        const live = self.live orelse return null;
        const timestamp = now orelse return null;
        if (self.reopen_id != null or timestamp >= self.authorized_until or
            !validOffer(live, offer) or offer.max_debit_msats > refill_debit_limit or
            !usableExpiry(timestamp, offer.requirements.refundTime) or
            live.requirements.refundTime != offer.requirements.refundTime) return null;
        return .{ .fund_with_consent = .{ .live = live, .offer = offer } };
    }

    fn submit(self: *FundingRuntime, worker: *wallet.Worker, session: u64, request: hoe.Request) bool {
        if (!worker.submitHoe(request)) return false;
        self.job = .{
            .session = session,
            .mutates_wallet = switch (request) {
                .fund_with_consent, .resume_funding, .recover_funding => true,
                else => false,
            },
        };
        return true;
    }

    fn completeWallet(self: *FundingRuntime, connection: *ws.Worker, session: u64, result: hoe.Result, now: ?u64) void {
        if (!stillUnfunded(connection, session)) return;
        const live = self.live orelse return;
        // Copy first: Zig initializes the destination union tag before its
        // payload, so the old payload must not be read from the destination.
        const previous = self.phase;
        self.phase = switch (result) {
            .pending => |saved| if (previous == .inspecting) self.inspect(saved, live, now) else .recovery,
            .quoted => |offer| if (previous == .quoting and validOffer(live, offer) and usableExpiry(now, offer.requirements.refundTime))
                .{ .offer = offer }
            else
                .unavailable,
            .funded => |funded| blk: {
                const matched = switch (previous) {
                    .funding => |offer| funded.capacity_msats == offer.capacity_msats and funded.refund_time == offer.requirements.refundTime,
                    .continuing => |pending| std.meta.eql(funded.operation_id, pending.operation_id) and
                        (pending.refund_time == null or funded.refund_time == pending.refund_time.?),
                    else => false,
                };
                if (matched and self.matchesOpen(funded, now)) break :blk .{ .funded = funded };
                return self.hold(error.UnexpectedFundingResult);
            },
            .admission_marked => |id| blk: {
                if (previous != .marking or !std.meta.eql(id, previous.marking)) break :blk .recovery;
                // An ACK records admission, not a balance. Re-auth before play.
                connection.refreshAuth(session);
                break :blk .opening;
            },
            .failed => |err| blk: {
                logError(err);
                if (previous == .marking) connection.refreshAuth(session);
                break :blk if (previous == .quoting or (previous == .funding and
                    (err == error.QuoteChanged or err == error.SenderFeeLimitExceeded or err == error.InsufficientBalance)))
                    .quote_failed
                else
                    .recovery;
            },
            else => .recovery,
        };
    }

    fn inspect(self: *const FundingRuntime, saved: hoe.Pending, live: hoe.Live, now: ?u64) Phase {
        return switch (saved) {
            .idle => if (self.reopen_id == null) .quoting else .recovery,
            .confirmed => |pending| if (self.reopen_id == null and validOffer(live, pending.offer) and usableExpiry(now, pending.offer.requirements.refundTime))
                .{ .continuing = .{ .operation_id = pending.operation_id, .refund_time = pending.offer.requirements.refundTime } }
            else
                .recovery,
            .funded => |funded| if (self.reopen_id != null and self.matchesOpen(funded, now))
                .{ .funded = funded }
            else
                .recovery,
            .recovery => |pending| if (pending.phase == .funding_started and pending.operation_id != null)
                .{ .continuing = .{ .operation_id = pending.operation_id.?, .refund_time = null } }
            else
                .recovery,
            .other_context => .recovery,
        };
    }

    fn matchesOpen(self: *const FundingRuntime, open_payload: hoe.Open, now: ?u64) bool {
        return protocol.validHoeCapacity(open_payload.capacity_msats) and usableExpiry(now, open_payload.refund_time) and
            (self.reopen_id == null or std.meta.eql(self.reopen_id.?, open_payload.id));
    }

    fn open(self: *FundingRuntime, connection: *ws.Worker, session: u64, funded: *const hoe.Open, now: ?u64) void {
        if (self.opening != null) return;
        const timestamp = now orelse return;
        if (!self.matchesOpen(funded.*, timestamp) or !stillUnfunded(connection, session)) return self.hold(error.AdmissionUnavailable);
        if (self.retry_open) |retry| {
            if (std.meta.eql(retry.channel, funded.id) and timestamp < retry.at) return;
        }
        const id = requestId(connection.io);
        if (!(connection.submitChannel(session, .channel_open, .{ .request_id = id, .payload = funded.payload() }) catch |err|
            return self.hold(err))) return;
        self.opening = .{ .session = session, .request = id, .channel = funded.id };
        self.retry_open = .{ .channel = funded.id, .at = timestamp +| 5 };
        self.phase = .opening;
    }

    fn hold(self: *FundingRuntime, err: anyerror) void {
        logError(err);
        self.phase = .recovery;
    }

    fn status(self: *const FundingRuntime) ?ui.Status {
        return switch (self.phase) {
            .idle => null,
            .requested, .requirements, .inspecting, .quoting, .offer => .checking,
            .quote_failed => .quote_failed,
            .funding, .continuing => .funding,

            .funded, .opening, .marking => .opening,
            .unavailable => .unavailable,
            .recovery => .recovery,
        };
    }
};

fn usableExpiry(now: ?u64, expiry: u64) bool {
    // Server admission requires at least five minutes remaining.
    return expiry -| (now orelse return false) > funding_ops.min_open_remaining_seconds;
}

fn validOffer(live: hoe.Live, offer: hoe.Offer) bool {
    return live.requirements.amount == funding_ops.price_msats and offer.requirements.amount == live.requirements.amount and
        std.meta.eql(live.requirements.pubkey, offer.requirements.pubkey) and protocol.validHoeCapacity(offer.capacity_msats) and
        offer.capacity_msats <= offer.nominal_msats and offer.nominal_msats <= offer.send_msats and
        offer.send_msats <= offer.max_debit_msats and offer.max_sender_fee_msats == offer.max_debit_msats - offer.send_msats;
}

fn stillUnfunded(connection: *ws.Worker, session: u64) bool {
    if (connection.hoeChannel(session) != null) return false;
    const network = connection.snapshot();
    return network.status == .ready and network.session == session;
}

fn logError(err: anyerror) void {
    std.log.debug("hoe funding: {s}", .{@errorName(err)});
}

test "a signed cut is not sent after the login or reach has changed" {
    const cut: Runtime.Cut = .{ .session = 1, .id = @splat(2), .tile = .{ .x = 2, .y = 3 } };
    var network: Network = .{ .status = .ready, .session = 1, .confirmed = .{ .x = 3, .y = 3 } };
    try std.testing.expect(canSend(network, cut));
    network.session += 1;
    try std.testing.expect(!canSend(network, cut));
    network.session = cut.session;
    network.confirmed.x += 1;
    try std.testing.expect(!canSend(network, cut));
}

test "refill closes only after a click and exact fresh zero, then retries only status" {
    const t = std.testing;
    const channel = testLocal(true, 50);
    var rt: Runtime = .{ .session = 1, .live = .{ .server = .{}, .session = 1, .requirements = .{ .pubkey = @splat(2), .amount = protocol.hoe_price_msat, .refundTime = 1000 } } };
    rt.applyActive(channel);
    var game = try Game.init(t.allocator, 800, 600);
    defer game.deinit();
    const network: Network = .{ .status = .ready, .session = 1 };
    var connection: ws.Worker = .{ .io = t.io, .paths = undefined, .state = network, .auth_player = @splat(3) };
    var worker: wallet.Worker = .{ .paths = undefined };

    rt.update(&connection, network, &worker, &game, false, 100);
    try t.expect(game.paid_hoe.view.can_refill);
    try t.expect(connection.channel == .idle);

    rt.server.?.accepted -= 1; // Zero whole cuts, but not zero remaining balance.
    game.paid_hoe.refill_requested = true;
    rt.click(&connection, &worker, &game, 100);
    try t.expect(!game.paid_hoe.refill_requested and connection.channel == .idle);
    rt.server.?.accepted += 1;
    rt.server.?.stale = true;
    game.paid_hoe.refill_requested = true;
    rt.click(&connection, &worker, &game, 100);
    try t.expect(!game.paid_hoe.refill_requested and connection.channel == .idle);

    for ([_]protocol.Outcome(.channel_close){ .{ .ok = {} }, .{ .failed = .settlement_pending } }) |outcome| {
        rt.applyActive(channel);
        game.paid_hoe.refill_requested = true;
        rt.click(&connection, &worker, &game, 100);
        try t.expect(!game.paid_hoe.refill_requested and !game.paid_hoe.view.can_refill);
        try t.expectEqual(protocol.Kind.channel_close, connection.channel.queued.kind);
        try t.expect(rt.refill != null and rt.takeRefill(&connection, rt.live.?, 100) == null);
        const id = connection.channel.queued.id;
        connection.channel = .{ .received = .{ .request_id = id, .outcome = .{ .channel_close = outcome } } };
        rt.update(&connection, network, &worker, &game, false, 100);
        try t.expect(rt.phase == .query and rt.job == null and !rt.canClose());
        if (outcome == .failed) {
            rt.update(&connection, network, &worker, &game, false, 101);
            try t.expect(connection.channel == .idle);
        }
        rt.update(&connection, network, &worker, &game, false, if (outcome == .ok) 100 else 102);
        try t.expectEqual(protocol.Kind.channel_status, connection.channel.queued.kind);
        const status_id = connection.channel.queued.id;
        connection.channel = .{ .received = .{
            .request_id = status_id,
            .outcome = .{ .channel_status = .{ .ok = .{
                .capacity_msat = channel.capacity_msats,
                .balance_msat = channel.capacity_msats,
                .phase = .depleted,
            } } },
        } };
        rt.update(&connection, network, &worker, &game, false, 102);
        rt.update(&connection, network, &worker, &game, false, 103);
        try t.expect(rt.canRefill() and connection.channel == .idle);
    }
}

test "only a local channel needing recovery is queried on bind, and it gates funding" {
    const t = std.testing;
    const live: hoe.Live = .{ .server = .{}, .session = 1, .requirements = .{
        .pubkey = @splat(1),
        .amount = 5,
        .refundTime = 1000,
    } };
    var rt: Runtime = .{ .session = 1, .live = live };
    rt.applyBinding(testLocal(true, 5));
    try t.expect(rt.phase == .active and rt.fundingLive(1) == null);
    rt.applyBinding(testLocal(true, 50));
    try t.expect(rt.phase == .query and !rt.canClose());
    rt.applyBinding(testLocal(false, 0));
    try t.expect(rt.phase == .query and rt.fundingLive(1) == null);
    rt.applyBinding(null);
    try t.expectEqual(live, rt.fundingLive(1).?);
    try t.expect(rt.fundingLive(2) == null);
}

test "only a matching settlement notice triggers status and forwards its owned receipt" {
    const t = std.testing;
    var rt: Runtime = .{ .session = 1 };
    rt.applyActive(testLocal(true, 5));
    var game = try Game.init(t.allocator, 800, 600);
    defer game.deinit();
    const network: Network = .{ .status = .ready, .session = 1 };
    var connection: ws.Worker = .{ .io = t.io, .paths = undefined, .state = network };
    var worker: wallet.Worker = .{ .paths = undefined };
    connection.settled_ids[0] = @splat(9);
    connection.settled_count = 1;
    rt.update(&connection, network, &worker, &game, false, 100);
    try t.expect(connection.channel == .idle);

    connection.settled_ids[0] = rt.local.?.id;
    connection.settled_count = 1;
    rt.update(&connection, network, &worker, &game, false, 100);
    try t.expectEqual(protocol.Kind.channel_status, connection.channel.queued.kind);
    const request = connection.channel.queued.id;
    var receipt: ws.ChannelStatusOutcome = .{ .ok = .{
        .capacity_msat = 50,
        .balance_msat = 5,
        .phase = .settled,
        .len = 2,
    } };
    @memcpy(receipt.ok.bytes[0..2], "[]");
    connection.channel = .{ .received = .{ .request_id = request, .outcome = .{ .channel_status = receipt } } };
    rt.update(&connection, network, &worker, &game, false, 100);
    try t.expect(rt.phase == .finalize and !rt.canClose());
    connection.channel = .idle;
    rt.update(&connection, network, &worker, &game, false, 100);
    const command = worker.request.hoe.finalize_settled;
    try t.expectEqual(rt.local.?.id, command.id);
    try t.expectEqualStrings("[]", command.sender_proofs.?.slice());
}

fn testLocal(active: bool, accepted: u64) hoe.PlayView {
    return .{
        .id = @splat(2),
        .capacity_msats = 50,
        .refund_time = 1000,
        .confirmed = true,
        .server_active = active,
        .cuts_left = if (active) (50 - accepted) / 5 else 0,
        .confirmed_balance_msats = accepted,
    };
}

test "only matching authoritative grass states reconcile a cut reply" {
    const t = std.testing;
    const tile: protocol.Location = .{ .x = -4, .y = 8 };
    var state: protocol.State = .{ .x = tile.x, .y = tile.y, .terrain = .grass, .cut = true };
    try t.expectEqual(Verdict.charged, classify(tile, .{ .ok = state }));
    try t.expectEqual(Verdict.already_cut, classify(tile, .{ .failed = .{ .already_cut = state } }));
    try t.expectEqual(Verdict.uncertain, classify(tile, .{ .failed = .server_busy }));
    state.x += 1;
    try t.expectEqual(Verdict.uncertain, classify(tile, .{ .ok = state }));
    try t.expect(!paid_cut.withinReach(.{ .x = std.math.minInt(i32), .y = 8 }, .{ .x = std.math.maxInt(i32), .y = 8 }));
    try t.expect(paid_cut.withinReach(tile, .{ .x = -3, .y = 9 }));
}

test "refill authorizes only a fresh affordable offer within the displayed cap" {
    const t = std.testing;
    if (!enabled) return error.SkipZigTest;
    const live = testLive();
    var offer = testOffer(live);
    var rt: FundingRuntime = .{ .live = live };
    try t.expectEqual(null, rt.consentRequest(offer, 100));
    rt.authorized_until = 400;
    offer.max_debit_msats = refill_debit_limit + 1;
    offer.max_sender_fee_msats = offer.max_debit_msats - offer.send_msats;
    try t.expectEqual(null, rt.consentRequest(offer, 100));
    offer.capacity_msats = 35;
    offer.nominal_msats = 35;
    offer.send_msats = 35;
    offer.max_sender_fee_msats = 0;
    offer.max_debit_msats = 35;
    try t.expectEqual(offer, rt.consentRequest(offer, 100).?.fund_with_consent.offer);
    try t.expectEqual(null, rt.consentRequest(offer, 400));
    offer.requirements.refundTime += 1;
    try t.expectEqual(null, rt.consentRequest(offer, 100));
}

test "one refill click closes first and funds once after a fresh unfunded login" {
    if (!enabled) return error.SkipZigTest;
    const t = std.testing;
    var live = testLive();
    var native: Runtime = .{
        .session = live.session,
        .live = live,
        .phase = .depleted,
        .server = .{ .capacity = 35, .accepted = 35 },
        .local = .{
            .id = @splat(2),
            .capacity_msats = 35,
            .confirmed_balance_msats = 35,
            .confirmed = true,
            .server_active = true,
            .refund_time = 1000,
            .cuts_left = 0,
        },
    };
    var game = try Game.init(t.allocator, 800, 600);
    defer game.deinit();
    var connection: ws.Worker = .{
        .io = t.io,
        .paths = undefined,
        .state = .{ .status = .ready, .session = live.session },
        .auth_player = @splat(3),
    };
    var worker: wallet.Worker = .{ .paths = undefined };
    var rt: FundingRuntime = .{};
    game.paid_hoe.refill_requested = true;
    native.click(&connection, &worker, &game, 100);
    try t.expectEqual(protocol.Kind.channel_close, connection.channel.queued.kind);
    _ = rt.update(&connection, connection.state, &native, &worker, &game.hoe_funding, 100);
    try t.expect(worker.state.load(.acquire) == .idle);

    // Settlement finalization has released the old channel, and the new
    // authenticated wallet binding reports no current channel.
    connection.channel = .idle;
    live.session += 1;
    connection.state.session = live.session;
    native.session = live.session;
    native.live = live;
    native.local = null;
    native.phase = .unfunded;
    _ = rt.update(&connection, connection.state, &native, &worker, &game.hoe_funding, 101);
    try t.expectEqual(protocol.Kind.channel_requirements, connection.channel.queued.kind);
    const requirements_id = connection.channel.queued.id;
    connection.channel = .{ .received = .{
        .request_id = requirements_id,
        .outcome = .{ .channel_requirements = .{ .ok = live.requirements } },
    } };
    _ = rt.update(&connection, connection.state, &native, &worker, &game.hoe_funding, 101);
    _ = rt.update(&connection, connection.state, &native, &worker, &game.hoe_funding, 101);
    try t.expect(worker.request.hoe == .inspect);
    worker.hoe_result = .{ .pending = .idle };
    worker.state.store(.result, .release);
    _ = rt.update(&connection, connection.state, &native, &worker, &game.hoe_funding, 102);
    try t.expect(worker.request.hoe == .quote);
    const offer: hoe.Offer = .{
        .id = @splat(4),
        .requirements = live.requirements,
        .capacity_msats = 35,
        .nominal_msats = 35,
        .send_msats = 35,
        .max_sender_fee_msats = 0,
        .max_debit_msats = 35,
        .keyset_hash = @splat(0),
    };
    worker.hoe_result = .{ .quoted = offer };
    worker.state.store(.result, .release);
    _ = rt.update(&connection, connection.state, &native, &worker, &game.hoe_funding, 103);
    try t.expectEqual(offer, worker.request.hoe.fund_with_consent.offer);

    // A changed quote cannot turn the same click into a second spend attempt.
    worker.hoe_result = .{ .failed = error.QuoteChanged };
    worker.state.store(.result, .release);
    _ = rt.update(&connection, connection.state, &native, &worker, &game.hoe_funding, 104);
    _ = rt.update(&connection, connection.state, &native, &worker, &game.hoe_funding, 105);
    try t.expectEqual(ui.Status.quote_failed, game.hoe_funding.status.?);
    try t.expect(worker.state.load(.acquire) == .idle);
}

test "saved admission opens without UI consent and records its acknowledgement" {
    const t = std.testing;
    const id: [32]u8 = @splat(2);
    const live = testLive();
    var native: Runtime = .{ .session = live.session, .live = live, .phase = .reopen, .local = .{
        .id = id,
        .capacity_msats = funding_ops.capacity_msats,
        .confirmed_balance_msats = 0,
        .confirmed = false,
        .server_active = false,
        .refund_time = 1000,
        .cuts_left = 0,
    } };
    var saved: hoe.Open = .{ .id = id, .operation_id = @splat(1), .capacity_msats = funding_ops.capacity_msats, .refund_time = 1000 };
    try t.expect(saved.params.set("{}"));
    try t.expect(saved.proof.set("[]"));
    var rt: FundingRuntime = .{ .session = live.session, .live = live, .reopen_id = id, .phase = .{ .funded = saved } };
    const network: Network = .{ .status = .ready, .session = live.session };
    var connection: ws.Worker = .{ .io = t.io, .paths = undefined, .state = network };
    var worker: wallet.Worker = .{ .paths = undefined };
    var controller: ui.Controller = .{};
    _ = rt.update(&connection, network, &native, &worker, &controller, 100);
    try t.expect(!controller.canStart());
    try t.expectEqual(protocol.Kind.channel_open, connection.channel.queued.kind);
    const request = connection.channel.queued.id;
    connection.channel = .{ .received = .{ .request_id = request, .outcome = .{ .channel_open = .{ .ok = {} } } } };
    _ = rt.update(&connection, network, &native, &worker, &controller, 100);
    try t.expect(rt.job != null);
    try t.expectEqual(id, worker.request.hoe.mark_admitted.id);
}

test "configured desktop mint and server enable hoe funding" {
    try std.testing.expect(enabled);
}

test "reopen only offers matching confirmed funding or non-spending saved admission" {
    const t = std.testing;
    const live = testLive();
    const offer = testOffer(live);
    const confirmed: hoe.Pending = .{ .confirmed = .{ .offer = offer, .operation_id = @splat(1) } };
    const opened: hoe.Pending = .{ .funded = .{ .id = @splat(2), .operation_id = @splat(1), .capacity_msats = 50, .refund_time = 1000 } };
    var rt: FundingRuntime = .{};
    try t.expect(rt.inspect(.idle, live, 100) == .quoting);
    try t.expect(rt.inspect(.other_context, live, 100) == .recovery);
    try t.expect(rt.inspect(.{ .recovery = .{ .phase = .sending } }, live, 100) == .recovery);

    const journaled: hoe.Pending = .{ .recovery = .{ .phase = .funding_started, .operation_id = @splat(1) } };
    try t.expectEqual(null, rt.inspect(journaled, live, 100).continuing.refund_time);
    var changed = live;
    changed.requirements.refundTime += 1;
    const continuation = rt.inspect(confirmed, changed, 100).continuing;
    try t.expectEqual(confirmed.confirmed.operation_id, continuation.operation_id);
    try t.expectEqual(offer.requirements.refundTime, continuation.refund_time.?);
    changed.requirements.pubkey[1] += 1;
    try t.expect(rt.inspect(confirmed, changed, 100) == .recovery);
    try t.expect(rt.inspect(opened, live, 100) == .recovery);
    rt.reopen_id = opened.funded.id;
    try t.expect(rt.inspect(opened, live, 100) == .funded);
    try t.expect(rt.inspect(opened, live, 1000) == .recovery);
    try t.expect(rt.inspect(.idle, live, 100) == .recovery);
    try t.expect(rt.inspect(confirmed, live, 100) == .recovery);
    rt.reopen_id = @splat(3);
    try t.expect(rt.inspect(opened, live, 100) == .recovery);
}

fn testLive() hoe.Live {
    return .{ .server = .{}, .session = 1, .requirements = .{ .pubkey = @splat(8), .refundTime = 1000, .amount = funding_ops.price_msats } };
}

fn testOffer(live: hoe.Live) hoe.Offer {
    return .{ .id = @splat(1), .requirements = live.requirements, .capacity_msats = 50, .nominal_msats = 52, .send_msats = 53, .max_sender_fee_msats = 2, .max_debit_msats = 55, .keyset_hash = @splat(0) };
}
