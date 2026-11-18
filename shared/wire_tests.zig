const std = @import("std");
const p = @import("protocol.zig");
const wire = @import("wire.zig");
const t = std.testing;

fn repeat(comptime bytes: []const u8, comptime count: usize) [bytes.len * count]u8 {
    var result: [bytes.len * count]u8 = undefined;
    for (0..count) |i| @memcpy(result[i * bytes.len ..][0..bytes.len], bytes);
    return result;
}

const id = "\x00\x01\x02\x03\x04\x05\x06\x7e\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f";
const id_tlv = "\x01\x10\x00" ++ id;
const point = "\xfe\xff\xff\xff\x04\x03\x02\x01";
const area = "\xfe\xff\xff\xff\x03\x00\x00\x00\xfe\xff\xff\xff\x03\x00\x00\x00";
const cut_frame = "\x01\x1e\x00" ++ id_tlv ++ "\x02\x08\x00" ++ point ++ "\x7e";
const area_frame = "\x02\x26\x00" ++ id_tlv ++ "\x02\x10\x00" ++ area ++ "\x7e";
const location_frame = "\x03\x1e\x00" ++ id_tlv ++ "\x02\x08\x00" ++ point ++ "\x7e";
const cut_ok = "\x81\x20\x00" ++ id_tlv ++ "\x03\x0a\x00" ++ point ++ "\x03\x01\x7e";
const cut_already = "\x81\x22\x00" ++ id_tlv ++ "\x04\x0c\x00\x0a\x00" ++ point ++ "\x03\x01\x7e";
const area_ok = "\x82\x6c\x00" ++ id_tlv ++ "\x03\x56\x00" ++ area ++
    "\x02\x00\x00\x00" ++ repeat("\x00", 32) ++ "\x01\x00" ++ repeat("\x7e\xa5", 16) ++ "\x7e";
const proof_frame = "\xf1\x67\x00\x11\x21\x00\x02" ++ repeat("\x7e", 32) ++ "\x12\x40\x00" ++ repeat("\x7e\x5a", 32) ++ "\x7e";
const protocol_error_frame = "\xff\x00\x00\x7e";

const cut_req: p.RequestFor(.cut) = .{ .request_id = id.*, .payload = .{ .x = -2, .y = 0x01020304 } };
const area_req: p.RequestFor(.read_area) = .{ .request_id = id.*, .payload = .{ .cx0 = -2, .cy0 = 3, .cx1 = -2, .cy1 = 3 } };
const location_req: p.RequestFor(.update_location) = .{ .request_id = id.*, .payload = .{ .x = -2, .y = 0x01020304 } };
const state: p.State = .{ .x = -2, .y = 0x01020304, .terrain = .tree, .cut = true };
const sentinel: p.Snapshot = .{
    .area = .{ .cx0 = -8, .cy0 = -9, .cx1 = -6, .cy1 = -7 },
    .count = 9,
    .chunks = @splat(@splat(0xcc)),
};

fn prefixError(len: usize, full_len: usize) wire.DecodeError {
    if (len < 3) return error.TruncatedHeader;
    if (len == full_len - 1) return error.MissingBye;
    return error.TruncatedBody;
}

fn checkRequest(comptime kind: p.Kind, req: p.RequestFor(kind), golden: []const u8) !void {
    var buf: [p.max_request_bytes]u8 = undefined;
    try t.expectEqualSlices(u8, golden, try wire.encodeRequest(buf[0..golden.len], kind, req));
    try t.expectError(error.BufferTooSmall, wire.encodeRequest(buf[0 .. golden.len - 1], kind, req));
    try t.expectEqualDeep(p.Request{
        .request_id = req.request_id,
        .operation = @unionInit(@FieldType(p.Request, "operation"), @tagName(kind), req.payload),
    }, try wire.decodeMessage(golden, true));
    for (0..golden.len) |len| {
        try t.expectError(prefixError(len, golden.len), wire.decodeMessage(golden[0..len], true));
    }
}

