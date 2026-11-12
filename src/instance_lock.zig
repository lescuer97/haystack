//! Desktop single-instance guard.
//!
//! One game process owns a user's storage root at a time. The guard is an OS
//! advisory exclusive lock on a `0600` file inside the Haystack config
//! directory. The lock is acquired atomically by `open`/`create` where the
//! platform supports it, released by closing the file, and therefore released
//! automatically when the process exits, crashes, or is killed.
//!
//! A second process fails startup with `error.AlreadyRunning` instead of
//! sharing or corrupting the same settings and content.

const std = @import("std");
const Io = std.Io;

const sf = @import("storage_fs.zig");

pub const file_name = "haystack.lock";

pub const Lock = struct {
    file: Io.File,

    pub fn release(self: Lock, io: Io) void {
        self.file.close(io);
    }
};

/// Acquire the storage-root lock, creating the Haystack config directory and
/// lock file if needed. Existing broad-permission or symlinked entries are
/// rejected rather than repaired.
pub fn acquire(io: Io, config_dir: []const u8) !Lock {
    try sf.ensureOwnedDir(io, config_dir);

    var dir = try Io.Dir.openDirAbsolute(io, config_dir, .{});
    defer dir.close(io);

    const existing = dir.statFile(io, file_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |stat| try sf.verifyFile(stat);

    const file = dir.createFile(io, file_name, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = sf.mode_file,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.AlreadyRunning,
        else => return err,
    };
    errdefer file.close(io);

    const stat = try file.stat(io);
    try sf.verifyFile(stat);

    return .{ .file = file };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

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
    defer if (held) |lock| lock.release(io);

    try testing.expectError(error.AlreadyRunning, acquire(io, dir));

    const lock_path = try std.fs.path.join(testing.allocator, &.{ dir, file_name });
    defer testing.allocator.free(lock_path);
    const stat = try Io.Dir.cwd().statFile(io, lock_path, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o600), sf.modeOf(stat));

    held.?.release(io);
    held = null;

    const second = try acquire(io, dir);
    second.release(io);
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
