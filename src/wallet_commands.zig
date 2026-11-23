//! Desktop wallet commands, executed serially by the wallet service. The caller
//! holds the wallet instance lock and supplies authenticated terms and consent
//! for hoe channel operations.
const std = @import("std");
const protocol = @import("shared").protocol;
const channels = @import("spilman_client_store.zig");

const wallet = @import("wallet.zig");
const Signer = @import("ws_auth.zig").Signer;
const ops_mod = @import("hoe_wallet_ops.zig");
const funding = @import("hoe_funding.zig");

const ui = @import("wallet_ui.zig");
const Text = ui.Text;

pub const ScreenResult = Text(128 * 1024);

pub fn executeScreen(io: std.Io, paths: wallet.Paths, owner: *?wallet.Wallet, request: *const ui.Request, output: *ScreenResult) !bool {
    const allocator = std.heap.page_allocator;
    if (request.operation == .open and owner.* == null) {
        const inspection = try wallet.inspect(io, allocator, paths, true);
        owner.* = inspection.wallet orelse return error.Unavailable;
    }
    const handle = if (owner.*) |*w| try w.borrowHandle() else return error.Unavailable;
    if (request.operation == .create) {
        var added = wallet.cdk.c.cdk_wallet_add_mint(handle, wallet.cdk.app_mint.ptr);
        try wallet.check(&added);
    }
    const operation: [:0]const u8 = switch (request.operation) {
        .open, .snapshot => "wallet_screen",
        .create => "create_deposit",
        .check, .recover, .poll => "deposit_update",
        .saved_invoice => "saved_invoice",
        .history => "quote_history_page",
        .resume_saved => "resume_deposit",
        .prepare_withdrawal => "prepare_withdrawal",
        .confirm_withdrawal => "confirm_withdrawal",
        .cancel_withdrawal => "cancel_withdrawal",
        .saved_withdrawal => "saved_withdrawal",
        .poll_withdrawals => "poll_withdrawals",
    };
    const args = if (request.operation == .check or request.operation == .poll or request.operation == .recover)
        try std.json.Stringify.valueAlloc(allocator, .{ wallet.cdk.app_mint, @tagName(request.operation), request.argument.slice() }, .{})
    else if (request.operation == .history)
        try std.json.Stringify.valueAlloc(allocator, .{request.argument.slice()}, .{})
    else if (request.operation == .open or request.operation == .snapshot or request.operation == .resume_saved)
        try std.json.Stringify.valueAlloc(allocator, .{wallet.cdk.app_mint}, .{})
    else
        try std.json.Stringify.valueAlloc(allocator, .{ wallet.cdk.app_mint, request.argument.slice() }, .{});
    defer allocator.free(args);
    const args_z = try allocator.dupeSentinel(u8, args, 0);
    defer allocator.free(args_z);
    var result = wallet.cdk.c.cdk_wallet_quotes(handle, operation.ptr, args_z.ptr);
    defer wallet.cdk.c.cdk_string_free(result.value);
    if (request.operation.isWithdrawal() and result.status >= 1 and result.status <= 27) {
        // check consumes only the Rust-owned error; the payload is freed by the defer above.
        wallet.check(&result) catch {};
        var buf: [256]u8 = undefined;
        return output.set(try std.fmt.bufPrint(&buf, "{{\"operation_error\":{{\"status\":{d},\"message\":\"Withdrawal request failed\"}}}}", .{result.status}));
    }
    try wallet.check(&result);
    const value = result.value orelse return error.Unavailable;
    return output.set(std.mem.span(@as([*:0]const u8, @ptrCast(value))));
}

// Hoe channel commands.

pub const Offer = ops_mod.Offer;

pub const Endpoint = Text(32);
pub const Live = struct {
    /// Copy the actual configured WebSocket endpoint, not a server-supplied label.
    server: Endpoint,
    session: u64,
    requirements: protocol.SpillmanChannelRequirementsRes,
};

pub const PlayScope = struct {
    server: Endpoint,
    receiver: [33]u8,
    /// Authenticated x-only identity encoded as a compressed public key.
    player: [33]u8,
};

pub const BindPlay = struct {
    session: u64,
    scope: PlayScope,
    active: ?struct {
        id: channels.Id,
        capacity_msats: u64,
        balance_msats: u64,
    } = null,
};

pub const SenderProofs = Text(protocol.max_sender_change_proofs_bytes);

pub const PlayView = struct {
    id: channels.Id,
    /// Durable evidence of admission, not evidence that the server is still open.
    confirmed: bool,
    /// Only an authenticated active login permits signing cuts.
    server_active: bool,
    refund_time: u64,
    cuts_left: u64,
    capacity_msats: u64,
    /// Last locally confirmed cumulative cut amount.
    confirmed_balance_msats: u64,
    payment_pending: bool = false,
};

pub const Request = union(enum) {
    bind_play: BindPlay,
    /// Only after an authenticated open acknowledgement or status for this ID.
    mark_admitted: struct { session: u64, id: channels.Id },
    /// Only for a correlated, authenticated settled reply. Null proofs mean
    /// the server confirmed that there is no sender change.
    finalize_settled: struct { session: u64, id: channels.Id, sender_proofs: ?SenderProofs },
    prepare_cut: struct { session: u64, id: protocol.Id, tile: protocol.Location },
    resolve_cut: struct { session: u64, id: protocol.Id, resolution: HoePayment.State.Resolution },
    /// Returns the largest affordable whole-cut offer, up to ten cuts. Does
    /// not reserve or spend money. First use can open the existing CDK wallet
    /// (with its standard startup recovery) and initialize local storage.
    quote: Live,
    /// Pass the quoted Offer unchanged. Consent covers its exact capacity,
    /// send and funding swap; funding never substitutes a different quote.
    fund_with_consent: struct { live: Live, offer: Offer },
    /// Continue a previously authorized, confirmed send; cannot send again.
    resume_funding: struct { live: Live, operation_id: funding.OperationId },
    /// Explicit recovery of the exact journal. Uses the live scope, not new
    /// offer terms; does not create a send or resubmit the swap.
    recover_funding: struct { live: Live, operation_id: funding.OperationId },

    /// Inspect the durable marker; never continue it automatically. An error
    /// here is not evidence of an idle wallet.
    inspect: Live,
};