fn checkReply(comptime kind: p.Kind, req: p.RequestFor(kind), outcome: p.Outcome(kind), golden: []const u8) !void {
    var buf: [p.max_response_bytes]u8 = undefined;
    var snapshot = sentinel;
    try t.expectEqualSlices(u8, golden, try wire.encodeReply(buf[0..golden.len], kind, req, outcome));
    try t.expectError(error.BufferTooSmall, wire.encodeReply(buf[0 .. golden.len - 1], kind, req, outcome));
    for (0..golden.len) |len| {
        try t.expectError(prefixError(len, golden.len), wire.decodeReply(golden[0..len], kind, req.request_id, &snapshot));
        try t.expectEqualDeep(sentinel, snapshot);
    }
    const decoded = try wire.decodeReply(golden, kind, req.request_id, &snapshot);
    if (kind == .read_area and outcome == .ok) {
        try t.expect(decoded.ok == &snapshot);
        try t.expectEqualDeep(outcome.ok.*, snapshot);
    } else {
        try t.expectEqualDeep(outcome, decoded);
        try t.expectEqualDeep(sentinel, snapshot);
    }
}

fn checkAuth(message: p.AuthMessage, golden: []const u8) !void {
    var buf: [p.max_request_bytes]u8 = undefined;
    const kind = std.meta.activeTag(message);
    try t.expectEqualSlices(u8, golden, try wire.encodeAuth(buf[0..golden.len], message));
    try t.expectError(error.BufferTooSmall, wire.encodeAuth(buf[0 .. golden.len - 1], message));
    try t.expectEqualDeep(message, try wire.decodeAuth(golden, true, kind));
    for (0..golden.len) |len| {
        try t.expectError(prefixError(len, golden.len), wire.decodeAuth(golden[0..len], true, kind));
    }
}

test "wire golden requests and every strict prefix" {
    try checkRequest(.cut, cut_req, cut_frame);
    try checkRequest(.read_area, area_req, area_frame);
    try checkRequest(.update_location, location_req, location_frame);
}

test "wire golden replies and every strict prefix" {
    var single: p.Snapshot = .{ .area = area_req.payload, .count = 1 };
    single.chunks[0] = repeat("\x7e\xa5", 16);
    try checkReply(.cut, cut_req, .{ .ok = state }, cut_ok);
    try checkReply(.cut, cut_req, .{ .failed = .{ .already_cut = state } }, cut_already);
    try checkReply(.cut, cut_req, .{ .failed = .not_cuttable }, "\x81\x18\x00" ++ id_tlv ++ "\x04\x02\x00\x09\x00\x7e");
    try checkReply(.read_area, area_req, .{ .ok = &single }, area_ok);
    try checkReply(.read_area, area_req, .{ .failed = .area_too_large }, "\x82\x18\x00" ++ id_tlv ++ "\x04\x02\x00\x08\x00\x7e");
    try checkReply(.update_location, location_req, .ok, "\x83\x16\x00" ++ id_tlv ++ "\x03\x00\x00\x7e");
    try checkReply(.update_location, location_req, .{ .failed = .server_busy }, "\x83\x18\x00" ++ id_tlv ++ "\x04\x02\x00\x0c\x00\x7e");
    try t.expectEqualSlices(u8, protocol_error_frame, &wire.protocol_error);
    try wire.decodeProtocolError(protocol_error_frame);
    for (0..protocol_error_frame.len) |len| {
        try t.expectError(prefixError(len, protocol_error_frame.len), wire.decodeProtocolError(protocol_error_frame[0..len]));
    }
}

test "wire water state preserves appended terrain ordinal" {
    var water = state;
    water.terrain = .water;
    water.cut = false;
    try checkReply(.cut, cut_req, .{ .ok = water }, "\x81\x20\x00" ++ id_tlv ++ "\x03\x0a\x00" ++ point ++ "\x04\x00\x7e");
}

