//! Allocation-free TLV codec. All integers on the wire are little-endian.
const std = @import("std");
const p = @import("protocol.zig");
const world = @import("world.zig");

const bye = 0x7e;
const header_bytes = 3;
const envelope_bytes = header_bytes + 1;
const Tag = enum(u8) {
    cut = 0x01,
    read_area = 0x02,
    update_location = 0x03,
    cut_reply = 0x81,
    read_area_reply = 0x82,
    update_location_reply = 0x83,
    challenge = 0xf0,
    proof = 0xf1,
    reply = 0xf2,
    channel_requirements = 0x21,
    channel_close = 0x23,
    channel_open = 0x24,
    channel_status = 0x25,
    channel_requirements_reply = 0xa1,
    channel_open_reply = 0xa2,
    channel_close_reply = 0xa3,
    channel_status_reply = 0xa5,
    channel_settled = 0xa6,
    protocol_error = 0xff,
};
const Field = enum(u8) {
    id = 1,
    payload = 2,
    ok = 3,
    failed = 4,
    nonce = 0x10,
    pubkey = 0x11,
    signature = 0x12,
    channel_id = 0x20,
    amount = 0x21,
    payment_signature = 0x22,
    tool = 0x23,
    funding_proof = 0x24,
    channel_params = 0x25,
    channel_capacity_msat = 0x26,
    channel_balance_msat = 0x27,
    tool_channels = 0x28,
};

pub const protocol_error = [4]u8{ @backingInt(Tag.protocol_error), 0, 0, bye };
pub const DecodeError = error{
    NonBinaryMessage,
    MessageTooLarge,
    TruncatedHeader,
    TruncatedBody,
    MissingBye,
    InvalidBye,
    TrailingBytes,
    UnknownMessageType,
    UnexpectedMessageType,
    TruncatedFieldHeader,
    TruncatedFieldValue,
    UnknownField,
    DuplicateField,
    OutOfOrderField,
    InvalidFieldLength,
    MissingRequiredField,
    InvalidFieldValue,
    ConflictingOutcome,
    UnexpectedRequestId,
    OverlappingBuffers,
};
const EncodeBufferError = error{ BufferTooSmall, OverlappingBuffers };
pub const EncodeError = EncodeBufferError || error{ InvalidSnapshot, InvalidSenderProofLength, InvalidChannelStatus };

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return if (a_start <= b_start) b_start - a_start < a.len else a_start - b_start < b.len;
}

fn get(comptime T: type, data: []const u8, offset: usize) T {
    return std.mem.readInt(T, data[offset..][0..@sizeOf(T)], .little);
}
fn put(comptime T: type, data: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, data[offset..][0..@sizeOf(T)], value, .little);
}

const Reader = struct {
    remaining: []const u8,
    seen: u64 = 0,
    last: u8 = 0,

    fn next(self: *Reader, allowed: []const Field) DecodeError!?struct { tag: Field, bytes: []const u8 } {
        const data = self.remaining;
        if (data.len == 0) return null;
        if (data.len < header_bytes) return error.TruncatedFieldHeader;
        const n = get(u16, data, 1);
        if (n > data.len - header_bytes) return error.TruncatedFieldValue;
        const tag = std.enums.fromInt(Field, data[0]) orelse return error.UnknownField;
        if (std.mem.indexOfScalar(Field, allowed, tag) == null) return error.UnknownField;
        const bit = @as(u64, 1) << @as(u6, @intCast(data[0]));
        if (self.seen & bit != 0) return error.DuplicateField;
        if (data[0] < self.last) return error.OutOfOrderField;
        self.seen |= bit;
        self.last = data[0];
        const end = header_bytes + @as(usize, n);
        self.remaining = data[end..];
        return .{ .tag = tag, .bytes = data[header_bytes..end] };
    }

    fn exact(self: *Reader, allowed: []const Field, expected: Field, comptime n: usize) DecodeError!*const [n]u8 {
        const item = try self.next(allowed) orelse return error.MissingRequiredField;
        if (item.tag != expected) return error.OutOfOrderField;
        if (item.bytes.len != n) return error.InvalidFieldLength;
        return item.bytes[0..n];
    }

    fn finish(self: *Reader, allowed: []const Field) DecodeError!void {
        if (try self.next(allowed)) |_| return error.ConflictingOutcome;
    }
};

