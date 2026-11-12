//! Browser settings and content bridge.
//!
//! The Emscripten JS library (`browser/game-storage.js`) owns the Web Lock,
//! IndexedDB access, and JSON encoding. Zig only sees plain values so no wasm
//! memory is borrowed across an `await`.
//!
//! Settings startup is a single-shot callback. Saves are fire-and-forget: the
//! JS side queues an IndexedDB transaction and resolves it independently, so
//! the frame loop never blocks and Asyncify stays disabled.
//!
//! Content storage mirrors the desktop content store: flat keys, whole-file
//! entries up to 64 MiB, and the same key grammar. All calls are asynchronous.
//! Inputs are copied by JS before any await. Successful read/list results are
//! allocated by JS with `malloc`; the Zig callback owns that allocation and must
//! call `freeResult` exactly once (a null pointer is a no-op). The JS side never
//! retains a wasm memory view across an await.

const std = @import("std");
const builtin = @import("builtin");

const key_mod = @import("content_key.zig");
const settings_mod = @import("settings.zig");

pub const Status = enum(c_int) {
    ready = 0,
    unavailable = 1,
    malformed = 2,
    newer_version = 3,
    locked = 4,
};

pub const Loaded = struct {
    status: Status,
    settings: settings_mod.Settings,
};

pub const callback_sig = *const fn (status: c_int, tile_grid: c_int, chunk_borders: c_int, autosave_blocked: c_int) callconv(.c) void;

extern "c" fn haystack_storage_start(callback: callback_sig, default_tile_grid: c_int, default_chunk_borders: c_int) void;
extern "c" fn haystack_storage_save(tile_grid: c_int, chunk_borders: c_int) void;
extern "c" fn haystack_storage_reset() void;

/// Start the Web Lock + settings load. The callback runs exactly once from the
/// JS async continuation. Built-in defaults are passed across so a missing or
/// unavailable configuration matches this build's `Settings{}` defaults.
pub fn start(callback: callback_sig) void {
    const defaults = settings_mod.Settings{};
    haystack_storage_start(
        callback,
        @intFromBool(defaults.debug.tile_grid),
        @intFromBool(defaults.debug.chunk_borders),
    );
}

/// Queue a settings write. This returns immediately and never blocks a frame.
pub fn save(tile_grid: bool, chunk_borders: bool) void {
    haystack_storage_save(@intFromBool(tile_grid), @intFromBool(chunk_borders));
}

/// Remove the stored configuration through the JS bridge. The next save is
/// allowed again once the delete transaction completes.
pub fn reset() void {
    haystack_storage_reset();
}

pub fn decode(status_code: c_int, tile_grid: c_int, chunk_borders: c_int) Loaded {
    const status: Status = switch (status_code) {
        0 => .ready,
        1 => .unavailable,
        2 => .malformed,
        3 => .newer_version,
        4 => .locked,
        else => .unavailable,
    };

    var settings: settings_mod.Settings = .{};
    // Only a successfully parsed configuration overrides built-in defaults.
    if (status == .ready) {
        settings.debug.tile_grid = tile_grid != 0;
        settings.debug.chunk_borders = chunk_borders != 0;
    }
    return .{ .status = status, .settings = settings };
}

// ── content store ────────────────────────────────────────────────────────────

pub const content_max_key_bytes = key_mod.max_key_bytes;
pub const content_max_file_bytes = key_mod.max_file_bytes;

/// Result codes shared by every content callback. `ok` is 0; any other value
/// means no result buffer is delivered (always null).
pub const ContentStatus = enum(c_int) {
    ok = 0,
    not_found = 1,
    invalid_key = 2,
    too_large = 3,
    unavailable = 4,
    io_error = 5,
};

pub const ContentError = key_mod.Error;

pub const WriteCallback = *const fn (context: usize, status: c_int) callconv(.c) void;
pub const DeleteCallback = WriteCallback;
/// `data` is a Zig-owned allocation of `len` bytes. The callback owns it and
/// must call `freeResult(data)` exactly once, even when `status` is not `ok`
/// (null is a no-op).
pub const ReadCallback = *const fn (context: usize, status: c_int, data: ?[*]u8, len: usize) callconv(.c) void;
/// `keys` contains `count` keys joined by single `\n` bytes (keys are ASCII and
/// never contain `\n`). The callback owns the allocation and must call
/// `freeResult(keys)` exactly once. An empty list delivers a null pointer, zero
/// length, and zero count.
pub const ListCallback = *const fn (context: usize, status: c_int, keys: ?[*]u8, len: usize, count: usize) callconv(.c) void;

/// JS calls back into these after the await to obtain and release result
/// memory. They are passed automatically by the `content*` helpers and are not
/// part of the public API.
pub const AllocCallback = *const fn (len: usize) callconv(.c) ?[*]u8;
pub const ReleaseCallback = *const fn (pointer: usize) callconv(.c) void;

extern "c" fn haystack_content_write(key_ptr: [*]const u8, key_len: usize, data_ptr: [*]const u8, data_len: usize, callback: WriteCallback, context: usize) void;
extern "c" fn haystack_content_read(key_ptr: [*]const u8, key_len: usize, callback: ReadCallback, context: usize, allocate: AllocCallback, release: ReleaseCallback) void;
extern "c" fn haystack_content_list(callback: ListCallback, context: usize, allocate: AllocCallback, release: ReleaseCallback) void;
extern "c" fn haystack_content_delete(key_ptr: [*]const u8, key_len: usize, callback: DeleteCallback, context: usize) void;

