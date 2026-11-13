//! Native fixed-wallet storage tests.
//!
//! These exercise the pair-level lifecycle around the real CDK C ABI: inspect
//! without writes, explicit provisioning through a private staging directory,
//! atomic no-replace commit, reuse, and rejection of unsafe entries. They never
//! print the mnemonic or seed.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const sf = @import("storage_fs.zig");
const wallet = @import("wallet.zig");
test {
    _ = @import("onboarding_native.zig");
}

const testing = std.testing;

const recovery_phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const recovery_id = "0123456789abcdef0123456789abcdef".*;
const other_recovery_id = "1123456789abcdef0123456789abcdef".*;

test "recovery prepares inspects and commits without overwriting" {
    var h = try Harness.init();
    defer h.deinit();
    const paths = try wallet.recoveryPaths(testing.allocator, h.paths);
    defer {
        paths.deinit(testing.allocator);
        testing.allocator.free(paths.dir);
    }
    try wallet.prepareRecovery(testing.io, testing.allocator, h.paths, recovery_phrase, recovery_id);
    try testing.expectError(error.RecoveryOwnershipMismatch, wallet.inspectRecovery(testing.io, testing.allocator, h.paths, other_recovery_id, false));
    try testing.expectError(error.RecoveryOwnershipMismatch, wallet.commitRecovery(testing.io, testing.allocator, h.paths, other_recovery_id));
    var inspected = try wallet.inspectRecovery(testing.io, testing.allocator, h.paths, recovery_id, true);
    try testing.expectEqual(wallet.State.ready, inspected.state);
    try inspected.close();
    const phrase = try wallet.readMnemonic(testing.io, testing.allocator, paths);
    defer testing.allocator.free(phrase);
    try testing.expectEqualStrings(recovery_phrase, phrase);
    _ = try wallet.recoveryCanAbandon(testing.io, testing.allocator, h.paths, recovery_id);
    try testing.expectEqual(wallet.Durability.durable, try wallet.commitRecovery(testing.io, testing.allocator, h.paths, recovery_id));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(testing.io, paths.dir, .{ .follow_symlinks = false }));
    const final_phrase = try wallet.readMnemonic(testing.io, testing.allocator, h.paths);
    defer testing.allocator.free(final_phrase);
    try testing.expectEqualStrings(recovery_phrase, final_phrase);
    const receipt_path = try std.fs.path.join(testing.allocator, &.{ h.paths.dir, "recovery-owner" });
    defer testing.allocator.free(receipt_path);
    var receipt = try Io.Dir.cwd().openFile(testing.io, receipt_path, .{ .follow_symlinks = false });
    defer receipt.close(testing.io);
    var buf: [33]u8 = undefined;
    var reader = receipt.reader(testing.io, &.{});
    const n = try reader.interface.readSliceShort(&buf);
    try testing.expectEqualStrings(&recovery_id, buf[0..n]);
    try testing.expectError(error.AlreadyInitialized, wallet.prepareRecovery(testing.io, testing.allocator, h.paths, recovery_phrase, recovery_id));
}

test "invalid recovery leaves no stage and retained stage does not block create" {
    var h = try Harness.init();
    defer h.deinit();
    const paths = try wallet.recoveryPaths(testing.allocator, h.paths);
    defer {
        paths.deinit(testing.allocator);
        testing.allocator.free(paths.dir);
    }
    try testing.expectError(error.InvalidMnemonic, wallet.prepareRecovery(testing.io, testing.allocator, h.paths, "invalid phrase", recovery_id));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(testing.io, paths.dir, .{ .follow_symlinks = false }));
    try wallet.prepareRecovery(testing.io, testing.allocator, h.paths, recovery_phrase, recovery_id);
    const created = try wallet.create(testing.io, testing.allocator, h.paths);
    defer created.deinit(testing.allocator);
    try testing.expectError(error.AlreadyInitialized, wallet.commitRecovery(testing.io, testing.allocator, h.paths, recovery_id));
    var inspected = try wallet.inspectRecovery(testing.io, testing.allocator, h.paths, recovery_id, true);
    try inspected.close();
}

