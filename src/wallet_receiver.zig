//! Private Spilman receiver ledger used by wallet_service. No gameplay or profile writes.
//! The wallet owner serializes all calls on the ledger and borrowed CDK handle.
const std = @import("std");
const cdk = @import("cdk");
const c = cdk.c;
const sqlite = @import("sqlite.zig");
const Db = sqlite.Db;
const Stmt = sqlite.Stmt;
const Allocator = std.mem.Allocator;

const protocol = @import("shared").protocol;
const hoe_price_msat = protocol.hoe_price_msat;

pub const Id = [32]u8;
pub const Pubkey = [33]u8;
pub const Signature = [64]u8;
const Ref = struct { id: Id, owner: Pubkey };
pub const Phase = enum { active, depleted, closing_window, expired, sender_refund_required, settlement_pending, settled };
pub const Info = struct {
    capacity_msat: u64,
    price_msat: u64,
    balance_msat: u64,
    expiry: u64,
    phase: Phase,
    wallet_redeemed: bool,

    pub fn remaining(self: Info) u64 {
        return self.capacity_msat - self.balance_msat;
    }
};
pub const Payment = struct { balance_msat: u64, signature: Signature };
pub const Open = struct {
    id: Id,
    params_json: []const u8,
    funding_proofs_json: []const u8,
};

pub const LiveChannel = struct {
    arena: std.heap.ArenaAllocator,
    id: Id,
    data: Stored,
    secret: [:0]const u8,

    pub fn exhausted(self: *const LiveChannel) bool {
        return self.data.info.remaining() < self.data.info.price_msat;
    }

    pub fn deinit(self: *LiveChannel) void {
        free(@constCast(self.secret.ptr));
        // Arena bookkeeping must outlive the arena-allocated handle.
        var arena = self.arena;
        arena.deinit();
    }
};
pub const LoadedChannel = struct { info: Info, live: ?*LiveChannel = null };

pub const Limits = struct {
    max_funding_msat: u64 = 1_000_000,
    max_lifetime_seconds: u64 = 86_400,
    min_open_remaining_seconds: u64 = 300,
    stop_payments_before_expiry_seconds: u64 = 120,
};

const max_params_bytes = 4096;
const max_proofs_bytes = 64 * 1024;
const max_material_bytes = 1024 * 1024;
const max_proofs = 64;

// Use the canonical keys emitted by CDK, and compare the exact fields CDK
// reconstructs. No client-supplied keyset, secret, clock, or receiver identity.
const Params = struct {
    capacity: u64,
    expiry_timestamp: u64,
    funding_token_amount: u64,
    input_fee_ppk: u64,
    keyset_id: []const u8,
    maximum_amount: u64,
    mint: []const u8,
    receiver_pubkey: []const u8,
    sender_pubkey: []const u8,
    setup_timestamp: u64,
    unit: []const u8,
};
const Proof = struct {
    amount: u64,
    id: []const u8,
    witness: ?std.json.Value = null,
    p2pk_e: ?std.json.Value = null,
};
const Keyset = struct { keysetId: []const u8, unit: []const u8, finalExpiry: ?u64 = null };

const metadata_schema =
    \\CREATE TABLE receiver_channels (
    \\  id BLOB PRIMARY KEY CHECK(length(id)=32), owner BLOB NOT NULL CHECK(length(owner)=33),
    \\  wallet_net_msat INTEGER CHECK(wallet_net_msat>0),
++ std.fmt.comptimePrint("  price_msat INTEGER NOT NULL DEFAULT {d} CHECK(price_msat>0)\n", .{hoe_price_msat}) ++
    \\) STRICT, WITHOUT ROWID;
;

// Join Haystack's ownership and wallet credit to Spilman's authoritative
// funding and lifecycle records. Lifecycle writes go through SpilmanStorage.
const receiver_view =
    \\CREATE VIEW receiver_state AS
    \\  SELECT m.id, m.owner, m.wallet_net_msat, s.balance, unhex(NULLIF(s.signature,'')) AS signature,
    \\    json_extract(json_extract(s.funding_json,'$.params_json'),'$.expiry_timestamp') AS expiry,
    \\    json_extract(json_extract(s.funding_json,'$.params_json'),'$.capacity') AS capacity,
    \\    CAST(json_extract(s.funding_json,'$.params_json') AS BLOB) AS params,
    \\    CAST(json_extract(s.funding_json,'$.keyset_info_json') AS BLOB) AS keyset,
    \\    CAST(json_extract(s.funding_json,'$.funding_proofs_json') AS BLOB) AS proofs,
    \\    CASE WHEN s.state='Closing' AND j.journal<>'refund_only' THEN CAST(j.journal AS BLOB) END AS pending,
    \\    CAST(s.closed_json AS BLOB) AS receipt, s.state,
    \\    CASE WHEN s.state='Closing' AND j.journal='refund_only' THEN 1 ELSE 0 END AS refund_only, m.price_msat
    \\  FROM receiver_channels m JOIN spilman_channels s ON s.channel_id=lower(hex(m.id))
    \\  LEFT JOIN spilman_close_journals j ON j.channel_id=s.channel_id;
;

