//! Desktop storage locations.
//!
//! The policy is intentionally small and explicit:
//! * Linux follows `XDG_CONFIG_HOME` and `XDG_DATA_HOME` when they contain a
//!   non-empty absolute path; otherwise the XDG defaults under `$HOME` apply.
//! * macOS always uses `~/Library/Application Support/haystack`.
//! * There is no cache directory.
//!
//! Path resolution is a pure function so the policy can be tested without
//! touching the real environment or filesystem.

const std = @import("std");
const builtin = @import("builtin");

pub const Platform = enum { linux, macos };

pub const Locations = struct {
    config_dir: []u8,
    config_path: []u8,
    content_dir: []u8,
    /// One fixed user wallet. The directory is Haystack-owned; its two entries
    /// are the plaintext BIP-39 mnemonic and the CDK SQLite database.
    wallet_dir: []u8,
    wallet_seed_path: []u8,
    wallet_db_path: []u8,
    /// Standard environment directories that a clean HOME may lack. They are
    /// created only when missing; existing entries are never modified. Explicit
    /// XDG overrides are not listed and must already exist.
    standard_parents: []const []u8,

    pub fn deinit(self: Locations, allocator: std.mem.Allocator) void {
        allocator.free(self.config_dir);
        allocator.free(self.config_path);
        allocator.free(self.content_dir);
        allocator.free(self.wallet_dir);
        allocator.free(self.wallet_seed_path);
        allocator.free(self.wallet_db_path);
        for (self.standard_parents) |path| allocator.free(path);
        allocator.free(self.standard_parents);
    }
};

pub const ResolveError = error{
    UnsupportedPlatform,
    InvalidHome,
    OutOfMemory,
};

/// Resolve the Haystack-owned directories for one user.
///
/// `xdg_config_home` and `xdg_data_home` are ignored on macOS and on Linux when
/// they are empty or relative. `home` must be absolute.
pub fn resolve(
    allocator: std.mem.Allocator,
    platform: Platform,
    xdg_config_home: ?[]const u8,
    xdg_data_home: ?[]const u8,
    home: []const u8,
) ResolveError!Locations {
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return error.InvalidHome;

    const config_dir = switch (platform) {
        .linux => blk: {
            if (validXdg(xdg_config_home)) |base| {
                break :blk try std.fs.path.join(allocator, &.{ base, "haystack" });
            }
            break :blk try std.fs.path.join(allocator, &.{ home, ".config", "haystack" });
        },
        .macos => try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "haystack" }),
    };
    errdefer allocator.free(config_dir);

    const config_path = try std.fs.path.join(allocator, &.{ config_dir, "config.json" });
    errdefer allocator.free(config_path);

    const content_dir = switch (platform) {
        .linux => blk: {
            if (validXdg(xdg_data_home)) |base| {
                break :blk try std.fs.path.join(allocator, &.{ base, "haystack", "content" });
            }
            break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share", "haystack", "content" });
        },
        .macos => try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "haystack", "content" }),
    };
    errdefer allocator.free(content_dir);

    const wallet_dir = switch (platform) {
        .linux => blk: {
            if (validXdg(xdg_data_home)) |base| {
                break :blk try std.fs.path.join(allocator, &.{ base, "haystack", "wallet" });
            }
            break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share", "haystack", "wallet" });
        },
        .macos => try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "haystack", "wallet" }),
    };
    errdefer allocator.free(wallet_dir);

    const wallet_seed_path = try std.fs.path.join(allocator, &.{ wallet_dir, "seed-words.txt" });
    errdefer allocator.free(wallet_seed_path);

    const wallet_db_path = try std.fs.path.join(allocator, &.{ wallet_dir, "wallet.sqlite" });
    errdefer allocator.free(wallet_db_path);

    var parents: std.ArrayList([]u8) = .empty;
    errdefer {
        for (parents.items) |path| allocator.free(path);
        parents.deinit(allocator);
    }
    switch (platform) {
        .linux => {
            if (validXdg(xdg_config_home) == null) {
                try appendJoined(&parents, allocator, &.{ home, ".config" });
            }
            if (validXdg(xdg_data_home) == null) {
                try appendJoined(&parents, allocator, &.{ home, ".local" });
                try appendJoined(&parents, allocator, &.{ home, ".local", "share" });
            }
        },
        .macos => {
            try appendJoined(&parents, allocator, &.{ home, "Library" });
            try appendJoined(&parents, allocator, &.{ home, "Library", "Application Support" });
        },
    }

    return .{
        .config_dir = config_dir,
        .config_path = config_path,
        .content_dir = content_dir,
        .wallet_dir = wallet_dir,
        .wallet_seed_path = wallet_seed_path,
        .wallet_db_path = wallet_db_path,
        .standard_parents = try parents.toOwnedSlice(allocator),
    };
}

fn validXdg(value: ?[]const u8) ?[]const u8 {
    const path = value orelse return null;
    if (path.len == 0) return null;
    if (!std.fs.path.isAbsolute(path)) return null;
    return path;
}

fn appendJoined(list: *std.ArrayList([]u8), allocator: std.mem.Allocator, components: []const []const u8) !void {
    const path = try std.fs.path.join(allocator, components);
    errdefer allocator.free(path);
    try list.append(allocator, path);
}