test "recovery rejects invalid ids and incomplete stages" {
    var h = try Harness.init();
    defer h.deinit();
    const invalid_id = "0123456789abcdef0123456789abcdeF".*;
    try testing.expectError(error.InvalidRecoveryId, wallet.prepareRecovery(testing.io, testing.allocator, h.paths, recovery_phrase, invalid_id));
    try testing.expectError(error.RecoveryStageUnavailable, wallet.inspectRecovery(testing.io, testing.allocator, h.paths, recovery_id, false));
    try sf.ensureOwnedDir(testing.io, h.dataRoot());
    const paths = try wallet.recoveryPaths(testing.allocator, h.paths);
    defer {
        paths.deinit(testing.allocator);
        testing.allocator.free(paths.dir);
    }
    try Io.Dir.createDirAbsolute(testing.io, paths.dir, sf.mode_dir);
    try testing.expectError(error.RecoveryStageUnavailable, wallet.inspectRecovery(testing.io, testing.allocator, h.paths, recovery_id, false));
    try testing.expectError(error.PathAlreadyExists, wallet.prepareRecovery(testing.io, testing.allocator, h.paths, recovery_phrase, recovery_id));
}

test "recovery commit retains wallet on parent sync failure" {
    var h = try Harness.init();
    defer h.deinit();
    try wallet.prepareRecovery(testing.io, testing.allocator, h.paths, recovery_phrase, recovery_id);
    wallet.testFailCommitSync = true;
    defer wallet.testFailCommitSync = false;
    try testing.expectEqual(wallet.Durability.unknown, try wallet.commitRecovery(testing.io, testing.allocator, h.paths, recovery_id));
    var inspection = try wallet.inspect(testing.io, testing.allocator, h.paths, true);
    try testing.expectEqual(wallet.State.ready, inspection.state);
    try inspection.close();
}

const Harness = struct {
    tmp: std.testing.TmpDir,
    base: [:0]u8,
    dir: []u8,
    paths: wallet.Paths,

    fn init() !Harness {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(base);

        const dir = try std.fs.path.join(testing.allocator, &.{ base, "haystack", "wallet" });
        errdefer testing.allocator.free(dir);

        const paths = try wallet.Paths.init(testing.allocator, dir);
        errdefer {
            paths.deinit(testing.allocator);
            testing.allocator.free(dir);
        }

        return .{ .tmp = tmp, .base = base, .dir = dir, .paths = paths };
    }

    fn deinit(self: *Harness) void {
        self.paths.deinit(testing.allocator);
        testing.allocator.free(self.dir);
        testing.allocator.free(self.base);
        self.tmp.cleanup();
    }

    fn dataRoot(self: Harness) []const u8 {
        return std.fs.path.dirname(self.dir).?;
    }
};

fn mode(io: Io, path: []const u8) !u32 {
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    return sf.modeOf(stat);
}

fn writeManagedFile(io: Io, path: []const u8, data: []const u8, permissions: std.posix.mode_t) !void {
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .permissions = Io.File.Permissions.fromMode(permissions) },
    });
}

fn countStagingEntries(io: Io, data_root: []const u8) !usize {
    var dir = Io.Dir.openDirAbsolute(io, data_root, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);

    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".wallet-staging-")) count += 1;
    }
    return count;
}

fn expectNoStaging(io: Io, data_root: []const u8) !void {
    try testing.expectEqual(@as(usize, 0), try countStagingEntries(io, data_root));
}

test "absent pair is not initialized and inspect never creates" {
    var h = try Harness.init();
    defer h.deinit();

    const closed = try wallet.inspect(testing.io, testing.allocator, h.paths, false);
    try testing.expectEqual(wallet.State.not_initialized, closed.state);
    try testing.expect(closed.wallet == null);

    // Requesting an open handle must still not create anything.
    const opened = try wallet.inspect(testing.io, testing.allocator, h.paths, true);
    try testing.expectEqual(wallet.State.not_initialized, opened.state);
    try testing.expect(opened.wallet == null);

    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(testing.io, h.paths.dir, .{ .follow_symlinks = false }),
    );
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(testing.io, h.paths.seed_path, .{ .follow_symlinks = false }),
    );
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(testing.io, h.paths.db_path, .{ .follow_symlinks = false }),
    );
}