pub const Ledger = struct {
    db: *Db,
    store: *c.CdkSpilmanReceiverStorage_t,
    allocator: Allocator,
    wallet: *c.CdkWallet_t,
    mint: [:0]const u8,
    receiver_key: [64:0]u8,
    receiver_pubkey: Pubkey,
    limits: Limits,

    /// `create` is an explicit first-time provisioning operation, not a recovery
    /// fallback. Use a dedicated file in a private server-owned directory. The
    /// mint URL (without trailing slash) and wallet must outlive this ledger.
    /// Back up the receiver key independently and retain it across restarts.
    pub fn open(allocator: Allocator, path: [:0]const u8, mode: enum { create, existing }, wallet: *c.CdkWallet_t, mint: [:0]const u8, receiver_secret: [32]u8, limits: Limits) !Ledger {
        if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null or
            mint.len == 0 or mint.len > 512 or std.mem.indexOfScalar(u8, mint, 0) != null or
            std.mem.endsWith(u8, mint, "/") or std.mem.indexOfScalar(u8, mint, '|') != null or
            !(std.mem.startsWith(u8, mint, "https://") or std.mem.startsWith(u8, mint, "http://127.0.0.1:")) or
            limits.max_funding_msat < hoe_price_msat or limits.max_funding_msat > std.math.maxInt(i64) or
            limits.max_lifetime_seconds < limits.min_open_remaining_seconds or
            limits.min_open_remaining_seconds <= limits.stop_payments_before_expiry_seconds)
            return error.InvalidChannelConfiguration;

        var key = hexZ(32, receiver_secret);
        defer std.crypto.secureZero(u8, &key);
        const result = c.cdk_spilman_secret_key_to_pubkey(&key);
        defer free(result.value);
        const pubkey_hex = try take(result, error.InvalidReceiverKey);
        const pubkey = try decodeHex(33, pubkey_hex);
        const db = try Db.open(path, .read_write_no_follow, mode == .create);
        errdefer db.close();
        try db.exec("PRAGMA trusted_schema=OFF; PRAGMA synchronous=EXTRA; PRAGMA fullfsync=ON;");
        if (mode == .create) {
            try db.exec("BEGIN IMMEDIATE");
            // Refuse unrelated DBs and refuse to reinitialize an existing ledger.
            const inspect = try db.prepare("SELECT 1 FROM sqlite_schema LIMIT 1");
            defer inspect.finalize();
            if (try inspect.next()) return error.ChannelDatabaseNotEmpty;
            try db.exec("CREATE TABLE hoe_meta (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL CHECK(version=1), mint BLOB NOT NULL, receiver BLOB NOT NULL CHECK(length(receiver)=33)) STRICT");
            const insert = try db.prepare("INSERT INTO hoe_meta VALUES (1,1,?1,?2)");
            defer insert.finalize();
            try insert.bindBlob(1, mint);
            try insert.bindBlob(2, &pubkey);
            try insert.finish();
            try db.exec("COMMIT");
        }
        if (mode == .existing and try hasTable(db, "hoe_channel")) return error.OutdatedChannelDatabase;
        {
            const meta = try db.prepare("SELECT version,mint,receiver FROM hoe_meta WHERE id=1");
            defer meta.finalize();
            if (!try meta.next() or try meta.uint(0) != 1 or !eql(try meta.blobSlice(1), mint) or
                !eql(&(try meta.blob(33, 2)), &pubkey)) return error.ChannelDatabaseIdentityMismatch;
        }
        if (mode == .existing) {
            if (!try hasColumn(db, "receiver_channels", "price_msat") or
                try hasColumn(db, "receiver_channels", "expiry") or try hasColumn(db, "receiver_channels", "capacity"))
                return error.OutdatedChannelDatabase;
            const check = try db.prepare("SELECT id, expiry, capacity, state, price_msat FROM receiver_state LIMIT 0");
            defer check.finalize();
            try check.finish();
        }
        const opened = c.cdk_spilman_receiver_storage_open(path.ptr);
        free(opened.@"error");
        if (opened.status != c.CDK_STATUS_OK) return error.InvalidChannelDatabase;
        const store = opened.handle orelse return error.InvalidChannelDatabase;
        errdefer c.cdk_spilman_receiver_storage_close(store);
        const ledger: Ledger = .{ .db = db, .store = store, .allocator = allocator, .wallet = wallet, .mint = mint, .receiver_key = key, .receiver_pubkey = pubkey, .limits = limits };
        if (mode == .create) {
            try db.exec("BEGIN IMMEDIATE");
            errdefer db.exec("ROLLBACK") catch {};
            try db.exec(metadata_schema ++ receiver_view);
            try db.exec("COMMIT");
        }
        return ledger;
    }

    pub fn close(self: *Ledger) void {
        c.cdk_spilman_receiver_storage_close(self.store);
        self.db.close();
        std.crypto.secureZero(u8, &self.receiver_key);
    }

    /// All timestamps are trusted server Unix seconds, never client timestamps.
    /// This is a ledger lookup, not a new mint-state query.
    pub fn lookup(self: *const Ledger, owner: Pubkey, id: Id, now: u64) !?Info {
        const stmt = try self.row(owner, id);
        defer stmt.finalize();
        if (!try stmt.next()) return null;
        return try self.readInfo(stmt, now);
    }

    pub fn loadLive(self: *const Ledger, owner: Pubkey, id: Id, now: u64) !?LoadedChannel {
        const stmt = try self.row(owner, id);
        defer stmt.finalize();
        if (!try stmt.next()) return null;
        const info = try self.readInfo(stmt, now);
        if (info.phase != .active or info.remaining() < info.price_msat)
            return .{ .info = info };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const live = try a.create(LiveChannel);
        const data = try readStored(a, stmt, info);
        const secret = try self.channelSecret(data.sender);
        live.* = .{ .arena = arena, .id = id, .data = data, .secret = secret };
        return .{ .info = info, .live = live };
    }

    pub fn acceptFunded(self: *Ledger, owner: Pubkey, request: Open, now: u64) !Info {
        return self.acceptToolFunded(owner, request, now, .hoe);
    }

    /// Accept already funded proofs. No swap is submitted by open. New entries
    /// require local funding verification and an UNSPENT mint report. An exact
    /// retry by the same owner and tool can use an active, previously verified entry.
    pub fn acceptToolFunded(self: *Ledger, owner: Pubkey, request: Open, now: u64, tool: protocol.tool) !Info {
        const price = tool.priceMsat();
        if (try self.checkBinding(owner, request.id, price)) {
            const stmt = try self.row(owner, request.id);
            defer stmt.finalize();
            if (try stmt.next()) {
                if (!eql(try stmt.blobSlice(4), request.params_json) or !eql(try stmt.blobSlice(6), request.funding_proofs_json))
                    return error.ChannelIdConflict;
                const existing = try self.readInfo(stmt, now);
                if (existing.phase != .active or existing.remaining() < price) return error.ChannelNotActive;
                return existing;
            }
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const params_json = try z(a, request.params_json, max_params_bytes);
        const proofs_json = try z(a, request.funding_proofs_json, max_proofs_bytes);
        const params = std.json.parseFromSliceLeaky(Params, a, params_json, .{}) catch return error.InvalidChannelParameters;
        const sender = try decodeHex(33, params.sender_pubkey);
        if (!eql(params.mint, self.mint) or !eql(params.unit, "msat") or
            (owner[0] != 2 and owner[0] != 3) or (sender[0] != 2 and sender[0] != 3) or
            !eql(&(try decodeHex(33, params.receiver_pubkey)), &self.receiver_pubkey) or
            eql(sender[1..], self.receiver_pubkey[1..]) or
            !tool.validCapacity(params.capacity) or params.capacity > params.funding_token_amount or
            params.funding_token_amount > self.limits.max_funding_msat or
            params.maximum_amount == 0 or params.maximum_amount > self.limits.max_funding_msat or
            params.setup_timestamp > now or params.expiry_timestamp <= now or
            params.expiry_timestamp > std.math.maxInt(i64) or
            params.expiry_timestamp - now < self.limits.min_open_remaining_seconds or
            params.expiry_timestamp - params.setup_timestamp > self.limits.max_lifetime_seconds)
            return error.InvalidChannelParameters;
        if (!eql(sender[1..], owner[1..])) return error.InvalidChannelOwnerBinding;

        const proofs = std.json.parseFromSliceLeaky([]Proof, a, proofs_json, .{ .ignore_unknown_fields = true }) catch return error.InvalidFundingProof;
        if (proofs.len == 0 or proofs.len > max_proofs) return error.InvalidFundingProof;
        var sum: u64 = 0;
        for (proofs) |proof| {
            if (proof.amount == 0 or !eql(proof.id, params.keyset_id) or
                proof.witness != null or proof.p2pk_e != null) return error.InvalidFundingProof;
            sum = std.math.add(u64, sum, proof.amount) catch return error.InvalidFundingProof;
        }
        if (sum != params.funding_token_amount) return error.InvalidFundingProof;

        const keyset_result = c.cdk_wallet_get_active_keyset_info_json(self.wallet, self.mint.ptr);
        defer free(keyset_result.value);
        const keyset = try take(keyset_result, error.MintUnavailable);
        const keys = try parse(a, Keyset, keyset);
        if (!eql(keys.unit, "msat") or !eql(keys.keysetId, params.keyset_id)) return error.InactiveFundingKeyset;
        if (keys.finalExpiry) |expiry| if (expiry <= params.expiry_timestamp) return error.InactiveFundingKeyset;

        const secret = try self.channelSecret(sender);
        defer free(@constCast(secret.ptr));
        const id_result = c.cdk_spilman_channel_parameters_get_channel_id(params_json.ptr, secret.ptr, keyset.ptr);
        defer free(id_result.value);
        if (!eql(try take(id_result, error.InvalidChannelParameters), &hexZ(32, request.id))) return error.ChannelIdMismatch;
        try status(c.cdk_spilman_verify_valid_channel(params_json.ptr, secret.ptr, keyset.ptr, proofs_json.ptr), error.InvalidFundingProof);
        try self.checkUnspent(a, proofs_json, proofs[0], proofs.len);

        // Metadata is written first; if interrupted, retrying the same funded
        // open can finish it. An incomplete entry is never reported as active.
        try self.bindPrice(owner, request.id, price);
        try self.persist(a, request.id, .{ .op = "fund", .funding = .{
            .params_json = params_json,
            .channel_secret_hex = secret,
            .keyset_info_json = keyset,
            .funding_proofs_json = proofs_json,
        } });
        const opened = (try self.lookup(owner, request.id, now)) orelse return error.ChannelIdConflict;
        if (opened.phase != .active) return error.ChannelNotActive;
        return opened;
    }

    fn checkBinding(self: *const Ledger, owner: Pubkey, id: Id, price: u64) !bool {
        const stmt = try self.db.prepare("SELECT owner,price_msat FROM receiver_channels WHERE id=?1");
        defer stmt.finalize();
        try stmt.bindBlob(1, &id);
        if (!try stmt.next()) return false;
        if (!eql(&(try stmt.blob(33, 0)), &owner) or try stmt.uint(1) != price) return error.ChannelIdConflict;
        return true;
    }

    fn bindPrice(self: *const Ledger, owner: Pubkey, id: Id, price: u64) !void {
        const stmt = try self.db.prepare("INSERT INTO receiver_channels (id,owner,price_msat) VALUES (?1,?2,?3) ON CONFLICT(id) DO NOTHING");
        defer stmt.finalize();
        try bindRef(stmt, id, owner);
        try stmt.bindUInt(3, price);
        try stmt.finish();
        if (!try self.checkBinding(owner, id, price)) return error.ChannelIdConflict;
    }

    /// Exactly one step; repeats, gaps and regressions are rejected. Return only
    /// after the new cumulative balance AND its signature commit together.
    pub fn acceptPayment(self: *Ledger, live: *LiveChannel, payment: Payment, now: u64) !void {
        const data = &live.data;
        if (data.info.expiry -| now <= self.limits.stop_payments_before_expiry_seconds)
            return error.ChannelNotActive;
        const price = data.info.price_msat;
        if (payment.balance_msat <= data.info.balance_msat or
            payment.balance_msat - data.info.balance_msat != price or payment.balance_msat > data.info.capacity_msat)
            return error.InvalidPaymentStep;
        const sig = hexZ(64, payment.signature);
        const id_hex = hexZ(32, live.id);
        try status(c.cdk_spilman_verify_balance_update(data.params.ptr, live.secret.ptr, data.keyset.ptr, data.proofs.ptr, &id_hex, payment.balance_msat, &sig), error.InvalidPaymentSignature);

        const previous = if (data.signature) |old| hexZ(64, old) else undefined;
        try self.persist(self.allocator, live.id, .{
            .op = "pay",
            .expected = .{ .balance = data.info.balance_msat, .signature = if (data.signature != null) previous[0..128] else "" },
            .payment = .{ .balance = payment.balance_msat, .signature = sig[0..128] },
        });
        data.info.balance_msat = payment.balance_msat;
        data.signature = payment.signature;
    }

    /// Explicit terminal close of the latest earned balance, even after expiry
    /// if the sender refund has not won. A failed/ambiguous post stays pending.
    /// Calling again only inspects/restores the saved swap, never reposts it.
    fn settle(self: *Ledger, owner: Pubkey, id: Id, now: u64) !enum { pending, settled } {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const data = try self.load(a, owner, id, now);
        if (data.info.phase == .settled) return .settled;
        const signature = data.signature orelse return error.NoEarnedBalance;
        const secret = try self.channelSecret(data.sender);
        defer free(@constCast(secret.ptr));
        const journal_json = data.pending orelse prepare: {
            // Signatures commit to outputs derived with the original keyset.
            const active_result = c.cdk_wallet_get_active_keyset_info_json(self.wallet, self.mint.ptr);
            defer free(active_result.value);
            const active = try parse(a, Keyset, try take(active_result, error.MintUnavailable));
            const original = try parse(a, Keyset, data.keyset);
            if (!eql(active.keysetId, original.keysetId)) return error.InactiveFundingKeyset;
            const sig = hexZ(64, signature);
            const result = c.cdk_spilman_prepare_close_swap(data.params.ptr, secret.ptr, data.keyset.ptr, data.keyset.ptr, data.proofs.ptr, data.info.balance_msat, &sig, &self.receiver_key);
            defer free(result.value);
            const prepared = try parse(a, struct { swap_request: std.json.Value, secrets_with_blinding: std.json.Value }, try take(result, error.ClosePreparationFailed));
            break :prepare try jsonZ(a, CloseJournal{
                .request_json = try jsonZ(a, prepared.swap_request),
                .blindings_json = try jsonZ(a, prepared.secrets_with_blinding),
            });
        };
        const journal = try parse(a, CloseJournal, journal_json);

        const response = if (data.pending == null) submit: {
            try self.freeze(a, id, data.info, signature, journal_json);
            const result = c.cdk_wallet_post_swap(self.wallet, self.mint.ptr, journal.request_json.ptr);
            defer free(result.value);
            break :submit try z(a, take(result, error.ClosePostFailed) catch return .pending, max_material_bytes);
        } else recover: {
            const result = c.cdk_wallet_recover_swap(self.wallet, self.mint.ptr, journal.request_json.ptr);
            defer free(result.value);
            const recovered = try parse(a, Evidence, try take(result, error.MintUnavailable));
            const restored = recovered.swap_response orelse return .pending;
            if (recovered.input_states.len == 0) return error.CloseCompletionFailed;
            for (recovered.input_states) |state| if (!eql(state, "SPENT")) return error.CloseCompletionFailed;
            break :recover try jsonZ(a, restored);
        };

        const closed = c.cdk_spilman_unblind_close_swap(data.params.ptr, secret.ptr, data.keyset.ptr, data.keyset.ptr, journal.blindings_json.ptr, response.ptr, data.info.balance_msat, &self.receiver_key);
        defer free(closed.@"error");
        defer free(closed.receiver_proofs_json);
        defer free(closed.sender_proofs_json);
        if (closed.status != c.CDK_STATUS_OK or closed.receiver_sum < data.info.balance_msat or
            closed.receiver_proofs_json == null or closed.sender_proofs_json == null) return error.CloseCompletionFailed;
        try self.persist(a, id, .{ .op = "finish", .expected = journal_json, .payout = .{
            .expiry_timestamp = data.info.expiry,
            .closed_amount = data.info.balance_msat,
            .value_after_stage1 = try std.math.add(u64, closed.receiver_sum, closed.sender_sum),
            .receiver_sum = closed.receiver_sum,
            .sender_sum = closed.sender_sum,
            .receiver_proofs_json = std.mem.span(closed.receiver_proofs_json),
            .sender_proofs_json = std.mem.span(closed.sender_proofs_json),
        } });
        return .settled;
    }

    pub fn settleAndRedeem(self: *Ledger, owner: Pubkey, id: Id, now: u64) !bool {
        const channel = (try self.lookup(owner, id, now)) orelse return error.ChannelNotFound;
        if (channel.phase != .settled and try self.settle(owner, id, now) == .pending) return false;
        return (try self.redeem(owner, id)) != null;
    }

    fn freeze(self: *const Ledger, a: Allocator, id: Id, info: Info, sig: Signature, journal: []const u8) !void {
        const encoded = hexZ(64, sig);
        try self.persist(a, id, .{
            .op = "freeze",
            .expiry = info.expiry,
            .expected = .{ .balance = info.balance_msat, .signature = encoded[0..128] },
            .journal = journal,
        });
    }

    fn persist(self: *const Ledger, a: Allocator, id: Id, operation: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(a, operation, .{});
        defer a.free(json);
        const id_hex = hexZ(32, id);
        try status(c.cdk_spilman_receiver_storage_write(self.store, &id_hex, cdk.byteSlice(json)), error.ChannelStorageWriteFailed);
    }

    /// Redeem only the verified receiver proofs in the durable close receipt.
    /// A positive result is the net amount confirmed by the wallet, not face value.
    /// Do not infer a wallet credit from spent inputs: the ABI cannot correlate
    /// that evidence with a committed receive after a crash or lost response.
    fn redeem(self: *Ledger, owner: Pubkey, id: Id) !?u64 {
        const receipt = (try self.loadSettlement(owner, id)) orelse return error.MissingSettlementReceipt;
        defer receipt.deinit();
        if (receipt.value.wallet_net_msat) |net| return net;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const proofs = try z(a, receipt.value.receiver_proofs_json, max_material_bytes);
        const parsed = try parse(a, []Proof, proofs);
        if (parsed.len == 0 or parsed.len > max_proofs) return error.InvalidSettlementReceipt;
        var sum: u64 = 0;
        for (parsed) |proof| sum = try std.math.add(u64, sum, proof.amount);
        if (sum == 0 or sum != receipt.value.receiver_sum) return error.InvalidSettlementReceipt;
        if (!try self.allUnspent(a, proofs, parsed[0], parsed.len)) return null;
        const received = c.cdk_wallet_receive_proofs(self.wallet, self.mint.ptr, proofs.ptr, null);
        defer free(received.@"error");
        if (received.status != c.CDK_STATUS_OK or received.net_msats == 0 or received.net_msats > sum) return null;

        const write = try self.db.prepare("UPDATE receiver_channels SET wallet_net_msat=?3 WHERE id=?1 AND owner=?2 AND wallet_net_msat IS NULL");
        defer write.finalize();
        try bindRef(write, id, owner);
        try write.bindUInt(3, received.net_msats);
        try write.finish();
        if (self.db.changes() != 1) return error.ChannelStateChanged;
        return received.net_msats;
    }

    /// Trusted operator API for scanning recovery or wallet redemption work. Start with null, then
    /// pass the previous ID. No dependency on an attached gameplay profile.
    pub fn nextPending(self: *const Ledger, after: ?Id) !?Ref {
        const query = if (after == null)
            "SELECT id,owner FROM receiver_state WHERE pending IS NOT NULL OR (receipt IS NOT NULL AND wallet_net_msat IS NULL) ORDER BY id LIMIT 1"
        else
            "SELECT id,owner FROM receiver_state WHERE id>?1 AND (pending IS NOT NULL OR (receipt IS NOT NULL AND wallet_net_msat IS NULL)) ORDER BY id LIMIT 1";
        const stmt = try self.db.prepare(query);
        defer stmt.finalize();
        if (after) |id| try stmt.bindBlob(1, &id);
        if (!try stmt.next()) return null;
        return .{ .id = try stmt.blob(32, 0), .owner = try stmt.blob(33, 1) };
    }

    /// Scan expired channels with earned balances, independent of gameplay
    /// profiles. Depletion alone is not permission to start settlement.
    pub fn nextDue(self: *const Ledger, after: ?Id, now: u64) !?Ref {
        const due = "SELECT id,owner FROM receiver_state WHERE expiry<=?1 AND balance>0 AND state='Open'";
        const first = " ORDER BY id LIMIT 1";
        const query = if (after == null) due ++ first else due ++ " AND id>?2" ++ first;
        const stmt = try self.db.prepare(query);
        defer stmt.finalize();
        try stmt.bindUInt(1, @min(now, std.math.maxInt(i64)));
        if (after) |id| try stmt.bindBlob(2, &id);
        if (!try stmt.next()) return null;
        return .{ .id = try stmt.blob(32, 0), .owner = try stmt.blob(33, 1) };
    }

    /// Trusted operator API. Contains spendable receiver material; never send
    /// this receipt to a client. Caller deinitializes the returned allocation.
    pub fn loadSettlement(self: *const Ledger, owner: Pubkey, id: Id) !?std.json.Parsed(Settlement) {
        const row_stmt = try self.row(owner, id);
        defer row_stmt.finalize();
        if (!try row_stmt.next() or row_stmt.isNull(8)) return null;
        const blob = try row_stmt.blobSlice(8);
        if (blob.len > max_material_bytes) return error.InvalidChannelDatabase;
        var receipt = try std.json.parseFromSlice(Settlement, self.allocator, blob, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        errdefer receipt.deinit();
        receipt.value.wallet_net_msat = if (row_stmt.isNull(9)) null else try row_stmt.uint(9);
        return receipt;
    }

    fn row(self: *const Ledger, owner: Pubkey, id: Id) !*Stmt {
        const stmt = try self.db.prepare("SELECT expiry,capacity,balance,signature,params,keyset,proofs,pending,receipt,wallet_net_msat,refund_only,state,price_msat FROM receiver_state WHERE id=?1 AND owner=?2");
        errdefer stmt.finalize();
        try bindRef(stmt, id, owner);
        return stmt;
    }

    fn readInfo(self: *const Ledger, stmt: *Stmt, now: u64) !Info {
        const expiry = try stmt.uint(0);
        const balance = try stmt.uint(2);
        const capacity = try stmt.uint(1);
        const price = try stmt.uint(12);
        if (expiry == 0 or price == 0 or capacity < price or balance > capacity or
            (balance == 0) != stmt.isNull(3)) return error.InvalidChannelDatabase;
        if (balance != 0) _ = try stmt.blob(64, 3);
        const phase: Phase = if (stmt.textEquals(11, "Closed")) closed: {
            if (stmt.isNull(8)) return error.InvalidChannelDatabase;
            break :closed .settled;
        } else if (stmt.textEquals(11, "Closing")) closing: {
            if (try stmt.uint(10) != 0 and balance == 0) break :closing .sender_refund_required;
            if (stmt.isNull(7) or balance == 0) return error.InvalidChannelDatabase;
            break :closing .settlement_pending;
        } else open: {
            if (!stmt.textEquals(11, "Open")) return error.InvalidChannelDatabase;
            if (now >= expiry) break :open .expired;
            if (balance == capacity) break :open .depleted;
            if (expiry - now <= self.limits.stop_payments_before_expiry_seconds) break :open .closing_window;
            break :open .active;
        };
        return .{
            .expiry = expiry,
            .capacity_msat = capacity,
            .price_msat = price,
            .balance_msat = balance,
            .phase = phase,
            .wallet_redeemed = !stmt.isNull(9),
        };
    }

    fn load(self: *const Ledger, a: Allocator, owner: Pubkey, id: Id, now: u64) !Stored {
        const stmt = try self.row(owner, id);
        defer stmt.finalize();
        if (!try stmt.next()) return error.ChannelNotFound;
        return readStored(a, stmt, try self.readInfo(stmt, now));
    }

    fn readStored(a: Allocator, stmt: *Stmt, info: Info) !Stored {
        const params = try z(a, try stmt.blobSlice(4), max_params_bytes);
        const sender = try parse(a, struct { sender_pubkey: []const u8 }, params);
        return .{
            .info = info,
            .signature = if (stmt.isNull(3)) null else try stmt.blob(64, 3),
            .sender = try decodeHex(33, sender.sender_pubkey),
            .params = params,
            .keyset = try z(a, try stmt.blobSlice(5), max_material_bytes),
            .proofs = try z(a, try stmt.blobSlice(6), max_proofs_bytes),
            .pending = if (stmt.isNull(7)) null else try z(a, try stmt.blobSlice(7), max_material_bytes),
        };
    }

    fn channelSecret(self: *const Ledger, sender: Pubkey) ![:0]const u8 {
        const pubkey = hexZ(33, sender);
        const result = c.cdk_spilman_compute_channel_secret(&self.receiver_key, &pubkey);
        errdefer free(result.value);
        return take(result, error.InvalidChannelKey);
    }

    fn checkUnspent(self: *const Ledger, a: Allocator, proofs: [:0]const u8, first: Proof, count: usize) !void {
        if (!try self.allUnspent(a, proofs, first, count)) return error.FundingNotUnspent;
    }

    fn allUnspent(self: *const Ledger, a: Allocator, proofs: [:0]const u8, first: Proof, count: usize) !bool {
        // The ABI exposes NUT-07 via recover_swap. Its parser requires a valid
        // output, but the output is unused on the all-UNSPENT path. This probe
        // is NEVER submitted and its restore results are never accepted.
        const output = try jsonZ(a, .{ .amount = first.amount, .id = first.id, .B_ = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798" });
        const probe = try std.fmt.allocPrintSentinel(a, "{{\"inputs\":{s},\"outputs\":[{s}]}}", .{ proofs, output }, 0);
        const result = c.cdk_wallet_recover_swap(self.wallet, self.mint.ptr, probe.ptr);
        defer free(result.value);
        const evidence = try parse(a, Evidence, try take(result, error.FundingStateUnavailable));
        if (evidence.input_states.len != count or evidence.swap_response != null) return false;
        for (evidence.input_states) |state| if (!eql(state, "UNSPENT")) return false;
        return true;
    }
};

fn hasTable(db: *Db, name: [:0]const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM sqlite_schema WHERE type='table' AND name=CAST(?1 AS TEXT) COLLATE NOCASE");
    defer stmt.finalize();
    try stmt.bindBlob(1, name);
    return stmt.next();
}

fn hasColumn(db: *Db, table: []const u8, column: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM pragma_table_info(CAST(?1 AS TEXT)) WHERE name=CAST(?2 AS TEXT)");
    defer stmt.finalize();
    try stmt.bindBlob(1, table);
    try stmt.bindBlob(2, column);
    return stmt.next();
}

/// Verified mint close receipt. Receiver proofs must stay on the trusted side.
/// Only a non-null wallet_net_msat confirms wallet credit.
const Settlement = struct {
    receiver_sum: u64,
    sender_sum: u64,
    receiver_proofs_json: []const u8,
    sender_proofs_json: []const u8,
    wallet_net_msat: ?u64 = null,
};
const Evidence = struct { input_states: [][]const u8, swap_response: ?std.json.Value };
const CloseJournal = struct { request_json: [:0]const u8, blindings_json: [:0]const u8 };
const Stored = struct {
    info: Info,
    signature: ?Signature,
    sender: Pubkey,
    params: [:0]const u8,
    keyset: [:0]const u8,
    proofs: [:0]const u8,
    pending: ?[:0]const u8,
};

fn bindRef(stmt: *Stmt, id: Id, owner: Pubkey) !void {
    try stmt.bindBlob(1, &id);
    try stmt.bindBlob(2, &owner);
}

fn eql(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, lhs, rhs);
}

fn hexZ(comptime n: usize, value: [n]u8) [n * 2:0]u8 {
    var encoded: [n * 2:0]u8 = undefined;
    encoded[n * 2] = 0;
    @memcpy(encoded[0 .. n * 2], &std.fmt.bytesToHex(value, .lower));
    return encoded;
}

fn decodeHex(comptime n: usize, hex: []const u8) ![n]u8 {
    var bytes: [n]u8 = undefined;
    if (hex.len != n * 2) return error.InvalidChannelHex;
    _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidChannelHex;
    return bytes;
}

fn z(a: Allocator, value: []const u8, max: usize) ![:0]const u8 {
    if (value.len == 0 or value.len > max or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidChannelPayload;
    return a.dupeSentinel(u8, value, 0);
}

fn parse(a: Allocator, comptime T: type, json: []const u8) !T {
    if (json.len > max_material_bytes) return error.InvalidChannelPayload;
    return std.json.parseFromSliceLeaky(T, a, json, .{ .ignore_unknown_fields = true });
}

fn jsonZ(a: Allocator, value: anytype) ![:0]const u8 {
    return z(a, try std.json.Stringify.valueAlloc(a, value, .{}), max_material_bytes);
}

fn free(s: [*c]u8) void {
    c.cdk_string_free(s);
}

fn take(result: c.CdkStringResult_t, failure: anyerror) ![:0]const u8 {
    free(result.@"error");
    if (result.status != c.CDK_STATUS_OK or result.value == null) return failure;
    return std.mem.span(result.value);
}

fn status(result: c.CdkStatusResult_t, failure: anyerror) !void {
    free(result.@"error");
    if (result.status != c.CDK_STATUS_OK) return failure;
}

const t = std.testing;
const bob_key: [32]u8 = @splat(0x22);

fn tmpPath(a: std.mem.Allocator, tmp: *t.TmpDir, name: []const u8) ![:0]const u8 {
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
}

fn openWallet(path: [:0]const u8, seed_byte: u8) !*c.CdkWallet_t {
    const seed: [64]u8 = @splat(seed_byte);
    const result = c.cdk_wallet_open(cdk.byteSlice(&seed), path.ptr);
    defer c.cdk_string_free(result.@"error");
    defer c.cdk_recovery_reports_free(result.reports);
    try t.expectEqual(c.CDK_STATUS_OK, result.status);
    return result.handle orelse error.TestCdkFailure;
}

fn closeWallet(wallet: *c.CdkWallet_t) void {
    const result = c.cdk_wallet_close(wallet);
    c.cdk_string_free(result.@"error");
}

test "ledger requires explicit provisioning and pins mint and receiver" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try tmpPath(a, &tmp, "hoe.sqlite");
    const wallet = try openWallet(try tmpPath(a, &tmp, "wallet.sqlite"), 0x42);
    defer closeWallet(wallet);
    const mint = "https://mint.example.com";
    try t.expectError(error.InvalidChannelConfiguration, Ledger.open(a, ":memory:", .create, wallet, mint, bob_key, .{}));
    try t.expectError(error.SqliteCannotOpen, Ledger.open(a, path, .existing, wallet, mint, bob_key, .{}));
    {
        var service = try Ledger.open(a, path, .create, wallet, mint, bob_key, .{});
        defer service.close();
        try t.expectEqual(null, try service.lookup(@splat(0), @splat(0), 1));
        try t.expectEqual(null, try service.nextPending(null));
    }
    try tmp.dir.symLink(t.io, "hoe.sqlite", "linked.sqlite", .{});
    const linked_path = try tmpPath(a, &tmp, "linked.sqlite");
    try t.expectError(error.SqliteCannotOpen, Ledger.open(a, linked_path, .existing, wallet, mint, bob_key, .{}));
    try t.expectError(error.ChannelDatabaseNotEmpty, Ledger.open(a, path, .create, wallet, mint, bob_key, .{}));
    try t.expectError(error.ChannelDatabaseIdentityMismatch, Ledger.open(a, path, .existing, wallet, "https://other.example.com", bob_key, .{}));
    try t.expectError(error.ChannelDatabaseIdentityMismatch, Ledger.open(a, path, .existing, wallet, mint, @splat(0x33), .{}));
    var service = try Ledger.open(a, path, .existing, wallet, mint, bob_key, .{});
    defer service.close();
    try t.expectEqual(null, try service.nextPending(null));
    const id: Id = @splat(1);
    const owner: Pubkey = @splat(2);
    const insert = try service.db.prepare("INSERT INTO receiver_channels (id,owner) VALUES (?1,?2)");
    defer insert.finalize();
    try bindRef(insert, id, owner);
    try insert.finish();
    try t.expectEqual(null, try service.lookup(owner, id, 1));
    try service.persist(a, id, .{ .op = "fund", .funding = .{
        .params_json = "{\"expiry_timestamp\":3600,\"capacity\":100}",
        .channel_secret_hex = "test",
        .keyset_info_json = "{}",
        .funding_proofs_json = "[]",
    } });
    const accepted = try service.acceptFunded(owner, .{
        .id = id,
        .params_json = "{\"expiry_timestamp\":3600,\"capacity\":100}",
        .funding_proofs_json = "[]",
    }, 1);
    try t.expectEqual(.active, accepted.phase);
    try t.expectEqual(hoe_price_msat, accepted.price_msat);
    try t.expectEqual(null, try service.nextDue(null, 3600)); // Nothing for the receiver to collect.

    const pragmas = try service.db.prepare("SELECT (SELECT synchronous FROM pragma_synchronous), (SELECT fullfsync FROM pragma_fullfsync), (SELECT trusted_schema FROM pragma_trusted_schema)");
    defer pragmas.finalize();
    try t.expect(try pragmas.next());
    try t.expectEqual(@as(i64, 3), try pragmas.int(0)); // EXTRA
    try t.expectEqual(@as(i64, 1), try pragmas.int(1));
    try t.expectEqual(@as(i64, 0), try pragmas.int(2));
    try pragmas.finish();
}

test "receiver ledgers with redundant funding columns are rejected without rewriting them" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try tmpPath(a, &tmp, "channels.sqlite");
    const wallet = try openWallet(try tmpPath(a, &tmp, "wallet.sqlite"), 0x42);
    defer closeWallet(wallet);
    const mint = "https://mint.example.com";
    {
        var ledger = try Ledger.open(a, path, .create, wallet, mint, bob_key, .{});
        defer ledger.close();
        try ledger.db.exec("ALTER TABLE receiver_channels ADD COLUMN expiry INTEGER; ALTER TABLE receiver_channels ADD COLUMN capacity INTEGER;");
    }
    try t.expectError(error.OutdatedChannelDatabase, Ledger.open(a, path, .existing, wallet, mint, bob_key, .{}));
    const db = try Db.open(path, .read_write_no_follow, false);
    defer db.close();
    try t.expect(try hasColumn(db, "receiver_channels", "expiry"));
    try t.expect(try hasColumn(db, "receiver_channels", "capacity"));
}

test "funded channel price survives reopen and controls retries and signed payments" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try tmpPath(a, &tmp, "channels.sqlite");
    const wallet = try openWallet(try tmpPath(a, &tmp, "wallet.sqlite"), 0x42);
    defer closeWallet(wallet);
    const fixture = try parse(a, struct {
        mint_url: [:0]const u8,
        alice_pubkey: []const u8,
        alice_secret: [:0]const u8,
        channel_secret: [:0]const u8,
        expiry_timestamp: u64,
        params_json: [:0]const u8,
        keyset_json: [:0]const u8,
        funding_proofs_json: [:0]const u8,
    }, @embedFile("testdata/spilman_vectors.json"));
    const owner = try decodeHex(33, fixture.alice_pubkey);
    const tool: protocol.tool = .pickaxe;
    const now = fixture.expiry_timestamp - 3600;
    const id_result = c.cdk_spilman_channel_parameters_get_channel_id(fixture.params_json.ptr, fixture.channel_secret.ptr, fixture.keyset_json.ptr);
    defer free(id_result.value);
    const id = try decodeHex(32, try take(id_result, error.TestCdkFailure));
    const request: Open = .{ .id = id, .params_json = fixture.params_json, .funding_proofs_json = fixture.funding_proofs_json };

    {
        var ledger = try Ledger.open(a, path, .create, wallet, fixture.mint_url, bob_key, .{});
        defer ledger.close();
        try ledger.bindPrice(owner, id, tool.priceMsat());
    }
    for (0..2) |run| {
        var ledger = try Ledger.open(a, path, .existing, wallet, fixture.mint_url, bob_key, .{});
        defer ledger.close();
        // The binding exists even before the separate funding write.
        try t.expectError(error.ChannelIdConflict, ledger.acceptFunded(owner, request, now));
        try t.expectError(error.ChannelIdConflict, ledger.acceptToolFunded(owner, request, now, .axe));
        if (run == 0) {
            try t.expectEqual(null, try ledger.lookup(owner, id, now));
            try ledger.bindPrice(owner, id, tool.priceMsat());
            try ledger.persist(a, id, .{ .op = "fund", .funding = .{
                .params_json = fixture.params_json,
                .channel_secret_hex = fixture.channel_secret,
                .keyset_info_json = fixture.keyset_json,
                .funding_proofs_json = fixture.funding_proofs_json,
            } });
            try t.expectError(error.ChannelIdConflict, ledger.acceptFunded(owner, request, now));
        }
        const accepted = try ledger.acceptToolFunded(owner, request, now, tool);
        try t.expectEqual(10, accepted.price_msat);
        try t.expectEqual(run * 10, accepted.balance_msat);
        const loaded = (try ledger.loadLive(owner, id, now)).?;
        const live = loaded.live.?;
        defer live.deinit();
        try t.expectEqual(accepted, loaded.info);
        try t.expect(!live.exhausted());
        try t.expectError(error.InvalidPaymentStep, ledger.acceptPayment(live, .{
            .balance_msat = accepted.balance_msat + hoe_price_msat,
            .signature = @splat(0),
        }, now));
        const balance = accepted.balance_msat + accepted.price_msat;
        const result = c.cdk_spilman_create_signed_balance_update(fixture.params_json.ptr, fixture.keyset_json.ptr, fixture.alice_secret.ptr, fixture.funding_proofs_json.ptr, balance);
        defer free(result.value);
        const signed = try parse(a, struct { signature: []const u8 }, try take(result, error.TestCdkFailure));
        const payment: Payment = .{ .balance_msat = balance, .signature = try decodeHex(64, signed.signature) };
        try ledger.acceptPayment(live, payment, now);
        try t.expectError(error.InvalidPaymentStep, ledger.acceptPayment(live, payment, now));
        try t.expectEqual(balance, (try ledger.lookup(owner, id, now)).?.balance_msat);
    }
}

