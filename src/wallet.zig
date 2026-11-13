pub const cdk = @import("cdk");

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const sf = @import("storage_fs.zig");

/// Spilman functions share the CDK C ABI (`cdk_spilman_*`).
pub const spilman = cdk.c;

/// Check a CDK/Spilman result and consume its Rust-owned error string.
/// Pass a pointer so the error field can be cleared; the caller still owns any
/// payload (including lists and handles) and must use its matching free helper.
/// On failure, inspect result.status for the specific C ABI status code.
pub fn check(result: anytype) error{CdkFailure}!void {
    const status = result.status;
    cdk.c.cdk_string_free(result.@"error");
    result.@"error" = null;
    if (status != cdk.c.CDK_STATUS_OK) return error.CdkFailure;
}

pub const Wallet = struct {
    /// Do not copy: the handle has a single owner.
    wallet: *cdk.c.CdkWallet_t,
    closed: bool = false,

    /// Close consumes the handle even if the ABI reports an error.
    pub fn close(self: *Wallet) error{CdkFailure}!void {
        if (self.closed) return;
        self.closed = true;
        var result = cdk.c.cdk_wallet_close(self.wallet);
        try check(&result);
    }
};

/// Open or create a wallet at the given database path. Call close when finished.
pub fn createWallet(seed: []const u8, db_path: [:0]const u8) error{CdkFailure}!Wallet {
    var result = cdk.c.cdk_wallet_open(cdk.byteSlice(seed), db_path.ptr);
    defer cdk.c.cdk_recovery_reports_free(result.reports);
    try check(&result);
    return .{ .wallet = result.handle orelse return error.CdkFailure };
}

// ── fixed user wallet storage ───────────────────────────────────────────────

/// Names inside the single Haystack-owned wallet directory.
pub const seed_file_name = "seed-words.txt";
pub const db_file_name = "wallet.sqlite";

/// The CDK ABI itself bounds mnemonic input at 1024 bytes. Keep the on-disk
/// bound identical so a file can never be read partially and misparsed.
pub const max_mnemonic_bytes: usize = 1024;

/// Paths of the one fixed user wallet. Callers must not construct a mismatched
/// set: use `init` (which derives the entry names from `dir`).
pub const Paths = struct {
    /// The Haystack-owned `0700` wallet directory.
    dir: []const u8,
    seed_path: []const u8,
    db_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !Paths {
        if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) return error.InvalidPath;
        const seed_path = try std.fs.path.join(allocator, &.{ dir, seed_file_name });
        errdefer allocator.free(seed_path);
        return .{
            .dir = dir,
            .seed_path = seed_path,
            .db_path = try std.fs.path.join(allocator, &.{ dir, db_file_name }),
        };
    }

    /// Frees the two derived entry paths. `dir` remains owned by the caller.
    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.seed_path);
        allocator.free(self.db_path);
    }
};

/// Pair-level state of the fixed user wallet.
pub const State = enum {
    /// Neither managed entry exists; no wallet has been provisioned.
    not_initialized,
    /// Exactly one managed entry exists. The pair is left untouched.
    incomplete,
    /// Both managed entries exist and passed the storage policy checks.
    ready,
};

/// Result of `inspect`. `wallet` is non-null only when `open` was requested and
/// the pair was ready. The caller owns and must close the handle.
pub const Inspection = struct {
    state: State,
    wallet: ?Wallet = null,

    pub fn close(self: *Inspection) error{CdkFailure}!void {
        if (self.wallet) |*wallet| {
            defer self.wallet = null;
            try wallet.close();
        }
    }
};

/// Whether the committed pair is known to have reached durable storage.
pub const Durability = enum {
    /// The parent directory was flushed after the atomic commit.
    durable,
    /// The pair is committed and retained, but the after-commit directory sync
    /// failed. Callers must treat it as provisioned-but-maybe-not-durable, not
    /// as unprovisioned.
    unknown,
};

