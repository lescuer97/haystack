//! Bounded callback mailbox. Callbacks never touch the onboarding model.
const std = @import("std");
const onboarding = @import("onboarding.zig");

pub const ClipboardMailbox = struct {
    bytes: [1024]u8 = @splat(0),
    len: usize = 0,
    has_paste: bool = false,
    copied: c_int = 0,

    pub fn clear(self: *ClipboardMailbox) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
        self.has_paste = false;
        self.copied = 0;
    }
    pub fn paste(self: *ClipboardMailbox, text: []const u8) void {
        if (text.len > self.bytes.len or std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return;
        std.crypto.secureZero(u8, &self.bytes);
        @memcpy(self.bytes[0..text.len], text);
        self.len = text.len;
        self.has_paste = true;
    }
    pub fn consume(self: *ClipboardMailbox, model: *onboarding.Onboarding, now: f64) void {
        defer self.clear();
        if (self.copied == 1) model.markCopyHandedOff(.copy_seed, now) else if (self.copied >= 2 and self.copied <= 13) model.markCopyHandedOff(.{ .copy_word = @intCast(self.copied - 2) }, now);
        if (self.has_paste and model.phase == .phrase_entry) {
            const text = model.allocator.dupe(u8, self.bytes[0..self.len]) catch return;
            model.receive(.{ .paste = text });
        }
    }
};

// kind: 0 pointer, 1 confirm, 2 native paste shortcut.
pub fn probe(model: *const onboarding.Onboarding, kind: c_int, x: c_int, y: c_int, width: f32, height: f32, out: []u8) c_int {
    if (width <= 0 or height <= 0) return 0;
    const controls = model.controls(onboarding.calculateLayout(width, height));
    const control = if (kind == 0) blk: {
        if (x < 0 or x > 1_000_000 or y < 0 or y > 1_000_000) return 0;
        break :blk controls.hitTest(@as(f32, @floatFromInt(x)) * width / 1_000_000, @as(f32, @floatFromInt(y)) * height / 1_000_000);
    } else if (kind == 1) blk: {
        const selected = model.selected orelse return 0;
        break :blk controls.find(selected);
    } else if (kind == 2) controls.find(.paste_phrase) else null;
    const c = control orelse return 0;
    if (!c.enabled) return 0;
    const text: []const u8, const code: c_int = switch (c.action) {
        .paste_phrase => return if (model.phase == .phrase_entry) 14 else 0,
        .copy_seed => .{ model.mnemonic() orelse return 0, 1 },
        .copy_word => |index| .{ model.mnemonicWord(index) orelse return 0, @as(c_int, index) + 2 },
        else => return 0,
    };
    if (model.phase != .backup or text.len == 0 or text.len > out.len) return 0;
    @memset(out, 0);
    @memcpy(out[0..text.len], text);
    return code;
}

test "clipboard probe and mailbox lifecycle" {
    var model = onboarding.Onboarding.init(std.testing.allocator);
    defer model.deinit();
    const phrase = "one two three four five six seven eight nine ten eleven twelve";
    model.receive(.{ .backup = try std.testing.allocator.dupe(u8, phrase) });
    var out: [1024]u8 = undefined;
    model.selected = .copy_seed;
    try std.testing.expectEqual(@as(c_int, 1), probe(&model, 1, 0, 0, 1000, 640, &out));
    try std.testing.expectEqualStrings(phrase, out[0..phrase.len]);
    model.selected = .{ .copy_word = 1 };
    try std.testing.expectEqual(@as(c_int, 3), probe(&model, 1, 0, 0, 1000, 640, &out));
    try std.testing.expectEqualStrings("two", out[0..3]);
    try std.testing.expectEqual(@as(c_int, 0), probe(&model, 0, -1, 0, 1000, 640, &out));
    const rect = onboarding.calculateLayout(1000, 640).copy;
    const x: c_int = @intFromFloat((rect.x + rect.width / 2) * 1000);
    const y: c_int = @intFromFloat((rect.y + rect.height / 2) * 1562.5);
    try std.testing.expectEqual(@as(c_int, 1), probe(&model, 0, x, y, 1000, 640, &out));
    var mailbox: ClipboardMailbox = .{};
    mailbox.copied = 1;
    mailbox.paste("abc");
    mailbox.consume(&model, 1);
    try std.testing.expectEqual(@as(?onboarding.Action, .copy_seed), model.feedback_target);
    try std.testing.expect(!mailbox.has_paste and mailbox.copied == 0);
    try std.testing.expect(std.mem.allEqual(u8, &mailbox.bytes, 0));
    mailbox.paste("bad\x00text");
    try std.testing.expect(!mailbox.has_paste);
    var recovery = onboarding.Onboarding.init(std.testing.allocator);
    defer recovery.deinit();
    recovery.receive(.{ .choice = .{ .recover_enabled = true } });
    _ = recovery.activateAction(.enter_recovery);
    try std.testing.expectEqual(@as(c_int, 14), probe(&recovery, 2, 0, 0, 1000, 640, &out));
    mailbox.paste("hello world");
    mailbox.consume(&recovery, 2);
    try std.testing.expectEqualStrings("hello world", recovery.recoveryPhrase());
    try std.testing.expect(std.mem.allEqual(u8, &mailbox.bytes, 0));
}