test "wire golden auth messages and every strict prefix" {
    try checkAuth(.{ .challenge = @splat(0x7e) }, "\xf0\x23\x00\x10\x20\x00" ++ repeat("\x7e", 32) ++ "\x7e");
    try checkAuth(.{ .proof = .{ .pubkey = "\x02".* ++ repeat("\x7e", 32), .signature = repeat("\x7e\x5a", 32) } }, proof_frame);
    try checkAuth(.{ .reply = .ok }, "\xf2\x03\x00\x03\x00\x00\x7e");
    try checkAuth(.{ .reply = .{ .failed = .invalid_credentials } }, "\xf2\x05\x00\x04\x02\x00\x01\x00\x7e");
    try checkAuth(.{ .reply = .{ .failed = .unavailable } }, "\xf2\x05\x00\x04\x02\x00\x02\x00\x7e");
}

fn frame(buf: []u8, tag: u8, body: []const u8) []const u8 {
    buf[0] = tag;
    std.mem.writeInt(u16, buf[1..3], @intCast(body.len), .little);
    @memcpy(buf[3..][0..body.len], body);
    buf[3 + body.len] = 0x7e;
    return buf[0 .. 4 + body.len];
}

test "wire rejects malformed envelopes and field lengths" {
    try t.expectError(error.NonBinaryMessage, wire.decodeMessage(cut_frame, false));
    try t.expectError(error.NonBinaryMessage, wire.decodeAuth(proof_frame, false, .proof));
    try t.expectError(error.MessageTooLarge, wire.decodeMessage(&(@as([p.max_request_bytes + 1]u8, @splat(0))), true));
    var snapshot = sentinel;
    try t.expectError(error.MessageTooLarge, wire.decodeReply("\x82\xff\xff\x7e", .read_area, id.*, &snapshot));
    try t.expectEqualDeep(sentinel, snapshot);
    const cases = [_]struct { want: wire.DecodeError, data: []const u8 }{
        .{ .want = error.MessageTooLarge, .data = "\x01\xff\xff\x7e" },
        .{ .want = error.MessageTooLarge, .data = "\x01\xfd\x00\x7e" },
        .{ .want = error.TruncatedBody, .data = "\x01\xfc\x00\x7e" },
        .{ .want = error.TruncatedBody, .data = "\x01\x1f\x00" ++ cut_frame[3 .. cut_frame.len - 1] },
        .{ .want = error.InvalidBye, .data = "\x01\x00\x00\x00" },
        .{ .want = error.TrailingBytes, .data = cut_frame ++ "\x7e" },
        .{ .want = error.UnknownMessageType, .data = "\xfe\x00\x00\x7e" },
        .{ .want = error.UnexpectedMessageType, .data = protocol_error_frame },
    };
    for (cases) |c| try t.expectError(c.want, wire.decodeMessage(c.data, true));

    var buf: [p.max_request_bytes]u8 = undefined;
    const fields = [_]struct { want: wire.DecodeError, body: []const u8 }{
        .{ .want = error.TruncatedFieldHeader, .body = "\x01" },
        .{ .want = error.TruncatedFieldHeader, .body = id_tlv ++ "\x02\x08" },
        .{ .want = error.TruncatedFieldValue, .body = "\x01\xff\xff" },
        .{ .want = error.TruncatedFieldValue, .body = id_tlv ++ "\x02\xff\xff" ++ point },
        .{ .want = error.TruncatedFieldValue, .body = id_tlv ++ "\x02\x09\x00" ++ point },
        .{ .want = error.InvalidFieldLength, .body = "\x01\x0f\x00" ++ id[0..15] },
        .{ .want = error.InvalidFieldLength, .body = id_tlv ++ "\x02\x07\x00" ++ point[0..7] },
    };
    for (fields) |c| try t.expectError(c.want, wire.decodeMessage(frame(&buf, 0x01, c.body), true));
}

