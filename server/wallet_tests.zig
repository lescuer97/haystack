//! Real persistent CDK wallet and volatile world, isolated filesystem only.
const std = @import("std");
const native = @import("native_storage");
const server_wallet = @import("wallet.zig");
const app = @import("app.zig");
const t = std.testing;
const sf = native.storage_fs;

var sync_seen: u8 = 0;
var sync_home: []const u8 = "";
fn observeSync(path: []const u8) void {
    if (std.mem.eql(u8, path, sync_home)) sync_seen |= 1;
    if (std.mem.endsWith(u8, path, "/.local")) sync_seen |= 2;
    if (std.mem.endsWith(u8, path, "/.local/share")) sync_seen |= 4;
    if (std.mem.endsWith(u8, path, "/.config")) sync_seen |= 8;
    if (std.mem.endsWith(u8, path, "/.config/haystack-server")) sync_seen |= 16;
}

const Home = struct {
    tmp: t.TmpDir,
    locations: native.paths.Locations,

    fn init() !Home {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
        defer t.allocator.free(root);
        const locations = try native.paths.resolveIdentity(t.allocator, .server, .linux, null, null, root);
        errdefer locations.deinit(t.allocator);
        try sf.ensureStandardParents(t.io, locations.standard_parents);
        return .{ .tmp = tmp, .locations = locations };
    }

    fn deinit(self: *Home) void {
        self.locations.deinit(t.allocator);
        self.tmp.cleanup();
    }

    fn seedHash(self: *Home) ![32]u8 {
        const paths = try native.wallet.Paths.init(t.allocator, self.locations.wallet_dir);
        defer paths.deinit(t.allocator);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, paths.seed_path, t.allocator, .limited(1024));
        defer {
            std.crypto.secureZero(u8, bytes);
            t.allocator.free(bytes);
        }
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        return hash;
    }
};

test "headless fresh world restart preserves borrowed wallet owner" {
    var home = try Home.init();
    defer home.deinit();
    var lock = try native.instance_lock.acquire(t.io, home.locations.config_dir);
    defer lock.release(t.io);
    sync_home = std.fs.path.dirname(home.locations.standard_parents[0]).?;
    sync_seen = 0;
    server_wallet.testSyncObserver = observeSync;
    defer {
        server_wallet.testSyncObserver = null;
        sync_home = "";
    }
    try t.expectError(error.AlreadyRunning, native.instance_lock.acquire(t.io, home.locations.config_dir));
    var wallet = try server_wallet.open(t.io, t.allocator, home.locations);
    defer wallet.close() catch {};
    try t.expectEqual(@as(u8, 31), sync_seen);
    const fingerprint = try home.seedHash();
    const paths = try native.wallet.Paths.init(t.allocator, home.locations.wallet_dir);
    defer paths.deinit(t.allocator);
    const inode = (try std.Io.Dir.cwd().statFile(t.io, paths.db_path, .{})).inode;
    const buffers = try t.allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(app.Layout)), app.default_budget);
    defer t.allocator.free(buffers);
    {
        var application = try app.App.init(t.io, buffers);
        defer application.deinit();
        try t.expect(application.wallet == null);
        application.wallet = &wallet;
        try t.expectEqual(try wallet.borrowHandle(), try application.wallet.?.borrowHandle());
        _ = try application.context.state.cut(@import("world_state.zig").request(0, 0, 0));
        try t.expectEqual(@as(usize, 1), application.context.state.replay_count);
    }
    _ = try wallet.borrowHandle(); // App did not close its borrowed wallet.
    // Wallet remains locked and usable after application teardown.
    try t.expectError(error.CdkFailure, server_wallet.open(t.io, t.allocator, home.locations));
    try wallet.close();
    {
        var application = try app.App.init(t.io, buffers);
        defer application.deinit();
        try t.expectEqual(@as(usize, 0), application.context.state.chunk_count);
        try t.expectEqual(@as(usize, 0), application.context.state.replay_count);
    }
    sync_seen = 0;
    wallet = try server_wallet.open(t.io, t.allocator, home.locations);
    try t.expectEqual(@as(u8, 31), sync_seen);
    try t.expectEqual(fingerprint, try home.seedHash());
    try t.expectEqual(inode, (try std.Io.Dir.cwd().statFile(t.io, paths.db_path, .{})).inode);
    try wallet.close();
    try t.expectError(error.WalletClosed, wallet.borrowHandle());
    // No client settings/content/onboarding artifacts were created.
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(t.io, home.locations.config_path, .{}));
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(t.io, home.locations.content_dir, .{}));
}