pub const Op = enum { inspect, create, restore, retry, generate, finish_restore, complete_backup };
pub const Result = struct { status: c_int, op: Op, bytes: [4096]u8 = undefined, len: u32 };
const StartCallback = *const fn (c_int, u32, [*c]const u8, u32) callconv(.c) void;
const RequestCallback = *const fn (c_int, u32, u32, [*c]const u8, u32) callconv(.c) void;
extern "c" fn haystack_onboarding_start(u32, StartCallback) void;
extern "c" fn haystack_onboarding_request(u32, u32, [*]const u8, u32, [*]const u8, u32, RequestCallback) void;
extern "c" fn haystack_onboarding_close(u32) void;

var generation: u32 = 0;
var token: u32 = 0;
var pending: bool = false;
var starting: bool = false;
var active: bool = false;
var known_stage: bool = false;
var operation: Op = .inspect;
var result: ?Result = null;

pub fn start() !void {
    if (active or pending or result != null) return error.Busy;
    generation +%= 1;
    known_stage = false;
    starting = true;
    pending = true;
    haystack_onboarding_start(generation, startupCallback);
}

pub fn request(op: []const u8, args: []const u8) !u32 {
    if (!active or pending or result != null) return error.Busy;
    if (args.len > 4096) return error.TooLarge;
    operation = std.meta.stringToEnum(Op, op) orelse return error.InvalidOperation;
    token +%= 1;
    pending = true;
    haystack_onboarding_request(generation, token, op.ptr, @intCast(op.len), args.ptr, @intCast(args.len), requestCallback);
    return token;
}

pub fn take() ?Result {
    const value = result;
    if (result) |*r| std.crypto.secureZero(u8, &r.bytes);
    result = null;
    return value;
}

pub fn isPending() bool {
    return pending;
}

pub fn close() void {
    haystack_onboarding_close(generation);
    generation +%= 1;
    pending = false;
    starting = false;
    active = false;
    known_stage = false;
    if (result) |*r| std.crypto.secureZero(u8, &r.bytes);
    result = null;
}

fn record(status: c_int, ptr: [*c]const u8, len: u32, op: Op) void {
    var value = Result{ .status = status, .op = op, .len = 0 };
    if (status == 1 and len <= 4096 and (len == 0 or ptr != null)) {
        value.len = len;
        if (len != 0) @memcpy(value.bytes[0..len], ptr[0..len]);
        // Only validated JSON events can establish knowledge of a durable stage.
    } else {
        const fallback = if (op == .complete_backup or op == .finish_restore)
            "{\"event\":\"complete_fail\"}"
        else if (op == .retry and known_stage)
            "{\"event\":\"restore_failed\",\"stage_created\":true,\"can_generate_new\":false}"
        else
            "{\"event\":\"blocked\"}";
        value.status = 0;
        value.len = @intCast(fallback.len);
        @memcpy(value.bytes[0..fallback.len], fallback);
    }
    result = value;
}

