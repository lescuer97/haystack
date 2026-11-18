//! Startup-only provisioning. Main owns the returned wallet and lifetime lock.
const std = @import("std");
const native = @import("native_storage");
const sf = native.storage_fs;
pub const Wallet = native.wallet.Wallet;
/// Test-only failure at a specific parent, after the pair was committed.
pub var testFailParentSyncPath: ?[]const u8 = null;
pub var testSyncObserver: ?*const fn ([]const u8) void = null;

pub fn open(io: std.Io, allocator: std.mem.Allocator, locations: native.paths.Locations) !Wallet {
    const paths = try native.wallet.Paths.init(allocator, locations.wallet_dir);
    defer paths.deinit(allocator);
    // Validate the managed data root even when the final wallet is absent.
    try sf.ensureOwnedDir(io, std.fs.path.dirname(paths.dir) orelse return error.InvalidPath);
    var inspected = try native.wallet.inspect(io, allocator, paths, true);
    errdefer inspected.close() catch {};
    switch (inspected.state) {
        .incomplete => return error.IncompleteWallet,
        .not_initialized => {
            // create refuses even an existing empty directory; never repair it.
            const created = try native.wallet.create(io, allocator, paths);
            const durability = created.durability;
            created.deinit(allocator);
            if (durability != .durable) return error.WalletDurabilityUnknown;
            inspected = try native.wallet.inspect(io, allocator, paths, true);
        },
        .ready => {},
    }
    try native.wallet.syncDurability(io, paths);
    try syncParents(io, locations);
    return inspected.wallet orelse error.WalletNotReady;
}

/// Repeat bottom-up on every restart, including HOME when standard parents
/// were newly created. Standard parents may be symlinks, unlike managed roots.
fn syncParents(io: std.Io, locations: native.paths.Locations) !void {
    try syncPath(io, locations.config_dir, true);
    try syncPath(io, std.fs.path.dirname(locations.config_dir) orelse return error.InvalidPath, false);
    var i = locations.standard_parents.len;
    while (i > 0) {
        i -= 1;
        const path = locations.standard_parents[i];
        try syncPath(io, path, false);
        try syncPath(io, std.fs.path.dirname(path) orelse return error.InvalidPath, false);
    }
}

fn syncPath(io: std.Io, path: []const u8, managed: bool) !void {
    const dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true, .follow_symlinks = !managed });
    defer dir.close(io);
    if (@import("builtin").is_test) if (testFailParentSyncPath) |failed| {
        if (std.mem.eql(u8, path, failed)) return error.SyncFailed;
    };
    try sf.syncDirectory(dir);
    if (@import("builtin").is_test) if (testSyncObserver) |observe| observe(path);
}