test "explicit create provisions a private pair and inspect reuses it" {
    var h = try Harness.init();
    defer h.deinit();

    var created = try wallet.create(testing.io, testing.allocator, h.paths);
    defer created.deinit(testing.allocator);
    try testing.expectEqual(wallet.Durability.durable, created.durability);

    // The returned backup material is a real 12-word English phrase.
    var words = std.mem.tokenizeScalar(u8, created.mnemonic, ' ');
    var word_count: usize = 0;
    while (words.next()) |_| word_count += 1;
    try testing.expectEqual(@as(usize, 12), word_count);

    try testing.expectEqual(@as(u32, 0o700), try mode(testing.io, h.paths.dir));
    try testing.expectEqual(@as(u32, 0o600), try mode(testing.io, h.paths.seed_path));
    try testing.expectEqual(@as(u32, 0o600), try mode(testing.io, h.paths.db_path));
    try expectNoStaging(testing.io, h.dataRoot());

    // The pair validates, and opening reuses the existing database.
    const inspected = try wallet.inspect(testing.io, testing.allocator, h.paths, false);
    try testing.expectEqual(wallet.State.ready, inspected.state);
    try testing.expect(inspected.wallet == null);

    var first = try wallet.inspect(testing.io, testing.allocator, h.paths, true);
    defer first.close() catch {};
    try testing.expectEqual(wallet.State.ready, first.state);
    try testing.expect(first.wallet != null);
    try first.close();

    var second = try wallet.inspect(testing.io, testing.allocator, h.paths, true);
    defer second.close() catch {};
    try testing.expectEqual(wallet.State.ready, second.state);
    try testing.expect(second.wallet != null);
}

test "post-commit sync failure retains the pair and reports unknown durability" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var h = try Harness.init();
    defer h.deinit();

    wallet.testFailCommitSync = true;
    defer wallet.testFailCommitSync = false;

    var created = try wallet.create(testing.io, testing.allocator, h.paths);
    defer created.deinit(testing.allocator);

    // The commit succeeded even though the parent sync reported failure. The
    // pair is fully present, valid and openable; only durability is unknown.
    try testing.expectEqual(wallet.Durability.unknown, created.durability);
    try testing.expectEqual(@as(u32, 0o600), try mode(testing.io, h.paths.seed_path));
    try testing.expectEqual(@as(u32, 0o600), try mode(testing.io, h.paths.db_path));
    const inspected = try wallet.inspect(testing.io, testing.allocator, h.paths, false);
    try testing.expectEqual(wallet.State.ready, inspected.state);
    try expectNoStaging(testing.io, h.dataRoot());

    // A later explicit create must observe the retained wallet, not treat it as
    // an unprovisioned remnants.
    try testing.expectError(
        error.AlreadyInitialized,
        wallet.create(testing.io, testing.allocator, h.paths),
    );
}

test "a second explicit create never overwrites or cleans the existing wallet" {
    var h = try Harness.init();
    defer h.deinit();

    var created = try wallet.create(testing.io, testing.allocator, h.paths);
    defer created.deinit(testing.allocator);

    const before = try Io.Dir.cwd().readFileAlloc(testing.io, h.paths.seed_path, testing.allocator, .limited(2048));
    defer testing.allocator.free(before);

    try testing.expectError(
        error.AlreadyInitialized,
        wallet.create(testing.io, testing.allocator, h.paths),
    );

    const after = try Io.Dir.cwd().readFileAlloc(testing.io, h.paths.seed_path, testing.allocator, .limited(2048));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try expectNoStaging(testing.io, h.dataRoot());

    // A non-directory final entry is also never replaced.
    var other = try Harness.init();
    defer other.deinit();
    try sf.ensureOwnedDir(testing.io, other.dataRoot());
    try writeManagedFile(testing.io, other.paths.dir, "owned-by-the-user", 0o600);
    try testing.expectError(
        error.AlreadyInitialized,
        wallet.create(testing.io, testing.allocator, other.paths),
    );
    const untouched = try Io.Dir.cwd().readFileAlloc(testing.io, other.paths.dir, testing.allocator, .limited(64));
    defer testing.allocator.free(untouched);
    try testing.expectEqualStrings("owned-by-the-user", untouched);
    try expectNoStaging(testing.io, other.dataRoot());
}