/// A newly provisioned wallet. The mnemonic is caller-owned plaintext secret
/// material for the eventual backup step; never log it.
pub const Created = struct {
    mnemonic: []u8,
    durability: Durability,

    pub fn deinit(self: Created, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.mnemonic);
        allocator.free(self.mnemonic);
    }
};

/// Test-only injection for the post-commit parent sync failure. Never read or
/// written outside tests; the committed pair must be retained either way.
pub var testFailCommitSync = false;

/// Inspect the managed pair without provisioning or repairing a missing pair.
///
/// With `open = false` this function neither creates nor mutates anything: the
/// pair is stat'd, checked against the storage policy, and the seed is read.
///
/// With `open = true` the existing CDK database is opened through the FFI after
/// the pair has been validated; opening validates the stored seed fingerprint
/// under the FFI database lock. Inspect itself still never provisions or
/// repairs a missing or incomplete pair, but opening an existing database runs
/// the FFI's normal startup path (CDK schema migrations and recovery), which
/// may mutate that database.
pub fn inspect(
    io: Io,
    allocator: std.mem.Allocator,
    paths: Paths,
    open: bool,
) !Inspection {
    if (!std.fs.path.isAbsolute(paths.dir)) return error.InvalidPath;

    const dir_stat = Io.Dir.cwd().statFile(io, paths.dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .state = .not_initialized },
        else => return err,
    };
    try sf.verifyDirectory(dir_stat);

    var dir = try Io.Dir.openDirAbsolute(io, paths.dir, .{ .follow_symlinks = false });
    defer dir.close(io);
    // Manager-owned mode bits do not rule out an inherited extended ACL; probe
    // the opened directory itself so no path is followed.
    try sf.verifyNoExtendedAclDir(dir);

    const seed_stat = try statEntry(io, dir, seed_file_name);
    const db_stat = try statEntry(io, dir, db_file_name);

    if (seed_stat == null and db_stat == null) {
        return .{ .state = .not_initialized };
    }
    if (seed_stat == null or db_stat == null) {
        return .{ .state = .incomplete };
    }

    try sf.verifyFile(seed_stat.?);
    try sf.verifyFile(db_stat.?);
    // The FFI rejects an empty pre-existing database. Report it before deriving
    // the seed so a placeholder pair never reaches the wallet library.
    if (db_stat.?.size == 0) return error.InvalidDatabase;

    var seed = try readSeed(io, allocator, dir, seed_stat.?);
    defer std.crypto.secureZero(u8, &seed);

    if (!open) return .{ .state = .ready };

    // Derive the database path from the verified directory rather than trusting
    // a caller-supplied field, so validation and the FFI open always refer to
    // the same managed entry.
    const db_path = try std.fs.path.join(allocator, &.{ paths.dir, db_file_name });
    defer allocator.free(db_path);

    const db_path_z = try allocator.dupeSentinel(u8, db_path, 0);
    defer allocator.free(db_path_z);

    return .{
        .state = .ready,
        .wallet = try createWallet(&seed, db_path_z),
    };
}

