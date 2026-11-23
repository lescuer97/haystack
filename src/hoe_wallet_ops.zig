//! Desktop worker orchestration. Hold the wallet root's instance lock and
//! serialize this with *all* wallet, journal, and channel-store access. Use the
//! same durable private root as the wallet. Never export or reclaim a send
//! identified here, or try to infer an ID for an interrupted send.
const std = @import("std");
const cdk = @import("cdk");
const c = cdk.c;
const protocol = @import("shared").protocol;
const funding = @import("hoe_funding.zig");
const channels = @import("spilman_client_store.zig");
const Journal = channels.Journal;
const sf = @import("storage_fs.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Requirements = protocol.SpillmanChannelRequirementsRes;
const OperationId = funding.OperationId;
const eql = std.mem.eql;
const Sha256 = std.crypto.hash.sha2.Sha256;

const max_record_bytes = 4096;
const max_mint_bytes = 512;
const max_amount = std.math.maxInt(i64);
const zero_id: OperationId = @splat(0);

pub const Offer = struct {
    id: [16]u8,
    requirements: Requirements,
    capacity_msats: u64,
    nominal_msats: u64,
    send_msats: u64,
    max_sender_fee_msats: u64,
    max_debit_msats: u64,
    // Bind consent to exactly the keyset observed when the offer was made.
    keyset_hash: [32]u8,

    pub fn cuts(self: Offer) u64 {
        return self.capacity_msats / self.requirements.amount;
    }
};

pub const ConfirmedSend = struct {
    operation_id: OperationId,
    sender_fee_msats: u64,
};

pub const Pending = struct {
    version: u32 = 2,
    scope: [32]u8,
    mint_url: [:0]const u8,
    max_output_msats: u64,
    offer: Offer,
    state: union(enum) {
        // A crash here can mean no send, a reserved send, or a confirmed send.
        sending,
        send_failed: struct { status: c.CdkStatus_t, operation_id: ?OperationId },
        // The original consent authorizes this exact send. A funding journal
        // for its ID, if present, supersedes consent to submit the swap.
        confirmed: ConfirmedSend,
        funded: struct { send: ConfirmedSend, channel_id: channels.Id },
    },
};

pub const Ops = struct {
    store: channels.Store,
    journal: Journal, // Borrows the store's connection.
    wallet: *c.CdkWallet_t,
    policy: funding.Policy,
    current: ?Offer = null,

    /// Owns the storage connection, not the wallet or `policy.mint_url`.
    pub fn open(io: Io, root_path: []const u8, wallet: *c.CdkWallet_t, scope: channels.Scope, policy: funding.Policy) !Ops {
        if (!std.fs.path.isAbsolute(root_path) or !validPolicy(policy)) return error.InvalidPolicy;
        const store = try channels.Store.open(io, root_path, scope);
        return .{ .store = store, .journal = .{ .db = store.db }, .wallet = wallet, .policy = policy };
    }

    pub fn close(self: *Ops, io: Io) void {
        self.store.close(io);
        self.* = undefined;
    }

    /// Quote the largest affordable whole-cut capacity, up to the protocol
    /// limit. The ABI cannot quote the exact wallet swap fee without preparing
    /// a send; the policy supplies a cap to display, not an estimate. A
    /// balance check is not a reservation.
    /// Use the current authenticated server requirements and a trusted mint
    /// that meets hoe_funding.Policy's recovery prerequisites.
    pub fn quote(self: *Ops, io: Io, a: Allocator, requirements: Requirements, sender: funding.Sender) !Offer {
        self.current = null;
        try self.requireIdle(io, a);
        try self.validateTerms(io, requirements, sender);
        const json = try self.activeKeyset();
        defer freeString(json);
        const keyset_json = std.mem.span(json.value);
        var fresh = try choose(a, requirements, self.policy, keyset_json, try self.balance(), protocol.max_channel_proof_bytes);
        try self.checkExistingChannel(io, a, fresh);
        try checkExpiry(io, requirements);
        io.random(&fresh.id);
        self.current = fresh;
        return fresh;
    }

    pub fn invalidateQuote(self: *Ops) void {
        self.current = null;
    }

    /// One consent covers the dedicated send and one journaled funding swap.
    /// `latest` must be from the same authenticated session as the quote.
    pub fn fundWithConsent(self: *Ops, io: Io, a: Allocator, accepted: Offer, latest: Requirements, sender: funding.Sender) !funding.Channel {
        const offered = try self.consumeOffer(accepted);
        try self.requireIdle(io, a);
        if (!std.meta.eql(offered.requirements, latest)) return error.StaleOffer;
        try self.validateTerms(io, latest, sender);
        freeString(self.checkedKeyset(offered) catch |err| return switch (err) {
            error.StaleOffer => error.QuoteChanged,
            else => err,
        });
        if (try self.balance() < offered.max_debit_msats) return error.InsufficientBalance;
        try self.checkExistingChannel(io, a, offered);
        try checkExpiry(io, latest);
        const send = try self.recordSend(io, a, offered, walletSend);
        return self.resumeFunding(io, a, send.operation_id, latest, sender);
    }

    fn consumeOffer(self: *Ops, accepted: Offer) !Offer {
        const offered = self.current orelse return error.StaleOffer;
        if (!std.meta.eql(offered, accepted)) return error.StaleOffer;
        self.current = null;
        return offered;
    }

    fn walletSend(self: Ops, _: Io, _: Allocator, offered: Offer) !c.CdkSendResult_t {
        return c.cdk_wallet_send(self.wallet, self.policy.mint_url, offered.send_msats, offered.max_sender_fee_msats);
    }

    fn recordSend(self: Ops, io: Io, a: Allocator, offered: Offer, comptime send: fn (Ops, Io, Allocator, Offer) anyerror!c.CdkSendResult_t) !ConfirmedSend {
        var pending: Pending = .{
            .scope = self.store.scope,
            .mint_url = self.policy.mint_url,
            .max_output_msats = self.policy.max_output_msats,
            .offer = offered,
            .state = .sending,
        };
        try self.writePending(io, a, pending);
        const result = try send(self, io, a, offered);
        defer c.cdk_string_free(result.@"error");
        defer c.cdk_string_free(result.token);
        const id = result.operation_id.idx;
        if (result.status != c.CDK_STATUS_OK or result.token == null or eql(u8, &id, &zero_id) or
            result.sender_fee_msats > offered.max_sender_fee_msats)
        {
            pending.state = .{ .send_failed = .{
                .status = result.status,
                .operation_id = if (eql(u8, &id, &zero_id)) null else id,
            } };
            try self.writePending(io, a, pending);
            // CDK only reports this status after successful cancellation.
            if (result.status == c.CDK_STATUS_FEE_LIMIT_EXCEEDED and result.token == null and !eql(u8, &id, &zero_id)) {
                try self.removePending(io);
                return error.SenderFeeLimitExceeded;
            }
            return error.SendNeedsReconciliation;
        }
        const confirmed: ConfirmedSend = .{ .operation_id = id, .sender_fee_msats = result.sender_fee_msats };
        pending.state = .{ .confirmed = confirmed };
        try self.writePending(io, a, pending);
        return confirmed;
    }

    /// Finish the exact confirmed send authorized by the durable marker.
    /// A refreshed requirements reply may propose a new expiry; only the
    /// original expiry is authorized. This path can never make another send.
    pub fn resumeFunding(self: *Ops, io: Io, a: Allocator, operation_id: OperationId, latest: Requirements, sender: funding.Sender) !funding.Channel {
        const saved = try self.readPending(io, a);
        defer saved.deinit();
        const pending = saved.value;
        try self.matchContext(pending);
        const send = switch (pending.state) {
            .confirmed => |value| value,
            else => return error.FundingNotAuthorized,
        };
        const accepted = pending.offer;
        if (!eql(u8, &send.operation_id, &operation_id) or accepted.requirements.amount != latest.amount or
            !eql(u8, &accepted.requirements.pubkey, &latest.pubkey)) return error.StaleOffer;
        if (try self.hasFundingJournal(io, a, operation_id)) return error.AlreadyPending;
        try self.validateTerms(io, latest, sender);
        try checkExpiry(io, accepted.requirements);
        const keyset = try self.checkedKeyset(accepted);
        defer freeString(keyset);
        try self.checkExistingChannel(io, a, accepted);

        // A pure preflight failure leaves the dedicated send reserved, with no
        // swap journal and no permission to issue a replacement send.
        const amounts: funding.Amounts = .{
            .capacity = accepted.capacity_msats,
            .send = accepted.send_msats,
            .nominal = accepted.nominal_msats,
        };
        var attempt = try funding.preflight(io, a, self.wallet, send.operation_id, self.policy, accepted.requirements, amounts, std.mem.span(keyset.value), sender);
        defer attempt.deinit();
        try checkExpiry(io, accepted.requirements);
        // `fund` commits the replay guard before the POST. Until it commits,
        // the confirmed send is still safe to continue, without another send.
        var channel = try attempt.fund(io, self.journal, self.wallet);
        errdefer channel.deinit();
        try self.saveFunded(io, a, pending, send, channel);
        return channel;
    }

    /// Recover only the exact journal for this scope and operation. This does
    /// not revalidate live offer terms, make a send, or submit a funding swap.
    /// The returned channel owns its material and is already durably stored.
    pub fn recoverFunding(self: *Ops, io: Io, a: Allocator, operation_id: OperationId) !funding.Channel {
        const saved = try self.readPending(io, a);
        defer saved.deinit();
        const pending = saved.value;
        try self.matchContext(pending);
        const send = switch (pending.state) {
            .confirmed => |value| value,
            else => return error.FundingNotRecoverable,
        };
        if (!eql(u8, &send.operation_id, &operation_id)) return error.PendingMismatch;
        if (!try self.hasFundingJournal(io, a, operation_id)) return error.FundingNotRecoverable;

        var channel = try funding.recover(io, a, self.journal, self.wallet, operation_id);
        errdefer channel.deinit();
        try self.saveFunded(io, a, pending, send, channel);
        return channel;
    }

    pub fn hasFundingJournal(self: Ops, io: Io, a: Allocator, operation_id: OperationId) !bool {
        const entry = self.journal.read(io, a, operation_id) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer entry.deinit();
        const swap = entry.value.operation.mint_swap;
        if (swap.kind != .funding or !eql(u8, swap.mint_url, self.policy.mint_url)) return error.FundingMismatch;
        return true;
    }

    fn saveFunded(self: Ops, io: Io, a: Allocator, pending: Pending, send: ConfirmedSend, channel: funding.Channel) !void {
        if (!eql(u8, &channel.operation_id, &send.operation_id) or !eql(u8, channel.mint_url, pending.mint_url) or
            channel.capacity_msats != pending.offer.capacity_msats or channel.refund_time != pending.offer.requirements.refundTime)
            return error.PendingMismatch;
        try self.store.saveFunded(io, a, self.journal, channel);
        var updated = pending;
        updated.state = .{ .funded = .{ .send = send, .channel_id = channel.id } };
        try self.writePending(io, a, updated);
    }

    /// Inspect the wallet-wide marker even when its scope differs from the
    /// current server. Owns a parse arena. FileNotFound is distinct from an
    /// invalid marker. This method never calls CDK or lists pending tokens.
    pub fn readPending(self: Ops, _: Io, a: Allocator) !std.json.Parsed(Pending) {
        const parsed = try self.store.db.read(Pending, a, channels.wallet_namespace, channels.pending_key, max_record_bytes);
        errdefer parsed.deinit();
        try validatePending(parsed.value);
        return parsed;
    }

    pub const CloseFunding = struct { operation_id: OperationId, pending: bool };

    /// A close must belong to this wallet's exact funded channel. An absent
    /// marker is only useful to the caller for replaying a terminal receipt.
    pub fn closeFunding(self: Ops, io: Io, a: Allocator, id: channels.Id) !CloseFunding {
        const record = try self.store.read(io, a, id);
        defer record.deinit();
        const channel = record.value.channel;
        if (!eql(u8, channel.mint_url, self.policy.mint_url)) return error.PendingMismatch;
        const saved = self.readPending(io, a) catch |err| switch (err) {
            error.FileNotFound => {
                if (try self.hasFundingJournal(io, a, channel.operation_id)) return error.AlreadyPending;

                return .{ .operation_id = channel.operation_id, .pending = false };
            },
            else => return err,
        };
        defer saved.deinit();
        try self.matchContext(saved.value);
        const funded = switch (saved.value.state) {
            .funded => |value| value,
            else => return error.FundingNotComplete,
        };
        if (!eql(u8, &funded.channel_id, &id) or !eql(u8, &funded.send.operation_id, &channel.operation_id) or
            saved.value.offer.capacity_msats != channel.capacity_msats or
            saved.value.offer.requirements.refundTime != channel.refund_time) return error.PendingMismatch;
        return .{ .operation_id = channel.operation_id, .pending = true };
    }

    /// Only after a durable terminal close receipt. CDK owns the original
    /// send saga; never reclaim its token or replay the raw funding swap.
    pub fn retireClosedFunding(self: *Ops, io: Io, a: Allocator, id: channels.Id, closed: CloseFunding) !void {
        if (!closed.pending) return;
        const recovery = c.cdk_wallet_recover(self.wallet, self.policy.mint_url);
        defer c.cdk_string_free(recovery.@"error");
        defer c.cdk_recovery_reports_free(recovery.reports);
        if (recovery.status != c.CDK_STATUS_OK or recovery.reports.len != 1 or recovery.reports.ptr == null)
            return error.SendNeedsReconciliation;
        const report = recovery.reports.ptr[0];
        if (report.status != c.CDK_STATUS_OK or report.failed != 0 or report.skipped != 0 or
            report.mint_url == null or !eql(u8, std.mem.span(report.mint_url), self.policy.mint_url))
            return error.SendNeedsReconciliation;

        // A clean report also counts TokenCreated sagas whose proofs were not
        // spent. The funded marker establishes the exact previously persisted
        // TokenCreated send; check that it no longer exists after CDK recovery.
        const token = c.cdk_wallet_get_pending_token(self.wallet, cdk.byteSlice(&closed.operation_id));
        defer freeString(token);
        if (token.status != c.CDK_STATUS_OPERATION_NOT_FOUND or token.value != null)
            return error.SendNeedsReconciliation;

        try self.store.retireFundingAfterWalletRecovery(io, a, self.journal, id);
        try self.retireAfterReconciliation(io, a, id, closed.operation_id);
    }

    /// Release the slot after successful funding only. The caller must first
    /// durably reconcile *this exact CDK send* independently, then retire its
    /// funding journal via the channel store. Unknown sends are not cleared.
    pub fn retireAfterReconciliation(self: *Ops, io: Io, a: Allocator, id: channels.Id, operation_id: OperationId) !void {
        const saved = try self.readPending(io, a);
        defer saved.deinit();
        try self.matchContext(saved.value);
        const funded = switch (saved.value.state) {
            .funded => |value| value,
            else => return error.FundingNotComplete,
        };
        if (!eql(u8, &funded.channel_id, &id) or !eql(u8, &funded.send.operation_id, &operation_id)) return error.PendingMismatch;
        const record = try self.store.read(io, a, id);
        defer record.deinit();
        if (!eql(u8, &record.value.channel.operation_id, &operation_id)) return error.PendingMismatch;
        if (self.journal.read(io, a, operation_id)) |entry| {
            entry.deinit();
            return error.AlreadyPending;
        } else |err| if (err != error.FileNotFound) return err;

        try self.removePending(io);
    }

    fn matchContext(self: Ops, pending: Pending) !void {
        if (!eql(u8, &self.store.scope, &pending.scope) or !eql(u8, self.policy.mint_url, pending.mint_url) or
            self.policy.max_output_msats != pending.max_output_msats) return error.PendingMismatch;
    }

    fn requireIdle(self: Ops, io: Io, a: Allocator) !void {
        if (self.readPending(io, a)) |saved| {
            saved.deinit();
            return error.HoeOperationPending;
        } else |err| if (err != error.FileNotFound) return err;
    }

    fn writePending(self: Ops, _: Io, a: Allocator, pending: Pending) !void {
        try validatePending(pending);
        const data = try std.json.Stringify.valueAlloc(a, pending, .{});
        defer a.free(data);
        if (data.len > max_record_bytes) return error.RecordTooLarge;
        self.store.db.put(channels.wallet_namespace, channels.pending_key, data, pending.state != .sending) catch |err| switch (err) {
            error.RecordAlreadyExists => return error.HoeOperationPending,
            else => return err,
        };
    }

    fn removePending(self: Ops, _: Io) !void {
        return self.store.db.remove(channels.wallet_namespace, channels.pending_key);
    }

    fn checkExistingChannel(self: Ops, io: Io, a: Allocator, offered: Offer) !void {
        // CDK's deterministic channel ID includes a seconds-resolution setup
        // time. Refuse overlapping matching terms rather than risk producing
        // the same funding output again after releasing the wallet-wide slot.
        const ids = try self.store.list(io, a);
        defer a.free(ids);
        for (ids) |id| {
            const record = try self.store.read(io, a, id);
            defer record.deinit();
            const channel = record.value.channel;
            if (channel.refund_time == offered.requirements.refundTime and channel.capacity_msats == offered.capacity_msats and
                eql(u8, channel.mint_url, self.policy.mint_url)) return error.MatchingChannelExists;
        }
    }

    fn validateTerms(self: Ops, io: Io, requirements: Requirements, sender: funding.Sender) !void {
        try checkExpiry(io, requirements);
        if (requirements.amount != funding.price_msats or !eql(u8, &requirements.pubkey, &self.store.receiver)) return error.InvalidRequirements;
        if ((sender.pubkey[0] != 2 and sender.pubkey[0] != 3) or !eql(u8, sender.pubkey[1..], self.store.player[1..]) or
            sender.secret_key_hex.len != 64 or std.mem.indexOfScalar(u8, sender.secret_key_hex, 0) != null) return error.InvalidSender;
        const key = c.cdk_spilman_secret_key_to_pubkey(sender.secret_key_hex);
        defer freeString(key);
        const hex = std.fmt.bytesToHex(self.store.player, .lower);
        if (key.status != c.CDK_STATUS_OK or key.value == null or !eql(u8, std.mem.span(key.value), &hex)) return error.InvalidSender;
        const receiver_hex = std.fmt.bytesToHex(requirements.pubkey, .lower) ++ [1]u8{0};
        const secret = c.cdk_spilman_compute_channel_secret(sender.secret_key_hex, &receiver_hex);
        defer freeString(secret);
        if (secret.status != c.CDK_STATUS_OK or secret.value == null) return error.InvalidRequirements;
    }

    fn balance(self: Ops) !u64 {
        const result = c.cdk_wallet_list_balances(self.wallet);
        defer c.cdk_string_free(result.@"error");
        defer c.cdk_balance_list_free(result.balances);
        if (result.status != c.CDK_STATUS_OK) return error.BalanceUnavailable;
        for (0..result.balances.len) |i| {
            const entry = result.balances.ptr[i];
            if (entry.mint_url != null and eql(u8, std.mem.span(entry.mint_url), self.policy.mint_url)) return entry.balance_msats;
        }
        return error.MintNotRegistered;
    }

    fn activeKeyset(self: Ops) !c.CdkStringResult_t {
        const result = c.cdk_wallet_get_active_keyset_info_json(self.wallet, self.policy.mint_url);
        errdefer freeString(result);
        if (result.status != c.CDK_STATUS_OK or result.value == null) return error.KeysetUnavailable;
        return result;
    }

    fn checkedKeyset(self: Ops, offered: Offer) !c.CdkStringResult_t {
        const keyset = try self.activeKeyset();
        errdefer freeString(keyset);
        const hash = hashKeyset(std.mem.span(keyset.value));
        if (!eql(u8, &hash, &offered.keyset_hash) or offered.max_sender_fee_msats != self.policy.max_sender_fee_msats)
            return error.StaleOffer;
        return keyset;
    }
};

const Keyset = struct { keysetId: []const u8, unit: []const u8, inputFeePpk: u64, finalExpiry: ?u64 = null, amounts: []const u64, keys: std.json.Value };

fn parseKeyset(a: Allocator, json: []const u8, req: Requirements, policy: funding.Policy) !std.json.Parsed(Keyset) {
    const info = try std.json.parseFromSlice(Keyset, a, json, .{ .ignore_unknown_fields = true });
    errdefer info.deinit();
    if (!eql(u8, info.value.unit, "msat")) return error.WrongUnit;
    if (info.value.finalExpiry) |expiry| if (expiry <= req.refundTime) return error.KeysetExpiresBeforeRefund;
    if (info.value.inputFeePpk != policy.input_fee_ppk) return error.UnquotableFundingInputFee;
    // CDK derives its greedy splits from keys. Require the advertised ladder
    // and the keys to agree before using binary proof counts to quote fees.
    const keys = info.value.keys;
    if (keys != .object or keys.object.count() != info.value.amounts.len) return error.UnquotableDenominations;
    var mask: u64 = 0;
    for (info.value.amounts) |amount| {
        var buf: [20]u8 = undefined;
        if (!std.math.isPowerOfTwo(amount) or mask & amount != 0 or
            !keys.object.contains(try std.fmt.bufPrint(&buf, "{d}", .{amount}))) return error.UnquotableDenominations;
        mask |= amount;
    }
    if (mask == 0 or mask & (mask +% 1) != 0) return error.UnquotableDenominations;
    return info;
}

fn checkExpiry(io: Io, req: Requirements) !void {
    const now = Io.Clock.real.now(io).toSeconds();
    if (now < 0 or req.refundTime -| @as(u64, @intCast(now)) <= funding.min_open_remaining_seconds) return error.InvalidRequirements;
}

fn choose(a: Allocator, req: Requirements, policy: funding.Policy, json: [:0]const u8, available: u64, proof_limit: usize) !Offer {
    if (req.amount != funding.price_msats) return error.InvalidRequirements;
    const keyset = try parseKeyset(a, json, req, policy);
    defer keyset.deinit();
    var mask: u64 = 0;
    for (keyset.value.amounts) |amount| mask |= amount;
    // Proof sizes and fee splits need not be monotonic in capacity.
    var cuts = protocol.hoe_refill_cuts;
    while (cuts > 1) : (cuts -= 1) {
        const offer = quoteCapacity(a, req, policy, json, keyset.value, mask, cuts * req.amount, available, proof_limit) catch |err| switch (err) {
            error.InsufficientBalance, error.UnquotableFundingLayout, error.ProofTooLarge => continue,
            else => return err,
        };
        return offer;
    }
    return quoteCapacity(a, req, policy, json, keyset.value, mask, req.amount, available, proof_limit);
}

fn quoteCapacity(a: Allocator, req: Requirements, policy: funding.Policy, json: [:0]const u8, keyset: Keyset, mask: u64, capacity: u64, available: u64, proof_limit: usize) !Offer {
    const fee_cap = policy.max_sender_fee_msats;
    const fee_ppk = keyset.inputFeePpk;
    if (capacity > @min(mask, policy.max_output_msats)) return error.UnquotableFundingLayout;
    // Spilman's inverse promises *at least* the target. Verify both forward
    // fee passes land on it, since the C ABI derives maximum capacity.
    const nominal = try funding.nominalForCapacity(capacity, json, policy.max_output_msats);
    if (nominal > @min(mask, policy.max_output_msats)) return error.UnquotableFundingLayout;
    const stage1 = nominal -| try funding.inputFee(fee_ppk, @popCount(nominal));
    if (stage1 -| try funding.inputFee(fee_ppk, @popCount(stage1)) != capacity) return error.UnquotableFundingLayout;

    // Find a canonical binary input split that leaves precisely the funding
    // nominal after the raw swap fee. CDK may select an equivalent split.
    const max_swap_fee = try funding.inputFee(fee_ppk, @bitSizeOf(u64));
    var swap_fee: u64 = 0;
    while (swap_fee <= max_swap_fee) : (swap_fee += 1) {
        if (try funding.inputFee(fee_ppk, @popCount(nominal + swap_fee)) == swap_fee) break;
    }
    const send = nominal + swap_fee;
    if (swap_fee > max_swap_fee or send > mask) return error.UnquotableFundingLayout;
    const max_debit = try std.math.add(u64, send, fee_cap);
    if (max_debit > max_amount) return error.UnquotableFundingLayout;
    if (max_debit > available) return error.InsufficientBalance;
    if (try funding.quotedProofBytes(a, nominal, keyset.keysetId, req.refundTime) > proof_limit) return error.ProofTooLarge;
    return .{
        .id = @splat(0),
        .requirements = req,
        .capacity_msats = capacity,
        .nominal_msats = nominal,
        .send_msats = send,
        .max_sender_fee_msats = fee_cap,
        .max_debit_msats = max_debit,
        .keyset_hash = hashKeyset(json),
    };
}

fn hashKeyset(json: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    Sha256.hash(json, &hash, .{});
    return hash;
}

fn freeString(result: c.CdkStringResult_t) void {
    c.cdk_string_free(result.@"error");
    c.cdk_string_free(result.value);
}

fn validPolicy(policy: funding.Policy) bool {
    const url = policy.mint_url;
    return url.len != 0 and url.len <= max_mint_bytes and url[url.len - 1] != '/' and
        std.mem.indexOfAny(u8, url, "\x00|") == null and std.unicode.utf8ValidateSlice(url) and policy.max_output_msats != 0 and
        (policy.input_fee_ppk == 0 or policy.input_fee_ppk == 100) and policy.max_sender_fee_msats <= max_amount;
}

fn validatePending(pending: Pending) !void {
    const o = pending.offer;
    if (pending.version != 2 or !validPolicy(.{ .mint_url = pending.mint_url, .max_output_msats = pending.max_output_msats }) or
        o.requirements.amount != funding.price_msats or o.requirements.refundTime == 0 or !protocol.validHoeCapacity(o.capacity_msats) or
        o.capacity_msats > o.nominal_msats or o.nominal_msats > pending.max_output_msats or o.nominal_msats > o.send_msats or
        o.max_debit_msats > max_amount or o.send_msats > o.max_debit_msats or o.max_sender_fee_msats != o.max_debit_msats - o.send_msats)
        return error.InvalidPending;
    const send = switch (pending.state) {
        .sending, .send_failed => return,
        .confirmed => |value| value,
        .funded => |value| value.send,
    };
    if (eql(u8, &send.operation_id, &zero_id) or send.sender_fee_msats > o.max_sender_fee_msats) return error.InvalidPending;
}

const t = std.testing;
const test_sender_secret = "1111111111111111111111111111111111111111111111111111111111111111";
const test_receiver_secret = "2222222222222222222222222222222222222222222222222222222222222222";

fn testPubkey(secret: [:0]const u8) !channels.Pubkey {
    const result = c.cdk_spilman_secret_key_to_pubkey(secret);
    defer freeString(result);
    try t.expectEqual(c.CDK_STATUS_OK, result.status);
    var key: channels.Pubkey = undefined;
    _ = try std.fmt.hexToBytes(&key, std.mem.span(result.value));
    return key;
}

fn testRoot(tmp: *t.TmpDir) ![:0]u8 {
    try tmp.dir.createDir(t.io, "root", sf.mode_dir);
    const parent = try tmp.dir.openDir(t.io, ".", .{ .iterate = true });
    defer parent.close(t.io);
    try sf.syncDirectory(parent);
    return tmp.dir.realPathFileAlloc(t.io, "root", t.allocator);
}

fn testRequirements(receiver: channels.Pubkey) Requirements {
    return .{ .pubkey = receiver, .amount = funding.price_msats, .refundTime = @as(u64, @intCast(Io.Clock.real.now(t.io).toSeconds())) + 3600 };
}

test "quote picks the largest whole-cut offer that fits balance, fees, denominations and proof budget" {
    const req: Requirements = .{ .pubkey = @splat(0), .amount = funding.price_msats, .refundTime = 100 };
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vector = try std.json.parseFromSliceLeaky(struct { keyset_json: []const u8 }, a, @embedFile("testdata/spilman_vectors.json"), .{ .ignore_unknown_fields = true });
    const msat = try std.mem.replaceOwned(u8, a, vector.keyset_json, "\"sat\"", "\"msat\"");
    const camel = try std.mem.replaceOwned(u8, a, msat, "keyset_id", "keysetId");
    const zero = try a.dupeSentinel(u8, try std.mem.replaceOwned(u8, a, camel, "input_fee_ppk", "inputFeePpk"), 0);
    const fixture: funding.Policy = .{ .mint_url = "http://127.0.0.1:18787", .max_output_msats = 1_000_000 };
    const limit = 8192;
    const free = try choose(a, req, fixture, zero, 50, limit);
    try t.expectEqual(50, free.capacity_msats);
    try t.expectEqual(50, free.nominal_msats);
    try t.expectEqual(50, free.max_debit_msats);
    try t.expectEqual(10, free.cuts());
    const partial = try choose(a, req, fixture, zero, 49, limit);
    try t.expectEqual(9, partial.cuts());
    try t.expectEqual(45, partial.max_debit_msats);
    try t.expectEqual(1, (try choose(a, req, fixture, zero, 9, limit)).cuts());
    try t.expectError(error.InsufficientBalance, choose(a, req, fixture, zero, 4, limit));
    var capped = fixture;
    capped.max_output_msats = 32;
    try t.expectEqual(30, (try choose(a, req, capped, zero, 100, limit)).capacity_msats);
    const key = "\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\"";
    const small = "{\"unit\":\"msat\",\"inputFeePpk\":0,\"keysetId\":\"00891271bfa74eb8\",\"amounts\":[1,2,4,8]," ++
        "\"keys\":{\"1\":" ++ key ++ ",\"2\":" ++ key ++ ",\"4\":" ++ key ++ ",\"8\":" ++ key ++ "}}";
    try t.expectEqual(15, (try choose(a, req, fixture, small, 100, limit)).capacity_msats);

    const fee = try a.dupeSentinel(u8, try std.mem.replaceOwned(u8, a, zero, "\"inputFeePpk\":0", "\"inputFeePpk\":100"), 0);
    const testnut: funding.Policy = .{ .mint_url = "https://testnut.cashu.space", .max_output_msats = 1_000_000, .input_fee_ppk = 100, .max_sender_fee_msats = 2 };
    const offer = try choose(a, req, testnut, fee, 55, limit);
    try t.expectEqual(50, offer.capacity_msats);
    try t.expectEqual(52, offer.nominal_msats);
    try t.expectEqual(53, offer.send_msats);
    try t.expectEqual(55, offer.max_debit_msats);
    try t.expectEqual(10, offer.cuts());
    const fee_partial = try choose(a, req, testnut, fee, 54, limit);
    try t.expectEqual(45, fee_partial.capacity_msats);
    try t.expectEqual(47, fee_partial.nominal_msats);
    try t.expectEqual(48, fee_partial.send_msats);
    try t.expectEqual(50, fee_partial.max_debit_msats);
    try t.expectEqual(40, (try choose(a, req, testnut, fee, 54, protocol.max_channel_proof_bytes)).capacity_msats);
    const proof_limited = try choose(a, req, testnut, fee, 55, 1024);
    try t.expectEqual(30, proof_limited.capacity_msats);
    try t.expectEqual(32, proof_limited.nominal_msats);
    try t.expectEqual(35, proof_limited.max_debit_msats);
    try t.expectError(error.ProofTooLarge, choose(a, req, testnut, fee, 55, 1));
    try t.expectError(error.InsufficientBalance, choose(a, req, testnut, fee, 9, limit));
    try t.expectError(error.UnquotableFundingInputFee, choose(a, req, testnut, zero, 55, limit));
    const mismatch = try a.dupeSentinel(u8, try std.mem.replaceOwned(u8, a, fee, "64,32,16", "64,32,15"), 0);
    try t.expectError(error.UnquotableDenominations, choose(a, req, testnut, mismatch, 55, limit));
}

test "an uncertain send preserves the exact returned ID and blocks across reopen" {
    const Fake = struct {
        fn send(ops: Ops, io: Io, a: Allocator, offer: Offer) !c.CdkSendResult_t {
            const before = try ops.readPending(io, a);
            defer before.deinit();
            try t.expectEqualDeep(offer, before.value.offer);
            try t.expect(before.value.state == .sending);
            return .{ .status = c.CDK_STATUS_SEND_UNCERTAIN, .operation_id = .{ .idx = @splat(7) } };
        }
    };
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer t.allocator.free(root);
    const scope: channels.Scope = .{ .server = "test-server", .player = try testPubkey(test_sender_secret), .receiver = try testPubkey(test_receiver_secret) };
    const policy: funding.Policy = .{ .mint_url = "https://mint.example", .max_output_msats = 1_000_000 };
    const wallet: *c.CdkWallet_t = @ptrFromInt(1); // The fake never dereferences this.
    const req = testRequirements(scope.receiver);
    const offer: Offer = .{ .id = @splat(6), .requirements = req, .capacity_msats = 50, .nominal_msats = 50, .send_msats = 50, .max_sender_fee_msats = 0, .max_debit_msats = 50, .keyset_hash = @splat(1) };
    {
        var ops = try Ops.open(t.io, root, wallet, scope, policy);
        defer ops.close(t.io);
        try t.expectError(error.SendNeedsReconciliation, ops.recordSend(t.io, t.allocator, offer, Fake.send));
    }
    var ops = try Ops.open(t.io, root, wallet, scope, policy);
    defer ops.close(t.io);
    const saved = try ops.readPending(t.io, t.allocator);
    defer saved.deinit();
    try t.expectEqualDeep(offer, saved.value.offer);
    try t.expectEqual(c.CDK_STATUS_SEND_UNCERTAIN, saved.value.state.send_failed.status);
    try t.expectEqual(@as(OperationId, @splat(7)), saved.value.state.send_failed.operation_id.?);
    const sender: funding.Sender = .{ .pubkey = scope.player, .secret_key_hex = test_sender_secret };
    try t.expectError(error.HoeOperationPending, ops.quote(t.io, t.allocator, req, sender));
    try t.expectError(error.StaleOffer, ops.fundWithConsent(t.io, t.allocator, offer, req, sender));
    try t.expectError(error.FundingNotAuthorized, ops.resumeFunding(t.io, t.allocator, @splat(7), req, sender));
}

test "confirmed consent survives reopen but an existing journal forbids another swap" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer t.allocator.free(root);
    const a = t.allocator;
    const scope: channels.Scope = .{ .server = "test-server", .player = try testPubkey(test_sender_secret), .receiver = try testPubkey(test_receiver_secret) };
    const policy: funding.Policy = .{ .mint_url = "https://mint.example", .max_output_msats = 1_000_000 };
    const wallet: *c.CdkWallet_t = @ptrFromInt(1); // No wallet call is authorized in this test.
    const req = testRequirements(scope.receiver);
    const offer: Offer = .{ .id = @splat(6), .requirements = req, .capacity_msats = 30, .nominal_msats = 30, .send_msats = 30, .max_sender_fee_msats = 0, .max_debit_msats = 30, .keyset_hash = @splat(1) };
    const op: OperationId = @splat(7);
    const sender: funding.Sender = .{ .pubkey = scope.player, .secret_key_hex = test_sender_secret };
    {
        var ops = try Ops.open(t.io, root, wallet, scope, policy);
        defer ops.close(t.io);
        ops.current = offer;
        var substituted = offer;
        substituted.capacity_msats = 25;
        substituted.nominal_msats = 25;
        substituted.send_msats = 25;
        substituted.max_debit_msats = 25;
        try t.expectError(error.StaleOffer, ops.fundWithConsent(t.io, a, substituted, req, sender));
        try t.expectEqualDeep(offer, try ops.consumeOffer(offer));
        try t.expectError(error.StaleOffer, ops.consumeOffer(offer));

        var mark: Pending = .{ .scope = ops.store.scope, .mint_url = policy.mint_url, .max_output_msats = policy.max_output_msats, .offer = offer, .state = .sending };
        for ([_]u64{ 0, 29, 55 }) |capacity| {
            mark.offer.capacity_msats = capacity;
            mark.offer.nominal_msats = capacity;
            mark.offer.send_msats = capacity;
            mark.offer.max_debit_msats = capacity;
            try t.expectError(error.InvalidPending, ops.writePending(t.io, a, mark));
        }
        mark.offer = offer;
        try ops.writePending(t.io, a, mark);
        mark.state = .{ .confirmed = .{ .operation_id = op, .sender_fee_msats = 0 } };
        try ops.writePending(t.io, a, mark);
    }
    var ops = try Ops.open(t.io, root, wallet, scope, policy);
    defer ops.close(t.io);
    const saved = try ops.readPending(t.io, a);
    defer saved.deinit();
    try t.expectEqual(op, saved.value.state.confirmed.operation_id);
    try t.expectEqualDeep(offer, saved.value.offer);
    try t.expectError(error.HoeOperationPending, ops.quote(t.io, a, req, sender));
    try t.expectError(error.StaleOffer, ops.resumeFunding(t.io, a, @splat(8), req, sender));
    try t.expectError(error.FundingNotRecoverable, ops.recoverFunding(t.io, a, op));
    try ops.journal.prepare(t.io, a, op, .{ .mint_swap = .{ .kind = .funding, .mint_url = policy.mint_url, .request_json = "{}", .completion_material = "{}" } });
    try t.expectError(error.AlreadyPending, ops.resumeFunding(t.io, a, op, req, sender));
}