fn startupCallback(status: c_int, gen: u32, ptr: [*c]const u8, len: u32) callconv(.c) void {
    if (gen != generation or !pending or !starting) return;
    pending = false;
    starting = false;
    active = status == 1 and len <= 4096 and (len == 0 or ptr != null);
    record(status, ptr, len, .inspect);
}
fn requestCallback(status: c_int, gen: u32, tok: u32, ptr: [*c]const u8, len: u32) callconv(.c) void {
    if (gen != generation or !pending or starting or tok != token) return;
    pending = false;
    record(status, ptr, len, operation);
}

fn field(obj: std.json.Value, name: []const u8) !std.json.Value {
    if (obj != .object) return error.InvalidEvent;
    return obj.object.get(name) orelse error.InvalidEvent;
}

fn exact(obj: std.json.Value, count: usize) !void {
    if (obj != .object or obj.object.count() != count) return error.InvalidEvent;
}

fn boolean(obj: std.json.Value, name: []const u8) !bool {
    const v = try field(obj, name);
    if (v != .bool) return error.InvalidEvent;
    return v.bool;
}

fn decimal(obj: std.json.Value, name: []const u8) !u64 {
    const v = try field(obj, name);
    if (v != .string or v.string.len == 0 or (v.string.len > 1 and v.string[0] == '0')) return error.InvalidEvent;
    for (v.string) |c| if (c < '0' or c > '9') return error.InvalidEvent;
    return std.fmt.parseInt(u64, v.string, 10) catch error.InvalidEvent;
}

fn report(obj: std.json.Value) !onboarding.RestoreReport {
    try exact(obj, 4);
    return .{ .spendable_sats = try decimal(obj, "spendable_sats"), .pending_sats = try decimal(obj, "pending_sats"), .spent_sats = try decimal(obj, "spent_sats"), .can_generate_new = try boolean(obj, "can_generate_new") };
}

/// Decode before delivery; no JSON or mnemonic is logged. Backup ownership is
/// transferred to the model's allocator. The scratch arena is scrubbed.
pub fn decode(r: *const Result, allocator: std.mem.Allocator, attempt_id: u64) !onboarding.Event {
    if (r.len > r.bytes.len or !std.unicode.utf8ValidateSlice(r.bytes[0..r.len])) return error.InvalidEvent;
    var scratch: [65536]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const parsed = try std.json.parseFromSlice(std.json.Value, fba.allocator(), r.bytes[0..r.len], .{});
    defer parsed.deinit();
    const root = parsed.value;
    const ev = try field(root, "event");
    if (ev != .string) return error.InvalidEvent;
    const name = ev.string;
    const eq = std.mem.eql;
    if (eq(u8, name, "blocked")) {
        try exact(root, 1);
        if (r.op == .complete_backup or r.op == .finish_restore) return error.InvalidEvent;
        return .blocked;
    }
    if (eq(u8, name, "ready")) {
        try exact(root, 1);
        if (r.op != .inspect) return error.InvalidEvent;
        return .ready;
    }
    if (eq(u8, name, "choice")) {
        try exact(root, 2);
        if (r.op != .inspect or !try boolean(root, "recover_enabled")) return error.InvalidEvent;
        return .{ .choice = .{ .recover_enabled = true } };
    }
    if (eq(u8, name, "backup")) {
        try exact(root, 2);
        if (r.op != .inspect and r.op != .create and r.op != .generate) return error.InvalidEvent;
        const v = try field(root, "mnemonic");
        if (v != .string or v.string.len == 0 or v.string.len > 1024 or !std.unicode.utf8ValidateSlice(v.string)) return error.InvalidEvent;
        var words: usize = 1;
        var prev_space = true;
        for (v.string) |c| {
            if (c == ' ') {
                if (prev_space) return error.InvalidEvent;
                words += 1;
                prev_space = true;
            } else {
                if (c < 'a' or c > 'z') return error.InvalidEvent;
                prev_space = false;
            }
        }
        if (prev_space or words != 12) return error.InvalidEvent;
        return .{ .backup = try allocator.dupe(u8, v.string) };
    }
    if (eq(u8, name, "complete_success") or eq(u8, name, "complete_fail")) {
        try exact(root, 1);
        if (r.op != .complete_backup and r.op != .finish_restore) return error.InvalidEvent;
        return if (eq(u8, name, "complete_success")) .complete_success else .complete_fail;
    }
    if (eq(u8, name, "resume_failed")) {
        try exact(root, 2);
        if (r.op != .inspect or try boolean(root, "can_generate_new")) return error.InvalidEvent;
        return .{ .resume_failed = .{ .can_generate_new = false } };
    }
    if (eq(u8, name, "resume_result")) {
        try exact(root, 2);
        if (r.op != .inspect) return error.InvalidEvent;
        return .{ .resume_result = try report(try field(root, "report")) };
    }
    if (eq(u8, name, "invalid_phrase")) {
        try exact(root, 1);
        if (r.op != .restore) return error.InvalidEvent;
        return .{ .invalid_phrase = attempt_id };
    }
    if (eq(u8, name, "restore_failed")) {
        try exact(root, 3);
        if ((r.op != .restore and r.op != .retry) or !try boolean(root, "stage_created") or try boolean(root, "can_generate_new")) return error.InvalidEvent;
        return .{ .restore_failed = .{ .attempt_id = attempt_id, .stage_created = true, .can_generate_new = false } };
    }
    if (eq(u8, name, "restore_finished")) {
        try exact(root, 2);
        if (r.op != .restore and r.op != .retry) return error.InvalidEvent;
        return .{ .restore_finished = .{ .attempt_id = attempt_id, .report = try report(try field(root, "report")) } };
    }
    return error.InvalidEvent;
}