pub const Open = struct {
    id: [32]u8,
    operation_id: funding.OperationId,
    capacity_msats: u64,
    refund_time: u64,
    params: Text(protocol.max_channel_params_bytes) = .{},
    proof: Text(protocol.max_channel_proof_bytes) = .{},

    /// Borrows only from this copy; keep it alive through wire encoding.
    pub fn payload(self: *const Open) protocol.SpillmanChannelOpen {
        return .{ .id = self.id, .params = self.params.slice(), .proof = self.proof.slice() };
    }

    fn copy(channel: anytype) !Open {
        var out: Open = .{
            .id = channel.id,
            .operation_id = channel.operation_id,
            .capacity_msats = channel.capacity_msats,
            .refund_time = channel.refund_time,
        };
        if (!out.params.set(channel.params_json) or !out.proof.set(channel.funding_proofs_json)) return error.InvalidOpenPayload;
        return out;
    }
};

pub const Pending = union(enum) {
    idle,
    /// The wallet-wide marker belongs to a different server, key or policy.
    other_context,
    confirmed: struct { offer: Offer, operation_id: funding.OperationId },
    recovery: struct {
        // Only funding_started has a matching funding journal.
        phase: enum { sending, send_failed, funding_started },
        operation_id: ?funding.OperationId = null,
    },
    /// A durable local record, not confirmation of server admission.
    funded: Open,
};

pub const Result = union(enum) {
    quoted: Offer,

    funded: Open,
    pending: Pending,
    play_bound: ?PlayView,
    admission_marked: channels.Id,
    settlement_finalized: struct { id: channels.Id, credited_msats: u64 },
    cut_prepared: protocol.RequestFor(.cut),
    cut_resolved: PlayView,
    failed: anyerror,
};

