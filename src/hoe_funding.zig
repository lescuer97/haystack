//! Desktop sender-side funding for the exact-capacity hoe protocol. The caller
//! holds the instance lock and serializes wallet, journal, and pending-token
//! access on the worker. Use one journal for the wallet's storage root.
//!
//! Funding only consumes a CDK-owned pending outgoing token, by its operation
//! ID; it never creates a send or posts wallet-owned unspent proofs. Use a
//! dedicated, unshared send. CDK's `cdk_wallet_send` confirms into a persisted
//! TokenCreated saga; reconcile interrupted sends via CDK and pending-token
//! listing, not by issuing a replacement send here.
//! From the moment a funding record might exist, do not export, reclaim, or
//! reuse that token while the record is unresolved. Raw swaps do not update
//! the wallet's send saga. Coordinate its separate reconciliation with the
//! channel store; wallet recovery is not swap recovery.
const std = @import("std");
const cdk = @import("cdk");
const protocol = @import("shared").protocol;
const client = @import("spilman_client_store.zig");
const c = cdk.c;
const Allocator = std.mem.Allocator;
const Journal = client.Journal;
pub const OperationId = Journal.Id;
pub const price_msats = protocol.hoe_price_msat;
pub const cuts = protocol.hoe_refill_cuts;
pub const capacity_msats = protocol.hoe_capacity_msat;
pub const min_open_remaining_seconds = 300;

/// Different tools can quote the same capacity to the same receiver in the
/// same second. Spilman IDs do not include the tool, but do include expiry.
/// Shorten new quotes by at most two seconds to give each tool a distinct
/// expiry residue. Never change the expiry of existing journaled material.
pub fn toolRefundTime(tool: protocol.tool, expiry: u64) u64 {
    const count = protocol.tools.len;
    const slot = @backingInt(tool);
    return expiry -| ((expiry % count + count - slot) % count);
}

pub const Policy = struct {
    /// Canonical CDK mint URL, as returned in Spilman parameters. Only enable
    /// funding for a trusted mint known to support NUT-07 and NUT-09 recovery
    /// with DLEQ data; the adapter cannot attest to these capabilities.
    mint_url: [:0]const u8,
    /// Maximum denomination allowed for deterministic funding/settlement.
    max_output_msats: u64,
    input_fee_ppk: u64 = 0,
    max_sender_fee_msats: u64 = 0,
};

pub const Sender = struct {
    /// The authenticated game identity (which may be even-Y normalized) and
    /// its existing, recoverable secret key. The key is never journaled.
    pubkey: [33]u8,
    secret_key_hex: [:0]const u8,
};

const Material = struct {
    version: u32 = 1,
    tool: protocol.tool = .hoe,
    capacity_msats: u64,
    refund_time: u64,
    channel_secret_hex: [:0]const u8,
    params_json: [:0]const u8,
    keyset_json: [:0]const u8,
    funding_secrets_json: [:0]const u8,
};

pub const Channel = struct {
    arena: std.heap.ArenaAllocator,
    tool: protocol.tool,
    operation_id: OperationId,
    id: [32]u8,
    mint_url: [:0]const u8,
    capacity_msats: u64,
    refund_time: u64,
    channel_secret_hex: [:0]const u8,
    params_json: [:0]const u8,
    keyset_json: [:0]const u8,
    funding_proofs_json: [:0]const u8,

    /// Borrows the verified funding proofs and canonical CDK parameters.
    pub fn openPayload(self: Channel) protocol.SpillmanChannelOpen {
        return .{ .id = self.id, .tool = self.tool, .proof = self.funding_proofs_json, .params = self.params_json };
    }

    pub fn deinit(self: *Channel) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Amounts = struct { capacity: u64, nominal: u64, send: u64 };

/// NUT-02 fees round up once per swap, after summing all inputs' ppk.
pub fn inputFee(ppk: u64, count: usize) !u64 {
    return std.math.divCeil(u64, try std.math.mul(u64, ppk, count), 1000);
}

pub fn nominalForCapacity(capacity: u64, keyset: [:0]const u8, max_output_msats: u64) !u64 {
    const result = c.cdk_spilman_compute_funding_token_amount(capacity, keyset, max_output_msats);
    defer c.cdk_string_free(result.@"error");
    if (result.status != c.CDK_STATUS_OK) return error.UnquotableFundingLayout;
    return result.amount;
}

/// The pinned Spilman funding secret has three compressed pubkeys, a nonce,
/// and an expiry. Quote its exact compact JSON size without making a wallet send.
pub fn quotedProofBytes(a: Allocator, nominal: u64, id: []const u8, expiry: u64) !usize {
    const hex64 = &@as([64:0]u8, @splat('0'));
    const key = "02" ++ hex64;
    const secret = try std.fmt.allocPrint(a, "[\"P2PK\",{{\"data\":\"{s}\",\"nonce\":\"{s}\",\"tags\":[[\"pubkeys\",\"{s}\"],[\"locktime\",\"{d}\"],[\"n_sigs\",\"2\"],[\"refund\",\"{s}\"],[\"n_sigs_refund\",\"1\"],[\"sigflag\",\"SIG_ALL\"]]}}]", .{ key, hex64, key, expiry, key });
    defer a.free(secret);
    var remaining = nominal;
    var bytes: usize = 1;
    while (remaining != 0) {
        const amount = @as(u64, 1) << @intCast(@ctz(remaining));
        remaining ^= amount;
        bytes += 1 + try proofSize(a, amount, id, secret);
    }
    return bytes;
}

fn proofSize(a: Allocator, amount: u64, id: []const u8, secret: []const u8) !usize {
    const hex64 = &@as([64:0]u8, @splat('0'));
    const estimate = try std.json.Stringify.valueAlloc(a, .{
        .amount = amount,
        .id = id,
        .secret = secret,
        .C = "02" ++ hex64,
        .dleq = .{ .e = hex64, .s = hex64, .r = hex64 },
    }, .{});
    defer a.free(estimate);
    return estimate.len;
}

pub const Attempt = struct {
    arena: ?std.heap.ArenaAllocator,
    prepared: Prepared,
    operation_id: OperationId,

    pub fn deinit(self: *Attempt) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = undefined;
    }

    /// The caller has recorded consent and must durably store the channel on success.
    /// If a journal exists after failure, recover it instead of submitting again.
    pub fn fund(self: *Attempt, io: std.Io, journal: Journal, wallet: *const c.CdkWallet_t) !Channel {
        const arena = if (self.arena) |*a| a else return error.AlreadySubmitted;
        const result = try submit(io, arena.allocator(), journal, self.operation_id, self.prepared, wallet, postSwap);
        const channel = result.owned(arena.*, self.operation_id, self.prepared);
        self.arena = null;
        return channel;
    }
};