test "wire enforces request reply and auth schemas" {
    var buf: [p.max_request_bytes]u8 = undefined;
    const requests = [_]struct { want: wire.DecodeError, body: []const u8 }{
        .{ .want = error.MissingRequiredField, .body = "" },
        .{ .want = error.MissingRequiredField, .body = id_tlv },
        .{ .want = error.UnknownField, .body = id_tlv ++ "\xff\x00\x00" },
        .{ .want = error.UnknownField, .body = id_tlv ++ "\x03\x00\x00" },
        .{ .want = error.DuplicateField, .body = id_tlv ++ id_tlv },
        .{ .want = error.DuplicateField, .body = id_tlv ++ repeat("\x02\x08\x00" ++ point, 2) },
        .{ .want = error.OutOfOrderField, .body = "\x02\x08\x00" ++ point ++ id_tlv },
    };
    for (requests) |c| try t.expectError(c.want, wire.decodeMessage(frame(&buf, 0x01, c.body), true));

    const replies = [_]struct { want: wire.DecodeError, outcome: []const u8 }{
        .{ .want = error.MissingRequiredField, .outcome = "" },
        .{ .want = error.ConflictingOutcome, .outcome = "\x03\x0a\x00" ++ point ++ "\x03\x01\x04\x02\x00\x09\x00" },
        .{ .want = error.OutOfOrderField, .outcome = "\x04\x02\x00\x09\x00\x03\x00\x00" },
        .{ .want = error.DuplicateField, .outcome = "\x04\x02\x00\x09\x00\x04\x02\x00\x09\x00" },
        .{ .want = error.InvalidFieldValue, .outcome = "\x03\x0a\x00" ++ point ++ "\xff\x01" },
        .{ .want = error.InvalidFieldValue, .outcome = "\x03\x0a\x00" ++ point ++ "\x03\x02" },
        .{ .want = error.InvalidFieldValue, .outcome = "\x04\x0c\x00\x0a\x00" ++ point ++ "\x03\x02" },
        .{ .want = error.InvalidFieldValue, .outcome = "\x04\x02\x00\x06\x00" },
        .{ .want = error.InvalidFieldLength, .outcome = "\x04\x02\x00\x0a\x00" },
    };
    var snapshot = sentinel;
    for (replies) |c| {
        // Preserve the complete envelope while varying only the outcome TLVs.
        var body: [p.max_request_bytes]u8 = undefined;
        @memcpy(body[0..id_tlv.len], id_tlv);
        @memcpy(body[id_tlv.len..][0..c.outcome.len], c.outcome);
        try t.expectError(c.want, wire.decodeReply(frame(&buf, 0x81, body[0 .. id_tlv.len + c.outcome.len]), .cut, id.*, &snapshot));
    }
    try t.expectError(error.InvalidFieldLength, wire.decodeReply(frame(&buf, 0x83, id_tlv ++ "\x03\x01\x00\x7e"), .update_location, id.*, &snapshot));
    try t.expectError(error.UnexpectedMessageType, wire.decodeReply(cut_ok, .update_location, id.*, &snapshot));
    try t.expectError(error.UnexpectedRequestId, wire.decodeReply(cut_ok, .cut, @splat(0), &snapshot));
    try t.expectEqualDeep(sentinel, snapshot);

    try t.expectError(error.UnexpectedMessageType, wire.decodeAuth(proof_frame, true, .challenge));
    try t.expectError(error.OutOfOrderField, wire.decodeAuth(frame(&buf, 0xf1, "\x12\x40\x00" ++ repeat("\x7e", 64)), true, .proof));
    try t.expectError(error.DuplicateField, wire.decodeAuth(frame(&buf, 0xf1, &repeat("\x11\x21\x00" ++ repeat("\x7e", 33), 2)), true, .proof));
    try t.expectError(error.MissingRequiredField, wire.decodeAuth(frame(&buf, 0xf2, ""), true, .reply));
    try t.expectError(error.ConflictingOutcome, wire.decodeAuth(frame(&buf, 0xf2, "\x03\x00\x00\x04\x02\x00\x01\x00"), true, .reply));
    try t.expectError(error.InvalidFieldValue, wire.decodeAuth(frame(&buf, 0xf2, "\x04\x02\x00\xff\xff"), true, .reply));
    try t.expectError(error.InvalidFieldLength, wire.decodeAuth(frame(&buf, 0xf2, "\x03\x01\x00\x7e"), true, .reply));
    try t.expectError(error.UnknownField, wire.decodeProtocolError(frame(&buf, 0xff, "\x03\x00\x00")));
}