pub const State = struct {
    signer: Signer = .{},
    // Scoped to the play binding; bindPlay clears it even on a failed rebind.
    ops: ?ops_mod.Ops = null,
    play_session: ?u64 = null,
    play_scope: ?PlayScope = null,
    active: ?Active = null,

    const Active = struct { store: channels.Store, local: channels.LocalChannel };
    const a = std.heap.page_allocator;

    pub fn deinit(self: *State, io: std.Io) void {
        if (self.ops) |*ops| ops.close(io);
        if (self.active) |active| active.store.close(io);
        self.signer.deinit();
        self.* = .{};
    }

    fn bindPlay(self: *State, io: std.Io, paths: wallet.Paths, req: BindPlay) !?PlayView {
        self.clearActive(io);
        self.play_session = null;
        self.play_scope = null;
        self.clearOps(io);

        const store = try self.openPlayStore(io, paths, &req.scope);
        defer if (self.active == null) store.close(io);
        var local = try store.discover(io, a);
        if (local) |*found| {
            const previous = try HoePayment.State.fromLocal(store, found.*);
            if (req.active) |active| {
                if (!std.meta.eql(active.id, found.id)) return error.ChannelMismatch;
                if (!protocol.validHoeCapacity(active.capacity_msats) or active.capacity_msats != found.capacity_msats) return error.CapacityMismatch;

                if (found.state.settlement == null) {
                    const balance = try HoePayment.State.reconcile(previous, store.scope, active.id, active.balance_msats, found.capacity_msats);
                    var lifecycle = found.state;
                    lifecycle.admitted = true;
                    lifecycle.confirmed_balance_msats = balance.confirmed_balance_msats;
                    lifecycle.pending_cut = balance.prepared;
                    if (!std.meta.eql(lifecycle, found.state)) try store.writeLifecycle(a, found.id, lifecycle);
                    found.state = lifecycle;
                    self.active = .{ .store = store, .local = found.* };
                }
            }
        } else if (req.active != null) return error.NoFundedChannel;
        self.play_scope = req.scope;
        self.play_session = req.session;
        return if (local) |found| playView(found, self.active != null) else null;
    }

    fn clearActive(self: *State, io: std.Io) void {
        if (self.active) |state| state.store.close(io);
        self.active = null;
    }

    fn clearOps(self: *State, io: std.Io) void {
        if (self.ops) |*ops| ops.close(io);
        self.ops = null;
    }

    fn channelScope(self: *State, io: std.Io, paths: wallet.Paths, scope: *const PlayScope) !channels.Scope {
        if (scope.server.len >= scope.server.bytes.len) return error.InvalidFixtureEndpoint;
        try self.signer.load(io, paths);
        // Auth identifies an x-only key; the store uses the actual compressed key.
        if ((scope.player[0] != 2 and scope.player[0] != 3) or
            !std.mem.eql(u8, scope.player[1..], self.signer.pubkey[1..])) return error.IdentityMismatch;
        return .{ .server = scope.server.slice(), .receiver = scope.receiver, .player = self.signer.pubkey };
    }

    fn openPlayStore(self: *State, io: std.Io, paths: wallet.Paths, scope: *const PlayScope) !channels.Store {
        return channels.Store.open(io, paths.dir, try self.channelScope(io, paths, scope));
    }

    fn markAdmission(store: channels.Store, local: channels.LocalChannel) !void {
        if (local.state.admitted) return;
        var lifecycle = local.state;
        lifecycle.admitted = true;
        try store.writeLifecycle(a, local.id, lifecycle);
    }

    fn playView(local: channels.LocalChannel, server_active: bool) PlayView {
        return .{
            .id = local.id,
            .confirmed = local.state.admitted,
            .server_active = server_active,
            .refund_time = local.refund_time,
            .cuts_left = if (server_active) (local.capacity_msats - local.state.confirmed_balance_msats) / funding.price_msats else 0,
            .capacity_msats = local.capacity_msats,
            .confirmed_balance_msats = local.state.confirmed_balance_msats,
            .payment_pending = local.state.pending_cut != null,
        };
    }

    fn commitCut(self: *State, io: std.Io, balance: HoePayment.State) !void {
        const active = &self.active.?;
        var lifecycle = active.local.state;
        lifecycle.confirmed_balance_msats = balance.confirmed_balance_msats;
        lifecycle.pending_cut = balance.prepared;
        // Rebind from storage before any further signing if a write fails.
        errdefer self.clearActive(io);
        try active.store.writeLifecycle(a, active.local.id, lifecycle);
        active.local.state = lifecycle;
    }

    fn finalizeSettled(self: *State, io: std.Io, paths: wallet.Paths, owner: *?wallet.Wallet, req: @FieldType(Request, "finalize_settled")) !u64 {
        if (self.play_session != req.session) return error.StalePlaySession;
        const scope = self.play_scope orelse return error.MissingPlayScope;
        const store = try self.openPlayStore(io, paths, &scope);
        defer store.close(io);
        const saved = try store.read(io, a, req.id);
        defer saved.deinit();
        const channel = saved.value.channel;
        const policy = try mintPolicy(wallet.cdk.app_mint);
        if (!std.mem.eql(u8, channel.mint_url, policy.mint_url) or !protocol.validHoeCapacity(channel.capacity_msats)) return error.PendingMismatch;

        const proofs = if (req.sender_proofs) |*text| blk: {
            if (text.len == 0 or text.len > protocol.max_sender_change_proofs_bytes) return error.InvalidSenderProofs;
            break :blk text.slice();
        } else null;
        const hash = receiptHash(proofs);
        var state = try store.readLifecycle(a, channel.id);
        if (state.settlement) |settlement| {
            if (!std.meta.eql(hash, settlement.receipt_hash)) return error.SettlementReceiptMismatch;
            if (settlement.released) return settlement.net_msats.?;
            if (settlement.net_msats == null) return error.SenderCreditUncertain;
        }
        const local = (try store.discover(io, a)) orelse return error.NoFundedChannel;
        if (!std.meta.eql(local.id, channel.id)) return error.ChannelMismatch;
        self.clearActive(io);
        self.clearOps(io);

        const handle = try walletHandle(io, paths, owner);
        var ops: ops_mod.Ops = .{ .store = store, .journal = .{ .db = store.db }, .wallet = handle, .policy = policy };
        const funding_to_retire = try ops.closeFunding(io, a, channel.id);
        if (state.settlement == null) {
            var sender_key: [64:0]u8 = undefined;
            defer std.crypto.secureZero(u8, &sender_key);
            if (proofs != null) try HoePayment.senderKey(&self.signer, &sender_key);
            state = try creditSender(store, channel.id, proofs, channel.capacity_msats, SenderReceive{
                .wallet_handle = handle,
                .mint = channel.mint_url,
                .signing_key = &sender_key,
            });
        }
        // A retry after this point only reconciles the original funding send.
        try ops.retireClosedFunding(io, a, channel.id, funding_to_retire);
        state.settlement.?.released = true;
        // The settled channel can no longer accept the pending cut. The
        // receipt does not tell us whether that cut was charged.
        state.pending_cut = null;
        try store.writeLifecycle(a, channel.id, state);
        return state.settlement.?.net_msats.?;
    }

    pub fn execute(self: *State, io: std.Io, paths: wallet.Paths, owner: *?wallet.Wallet, request: Request) !Result {
        // A replacement quote (even a failed one) must revoke the previous one.
        if (request == .quote) if (self.ops) |*ops| ops.invalidateQuote();
        const live = switch (request) {
            .quote => |req| req,
            .fund_with_consent => |req| req.live,
            .resume_funding => |req| req.live,
            .recover_funding => |req| req.live,
            .inspect => |req| req,
            .bind_play => |req| return .{ .play_bound = try self.bindPlay(io, paths, req) },
            .mark_admitted => |req| {
                if (self.play_session != req.session) return error.StalePlaySession;
                const scope = self.play_scope orelse return error.MissingPlayScope;
                const store = try self.openPlayStore(io, paths, &scope);
                defer store.close(io);
                const local = (try store.discover(io, a)) orelse return error.NoFundedChannel;
                if (!std.meta.eql(local.id, req.id)) return error.ChannelMismatch;
                try markAdmission(store, local);
                self.clearOps(io);
                return .{ .admission_marked = req.id };
            },
            .finalize_settled => |req| return .{ .settlement_finalized = .{
                .id = req.id,
                .credited_msats = try self.finalizeSettled(io, paths, owner, req),
            } },
            .prepare_cut => |req| {
                if (self.play_session != req.session or self.active == null) return error.NoActiveChannel;
                const active = &self.active.?;
                var balance = try HoePayment.State.fromLocal(active.store, active.local);
                const cut = try balance.prepareCut(io, a, &active.store, &self.signer, active.local.capacity_msats, req.id, req.tile);
                try self.commitCut(io, balance);
                return .{ .cut_prepared = cut };
            },
            .resolve_cut => |req| {
                if (self.play_session != req.session or self.active == null) return error.NoActiveChannel;
                const active = &self.active.?;
                var balance = try HoePayment.State.fromLocal(active.store, active.local);
                try balance.resolve(req.id, req.resolution);
                try self.commitCut(io, balance);
                return .{ .cut_resolved = playView(active.local, true) };
            },
        };
        if (self.play_session != live.session or self.active != null) return error.FundingUnavailable;
        if (live.server.len >= live.server.bytes.len) return error.InvalidFixtureEndpoint;
        const server = live.server.slice();
        _ = try loopbackPort(server, "ws://127.0.0.1:", true);
        const policy = comptime mintPolicy(wallet.cdk.app_mint) catch @compileError("hoe funding requires the exact Testnut URL or a local fake mint");
        const play_scope = self.play_scope orelse return error.MissingPlayScope;
        if (!std.mem.eql(u8, play_scope.server.slice(), server) or !std.meta.eql(play_scope.receiver, live.requirements.pubkey)) return error.ScopeMismatch;
        const scope = try self.channelScope(io, paths, &play_scope);
        if (self.ops == null) {
            if (request == .fund_with_consent) return error.StaleOffer;
            self.ops = try ops_mod.Ops.open(io, paths.dir, try walletHandle(io, paths, owner), scope, policy);
        }
        const ops = &self.ops.?;
        const local = try ops.store.discover(io, a);
        if (local) |found| {
            if (found.state.admitted or (request != .inspect and request != .recover_funding)) return error.FundingUnavailable;
        }
        if (request == .inspect) {
            const pending = try inspect(ops, io, a);
            if (local != null and pending == .idle) return error.PendingMismatch;
            return .{ .pending = pending };
        }
        if (request == .recover_funding) {
            var channel = try ops.recoverFunding(io, a, request.recover_funding.operation_id);
            defer channel.deinit();
            return .{ .funded = try Open.copy(channel) };
        }

        var hex: [64:0]u8 = undefined;
        defer std.crypto.secureZero(u8, &hex);
        try HoePayment.senderKey(&self.signer, &hex);
        const sender: funding.Sender = .{ .pubkey = self.signer.pubkey, .secret_key_hex = &hex };
        return switch (request) {
            .quote => .{ .quoted = try ops.quote(io, a, live.requirements, sender) },
            .fund_with_consent => |req| blk: {
                var channel = try ops.fundWithConsent(io, a, req.offer, live.requirements, sender);
                defer channel.deinit();
                break :blk .{ .funded = try Open.copy(channel) };
            },
            .resume_funding => |req| blk: {
                var channel = try ops.resumeFunding(io, a, req.operation_id, live.requirements, sender);
                defer channel.deinit();
                break :blk .{ .funded = try Open.copy(channel) };
            },
            .recover_funding, .inspect, .bind_play, .mark_admitted, .finalize_settled, .prepare_cut, .resolve_cut => unreachable,
        };
    }
};