/// Read the exact confirmed CDK send and build/validate a swap without posting
/// or writing a funding marker. The caller supplies the checked active keyset.
pub fn preflight(
    io: std.Io,
    allocator: Allocator,
    wallet: *const c.CdkWallet_t,
    pending_send: OperationId,
    policy: Policy,
    quote: protocol.SpillmanChannelRequirementsRes,
    amounts: Amounts,
    keyset: [:0]const u8,
    sender: Sender,
) !Attempt {
    return preflightTool(.hoe, io, allocator, wallet, pending_send, policy, quote, amounts, keyset, sender);
}

pub fn preflightTool(
    tool: protocol.tool,
    io: std.Io,
    allocator: Allocator,
    wallet: *const c.CdkWallet_t,
    pending_send: OperationId,
    policy: Policy,
    quote: protocol.SpillmanChannelRequirementsRes,
    amounts: Amounts,
    keyset: [:0]const u8,
    sender: Sender,
) !Attempt {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const now = std.Io.Clock.real.now(io).toSeconds();
    if (now < 0) return error.InvalidClock;
    try validateQuote(policy, quote, @intCast(now));
    if (quote.amount != tool.priceMsat() or !tool.validCapacity(amounts.capacity)) return error.InvalidCapacity;
    const token = try take(a, c.cdk_wallet_get_pending_token(wallet, cdk.byteSlice(&pending_send)));
    var prepared = try prepareExact(a, policy, quote, amounts, token, try a.dupeSentinel(u8, keyset, 0), sender);
    prepared.material.tool = tool;
    if (prepared.proof_bytes > protocol.max_channel_proof_bytes) return error.ProofTooLarge;
    return .{ .arena = arena, .prepared = prepared, .operation_id = pending_send };
}

/// Load the exact mint/request/material from disk and query NUT-07/NUT-09.
/// `FundingUnresolved` is not permission to retry, even for unspent inputs.
/// Success has the same durable handoff requirement as `fund`.
pub fn recover(
    io: std.Io,
    allocator: Allocator,
    journal: Journal,
    wallet: *const c.CdkWallet_t,
    pending_send: OperationId,
) !Channel {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const prepared = try load(io, a, journal, pending_send);
    const evidence = try take(a, c.cdk_wallet_recover_swap(wallet, prepared.mint_url, prepared.request_json));
    const result = try completeRecovery(a, prepared, evidence);
    return result.owned(arena, pending_send, prepared);
}

const Prepared = struct {
    mint_url: [:0]const u8,
    request_json: [:0]const u8,
    material: Material,
    proof_bytes: usize,
};

const Verified = struct {
    id: [32]u8,
    proofs: [:0]const u8,

    fn owned(self: Verified, arena: std.heap.ArenaAllocator, op: OperationId, p: Prepared) Channel {
        return .{
            .arena = arena,
            .tool = p.material.tool,
            .operation_id = op,
            .id = self.id,
            .mint_url = p.mint_url,
            .capacity_msats = p.material.capacity_msats,
            .refund_time = p.material.refund_time,

            .channel_secret_hex = p.material.channel_secret_hex,
            .params_json = p.material.params_json,
            .keyset_json = p.material.keyset_json,
            .funding_proofs_json = self.proofs,
        };
    }
};

fn validateQuote(policy: Policy, quote: protocol.SpillmanChannelRequirementsRes, now: u64) !void {
    if (policy.mint_url.len == 0 or std.mem.indexOfScalar(u8, policy.mint_url, 0) != null or
        policy.max_output_msats == 0 or quote.amount == 0 or
        quote.refundTime <= now or (quote.pubkey[0] != 2 and quote.pubkey[0] != 3)) return error.InvalidQuote;
}

fn validateCapacity(cost_per_cut_msats: u64, requested_capacity_msats: u64) !void {
    if (cost_per_cut_msats == 0) return error.InvalidQuote;
    if (requested_capacity_msats < cost_per_cut_msats) return error.InvalidCapacity;
}

