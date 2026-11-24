//! Typed message contract; serialization lives in wire.zig.
const std = @import("std");
const world = @import("world.zig");
pub const hoe_price_msat: u64 = 5;
pub const hoe_refill_cuts: u64 = 10;
pub const large_tool_refill_cuts: u64 = 20;
pub const max_tool_channel_cuts: u64 = 40;
pub const hoe_capacity_msat = hoe_price_msat * hoe_refill_cuts;

pub fn validHoeCapacity(capacity_msat: u64) bool {
    return tool.hoe.validCapacity(capacity_msat);
}

pub const max_area_chunks = 64;
pub const max_gameplay_request_bytes = 256;
pub const max_request_bytes = max_channel_open_with_params_bytes;
pub const max_channel_proof_bytes = 8192;
pub const max_channel_params_bytes = 4096;
// Envelope, five TLV headers, and the request ID, channel ID, tool, proof and params values.
pub const max_channel_open_with_params_bytes = 4 + 5 * 3 + @sizeOf(Id) + 32 + 1 + max_channel_proof_bytes + max_channel_params_bytes;
pub const snapshot_metadata_bytes = 16 + 4 + 32 + 2;
pub const chunk_bytes = 32;
// Envelope, request ID TLV, outcome TLV header, and fixed snapshot metadata.
pub const area_response_overhead = 4 + 3 + @sizeOf(Id) + 3 + snapshot_metadata_bytes;
pub const max_response_bytes = area_response_overhead + max_area_chunks * chunk_bytes;
// Match the wallet receive bridge limit. Cut prizes bypass the gameplay mailbox.
pub const max_prize_token_bytes = 4096;
pub const max_cut_reply_bytes = close_reply_overhead + 10 + max_prize_token_bytes;
// Separate from the gameplay buffer limit. The envelope body length is u16.
pub const max_sender_change_proofs_bytes = 60 * 1024;
pub const close_reply_overhead = 4 + 3 + @sizeOf(Id) + 3;
pub const max_channel_close_reply_bytes = close_reply_overhead + @sizeOf(u16);
pub const channel_status_reply_overhead = close_reply_overhead + 2 * @sizeOf(u64) + 1;
pub const max_channel_status_reply_bytes = channel_status_reply_overhead + max_sender_change_proofs_bytes;
pub const Id = [16]u8;
pub const min_chunk: i32 = -134217728;
pub const max_chunk: i32 = 134217727;

pub const AreaGeometry = struct { cols: usize, rows: usize, count: u16 };

pub fn areaGeometry(area: world.ChunkRange) error{ InvalidArea, OutOfBounds, AreaTooLarge }!AreaGeometry {
    if (area.cx0 > area.cx1 or area.cy0 > area.cy1) return error.InvalidArea;
    if (area.cx0 < min_chunk or area.cy0 < min_chunk or area.cx1 > max_chunk or area.cy1 > max_chunk) return error.OutOfBounds;
    const cols = @as(i64, area.cx1) - area.cx0 + 1;
    const rows = @as(i64, area.cy1) - area.cy0 + 1;
    const count = cols * rows;
    if (count > max_area_chunks) return error.AreaTooLarge;
    return .{ .cols = @intCast(cols), .rows = @intCast(rows), .count = @intCast(count) };
}
test "area geometry checks order, coordinate bounds, and the 64 chunk limit" {
    try std.testing.expectEqual(AreaGeometry{ .cols = 8, .rows = 8, .count = 64 }, try areaGeometry(.{ .cx0 = min_chunk, .cy0 = max_chunk - 7, .cx1 = min_chunk + 7, .cy1 = max_chunk }));
    try std.testing.expectError(error.AreaTooLarge, areaGeometry(.{ .cx0 = 0, .cy0 = 0, .cx1 = 64, .cy1 = 0 }));
    try std.testing.expectError(error.InvalidArea, areaGeometry(.{ .cx0 = 1, .cy0 = 0, .cx1 = 0, .cy1 = 0 }));
    try std.testing.expectError(error.OutOfBounds, areaGeometry(.{ .cx0 = std.math.minInt(i32), .cy0 = 0, .cx1 = std.math.maxInt(i32), .cy1 = 0 }));
}

pub const Cut = struct {
    x: i32,
    y: i32,
    payment: ?SpillmanChannelPayment = null,
    tool: tool = .hoe,
};
/// World tile coordinates; each axis spans the full signed i32 range.
pub const Location = packed struct(u64) { x: i32, y: i32 };

pub const AuthKind = enum(u8) { challenge = 0xf0, proof = 0xf1, reply = 0xf2 };
pub const AuthProof = struct { pubkey: [33]u8, signature: [64]u8 };
pub const AuthFailure = enum(u16) { invalid_credentials = 1, unavailable = 2 };
pub const AuthOutcome = union(enum) {
    ok: Location,
    failed: AuthFailure,
    ok_with_tool_channels: struct {
        location: Location,
        channels: ToolChannels,
    },
    ok_with_hoe_channel: struct {
        location: Location,
        hoe_channel_id: [32]u8,
        hoe_channel_capacity_msat: u64,
        /// Cumulative balance accepted by the receiver, not the remaining capacity.
        hoe_channel_balance_msat: u64,
    },
};
pub const AuthMessage = union(AuthKind) { challenge: [32]u8, proof: AuthProof, reply: AuthOutcome };

pub const ToolChannel = struct {
    id: [32]u8,
    capacity_msat: u64,
    balance_msat: u64,
};
pub const ToolChannels = [tools.len]?ToolChannel;