fn open(data: []const u8, binary: bool, cap: usize) DecodeError!struct { tag: Tag, body: Reader } {
    if (!binary) return error.NonBinaryMessage;
    if (data.len > cap) return error.MessageTooLarge;
    if (data.len < header_bytes) return error.TruncatedHeader;
    const n: usize = get(u16, data, 1);
    if (n > cap - envelope_bytes) return error.MessageTooLarge;
    const available = data.len - header_bytes;
    if (n > available) return error.TruncatedBody;
    if (n == available) return error.MissingBye;
    const end = header_bytes + n;
    if (data[end] != bye) return error.InvalidBye;
    if (available - n != 1) return error.TrailingBytes;
    const tag = std.enums.fromInt(Tag, data[0]) orelse return error.UnknownMessageType;
    return .{ .tag = tag, .body = .{ .remaining = data[header_bytes..end] } };
}

const Writer = struct {
    frame: []u8,
    offset: usize = header_bytes,

    fn initFrom(out: []u8, tag: Tag, body_len: u16, source: []const u8) EncodeBufferError!Writer {
        const n = envelope_bytes + @as(usize, body_len);
        if (out.len >= n and overlaps(out[0..n], source)) return error.OverlappingBuffers;
        return init(out, tag, body_len);
    }
    fn init(out: []u8, tag: Tag, body_len: u16) error{BufferTooSmall}!Writer {
        const n = envelope_bytes + @as(usize, body_len);
        if (out.len < n) return error.BufferTooSmall;
        out[0] = @backingInt(tag);
        put(u16, out, 1, body_len);
        out[n - 1] = bye;
        return .{ .frame = out[0..n] };
    }
    fn field(self: *Writer, tag: Field, n: u16) []u8 {
        const start = self.offset;
        const end = start + header_bytes + @as(usize, n);
        std.debug.assert(end < self.frame.len);
        self.frame[start] = @backingInt(tag);
        put(u16, self.frame, start + 1, n);
        self.offset = end;
        return self.frame[start + header_bytes .. end];
    }
    fn bytes(self: *Writer, tag: Field, data: []const u8) void {
        @memcpy(self.field(tag, @intCast(data.len)), data);
    }
    fn finish(self: Writer) []const u8 {
        std.debug.assert(self.offset + 1 == self.frame.len);
        return self.frame;
    }
};

fn requestTag(kind: p.Kind) Tag {
    return switch (kind) {
        .cut => .cut,
        .read_area => .read_area,
        .update_location => .update_location,
        .channel_requirements => .channel_requirements,
        .channel_open => .channel_open,
        .channel_close => .channel_close,
        .channel_status => .channel_status,
    };
}
fn replyTag(kind: p.Kind) Tag {
    return switch (kind) {
        .cut => .cut_reply,
        .read_area => .read_area_reply,
        .update_location => .update_location_reply,
        .channel_requirements => .channel_requirements_reply,
        .channel_open => .channel_open_reply,
        .channel_close => .channel_close_reply,
        .channel_status => .channel_status_reply,
    };
}

fn writePoint(out: []u8, x: i32, y: i32) void {
    put(i32, out, 0, x);
    put(i32, out, 4, y);
}
fn writeArea(out: []u8, area: world.ChunkRange) void {
    writePoint(out, area.cx0, area.cy0);
    writePoint(out[8..], area.cx1, area.cy1);
}
fn readArea(data: []const u8) world.ChunkRange {
    return .{ .cx0 = get(i32, data, 0), .cy0 = get(i32, data, 4), .cx1 = get(i32, data, 8), .cy1 = get(i32, data, 12) };
}
fn writeState(out: []u8, s: p.State) void {
    writePoint(out, s.x, s.y);
    out[8] = @backingInt(s.terrain);
    out[9] = @intFromBool(s.cut);
}
fn readState(data: []const u8) DecodeError!p.State {
    if (data.len != 10) return error.InvalidFieldLength;
    if (data[9] > 1) return error.InvalidFieldValue;
    return .{ .x = get(i32, data, 0), .y = get(i32, data, 4), .terrain = std.enums.fromInt(world.Tile, data[8]) orelse return error.InvalidFieldValue, .cut = data[9] == 1 };
}