test "wire maximum snapshot fits exactly and rejects every strict prefix" {
    const max_area: p.Payload(.read_area) = .{ .cx0 = p.min_chunk, .cy0 = p.max_chunk - 7, .cx1 = p.min_chunk + 7, .cy1 = p.max_chunk };
    const req: p.RequestFor(.read_area) = .{ .request_id = id.*, .payload = max_area };
    var max: p.Snapshot = .{ .area = max_area, .count = p.max_area_chunks };
    for (&max.chunks, 0..) |*chunk, i| {
        chunk.* = @splat(@intCast(i));
        chunk[0] = 0x7e;
    }
    const header = "\x82\x4c\x08" ++ id_tlv ++ "\x03\x36\x08" ++
        "\x00\x00\x00\xf8\xf8\xff\xff\x07\x07\x00\x00\xf8\xff\xff\xff\x07" ++
        "\x02\x00\x00\x00" ++ repeat("\x00", 32) ++ "\x40\x00";
    var golden: [p.max_response_bytes]u8 = undefined;
    @memcpy(golden[0..header.len], header);
    @memcpy(golden[header.len .. golden.len - 1], std.mem.asBytes(&max.chunks));
    golden[golden.len - 1] = 0x7e;
    try checkReply(.read_area, req, .{ .ok = &max }, &golden);

    var buf: [p.max_response_bytes + 1]u8 = @splat(0);
    var snapshot = sentinel;
    try t.expectError(error.MessageTooLarge, wire.decodeReply(&buf, .read_area, id.*, &snapshot));
    try t.expectEqualDeep(sentinel, snapshot);
    max.count -= 1;
    try t.expectError(error.InvalidSnapshot, wire.encodeReply(&buf, .read_area, req, .{ .ok = &max }));
    max.count = p.max_area_chunks;
    max.area.cx1 += 1;
    try t.expectError(error.InvalidSnapshot, wire.encodeReply(&buf, .read_area, req, .{ .ok = &max }));
}

test "wire snapshot output stays unchanged on metadata schema and correlation failures" {
    const value = 3 + id_tlv.len + 3;
    const mutations = [_]struct { want: wire.DecodeError, offset: usize, byte: u8 }{
        .{ .want = error.InvalidFieldValue, .offset = value + 8, .byte = 0xfd }, // Inverted x range.
        .{ .want = error.InvalidFieldValue, .offset = value + 15, .byte = 0x08 }, // Out-of-bounds y.
        .{ .want = error.InvalidFieldValue, .offset = value + 12, .byte = 68 }, // 66 chunks.
        .{ .want = error.InvalidFieldLength, .offset = value + 12, .byte = 4 }, // Geometry needs two chunks.
        .{ .want = error.InvalidFieldValue, .offset = value + 16, .byte = 1 }, // Previous generator version.
        .{ .want = error.InvalidFieldValue, .offset = value + 20, .byte = 0x7e }, // Public seed.
        .{ .want = error.InvalidFieldValue, .offset = value + 52, .byte = 0 }, // Declared count.
        .{ .want = error.InvalidFieldValue, .offset = value + 53, .byte = 0xff },
    };
    var snapshot = sentinel;
    for (mutations) |c| {
        var bad = area_ok.*;
        bad[c.offset] = c.byte;
        try t.expectError(c.want, wire.decodeReply(&bad, .read_area, id.*, &snapshot));
        try t.expectEqualDeep(sentinel, snapshot);
    }
    var buf: [p.max_response_bytes]u8 = undefined;
    const body = area_ok[3 .. area_ok.len - 1];
    try t.expectError(error.ConflictingOutcome, wire.decodeReply(frame(&buf, 0x82, body ++ "\x04\x02\x00\x08\x00"), .read_area, id.*, &snapshot));
    try t.expectEqualDeep(sentinel, snapshot);
    try t.expectError(error.TruncatedFieldHeader, wire.decodeReply(frame(&buf, 0x82, body ++ "\x04"), .read_area, id.*, &snapshot));
    try t.expectEqualDeep(sentinel, snapshot);
    try t.expectError(error.UnexpectedRequestId, wire.decodeReply(area_ok, .read_area, @splat(0), &snapshot));
    try t.expectEqualDeep(sentinel, snapshot);
}