fn walletHandle(io: std.Io, paths: wallet.Paths, owner: *?wallet.Wallet) !*wallet.cdk.c.CdkWallet_t {
    if (owner.* == null) {
        const inspection = try wallet.inspect(io, State.a, paths, true);
        owner.* = inspection.wallet orelse return error.Unavailable;
    }
    return owner.*.?.borrowHandle();
}

const SenderReceive = struct {
    wallet_handle: *wallet.cdk.c.CdkWallet_t,
    mint: [:0]const u8,
    signing_key: *const [64:0]u8,

    fn receive(self: SenderReceive, proofs: [:0]const u8) !u64 {
        const c = wallet.cdk.c;
        const result = c.cdk_wallet_receive_proofs(self.wallet_handle, self.mint.ptr, proofs.ptr, self.signing_key);
        defer c.cdk_string_free(result.@"error");
        if (result.status != c.CDK_STATUS_OK) return error.SenderCreditUncertain;
        return result.net_msats;
    }
};

fn receiptHash(proofs: ?[]const u8) channels.Id {
    var hash: channels.Id = undefined;
    std.crypto.hash.sha2.Sha256.hash(proofs orelse "", &hash, .{});
    return hash;
}

fn creditSender(store: channels.Store, id: channels.Id, proofs: ?[]const u8, capacity: u64, receiver: anytype) !channels.Lifecycle {
    const a = State.a;
    var state = try store.readLifecycle(a, id);
    const hash = receiptHash(proofs);
    if (state.settlement) |existing| {
        if (!std.meta.eql(hash, existing.receipt_hash)) return error.SettlementReceiptMismatch;
        if (existing.net_msats == null) return error.SenderCreditUncertain;
        return state;
    }
    state.admitted = true;
    state.settlement = .{ .receipt_hash = hash, .net_msats = if (proofs == null) 0 else null };
    if (proofs) |json| {
        const face = try senderFaceValue(a, json, capacity);
        const z = try a.dupeSentinel(u8, json, 0);
        defer {
            std.crypto.secureZero(u8, z);
            a.free(z);
        }
        // The mint and these records don't share a transaction. A crash or
        // error after this commit must not submit a second receive.
        try store.writeLifecycle(a, id, state);
        const net = try receiver.receive(z);
        if (net == 0 or net > face) return error.SenderCreditUncertain;
        state.settlement.?.net_msats = net;
    }
    try store.writeLifecycle(a, id, state);
    return state;
}