const payment_tlv_bytes = 3 * header_bytes + 32 + 8 + 64;

fn writePayment(writer: *Writer, payment: p.SpillmanChannelPayment) void {
    writer.bytes(.channel_id, &payment.id);
    put(u64, writer.field(.amount, 8), 0, payment.amount);
    writer.bytes(.payment_signature, &payment.signature);
}

fn readPayment(reader: *Reader, fields: []const Field) DecodeError!p.SpillmanChannelPayment {
    return .{
        .id = (try reader.exact(fields, .channel_id, 32)).*,
        .amount = get(u64, try reader.exact(fields, .amount, 8), 0),
        .signature = (try reader.exact(fields, .payment_signature, 64)).*,
    };
}

/// A channel-open proof and params must not overlap the bytes written to `out`.
pub fn encodeRequest(out: []u8, comptime kind: p.Kind, req: p.RequestFor(kind)) (EncodeBufferError || error{ InvalidProofLength, InvalidParamsLength })![]const u8 {
    const tool_bytes: u16 = switch (kind) {
        .cut, .channel_open => if (req.payload.tool == .hoe) 0 else header_bytes + 1,
        else => 0,
    };
    const payload_bytes: u16 = switch (kind) {
        .cut => header_bytes + 8 + @as(u16, if (req.payload.payment != null) payment_tlv_bytes else 0) + tool_bytes,
        .update_location => header_bytes + 8,
        .read_area => header_bytes + 16,
        .channel_requirements => header_bytes + 1,
        .channel_close => header_bytes + 32 + @as(u16, if (req.payload.expected_balance_msat != null) header_bytes + 8 else 0),
        .channel_status => header_bytes + 32,
        .channel_open => blk: {
            const proof_len = req.payload.proof.len;
            if (proof_len == 0 or proof_len > p.max_channel_proof_bytes) return error.InvalidProofLength;
            const params_len = req.payload.params.len;
            if (params_len == 0 or params_len > p.max_channel_params_bytes) return error.InvalidParamsLength;
            break :blk @intCast(3 * header_bytes + 32 + proof_len + params_len + tool_bytes);
        },
    };
    const body_len = header_bytes + @sizeOf(p.Id) + payload_bytes;
    const frame_len = envelope_bytes + @as(usize, body_len);
    if (kind == .channel_open and out.len >= frame_len and overlaps(out[0..frame_len], req.payload.params)) return error.OverlappingBuffers;
    const source = if (kind == .channel_open) req.payload.proof else &.{};
    var writer = try Writer.initFrom(out, requestTag(kind), body_len, source);
    writer.bytes(.id, &req.request_id);
    switch (kind) {
        .cut => {
            writePoint(writer.field(.payload, 8), req.payload.x, req.payload.y);
            if (req.payload.payment) |payment| writePayment(&writer, payment);
            if (tool_bytes != 0) writer.field(.tool, 1)[0] = @backingInt(req.payload.tool);
        },
        .update_location => writePoint(writer.field(.payload, 8), req.payload.x, req.payload.y),
        .read_area => writeArea(writer.field(.payload, 16), req.payload),
        .channel_requirements => writer.field(.tool, 1)[0] = @backingInt(req.payload.tool),
        .channel_close => {
            writer.bytes(.channel_id, &req.payload.id);
            if (req.payload.expected_balance_msat) |balance| put(u64, writer.field(.channel_balance_msat, 8), 0, balance);
        },
        .channel_status => writer.bytes(.channel_id, &req.payload.id),
        .channel_open => {
            writer.bytes(.channel_id, &req.payload.id);
            if (tool_bytes != 0) writer.field(.tool, 1)[0] = @backingInt(req.payload.tool);
            writer.bytes(.funding_proof, req.payload.proof);
            writer.bytes(.channel_params, req.payload.params);
        },
    }
    return writer.finish();
}