test "pending replies match both ID and type, preserve entries on errors, and ignore late replies" {
    var pending: wire.Pending = .{};
    var snapshot = sentinel;
    try pending.track(.cut, cut_req);
    try t.expectError(error.DuplicateRequestId, pending.track(.read_area, area_req));
    var other = location_req;
    other.request_id = @splat(0xff);
    try pending.track(.update_location, other);

    try t.expectEqual(.protocol_error, try pending.receive(protocol_error_frame, true, &snapshot));
    try t.expectError(error.UnexpectedMessageType, pending.receive(area_ok, true, &snapshot));
    try t.expectError(error.MissingBye, pending.receive(cut_ok[0 .. cut_ok.len - 1], true, &snapshot));
    try t.expectEqualDeep(sentinel, snapshot);

    var buf: [p.max_response_bytes]u8 = undefined;
    const ack = try wire.encodeReply(&buf, .update_location, other, .ok);
    try t.expectEqual(.ok, (try pending.receive(ack, true, &snapshot)).reply.outcome.update_location);
    try t.expectEqualDeep(state, (try pending.receive(cut_ok, true, &snapshot)).reply.outcome.cut.ok);
    try t.expectEqualDeep(id.*, (try pending.receive(area_ok, true, &snapshot)).unmatched_reply);
    try t.expectEqualDeep(sentinel, snapshot);

    try pending.track(.read_area, area_req);
    const received = try pending.receive(area_ok, true, &snapshot);
    try t.expect(received.reply.outcome.read_area.ok == &snapshot);
    try t.expectEqual(@as(u16, 1), snapshot.count);
}

test "pending capacity is fixed and timed-out entries can be removed" {
    var pending: wire.Pending = .{};
    var req = location_req;
    for (0..wire.Pending.capacity) |i| {
        req.request_id[0] = @intCast(i);
        try pending.track(.update_location, req);
    }
    req.request_id[0] = 8;
    try t.expectError(error.TooManyPendingRequests, pending.track(.update_location, req));
    pending.forget(location_req.request_id);
    try pending.track(.update_location, req);
}

test "channel requirements, open, payment, and close have typed pending replies" {
    const requirements: p.RequestFor(.channel_requirements) = .{ .request_id = id.*, .payload = .{ .tool = .pickaxe } };
    try checkRequest(.channel_requirements, requirements, "\x21\x17\x00" ++ id_tlv ++ "\x23\x01\x00\x02\x7e");
    const quote: p.SpillmanChannelRequirementsRes = .{ .pubkey = .{2} ++ @as([32]u8, @splat(0x7e)), .amount = 9, .refundTime = 10 };
    const golden_quote = "\xa1\x47\x00" ++ id_tlv ++ "\x03\x31\x00\x02" ++ repeat("\x7e", 32) ++
        "\x09\x00\x00\x00\x00\x00\x00\x00\x0a\x00\x00\x00\x00\x00\x00\x00\x7e";
    try checkReply(.channel_requirements, requirements, .{ .ok = quote }, golden_quote);
    var pending: wire.Pending = .{};
    var snapshot = sentinel;
    try pending.track(.channel_requirements, requirements);
    try t.expectEqualDeep(quote, (try pending.receive(golden_quote, true, &snapshot)).reply.outcome.channel_requirements.ok);

    const closing: p.RequestFor(.channel_close) = .{ .request_id = id.*, .payload = .{ .id = @splat(0x42) } };
    try checkRequest(.channel_close, closing, "\x23\x36\x00" ++ id_tlv ++ "\x20\x20\x00" ++ repeat("B", 32) ++ "\x7e");
    try checkReply(.channel_close, closing, .ok, "\xa3\x16\x00" ++ id_tlv ++ "\x03\x00\x00\x7e");
    try t.expectError(error.InvalidFieldValue, wire.decodeReply("\xa3\x18\x00" ++ id_tlv ++ "\x04\x02\x00\x16\x00\x7e", .channel_close, id.*, &snapshot));
    try t.expectError(error.InvalidFieldValue, wire.decodeMessage("\x21\x17\x00" ++ id_tlv ++ "\x23\x01\x00\xff\x7e", true));
}

