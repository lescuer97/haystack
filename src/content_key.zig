//! Content addressing shared by the desktop filesystem store and the browser
//! IndexedDB store.
//!
//! A key is 1–128 ASCII bytes from `[A-Za-z0-9_-]`. There are no directories,
//! extensions, or nesting. Each key maps to one whole entry of at most 64 MiB.
//!
//! This module is deliberately dependency-free so the browser build can use it
//! without pulling in the desktop filesystem modules.

const std = @import("std");

pub const max_key_bytes: usize = 128;
pub const max_file_bytes: usize = 64 * 1024 * 1024;

pub const Error = error{
    InvalidKey,
    FileTooLarge,
};

pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_bytes) return false;
    for (key) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return false;
    }
    return true;
}

pub fn validateKey(key: []const u8) Error!void {
    if (!validKey(key)) return error.InvalidKey;
}

pub fn validateSize(size: usize) Error!void {
    if (size > max_file_bytes) return error.FileTooLarge;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "keys are flat, bounded, and ASCII" {
    try validateKey("abc");
    try validateKey("A_b-9");
    try testing.expect(!validKey(""));
    try testing.expect(!validKey("has space"));
    try testing.expect(!validKey("nested/key"));
    try testing.expect(!validKey(".tmp-123"));
    try testing.expect(!validKey("caf\u{e9}"));

    const max: [max_key_bytes]u8 = @splat('a');
    try validateKey(&max);
    const too_long: [max_key_bytes + 1]u8 = @splat('a');
    try testing.expectError(error.InvalidKey, validateKey(&too_long));
}

test "content entries are capped at 64 MiB" {
    try validateSize(0);
    try validateSize(max_file_bytes);
    try testing.expectError(error.FileTooLarge, validateSize(max_file_bytes + 1));
}
