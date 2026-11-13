//! Native storage startup tests for a clean Linux-like HOME.
//!
//! These exercise the real sequence `main` uses: resolve locations, create only
//! missing standard parents, take the single-instance lock, persist config, and
//! use the content store. Nothing here runs on the browser target.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const config = @import("config.zig");
const content = @import("content.zig");
const instance_lock = @import("instance_lock.zig");
const paths = @import("paths.zig");
const settings_mod = @import("settings.zig");
const sf = @import("storage_fs.zig");

const testing = std.testing;

test "clean HOME startup creates only the missing standard directories" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const home = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(home);

    const platform: paths.Platform = if (builtin.os.tag == .linux) .linux else .macos;
    const locations = try paths.resolve(testing.allocator, platform, null, null, home);
    defer locations.deinit(testing.allocator);

    // Simulate a conventional existing ~/.config on Linux. Startup must not
    // rewrite it, but Haystack-owned entries inside it are strict.
    if (platform == .linux) {
        try tmp.dir.createDir(io, ".config", Io.File.Permissions.fromMode(0o755));
    }

    try sf.ensureStandardParents(io, locations.standard_parents);

    if (platform == .linux) {
        const stat = try Io.Dir.cwd().statFile(io, locations.standard_parents[0], .{ .follow_symlinks = false });
        try testing.expectEqual(@as(u32, 0o755), sf.modeOf(stat));
    }

    var lock = try instance_lock.acquire(io, locations.config_dir);
    defer lock.release(io);

    try config.save(io, locations.config_path, settings_mod.Settings{});

    const config_dir_stat = try Io.Dir.cwd().statFile(io, locations.config_dir, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o700), sf.modeOf(config_dir_stat));
    const config_stat = try Io.Dir.cwd().statFile(io, locations.config_path, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o600), sf.modeOf(config_stat));

    const loaded = config.load(io, testing.allocator, locations.config_path);
    try testing.expectEqual(config.Status.loaded, loaded.status);
    try testing.expect(loaded.autosaveAllowed());

    const store = content.Store{ .root = locations.content_dir };
    try store.write(io, "clean_home", "payload");
    const bytes = try store.read(io, testing.allocator, "clean_home");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("payload", bytes);

    const keys = try store.list(io, testing.allocator);
    defer content.Store.freeKeys(testing.allocator, keys);
    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expectEqualStrings("clean_home", keys[0]);

    try store.delete(io, "clean_home");
    try testing.expectError(error.FileNotFound, store.read(io, testing.allocator, "clean_home"));
}

test "clean HOME without standard parents creates them before storage starts" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const home = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(home);

    const platform: paths.Platform = if (builtin.os.tag == .linux) .linux else .macos;
    const locations = try paths.resolve(testing.allocator, platform, null, null, home);
    defer locations.deinit(testing.allocator);

    // A truly clean HOME has none of the standard parents. Startup creates
    // every missing one with owner-only permissions and never needs a
    // pre-existing ~/.config (the macOS equivalents are checked the same way).
    for (locations.standard_parents) |path| {
        try testing.expectError(
            error.FileNotFound,
            Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }),
        );
    }
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(io, locations.config_dir, .{ .follow_symlinks = false }),
    );

    try sf.ensureStandardParents(io, locations.standard_parents);
    for (locations.standard_parents) |path| {
        const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        try testing.expectEqual(@as(u32, 0o700), sf.modeOf(stat));
    }

    // The content root still does not exist: read/delete behave like a missing
    // entry and list is empty, without creating any Haystack directories.
    const store = content.Store{ .root = locations.content_dir };
    try testing.expectError(error.FileNotFound, store.read(io, testing.allocator, "absent"));
    try testing.expectError(error.FileNotFound, store.delete(io, "absent"));
    const empty = try store.list(io, testing.allocator);
    defer content.Store.freeKeys(testing.allocator, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(io, locations.content_dir, .{ .follow_symlinks = false }),
    );

    var lock = try instance_lock.acquire(io, locations.config_dir);
    defer lock.release(io);

    const loaded = config.load(io, testing.allocator, locations.config_path);
    try testing.expectEqual(config.Status.missing, loaded.status);
    try testing.expect(loaded.autosaveAllowed());

    try config.save(io, locations.config_path, settings_mod.Settings{});
    const saved = config.load(io, testing.allocator, locations.config_path);
    try testing.expectEqual(config.Status.loaded, saved.status);
    try testing.expect(saved.autosaveAllowed());

    try store.write(io, "clean_home_2", "payload");
    const bytes = try store.read(io, testing.allocator, "clean_home_2");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("payload", bytes);
    try store.delete(io, "clean_home_2");
}