fn senderFaceValue(a: std.mem.Allocator, proofs: []const u8, capacity: u64) !u64 {
    if (proofs.len == 0 or proofs.len > protocol.max_sender_change_proofs_bytes or std.mem.indexOfScalar(u8, proofs, 0) != null) return error.InvalidSenderProofs;
    const parsed = try std.json.parseFromSlice([]struct { amount: u64, p2pk_e: []const u8 }, a, proofs, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var face: u64 = 0;
    for (parsed.value) |proof| {
        if (proof.amount == 0 or proof.p2pk_e.len != 66 or
            (!std.mem.startsWith(u8, proof.p2pk_e, "02") and !std.mem.startsWith(u8, proof.p2pk_e, "03"))) return error.InvalidSenderProofs;
        for (proof.p2pk_e) |ch| if (!std.ascii.isHex(ch)) return error.InvalidSenderProofs;
        face = std.math.add(u64, face, proof.amount) catch return error.InvalidSenderProofs;
    }
    if (face == 0 or face > capacity) return error.InvalidSenderProofs;
    return face;
}

fn inspect(ops: *const ops_mod.Ops, io: std.Io, a: std.mem.Allocator) !Pending {
    const saved = ops.readPending(io, a) catch |err| switch (err) {
        error.FileNotFound => return .idle,
        else => return err,
    };
    defer saved.deinit();
    const mark = saved.value;
    if (!std.mem.eql(u8, &mark.scope, &ops.store.scope) or !std.mem.eql(u8, mark.mint_url, ops.policy.mint_url) or
        mark.max_output_msats != ops.policy.max_output_msats) return .other_context;
    return switch (mark.state) {
        .sending => .{ .recovery = .{ .phase = .sending } },
        .send_failed => |failed| .{ .recovery = .{ .phase = .send_failed, .operation_id = failed.operation_id } },
        .confirmed => |send| if (try ops.hasFundingJournal(io, a, send.operation_id))
            .{ .recovery = .{ .phase = .funding_started, .operation_id = send.operation_id } }
        else
            .{ .confirmed = .{ .offer = mark.offer, .operation_id = send.operation_id } },
        .funded => |done| blk: {
            const record = try ops.store.read(io, a, done.channel_id);
            defer record.deinit();
            const channel = record.value.channel;
            if (!std.mem.eql(u8, &channel.operation_id, &done.send.operation_id) or channel.capacity_msats != mark.offer.capacity_msats or
                channel.refund_time != mark.offer.requirements.refundTime or
                !std.mem.eql(u8, channel.mint_url, mark.mint_url)) return error.PendingMismatch;
            break :blk .{ .funded = try Open.copy(channel) };
        },
    };
}

pub fn enabled(comptime mint: [:0]const u8, server: []const u8) bool {
    _ = loopbackPort(server, "ws://127.0.0.1:", true) catch return false;
    _ = mintPolicy(mint) catch return false;
    return true;
}

pub fn refillDebitLimit(comptime mint: [:0]const u8) u64 {
    const policy = comptime mintPolicy(mint) catch return 0;
    // For up to 50 msat, each of the three mint fee passes costs at most
    // 1 msat on Testnut (fewer than ten proofs in the binary split).
    return protocol.hoe_capacity_msat + (if (policy.input_fee_ppk == 0) @as(u64, 0) else 3) + policy.max_sender_fee_msats;
}

fn mintPolicy(comptime mint: [:0]const u8) !funding.Policy {
    // Match the native server's default denomination limit. Only the exact
    // desktop default and the explicit loopback fixture override are trusted.
    if (std.mem.eql(u8, mint, "https://testnut.cashu.space/")) return .{
        .mint_url = "https://testnut.cashu.space",
        .max_output_msats = 1_000_000,
        .input_fee_ppk = 100,
        .max_sender_fee_msats = 2,
    };
    const normalized: [:0]const u8 = comptime if (std.mem.endsWith(u8, mint, "/")) mint[0 .. mint.len - 1] ++ "" else mint;
    _ = loopbackPort(normalized, "http://127.0.0.1:", false) catch return error.MintFundingDisabled;
    return .{ .mint_url = normalized, .max_output_msats = 1_000_000 };
}

fn loopbackPort(url: []const u8, prefix: []const u8, trailing_slash: bool) !u16 {
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidFixtureEndpoint;
    var port: []const u8 = url[prefix.len..];
    if (trailing_slash) {
        if (!std.mem.endsWith(u8, port, "/")) return error.InvalidFixtureEndpoint;
        port = port[0 .. port.len - 1];
    }
    if (port.len == 0 or port[0] == '0') return error.InvalidFixtureEndpoint;
    for (port) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidFixtureEndpoint;
    return std.fmt.parseInt(u16, port, 10) catch error.InvalidFixtureEndpoint;
}

const t = std.testing;

test "a restarted worker retains the local balance and reconciles only exact pending claims" {
    const sf = @import("storage_fs.zig");
    const c = wallet.cdk.c;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "wallet", sf.mode_dir);
    try tmp.dir.writeFile(t.io, .{
        .sub_path = "wallet/" ++ wallet.seed_file_name,
        .data = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        .flags = .{ .permissions = sf.mode_file },
    });
    const root = try tmp.dir.realPathFileAlloc(t.io, "wallet", t.allocator);
    defer t.allocator.free(root);
    const paths = try wallet.Paths.init(t.allocator, root);
    defer paths.deinit(t.allocator);
    var owner: ?wallet.Wallet = null;
    var state: State = .{};
    defer state.deinit(t.io);
    try state.signer.load(t.io, paths);
    var scope: PlayScope = .{ .server = .{}, .player = state.signer.pubkey, .receiver = undefined };
    try t.expect(scope.server.set("ws://127.0.0.1:9224/"));
    const receiver = "02466d7fcae563e5cb09a0d1870bb580344804617879a14949cf22285f1bae3f27";
    _ = try std.fmt.hexToBytes(&scope.receiver, receiver);
    const mint = "https://mint.example";
    const key = "03d30199d74fb5a22d47b6e054e2f378cedacffcb89904a61d75d0dbd407143e65";
    const keys = "{\"keyset_id\":\"00891271bfa74eb8\",\"unit\":\"msat\",\"input_fee_ppk\":0,\"keys\":{\"32\":\"" ++ key ++
        "\",\"2\":\"" ++ key ++ "\",\"1\":\"" ++ key ++ "\"}}";
    const params = try std.fmt.allocPrintSentinel(t.allocator, "{{\"sender_pubkey\":\"{s}\",\"receiver_pubkey\":\"" ++ receiver ++
        "\",\"mint\":\"" ++ mint ++ "\",\"unit\":\"msat\",\"capacity\":35,\"expiry_timestamp\":4000000000,\"setup_timestamp\":1," ++
        "\"funding_token_amount\":35,\"maximum_amount\":32,\"keyset_id\":\"00891271bfa74eb8\",\"input_fee_ppk\":0}}", .{std.fmt.bytesToHex(scope.player, .lower)}, 0);
    defer t.allocator.free(params);
    const secret = "abababababababababababababababababababababababababababababababab";
    const derived = c.cdk_spilman_channel_parameters_get_channel_id(params, secret, keys);
    defer c.cdk_string_free(derived.@"error");
    defer c.cdk_string_free(derived.value);
    if (derived.status != c.CDK_STATUS_OK) std.debug.print("fixture channel ID: {s}\n", .{std.mem.span(derived.@"error")});
    try t.expectEqual(c.CDK_STATUS_OK, derived.status);
    var id: channels.Id = undefined;
    _ = try std.fmt.hexToBytes(&id, std.mem.span(derived.value));
    {
        const store = try state.openPlayStore(t.io, paths, &scope);
        defer store.close(t.io);
        const data = try std.json.Stringify.valueAlloc(t.allocator, channels.Record{
            .version = 1,
            .scope = store.scope,
            .channel = .{
                .operation_id = @splat(1),
                .id = id,
                .mint_url = mint,
                .capacity_msats = 35,
                .refund_time = 4_000_000_000,
                .channel_secret_hex = secret,
                .params_json = params,
                .keyset_json = keys,
                .funding_proofs_json = "[]",
            },
        }, .{});
        defer t.allocator.free(data);
        const result = c.cdk_spilman_client_storage_save_funded(store.db.handle, wallet.cdk.byteSlice(data), wallet.cdk.byteSlice("{\"inputs\":[]}"));
        defer c.cdk_string_free(result.@"error");
        try t.expectEqual(c.CDK_STATUS_OK, result.status);
    }
    var bind: BindPlay = .{ .session = 1, .scope = scope };
    const new = (try state.bindPlay(t.io, paths, bind)).?;
    try t.expectEqual(@as(u64, 0), new.confirmed_balance_msats);
    try t.expect(!new.confirmed and !new.payment_pending and !new.server_active);
    bind.active = .{ .id = id, .capacity_msats = 50, .balance_msats = 10 };
    try t.expectError(error.CapacityMismatch, state.bindPlay(t.io, paths, bind));
    bind.active.?.capacity_msats = 35;
    const admitted = (try state.bindPlay(t.io, paths, bind)).?;
    try t.expect(admitted.server_active);
    try t.expectEqual(35, admitted.capacity_msats);
    try t.expectEqual(5, admitted.cuts_left);

    const cut_id: protocol.Id = @splat(3);
    const prepare: Request = .{ .prepare_cut = .{ .id = cut_id, .session = 1, .tile = .{ .x = 0, .y = 0 } } };
    const active = state.active.?;
    var balance = try HoePayment.State.fromLocal(active.store, active.local);
    // This storage fixture has no spendable proofs. Commit the same reservation
    // that successful signing would produce, then exercise the real worker paths.
    balance.prepared = .{ .request_id = cut_id, .amount = 15 };
    try state.commitCut(t.io, balance);
    try t.expectError(error.PaymentUnresolved, state.execute(t.io, paths, &owner, prepare));
    try t.expectError(error.UnexpectedResolution, state.execute(t.io, paths, &owner, .{
        .resolve_cut = .{ .session = 1, .id = @splat(4), .resolution = .not_charged },
    }));
    state.deinit(t.io);

    bind = .{ .session = 2, .scope = scope };
    const offline = (try state.bindPlay(t.io, paths, bind)).?;
    try t.expect(offline.confirmed and offline.payment_pending and !offline.server_active);
    try t.expectEqual(@as(u64, 10), offline.confirmed_balance_msats);
    try t.expectEqual(@as(u64, 0), offline.cuts_left);
    var retry = prepare;
    retry.prepare_cut.session = 2;
    try t.expectError(error.NoActiveChannel, state.execute(t.io, paths, &owner, retry));

    bind.active = .{ .id = id, .capacity_msats = 35, .balance_msats = 20 };
    try t.expectError(error.PaymentUnresolved, state.bindPlay(t.io, paths, bind));
    try t.expectError(error.NoActiveChannel, state.execute(t.io, paths, &owner, retry));
    try t.expectEqual(offline, (try state.bindPlay(t.io, paths, .{ .session = 2, .scope = scope })).?);
    bind.active.?.balance_msats = 15;
    const reconciled = (try state.bindPlay(t.io, paths, bind)).?;
    try t.expect(reconciled.server_active and !reconciled.payment_pending);
    try t.expectEqual(@as(u64, 15), reconciled.confirmed_balance_msats);
    state.deinit(t.io);

    bind.session = 3;
    bind.active.?.balance_msats = 10;
    try t.expectError(error.BalanceUnknown, state.bindPlay(t.io, paths, bind));
    bind.active = null;
    const restored = (try state.bindPlay(t.io, paths, bind)).?;
    try t.expect(!restored.server_active and !restored.payment_pending);
    try t.expectEqual(@as(u64, 15), restored.confirmed_balance_msats);
}