fn readTool(reader: *Reader, fields: []const Field) DecodeError!p.tool {
    return std.enums.fromInt(p.tool, (try reader.exact(fields, .tool, 1))[0]) orelse error.InvalidFieldValue;
}

fn nextIs(reader: Reader, field: Field) bool {
    return reader.remaining.len != 0 and reader.remaining[0] == @backingInt(field);
}

/// Decoded channel-open proof and params borrow `data` until that buffer is reused.
pub fn decodeMessage(data: []const u8, binary: bool) DecodeError!p.Request {
    const cap: usize = switch (if (data.len == 0) 0 else data[0]) {
        @backingInt(Tag.channel_open) => p.max_channel_open_with_params_bytes,
        else => p.max_gameplay_request_bytes,
    };
    var frame = try open(data, binary, cap);
    const fields: []const Field = switch (frame.tag) {
        .cut => &.{ .id, .payload, .channel_id, .amount, .payment_signature, .tool },
        .read_area, .update_location => &.{ .id, .payload },
        .channel_requirements => &.{ .id, .tool },
        .channel_open => &.{ .id, .channel_id, .tool, .funding_proof, .channel_params },
        .channel_close => &.{ .id, .channel_id, .channel_balance_msat },
        .channel_status => &.{ .id, .channel_id },
        else => return error.UnexpectedMessageType,
    };
    const id = (try frame.body.exact(fields, .id, @sizeOf(p.Id))).*;
    const operation: @FieldType(p.Request, "operation") = switch (frame.tag) {
        .cut => blk: {
            const point = try frame.body.exact(fields, .payload, 8);
            const payment = if (frame.body.remaining.len == 0 or nextIs(frame.body, .tool)) null else try readPayment(&frame.body, fields);
            break :blk .{ .cut = .{
                .x = get(i32, point, 0),
                .y = get(i32, point, 4),
                .payment = payment,
                .tool = if (nextIs(frame.body, .tool)) try readTool(&frame.body, fields) else .hoe,
            } };
        },
        .update_location => blk: {
            const point = try frame.body.exact(fields, .payload, 8);
            break :blk .{ .update_location = .{ .x = get(i32, point, 0), .y = get(i32, point, 4) } };
        },
        .read_area => .{ .read_area = readArea(try frame.body.exact(fields, .payload, 16)) },
        .channel_requirements => .{ .channel_requirements = .{
            .tool = try readTool(&frame.body, fields),
        } },
        .channel_open => blk: {
            const channel_id = (try frame.body.exact(fields, .channel_id, 32)).*;
            const tool = if (nextIs(frame.body, .tool)) try readTool(&frame.body, fields) else .hoe;
            const proof = try frame.body.next(fields) orelse return error.MissingRequiredField;
            if (proof.tag != .funding_proof) return error.OutOfOrderField;
            if (proof.bytes.len == 0 or proof.bytes.len > p.max_channel_proof_bytes) return error.InvalidFieldLength;
            const params = try frame.body.next(fields) orelse return error.MissingRequiredField;
            if (params.tag != .channel_params) return error.OutOfOrderField;
            if (params.bytes.len == 0 or params.bytes.len > p.max_channel_params_bytes) return error.InvalidFieldLength;
            break :blk .{ .channel_open = .{ .id = channel_id, .proof = proof.bytes, .params = params.bytes, .tool = tool } };
        },
        .channel_close => blk: {
            const channel_id = (try frame.body.exact(fields, .channel_id, 32)).*;
            const expected = if (nextIs(frame.body, .channel_balance_msat))
                get(u64, try frame.body.exact(fields, .channel_balance_msat, 8), 0)
            else
                null;
            break :blk .{ .channel_close = .{ .id = channel_id, .expected_balance_msat = expected } };
        },
        .channel_status => .{ .channel_status = .{ .id = (try frame.body.exact(fields, .channel_id, 32)).* } },
        else => unreachable,
    };
    try frame.body.finish(fields);
    return .{ .request_id = id, .operation = operation };
}

