//! Desktop content store.
//!
//! Content is addressed by a flat logical key. A key is 1–128 ASCII bytes from
//! `[A-Za-z0-9_-]`; there are no directories, extensions, or nesting. Each key
//! maps to one whole file of at most 64 MiB.
//!
//! Reads, lists, and deletes of missing entries are explicit: reads and deletes
//! return `error.FileNotFound`, lists return an empty result. Writes create the
//! content directory lazily and replace files atomically, so a list never sees a
//! partially written entry. Temporary files use names that are not valid keys
//! and are therefore never listed.
//!
//! The store is constructed without touching the filesystem. Content
//! unavailability can therefore never prevent the game from starting.
//!
//! Reads, lists, and deletes enforce the same symlink and permission policy as
//! writes: both the Haystack-owned content root and its Haystack-owned parent
//! must be real `0700` directories, never symlinks. A missing parent or root is
//! an empty store for list and `error.FileNotFound` for read/delete.

const std = @import("std");
const Io = std.Io;

const key_mod = @import("content_key.zig");
const sf = @import("storage_fs.zig");

pub const MAX_KEY_BYTES: usize = key_mod.max_key_bytes;
pub const MAX_FILE_BYTES: usize = key_mod.max_file_bytes;

pub const Error = key_mod.Error;

pub const Store = struct {
    /// Absolute path of the content directory.
    root: []const u8,

    pub fn write(self: Store, io: Io, key: []const u8, data: []const u8) !void {
        try key_mod.validateKey(key);
        try key_mod.validateSize(data.len);

        // The content directory is created lazily. Its Haystack-owned parent
        // (the data-root `haystack` directory) is part of the same policy and
        // is created first; standard XDG parents are never touched.
        const parent = std.fs.path.dirname(self.root) orelse return error.InvalidPath;
        try sf.ensureOwnedDir(io, parent);
        try sf.ensureOwnedDir(io, self.root);

        var dir = try self.openVerifiedRoot(io, false);
        defer dir.close(io);

        const existing = dir.statFile(io, key, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |stat| try sf.verifyFile(stat);

        try sf.writeAtomicIn(dir, io, key, data);
    }

    pub fn read(self: Store, io: Io, allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        try key_mod.validateKey(key);

        var dir = try self.openVerifiedRoot(io, false);
        defer dir.close(io);

        var file = try dir.openFile(io, key, .{ .follow_symlinks = false });
        defer file.close(io);

        const stat = try file.stat(io);
        try sf.verifyFile(stat);
        if (stat.size > MAX_FILE_BYTES) return error.FileTooLarge;

        var reader = file.reader(io, &.{});
        return reader.interface.allocRemaining(allocator, .limited(MAX_FILE_BYTES));
    }

    /// List committed keys in stable byte order. A missing content directory is
    /// an empty list. Temporary and invalid names are skipped; a committed
    /// entry that violates the managed-file policy is an error.
    pub fn list(self: Store, io: Io, allocator: std.mem.Allocator) ![]const []u8 {
        var dir = self.openVerifiedRoot(io, true) catch |err| switch (err) {
            error.FileNotFound => return allocator.alloc([]u8, 0),
            else => return err,
        };
        defer dir.close(io);

        var keys: std.ArrayList([]u8) = .empty;
        errdefer {
            for (keys.items) |key| allocator.free(key);
            keys.deinit(allocator);
        }

        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (!validKey(entry.name)) continue;

            const entry_stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
            try sf.verifyFile(entry_stat);

            const key = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(key);
            try keys.append(allocator, key);
        }

        std.mem.sort([]u8, keys.items, {}, keyLessThan);
        return keys.toOwnedSlice(allocator);
    }

    pub fn freeKeys(allocator: std.mem.Allocator, keys: []const []u8) void {
        for (keys) |key| allocator.free(key);
        allocator.free(keys);
    }

    pub fn delete(self: Store, io: Io, key: []const u8) !void {
        try key_mod.validateKey(key);

        var dir = try self.openVerifiedRoot(io, false);
        defer dir.close(io);

        const existing = try dir.statFile(io, key, .{ .follow_symlinks = false });
        try sf.verifyFile(existing);
        try dir.deleteFile(io, key);
    }

    /// Verify the Haystack-owned parent and content root without creating them,
    /// then open the root without following a final symlink. Both directory
    /// entries must be real `0700` directories.
    fn openVerifiedRoot(self: Store, io: Io, iterate: bool) !Io.Dir {
        const parent = std.fs.path.dirname(self.root) orelse return error.InvalidPath;
        sf.verifyOwnedDir(io, parent) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        const root_stat = Io.Dir.cwd().statFile(io, self.root, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        try sf.verifyDirectory(root_stat);

        return Io.Dir.openDirAbsolute(io, self.root, .{
            .iterate = iterate,
            .follow_symlinks = false,
        });
    }
};

pub const validKey = key_mod.validKey;
pub const validateKey = key_mod.validateKey;

fn keyLessThan(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const TempContent = struct {
    root: []const u8,

    fn init(tmp: *testing.TmpDir) !TempContent {
        const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(base);
        return .{ .root = try std.fs.path.join(testing.allocator, &.{ base, "haystack", "content" }) };
    }

    fn deinit(self: TempContent) void {
        testing.allocator.free(self.root);
    }

    fn store(self: TempContent) Store {
        return .{ .root = self.root };
    }
};

test "keys are flat, bounded, and ASCII" {
    try validateKey("abc");
    try validateKey("A_b-9");
    try testing.expect(!validKey(""));
    try testing.expect(!validKey("has space"));
    try testing.expect(!validKey("nested/key"));
    try testing.expect(!validKey(".tmp-123"));
    try testing.expect(!validKey("caf\u{e9}"));

    const max: [MAX_KEY_BYTES]u8 = @splat('a');
    try validateKey(&max);
    const too_long: [MAX_KEY_BYTES + 1]u8 = @splat('a');
    try testing.expectError(error.InvalidKey, validateKey(&too_long));
}

test "write creates the content directory lazily, reads, replaces, and deletes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp = try TempContent.init(&tmp);
    defer temp.deinit();
    const store = temp.store();

    const cwd = Io.Dir.cwd();
    try testing.expectError(error.FileNotFound, cwd.statFile(testing.io, temp.root, .{ .follow_symlinks = false }));

    try store.write(testing.io, "hello_world", "first");
    const dir_stat = try cwd.statFile(testing.io, temp.root, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o700), sf.modeOf(dir_stat));

    const first = try store.read(testing.io, testing.allocator, "hello_world");
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("first", first);

    try store.write(testing.io, "hello_world", "second");
    const second = try store.read(testing.io, testing.allocator, "hello_world");
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("second", second);

    try store.delete(testing.io, "hello_world");
    try testing.expectError(error.FileNotFound, store.read(testing.io, testing.allocator, "hello_world"));
    try testing.expectError(error.FileNotFound, store.delete(testing.io, "hello_world"));
}