fn prepare(a: Allocator, policy: Policy, quote: protocol.SpillmanChannelRequirementsRes, requested_capacity_msats: u64, token: [:0]const u8, keyset: [:0]const u8, identity: Sender) !Prepared {
    try validateCapacity(quote.amount, requested_capacity_msats);
    const ks = try parse(struct {
        unit: []const u8,
        finalExpiry: ?u64 = null,
        final_expiry: ?u64 = null,
        keys: std.json.Value,
    }, a, keyset);
    if (!std.mem.eql(u8, ks.unit, "msat")) return error.WrongUnit;
    if (ks.finalExpiry orelse ks.final_expiry) |expiry| if (expiry <= quote.refundTime) return error.KeysetExpiresBeforeRefund;
    const receiver = try a.dupeSentinel(u8, &std.fmt.bytesToHex(quote.pubkey, .lower), 0);
    if (identity.secret_key_hex.len != 64) return error.InvalidSenderKey;
    for (identity.secret_key_hex) |byte| if (!std.ascii.isHex(byte)) return error.InvalidSenderKey;
    const sender = try take(a, c.cdk_spilman_secret_key_to_pubkey(identity.secret_key_hex));
    // Login matches x-only keys; CDK and the receiver need the true compressed key.
    const identity_hex = std.fmt.bytesToHex(identity.pubkey, .lower);
    if ((identity.pubkey[0] != 2 and identity.pubkey[0] != 3) or sender.len != identity_hex.len or
        !std.mem.eql(u8, sender[2..], identity_hex[2..])) return error.SenderIdentityMismatch;
    if (std.mem.eql(u8, sender[2..], receiver[2..])) return error.IdenticalChannelKeys;
    const secret = try take(a, c.cdk_spilman_compute_channel_secret(identity.secret_key_hex, receiver));
    const computed = try take(a, c.cdk_spilman_compute_channel_from_token(
        token,
        receiver,
        sender,
        secret,
        quote.refundTime,
        keyset,
        policy.max_output_msats,
    ));
    const params = try parse(struct {
        capacity: u64,
        funding_token_amount: u64,
        change_amount_raw: u64,
        output_keyset_id: []const u8,
        mint_url: [:0]const u8,
        unit: []const u8,
        params_json: [:0]const u8,
        proofs_json: [:0]const u8,
    }, a, computed);
    if (!std.mem.eql(u8, params.unit, "msat")) return error.WrongUnit;
    if (!std.mem.eql(u8, params.mint_url, policy.mint_url)) return error.WrongMint;
    if (params.capacity != requested_capacity_msats or params.change_amount_raw != 0) return error.FundingCapacityMismatch;
    if (params.params_json.len > protocol.max_channel_params_bytes) return error.ParamsTooLarge;
    if (params.funding_token_amount > policy.max_output_msats or ks.keys != .object) return error.FundingLayoutMismatch;

    const swap = try take(a, c.cdk_spilman_create_funding_swap(params.params_json, secret, keyset, params.proofs_json));
    const funding = try parse(struct {
        swap_request_json: [:0]const u8,
        funding_secrets_json: [:0]const u8,
        funding_count: usize,
    }, a, swap);
    const secrets = try parse([]struct { secret: []const u8, amount: u64 }, a, funding.funding_secrets_json);
    const request = try parse(SwapLayout, a, funding.swap_request_json);
    if (secrets.len == 0 or secrets.len != request.outputs.len or secrets.len != funding.funding_count)
        return error.FundingLayoutMismatch;
    var denominations: u64 = 0;
    var proof_bytes: usize = 1; // '[' and one comma or ']' per proof
    for (secrets, request.outputs) |secret_out, output| {
        if (secret_out.amount != output.amount or !std.math.isPowerOfTwo(output.amount) or
            denominations & output.amount != 0 or !std.mem.eql(u8, output.id, params.output_keyset_id))
            return error.FundingLayoutMismatch;
        denominations |= output.amount;
        proof_bytes += 1 + try proofSize(a, output.amount, output.id, secret_out.secret);
    }
    if (denominations != params.funding_token_amount) return error.FundingLayoutMismatch;

    return .{ .mint_url = params.mint_url, .request_json = funding.swap_request_json, .proof_bytes = proof_bytes, .material = .{
        .capacity_msats = params.capacity,
        .refund_time = quote.refundTime,

        .channel_secret_hex = secret,
        .params_json = params.params_json,
        .keyset_json = keyset,
        .funding_secrets_json = funding.funding_secrets_json,
    } };
}

const SwapProof = struct { id: []const u8, amount: u64 };
const SwapLayout = struct { inputs: []const SwapProof, outputs: []const SwapProof };

fn prepareExact(a: Allocator, policy: Policy, quote: protocol.SpillmanChannelRequirementsRes, amounts: Amounts, token: [:0]const u8, keyset: [:0]const u8, sender: Sender) !Prepared {
    const prepared = try prepare(a, policy, quote, amounts.capacity, token, keyset, sender);
    try checkLayout(a, prepared, amounts, policy.input_fee_ppk);
    return prepared;
}

fn checkLayout(a: Allocator, prepared: Prepared, amounts: Amounts, fee_ppk: u64) !void {
    const swap = try parse(SwapLayout, a, prepared.request_json);
    if (swap.outputs.len == 0 or swap.inputs.len == 0) return error.FundingLayoutMismatch;
    var nominal: u64 = 0;
    for (swap.outputs) |output| nominal = try std.math.add(u64, nominal, output.amount);
    if (nominal != amounts.nominal) return error.FundingLayoutMismatch;
    var total: u64 = 0;
    for (swap.inputs) |input| {
        if (!std.mem.eql(u8, input.id, swap.outputs[0].id)) return error.FundingLayoutMismatch;
        total = try std.math.add(u64, total, input.amount);
    }
    if (total != amounts.send) return error.FundingLayoutMismatch;
    // The wallet may select different denominations. Only accept the quoted
    // total and the exact fee difference, with every proof in the bound keyset.
    const input_fee = try inputFee(fee_ppk, swap.inputs.len);
    if (amounts.nominal > total or total - amounts.nominal != input_fee) return error.FundingLayoutMismatch;
}

