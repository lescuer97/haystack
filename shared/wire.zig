//! Allocation-free, explicit little-endian v1 wire format. No native struct layout.
const std = @import("std");
const p = @import("protocol.zig");
const world = @import("world.zig");
/// Separate from the gameplay header. The caller supplies storage for the fixed message length.
pub fn encodeAuth(out: []u8, message: p.AuthMessage) []const u8 {
    out[0] = @backingInt(message);
    switch (message) {
        .challenge => |nonce| {
            @memcpy(out[1..33], &nonce);
            return out[0..33];
        },
        .proof => |proof| {
            @memcpy(out[1..34], &proof.pubkey);
            @memcpy(out[34..98], &proof.signature);
            return out[0..98];
        },
        .authenticated => return out[0..1],
    }
}
/// Structural validation only; direction and cryptographic verification belong to the caller.
pub fn decodeAuth(data: []const u8, binary: bool) error{InvalidAuthentication}!p.AuthMessage {
    if (!binary or data.len == 0) return error.InvalidAuthentication;
    const kind = std.enums.fromInt(p.AuthKind, data[0]) orelse return error.InvalidAuthentication;
    switch (kind) {
        .challenge => {
            if (data.len != 33) return error.InvalidAuthentication;
            return .{ .challenge = data[1..33].* };
        },
        .proof => {
            if (data.len != 98) return error.InvalidAuthentication;
            return .{ .proof = .{ .pubkey = data[1..34].*, .signature = data[34..98].* } };
        },
        .authenticated => {
            if (data.len != 1) return error.InvalidAuthentication;
            return .authenticated;
        },
    }
}
pub const Decoded = union(enum) { request: p.Request, failure: p.Response };
pub fn failure(id: ?p.Id, code: p.ErrorCode) p.Response {
    return .{ .request_id = id, .result = .{ .failure = .{ .code = code } } };
}
pub fn decodeMessage(data: []const u8, binary: bool) Decoded {
    return if (binary) decode(data) else .{ .failure = failure(null, .unsupported_message) };
}
fn get(comptime T: type, data: []const u8, offset: usize) T {
    return std.mem.readInt(T, data[offset..][0..@sizeOf(T)], .little);
}
fn put(comptime T: type, data: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, data[offset..][0..@sizeOf(T)], value, .little);
}
pub fn decode(data: []const u8) Decoded {
    if (data.len > p.max_request_bytes) return .{ .failure = failure(null, .too_large) };
    if (data.len < 20 or data[3] != 1) return .{ .failure = failure(null, .invalid_request) };
    const id: p.Id = data[4..20].*;
    if (get(u16, data, 0) != p.version) return .{ .failure = failure(id, .unsupported_version) };
    const expected: usize = switch (data[2]) {
        1, 3 => 28,
        2 => 36,
        else => return .{ .failure = failure(id, .unknown_operation) },
    };
    if (data.len != expected) return .{ .failure = failure(id, .invalid_request) };
    return .{ .request = .{ .request_id = id, .operation = switch (data[2]) {
        1 => .{ .cut = .{ .x = get(i32, data, 20), .y = get(i32, data, 24) } },
        2 => .{ .read_area = .{ .cx0 = get(i32, data, 20), .cy0 = get(i32, data, 24), .cx1 = get(i32, data, 28), .cy1 = get(i32, data, 32) } },
        3 => .{ .update_location = .{ .x = get(i32, data, 20), .y = get(i32, data, 24) } },
        else => unreachable,
    } } };
}
fn header(out: []u8, kind: u8, id: ?p.Id) void {
    put(u16, out, 0, p.version);
    out[2] = kind;
    out[3] = @intFromBool(id != null);
    @memcpy(out[4..20], &(id orelse @as(p.Id, @splat(0))));
}
fn state(out: []u8, offset: usize, s: p.State) void {
    put(i32, out, offset, s.x);
    put(i32, out, offset + 4, s.y);
    out[offset + 8] = @intCast(@backingInt(s.terrain));
    out[offset + 9] = @intFromBool(s.cut);
}
fn rectangle(out: []u8, area: world.ChunkRange) void {
    put(i32, out, 20, area.cx0);
    put(i32, out, 24, area.cy0);
    put(i32, out, 28, area.cx1);
    put(i32, out, 32, area.cy1);
}
pub fn encodeRequest(out: *[36]u8, req: p.Request) []const u8 {
    header(out, switch (req.operation) {
        .cut => 1,
        .read_area => 2,
        .update_location => 3,
    }, req.request_id);
    put(u16, out, 0, req.version);
    switch (req.operation) {
        .update_location => |tile| {
            put(i32, out, 20, tile.x);
            put(i32, out, 24, tile.y);
            return out[0..28];
        },
        .cut => |tile| {
            put(i32, out, 20, tile.x);
            put(i32, out, 24, tile.y);
            return out[0..28];
        },
        .read_area => |area| {
            rectangle(out, area);
            return out;
        },
    }
}
pub fn encode(out: []u8, response: p.Response) []const u8 {
    switch (response.result) {
        .location_updated => {
            std.debug.assert(response.request_id != null);
            header(out, 131, response.request_id);
            return out[0..20];
        },
        .cut => |s| {
            header(out, 129, response.request_id);
            state(out, 20, s);
            return out[0..30];
        },
        .failure => |f| {
            header(out, 255, response.request_id);
            put(u16, out, 20, @backingInt(f.code));
            std.debug.assert(f.current == null or f.code == .already_cut);
            out[22] = @intFromBool(f.current != null);
            if (f.current) |s| {
                state(out, 23, s);
                return out[0..33];
            }
            return out[0..23];
        },
        .snapshot => |s| {
            std.debug.assert(s.count >= 1 and s.count <= 64);
            header(out, 130, response.request_id);
            rectangle(out, s.area);
            put(u32, out, 36, world.generator_version);
            @memcpy(out[40..72], &world.public_seed);
            put(u16, out, 72, s.count);
            for (s.chunks[0..s.count], 0..) |chunk, i| @memcpy(out[74 + i * 32 ..][0..32], &chunk);
            return out[0 .. 74 + @as(usize, s.count) * 32];
        },
    }
}
pub const ReplyError = error{InvalidReply};
fn readState(data: []const u8, offset: usize) ReplyError!p.State {
    if (data[offset + 9] > 1) return error.InvalidReply;
    return .{ .x = get(i32, data, offset), .y = get(i32, data, offset + 4), .terrain = std.enums.fromInt(world.Tile, data[offset + 8]) orelse return error.InvalidReply, .cut = data[offset + 9] == 1 };
}
/// Optional public reply decoder; uses caller-owned bitmap storage, never allocates.
pub fn decodeResponse(data: []const u8, snapshot: *p.Snapshot) ReplyError!p.Response {
    if (data.len < 20 or data[3] > 1 or get(u16, data, 0) != p.version) return error.InvalidReply;
    const id: p.Id = data[4..20].*;
    if (data[3] == 0 and !std.mem.allEqual(u8, &id, 0)) return error.InvalidReply;
    const reply_id: ?p.Id = if (data[3] == 1) id else null;
    switch (data[2]) {
        131 => {
            if (data.len != 20 or reply_id == null) return error.InvalidReply;
            return .{ .request_id = reply_id, .result = .location_updated };
        },
        129 => {
            if (data.len != 30) return error.InvalidReply;
            return .{ .request_id = reply_id, .result = .{ .cut = try readState(data, 20) } };
        },
        255 => {
            if (data.len != 23 and data.len != 33) return error.InvalidReply;
            const code = std.enums.fromInt(p.ErrorCode, get(u16, data, 20)) orelse return error.InvalidReply;
            if (data[22] > 1 or (data[22] == 1 and (code != .already_cut or data.len != 33)) or (data[22] == 0 and (code == .already_cut or data.len != 23))) return error.InvalidReply;
            return .{ .request_id = reply_id, .result = .{ .failure = .{ .code = code, .current = if (data[22] == 1) try readState(data, 23) else null } } };
        },
        130 => {
            if (data.len < 106 or data.len > p.max_response_bytes) return error.InvalidReply;
            const area = world.ChunkRange{ .cx0 = get(i32, data, 20), .cy0 = get(i32, data, 24), .cx1 = get(i32, data, 28), .cy1 = get(i32, data, 32) };
            if (area.cx0 > area.cx1 or area.cy0 > area.cy1 or area.cx0 < p.min_chunk or area.cy0 < p.min_chunk or area.cx1 > p.max_chunk or area.cy1 > p.max_chunk) return error.InvalidReply;
            const count = (@as(i64, area.cx1) - area.cx0 + 1) * (@as(i64, area.cy1) - area.cy0 + 1);
            if (count < 1 or count > 64 or get(u16, data, 72) != count or data.len != 74 + count * 32 or get(u32, data, 36) != world.generator_version or !std.mem.eql(u8, data[40..72], &world.public_seed)) return error.InvalidReply;
            snapshot.* = .{ .area = area, .count = @intCast(count) };
            for (snapshot.chunks[0..snapshot.count], 0..) |*chunk, i| @memcpy(chunk, data[74 + i * 32 ..][0..32]);
            return .{ .request_id = reply_id, .result = .{ .snapshot = snapshot } };
        },
        else => return error.InvalidReply,
    }
}
test "reply decoding rejects invalid boolean enum flags lengths and metadata" {
    var out: [p.max_response_bytes]u8 = undefined;
    var snapshot: p.Snapshot = undefined;
    const response = p.Response{ .request_id = @splat(0), .result = .{ .cut = .{ .x = -1, .y = 2, .terrain = .rock, .cut = true } } };
    _ = encode(&out, response);
    try std.testing.expectEqualDeep(response, try decodeResponse(out[0..30], &snapshot));
    out[29] = 2;
    try std.testing.expectError(error.InvalidReply, decodeResponse(out[0..30], &snapshot));
    out[29] = 1;
    out[28] = 4;
    try std.testing.expectError(error.InvalidReply, decodeResponse(out[0..30], &snapshot));
    out[28] = 2;
    out[3] = 3;
    try std.testing.expectError(error.InvalidReply, decodeResponse(out[0..30], &snapshot));
    out[3] = 1;
    try std.testing.expectError(error.InvalidReply, decodeResponse(out[0..31], &snapshot));
    out[3] = 0;
    out[4] = 1;
    try std.testing.expectError(error.InvalidReply, decodeResponse(out[0..30], &snapshot));
    _ = encode(&out, failure(null, .server_busy));
    out[20] = 14;
    try std.testing.expectError(error.InvalidReply, decodeResponse(out[0..23], &snapshot));
    out[20] = 12;
    out[22] = 2;
    try std.testing.expectError(error.InvalidReply, decodeResponse(out[0..23], &snapshot));
    var source = p.Snapshot{ .area = .{ .cx0 = -1, .cy0 = -1, .cx1 = -1, .cy1 = -1 }, .count = 1 };
    _ = encode(&out, .{ .request_id = null, .result = .{ .snapshot = &source } });
    try std.testing.expectEqual(@as(u16, 1), (try decodeResponse(out[0..106], &snapshot)).result.snapshot.count);
    out[40] ^= 1;
    try std.testing.expectError(error.InvalidReply, decodeResponse(out[0..106], &snapshot));
    out[40] ^= 1;
    out[72] = 0;
    try std.testing.expectError(error.InvalidReply, decodeResponse(out[0..106], &snapshot));
}
test "binary golden zero ID extreme coordinates request and success" {
    var buf: [36]u8 = undefined;
    const req = p.Request{ .request_id = @splat(0), .operation = .{ .cut = .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32) } } };
    const bytes = encodeRequest(&buf, req);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 255, 255, 255, 127 }, bytes);
    try std.testing.expectEqualDeep(req, decode(bytes).request);
    const area = p.Request{ .request_id = @splat(0), .operation = .{ .read_area = .{ .cx0 = -1, .cy0 = -2, .cx1 = 0, .cy1 = 1 } } };
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 254, 255, 255, 255, 0, 0, 0, 0, 1, 0, 0, 0 }, encodeRequest(&buf, area));
    try std.testing.expectEqualDeep(area, decode(&buf).request);
    var out: [p.max_response_bytes]u8 = undefined;
    const success = encode(&out, .{ .request_id = req.request_id, .result = .{ .cut = .{ .x = -1, .y = 0, .terrain = .tree, .cut = true } } });
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 129, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0, 0, 3, 1 }, success);
    const err = encode(&out, failure(null, .server_busy));
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12, 0, 0 }, err);
}
test "binary malformed flags lengths unknown operations versions and cap" {
    var buf: [129]u8 = @splat(0);
    buf[0] = 1;
    buf[2] = 1;
    buf[3] = 1;
    for ([_]usize{ 0, 19, 20, 27, 29, 36, 128 }) |n| try std.testing.expectEqual(p.ErrorCode.invalid_request, decode(buf[0..n]).failure.result.failure.code);
    try std.testing.expectEqual(p.ErrorCode.too_large, decode(&buf).failure.result.failure.code);
    buf[3] = 3;
    try std.testing.expect(decode(buf[0..28]).failure.request_id == null);
    buf[3] = 0;
    try std.testing.expect(decode(buf[0..28]).failure.request_id == null);
    buf[3] = 1;
    buf[0] = 2;
    try std.testing.expectEqual(p.ErrorCode.unsupported_version, decode(buf[0..28]).failure.result.failure.code);
    buf[0] = 1;
    buf[2] = 129;
    try std.testing.expectEqual(p.ErrorCode.unknown_operation, decode(buf[0..28]).failure.result.failure.code);
    try std.testing.expectEqual(p.ErrorCode.unsupported_message, decodeMessage(buf[0..28], false).failure.result.failure.code);
    try std.testing.expect(decodeMessage("not binary", false).failure.request_id == null);
}
test "snapshot golden metadata empty full and error state" {
    var snapshot = p.Snapshot{ .area = .{ .cx0 = -1, .cy0 = -2, .cx1 = 6, .cy1 = 5 }, .count = 64 };
    snapshot.chunks[0][0] = 1;
    snapshot.chunks[63] = @splat(255);
    var out: [p.max_response_bytes]u8 = undefined;
    const bytes = encode(&out, .{ .request_id = @splat(0), .result = .{ .snapshot = &snapshot } });
    try std.testing.expectEqual(@as(usize, 2122), bytes.len);
    try std.testing.expectEqual(@as(u8, 130), bytes[2]);
    try std.testing.expectEqual(@as(i32, -2), get(i32, bytes, 24));
    try std.testing.expectEqual(world.generator_version, get(u32, bytes, 36));
    try std.testing.expectEqualSlices(u8, &world.public_seed, bytes[40..72]);
    try std.testing.expectEqual(@as(u16, 64), get(u16, bytes, 72));
    try std.testing.expectEqual(@as(u8, 1), bytes[74]);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(255)), bytes[2090..2122]);
    snapshot.count = 1;
    try std.testing.expectEqual(@as(usize, 106), encode(&out, .{ .request_id = null, .result = .{ .snapshot = &snapshot } }).len);
    const err = encode(&out, .{ .request_id = @splat(0), .result = .{ .failure = .{ .code = .already_cut, .current = .{ .x = -1, .y = 1, .terrain = .grass, .cut = true } } } });
    try std.testing.expectEqual(@as(usize, 33), err.len);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 1, 255, 255, 255, 255, 1, 0, 0, 0, 0, 1 }, err[20..]);
}
test "location wire goldens exact lengths IDs flags and packed representation" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(p.Location));
    try std.testing.expectEqual(@as(usize, 64), @bitSizeOf(p.Location));
    var buf: [36]u8 = undefined;
    const req = p.Request{ .request_id = @splat(0), .operation = .{ .update_location = .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32) } } };
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 3, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 255, 255, 255, 127 }, encodeRequest(&buf, req));
    try std.testing.expectEqualDeep(req, decode(buf[0..28]).request);
    const locations = [_]p.Location{ .{ .x = 0, .y = 0 }, .{ .x = -1, .y = -2 }, .{ .x = 12, .y = 34 } };
    const payloads = [_][8]u8{ .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 255, 255, 255, 255, 254, 255, 255, 255 }, .{ 12, 0, 0, 0, 34, 0, 0, 0 } };
    for (locations, payloads) |location, payload| {
        const reused = p.Request{ .request_id = req.request_id, .operation = .{ .update_location = location } };
        try std.testing.expectEqualDeep(reused, decode(encodeRequest(&buf, reused)).request);
        try std.testing.expectEqualSlices(u8, &payload, buf[20..28]);
    }
    for (0..37) |n| {
        if (n != 28 and n <= buf.len) try std.testing.expect(decode(buf[0..n]) == .failure);
    }
    buf[3] = 0;
    try std.testing.expect(decode(buf[0..28]) == .failure);
    buf[3] = 2;
    try std.testing.expect(decode(buf[0..28]) == .failure);
    buf[3] = 1;
    buf[2] = 4;
    try std.testing.expectEqual(p.ErrorCode.unknown_operation, decode(buf[0..28]).failure.result.failure.code);
    var out: [p.max_response_bytes + 1]u8 = @splat(0);
    var snapshot: p.Snapshot = undefined;
    const ack = p.Response{ .request_id = @splat(0), .result = .location_updated };
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 131, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, encode(&out, ack));
    try std.testing.expectEqualDeep(ack, try decodeResponse(out[0..20], &snapshot));
    const nonzero = p.Response{ .request_id = @splat(0x45), .result = .location_updated };
    try std.testing.expectEqualDeep(nonzero, try decodeResponse(encode(&out, nonzero), &snapshot));
    _ = encode(&out, ack);
    for (0..out.len + 1) |n| {
        if (n != 20) try std.testing.expectError(error.InvalidReply, decodeResponse(out[0..n], &snapshot));
    }
    for ([_]u8{ 0, 2, 3, 255 }) |flag| {
        out[3] = flag;
        try std.testing.expectError(error.InvalidReply, decodeResponse(out[0..20], &snapshot));
    }
}
test "authentication independent byte goldens and roundtrips" {
    const cases = [_]struct { message: p.AuthMessage, golden: []const u8 }{
        .{ .message = .{ .challenge = @splat(0) }, .golden = &(.{0xf0} ++ @as([32]u8, @splat(0))) },
        .{ .message = .{ .challenge = @splat(255) }, .golden = &(.{0xf0} ++ @as([32]u8, @splat(255))) },
        .{ .message = .{ .proof = .{ .pubkey = @splat(0), .signature = @splat(255) } }, .golden = &(.{0xf1} ++ @as([33]u8, @splat(0)) ++ @as([64]u8, @splat(255))) },
        .{ .message = .{ .proof = .{ .pubkey = @splat(255), .signature = @splat(0) } }, .golden = &(.{0xf1} ++ @as([33]u8, @splat(255)) ++ @as([64]u8, @splat(0))) },
        .{ .message = .authenticated, .golden = &.{0xf2} },
    };
    var out: [98]u8 = undefined;
    for (cases) |case| {
        const encoded = encodeAuth(&out, case.message);
        try std.testing.expectEqualSlices(u8, case.golden, encoded);
        try std.testing.expectEqualDeep(case.message, try decodeAuth(case.golden, true));
        try std.testing.expectEqualDeep(case.message, try decodeAuth(encoded, true));
        try std.testing.expectError(error.InvalidAuthentication, decodeAuth(case.golden, false));
    }
}
test "authentication rejects every wrong tag length and text" {
    var buf: [129]u8 = @splat(0);
    for (0..256) |tag| {
        buf[0] = @intCast(tag);
        const expected: ?usize = switch (tag) {
            0xf0 => 33,
            0xf1 => 98,
            0xf2 => 1,
            else => null,
        };
        for (0..buf.len + 1) |n| {
            if (expected == null or n != expected.?) try std.testing.expectError(error.InvalidAuthentication, decodeAuth(buf[0..n], true));
            try std.testing.expectError(error.InvalidAuthentication, decodeAuth(buf[0..n], false));
        }
    }
}
test "random request reply and authentication decode guards" {
    var random = std.Random.DefaultPrng.init(0x73657373696f6e);
    var buf: [p.max_response_bytes + 1]u8 = undefined;
    var snapshot: p.Snapshot = undefined;
    for (0..2000) |_| {
        random.random().bytes(&buf);
        const n = random.random().uintLessThan(usize, buf.len + 1);
        _ = decode(buf[0..n]);
        _ = decodeResponse(buf[0..n], &snapshot) catch {};
        _ = decodeAuth(buf[0..n], true) catch {};
    }
}