pub fn deliver(r: *const Result, model: *onboarding.Onboarding) void {
    const event = decode(r, model.allocator, model.attempt_id) catch {
        model.receive(.blocked);
        return;
    };
    switch (event) {
        .resume_failed, .resume_result, .restore_failed, .restore_finished => known_stage = true,
        .choice, .ready, .backup, .complete_success => known_stage = false,
        else => {},
    }
    model.receive(event);
}

// Retain all bridge symbols in the renderer without starting the service.
pub fn link(which: u32) callconv(.c) void {
    switch (which) {
        1 => start() catch {},
        2 => {
            _ = request("inspect", "{}") catch 0;
        },
        3 => close(),
        else => {},
    }
}

test "stale tokens, generations, duplicate callbacks and bounded results" {
    generation = 10;
    token = 7;
    pending = true;
    starting = false;
    result = null;
    requestCallback(1, 9, 7, null, 0);
    requestCallback(1, 10, 6, null, 0);
    try std.testing.expect(pending and result == null);
    operation = .inspect;
    requestCallback(1, 10, 7, null, 4097);
    try std.testing.expect(!pending);
    const r = take().?;
    try std.testing.expectEqualStrings("{\"event\":\"blocked\"}", r.bytes[0..r.len]);
    requestCallback(1, 10, 7, null, 0);
    try std.testing.expect(take() == null);
    var full: [4096]u8 = @splat('x');
    record(1, &full, 4096, .inspect);
    try std.testing.expectEqual(@as(u32, 4096), take().?.len);
}

test "retry failure only reports a known stage" {
    known_stage = false;
    record(0, null, 0, .retry);
    var r = take().?;
    try std.testing.expectEqualStrings("{\"event\":\"blocked\"}", r.bytes[0..r.len]);
    const stage = "{\"event\":\"resume_failed\",\"can_generate_new\":false}";
    record(1, stage.ptr, stage.len, .inspect);
    var model = onboarding.Onboarding.init(std.testing.allocator);
    defer model.deinit();
    deliver(&(take().?), &model);
    record(0, null, 0, .retry);
    r = take().?;
    try std.testing.expectEqualStrings("{\"event\":\"restore_failed\",\"stage_created\":true,\"can_generate_new\":false}", r.bytes[0..r.len]);
    record(0, null, 0, .restore);
    r = take().?;
    try std.testing.expectEqualStrings("{\"event\":\"blocked\"}", r.bytes[0..r.len]);
}

fn testResult(op: Op, text: []const u8) Result {
    var r = Result{ .status = 1, .op = op, .len = @intCast(text.len) };
    @memcpy(r.bytes[0..text.len], text);
    return r;
}