fn submit(io: std.Io, a: Allocator, journal: Journal, id: OperationId, p: Prepared, context: anytype, comptime post: anytype) !Verified {
    if (journal.tool != p.material.tool) return error.ScopeMismatch;
    // Validate/derive the ID before the first external write as well.
    const cid = try channelId(a, p.material);
    const material = try std.json.Stringify.valueAlloc(a, p.material, .{});
    try journal.prepare(io, a, id, .{ .mint_swap = .{
        .kind = .funding,
        .mint_url = p.mint_url,
        .request_json = p.request_json,
        .completion_material = material,
    } });
    const response = try post(a, context, p.mint_url, p.request_json);
    return complete(a, p.material, cid, response, protocol.max_channel_proof_bytes);
}

fn postSwap(a: Allocator, wallet: *const c.CdkWallet_t, mint: [:0]const u8, request: [:0]const u8) ![:0]const u8 {
    // The journal is already durable. An error does not authorize resubmission.
    return take(a, c.cdk_wallet_post_swap(wallet, mint, request)) catch error.FundingUnresolved;
}

fn load(io: std.Io, a: Allocator, journal: Journal, id: OperationId) !Prepared {
    const record = try journal.read(io, a, id);
    defer record.deinit();
    const swap = record.value.operation.mint_swap;
    if (swap.kind != .funding) return error.NotFundingRecord;
    const material = try std.json.parseFromSliceLeaky(Material, a, swap.completion_material, .{ .allocate = .alloc_always });
    if (material.version != 1) return error.UnsupportedFundingVersion;
    if (material.tool != journal.tool) return error.ScopeMismatch;
    if (!material.tool.validCapacity(material.capacity_msats)) return error.InvalidCapacity;
    return .{
        .mint_url = try a.dupeSentinel(u8, swap.mint_url, 0),
        .request_json = try a.dupeSentinel(u8, swap.request_json, 0),
        .material = material,
        .proof_bytes = 0, // Not used when recovering an already-journaled swap.
    };
}

fn completeRecovery(a: Allocator, p: Prepared, evidence: []const u8) !Verified {
    const parsed = try parse(struct { swap_response: ?std.json.Value }, a, evidence);
    const response = parsed.swap_response orelse return error.FundingUnresolved;
    const text = try std.json.Stringify.valueAlloc(a, response, .{});
    return complete(a, p.material, try channelId(a, p.material), try a.dupeSentinel(u8, text, 0), protocol.max_channel_proof_bytes);
}

fn channelId(a: Allocator, m: Material) ![32]u8 {
    const hex = try take(a, c.cdk_spilman_channel_parameters_get_channel_id(m.params_json, m.channel_secret_hex, m.keyset_json));
    var id: [32]u8 = undefined;
    if (hex.len != id.len * 2) return error.InvalidChannelId;
    _ = try std.fmt.hexToBytes(&id, hex);
    return id;
}

fn complete(a: Allocator, m: Material, id: [32]u8, response: [:0]const u8, proof_limit: usize) !Verified {
    const completed = try take(a, c.cdk_spilman_complete_funding_swap(response, m.funding_secrets_json, m.keyset_json));
    const proofs = (try parse(struct { funding_proofs_json: [:0]const u8 }, a, completed)).funding_proofs_json;
    if (proofs.len > proof_limit) return error.ProofTooLarge;

    const valid = c.cdk_spilman_verify_valid_channel(m.params_json, m.channel_secret_hex, m.keyset_json, proofs);
    defer c.cdk_string_free(valid.@"error");
    if (valid.status != c.CDK_STATUS_OK) return error.InvalidFundingProof;
    return .{ .id = id, .proofs = proofs };
}

fn parse(comptime T: type, a: Allocator, text: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, text, .{ .ignore_unknown_fields = true });
}

fn span(ptr: [*c]const u8) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
}

fn take(a: Allocator, result: c.CdkStringResult_t) ![:0]const u8 {
    // FFI diagnostics can contain private material; do not propagate strings.
    defer c.cdk_string_free(result.@"error");
    defer c.cdk_string_free(result.value);
    switch (result.status) {
        c.CDK_STATUS_OK => {},

        c.CDK_STATUS_OPERATION_NOT_FOUND => return error.PendingSendNotFound,
        c.CDK_STATUS_MINT_NOT_REGISTERED => return error.MintNotRegistered,
        c.CDK_STATUS_RECOVERY_PENDING => return error.WalletRecoveryPending,
        else => return error.CdkFundingFailure,
    }
    if (result.value == null) return error.CdkFundingFailure;
    return a.dupeSentinel(u8, span(result.value), 0);
}