test "headless unknown commit and ancestor failures preserve pair for restart" {
    defer {
        native.wallet.testFailCommitSync = false;
        native.wallet.testFailAncestorSync = false;
        server_wallet.testFailParentSyncPath = null;
    }
    for (0..3) |failure| {
        var home = try Home.init();
        defer home.deinit();
        var lock = try native.instance_lock.acquire(t.io, home.locations.config_dir);
        defer lock.release(t.io);
        native.wallet.testFailCommitSync = failure == 0;
        native.wallet.testFailAncestorSync = failure == 1;
        server_wallet.testFailParentSyncPath = if (failure == 2) std.fs.path.dirname(home.locations.standard_parents[0]).? else null;
        if (failure == 2) {
            try t.expectError(error.SyncFailed, server_wallet.open(t.io, t.allocator, home.locations));
        } else try t.expectError(error.WalletDurabilityUnknown, server_wallet.open(t.io, t.allocator, home.locations));
        const fingerprint = try home.seedHash();
        native.wallet.testFailCommitSync = false;
        native.wallet.testFailAncestorSync = false;
        server_wallet.testFailParentSyncPath = null;
        var wallet = try server_wallet.open(t.io, t.allocator, home.locations);
        defer wallet.close() catch {};
        try t.expectEqual(fingerprint, try home.seedHash());
        try t.expectError(error.AlreadyRunning, native.instance_lock.acquire(t.io, home.locations.config_dir));
    }
}

test "headless empty partial invalid and insecure wallets fail without repair" {
    for (0..4) |kind| {
        var home = try Home.init();
        defer home.deinit();
        var lock = try native.instance_lock.acquire(t.io, home.locations.config_dir);
        defer lock.release(t.io);
        const paths = try native.wallet.Paths.init(t.allocator, home.locations.wallet_dir);
        defer paths.deinit(t.allocator);
        try sf.ensureOwnedDir(t.io, std.fs.path.dirname(paths.dir).?);
        try sf.ensureOwnedDir(t.io, paths.dir);
        if (kind > 0) try std.Io.Dir.cwd().writeFile(t.io, .{
            .sub_path = paths.seed_path,
            .data = "invalid seed must remain untouched",
            .flags = .{ .permissions = sf.mode_file },
        });
        if (kind > 1) try std.Io.Dir.cwd().writeFile(t.io, .{
            .sub_path = paths.db_path,
            .data = "invalid database must remain untouched",
            .flags = .{ .permissions = if (kind == 3) .fromMode(0o644) else sf.mode_file },
        });
        const before = try std.Io.Dir.cwd().statFile(t.io, paths.dir, .{});
        if (server_wallet.open(t.io, t.allocator, home.locations)) |value| {
            var unexpected = value;
            defer unexpected.close() catch {};
            return error.UnexpectedWallet;
        } else |err| switch (kind) {
            0 => try t.expectEqual(error.AlreadyInitialized, err),
            1 => try t.expectEqual(error.IncompleteWallet, err),
            2 => try t.expectEqual(error.CdkFailure, err),
            3 => try t.expectEqual(error.InsecurePermissions, err),
            else => unreachable,
        }
        try t.expectEqual(before.inode, (try std.Io.Dir.cwd().statFile(t.io, paths.dir, .{})).inode);
        if (kind == 0) try t.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(t.io, paths.seed_path, .{}));
        if (kind < 2) try t.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(t.io, paths.db_path, .{}));
        if (kind > 0) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, paths.seed_path, t.allocator, .limited(1024));
            defer t.allocator.free(bytes);
            try t.expectEqualStrings("invalid seed must remain untouched", bytes);
        }
        if (kind > 1) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, paths.db_path, t.allocator, .limited(1024));
            defer t.allocator.free(bytes);
            try t.expectEqualStrings("invalid database must remain untouched", bytes);
            try t.expectEqual(@as(u32, if (kind == 3) 0o644 else 0o600), sf.modeOf(try std.Io.Dir.cwd().statFile(t.io, paths.db_path, .{})));
        }
    }
}