test "legacy receiver database is rejected without rewriting funded records" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try tmpPath(a, &tmp, "channels.sqlite");
    const wallet = try openWallet(try tmpPath(a, &tmp, "wallet.sqlite"), 0x42);
    defer closeWallet(wallet);
    const mint = "https://mint.example.com";
    {
        var ledger = try Ledger.open(a, path, .create, wallet, mint, bob_key, .{});
        defer ledger.close();
        try ledger.db.exec(
            \\DROP VIEW receiver_state; DROP TABLE receiver_channels;
            \\DROP TABLE spilman_channels; DROP TABLE spilman_close_journals;
            \\PRAGMA journal_mode=DELETE;
            \\CREATE TABLE hoe_channel (id BLOB,owner BLOB,expiry INTEGER,capacity INTEGER,params BLOB,keyset BLOB,proofs BLOB,
            \\  balance INTEGER,signature BLOB,pending BLOB,receipt BLOB);
            \\INSERT INTO hoe_channel VALUES (zeroblob(32),zeroblob(33),3600,100,
            \\  X'7b7d', X'7b7d', X'5b5d', 5, zeroblob(64), CAST('exact submitted request' AS BLOB), NULL);
        );
    }
    const before = try tmp.dir.readFileAlloc(t.io, "channels.sqlite", a, .limited(1024 * 1024));
    try t.expectError(error.OutdatedChannelDatabase, Ledger.open(a, path, .existing, wallet, mint, bob_key, .{}));
    const after = try tmp.dir.readFileAlloc(t.io, "channels.sqlite", a, .limited(1024 * 1024));
    try t.expectEqualSlices(u8, before, after);
}