const t = std.testing;
const TestInputs = struct {
    const policy: Policy = .{ .mint_url = "https://mint.example.com", .max_output_msats = 32 };
    const cost_per_cut = 5;
    const receiver_secret = &@as([64:0]u8, @splat('2'));
    const sender: Sender = .{
        .pubkey = blk: {
            var key: [33]u8 = undefined;
            _ = std.fmt.hexToBytes(&key, "034f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa") catch unreachable;
            break :blk key;
        },
        .secret_key_hex = &@as([64:0]u8, @splat('1')),
    };
    const keyset_id = "00891271bfa74eb8";
    const keyset =
        \\{"keyset_id":"00891271bfa74eb8","unit":"msat","input_fee_ppk":0,
        \\ "keys":{"1":"0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
        \\ "2":"02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5",
        \\ "4":"02e493dbf1c10d80f3581e4904930b1404cc6c13900ee0758474fa94abe8c4cd13",
        \\ "8":"022f01e5e15cca351daff3843fb70f3c2f0a1bdd05e5af888a67784ef3e10a2a01",
        \\ "16":"03e60fce93b59e9ec53011aabc21c23e97b2a31369b87a5ae9c44ee89e2a6dec0a",
        \\ "32":"03d30199d74fb5a22d47b6e054e2f378cedacffcb89904a61d75d0dbd407143e65"}}
    ;

    fn quote() !protocol.SpillmanChannelRequirementsRes {
        var key: [33]u8 = undefined;
        _ = try std.fmt.hexToBytes(&key, "02466d7fcae563e5cb09a0d1870bb580344804617879a14949cf22285f1bae3f27");
        return .{ .pubkey = key, .amount = cost_per_cut, .refundTime = 4_000_000_000 };
    }

    fn token(a: Allocator, amounts: []const u64, mint: [:0]const u8) ![:0]const u8 {
        return tokenForKeyset(a, amounts, mint, keyset_id);
    }

    fn tokenForKeyset(a: Allocator, amounts: []const u64, mint: [:0]const u8, id: []const u8) ![:0]const u8 {
        const proofs_data = try a.alloc(struct { amount: u64, id: []const u8, secret: []const u8, C: []const u8 }, amounts.len);
        for (proofs_data, amounts, 0..) |*proof, amount, i| proof.* = .{
            .amount = amount,
            .id = id,
            .secret = try std.fmt.allocPrint(a, "test-input-{d}", .{i}),
            .C = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
        };
        const proofs = try std.json.Stringify.valueAlloc(a, proofs_data, .{});
        return take(a, c.cdk_spilman_build_cashu_b_token(mint, "msat", try a.dupeSentinel(u8, proofs, 0)));
    }
};

test "funding preflight requires exact derived capacity and supports split funding" {
    t.refAllDecls(@This());
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = TestInputs;
    const q = try f.quote();
    const wallet: *const c.CdkWallet_t = @ptrFromInt(1); // Invalid capacity must fail before reading the wallet.
    for ([_]u64{ 0, 14, 55 }) |capacity| {
        try t.expectError(error.InvalidCapacity, preflight(t.io, a, wallet, @splat(1), f.policy, q, .{
            .capacity = capacity,
            .nominal = capacity,
            .send = capacity,
        }, f.keyset, f.sender));
    }
    try validateQuote(f.policy, q, q.refundTime - 1);
    try t.expectError(error.InvalidQuote, validateQuote(f.policy, q, q.refundTime));
    var zero_price = q;
    zero_price.amount = 0;
    try t.expectError(error.InvalidQuote, prepare(a, f.policy, zero_price, 5, "", f.keyset, f.sender));
    try t.expectError(error.InvalidCapacity, prepare(a, f.policy, q, 0, "", f.keyset, f.sender));
    try t.expectError(error.InvalidCapacity, prepare(a, f.policy, q, 4, "", f.keyset, f.sender));
    const policy_64: Policy = .{ .mint_url = f.policy.mint_url, .max_output_msats = 64 };
    const keyset_64 = f.keyset[0 .. f.keyset.len - 2] ++
        ",\"64\":\"03bf23c1542d16eab70b1051eaf832823cfc4c6f1dcdbafd81e37918e6f874ef8b\"}}";
    const power_of_two = try f.token(a, &.{64}, policy_64.mint_url);
    const prepared = try prepare(a, policy_64, q, 64, power_of_two, keyset_64, f.sender);
    try t.expectEqual(@as(u64, 64), prepared.material.capacity_msats);
    try t.expectError(error.FundingCapacityMismatch, prepare(a, policy_64, q, 60, power_of_two, keyset_64, f.sender));
    const wrong = try f.token(a, &.{8}, "https://wrong.example.com");
    try t.expectError(error.WrongMint, prepare(a, f.policy, q, 5, wrong, f.keyset, f.sender));
    var wrong_identity = f.sender;
    wrong_identity.pubkey = q.pubkey;
    try t.expectError(error.SenderIdentityMismatch, prepare(a, f.policy, q, 5, wrong, f.keyset, wrong_identity));
    var same_receiver = q;
    same_receiver.pubkey = f.sender.pubkey;
    same_receiver.pubkey[0] = 2;
    try t.expectError(error.IdenticalChannelKeys, prepare(a, f.policy, same_receiver, 5, wrong, f.keyset, f.sender));
    const expiring = f.keyset[0 .. f.keyset.len - 1] ++ ",\"finalExpiry\":1}";
    try t.expectError(error.KeysetExpiresBeforeRefund, prepare(a, f.policy, q, 5, wrong, expiring, f.sender));
    const token = try f.token(a, &.{8}, f.policy.mint_url);
    try t.expectError(error.FundingCapacityMismatch, prepare(a, f.policy, q, 5, token, f.keyset, f.sender));
    try t.expectError(error.FundingCapacityMismatch, prepare(a, f.policy, q, 10, token, f.keyset, f.sender));
    const split = try f.token(a, &.{ 8, 2 }, f.policy.mint_url);
    try t.expectEqual(10, (try prepare(a, f.policy, q, 10, split, f.keyset, f.sender)).material.capacity_msats);
}