test "strict event decoding and operation gating" {
    const cases = [_]struct { Op, []const u8 }{
        .{ .inspect, "{\"event\":\"choice\",\"recover_enabled\":true}" },
        .{ .inspect, "{\"event\":\"ready\"}" },
        .{ .inspect, "{\"event\":\"blocked\"}" },
        .{ .inspect, "{\"event\":\"resume_failed\",\"can_generate_new\":false}" },
        .{ .inspect, "{\"event\":\"resume_result\",\"report\":{\"spendable_sats\":\"18446744073709551615\",\"pending_sats\":\"0\",\"spent_sats\":\"1\",\"can_generate_new\":false}}" },
        .{ .restore, "{\"event\":\"invalid_phrase\"}" },
        .{ .retry, "{\"event\":\"restore_failed\",\"stage_created\":true,\"can_generate_new\":false}" },
        .{ .restore, "{\"event\":\"restore_finished\",\"report\":{\"spendable_sats\":\"0\",\"pending_sats\":\"0\",\"spent_sats\":\"0\",\"can_generate_new\":true}}" },
        .{ .complete_backup, "{\"event\":\"complete_success\"}" },
        .{ .finish_restore, "{\"event\":\"complete_fail\"}" },
    };
    for (cases) |c| _ = try decode(&testResult(c[0], c[1]), std.testing.allocator, 42);
    const bad = [_]struct { Op, []const u8 }{
        .{ .create, "{\"event\":\"ready\"}" },
        .{ .retry, "{\"event\":\"invalid_phrase\"}" },
        .{ .finish_restore, "{\"event\":\"blocked\"}" },
        .{ .inspect, "{\"event\":\"ready\",\"extra\":1}" },
        .{ .inspect, "{\"event\":\"ready\",\"event\":\"ready\"}" },
        .{ .inspect, "{\"event\":\"choice\",\"recover_enabled\":false}" },
        .{ .inspect, "{\"event\":\"resume_failed\",\"can_generate_new\":true}" },
        .{ .restore, "{\"event\":\"restore_failed\",\"stage_created\":false,\"can_generate_new\":false}" },
        .{ .inspect, "{\"event\":\"resume_result\",\"report\":{\"spendable_sats\":\"01\",\"pending_sats\":\"0\",\"spent_sats\":\"0\",\"can_generate_new\":false}}" },
        .{ .inspect, "{\"event\":\"resume_result\",\"report\":{\"spendable_sats\":\"18446744073709551616\",\"pending_sats\":\"0\",\"spent_sats\":\"0\",\"can_generate_new\":false}}" },
        .{ .inspect, "{\"event\":\"ready\"}\xff" },
    };
    for (bad) |c| {
        if (decode(&testResult(c[0], c[1]), std.testing.allocator, 42)) |_| {
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "backup ownership validation and scan attempt" {
    const good = "{\"event\":\"backup\",\"mnemonic\":\"one two three four five six seven eight nine ten eleven twelve\"}";
    var model = onboarding.Onboarding.init(std.testing.allocator);
    defer model.deinit();
    deliver(&testResult(.inspect, good), &model);
    try std.testing.expect(model.phase == .backup);
    const bad = [_][]const u8{
        "{\"event\":\"backup\",\"mnemonic\":\"\"}",
        "{\"event\":\"backup\",\"mnemonic\":\"one two\"}",
        "{\"event\":\"backup\",\"mnemonic\":\"one  two three four five six seven eight nine ten eleven twelve\"}",
        "{\"event\":\"backup\",\"mnemonic\":\"One two three four five six seven eight nine ten eleven twelve\"}",
        "{\"event\":\"backup\",\"mnemonic\":\"one two three four five six seven eight nine ten eleven twelve\\u0000\"}",
    };
    for (bad) |text| try std.testing.expectError(error.InvalidEvent, decode(&testResult(.inspect, text), std.testing.allocator, 0));
    const event = try decode(&testResult(.restore, "{\"event\":\"invalid_phrase\"}"), std.testing.allocator, 42);
    try std.testing.expect(event == .invalid_phrase and event.invalid_phrase == 42);
}

test "startup callback defers model delivery and fails closed" {
    var model = onboarding.Onboarding.init(std.testing.allocator);
    defer model.deinit();
    generation = 88;
    pending = true;
    starting = true;
    result = null;
    startupCallback(0, 88, null, 0);
    try std.testing.expect(model.phase == .loading);
    var r = take().?;
    defer std.crypto.secureZero(u8, &r.bytes);
    deliver(&r, &model);
    try std.testing.expect(model.phase == .blocked);
}