test "missing content lists empty; lists skip temporary names and sort committed keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp = try TempContent.init(&tmp);
    defer temp.deinit();
    const store = temp.store();

    const empty = try store.list(testing.io, testing.allocator);
    defer Store.freeKeys(testing.allocator, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    try store.write(testing.io, "zeta", "z");
    try store.write(testing.io, "alpha", "a");
    try store.write(testing.io, "middle-1", "m");

    // A crash could leave an atomic-write temporary behind. It must not look
    // like a committed logical key.
    const temp_path = try std.fs.path.join(testing.allocator, &.{ temp.root, ".tmp-deadbeef" });
    defer testing.allocator.free(temp_path);
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = temp_path,
        .data = "partial",
        .flags = .{ .permissions = sf.mode_file },
    });

    const keys = try store.list(testing.io, testing.allocator);
    defer Store.freeKeys(testing.allocator, keys);
    try testing.expectEqual(@as(usize, 3), keys.len);
    try testing.expectEqualStrings("alpha", keys[0]);
    try testing.expectEqualStrings("middle-1", keys[1]);
    try testing.expectEqualStrings("zeta", keys[2]);
}

test "content files are exactly 0600 and oversize files are rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp = try TempContent.init(&tmp);
    defer temp.deinit();
    const store = temp.store();

    try store.write(testing.io, "small", "x");
    const path = try std.fs.path.join(testing.allocator, &.{ temp.root, "small" });
    defer testing.allocator.free(path);
    const stat = try Io.Dir.cwd().statFile(testing.io, path, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o600), sf.modeOf(stat));

    const big_path = try std.fs.path.join(testing.allocator, &.{ temp.root, "big" });
    defer testing.allocator.free(big_path);
    const file = try Io.Dir.cwd().createFile(testing.io, big_path, .{ .permissions = sf.mode_file });
    defer file.close(testing.io);
    try file.setLength(testing.io, MAX_FILE_BYTES + 1);

    try testing.expectError(error.FileTooLarge, store.read(testing.io, testing.allocator, "big"));
}