test "Testnut fee preflight turns a 17 msat pending token into one 16 msat proof and 14 msat capacity" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = TestInputs;
    const q = try f.quote();
    const policy: Policy = .{ .mint_url = "https://testnut.cashu.space", .max_output_msats = 1_000_000, .input_fee_ppk = 100, .max_sender_fee_msats = 2 };
    const keyset = try a.dupeSentinel(u8, try std.mem.replaceOwned(u8, a, f.keyset, "\"input_fee_ppk\":0", "\"input_fee_ppk\":100"), 0);
    const amounts: Amounts = .{ .nominal = try nominalForCapacity(14, keyset, policy.max_output_msats), .capacity = 14, .send = 17 };
    try t.expectEqual(16, amounts.nominal);
    try t.expectEqual(1, try inputFee(policy.input_fee_ppk, 2));
    try t.expectEqual(1, try inputFee(policy.input_fee_ppk, 10));
    try t.expectEqual(2, try inputFee(policy.input_fee_ppk, 11));
    const token = try f.token(a, &.{ 16, 1 }, policy.mint_url);
    const prepared = try prepareExact(a, policy, q, amounts, token, keyset, f.sender);
    try t.expectEqual(14, prepared.material.capacity_msats);
    const layout = try parse(SwapLayout, a, prepared.request_json);
    try t.expectEqual(1, layout.outputs.len);
    try t.expectEqual(16, layout.outputs[0].amount);

    const alternate = try f.token(a, &.{ 8, 8, 1 }, policy.mint_url);
    _ = try prepareExact(a, policy, q, amounts, alternate, keyset, f.sender);
    var wrong_capacity = amounts;
    wrong_capacity.capacity = amounts.nominal;
    try t.expectError(error.FundingCapacityMismatch, prepareExact(a, policy, q, wrong_capacity, token, keyset, f.sender));
    const zero_fee_token = try f.token(a, &.{32}, f.policy.mint_url);
    _ = try prepareExact(a, f.policy, q, .{ .capacity = 32, .nominal = 32, .send = 32 }, zero_fee_token, f.keyset, f.sender);
}

const TestOutput = struct { B_: []const u8, id: []const u8, amount: u64 };
const TestSignature = struct { amount: u64, id: []const u8, C_: [66]u8, dleq: struct { e: [64]u8, s: [64]u8 } };

// Offline mint response: each fixture denomination is keyed by its amount.
fn testSign(output: TestOutput) !TestSignature {
    const Curve = std.crypto.ecc.Secp256k1;
    var blinded: [33]u8 = undefined;
    _ = try std.fmt.hexToBytes(&blinded, output.B_);
    const b = try Curve.fromSec1(&blinded);
    const nonce = @as([31]u8, @splat(0)) ++ [_]u8{7};
    const r1 = try Curve.basePoint.mul(nonce, .big);
    const r2 = try b.mul(nonce, .big);
    var mint_scalar: [32]u8 = @splat(0);
    std.mem.writeInt(u64, mint_scalar[24..], output.amount, .big);
    const mint_pubkey = try Curve.basePoint.mul(mint_scalar, .big);
    const signature = try b.mul(mint_scalar, .big);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for ([_]Curve{ r1, r2, mint_pubkey, signature }) |point| {
        hash.update(&std.fmt.bytesToHex(point.toUncompressedSec1(), .lower));
    }
    const e = hash.finalResult();
    const s = (try Curve.scalar.Scalar.fromBytes(e, .big)).mul(try .fromBytes(mint_scalar, .big)).add(try .fromBytes(nonce, .big)).toBytes(.big);
    return .{
        .amount = output.amount,
        .id = output.id,
        .C_ = std.fmt.bytesToHex(signature.toCompressedSec1(), .lower),
        .dleq = .{ .e = std.fmt.bytesToHex(e, .lower), .s = std.fmt.bytesToHex(s, .lower) },
    };
}

fn testResponse(a: Allocator, request_json: []const u8) ![:0]const u8 {
    const outputs = (try parse(struct { outputs: []TestOutput }, a, request_json)).outputs;
    const signatures = try a.alloc(TestSignature, outputs.len);
    for (signatures, outputs) |*sig, output| sig.* = try testSign(output);
    const text = try std.json.Stringify.valueAlloc(a, .{ .signatures = signatures }, .{});
    return a.dupeSentinel(u8, text, 0);
}