/// Allocate a result buffer after the JS await has completed. The JS bridge
/// copies bytes into this buffer and then invokes the Zig callback, which owns
/// and frees it.
pub fn allocContentResult(len: usize) callconv(.c) ?[*]u8 {
    if (len == 0 or len > content_max_file_bytes) return null;
    const buffer = std.heap.c_allocator.alloc(u8, len) catch return null;
    return buffer.ptr;
}

/// Release a buffer returned through a content callback. Safe for a null
/// pointer and for a zero-length result.
pub fn freeContentResult(pointer: usize) callconv(.c) void {
    if (pointer == 0) return;
    std.c.free(@ptrFromInt(pointer));
}

/// Write one whole entry. Local argument errors are returned synchronously;
/// storage results arrive through the callback. Inputs are copied by JS before
/// the first await, so `data` may be freed as soon as this returns.
pub fn contentWrite(key: []const u8, data: []const u8, callback: WriteCallback, context: usize) ContentError!void {
    try key_mod.validateKey(key);
    try key_mod.validateSize(data.len);
    if (comptime builtin.os.tag == .emscripten) {
        haystack_content_write(key.ptr, key.len, data.ptr, data.len, callback, context);
    } else {
        @panic("browser content storage is only available in the browser build");
    }
}

/// Read one whole entry. Local argument errors are returned synchronously.
pub fn contentRead(key: []const u8, callback: ReadCallback, context: usize) ContentError!void {
    try key_mod.validateKey(key);
    if (comptime builtin.os.tag == .emscripten) {
        haystack_content_read(key.ptr, key.len, callback, context, &allocContentResult, &freeContentResult);
    } else {
        @panic("browser content storage is only available in the browser build");
    }
}

/// List committed keys in stable byte order.
pub fn contentList(callback: ListCallback, context: usize) void {
    if (comptime builtin.os.tag == .emscripten) {
        haystack_content_list(callback, context, &allocContentResult, &freeContentResult);
    } else {
        @panic("browser content storage is only available in the browser build");
    }
}

/// Delete one entry. Local argument errors are returned synchronously. A
/// missing entry is reported as `ContentStatus.not_found` through the callback;
/// the JS bridge checks existence and deletes in one readwrite transaction.
pub fn contentDelete(key: []const u8, callback: DeleteCallback, context: usize) ContentError!void {
    try key_mod.validateKey(key);
    if (comptime builtin.os.tag == .emscripten) {
        haystack_content_delete(key.ptr, key.len, callback, context);
    } else {
        @panic("browser content storage is only available in the browser build");
    }
}

/// Release a result buffer allocated by the JS bridge. Safe for null.
pub fn freeResult(buffer: ?[*]u8) void {
    if (buffer) |ptr| freeContentResult(@intFromPtr(ptr));
}

/// A non-null result buffer as a borrowed slice. Do not retain it after the
/// callback returns unless you copy the bytes first.
pub fn resultSlice(buffer: ?[*]u8, len: usize) []const u8 {
    const ptr = buffer orelse return &.{};
    return ptr[0..len];
}

pub fn contentStatusFromCode(code: c_int) ContentStatus {
    return switch (code) {
        0 => .ok,
        1 => .not_found,
        2 => .invalid_key,
        3 => .too_large,
        4 => .unavailable,
        5 => .io_error,
        else => .io_error,
    };
}

// The game does not call the content API yet, so a plain extern reference would
// be dead-code eliminated and the JS library functions would never be linked or
// signature-checked. This exported anchor keeps the bridge in the module.
comptime {
    if (builtin.os.tag == .emscripten) @export(&contentBridgeAnchor, .{ .name = "haystack_content_bridge_anchor" });
}

var content_bridge_sink: usize = 0;

fn contentBridgeAnchor() callconv(.c) void {
    content_bridge_sink = @intFromPtr(&haystack_content_write) ^
        @intFromPtr(&haystack_content_read) ^
        @intFromPtr(&haystack_content_list) ^
        @intFromPtr(&haystack_content_delete);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "browser content rejects local key and size violations before the bridge" {
    const Noop = struct {
        fn write(_: usize, _: c_int) callconv(.c) void {}
        fn read(_: usize, _: c_int, _: ?[*]u8, _: usize) callconv(.c) void {}
    };

    try testing.expectError(error.InvalidKey, contentWrite("nested/key", "x", Noop.write, 0));
    try testing.expectError(error.InvalidKey, contentRead("has space", Noop.read, 0));

    const oversized = try testing.allocator.alloc(u8, content_max_file_bytes + 1);
    defer testing.allocator.free(oversized);
    try testing.expectError(error.FileTooLarge, contentWrite("valid", oversized, Noop.write, 0));
}

test "browser content status codes map explicitly" {
    try testing.expectEqual(ContentStatus.ok, contentStatusFromCode(0));
    try testing.expectEqual(ContentStatus.not_found, contentStatusFromCode(1));
    try testing.expectEqual(ContentStatus.invalid_key, contentStatusFromCode(2));
    try testing.expectEqual(ContentStatus.too_large, contentStatusFromCode(3));
    try testing.expectEqual(ContentStatus.unavailable, contentStatusFromCode(4));
    try testing.expectEqual(ContentStatus.io_error, contentStatusFromCode(5));
    try testing.expectEqual(ContentStatus.io_error, contentStatusFromCode(99));
}
