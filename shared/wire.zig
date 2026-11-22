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
    channel_payment = 0x20,
    channel_requirements = 0x21,
    channel_open = 0x22,
    channel_close = 0x23,
    channel_payment_reply = 0xa0,
    channel_requirements_reply = 0xa1,
    channel_open_reply = 0xa2,
    channel_close_reply = 0xa3,
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
pub const EncodeError = EncodeBufferError || error{InvalidSnapshot};

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
        .channel_payment => .channel_payment,
        .channel_close => .channel_close,
    };
}
fn replyTag(kind: p.Kind) Tag {
    return switch (kind) {
        .cut => .cut_reply,
        .read_area => .read_area_reply,
        .update_location => .update_location_reply,
        .channel_requirements => .channel_requirements_reply,
        .channel_open => .channel_open_reply,
        .channel_payment => .channel_payment_reply,
        .channel_close => .channel_close_reply,
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

/// A channel-open proof must not overlap the bytes written to `out`.
pub fn encodeRequest(out: []u8, comptime kind: p.Kind, req: p.RequestFor(kind)) (EncodeBufferError || error{InvalidProofLength})![]const u8 {
    const payload_bytes: u16 = switch (kind) {
        .cut, .update_location => header_bytes + 8,
        .read_area => header_bytes + 16,
        .channel_requirements => header_bytes + 1,
        .channel_close => header_bytes + 32,
        .channel_payment => 3 * header_bytes + 32 + 8 + 64,
        .channel_open => blk: {
            const len = req.payload.proof.len;
            if (len == 0 or len > p.max_channel_proof_bytes) return error.InvalidProofLength;
            break :blk @intCast(2 * header_bytes + 32 + len);
        },
    };
    const source = if (kind == .channel_open) req.payload.proof else &.{};
    var writer = try Writer.initFrom(out, requestTag(kind), header_bytes + @sizeOf(p.Id) + payload_bytes, source);
    writer.bytes(.id, &req.request_id);
    switch (kind) {
        .cut, .update_location => writePoint(writer.field(.payload, 8), req.payload.x, req.payload.y),
        .read_area => writeArea(writer.field(.payload, 16), req.payload),
        .channel_requirements => writer.field(.tool, 1)[0] = @backingInt(req.payload.tool),
        .channel_close => writer.bytes(.channel_id, &req.payload.id),
        .channel_payment => {
            writer.bytes(.channel_id, &req.payload.id);
            put(u64, writer.field(.amount, 8), 0, req.payload.amount);
            writer.bytes(.payment_signature, &req.payload.signature);
        },
        .channel_open => {
            writer.bytes(.channel_id, &req.payload.id);
            writer.bytes(.funding_proof, req.payload.proof);
        },
    }
    return writer.finish();
}

/// A decoded channel-open proof borrows `data` until that buffer is reused.
pub fn decodeMessage(data: []const u8, binary: bool) DecodeError!p.Request {
    const cap: usize = if (data.len > 0 and data[0] == @backingInt(Tag.channel_open)) p.max_request_bytes else p.max_gameplay_request_bytes;
    var frame = try open(data, binary, cap);
    const fields: []const Field = switch (frame.tag) {
        .cut, .read_area, .update_location => &.{ .id, .payload },
        .channel_requirements => &.{ .id, .tool },
        .channel_open => &.{ .id, .channel_id, .funding_proof },
        .channel_payment => &.{ .id, .channel_id, .amount, .payment_signature },
        .channel_close => &.{ .id, .channel_id },
        else => return error.UnexpectedMessageType,
    };
    const id = (try frame.body.exact(fields, .id, @sizeOf(p.Id))).*;
    const operation: @FieldType(p.Request, "operation") = switch (frame.tag) {
        .cut => blk: {
            const point = try frame.body.exact(fields, .payload, 8);
            break :blk .{ .cut = .{ .x = get(i32, point, 0), .y = get(i32, point, 4) } };
        },
        .update_location => blk: {
            const point = try frame.body.exact(fields, .payload, 8);
            break :blk .{ .update_location = .{ .x = get(i32, point, 0), .y = get(i32, point, 4) } };
        },
        .read_area => .{ .read_area = readArea(try frame.body.exact(fields, .payload, 16)) },
        .channel_requirements => .{ .channel_requirements = .{
            .tool = std.enums.fromInt(p.tool, (try frame.body.exact(fields, .tool, 1))[0]) orelse return error.InvalidFieldValue,
        } },
        .channel_open => blk: {
            const channel_id = (try frame.body.exact(fields, .channel_id, 32)).*;
            const proof = try frame.body.next(fields) orelse return error.MissingRequiredField;
            if (proof.tag != .funding_proof) return error.OutOfOrderField;
            if (proof.bytes.len == 0 or proof.bytes.len > p.max_channel_proof_bytes) return error.InvalidFieldLength;
            break :blk .{ .channel_open = .{ .id = channel_id, .proof = proof.bytes } };
        },
        .channel_payment => .{ .channel_payment = .{
            .id = (try frame.body.exact(fields, .channel_id, 32)).*,
            .amount = get(u64, try frame.body.exact(fields, .amount, 8), 0),
            .signature = (try frame.body.exact(fields, .payment_signature, 64)).*,
        } },
        .channel_close => .{ .channel_close = .{ .id = (try frame.body.exact(fields, .channel_id, 32)).* } },
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

/// A snapshot source must not overlap the bytes written to `out`.
pub fn encodeReply(out: []u8, comptime kind: p.Kind, req: p.RequestFor(kind), outcome: p.Outcome(kind)) EncodeError![]const u8 {
    const n: u16 = switch (outcome) {
        .ok => |value| switch (kind) {
            .cut => 10,
            .channel_requirements => 49,
            .update_location, .channel_open, .channel_payment, .channel_close => 0,
            .read_area => blk: {
                const geometry = p.areaGeometry(value.area) catch return error.InvalidSnapshot;
                if (value.count != geometry.count) return error.InvalidSnapshot;
                break :blk snapshotSize(value.count);
            },
        },
        .failed => |failure| if (kind == .cut and failure == .already_cut) 12 else 2,
    };
    const source = if (kind == .read_area and outcome == .ok) std.mem.asBytes(outcome.ok) else &.{};
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
                .update_location, .channel_open, .channel_payment, .channel_close => {},
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

/// On snapshot success, `snapshot` must not overlap the input frame `data`.
pub fn decodeReply(data: []const u8, comptime kind: p.Kind, expected_id: p.Id, snapshot: *p.Snapshot) DecodeError!p.Outcome(kind) {
    var frame = try open(data, true, p.max_response_bytes);
    if (frame.tag != replyTag(kind)) return error.UnexpectedMessageType;
    const id = try frame.body.exact(reply_fields, .id, @sizeOf(p.Id));
    if (!std.mem.eql(u8, id, &expected_id)) return error.UnexpectedRequestId;
    return (try decodeOutcome(&frame.body, kind, snapshot, data)).?;
}

const reply_fields: []const Field = &.{ .id, .ok, .failed };

// A null destination validates a late reply without touching application storage.
fn decodeOutcome(body: *Reader, comptime kind: p.Kind, snapshot: ?*p.Snapshot, data: []const u8) DecodeError!?p.Outcome(kind) {
    const outcome = try body.next(reply_fields) orelse return error.MissingRequiredField;
    try body.finish(reply_fields);
    if (outcome.tag == .failed) return .{ .failed = try readFailure(kind, outcome.bytes) };
    return .{ .ok = switch (kind) {
        .cut => try readState(outcome.bytes),
        .read_area => blk: {
            const meta = try validateSnapshot(outcome.bytes);
            const dest = snapshot orelse return null;
            if (overlaps(std.mem.asBytes(dest), data)) return error.OverlappingBuffers;
            dest.* = .{ .area = meta.area, .count = meta.count };
            @memcpy(std.mem.sliceAsBytes(dest.chunks[0..meta.count]), outcome.bytes[p.snapshot_metadata_bytes..]);
            break :blk dest;
        },
        .channel_requirements => blk: {
            if (outcome.bytes.len != 49) return error.InvalidFieldLength;
            break :blk .{
                .pubkey = outcome.bytes[0..33].*,
                .amount = get(u64, outcome.bytes, 33),
                .refundTime = get(u64, outcome.bytes, 41),
            };
        },
        .update_location, .channel_open, .channel_payment, .channel_close => if (outcome.bytes.len != 0) return error.InvalidFieldLength,
    } };
}

/// Client-side correlation only. A socket/UI integration owns logging, deadlines,
/// and the popover; protocol errors deliberately never consume an entry.
pub const Pending = struct {
    pub const capacity = 8;
    const Entry = struct { id: p.Id, kind: p.Kind };
    pub const Received = union(enum) {
        protocol_error,
        unmatched_reply: p.Id,
        reply: struct {
            id: p.Id,
            outcome: union(p.Kind) {
                cut: p.Outcome(.cut),
                read_area: p.Outcome(.read_area),
                update_location: p.Outcome(.update_location),
                channel_requirements: p.Outcome(.channel_requirements),
                channel_open: p.Outcome(.channel_open),
                channel_payment: p.Outcome(.channel_payment),
                channel_close: p.Outcome(.channel_close),
            },
        },
    };
    entries: [capacity]?Entry = @splat(null),

    pub fn track(self: *Pending, comptime kind: p.Kind, req: p.RequestFor(kind)) error{ DuplicateRequestId, TooManyPendingRequests }!void {
        if (self.find(req.request_id) != null) return error.DuplicateRequestId;
        for (&self.entries) |*entry| {
            if (entry.* == null) {
                entry.* = .{ .id = req.request_id, .kind = kind };
                return;
            }
        }
        return error.TooManyPendingRequests;
    }

    /// Call when the connection's owner times out or fails to send a request.
    pub fn forget(self: *Pending, id: p.Id) void {
        if (self.find(id)) |index| self.entries[index] = null;
    }

    fn find(self: *const Pending, id: p.Id) ?usize {
        for (self.entries, 0..) |maybe, i| {
            const entry = maybe orelse continue;
            if (std.mem.eql(u8, &id, &entry.id)) return i;
        }
        return null;
    }

    /// A matched snapshot reply requires `snapshot` to be disjoint from `data`.
    pub fn receive(self: *Pending, data: []const u8, binary: bool, snapshot: *p.Snapshot) DecodeError!Received {
        var frame = try open(data, binary, p.max_response_bytes);
        if (frame.tag == .protocol_error) {
            try frame.body.finish(&.{});
            return .protocol_error;
        }
        const kind: p.Kind = switch (frame.tag) {
            .cut_reply => .cut,
            .read_area_reply => .read_area,
            .update_location_reply => .update_location,
            .channel_requirements_reply => .channel_requirements,
            .channel_open_reply => .channel_open,
            .channel_payment_reply => .channel_payment,
            .channel_close_reply => .channel_close,
            else => return error.UnexpectedMessageType,
        };
        const id = (try frame.body.exact(reply_fields, .id, @sizeOf(p.Id))).*;
        const index = self.find(id);
        if (index) |i| {
            if (self.entries[i].?.kind != kind) return error.UnexpectedMessageType;
        }
        switch (kind) {
            inline else => |k| {
                const outcome = try decodeOutcome(&frame.body, k, if (index != null) snapshot else null, data);
                const i = index orelse return .{ .unmatched_reply = id };
                self.entries[i] = null;
                return .{ .reply = .{ .id = id, .outcome = @unionInit(@FieldType(@FieldType(Received, "reply"), "outcome"), @tagName(k), outcome.?) } };
            },
        }
    }
};

pub fn encodeAuth(out: []u8, message: p.AuthMessage) error{BufferTooSmall}![]const u8 {
    const n: u16 = switch (message) {
        .challenge => header_bytes + 32,
        .proof => 2 * header_bytes + 33 + 64,
        .reply => |outcome| header_bytes + @as(u16, if (outcome == .ok) 8 else 2),
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
            const fields = &.{ .ok, .failed };
            const outcome = try frame.body.next(fields) orelse return error.MissingRequiredField;
            try frame.body.finish(fields);
            if (outcome.tag == .ok) {
                if (outcome.bytes.len != 8) return error.InvalidFieldLength;
                return .{ .reply = .{ .ok = .{ .x = get(i32, outcome.bytes, 0), .y = get(i32, outcome.bytes, 4) } } };
            }
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

test "payment request matches golden bytes and rejects truncated prefixes" {
    const payment: p.SpillmanChannelPayment = .{ .id = @splat(0x42), .amount = 0x0102030405060708, .signature = @splat(bye) };
    const id: p.Id = @splat(0x24);
    var storage: [136]u8 = undefined;
    const data = try encodeRequest(&storage, .channel_payment, .{ .request_id = id, .payload = payment });
    const golden = [_]u8{ 0x20, 132, 0, 1, 16, 0 } ++ id ++
        [_]u8{ 0x20, 32, 0 } ++ payment.id ++ [_]u8{ 0x21, 8, 0, 8, 7, 6, 5, 4, 3, 2, 1, 0x22, 64, 0 } ++
        payment.signature ++ [_]u8{0x7e};
    try std.testing.expectEqualSlices(u8, &golden, data);
    try std.testing.expectEqualDeep(p.Request{ .request_id = id, .operation = .{ .channel_payment = payment } }, try decodeMessage(data, true));
    for (0..data.len) |n| {
        const err: DecodeError = if (n < header_bytes) error.TruncatedHeader else if (n == data.len - 1) error.MissingBye else error.TruncatedBody;
        try std.testing.expectError(err, decodeMessage(data[0..n], true));
    }
}

test {
    _ = @import("wire_tests.zig");
}