test "channel open proof length is bounded and decoded as a borrowed slice" {
    const max = p.max_channel_proof_bytes;
    const proof = @as([max + 1]u8, @splat(0x7e));
    var req: p.RequestFor(.channel_open) = .{ .request_id = id.*, .payload = .{ .id = @splat(0x42), .proof = proof[0..max] } };
    var buf: [p.max_request_bytes + 1]u8 = undefined;
    const data = try wire.encodeRequest(&buf, .channel_open, req);
    try t.expectEqual(@as(usize, p.max_request_bytes), data.len);
    const decoded = (try wire.decodeMessage(data, true)).operation.channel_open;
    try t.expectEqualSlices(u8, req.payload.proof, decoded.proof);
    try t.expectEqual(data[data.len - 1 - max ..].ptr, decoded.proof.ptr);
    try t.expectError(error.MissingBye, wire.decodeMessage(data[0 .. data.len - 1], true));
    try t.expectError(error.MessageTooLarge, wire.decodeMessage(&buf, true));
    try t.expectError(error.MessageTooLarge, wire.decodeMessage("\x22\xff\xff\x7e", true));
    req.payload.proof = &proof;
    try t.expectError(error.InvalidProofLength, wire.encodeRequest(&buf, .channel_open, req));
    req.payload.proof = "";
    try t.expectError(error.InvalidProofLength, wire.encodeRequest(&buf, .channel_open, req));
    const open_body = id_tlv ++ "\x20\x20\x00" ++ repeat("B", 32);
    try t.expectError(error.InvalidFieldLength, wire.decodeMessage(frame(&buf, 0x22, open_body ++ "\x24\x00\x00"), true));
    try t.expectError(error.TruncatedFieldValue, wire.decodeMessage(frame(&buf, 0x22, open_body ++ "\x24\xff\xff"), true));
}

test "proof encoding rejects exact and partial overlap before writing but accepts adjacent storage" {
    const frame_len = p.max_request_bytes - p.max_channel_proof_bytes + 4;
    var buf: [frame_len + 4]u8 = @splat(0xa5);
    const before = buf;
    var req: p.RequestFor(.channel_open) = .{ .request_id = id.*, .payload = .{ .id = @splat(0x42), .proof = buf[0..4] } };
    try t.expectError(error.OverlappingBuffers, wire.encodeRequest(buf[0..frame_len], .channel_open, req));
    try t.expectEqualSlices(u8, &before, &buf);
    req.payload.proof = buf[frame_len - 1 ..][0..4];
    try t.expectError(error.OverlappingBuffers, wire.encodeRequest(buf[0..frame_len], .channel_open, req));
    try t.expectEqualSlices(u8, &before, &buf);
    req.payload.proof = buf[frame_len..];
    const encoded = try wire.encodeRequest(&buf, .channel_open, req);
    try t.expectEqual(@as(usize, frame_len), encoded.len);
    try t.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5, 0xa5 }, (try wire.decodeMessage(encoded, true)).operation.channel_open.proof);
}