test "both mint fee policies produce and verify exactly ten cuts for each tool" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = TestInputs;
    var q = try f.quote();
    var keys: std.json.ArrayHashMap([66]u8) = .{};
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (0..7) |shift| {
        const amount = @as(u64, 1) << @intCast(shift);
        var scalar: [32]u8 = @splat(0);
        std.mem.writeInt(u64, scalar[24..], amount, .big);
        const key = try std.crypto.ecc.Secp256k1.basePoint.mul(scalar, .big);
        const compressed = key.toCompressedSec1();
        hash.update(&compressed);
        try keys.map.put(a, try std.fmt.allocPrint(a, "{d}", .{amount}), std.fmt.bytesToHex(compressed, .lower));
    }
    const digest = hash.finalResult();
    const keyset_id = "00" ++ std.fmt.bytesToHex(digest[0..7].*, .lower);
    for ([_]u64{ 0, 100 }) |ppk| {
        const policy: Policy = .{ .mint_url = f.policy.mint_url, .max_output_msats = 1_000_000, .input_fee_ppk = ppk };
        const text = try std.json.Stringify.valueAlloc(a, .{ .keyset_id = keyset_id, .unit = "msat", .input_fee_ppk = ppk, .keys = keys }, .{});
        const keyset = try a.dupeSentinel(u8, text, 0);
        for (protocol.tools) |tool| {
            q.amount = tool.priceMsat();
            const capacity = cuts * q.amount;
            const nominal = try nominalForCapacity(capacity, keyset, policy.max_output_msats);
            const send = nominal + try inputFee(ppk, @popCount(nominal));
            const amounts: Amounts = .{ .capacity = capacity, .nominal = nominal, .send = send };
            var input_buffer: [64]u64 = undefined;
            var remaining = send;
            const inputs = input_buffer[0..@popCount(send)];
            for (inputs) |*input| {
                input.* = @as(u64, 1) << @intCast(@ctz(remaining));
                remaining ^= input.*;
            }
            const token = try f.tokenForKeyset(a, inputs, policy.mint_url, keyset_id);
            const prepared = try prepareExact(a, policy, q, amounts, token, keyset, f.sender);
            try t.expectEqual(capacity, prepared.material.capacity_msats);
            try t.expectEqual(try quotedProofBytes(a, nominal, keyset_id, q.refundTime), prepared.proof_bytes);
            const id = try channelId(a, prepared.material);
            const response = try testResponse(a, prepared.request_json);
            try t.expectError(error.ProofTooLarge, complete(a, prepared.material, id, response, 1024));
            const verified = try complete(a, prepared.material, id, response, 8192);
            try t.expectEqual(prepared.proof_bytes, verified.proofs.len);
            try t.expectEqual(@popCount(nominal), (try parse([]SwapProof, a, verified.proofs)).len);
            for (1..cuts + 1) |cut| {
                _ = try take(a, c.cdk_spilman_create_signed_balance_update(prepared.material.params_json, keyset, f.sender.secret_key_hex, verified.proofs, cut * q.amount));
            }
        }
    }
}