test "sender change receive is never replayed after a confirmed or uncertain attempt" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "wallet", @import("storage_fs.zig").mode_dir);
    const root = try tmp.dir.realPathFileAlloc(t.io, "wallet", t.allocator);
    defer t.allocator.free(root);
    const scope: channels.Scope = .{ .server = "ws://127.0.0.1:9224/", .receiver = @splat(2), .player = @splat(3) };
    const confirmed: channels.Id = @splat(1);
    const uncertain: channels.Id = @splat(2);
    const no_change: channels.Id = @splat(3);
    const proofs = "[{\"amount\":5,\"p2pk_e\":\"02abababababababababababababababababababababababababababababababab\"}]";
    const Fake = struct {
        calls: usize = 0,
        fail: bool = false,

        fn receive(self: *@This(), json: [:0]const u8) !u64 {
            try t.expectEqualStrings(proofs, json);
            self.calls += 1;
            return if (self.fail) error.SenderCreditUncertain else 4;
        }
    };
    var mint: Fake = .{};
    {
        const store = try channels.Store.open(t.io, root, scope);
        defer store.close(t.io);
        try t.expectError(error.InvalidSenderProofs, creditSender(store, confirmed, proofs, 4, &mint));
        try t.expect((try store.readLifecycle(t.allocator, confirmed)).settlement == null);
        try t.expectEqual(4, (try creditSender(store, confirmed, proofs, 50, &mint)).settlement.?.net_msats.?);
        mint.fail = true;
        try t.expectError(error.SenderCreditUncertain, creditSender(store, uncertain, proofs, 50, &mint));
        try t.expectEqual(0, (try creditSender(store, no_change, null, 50, &mint)).settlement.?.net_msats.?);
    }
    const store = try channels.Store.open(t.io, root, scope);
    defer store.close(t.io);
    try t.expectEqual(4, (try creditSender(store, confirmed, proofs, 50, &mint)).settlement.?.net_msats.?);
    try t.expectEqual(0, (try creditSender(store, no_change, null, 50, &mint)).settlement.?.net_msats.?);
    try t.expectError(error.SenderCreditUncertain, creditSender(store, uncertain, proofs, 50, &mint));
    try t.expectError(error.SettlementReceiptMismatch, creditSender(store, uncertain, null, 50, &mint));
    try t.expectEqual(@as(usize, 2), mint.calls);
}