test "current receiver ledger reopens without losing pending closes or receipts" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try tmpPath(a, &tmp, "channels.sqlite");
    const wallet = try openWallet(try tmpPath(a, &tmp, "wallet.sqlite"), 0x42);
    defer closeWallet(wallet);
    const mint = "https://mint.example.com";
    const owner: Pubkey = @splat(2);
    {
        var ledger = try Ledger.open(a, path, .create, wallet, mint, bob_key, .{});
        defer ledger.close();
        for ([_]u8{ 1, 2, 3, 4 }) |i| {
            const id: Id = @splat(i);
            try ledger.bindPrice(owner, id, hoe_price_msat);
            try ledger.persist(a, id, .{ .op = "fund", .funding = .{
                .params_json = "{\"sender_pubkey\":\"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\",\"capacity\":100,\"expiry_timestamp\":3600}",
                .channel_secret_hex = "test",
                .keyset_info_json = "{}",
                .funding_proofs_json = "[]",
            } });
            if (i == 1) continue;
            if (i == 4) {
                try ledger.persist(a, id, .{
                    .op = "freeze",
                    .expiry = @as(u64, 3600),
                    .expected = .{ .balance = @as(u64, 0), .signature = "" },
                    .journal = "refund_only",
                });
                continue;
            }
            const sig = hexZ(64, @splat(0x81));
            try ledger.persist(a, id, .{
                .op = "pay",
                .expected = .{ .balance = @as(u64, 0), .signature = "" },
                .payment = .{ .balance = @as(u64, 5), .signature = sig[0..128] },
            });
            const info = (try ledger.lookup(owner, id, 1)).?;
            const journal = "exact submitted request";
            try ledger.freeze(a, id, info, @splat(0x81), journal);
            if (i == 3) {
                try ledger.persist(a, id, .{ .op = "finish", .expected = journal, .payout = .{
                    .expiry_timestamp = info.expiry,
                    .closed_amount = info.balance_msat,
                    .value_after_stage1 = @as(u64, 100),
                    .receiver_sum = @as(u64, 5),
                    .sender_sum = @as(u64, 95),
                    .receiver_proofs_json = "[]",
                    .sender_proofs_json = "[]",
                } });
                const credit = try ledger.db.prepare("UPDATE receiver_channels SET wallet_net_msat=4 WHERE id=?1");
                defer credit.finalize();
                try credit.bindBlob(1, &id);
                try credit.finish();
            }
        }
    }
    for (0..2) |run| {
        var ledger = try Ledger.open(a, path, .existing, wallet, mint, bob_key, .{});
        defer ledger.close();
        try t.expectEqual(.sender_refund_required, (try ledger.lookup(owner, @splat(4), 1)).?.phase);
        const paid = (try ledger.lookup(owner, @splat(2), 1)).?;
        try t.expectEqual(.settlement_pending, paid.phase);
        try t.expectEqual(5, paid.balance_msat);
        try t.expectEqual(hoe_price_msat, paid.price_msat);
        const data = try ledger.load(a, owner, @splat(2), 1);
        try t.expectEqual(@as(Signature, @splat(0x81)), data.signature.?);
        try t.expectEqualStrings("exact submitted request", data.pending.?);
        try t.expectEqual(@as(Id, @splat(2)), (try ledger.nextPending(@splat(1))).?.id);
        try t.expectEqual(null, try ledger.nextPending(@splat(2)));
        const receipt = (try ledger.loadSettlement(owner, @splat(3))).?;
        defer receipt.deinit();
        try t.expectEqual(95, receipt.value.sender_sum);
        try t.expectEqual(4, receipt.value.wallet_net_msat.?);
        const id: Id = @splat(1);
        if (run == 0) {
            const sig = hexZ(64, @splat(0xab));
            const auth = .{ .balance = @as(u64, 5), .signature = sig[0..128] };
            const payment = .{ .op = "pay", .expected = .{ .balance = @as(u64, 0), .signature = "" }, .payment = auth };
            try ledger.persist(a, id, payment);
            try t.expectError(error.ChannelStorageWriteFailed, ledger.persist(a, id, payment));
            const accepted = (try ledger.lookup(owner, id, 1)).?;
            try t.expectEqual(null, try ledger.nextDue(null, accepted.expiry - 1));
            try t.expectEqual(id, (try ledger.nextDue(null, accepted.expiry)).?.id);
            // Dust and exactly zero remaining both stay open until expiry.
            for ([_]u64{ 9, 5 }) |capacity| {
                const update = try ledger.db.prepare(
                    \\UPDATE spilman_channels SET funding_json=json_set(funding_json,'$.params_json',
                    \\  json_set(json_extract(funding_json,'$.params_json'),'$.capacity',?2))
                    \\WHERE channel_id=lower(hex(?1))
                );
                defer update.finalize();
                try update.bindBlob(1, &id);
                try update.bindUInt(2, capacity);
                try update.finish();
                try t.expectEqual(null, try ledger.nextDue(null, 1));
                try t.expectEqual(null, try ledger.nextDue(null, accepted.expiry - 1));
                try t.expectEqual(id, (try ledger.nextDue(null, accepted.expiry)).?.id);
                try t.expectEqual(null, try ledger.nextDue(id, accepted.expiry));
            }
            try ledger.freeze(a, id, accepted, @splat(0xab), "new exact journal");
            try ledger.persist(a, id, .{ .op = "finish", .expected = "new exact journal", .payout = .{
                .expiry_timestamp = accepted.expiry,
                .closed_amount = accepted.balance_msat,
                .value_after_stage1 = @as(u64, 5),
                .receiver_sum = @as(u64, 5),
                .sender_sum = @as(u64, 0),
                .receiver_proofs_json = "[]",
                .sender_proofs_json = "[]",
            } });
        } else {
            try t.expectEqual(.settled, (try ledger.lookup(owner, id, 1)).?.phase);
        }
    }
}