/// Explicitly provision the fixed user wallet.
///
/// The pair is built in a random, private `0700` staging directory next to the
/// final `wallet` directory. The FFI initializes the database there and closes
/// it before the whole directory is committed with one atomic no-replace
/// rename. The staging directory is flushed before the commit. A failed
/// post-commit sync never rolls the pair back: the result reports
/// [`Durability.unknown`] so the caller knows the wallet exists but may not
/// survive a crash. An existing final wallet is never overwritten or cleaned.
/// Failed pre-commit work removes only the exact staging directory owned by
/// this call.
///
/// Startup provisioning must first durably record pending onboarding and must
/// treat unknown durability as blocked without retrying creation in that run.
pub fn create(
    io: Io,
    allocator: std.mem.Allocator,
    paths: Paths,
) !Created {
    if (!std.fs.path.isAbsolute(paths.dir)) return error.InvalidPath;
    const data_root = std.fs.path.dirname(paths.dir) orelse return error.InvalidPath;
    const final_name = try sf.basename(paths.dir);

    // The data root is Haystack-owned. Create it when missing, but reject a
    // symlink, broad mode, or non-directory instead of repairing it.
    try sf.ensureOwnedDir(io, data_root);

    var parent = try Io.Dir.openDirAbsolute(io, data_root, .{ .follow_symlinks = false });
    defer parent.close(io);
    try sf.verifyNoExtendedAclDir(parent);

    // Never overwrite any existing entry at the final name, including a
    // symlink or a file. The no-replace commit below closes the remaining race.
    if (try statEntry(io, parent, final_name) != null) {
        return error.AlreadyInitialized;
    }

    var generated = cdk.c.cdk_generate_mnemonic();
    defer cdk.c.cdk_string_free(generated.value);
    try check(&generated);
    const phrase_ptr = generated.value orelse return error.CdkFailure;
    const phrase = std.mem.span(@as([*:0]const u8, @ptrCast(phrase_ptr)));
    if (phrase.len == 0 or phrase.len > max_mnemonic_bytes) return error.InvalidMnemonic;

    var seed = try seedFromMnemonic(phrase_ptr);
    defer std.crypto.secureZero(u8, &seed);

    var staging_name_buf: [staging_name_len]u8 = undefined;
    const staging_name = try createStagingDir(io, parent, &staging_name_buf);
    var staging_owned = true;
    errdefer if (staging_owned) parent.deleteTree(io, staging_name) catch {};

    var staging = try parent.openDir(io, staging_name, .{ .follow_symlinks = false });
    defer staging.close(io);
    try sf.verifyDirectory(try parent.statFile(io, staging_name, .{ .follow_symlinks = false }));
    try sf.verifyNoExtendedAclDir(staging);

    try writeSeedFile(io, staging, phrase);

    // The FFI creates and marks the database. No empty placeholder is ever
    // written by Haystack. Close it before committing so the staged pair is
    // complete and unlocked.
    const staging_db = try std.fs.path.join(allocator, &.{ data_root, staging_name, db_file_name });
    defer allocator.free(staging_db);
    const staging_db_z = try allocator.dupeSentinel(u8, staging_db, 0);
    defer allocator.free(staging_db_z);
    var staged_wallet = try createWallet(&seed, staging_db_z);
    try staged_wallet.close();

    try validateStagedPair(io, allocator, staging, &seed);

    // The staged directory entries (mnemonic and closed SQLite database) must
    // reach disk before the directory itself is committed.
    try sf.syncDirectory(staging);

    // Copy the phrase before the commit: after a successful rename the pair is
    // retained and the caller must still receive the backup material.
    const mnemonic = try allocator.dupe(u8, phrase);
    errdefer {
        std.crypto.secureZero(u8, mnemonic);
        allocator.free(mnemonic);
    }

    // Atomic no-replace commit of the whole directory. If another process won
    // the race, this fails and only this call's staging directory is removed.
    try Io.Dir.renamePreserve(parent, staging_name, parent, final_name, io);
    staging_owned = false;

    // The pair is committed now. A failed parent sync is reported as
    // durability-unknown and never rolls the committed pair back.
    const durability: Durability = blk: {
        if (builtin.is_test and testFailCommitSync) break :blk .unknown;
        sf.syncDirectory(parent) catch break :blk .unknown;
        break :blk .durable;
    };

    return .{ .mnemonic = mnemonic, .durability = durability };
}

const recovery_dir_name = ".wallet-recovery";
const recovery_receipt_name = "recovery-owner";