test "funding trusts the exact desktop mint and canonical loopback fixtures" {
    const fixture = try mintPolicy("http://127.0.0.1:18787/");
    try t.expectEqualStrings("http://127.0.0.1:18787", fixture.mint_url);
    try t.expectEqual(0, fixture.input_fee_ppk);
    const testnut = try mintPolicy("https://testnut.cashu.space/");
    try t.expectEqualStrings("https://testnut.cashu.space", testnut.mint_url);
    try t.expectEqual(100, testnut.input_fee_ppk);
    try t.expectEqual(2, testnut.max_sender_fee_msats);
    try t.expect(enabled("https://testnut.cashu.space/", "ws://127.0.0.1:9224/"));

    try t.expectError(error.MintFundingDisabled, mintPolicy("https://testnut.cashu.space"));
    try t.expectError(error.MintFundingDisabled, mintPolicy("https://testnut.cashu.space:443/"));
    try t.expectError(error.MintFundingDisabled, mintPolicy("https://testnut.cashu.space/v1/"));
    try t.expectError(error.MintFundingDisabled, mintPolicy("http://127.0.0.1:80@remote.example/"));
    for ([_][]const u8{ "ws://localhost:9224/", "ws://127.0.0.1:0/", "ws://127.0.0.1:09224/", "ws://127.0.0.1:65536/", "ws://127.0.0.1:9224/path" }) |url| {
        try t.expectError(error.InvalidFixtureEndpoint, loopbackPort(url, "ws://127.0.0.1:", true));
    }
}

