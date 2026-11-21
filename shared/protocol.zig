//! Typed message contract; serialization lives in wire.zig.
const world = @import("world.zig");
pub const max_area_chunks = 64;
pub const max_gameplay_request_bytes = 256;
// One serialized Spilman funding proof from the fixture fits with framing.
pub const max_request_bytes = 1024;
// Envelope, request ID TLV, channel ID TLV, proof TLV header.
pub const max_channel_proof_bytes = max_request_bytes - (4 + 3 + @sizeOf(Id) + 3 + 32 + 3);
pub const snapshot_metadata_bytes = 16 + 4 + 32 + 2;
pub const chunk_bytes = 32;
// Envelope, request ID TLV, outcome TLV, and maximum snapshot value.
pub const max_response_bytes = 4 + 3 + @sizeOf(Id) + 3 + snapshot_metadata_bytes + max_area_chunks * chunk_bytes;
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
    const std = @import("std");
    try std.testing.expectEqual(AreaGeometry{ .cols = 8, .rows = 8, .count = 64 }, try areaGeometry(.{ .cx0 = min_chunk, .cy0 = max_chunk - 7, .cx1 = min_chunk + 7, .cy1 = max_chunk }));
    try std.testing.expectError(error.AreaTooLarge, areaGeometry(.{ .cx0 = 0, .cy0 = 0, .cx1 = 64, .cy1 = 0 }));
    try std.testing.expectError(error.InvalidArea, areaGeometry(.{ .cx0 = 1, .cy0 = 0, .cx1 = 0, .cy1 = 0 }));
    try std.testing.expectError(error.OutOfBounds, areaGeometry(.{ .cx0 = std.math.minInt(i32), .cy0 = 0, .cx1 = std.math.maxInt(i32), .cy1 = 0 }));
}

pub const Cut = struct { x: i32, y: i32 };
pub const Location = packed struct(u64) { x: i32, y: i32 };
pub const AuthKind = enum(u8) { challenge = 0xf0, proof = 0xf1, reply = 0xf2 };
pub const AuthProof = struct { pubkey: [33]u8, signature: [64]u8 };
pub const AuthFailure = enum(u16) { invalid_credentials = 1, unavailable = 2 };
pub const AuthOutcome = union(enum) { ok: void, failed: AuthFailure };
pub const AuthMessage = union(AuthKind) { challenge: [32]u8, proof: AuthProof, reply: AuthOutcome };

pub const tool = enum(u8) { axe = 0, hoe = 1, pickaxe = 2 };

// Client spillman requests
pub const SpillmanChannelRequirementsReq = struct { tool: tool };
pub const SpillmanChannelRequirementsRes = struct {
    pubkey: [33]u8,
    amount: u64,
    // absolute unix time in seconds
    refundTime: u64,
};

pub const SpillmanChannelPayment = struct { id: [32]u8, amount: u64, signature: [64]u8 };
pub const SpillmanChannelClosing = struct { id: [32]u8 };
pub const SpillmanChannelFundsPayment = SpillmanChannelPayment;
pub const SpillmanChannelClosingRequest = SpillmanChannelClosing;
/// Funding proof bytes are opaque to the wire codec. Decoding borrows the input.
pub const SpillmanChannelOpen = struct { id: [32]u8, proof: []const u8 };

pub const Kind = enum { cut, read_area, update_location, channel_requirements, channel_open, channel_payment, channel_close };
pub fn isChannel(kind: Kind) bool {
    return switch (kind) {
        .cut, .read_area, .update_location => false,
        .channel_requirements, .channel_open, .channel_payment, .channel_close => true,
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
        channel_payment: SpillmanChannelPayment,
        channel_close: SpillmanChannelClosing,
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

pub const State = struct { x: i32, y: i32, terrain: world.Tile, cut: bool };
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
pub const ChannelPaymentFailure = enum(u16) { invalid_request = 1, server_busy = 12, unavailable = 20, payment_rejected = 22 };
pub const ChannelCloseFailure = enum(u16) { invalid_request = 1, server_busy = 12, unavailable = 20, close_rejected = 23 };
pub const Snapshot = struct {
    area: world.ChunkRange,
    count: u16,
    chunks: [max_area_chunks][chunk_bytes]u8 = @splat(@splat(0)),
};

pub fn Success(comptime kind: Kind) type {
    return switch (kind) {
        .cut => State,
        .read_area => *const Snapshot,
        .channel_requirements => SpillmanChannelRequirementsRes,
        .update_location, .channel_open, .channel_payment, .channel_close => void,
    };
}

pub fn FailureFor(comptime kind: Kind) type {
    return switch (kind) {
        .cut => CutFailure,
        .read_area => AreaFailure,
        .update_location => LocationFailure,
        .channel_requirements => ChannelRequirementsFailure,
        .channel_open => ChannelOpenFailure,
        .channel_payment => ChannelPaymentFailure,
        .channel_close => ChannelCloseFailure,
    };
}

pub fn Outcome(comptime kind: Kind) type {
    return union(enum) { ok: Success(kind), failed: FailureFor(kind) };
}