fn snapshotSize(count: u16) u16 {
    return p.snapshot_metadata_bytes + count * p.chunk_bytes;
}
fn writeSnapshot(out: []u8, s: *const p.Snapshot) void {
    writeArea(out, s.area);
    put(u32, out, 16, world.generator_version);
    @memcpy(out[20..52], &world.public_seed);
    put(u16, out, 52, s.count);
    @memcpy(out[p.snapshot_metadata_bytes..], std.mem.sliceAsBytes(s.chunks[0..s.count]));
}
fn validateSnapshot(data: []const u8) DecodeError!struct { area: world.ChunkRange, count: u16 } {
    if (data.len < p.snapshot_metadata_bytes) return error.InvalidFieldLength;
    const area = readArea(data);
    const count = (p.areaGeometry(area) catch return error.InvalidFieldValue).count;
    if (data.len != snapshotSize(count)) return error.InvalidFieldLength;
    if (get(u16, data, 52) != count or get(u32, data, 16) != world.generator_version or !std.mem.eql(u8, data[20..52], &world.public_seed)) return error.InvalidFieldValue;
    return .{ .area = area, .count = count };
}

const status_bytes = p.channel_status_reply_overhead - p.close_reply_overhead;

pub const channel_settled_bytes = envelope_bytes + header_bytes + 32;

pub fn encodeChannelSettled(out: []u8, id: [32]u8) EncodeBufferError![]const u8 {
    var writer = try Writer.init(out, .channel_settled, channel_settled_bytes - envelope_bytes);
    writer.bytes(.channel_id, &id);
    return writer.finish();
}

pub fn decodeChannelSettled(data: []const u8, binary: bool) DecodeError![32]u8 {
    var frame = try open(data, binary, channel_settled_bytes);
    if (frame.tag != .channel_settled) return error.UnexpectedMessageType;
    const fields: []const Field = &.{.channel_id};
    const id = (try frame.body.exact(fields, .channel_id, 32)).*;
    try frame.body.finish(fields);
    return id;
}

/// Snapshot and sender proof sources must not overlap the bytes written to `out`.
pub fn encodeReply(out: []u8, comptime kind: p.Kind, req: p.RequestFor(kind), outcome: p.Outcome(kind)) EncodeError![]const u8 {
    const n: u16 = switch (outcome) {
        .ok => |value| switch (kind) {
            .cut => 10,
            .channel_requirements => 49,
            .channel_status => blk: {
                if (value.balance_msat > value.capacity_msat) return error.InvalidChannelStatus;
                const len = if (value.sender_proofs) |proofs| len: {
                    if (value.phase != .settled) return error.InvalidChannelStatus;
                    if (proofs.len == 0 or proofs.len > p.max_sender_change_proofs_bytes) return error.InvalidSenderProofLength;
                    break :len proofs.len;
                } else 0;
                break :blk @intCast(status_bytes + len);
            },
            .update_location, .channel_open, .channel_close => 0,
            .read_area => blk: {
                const geometry = p.areaGeometry(value.area) catch return error.InvalidSnapshot;
                if (value.count != geometry.count) return error.InvalidSnapshot;
                break :blk snapshotSize(value.count);
            },
        },
        .failed => |failure| if (kind == .cut and failure == .already_cut) 12 else 2,
    };
    const source: []const u8 = if (outcome == .ok) switch (kind) {
        .read_area => std.mem.asBytes(outcome.ok),
        .channel_status => outcome.ok.sender_proofs orelse &.{},
        else => &.{},
    } else &.{};
    var writer = try Writer.initFrom(out, replyTag(kind), 2 * header_bytes + @sizeOf(p.Id) + n, source);
    writer.bytes(.id, &req.request_id);
    switch (outcome) {
        .ok => |value| {
            const dest = writer.field(.ok, n);
            switch (kind) {
                .cut => writeState(dest, value),
                .read_area => writeSnapshot(dest, value),
                .channel_requirements => {
                    @memcpy(dest[0..33], &value.pubkey);
                    put(u64, dest, 33, value.amount);
                    put(u64, dest, 41, value.refundTime);
                },
                .channel_status => {
                    put(u64, dest, 0, value.capacity_msat);
                    put(u64, dest, 8, value.balance_msat);
                    dest[16] = @backingInt(value.phase);
                    @memcpy(dest[status_bytes..], source);
                },
                .update_location, .channel_open, .channel_close => {},
            }
        },
        .failed => |failure| {
            const dest = writer.field(.failed, n);
            if (kind == .cut) {
                put(u16, dest, 0, @backingInt(std.meta.activeTag(failure)));
                if (failure == .already_cut) writeState(dest[2..], failure.already_cut);
            } else put(u16, dest, 0, @backingInt(failure));
        },
    }
    return writer.finish();
}