test "one-sided pairs are incomplete and are left unchanged" {
    var missing_db = try Harness.init();
    defer missing_db.deinit();
    var created_db = try wallet.create(testing.io, testing.allocator, missing_db.paths);
    defer created_db.deinit(testing.allocator);

    try Io.Dir.cwd().deleteFile(testing.io, missing_db.paths.db_path);
    const no_db = try wallet.inspect(testing.io, testing.allocator, missing_db.paths, false);
    try testing.expectEqual(wallet.State.incomplete, no_db.state);
    try testing.expect(no_db.wallet == null);
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(testing.io, missing_db.paths.db_path, .{ .follow_symlinks = false }),
    );
    _ = try Io.Dir.cwd().statFile(testing.io, missing_db.paths.seed_path, .{ .follow_symlinks = false });

    var missing_seed = try Harness.init();
    defer missing_seed.deinit();
    var created_seed = try wallet.create(testing.io, testing.allocator, missing_seed.paths);
    defer created_seed.deinit(testing.allocator);

    try Io.Dir.cwd().deleteFile(testing.io, missing_seed.paths.seed_path);
    const no_seed = try wallet.inspect(testing.io, testing.allocator, missing_seed.paths, false);
    try testing.expectEqual(wallet.State.incomplete, no_seed.state);
    try testing.expect(no_seed.wallet == null);
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(testing.io, missing_seed.paths.seed_path, .{ .follow_symlinks = false }),
    );
    _ = try Io.Dir.cwd().statFile(testing.io, missing_seed.paths.db_path, .{ .follow_symlinks = false });
}

test "an empty database placeholder is rejected before the FFI is called" {
    var h = try Harness.init();
    defer h.deinit();
    var created = try wallet.create(testing.io, testing.allocator, h.paths);
    defer created.deinit(testing.allocator);

    try writeManagedFile(testing.io, h.paths.db_path, "", 0o600);

    try testing.expectError(
        error.InvalidDatabase,
        wallet.inspect(testing.io, testing.allocator, h.paths, false),
    );
    try testing.expectEqual(@as(u32, 0o600), try mode(testing.io, h.paths.db_path));
}

test "a wrong mnemonic is rejected by the FFI fingerprint check" {
    var first = try Harness.init();
    defer first.deinit();
    var first_created = try wallet.create(testing.io, testing.allocator, first.paths);
    defer first_created.deinit(testing.allocator);

    var second = try Harness.init();
    defer second.deinit();
    var second_created = try wallet.create(testing.io, testing.allocator, second.paths);
    defer second_created.deinit(testing.allocator);

    // Replace the first wallet's valid mnemonic with the second wallet's valid
    // phrase. Storage checks pass, but the database fingerprint must not.
    const replacement = try std.mem.concat(testing.allocator, u8, &.{ second_created.mnemonic, "\n" });
    defer {
        std.crypto.secureZero(u8, replacement);
        testing.allocator.free(replacement);
    }
    try writeManagedFile(testing.io, first.paths.seed_path, replacement, 0o600);

    const inspected = try wallet.inspect(testing.io, testing.allocator, first.paths, false);
    try testing.expectEqual(wallet.State.ready, inspected.state);

    try testing.expectError(
        error.CdkFailure,
        wallet.inspect(testing.io, testing.allocator, first.paths, true),
    );
}