/// The returned directory is separately allocated: call Paths.deinit and then
/// free its dir with the same allocator.
pub fn recoveryPaths(allocator: std.mem.Allocator, final_paths: Paths) !Paths {
    if (!std.fs.path.isAbsolute(final_paths.dir)) return error.InvalidPath;
    const parent = std.fs.path.dirname(final_paths.dir) orelse return error.InvalidPath;
    const dir = try std.fs.path.join(allocator, &.{ parent, recovery_dir_name });
    errdefer allocator.free(dir);
    return Paths.init(allocator, dir);
}

fn validateRecoveryId(id: [32]u8) !void {
    for (id) |c| {
        if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return error.InvalidRecoveryId;
    }
}

pub fn validateRecoveryPhrase(phrase: []const u8) !void {
    if (phrase.len == 0 or phrase.len > max_mnemonic_bytes or std.mem.indexOfScalar(u8, phrase, 0) != null) return error.InvalidMnemonic;
    var buf: [max_mnemonic_bytes + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    @memcpy(buf[0..phrase.len], phrase);
    buf[phrase.len] = 0;
    var seed = seedFromMnemonic(@ptrCast(&buf)) catch return error.InvalidMnemonic;
    std.crypto.secureZero(u8, &seed);
}

pub fn prepareRecovery(io: Io, allocator: std.mem.Allocator, final_paths: Paths, phrase: []const u8, id: [32]u8) !void {
    try validateRecoveryId(id);
    if (phrase.len == 0 or phrase.len > max_mnemonic_bytes or std.mem.indexOfScalar(u8, phrase, 0) != null) return error.InvalidMnemonic;
    const phrase_z = try allocator.dupeSentinel(u8, phrase, 0);
    defer {
        std.crypto.secureZero(u8, phrase_z);
        allocator.free(phrase_z);
    }
    var seed = seedFromMnemonic(phrase_z.ptr) catch return error.InvalidMnemonic;
    defer std.crypto.secureZero(u8, &seed);

    const paths = try recoveryPaths(allocator, final_paths);
    defer {
        paths.deinit(allocator);
        allocator.free(paths.dir);
    }
    const root = std.fs.path.dirname(final_paths.dir) orelse return error.InvalidPath;
    const final_name = try sf.basename(final_paths.dir);
    // Check without following the final entry, including before creating root.
    if (Io.Dir.cwd().statFile(io, final_paths.dir, .{ .follow_symlinks = false })) |_| {
        return error.AlreadyInitialized;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try sf.ensureOwnedDir(io, root);
    var parent = try Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer parent.close(io);
    try sf.verifyNoExtendedAclDir(parent);
    if (try statEntry(io, parent, final_name) != null) return error.AlreadyInitialized;
    try parent.createDir(io, recovery_dir_name, sf.mode_dir);
    // Never remove the stage after creation, even on failure.
    try sf.verifyDirectory(try parent.statFile(io, recovery_dir_name, .{ .follow_symlinks = false }));
    var stage = try parent.openDir(io, recovery_dir_name, .{ .follow_symlinks = false });
    defer stage.close(io);
    try sf.verifyNoExtendedAclDir(stage);
    const db_z = try allocator.dupeSentinel(u8, paths.db_path, 0);
    defer allocator.free(db_z);
    var staged_wallet = try createWallet(&seed, db_z);
    try staged_wallet.close();
    try writeSeedFile(io, stage, phrase);
    const receipt = try stage.createFile(io, recovery_receipt_name, .{ .exclusive = true, .permissions = sf.mode_file });
    defer receipt.close(io);
    try sf.verifyFile(try receipt.stat(io));
    try sf.verifyNoExtendedAcl(receipt);
    try receipt.writeStreamingAll(io, &id);
    try receipt.sync(io);
    try validateStagedPair(io, allocator, stage, &seed);
    try sf.syncDirectory(stage);
    try sf.syncDirectory(parent);
}

pub fn inspectRecovery(io: Io, allocator: std.mem.Allocator, final_paths: Paths, id: [32]u8, open: bool) !Inspection {
    const paths = try recoveryPaths(allocator, final_paths);
    defer {
        paths.deinit(allocator);
        allocator.free(paths.dir);
    }
    return inspectOwnedRecovery(io, allocator, paths, id, open);
}

pub fn inspectCommittedRecovery(io: Io, allocator: std.mem.Allocator, final_paths: Paths, id: [32]u8, open: bool) !Inspection {
    return inspectOwnedRecovery(io, allocator, final_paths, id, open);
}

pub fn retiredRecoveryPaths(allocator: std.mem.Allocator, final_paths: Paths, id: [32]u8) !Paths {
    try validateRecoveryId(id);
    const root = std.fs.path.dirname(final_paths.dir) orelse return error.InvalidPath;
    const basename = try std.fmt.allocPrint(allocator, ".wallet-recovery-retired-{s}", .{id});
    defer allocator.free(basename);
    const dir = try std.fs.path.join(allocator, &.{ root, basename });
    errdefer allocator.free(dir);
    return Paths.init(allocator, dir);
}

pub fn inspectRetiredRecovery(io: Io, allocator: std.mem.Allocator, final_paths: Paths, id: [32]u8, open: bool) !Inspection {
    const paths = try retiredRecoveryPaths(allocator, final_paths, id);
    defer {
        paths.deinit(allocator);
        allocator.free(paths.dir);
    }
    return inspectOwnedRecovery(io, allocator, paths, id, open);
}

fn inspectOwnedRecovery(io: Io, allocator: std.mem.Allocator, paths: Paths, id: [32]u8, open: bool) !Inspection {
    try validateRecoveryId(id);
    const root = std.fs.path.dirname(paths.dir) orelse return error.InvalidPath;
    sf.verifyOwnedDir(io, root) catch |err| switch (err) {
        error.FileNotFound => return error.RecoveryStageUnavailable,
        else => return err,
    };
    var parent = try Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer parent.close(io);
    const basename = try sf.basename(paths.dir);
    const stat = (try statEntry(io, parent, basename)) orelse return error.RecoveryStageUnavailable;
    try sf.verifyDirectory(stat);
    var stage = try parent.openDir(io, basename, .{ .follow_symlinks = false });
    defer stage.close(io);
    try sf.verifyNoExtendedAclDir(stage);
    const receipt_stat = (try statEntry(io, stage, recovery_receipt_name)) orelse return error.RecoveryStageUnavailable;
    try sf.verifyFile(receipt_stat);
    var receipt = stage.openFile(io, recovery_receipt_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.RecoveryStageUnavailable,
        else => return err,
    };
    defer receipt.close(io);
    const opened = try receipt.stat(io);
    try sf.verifyFile(opened);
    try sf.verifyNoExtendedAcl(receipt);
    if (opened.size != id.len) return error.RecoveryStageUnavailable;
    var buf: [33]u8 = undefined;
    var reader = receipt.reader(io, &.{});
    const n = try reader.interface.readSliceShort(&buf);
    if (n != id.len) return error.RecoveryStageUnavailable;
    if (!std.mem.eql(u8, buf[0..n], &id)) return error.RecoveryOwnershipMismatch;
    const inspection = try inspect(io, allocator, paths, open);
    if (inspection.state != .ready) return error.RecoveryStageUnavailable;
    return inspection;
}

pub fn retireRecovery(io: Io, allocator: std.mem.Allocator, final_paths: Paths, id: [32]u8) !Durability {
    var inspection = try inspectRecovery(io, allocator, final_paths, id, true);
    try inspection.close();
    const paths = try retiredRecoveryPaths(allocator, final_paths, id);
    defer {
        paths.deinit(allocator);
        allocator.free(paths.dir);
    }
    var parent = try sf.openParent(io, final_paths.dir);
    defer parent.close(io);
    try sf.verifyNoExtendedAclDir(parent);
    const basename = try sf.basename(paths.dir);
    if (try statEntry(io, parent, basename) != null) return error.AlreadyInitialized;
    try Io.Dir.renamePreserve(parent, recovery_dir_name, parent, basename, io);
    if (builtin.is_test and testFailCommitSync) return .unknown;
    sf.syncDirectory(parent) catch return .unknown;
    return .durable;
}

pub fn commitRecovery(io: Io, allocator: std.mem.Allocator, final_paths: Paths, id: [32]u8) !Durability {
    var inspection = try inspectRecovery(io, allocator, final_paths, id, true);
    try inspection.close();
    const root = std.fs.path.dirname(final_paths.dir) orelse return error.InvalidPath;
    var parent = try Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer parent.close(io);
    try sf.verifyNoExtendedAclDir(parent);
    const final_name = try sf.basename(final_paths.dir);
    if (try statEntry(io, parent, final_name) != null) return error.AlreadyInitialized;
    try Io.Dir.renamePreserve(parent, recovery_dir_name, parent, final_name, io);
    if (builtin.is_test and testFailCommitSync) return .unknown;
    sf.syncDirectory(parent) catch return .unknown;
    return .durable;
}

/// Advisory only; this neither proves ownership beyond the receipt nor deletes.
pub fn recoveryCanAbandon(io: Io, allocator: std.mem.Allocator, final_paths: Paths, id: [32]u8) !bool {
    var inspection = try inspectRecovery(io, allocator, final_paths, id, true);
    const handle = if (inspection.wallet) |w| w.wallet else return error.RecoveryStageUnavailable;
    const result = cdk.c.cdk_wallet_restore_can_abandon(handle);
    cdk.c.cdk_string_free(result.@"error");
    const safe = result.status == cdk.c.CDK_STATUS_OK and result.safe_to_abandon == 1;
    try inspection.close();
    return safe;
}

fn statEntry(io: Io, dir: Io.Dir, name: []const u8) !?Io.File.Stat {
    return dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn seedFromMnemonic(phrase: [*c]const u8) error{CdkFailure}![cdk.seed_len]u8 {
    var result = cdk.c.cdk_mnemonic_to_seed(phrase);
    defer cdk.c.cdk_bytes_free(result.bytes);
    try check(&result);
    if (result.bytes.len != cdk.seed_len) return error.CdkFailure;

    var seed: [cdk.seed_len]u8 = undefined;
    @memcpy(&seed, result.bytes.ptr[0..cdk.seed_len]);
    return seed;
}

/// Re-read the original validated phrase. Caller must scrub and free it.
/// Call only after a successful open-and-close inspection of the pair.
pub fn readMnemonic(io: Io, allocator: std.mem.Allocator, paths: Paths) ![]u8 {
    try sf.verifyOwnedDir(io, paths.dir);
    var dir = try Io.Dir.openDirAbsolute(io, paths.dir, .{ .follow_symlinks = false });
    defer dir.close(io);
    try sf.verifyNoExtendedAclDir(dir);
    const stat = try dir.statFile(io, seed_file_name, .{ .follow_symlinks = false });
    try sf.verifyFile(stat);
    var file = try dir.openFile(io, seed_file_name, .{ .follow_symlinks = false });
    defer file.close(io);
    const opened = try file.stat(io);
    try sf.verifyFile(opened);
    try sf.verifyNoExtendedAcl(file);
    if (opened.size == 0 or opened.size > max_mnemonic_bytes) return error.InvalidMnemonic;
    var buffer: [max_mnemonic_bytes + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var reader = file.reader(io, &.{});
    const n = try reader.interface.readSliceShort(&buffer);
    if (n == buffer.len) return error.MnemonicTooLong;
    const phrase = std.mem.trim(u8, buffer[0..n], " \t\r\n");
    if (phrase.len == 0) return error.InvalidMnemonic;
    const z = try allocator.dupeSentinel(u8, phrase, 0);
    defer {
        std.crypto.secureZero(u8, z);
        allocator.free(z);
    }
    var seed = try seedFromMnemonic(z.ptr);
    defer std.crypto.secureZero(u8, &seed);
    return allocator.dupe(u8, phrase);
}

/// Read the bounded plaintext mnemonic and derive its seed through the CDK ABI.
/// Temporary plaintext buffers are scrubbed before they are freed.
fn readSeed(
    io: Io,
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    stat: Io.File.Stat,
) ![cdk.seed_len]u8 {
    if (stat.size == 0 or stat.size > max_mnemonic_bytes) return error.InvalidMnemonic;

    var file = try dir.openFile(io, seed_file_name, .{ .follow_symlinks = false });
    defer file.close(io);

    const opened = try file.stat(io);
    try sf.verifyFile(opened);
    // The mnemonic descriptor itself must not carry an extended ACL, even when
    // the mode bits are already exactly 0600.
    try sf.verifyNoExtendedAcl(file);
    if (opened.size == 0 or opened.size > max_mnemonic_bytes) return error.InvalidMnemonic;

    var buffer: [max_mnemonic_bytes + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);

    var reader = file.reader(io, &.{});
    const read = try reader.interface.readSliceShort(&buffer);
    if (read == buffer.len) return error.MnemonicTooLong;

    const phrase = std.mem.trim(u8, buffer[0..read], " \t\r\n");
    if (phrase.len == 0 or phrase.len > max_mnemonic_bytes) return error.InvalidMnemonic;

    const phrase_z = try allocator.dupeSentinel(u8, phrase, 0);
    defer {
        std.crypto.secureZero(u8, phrase_z);
        allocator.free(phrase_z);
    }
    return seedFromMnemonic(phrase_z.ptr);
}

fn writeSeedFile(io: Io, dir: Io.Dir, phrase: []const u8) !void {
    const file = try dir.createFile(io, seed_file_name, .{
        .exclusive = true,
        .permissions = sf.mode_file,
    });
    defer file.close(io);

    // A hostile umask must not leave an accepted-looking managed file.
    try sf.verifyFile(try file.stat(io));
    // Neither may an inherited extended ACL: reject it instead of chmodding.
    try sf.verifyNoExtendedAcl(file);
    try file.writeStreamingAll(io, phrase);
    try file.writeStreamingAll(io, "\n");
    try file.sync(io);
}

fn validateStagedPair(
    io: Io,
    allocator: std.mem.Allocator,
    staging: Io.Dir,
    expected_seed: []const u8,
) !void {
    const seed_stat = try staging.statFile(io, seed_file_name, .{ .follow_symlinks = false });
    try sf.verifyFile(seed_stat);
    const db_stat = try staging.statFile(io, db_file_name, .{ .follow_symlinks = false });
    try sf.verifyFile(db_stat);
    if (db_stat.size == 0) return error.InvalidDatabase;

    var seed = try readSeed(io, allocator, staging, seed_stat);
    defer std.crypto.secureZero(u8, &seed);
    if (!std.mem.eql(u8, &seed, expected_seed)) return error.SeedMismatch;
}

const staging_prefix = ".wallet-staging-";
const staging_name_len = staging_prefix.len + 32;

fn createStagingDir(
    io: Io,
    parent: Io.Dir,
    buffer: *[staging_name_len]u8,
) ![]const u8 {
    // A 128-bit random name makes an existing staging entry an unexpected
    // collision, not a reusable directory. Retry a few times without ever
    // adopting an existing entry.
    var attempt: u8 = 0;
    while (attempt < 4) : (attempt += 1) {
        var random: [16]u8 = undefined;
        io.random(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        @memcpy(buffer[0..staging_prefix.len], staging_prefix);
        @memcpy(buffer[staging_prefix.len..], &hex);

        parent.createDir(io, buffer, sf.mode_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return buffer;
    }
    return error.PathAlreadyExists;
}