fn readFailure(comptime kind: p.Kind, value: []const u8) DecodeError!p.FailureFor(kind) {
    if (value.len < 2) return error.InvalidFieldLength;
    const code = get(u16, value, 0);
    if (kind != .cut) {
        if (value.len != 2) return error.InvalidFieldLength;
        return std.enums.fromInt(p.FailureFor(kind), code) orelse error.InvalidFieldValue;
    }
    const tag = std.enums.fromInt(std.meta.Tag(p.CutFailure), code) orelse return error.InvalidFieldValue;
    if (tag == .already_cut) return .{ .already_cut = try readState(value[2..]) };
    if (value.len != 2) return error.InvalidFieldLength;
    return switch (tag) {
        .already_cut => unreachable,
        inline else => |t| @unionInit(p.CutFailure, @tagName(t), {}),
    };
}

fn replyCap(tag: Tag) usize {
    return switch (tag) {
        .channel_close_reply => p.max_channel_close_reply_bytes,
        .channel_status_reply => p.max_channel_status_reply_bytes,
        else => p.max_response_bytes,
    };
}

/// On snapshot success, `snapshot` must not overlap the input frame `data`.
pub fn decodeReply(data: []const u8, comptime kind: p.Kind, expected_id: p.Id, snapshot: *p.Snapshot) DecodeError!p.Outcome(kind) {
    var frame = try open(data, true, replyCap(replyTag(kind)));
    if (frame.tag != replyTag(kind)) return error.UnexpectedMessageType;
    const id = try frame.body.exact(reply_fields, .id, @sizeOf(p.Id));
    if (!std.mem.eql(u8, id, &expected_id)) return error.UnexpectedRequestId;
    return decodeOutcome(&frame.body, kind, snapshot, data);
}

const reply_fields: []const Field = &.{ .id, .ok, .failed };