test "insecure content entries are rejected without chmod" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp = try TempContent.init(&tmp);
    defer temp.deinit();
    const store = temp.store();

    tmp.dir.createDir(testing.io, "haystack", sf.mode_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    tmp.dir.createDir(testing.io, "haystack/content", sf.mode_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const path = try std.fs.path.join(testing.allocator, &.{ temp.root, "broad" });
    defer testing.allocator.free(path);
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = path,
        .data = "x",
        .flags = .{ .permissions = Io.File.Permissions.fromMode(0o644) },
    });

    try testing.expectError(error.InsecurePermissions, store.read(testing.io, testing.allocator, "broad"));
    const after = try Io.Dir.cwd().statFile(testing.io, path, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o644), sf.modeOf(after));

    // A symlinked managed entry is not a committed content file.
    const target = try std.fs.path.join(testing.allocator, &.{ temp.root, "target" });
    defer testing.allocator.free(target);
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = target,
        .data = "x",
        .flags = .{ .permissions = sf.mode_file },
    });
    try tmp.dir.symLink(testing.io, "target", "haystack/content/link", .{});
    try testing.expectError(error.InsecureEntry, store.list(testing.io, testing.allocator));
}

test "read, list, and delete reject broad content directories without chmod" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const base = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);

    // A valid Haystack parent with a broad content root.
    try tmp.dir.createDir(io, "haystack", sf.mode_dir);
    try tmp.dir.createDir(io, "haystack/content", Io.File.Permissions.fromMode(0o755));
    try tmp.dir.writeFile(io, .{
        .sub_path = "haystack/content/entry",
        .data = "data",
        .flags = .{ .permissions = sf.mode_file },
    });
    const root = try std.fs.path.join(testing.allocator, &.{ base, "haystack", "content" });
    defer testing.allocator.free(root);
    const store = Store{ .root = root };

    try testing.expectError(error.InsecurePermissions, store.read(io, testing.allocator, "entry"));
    try testing.expectError(error.InsecurePermissions, store.list(io, testing.allocator));
    try testing.expectError(error.InsecurePermissions, store.delete(io, "entry"));
    const root_stat = try Io.Dir.cwd().statFile(io, root, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o755), sf.modeOf(root_stat));

    // A broad Haystack parent with a valid content root.
    try tmp.dir.createDir(io, "broad", Io.File.Permissions.fromMode(0o755));
    try tmp.dir.createDir(io, "broad/content", sf.mode_dir);
    try tmp.dir.writeFile(io, .{
        .sub_path = "broad/content/entry",
        .data = "data",
        .flags = .{ .permissions = sf.mode_file },
    });
    const broad_root = try std.fs.path.join(testing.allocator, &.{ base, "broad", "content" });
    defer testing.allocator.free(broad_root);
    const broad_store = Store{ .root = broad_root };

    try testing.expectError(error.InsecurePermissions, broad_store.read(io, testing.allocator, "entry"));
    try testing.expectError(error.InsecurePermissions, broad_store.list(io, testing.allocator));
    try testing.expectError(error.InsecurePermissions, broad_store.delete(io, "entry"));
    const broad_path = try std.fs.path.join(testing.allocator, &.{ base, "broad" });
    defer testing.allocator.free(broad_path);
    const broad_stat = try Io.Dir.cwd().statFile(io, broad_path, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o755), sf.modeOf(broad_stat));
}

test "read, list, and delete reject a symlinked content root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp = try TempContent.init(&tmp);
    defer temp.deinit();

    // A real store with one entry, then replace the content directory with a
    // symlink to it. The entry is valid, but the root itself is not managed.
    const store = temp.store();
    try store.write(testing.io, "entry", "data");

    try tmp.dir.rename("haystack/content", tmp.dir, "real-content", testing.io);
    try tmp.dir.symLink(testing.io, "../real-content", "haystack/content", .{});

    try testing.expectError(error.InsecureEntry, store.read(testing.io, testing.allocator, "entry"));
    try testing.expectError(error.InsecureEntry, store.list(testing.io, testing.allocator));
    try testing.expectError(error.InsecureEntry, store.delete(testing.io, "entry"));
}

test "read, list, and delete reject a symlinked Haystack parent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = testing.io;
    try tmp.dir.createDir(io, "real", sf.mode_dir);
    try tmp.dir.createDir(io, "real/haystack", sf.mode_dir);
    try tmp.dir.createDir(io, "real/haystack/content", sf.mode_dir);
    try tmp.dir.writeFile(io, .{
        .sub_path = "real/haystack/content/entry",
        .data = "data",
        .flags = .{ .permissions = sf.mode_file },
    });
    try tmp.dir.symLink(io, "real/haystack", "linked", .{});

    const base = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);
    const root = try std.fs.path.join(testing.allocator, &.{ base, "linked", "content" });
    defer testing.allocator.free(root);
    const store = Store{ .root = root };

    try testing.expectError(error.InsecureEntry, store.read(io, testing.allocator, "entry"));
    try testing.expectError(error.InsecureEntry, store.list(io, testing.allocator));
    try testing.expectError(error.InsecureEntry, store.delete(io, "entry"));
}
