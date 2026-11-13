//! Small shared filesystem policy helpers for Haystack-owned desktop storage.
//!
//! The policy is intentionally narrow rather than a general filesystem layer:
//! * Haystack-owned directories must already be exactly `0700`.
//! * Haystack-owned files must already be exactly `0600`.
//! * macOS extended ACLs on managed mnemonics and directories are rejected on
//!   the open descriptor, never repaired by chmod.
//! * Symlinks are never followed for managed entries.
//! * Existing entries with broader permissions are rejected, never repaired.
//! * Writes use a temporary file in the destination directory and an atomic
//!   rename, so readers never observe a partially written managed file. The
//!   directory is synced after the rename; a failed sync is reported.
//!
//! `ensureOwnedDir` creates only the Haystack-owned directory at the final path
//! component; it never creates or chmods standard parents such as `~/.config`.
//! `ensureStandardParents` creates missing standard parents with owner-only
//! permissions, but never modifies an existing entry.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const mode_dir = Io.File.Permissions.fromMode(0o700);
pub const mode_file = Io.File.Permissions.fromMode(0o600);
/// Standard user directories that Haystack may need to create when a clean
/// HOME lacks them (for example `~/.config` or `~/.local/share`). They are not
/// Haystack-owned, so an existing directory is never chmodded or rewritten.
pub const mode_standard_parent = Io.File.Permissions.fromMode(0o700);

pub const Error = error{
    InsecureEntry,
    InsecurePermissions,
    InsecureAcl,
    AclInspectionFailed,
    InvalidPath,
};

/// Owner-only mode bits do not describe macOS extended ACLs: a `0600` file can
/// still carry a principal-specific allow ACL. Probe the already-open
/// descriptor so no path is followed, exactly like the Rust FFI does. Linux has
/// no equivalent check for these entries and compiles the probe to a no-op.
///
/// A NULL `acl_get_fd_np` result with `ENOENT` is the only proof that no
/// extended ACL exists. NULL with errno 0 (or any other errno) is an
/// uninspectable outcome and fails closed; it is never treated as clean.
const acl = if (builtin.os.tag == .macos) struct {
    const ACL_TYPE_EXTENDED: c_int = 0x0000_0100;

    extern "c" fn acl_get_fd_np(fd: c_int, acl_type: c_int) ?*anyopaque;
    extern "c" fn acl_free(obj: ?*anyopaque) c_int;

    fn verifyFd(fd: std.posix.fd_t) Error!void {
        std.posix.system._errno().* = 0;
        const handle = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
        if (handle) |acl_handle| {
            _ = acl_free(acl_handle);
            return error.InsecureAcl;
        }
        if (std.posix.system._errno().* == @backingInt(std.posix.system.E.NOENT)) return;
        return error.AclInspectionFailed;
    }
} else struct {
    fn verifyFd(_: std.posix.fd_t) Error!void {}
};

pub fn verifyNoExtendedAcl(file: Io.File) Error!void {
    return acl.verifyFd(file.handle);
}

pub fn verifyNoExtendedAclDir(dir: Io.Dir) Error!void {
    return acl.verifyFd(dir.handle);
}

pub fn verifyNoExtendedAclFd(fd: std.posix.fd_t) Error!void {
    return acl.verifyFd(fd);
}

pub fn modeOf(stat: Io.File.Stat) u32 {
    return @intCast(stat.permissions.toMode() & 0o777);
}

pub fn verifyDirectory(stat: Io.File.Stat) Error!void {
    if (stat.kind != .directory) return error.InsecureEntry;
    if (modeOf(stat) != 0o700) return error.InsecurePermissions;
}

pub fn verifyFile(stat: Io.File.Stat) Error!void {
    if (stat.kind != .file) return error.InsecureEntry;
    if (modeOf(stat) != 0o600) return error.InsecurePermissions;
}

/// Ensure `path` exists as a Haystack-owned `0700` directory without changing
/// the mode of an existing directory or creating any of its parents.
pub fn ensureOwnedDir(io: Io, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const stat = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            try Io.Dir.createDirAbsolute(io, path, mode_dir);
            const created = try cwd.statFile(io, path, .{ .follow_symlinks = false });
            try verifyDirectory(created);
            return verifyDirectoryAcl(io, path);
        },
        else => return err,
    };
    try verifyDirectory(stat);
    try verifyDirectoryAcl(io, path);
}