fn decodeOutcome(body: *Reader, comptime kind: p.Kind, snapshot: *p.Snapshot, data: []const u8) DecodeError!p.Outcome(kind) {
    const outcome = try body.next(reply_fields) orelse return error.MissingRequiredField;
    try body.finish(reply_fields);
    if (outcome.tag == .failed) return .{ .failed = try readFailure(kind, outcome.bytes) };
    return .{ .ok = switch (kind) {
        .cut => try readState(outcome.bytes),
        .read_area => blk: {
            const meta = try validateSnapshot(outcome.bytes);
            if (overlaps(std.mem.asBytes(snapshot), data)) return error.OverlappingBuffers;
            snapshot.* = .{ .area = meta.area, .count = meta.count };
            @memcpy(std.mem.sliceAsBytes(snapshot.chunks[0..meta.count]), outcome.bytes[p.snapshot_metadata_bytes..]);
            break :blk snapshot;
        },
        .channel_requirements => blk: {
            if (outcome.bytes.len != 49) return error.InvalidFieldLength;
            break :blk .{
                .pubkey = outcome.bytes[0..33].*,
                .amount = get(u64, outcome.bytes, 33),
                .refundTime = get(u64, outcome.bytes, 41),
            };
        },
        .channel_status => blk: {
            const bytes = outcome.bytes;
            if (bytes.len < status_bytes) return error.InvalidFieldLength;
            const phase = std.enums.fromInt(p.ChannelPhase, bytes[16]) orelse return error.InvalidFieldValue;
            const capacity = get(u64, bytes, 0);
            const balance = get(u64, bytes, 8);
            const proofs = bytes[status_bytes..];
            if (balance > capacity or (proofs.len != 0 and phase != .settled)) return error.InvalidFieldValue;
            break :blk .{ .capacity_msat = capacity, .balance_msat = balance, .phase = phase, .sender_proofs = if (proofs.len == 0) null else proofs };
        },
        .update_location, .channel_open, .channel_close => if (outcome.bytes.len != 0) return error.InvalidFieldLength,
    } };
}

const auth_channel_reply_body_bytes = 4 * header_bytes + 8 + 32 + 2 * @sizeOf(u64);
const tool_channel_bytes = 1 + 32 + 2 * @sizeOf(u64);
pub const max_auth_reply_bytes = envelope_bytes + 2 * header_bytes + 8 + p.tools.len * tool_channel_bytes;

pub fn encodeAuth(out: []u8, message: p.AuthMessage) error{ BufferTooSmall, InvalidChannelBalance }![]const u8 {
    const n: u16 = switch (message) {
        .challenge => header_bytes + 32,
        .proof => 2 * header_bytes + 33 + 64,
        .reply => |outcome| switch (outcome) {
            .ok => header_bytes + 8,
            .ok_with_tool_channels => |success| blk: {
                var bytes: u16 = 0;
                for (success.channels) |entry| if (entry) |channel| {
                    if (channel.balance_msat > channel.capacity_msat) return error.InvalidChannelBalance;
                    bytes += tool_channel_bytes;
                };
                break :blk 2 * header_bytes + 8 + bytes;
            },
            .ok_with_hoe_channel => |success| if (success.hoe_channel_balance_msat > success.hoe_channel_capacity_msat)
                return error.InvalidChannelBalance
            else
                auth_channel_reply_body_bytes,
            .failed => header_bytes + 2,
        },
    };
    var writer = try Writer.init(out, @fromBackingInt(@intCast(@backingInt(std.meta.activeTag(message)))), n);
    switch (message) {
        .challenge => |nonce| writer.bytes(.nonce, &nonce),
        .proof => |proof| {
            writer.bytes(.pubkey, &proof.pubkey);
            writer.bytes(.signature, &proof.signature);
        },
        .reply => |outcome| switch (outcome) {
            .ok => |pos| writePoint(writer.field(.ok, 8), pos.x, pos.y),
            .ok_with_tool_channels => |success| {
                writePoint(writer.field(.ok, 8), success.location.x, success.location.y);
                var entries = writer.field(.tool_channels, n - 2 * header_bytes - 8);
                for (success.channels, 0..) |entry, i| if (entry) |channel| {
                    entries[0] = @intCast(i);
                    @memcpy(entries[1..33], &channel.id);
                    put(u64, entries, 33, channel.capacity_msat);
                    put(u64, entries, 41, channel.balance_msat);
                    entries = entries[tool_channel_bytes..];
                };
            },
            .ok_with_hoe_channel => |success| {
                writePoint(writer.field(.ok, 8), success.location.x, success.location.y);
                writer.bytes(.channel_id, &success.hoe_channel_id);
                put(u64, writer.field(.channel_capacity_msat, 8), 0, success.hoe_channel_capacity_msat);
                put(u64, writer.field(.channel_balance_msat, 8), 0, success.hoe_channel_balance_msat);
            },
            .failed => |code| put(u16, writer.field(.failed, 2), 0, @backingInt(code)),
        },
    }
    return writer.finish();
}