/// The compile-time desktop platform. Callers should reject before this on an
/// unsupported target; `main` only reaches desktop storage on Linux/macOS.
pub fn currentPlatform() error{UnsupportedPlatform}!Platform {
    return switch (builtin.os.tag) {
        .linux => .linux,
        .macos => .macos,
        else => error.UnsupportedPlatform,
    };
}

/// Read the current user's storage locations from the environment.
pub fn resolveCurrent(allocator: std.mem.Allocator) (ResolveError || error{EnvironmentUnavailable})!Locations {
    const platform = try currentPlatform();
    const home = env("HOME") orelse return error.EnvironmentUnavailable;
    if (platform == .linux) {
        return resolve(allocator, platform, env("XDG_CONFIG_HOME"), env("XDG_DATA_HOME"), home);
    }
    return resolve(allocator, platform, null, null, home);
}

fn env(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name.ptr) orelse return null;
    return std.mem.span(value);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "linux defaults to XDG base directories under HOME" {
    const locations = try resolve(testing.allocator, .linux, null, null, "/home/player");
    defer locations.deinit(testing.allocator);

    try testing.expectEqualStrings("/home/player/.config/haystack", locations.config_dir);
    try testing.expectEqualStrings("/home/player/.config/haystack/config.json", locations.config_path);
    try testing.expectEqualStrings("/home/player/.local/share/haystack/content", locations.content_dir);
    try testing.expectEqualStrings("/home/player/.local/share/haystack/wallet", locations.wallet_dir);
    try testing.expectEqualStrings("/home/player/.local/share/haystack/wallet/seed-words.txt", locations.wallet_seed_path);
    try testing.expectEqualStrings("/home/player/.local/share/haystack/wallet/wallet.sqlite", locations.wallet_db_path);
    try testing.expectEqual(@as(usize, 3), locations.standard_parents.len);
    try testing.expectEqualStrings("/home/player/.config", locations.standard_parents[0]);
    try testing.expectEqualStrings("/home/player/.local", locations.standard_parents[1]);
    try testing.expectEqualStrings("/home/player/.local/share", locations.standard_parents[2]);
}

test "linux honours absolute XDG overrides" {
    const locations = try resolve(
        testing.allocator,
        .linux,
        "/srv/config",
        "/srv/data",
        "/home/player",
    );
    defer locations.deinit(testing.allocator);

    try testing.expectEqualStrings("/srv/config/haystack", locations.config_dir);
    try testing.expectEqualStrings("/srv/data/haystack/content", locations.content_dir);
    try testing.expectEqualStrings("/srv/data/haystack/wallet", locations.wallet_dir);
    try testing.expectEqualStrings("/srv/data/haystack/wallet/seed-words.txt", locations.wallet_seed_path);
    try testing.expectEqualStrings("/srv/data/haystack/wallet/wallet.sqlite", locations.wallet_db_path);
    // Explicit XDG bases are user-supplied and must already exist.
    try testing.expectEqual(@as(usize, 0), locations.standard_parents.len);
}

test "linux ignores empty and relative XDG overrides" {
    const locations = try resolve(
        testing.allocator,
        .linux,
        "",
        "relative/data",
        "/home/player",
    );
    defer locations.deinit(testing.allocator);

    try testing.expectEqualStrings("/home/player/.config/haystack", locations.config_dir);
    try testing.expectEqualStrings("/home/player/.local/share/haystack/content", locations.content_dir);
    try testing.expectEqualStrings("/home/player/.local/share/haystack/wallet", locations.wallet_dir);
}

test "macos ignores XDG and uses Application Support" {
    const locations = try resolve(
        testing.allocator,
        .macos,
        "/srv/config",
        "/srv/data",
        "/Users/player",
    );
    defer locations.deinit(testing.allocator);

    try testing.expectEqualStrings("/Users/player/Library/Application Support/haystack", locations.config_dir);
    try testing.expectEqualStrings("/Users/player/Library/Application Support/haystack/config.json", locations.config_path);
    try testing.expectEqualStrings("/Users/player/Library/Application Support/haystack/content", locations.content_dir);
    try testing.expectEqualStrings("/Users/player/Library/Application Support/haystack/wallet", locations.wallet_dir);
    try testing.expectEqualStrings("/Users/player/Library/Application Support/haystack/wallet/seed-words.txt", locations.wallet_seed_path);
    try testing.expectEqualStrings("/Users/player/Library/Application Support/haystack/wallet/wallet.sqlite", locations.wallet_db_path);
    try testing.expectEqual(@as(usize, 2), locations.standard_parents.len);
    try testing.expectEqualStrings("/Users/player/Library", locations.standard_parents[0]);
    try testing.expectEqualStrings("/Users/player/Library/Application Support", locations.standard_parents[1]);
}

test "invalid HOME is rejected" {
    try testing.expectError(error.InvalidHome, resolve(testing.allocator, .linux, null, null, ""));
    try testing.expectError(error.InvalidHome, resolve(testing.allocator, .linux, null, null, "relative/home"));
}