// Wallet-worker-only paid-hoe signing and balance reconciliation.
const HoePayment = struct {
    const secp = @import("secp256k1");
    const c = @import("cdk").c;
    const eql = std.mem.eql;

    pub const Payment = protocol.SpillmanChannelPayment;
    pub const CutRequest = protocol.RequestFor(.cut);

    const cost_msats = protocol.hoe_price_msat;

    const Error = error{
        NoActiveChannel,
        BalanceUnknown,
        PaymentUnresolved,
        UnexpectedResolution,
        ChannelUnavailable,
        IdentityMismatch,
        InsufficientCapacity,
        SigningFailed,
        OutOfMemory,
    };

    /// The worker restores this state from the funded channel lifecycle and commits
    /// mutations before exposing a signed request or a resolved balance.
    pub const State = struct {
        const Self = @This();

        scope: [32]u8,
        channel_id: channels.Id,
        confirmed_balance_msats: u64,
        prepared: ?channels.Lifecycle.PendingCut = null,

        pub fn fromLocal(store: channels.Store, local: channels.LocalChannel) Error!Self {
            const balance = local.state.confirmed_balance_msats;
            if (balance > local.capacity_msats or balance % cost_msats != 0) return error.BalanceUnknown;
            if (local.state.pending_cut) |pending| {
                if (pending.amount != try nextBalance(balance, local.capacity_msats)) return error.BalanceUnknown;
            }
            return .{
                .scope = store.scope,
                .channel_id = local.id,
                .confirmed_balance_msats = balance,
                .prepared = local.state.pending_cut,
            };
        }

        pub fn reconcile(previous: ?Self, scope: [32]u8, id: channels.Id, balance: u64, capacity: u64) Error!Self {
            if (balance > capacity or balance % cost_msats != 0) return error.BalanceUnknown;
            const fresh: Self = .{ .scope = scope, .channel_id = id, .confirmed_balance_msats = balance };
            var old = previous orelse return fresh;
            const same_channel = eql(u8, &old.channel_id, &id) and eql(u8, &old.scope, &scope);
            if (old.prepared) |pending| {
                if (!same_channel) return error.PaymentUnresolved;
                const resolution: Resolution = if (balance == pending.amount) .charged else if (balance == old.confirmed_balance_msats) .not_charged else return error.PaymentUnresolved;
                try old.resolve(pending.request_id, resolution);
                return old;
            }
            if (same_channel and balance < old.confirmed_balance_msats) return error.BalanceUnknown;
            return fresh;
        }

        /// Prepare exactly one paid cut, with no enqueue or send. On success the
        /// request is reserved, not charged. If dispatch is ambiguous, leave it
        /// reserved until the charge is resolved authoritatively.
        pub fn prepareCut(self: *Self, io: std.Io, a: std.mem.Allocator, store: *const channels.Store, identity: *const Signer, capacity: u64, request_id: protocol.Id, tile: protocol.Location) Error!CutRequest {
            if (!eql(u8, &self.scope, &store.scope)) return error.NoActiveChannel;
            if (self.prepared != null) return error.PaymentUnresolved;
            if (!eql(u8, &identity.pubkey, &store.player)) return error.IdentityMismatch;

            const record = store.read(io, a, self.channel_id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ChannelUnavailable,
            };
            defer record.deinit();
            const channel = record.value.channel;
            const now = std.Io.Clock.real.now(io).toSeconds();
            if (now < 0 or @as(u64, @intCast(now)) >= channel.refund_time or channel.capacity_msats != capacity) return error.ChannelUnavailable;
            const amount = try nextBalance(self.confirmed_balance_msats, capacity);

            var secret_hex: [64:0]u8 = undefined;
            defer std.crypto.secureZero(u8, &secret_hex);
            try senderKey(identity, &secret_hex);
            const payment = try sign(a, channel, &secret_hex, amount);
            self.prepared = .{ .request_id = request_id, .amount = amount };
            return .{ .request_id = request_id, .payload = .{ .x = tile.x, .y = tile.y, .payment = payment } };
        }

        pub const Resolution = enum { charged, not_charged };

        /// Use `charged` only on evidence that this exact payment was accepted.
        /// Use `not_charged` only if it certainly wasn't dispatched or committed.
        /// A generic gameplay error or timeout is not such evidence by itself.
        pub fn resolve(self: *Self, request_id: protocol.Id, outcome: Resolution) Error!void {
            const pending = self.prepared orelse return error.UnexpectedResolution;
            if (!eql(u8, &pending.request_id, &request_id)) return error.UnexpectedResolution;
            if (outcome == .charged) self.confirmed_balance_msats = pending.amount;
            self.prepared = null;
        }
    };

    /// The caller wipes the output, including on error.
    pub fn senderKey(identity: *const Signer, hex: *[64:0]u8) Error!void {
        const context = identity.context orelse return error.IdentityMismatch;
        var scalar: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &scalar);
        if (secp.secp256k1_keypair_sec(context, &scalar, &identity.keypair) != 1) return error.IdentityMismatch;
        @memcpy(hex[0..64], &std.fmt.bytesToHex(&scalar, .lower));
        hex[64] = 0;
    }

    fn nextBalance(previous: u64, capacity: u64) Error!u64 {
        const next = std.math.add(u64, previous, cost_msats) catch return error.InsufficientCapacity;
        if (next > capacity) return error.InsufficientCapacity;
        return next;
    }

    fn sign(a: std.mem.Allocator, channel: channels.Funded, secret_hex: [:0]const u8, amount: u64) Error!Payment {
        const result = c.cdk_spilman_create_signed_balance_update(channel.params_json, channel.keyset_json, secret_hex, channel.funding_proofs_json, amount);
        defer c.cdk_string_free(result.@"error");
        defer c.cdk_string_free(result.value);
        if (result.status != c.CDK_STATUS_OK or result.value == null) return error.SigningFailed;
        const parsed = std.json.parseFromSlice(struct { channel_id: []const u8, amount: u64, signature: []const u8 }, a, std.mem.span(result.value), .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SigningFailed,
        };
        defer parsed.deinit();
        const update = parsed.value;
        var payment: Payment = .{ .id = undefined, .amount = amount, .signature = undefined };
        if (update.amount != amount or update.channel_id.len != 2 * payment.id.len or update.signature.len != 2 * payment.signature.len) return error.SigningFailed;
        _ = std.fmt.hexToBytes(&payment.id, update.channel_id) catch return error.SigningFailed;
        if (!eql(u8, &payment.id, &channel.id)) return error.SigningFailed;
        _ = std.fmt.hexToBytes(&payment.signature, update.signature) catch return error.SigningFailed;
        return payment;
    }
};

test "next balance costs five msats, including when capacity is exact" {
    try t.expectEqual(@as(u64, 5), try HoePayment.nextBalance(0, 15));
    try t.expectEqual(@as(u64, 15), try HoePayment.nextBalance(10, 15));
    try t.expectError(error.InsufficientCapacity, HoePayment.nextBalance(10, 14));
    try t.expectError(error.InsufficientCapacity, HoePayment.nextBalance(std.math.maxInt(u64) - 1, std.math.maxInt(u64)));
}

test "a reconnect resolves only the exact pending balance in the same scope" {
    var previous = try HoePayment.State.reconcile(null, @splat(1), @splat(2), 10, 24);
    previous.prepared = .{ .request_id = @splat(3), .amount = 15 };
    try t.expectError(error.UnexpectedResolution, previous.resolve(@splat(4), .not_charged));
    for ([_]u64{ 10, 15 }) |balance| {
        const settled = try HoePayment.State.reconcile(previous, previous.scope, previous.channel_id, balance, 24);
        try t.expectEqual(balance, settled.confirmed_balance_msats);
        try t.expect(settled.prepared == null);
    }
    try t.expectError(error.PaymentUnresolved, HoePayment.State.reconcile(previous, previous.scope, previous.channel_id, 20, 24));
    try t.expectError(error.PaymentUnresolved, HoePayment.State.reconcile(previous, @splat(9), previous.channel_id, 15, 24));
    try t.expectError(error.PaymentUnresolved, HoePayment.State.reconcile(previous, previous.scope, @splat(9), 15, 24));
    try t.expectError(error.BalanceUnknown, HoePayment.State.reconcile(previous, previous.scope, previous.channel_id, 25, 24));
}