test "snapshot encoding and decoding reject overlapping buffers without writing" {
    var snapshots: [2]p.Snapshot = undefined;
    const raw = std.mem.asBytes(&snapshots);
    const boundary = @sizeOf(p.Snapshot);
    @memset(raw, 0);
    snapshots[1].area = area_req.payload;
    snapshots[1].count = 1;
    const before = raw.*;
    const outcome: p.Outcome(.read_area) = .{ .ok = &snapshots[1] };
    try t.expectError(error.OverlappingBuffers, wire.encodeReply(raw[boundary..], .read_area, area_req, outcome));
    try t.expectError(error.OverlappingBuffers, wire.encodeReply(raw[boundary - 1 ..], .read_area, area_req, outcome));
    try t.expectEqualSlices(u8, &before, raw);

    const adjacent = raw[boundary - area_ok.len .. boundary];
    @memcpy(&snapshots[1].chunks[0], area_ok[area_ok.len - 1 - p.chunk_bytes .. area_ok.len - 1]);
    try t.expectEqualSlices(u8, area_ok, try wire.encodeReply(adjacent, .read_area, area_req, outcome));
    _ = try wire.decodeReply(adjacent, .read_area, id.*, &snapshots[1]);
    try t.expectEqualSlices(u8, area_ok, adjacent);

    for ([_]usize{ boundary, boundary - 1 }) |start| {
        const input = raw[start..][0..area_ok.len];
        @memcpy(input, area_ok);
        const unchanged = raw.*;
        try t.expectError(error.OverlappingBuffers, wire.decodeReply(input, .read_area, id.*, &snapshots[1]));
        var pending: wire.Pending = .{};
        try pending.track(.read_area, area_req);
        try t.expectError(error.OverlappingBuffers, pending.receive(input, true, &snapshots[1]));
        try t.expectError(error.DuplicateRequestId, pending.track(.read_area, area_req));
        try t.expectEqualSlices(u8, &unchanged, raw);
    }
}

fn exerciseDecoders(data: []const u8) !void {
    var pending: wire.Pending = .{};
    var pending_snapshot = sentinel;
    _ = pending.receive(data, true, &pending_snapshot) catch {};
    try t.expectEqualDeep(sentinel, pending_snapshot);
    _ = wire.decodeMessage(data, true) catch {};
    inline for ([_]p.AuthKind{ .challenge, .proof, .reply }) |kind| {
        _ = wire.decodeAuth(data, true, kind) catch {};
    }
    inline for (std.enums.values(p.Kind)) |kind| {
        var snapshot = sentinel;
        if (wire.decodeReply(data, kind, id.*, &snapshot)) |outcome| {
            if (kind == .read_area and outcome == .ok) {
                try t.expect(outcome.ok == &snapshot);
            } else {
                try t.expectEqualDeep(sentinel, snapshot);
            }
        } else |_| {
            try t.expectEqualDeep(sentinel, snapshot);
        }
    }
    wire.decodeProtocolError(data) catch {};
}

test "wire decoders are panic-free on deterministic random input" {
    var prng = std.Random.DefaultPrng.init(0x16ba_d7e);
    const random = prng.random();
    const tags = [_]u8{ 0x01, 0x02, 0x03, 0x20, 0x21, 0x22, 0x23, 0x81, 0x82, 0x83, 0xa0, 0xa1, 0xa2, 0xa3, 0xf0, 0xf1, 0xf2, 0xff };
    const seeds = [_][]const u8{ cut_frame, area_frame, location_frame, cut_ok, cut_already, area_ok, proof_frame, protocol_error_frame };
    var buf: [@max(p.max_response_bytes, p.max_request_bytes) + 16]u8 = undefined;
    for (0..2048) |i| {
        const raw = buf[0..random.intRangeAtMost(usize, 0, buf.len)];
        random.bytes(raw);
        try exerciseDecoders(raw);

        // Bypass the envelope checks so random bytes also reach the TLV reader.
        const n = random.intRangeAtMost(usize, 0, p.max_request_bytes - 4);
        buf[0] = tags[i % tags.len];
        std.mem.writeInt(u16, buf[1..3], @intCast(n), .little);
        random.bytes(buf[3..][0..n]);
        buf[3 + n] = 0x7e;
        try exerciseDecoders(buf[0 .. 4 + n]);

        const seed = seeds[i % seeds.len];
        @memcpy(buf[0..seed.len], seed);
        buf[random.intRangeLessThan(usize, 0, seed.len)] ^= random.intRangeAtMost(u8, 1, 255);
        try exerciseDecoders(buf[0..seed.len]);
    }
}