pub const tool = enum(u8) {
    axe = 0,
    hoe = 1,
    pickaxe = 2,

    pub fn priceMsat(self: tool) u64 {
        return switch (self) {
            .axe => 2,
            .hoe => hoe_price_msat,
            .pickaxe => 10,
        };
    }

    pub fn validCapacity(self: tool, capacity_msat: u64) bool {
        const price = self.priceMsat();
        return capacity_msat != 0 and capacity_msat <= price * max_tool_channel_cuts and capacity_msat % price == 0;
    }

    pub fn terrain(self: tool) world.Tile {
        return switch (self) {
            .axe => .tree,
            .hoe => .grass,
            .pickaxe => .rock,
        };
    }
};
pub const tools = std.enums.values(tool);

// Client spillman requests
pub const SpillmanChannelRequirementsReq = struct { tool: tool };
pub const SpillmanChannelRequirementsRes = struct {
    pubkey: [33]u8,
    amount: u64,
    // absolute unix time in seconds
    refundTime: u64,
};

pub const SpillmanChannelPayment = struct { id: [32]u8, amount: u64, signature: [64]u8 };
pub const SpillmanChannelClosing = struct {
    id: [32]u8,
    /// Opt in to cooperative close at this exact cumulative accepted payment.
    /// Omission preserves the depleted-only close behavior.
    expected_balance_msat: ?u64 = null,
};
pub const ChannelStatusRequest = struct { id: [32]u8 };

pub const SpillmanChannelClosingRequest = SpillmanChannelClosing;
/// Proof and canonical CDK params JSON are opaque to the wire codec. Decoding borrows both slices.
pub const SpillmanChannelOpen = struct {
    id: [32]u8,
    proof: []const u8,
    params: []const u8,
    tool: tool = .hoe,
};

pub const Kind = enum { cut, read_area, update_location, channel_requirements, channel_open, channel_close, channel_status };
pub fn isChannel(kind: Kind) bool {
    return switch (kind) {
        .cut, .read_area, .update_location => false,
        else => true,
    };
}

pub const Request = struct {
    request_id: Id,
    operation: union(Kind) {
        cut: Cut,
        read_area: world.ChunkRange,
        update_location: Location,
        channel_requirements: SpillmanChannelRequirementsReq,
        channel_open: SpillmanChannelOpen,

        channel_close: SpillmanChannelClosing,
        channel_status: ChannelStatusRequest,
    },
};

pub fn Payload(comptime kind: Kind) type {
    return @FieldType(@FieldType(Request, "operation"), @tagName(kind));
}

pub fn RequestFor(comptime kind: Kind) type {
    return struct {
        request_id: Id,
        payload: Payload(kind),
    };
}

pub const State = struct {
    x: i32,
    y: i32,
    terrain: world.Tile,
    cut: bool,
    /// Cashu bearer token, successful cuts only. Borrowed from the frame on decode.
    prize_token: ?[]const u8 = null,
};
pub const CutFailure = union(enum(u16)) {
    invalid_request: void = 1,
    not_cuttable: void = 9,
    already_cut: State = 10,
    request_id_conflict: void = 11,
    server_busy: void = 12,
};
pub const AreaFailure = enum(u16) { invalid_request = 1, out_of_bounds = 6, invalid_area = 7, area_too_large = 8, server_busy = 12 };
pub const LocationFailure = enum(u16) { invalid_request = 1, server_busy = 12 };
pub const ChannelRequirementsFailure = enum(u16) { invalid_request = 1, server_busy = 12, unavailable = 20 };
pub const ChannelOpenFailure = enum(u16) { invalid_request = 1, server_busy = 12, unavailable = 20, invalid_proof = 21 };

pub const ChannelCloseFailure = enum(u16) {
    invalid_request = 1,
    server_busy = 12,
    unavailable = 20,
    close_rejected = 23,

    settlement_pending = 25,
};

pub const ChannelStatusFailure = enum(u16) { invalid_request = 1, server_busy = 12, unavailable = 20, not_found = 26 };
pub const ChannelPhase = enum(u8) { active = 0, depleted = 1, settlement_pending = 2, settled = 3, sender_refund_required = 4 };
pub const ChannelStatusSuccess = struct {
    capacity_msat: u64,
    /// Cumulative receiver balance; remaining capacity is capacity minus balance.
    balance_msat: u64,
    phase: ChannelPhase,
    /// Sender-only proofs, borrowed from the input frame on decode.
    sender_proofs: ?[]const u8 = null,
};
pub const Snapshot = struct {
    area: world.ChunkRange,
    count: u16,
    // Chunks are row-major within area. Within each chunk, bit y * CT + x
    // is stored least-significant-bit first at that tile's local address.
    chunks: [max_area_chunks][chunk_bytes]u8 = @splat(@splat(0)),
};

pub fn Success(comptime kind: Kind) type {
    return switch (kind) {
        .cut => State,
        .read_area => *const Snapshot,
        .channel_requirements => SpillmanChannelRequirementsRes,
        .channel_status => ChannelStatusSuccess,
        .update_location, .channel_open, .channel_close => void,
    };
}

pub fn FailureFor(comptime kind: Kind) type {
    return switch (kind) {
        .cut => CutFailure,
        .read_area => AreaFailure,
        .update_location => LocationFailure,
        .channel_requirements => ChannelRequirementsFailure,
        .channel_open => ChannelOpenFailure,

        .channel_close => ChannelCloseFailure,
        .channel_status => ChannelStatusFailure,
    };
}

pub fn Outcome(comptime kind: Kind) type {
    return union(enum) { ok: Success(kind), failed: FailureFor(kind) };
}