test "ambiguous funding is journaled before POST and recovery verifies the exact output" {
    const sf = @import("storage_fs.zig");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "root", sf.mode_dir);
    const tmp_dir = try tmp.dir.openDir(t.io, ".", .{ .iterate = true });
    defer tmp_dir.close(t.io);
    try sf.syncDirectory(tmp_dir);
    const root = try tmp.dir.realPathFileAlloc(t.io, "root", t.allocator);
    defer t.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = TestInputs;
    var q = try f.quote();
    q.amount = protocol.tool.pickaxe.priceMsat();
    // 33 msat input -> 32 msat funding proof -> 31 -> 30 msat spendable after fees.
    const token = try f.token(a, &.{ 32, 1 }, f.policy.mint_url);
    const fee_keyset = try a.dupeSentinel(u8, try std.mem.replaceOwned(u8, a, f.keyset, "\"input_fee_ppk\":0", "\"input_fee_ppk\":100"), 0);
    var identity = f.sender;
    identity.pubkey[0] = 2; // The server normalizes the odd-Y login key.
    var fee_policy = f.policy;
    fee_policy.input_fee_ppk = 100;
    var p = try prepareExact(a, fee_policy, q, .{ .capacity = 30, .nominal = 32, .send = 33 }, token, fee_keyset, identity);
    p.material.tool = .pickaxe;
    const terms: Amounts = .{ .capacity = 14, .nominal = 16, .send = 17 };
    const exact = try f.token(a, &.{ 1, 16 }, f.policy.mint_url);
    try checkLayout(a, try prepare(a, f.policy, q, terms.capacity, exact, fee_keyset, identity), terms, 100);
    const other_layout = try f.token(a, &.{ 8, 8, 1 }, f.policy.mint_url);
    try checkLayout(a, try prepare(a, f.policy, q, terms.capacity, other_layout, fee_keyset, identity), terms, 100);
    const id: OperationId = @splat(41);
    const Fake = struct {
        journal: Journal,
        calls: usize = 0,

        fn post(a2: Allocator, self: *@This(), mint: [:0]const u8, request: [:0]const u8) ![:0]const u8 {
            self.calls += 1;
            const saved = try load(t.io, a2, self.journal, id);
            try t.expectEqualStrings(saved.mint_url, mint);
            try t.expectEqualStrings(saved.request_json, request);
            return error.FundingUnresolved;
        }
    };
    {
        const journal = try Journal.openTool(t.io, root, .pickaxe);
        defer journal.close(t.io);
        var fake: Fake = .{ .journal = journal };
        var oversized = p;
        const too_large = try a.allocSentinel(u8, 1024 * 1024, 0);
        @memset(too_large, 'x');
        oversized.request_json = too_large;
        try t.expectError(error.RecordTooLarge, submit(t.io, a, journal, id, oversized, &fake, Fake.post));
        try t.expectEqual(@as(usize, 0), fake.calls);
        try t.expectError(error.FundingUnresolved, submit(t.io, a, journal, id, p, &fake, Fake.post));
        try t.expectError(error.AlreadyPending, submit(t.io, a, journal, id, p, &fake, Fake.post));
        try t.expectEqual(@as(usize, 1), fake.calls);
    }
    const journal = try Journal.openTool(t.io, root, .pickaxe);
    defer journal.close(t.io);
    const saved = try load(t.io, a, journal, id);
    try t.expectEqualDeep(p.material, saved.material);
    try t.expectEqualStrings(p.mint_url, saved.mint_url);
    try t.expectEqualStrings(p.request_json, saved.request_json);
    try t.expectError(error.FundingUnresolved, completeRecovery(a, saved, "{\"input_states\":[\"UNSPENT\"],\"swap_response\":null}"));
    const response = try testResponse(a, saved.request_json);
    const evidence = try std.fmt.allocPrint(a, "{{\"input_states\":[\"SPENT\"],\"swap_response\":{s}}}", .{response});
    const verified = try completeRecovery(a, saved, evidence);
    try t.expectEqual(try channelId(a, p.material), verified.id);
    try t.expectEqual(p.proof_bytes, verified.proofs.len);
    try t.expectEqual(p.proof_bytes, try quotedProofBytes(a, 32, f.keyset_id, q.refundTime));
    try t.expect(verified.proofs.len <= protocol.max_channel_proof_bytes);
    const channel = verified.owned(arena, id, saved);
    const open = channel.openPayload();
    try t.expectEqual(protocol.tool.pickaxe, open.tool);
    try t.expectEqual(verified.id, open.id);
    try t.expectEqualStrings(verified.proofs, open.proof);
    try t.expectEqualStrings(saved.material.params_json, open.params);
    const params = try parse(struct { sender_pubkey: [:0]const u8, capacity: u64, funding_token_amount: u64 }, a, open.params);
    try t.expectEqual(@as(u64, 3) * q.amount, channel.capacity_msats);
    try t.expectEqual(channel.capacity_msats, params.capacity);
    try t.expectEqual(@as(u64, 32), params.funding_token_amount);
    try t.expectEqualStrings(&std.fmt.bytesToHex(f.sender.pubkey, .lower), params.sender_pubkey);
    const receiver_secret = try take(a, c.cdk_spilman_compute_channel_secret(f.receiver_secret, params.sender_pubkey));
    try t.expectEqualStrings(saved.material.channel_secret_hex, receiver_secret);
    try t.expectError(error.CdkFundingFailure, completeRecovery(a, saved, "{\"input_states\":[\"SPENT\"],\"swap_response\":{\"signatures\":[]}}"));
    _ = try load(t.io, a, journal, id);

    // Hand off the actual recovered channel through the desktop ABI, then
    // verify exact material and funding association after reopening.
    var scope: client.Scope = .{ .server = "wss://game.example/play", .player = f.sender.pubkey, .receiver = q.pubkey, .tool = .pickaxe };
    {
        const store = try client.Store.open(t.io, root, scope);
        defer store.close(t.io);
        try t.expectError(error.FileNotFound, store.retireFundingAfterWalletRecovery(t.io, a, journal, channel.id));
        var mismatch = channel;
        mismatch.keyset_json = "{}";
        try t.expectError(error.FundingMismatch, store.saveFunded(t.io, a, journal, mismatch));
        try store.saveFunded(t.io, a, journal, channel);
        try store.saveFunded(t.io, a, journal, channel);
        mismatch = channel;
        mismatch.funding_proofs_json = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "{s}\n", .{channel.funding_proofs_json}), 0);
        try t.expectError(error.ChannelConflict, store.saveFunded(t.io, a, journal, mismatch));
    }
    {
        const store = try client.Store.open(t.io, root, scope);
        defer store.close(t.io);
        const ids = try store.list(t.io, a);
        try t.expectEqualSlices(client.Id, &.{channel.id}, ids);
        const funded = try store.read(t.io, a, channel.id);
        defer funded.deinit();
        const material = funded.value.channel;
        try t.expectEqual(channel.operation_id, material.operation_id);
        try t.expectEqual(channel.capacity_msats, material.capacity_msats);
        try t.expectEqual(channel.refund_time, material.refund_time);
        try t.expectEqualStrings(channel.mint_url, material.mint_url);
        try t.expectEqualStrings(channel.params_json, material.params_json);
        try t.expectEqualStrings(channel.keyset_json, material.keyset_json);
        try t.expectEqualStrings(channel.channel_secret_hex, material.channel_secret_hex);
        try t.expectEqualStrings(channel.funding_proofs_json, material.funding_proofs_json);
        try store.retireFundingAfterWalletRecovery(t.io, a, journal, channel.id);
        try store.retireFundingAfterWalletRecovery(t.io, a, journal, channel.id);
        try t.expectError(error.FileNotFound, journal.read(t.io, a, id));
        try store.saveFunded(t.io, a, journal, channel);
    }
    scope.server = "wss://other.example/play";
    const other = try client.Store.open(t.io, root, scope);
    defer other.close(t.io);
    try t.expectEqual(@as(usize, 0), (try other.list(t.io, a)).len);
    try t.expectError(error.FileNotFound, other.read(t.io, a, channel.id));
    try t.expectError(error.ChannelConflict, other.saveFunded(t.io, a, journal, channel));
}

test "new tool expiries cannot alias even with identical channel capacities" {
    for (1000..1006) |expiry| {
        for (protocol.tools) |tool| {
            const result = toolRefundTime(tool, expiry);
            try t.expect(result <= expiry and expiry - result < protocol.tools.len);
            try t.expectEqual(@as(u64, @backingInt(tool)), result % protocol.tools.len);
        }
    }
}
