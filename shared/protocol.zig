//! Typed v1 contract; no serialization or runtime dependencies.
const world = @import("world.zig");
pub const version: u16 = 1;
pub const max_area_chunks = 64;
pub const max_request_bytes = 128;
pub const max_response_bytes = 2122;
pub const Id = [16]u8;
pub const min_chunk: i32 = -134217728;
pub const max_chunk: i32 = 134217727;
pub const Cut = struct { x: i32, y: i32 };
pub const Location = packed struct(u64) { x: i32, y: i32 };
pub const AuthKind = enum(u8) { challenge = 0xf0, proof = 0xf1, authenticated = 0xf2 };
pub const AuthProof = struct { pubkey: [33]u8, signature: [64]u8 };
pub const AuthMessage = union(AuthKind) { challenge: [32]u8, proof: AuthProof, authenticated: void };
pub const Request = struct {
    version: u16 = version,
    request_id: Id,
    operation: union(enum) { cut: Cut, read_area: world.ChunkRange, update_location: Location },
};
pub const ErrorCode = enum(u16) {
    invalid_request = 1,
    unsupported_version = 2,
    unknown_operation = 3,
    unsupported_message = 4,
    too_large = 5,
    out_of_bounds = 6,
    invalid_area = 7,
    area_too_large = 8,
    not_cuttable = 9,
    already_cut = 10,
    request_id_conflict = 11,
    server_busy = 12,
    internal_error = 13,
};
pub const State = struct { x: i32, y: i32, terrain: world.Tile, cut: bool };
pub const Failure = struct { code: ErrorCode, current: ?State = null };
pub const CutResult = union(enum) { success: State, failure: Failure };
pub const Snapshot = struct {
    area: world.ChunkRange,
    count: u16,
    chunks: [64][32]u8 = @splat(@splat(0)),
};
pub const Response = struct {
    request_id: ?Id,
    result: union(enum) { cut: State, snapshot: *const Snapshot, failure: Failure, location_updated: void },
};