/// Verify that `path` exists as a real Haystack-owned `0700` directory without
/// creating or modifying anything. Missing paths return `error.FileNotFound`.
pub fn verifyOwnedDir(io: Io, path: []const u8) !void {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    try verifyDirectory(stat);
    try verifyDirectoryAcl(io, path);
}

fn verifyDirectoryAcl(io: Io, path: []const u8) !void {
    var dir = try Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false });
    defer dir.close(io);
    try verifyNoExtendedAclDir(dir);
}

/// Create any missing standard parent directories in order.
///
/// Standard parents (`~/.config`, `~/.local`, `~/.local/share`,
/// `~/Library/Application Support`, ...) are not Haystack-owned. Existing
/// entries are only checked to be directories and are never chmodded or
/// rewritten. Missing entries are created with owner-only `0700`; explicit XDG
/// base directories supplied by the user are not in this list and must already
/// exist.
pub fn ensureStandardParents(io: Io, parents: []const []const u8) !void {
    const cwd = Io.Dir.cwd();
    for (parents) |path| {
        _ = try cwd.createDirPathStatus(io, path, mode_standard_parent);
        const stat = try cwd.statFile(io, path, .{ .follow_symlinks = true });
        if (stat.kind != .directory) return error.InsecureEntry;
    }
}

/// Open the parent directory of an absolute managed path.
pub fn openParent(io: Io, path: []const u8) !Io.Dir {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    return Io.Dir.openDirAbsolute(io, parent, .{});
}

pub fn basename(path: []const u8) ![]const u8 {
    const name = std.fs.path.basename(path);
    if (name.len == 0) return error.InvalidPath;
    return name;
}

/// Flush a directory after creating or renaming entries in it. A failed sync is
/// reported, never treated as durable just because the rename returned.
pub fn syncDirectory(dir: Io.Dir) error{SyncFailed}!void {
    if (std.c.fsync(dir.handle) != 0) return error.SyncFailed;
}

/// Atomically replace `dir/name` with `data`, creating the temporary file with
/// `0600` permissions. The caller is responsible for validating any existing
/// destination before calling this.
pub fn writeAtomicIn(dir: Io.Dir, io: Io, name: []const u8, data: []const u8) !void {
    var random: [16]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);

    var temp_name_buf: [5 + hex.len]u8 = undefined;
    @memcpy(temp_name_buf[0..5], ".tmp-");
    @memcpy(temp_name_buf[5..], &hex);
    const temp_name = temp_name_buf[0..];

    var temp_created = false;
    errdefer if (temp_created) dir.deleteFile(io, temp_name) catch {};

    {
        const file = try dir.createFile(io, temp_name, .{
            .exclusive = true,
            .permissions = mode_file,
        });
        temp_created = true;
        defer file.close(io);

        // The process umask can only clear bits, but a hostile or broken umask
        // must not silently produce a managed file that the next load rejects.
        try verifyFile(try file.stat(io));
        try file.writeStreamingAll(io, data);
        try file.sync(io);
    }

    try dir.rename(temp_name, dir, name, io);
    temp_created = false;
    // The rename is visible immediately, but its directory entry is durable only
    // after this sync. Propagate a failure rather than claim a durable write.
    try syncDirectory(dir);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "permission policy rejects broader directories without changing them" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const owned = try std.fs.path.join(testing.allocator, &.{ root, "owned" });
    defer testing.allocator.free(owned);
    try ensureOwnedDir(io, owned);
    const st = try Io.Dir.cwd().statFile(io, owned, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o700), modeOf(st));

    const broad = try std.fs.path.join(testing.allocator, &.{ root, "broad" });
    defer testing.allocator.free(broad);
    try Io.Dir.createDirAbsolute(io, broad, Io.File.Permissions.fromMode(0o755));
    try testing.expectError(error.InsecurePermissions, ensureOwnedDir(io, broad));

    const after = try Io.Dir.cwd().statFile(io, broad, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o755), modeOf(after));

    // verifyOwnedDir never creates and rejects a symlink to a valid directory.
    const missing = try std.fs.path.join(testing.allocator, &.{ root, "missing" });
    defer testing.allocator.free(missing);
    try testing.expectError(error.FileNotFound, verifyOwnedDir(io, missing));

    try tmp.dir.symLink(io, "owned", "linked", .{});
    const linked = try std.fs.path.join(testing.allocator, &.{ root, "linked" });
    defer testing.allocator.free(linked);
    try testing.expectError(error.InsecureEntry, verifyOwnedDir(io, linked));
}