pub fn decodeAuth(data: []const u8, binary: bool, expected: p.AuthKind) DecodeError!p.AuthMessage {
    var frame = try open(data, binary, p.max_gameplay_request_bytes);
    if (@backingInt(frame.tag) != @backingInt(expected)) return error.UnexpectedMessageType;
    switch (expected) {
        .challenge => {
            const fields = &.{.nonce};
            const nonce = try frame.body.exact(fields, .nonce, 32);
            try frame.body.finish(fields);
            return .{ .challenge = nonce.* };
        },
        .proof => {
            const fields = &.{ .pubkey, .signature };
            const key = try frame.body.exact(fields, .pubkey, 33);
            const signature = try frame.body.exact(fields, .signature, 64);
            try frame.body.finish(fields);
            return .{ .proof = .{ .pubkey = key.*, .signature = signature.* } };
        },
        .reply => {
            const fields = &.{ .ok, .failed, .channel_id, .channel_capacity_msat, .channel_balance_msat, .tool_channels };
            const outcome = try frame.body.next(&.{ .ok, .failed }) orelse return error.MissingRequiredField;
            if (outcome.tag == .ok) {
                const is_tool_group = nextIs(frame.body, .tool_channels);
                const optional_channel = if (is_tool_group) null else try frame.body.next(fields);
                if (optional_channel) |channel| {
                    if (channel.tag != .channel_id) return error.ConflictingOutcome;
                    if (channel.bytes.len != 32) return error.InvalidFieldLength;
                }
                if (outcome.bytes.len != 8) return error.InvalidFieldLength;
                const pos: p.Location = .{ .x = get(i32, outcome.bytes, 0), .y = get(i32, outcome.bytes, 4) };
                if (is_tool_group) {
                    const encoded = (try frame.body.next(fields)).?.bytes;
                    if (encoded.len % tool_channel_bytes != 0) return error.InvalidFieldLength;
                    var channels: p.ToolChannels = @splat(null);
                    var min_index: usize = 0;
                    var entries = encoded;
                    while (entries.len != 0) : (entries = entries[tool_channel_bytes..]) {
                        const index = entries[0];
                        if (index >= channels.len or index < min_index) return error.InvalidFieldValue;
                        const capacity = get(u64, entries, 33);
                        const balance = get(u64, entries, 41);
                        if (balance > capacity) return error.InvalidFieldValue;
                        channels[index] = .{ .id = entries[1..33].*, .capacity_msat = capacity, .balance_msat = balance };
                        min_index = @as(usize, index) + 1;
                    }
                    try frame.body.finish(fields);
                    return .{ .reply = .{ .ok_with_tool_channels = .{ .location = pos, .channels = channels } } };
                }
                const channel = optional_channel orelse return .{ .reply = .{ .ok = pos } };
                const capacity = get(u64, try frame.body.exact(fields, .channel_capacity_msat, 8), 0);
                const balance = get(u64, try frame.body.exact(fields, .channel_balance_msat, 8), 0);
                try frame.body.finish(fields);
                if (balance > capacity) return error.InvalidFieldValue;
                return .{ .reply = .{ .ok_with_hoe_channel = .{
                    .location = pos,
                    .hoe_channel_id = channel.bytes[0..32].*,
                    .hoe_channel_capacity_msat = capacity,
                    .hoe_channel_balance_msat = balance,
                } } };
            }
            try frame.body.finish(fields);
            if (outcome.bytes.len != 2) return error.InvalidFieldLength;
            const code = std.enums.fromInt(p.AuthFailure, get(u16, outcome.bytes, 0)) orelse return error.InvalidFieldValue;
            return .{ .reply = .{ .failed = code } };
        },
    }
}

pub fn decodeProtocolError(data: []const u8) DecodeError!void {
    var frame = try open(data, true, p.max_response_bytes);
    if (frame.tag != .protocol_error) return error.UnexpectedMessageType;
    try frame.body.finish(&.{});
}