test "broad managed modes and oversized mnemonics are rejected without chmod" {
    var seed_mode = try Harness.init();
    defer seed_mode.deinit();
    var seed_created = try wallet.create(testing.io, testing.allocator, seed_mode.paths);
    defer seed_created.deinit(testing.allocator);

    {
        var file = try Io.Dir.cwd().openFile(testing.io, seed_mode.paths.seed_path, .{ .follow_symlinks = false });
        defer file.close(testing.io);
        try file.setPermissions(testing.io, Io.File.Permissions.fromMode(0o644));
    }
    try testing.expectError(
        error.InsecurePermissions,
        wallet.inspect(testing.io, testing.allocator, seed_mode.paths, false),
    );
    try testing.expectEqual(@as(u32, 0o644), try mode(testing.io, seed_mode.paths.seed_path));

    var db_mode = try Harness.init();
    defer db_mode.deinit();
    var db_created = try wallet.create(testing.io, testing.allocator, db_mode.paths);
    defer db_created.deinit(testing.allocator);

    {
        var file = try Io.Dir.cwd().openFile(testing.io, db_mode.paths.db_path, .{ .follow_symlinks = false });
        defer file.close(testing.io);
        try file.setPermissions(testing.io, Io.File.Permissions.fromMode(0o640));
    }
    try testing.expectError(
        error.InsecurePermissions,
        wallet.inspect(testing.io, testing.allocator, db_mode.paths, false),
    );
    try testing.expectEqual(@as(u32, 0o640), try mode(testing.io, db_mode.paths.db_path));

    var oversized = try Harness.init();
    defer oversized.deinit();
    var oversized_created = try wallet.create(testing.io, testing.allocator, oversized.paths);
    defer oversized_created.deinit(testing.allocator);

    const huge: [wallet.max_mnemonic_bytes + 1]u8 = @splat('a');
    try writeManagedFile(testing.io, oversized.paths.seed_path, &huge, 0o600);
    try testing.expectError(
        error.InvalidMnemonic,
        wallet.inspect(testing.io, testing.allocator, oversized.paths, false),
    );
    try testing.expectEqual(@as(u32, 0o600), try mode(testing.io, oversized.paths.seed_path));
}

test "symlinked managed entries are rejected" {
    var seed_link = try Harness.init();
    defer seed_link.deinit();
    var seed_created = try wallet.create(testing.io, testing.allocator, seed_link.paths);
    defer seed_created.deinit(testing.allocator);

    // Move the real mnemonic outside the wallet and leave a symlink in its
    // managed place. Inspect must reject the symlink, never follow it.
    const outside = try std.fs.path.join(testing.allocator, &.{ seed_link.base, "outside-seed.txt" });
    defer testing.allocator.free(outside);
    try writeManagedFile(testing.io, outside, seed_created.mnemonic, 0o600);
    try Io.Dir.cwd().deleteFile(testing.io, seed_link.paths.seed_path);
    try seed_link.tmp.dir.symLink(testing.io, "../../outside-seed.txt", "haystack/wallet/seed-words.txt", .{});

    try testing.expectError(
        error.InsecureEntry,
        wallet.inspect(testing.io, testing.allocator, seed_link.paths, false),
    );
    _ = try Io.Dir.cwd().statFile(testing.io, outside, .{ .follow_symlinks = false });

    // A symlinked wallet directory is likewise not a managed pair.
    var dir_link = try Harness.init();
    defer dir_link.deinit();
    var dir_created = try wallet.create(testing.io, testing.allocator, dir_link.paths);
    defer dir_created.deinit(testing.allocator);

    const real_dir = try std.fs.path.join(testing.allocator, &.{ dir_link.dataRoot(), "wallet-real" });
    defer testing.allocator.free(real_dir);
    try Io.Dir.renameAbsolute(dir_link.paths.dir, real_dir, testing.io);
    try dir_link.tmp.dir.symLink(testing.io, "wallet-real", "haystack/wallet", .{});

    try testing.expectError(
        error.InsecureEntry,
        wallet.inspect(testing.io, testing.allocator, dir_link.paths, false),
    );
    // Explicit creation never replaces the symlinked final entry.
    try testing.expectError(
        error.AlreadyInitialized,
        wallet.create(testing.io, testing.allocator, dir_link.paths),
    );
    _ = try Io.Dir.cwd().statFile(testing.io, real_dir, .{ .follow_symlinks = false });
}