test "standard parents are created once and existing modes are preserved" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = testing.io;
    const home = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(home);

    const config = try std.fs.path.join(testing.allocator, &.{ home, ".config" });
    defer testing.allocator.free(config);
    const local = try std.fs.path.join(testing.allocator, &.{ home, ".local" });
    defer testing.allocator.free(local);
    const share = try std.fs.path.join(testing.allocator, &.{ home, ".local", "share" });
    defer testing.allocator.free(share);

    try ensureStandardParents(io, &.{ config, local, share });

    const config_stat = try Io.Dir.cwd().statFile(io, config, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o700), modeOf(config_stat));
    const share_stat = try Io.Dir.cwd().statFile(io, share, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o700), modeOf(share_stat));

    // An existing standard parent with a broad mode is used as-is.
    const broad = try std.fs.path.join(testing.allocator, &.{ home, "existing" });
    defer testing.allocator.free(broad);
    try Io.Dir.createDirAbsolute(io, broad, Io.File.Permissions.fromMode(0o755));
    try ensureStandardParents(io, &.{broad});
    const broad_stat = try Io.Dir.cwd().statFile(io, broad, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o755), modeOf(broad_stat));

    // A non-directory standard parent is rejected, not removed.
    const file_path = try std.fs.path.join(testing.allocator, &.{ home, "not-a-dir" });
    defer testing.allocator.free(file_path);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = file_path,
        .data = "x",
        .flags = .{ .permissions = mode_file },
    });
    try testing.expectError(error.NotDir, ensureStandardParents(io, &.{file_path}));
    _ = try Io.Dir.cwd().statFile(io, file_path, .{ .follow_symlinks = false });
}

fn addExtendedAcl(io: Io, path: []const u8) !void {
    const result = try std.process.run(testing.allocator, io, .{
        .argv = &.{ "/bin/chmod", "+a", "everyone allow read", path },
    });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(result.term.success());
}

test "macOS extended ACLs fail closed on opened files and directories" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const file_path = try std.fs.path.join(testing.allocator, &.{ root, "acl-file" });
    defer testing.allocator.free(file_path);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = file_path,
        .data = "x",
        .flags = .{ .permissions = mode_file },
    });

    {
        var file = try Io.Dir.cwd().openFile(io, file_path, .{ .follow_symlinks = false });
        defer file.close(io);
        try verifyNoExtendedAcl(file);
    }

    // An ordinary owner-only descriptor passes; an ACL on the same descriptor
    // is rejected even though the mode bits stay 0600 and are never repaired.
    try addExtendedAcl(io, file_path);
    {
        var file = try Io.Dir.cwd().openFile(io, file_path, .{ .follow_symlinks = false });
        defer file.close(io);
        try testing.expectError(error.InsecureAcl, verifyNoExtendedAcl(file));
    }
    const stat = try Io.Dir.cwd().statFile(io, file_path, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o600), modeOf(stat));

    const dir_path = try std.fs.path.join(testing.allocator, &.{ root, "acl-dir" });
    defer testing.allocator.free(dir_path);
    try Io.Dir.createDirAbsolute(io, dir_path, mode_dir);
    {
        var dir = try Io.Dir.openDirAbsolute(io, dir_path, .{ .follow_symlinks = false });
        defer dir.close(io);
        try verifyNoExtendedAclDir(dir);
    }
    try addExtendedAcl(io, dir_path);
    {
        var dir = try Io.Dir.openDirAbsolute(io, dir_path, .{ .follow_symlinks = false });
        defer dir.close(io);
        try testing.expectError(error.InsecureAcl, verifyNoExtendedAclDir(dir));
    }

    // An uninspectable descriptor fails closed instead of being accepted.
    try testing.expectError(error.AclInspectionFailed, verifyNoExtendedAclFd(-1));
}

test "a failed directory sync is reported, never claimed durable" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try testing.expectError(error.SyncFailed, syncDirectory(.{ .handle = -1 }));
}
