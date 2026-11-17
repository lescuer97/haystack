//! Desktop single-instance guard.
//!
//! One game process owns a user's storage root at a time. The guard is an OS
//! advisory exclusive lock on a `0600` file inside the Haystack config
//! directory. The verified descriptor is locked with nonblocking flock,
//! released by closing the file, and therefore released
//! automatically when the process exits, crashes, or is killed.
//!
//! A second process fails startup with `error.AlreadyRunning` instead of
//! sharing or corrupting the same settings and content.

const std = @import("std");
const Io = std.Io;

const sf = @import("storage_fs.zig");

pub const file_name = "haystack.lock";

/// Single owner of the lock file. An owning Lock must not be copied.
pub const Lock = struct {
    file: ?Io.File,

    pub fn release(self: *Lock, io: Io) void {
        const file = self.file orelse return;
        self.file = null;
        file.close(io);
    }
};

/// Acquire the storage-root lock, creating the Haystack config directory and
/// lock file if needed. Existing broad-permission or symlinked entries are
/// rejected rather than repaired.
pub fn acquire(io: Io, config_dir: []const u8) !Lock {
    const dir = try sf.openOwnedDir(io, config_dir, .{ .create = true });
    defer dir.close(io);

    // Reject symlinks at open and validate only the resulting descriptor.
    // NONBLOCK also prevents a substituted FIFO from hanging before validation.
    const fd = std.posix.openat(dir.handle, file_name, .{
        .ACCMODE = .RDONLY,
        .CREAT = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
        .NONBLOCK = true,
    }, 0o600) catch |err| switch (err) {
        error.SymLinkLoop, error.IsDir => return error.InsecureEntry,
        else => return err,
    };
    const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    errdefer file.close(io);

    try sf.verifyFile(try file.stat(io));
    try sf.verifyNoExtendedAcl(file);
    while (true) {
        switch (std.posix.errno(std.c.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
            .SUCCESS => break,
            .INTR => continue,
            .AGAIN => return error.AlreadyRunning,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    return .{ .file = file };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.posix.mode_t) c_int;

fn tempConfigDir(tmp: *testing.TmpDir) ![:0]const u8 {
    const io = testing.io;
    tmp.dir.createDir(io, "cfg", sf.mode_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return tmp.dir.realPathFileAlloc(io, "cfg", testing.allocator);
}

test "the lock is exclusive and can be reacquired after release" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tempConfigDir(&tmp);
    defer testing.allocator.free(dir);
    const io = testing.io;

    var held: ?Lock = try acquire(io, dir);
    defer if (held) |*lock| lock.release(io);

    try testing.expectError(error.AlreadyRunning, acquire(io, dir));

    const lock_path = try std.fs.path.join(testing.allocator, &.{ dir, file_name });
    defer testing.allocator.free(lock_path);
    const stat = try Io.Dir.cwd().statFile(io, lock_path, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o600), sf.modeOf(stat));

    held.?.release(io);
    held = null;
    const persisted = try Io.Dir.cwd().statFile(io, lock_path, .{ .follow_symlinks = false });
    try testing.expectEqual(stat.inode, persisted.inode);

    var second = try acquire(io, dir);
    second.release(io);
}

test "repeated release leaves a replacement lock live and exclusive" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tempConfigDir(&tmp);
    defer testing.allocator.free(dir);
    const io = testing.io;

    var original = try acquire(io, dir);
    defer original.release(io);
    try testing.expect(original.file != null);
    original.release(io);
    try testing.expect(original.file == null);
    original.release(io);
    try testing.expect(original.file == null);

    var second = try acquire(io, dir);
    defer second.release(io);
    original.release(io);
    _ = try second.file.?.stat(io);
    try testing.expectError(error.AlreadyRunning, acquire(io, dir));

    second.release(io);
    var reacquired = try acquire(io, dir);
    defer reacquired.release(io);
}

test "broad or symlinked lock files are rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tempConfigDir(&tmp);
    defer testing.allocator.free(dir);

    const broad = try std.fs.path.join(testing.allocator, &.{ dir, file_name });
    defer testing.allocator.free(broad);
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = broad,
        .data = "",
        .flags = .{ .permissions = Io.File.Permissions.fromMode(0o644) },
    });

    try testing.expectError(error.InsecurePermissions, acquire(testing.io, dir));
    const after = try Io.Dir.cwd().statFile(testing.io, broad, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o644), sf.modeOf(after));

    try Io.Dir.cwd().deleteFile(testing.io, broad);
    // A dangling symlink must be rejected, never followed to create its target.
    try tmp.dir.symLink(testing.io, "target", "cfg/" ++ file_name, .{});
    try testing.expectError(error.InsecureEntry, acquire(testing.io, dir));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "cfg/target", .{}));
}

test "symlinked lock directory and FIFO lock are rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const dir = try tempConfigDir(&tmp);
    defer testing.allocator.free(dir);
    try tmp.dir.symLink(io, "cfg", "linked", .{});
    const linked = try std.fs.path.join(testing.allocator, &.{ dir, "..", "linked" });
    defer testing.allocator.free(linked);
    try testing.expectError(error.InsecureEntry, acquire(io, linked));

    // With no writer a blocking FIFO open would hang; our open is nonblocking
    // and the descriptor must still pass the regular-file check.
    const fifo = try std.fs.path.joinZ(testing.allocator, &.{ dir, file_name });
    defer testing.allocator.free(fifo);
    try testing.expectEqual(@as(c_int, 0), mkfifo(fifo, 0o600));
    try testing.expectError(error.InsecureEntry, acquire(io, dir));
}

test "macOS lock file ACL is rejected" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const dir = try tempConfigDir(&tmp);
    defer testing.allocator.free(dir);
    var lock = try acquire(io, dir);
    lock.release(io);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, file_name });
    defer testing.allocator.free(path);
    const result = try std.process.run(testing.allocator, io, .{
        .argv = &.{ "/bin/chmod", "+a", "everyone allow read", path },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(result.term.success());
    try testing.expectError(error.InsecureAcl, acquire(io, dir));
}

test "lock directory must already be exactly 0700" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "broad", Io.File.Permissions.fromMode(0o755));
    const dir = try tmp.dir.realPathFileAlloc(io, "broad", testing.allocator);
    defer testing.allocator.free(dir);

    try testing.expectError(error.InsecurePermissions, acquire(io, dir));
}
