//! Desktop settings persistence.
//!
//! The on-disk format is intentionally small and versioned:
//!
//! ```json
//! {
//!   "version": 1,
//!   "debug": { "tile_grid": true, "chunk_borders": false }
//! }
//! ```
//!
//! Missing optional fields fall back to the built-in defaults. A missing file
//! is normal and enables autosave. A malformed file, a current-version file
//! with fields this build does not understand, a file with a newer version, an
//! unreadable file, or an entry that violates the storage permission policy all
//! preserve the game start with built-in defaults while blocking autosave until
//! `reset` removes the offending file. The version envelope is parsed first, so
//! a newer document is still reported as `newer_version` even when its body
//! contains fields or shapes this build cannot represent.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const settings_mod = @import("settings.zig");
const sf = @import("storage_fs.zig");

pub const CURRENT_VERSION: u32 = 1;
pub const MAX_BYTES: usize = 64 * 1024;
pub const file_name = "config.json";

/// Expected corruption is reported at error severity in a normal build. Unit
/// tests deliberately exercise those paths, so they downgrade the severity to
/// warnings; the Zig test runner treats any error log as a failed test.
pub var failure_level: std.log.Level = if (builtin.is_test) .warn else .err;

fn logFailure(comptime format: []const u8, args: anytype) void {
    switch (failure_level) {
        .err => std.log.err(format, args),
        .warn => std.log.warn(format, args),
        .info => std.log.info(format, args),
        .debug => std.log.debug(format, args),
    }
}

const Wire = struct {
    version: u32,
    debug: struct {
        tile_grid: ?bool = null,
        chunk_borders: ?bool = null,
    } = .{},
};

/// Minimal first pass: only the version is needed to distinguish a document
/// written by a newer build from one this build understands. Unknown fields
/// are ignored here because they belong to the later strict parse.
const Envelope = struct {
    version: u32,
};

pub const Status = enum {
    /// A valid current-version file was loaded.
    loaded,
    /// No file exists; defaults apply and autosave may create one.
    missing,
    /// The file exists but is not valid current-version configuration.
    malformed,
    /// The file was written by a newer version and must not be overwritten.
    newer_version,
    /// The file could not be read safely (I/O error or insecure entry).
    unavailable,
};

pub const Loaded = struct {
    settings: settings_mod.Settings,
    status: Status,

    pub fn autosaveAllowed(self: Loaded) bool {
        return self.status == .missing or self.status == .loaded;
    }
};

/// Load settings, always returning a usable value. Failures are logged and
/// convert to built-in defaults with autosave disabled.
pub fn load(io: Io, allocator: std.mem.Allocator, path: []const u8) Loaded {
    const defaults = Loaded{ .settings = .{}, .status = .missing };

    const parent = std.fs.path.dirname(path) orelse {
        logFailure("config: invalid path path={s}", .{path});
        return .{ .settings = .{}, .status = .unavailable };
    };
    var dir = Io.Dir.openDirAbsolute(io, parent, .{}) catch |err| switch (err) {
        error.FileNotFound => return defaults,
        else => {
            logFailure("config: cannot open directory path={s} error={s}", .{ path, @errorName(err) });
            return .{ .settings = .{}, .status = .unavailable };
        },
    };
    defer dir.close(io);

    const name = std.fs.path.basename(path);
    if (name.len == 0) {
        logFailure("config: invalid path path={s}", .{path});
        return .{ .settings = .{}, .status = .unavailable };
    }

    const existing = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return defaults,
        else => {
            logFailure("config: cannot stat path={s} error={s}", .{ path, @errorName(err) });
            return .{ .settings = .{}, .status = .unavailable };
        },
    };
    sf.verifyFile(existing) catch |err| {
        logFailure("config: insecure entry path={s} mode={o} error={s}", .{ path, sf.modeOf(existing), @errorName(err) });
        return .{ .settings = .{}, .status = .unavailable };
    };
    if (existing.size > MAX_BYTES) {
        logFailure("config: too large path={s} size={d} limit={d}", .{ path, existing.size, MAX_BYTES });
        return .{ .settings = .{}, .status = .malformed };
    }

    var file = dir.openFile(io, name, .{ .follow_symlinks = false }) catch |err| {
        logFailure("config: cannot open path={s} error={s}", .{ path, @errorName(err) });
        return .{ .settings = .{}, .status = .unavailable };
    };
    defer file.close(io);

    var buffer: [MAX_BYTES]u8 = undefined;
    var reader = file.reader(io, &.{});
    const length = reader.interface.readSliceShort(&buffer) catch |err| {
        logFailure("config: cannot read path={s} error={s}", .{ path, @errorName(err) });
        return .{ .settings = .{}, .status = .unavailable };
    };

    const envelope = std.json.parseFromSlice(
        Envelope,
        allocator,
        buffer[0..length],
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        logFailure("config: parse failed path={s} error={s}", .{ path, @errorName(err) });
        return .{ .settings = .{}, .status = .malformed };
    };
    defer envelope.deinit();

    if (envelope.value.version > CURRENT_VERSION) {
        std.log.warn(
            "config: newer version preserved path={s} found={d} supported={d}",
            .{ path, envelope.value.version, CURRENT_VERSION },
        );
        return .{ .settings = .{}, .status = .newer_version };
    }
    if (envelope.value.version != CURRENT_VERSION) {
        logFailure(
            "config: unsupported version path={s} found={d} supported={d}",
            .{ path, envelope.value.version, CURRENT_VERSION },
        );
        return .{ .settings = .{}, .status = .malformed };
    }

    // The current version must match this build exactly. Unknown fields are
    // rejected rather than silently discarded: accepting them here would allow
    // the next autosave to overwrite data written by a future build.
    const parsed = std.json.parseFromSlice(
        Wire,
        allocator,
        buffer[0..length],
        .{},
    ) catch |err| {
        logFailure("config: parse failed path={s} error={s}", .{ path, @errorName(err) });
        return .{ .settings = .{}, .status = .malformed };
    };
    defer parsed.deinit();

    var settings: settings_mod.Settings = .{};
    if (parsed.value.debug.tile_grid) |value| settings.debug.tile_grid = value;
    if (parsed.value.debug.chunk_borders) |value| settings.debug.chunk_borders = value;

    return .{ .settings = settings, .status = .loaded };
}

/// Serialize settings to the current on-disk format.
pub fn serialize(settings: settings_mod.Settings, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{{\n  \"version\": {d},\n  \"debug\": {{\n    \"tile_grid\": {s},\n    \"chunk_borders\": {s}\n  }}\n}}\n",
        .{
            CURRENT_VERSION,
            boolLiteral(settings.debug.tile_grid),
            boolLiteral(settings.debug.chunk_borders),
        },
    );
}

fn boolLiteral(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// Atomically write a complete configuration file. Existing files are only
/// replaced when they already satisfy the managed-file policy.
pub fn save(io: Io, path: []const u8, settings: settings_mod.Settings) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try sf.ensureOwnedDir(io, parent);

    var dir = try sf.openParent(io, path);
    defer dir.close(io);
    const name = try sf.basename(path);

    const existing = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |stat| try sf.verifyFile(stat);

    var buffer: [256]u8 = undefined;
    const data = try serialize(settings, &buffer);
    try sf.writeAtomicIn(dir, io, name, data);
}

/// Remove an existing configuration file. Missing files and missing Haystack
/// directories are already a successful reset. Insecure entries are rejected
/// rather than deleted.
pub fn reset(io: Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;

    var dir = Io.Dir.openDirAbsolute(io, parent, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    const name = try sf.basename(path);
    const existing = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try sf.verifyFile(existing);
    try dir.deleteFile(io, name);
}

/// Explicit user-requested reset. Removing a malformed or newer file is the
/// only way to re-enable autosave; the caller can then save current defaults or
/// let the next toggle write the first current-version file.
pub fn resetSettings(io: Io, path: []const u8) !void {
    return reset(io, path);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const TempConfig = struct {
    dir: [:0]const u8,
    path: []const u8,

    fn init(tmp: *testing.TmpDir) !TempConfig {
        const io = testing.io;
        tmp.dir.createDir(io, "cfg", sf.mode_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const dir = try tmp.dir.realPathFileAlloc(io, "cfg", testing.allocator);
        errdefer testing.allocator.free(dir);
        const path = try std.fs.path.join(testing.allocator, &.{ dir, file_name });
        return .{ .dir = dir, .path = path };
    }

    fn deinit(self: TempConfig) void {
        testing.allocator.free(self.path);
        testing.allocator.free(self.dir);
    }
};

test "missing config yields defaults and allows autosave" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const location = try TempConfig.init(&tmp);
    defer location.deinit();

    const loaded = load(testing.io, testing.allocator, location.path);
    try testing.expectEqual(Status.missing, loaded.status);
    try testing.expect(loaded.autosaveAllowed());
    try testing.expectEqual(settings_mod.Settings{}, loaded.settings);
}

test "settings serialize and load with version and exact permissions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const location = try TempConfig.init(&tmp);
    defer location.deinit();

    const expected = settings_mod.Settings{
        .debug = .{ .tile_grid = true, .chunk_borders = false },
    };
    try save(testing.io, location.path, expected);

    const stat = try Io.Dir.cwd().statFile(testing.io, location.path, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o600), sf.modeOf(stat));

    const text = try Io.Dir.cwd().readFileAlloc(testing.io, location.path, testing.allocator, .limited(MAX_BYTES));
    defer testing.allocator.free(text);
    try testing.expect(std.mem.find(u8, text, "\"version\": 1") != null);
    try testing.expect(std.mem.find(u8, text, "\"tile_grid\": true") != null);

    const loaded = load(testing.io, testing.allocator, location.path);
    try testing.expectEqual(Status.loaded, loaded.status);
    try testing.expect(loaded.autosaveAllowed());
    try testing.expectEqual(expected, loaded.settings);
}

test "missing debug fields take built-in defaults" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const location = try TempConfig.init(&tmp);
    defer location.deinit();

    const text = "{\"version\":1,\"debug\":{\"tile_grid\":false}}";
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = location.path,
        .data = text,
        .flags = .{ .permissions = sf.mode_file },
    });

    const loaded = load(testing.io, testing.allocator, location.path);
    try testing.expectEqual(Status.loaded, loaded.status);
    try testing.expectEqual(false, loaded.settings.debug.tile_grid);
    try testing.expectEqual((settings_mod.Settings{}).debug.chunk_borders, loaded.settings.debug.chunk_borders);
}

test "malformed config is preserved, defaults apply, autosave blocked until reset" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const location = try TempConfig.init(&tmp);
    defer location.deinit();

    const text = "{ not json";
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = location.path,
        .data = text,
        .flags = .{ .permissions = sf.mode_file },
    });

    const loaded = load(testing.io, testing.allocator, location.path);
    try testing.expectEqual(Status.malformed, loaded.status);
    try testing.expect(!loaded.autosaveAllowed());
    try testing.expectEqual(settings_mod.Settings{}, loaded.settings);

    // Autosave is the caller's decision, but the file must remain untouched.
    const preserved = try Io.Dir.cwd().readFileAlloc(testing.io, location.path, testing.allocator, .limited(MAX_BYTES));
    defer testing.allocator.free(preserved);
    try testing.expectEqualStrings(text, preserved);

    try reset(testing.io, location.path);
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().openFile(testing.io, location.path, .{}),
    );

    const after = load(testing.io, testing.allocator, location.path);
    try testing.expectEqual(Status.missing, after.status);
    try testing.expect(after.autosaveAllowed());
}

test "newer config is preserved and blocks autosave" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const location = try TempConfig.init(&tmp);
    defer location.deinit();

    const text = "{\"version\":99,\"debug\":{\"tile_grid\":false}}";
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = location.path,
        .data = text,
        .flags = .{ .permissions = sf.mode_file },
    });

    const loaded = load(testing.io, testing.allocator, location.path);
    try testing.expectEqual(Status.newer_version, loaded.status);
    try testing.expect(!loaded.autosaveAllowed());

    const preserved = try Io.Dir.cwd().readFileAlloc(testing.io, location.path, testing.allocator, .limited(MAX_BYTES));
    defer testing.allocator.free(preserved);
    try testing.expectEqualStrings(text, preserved);
}

test "current-version config with unknown fields is preserved and blocks autosave" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const location = try TempConfig.init(&tmp);
    defer location.deinit();

    const cases = [_][]const u8{
        "{\"version\":1,\"debug\":{\"tile_grid\":true},\"future\":true}",
        "{\"version\":1,\"debug\":{\"tile_grid\":true,\"future\":true}}",
    };
    for (cases) |text| {
        try Io.Dir.cwd().writeFile(testing.io, .{
            .sub_path = location.path,
            .data = text,
            .flags = .{ .permissions = sf.mode_file },
        });

        const loaded = load(testing.io, testing.allocator, location.path);
        try testing.expectEqual(Status.malformed, loaded.status);
        try testing.expect(!loaded.autosaveAllowed());
        // A document this build does not fully understand never contributes
        // settings; the caller starts with built-in defaults.
        try testing.expectEqual(settings_mod.Settings{}, loaded.settings);

        const preserved = try Io.Dir.cwd().readFileAlloc(testing.io, location.path, testing.allocator, .limited(MAX_BYTES));
        defer testing.allocator.free(preserved);
        try testing.expectEqualStrings(text, preserved);
    }
}

test "newer config is reported before strict body validation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const location = try TempConfig.init(&tmp);
    defer location.deinit();

    // The body is not valid current-version configuration (and contains an
    // unknown field), but the version envelope decides the status first.
    const text = "{\"version\":99,\"debug\":123,\"future\":{\"nested\":true}}";
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = location.path,
        .data = text,
        .flags = .{ .permissions = sf.mode_file },
    });

    const loaded = load(testing.io, testing.allocator, location.path);
    try testing.expectEqual(Status.newer_version, loaded.status);
    try testing.expect(!loaded.autosaveAllowed());
    try testing.expectEqual(settings_mod.Settings{}, loaded.settings);

    const preserved = try Io.Dir.cwd().readFileAlloc(testing.io, location.path, testing.allocator, .limited(MAX_BYTES));
    defer testing.allocator.free(preserved);
    try testing.expectEqualStrings(text, preserved);
}

test "oversized config is rejected without reading or rewriting it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const location = try TempConfig.init(&tmp);
    defer location.deinit();

    const oversized = try testing.allocator.alloc(u8, MAX_BYTES + 1);
    defer testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = location.path,
        .data = oversized,
        .flags = .{ .permissions = sf.mode_file },
    });

    const loaded = load(testing.io, testing.allocator, location.path);
    try testing.expectEqual(Status.malformed, loaded.status);
    try testing.expect(!loaded.autosaveAllowed());
}

test "broad config permissions are rejected and never repaired" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const location = try TempConfig.init(&tmp);
    defer location.deinit();

    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = location.path,
        .data = "{\"version\":1}",
        .flags = .{ .permissions = Io.File.Permissions.fromMode(0o644) },
    });

    const loaded = load(testing.io, testing.allocator, location.path);
    try testing.expectEqual(Status.unavailable, loaded.status);
    try testing.expect(!loaded.autosaveAllowed());

    const stat = try Io.Dir.cwd().statFile(testing.io, location.path, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o644), sf.modeOf(stat));
    try testing.expectError(
        error.InsecurePermissions,
        save(testing.io, location.path, settings_mod.Settings{}),
    );
    const after = try Io.Dir.cwd().statFile(testing.io, location.path, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o644), sf.modeOf(after));
}

test "reset refuses a broad config file and preserves it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const location = try TempConfig.init(&tmp);
    defer location.deinit();

    const text = "{ not json";
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = location.path,
        .data = text,
        .flags = .{ .permissions = Io.File.Permissions.fromMode(0o644) },
    });

    try testing.expectError(error.InsecurePermissions, reset(testing.io, location.path));

    const stat = try Io.Dir.cwd().statFile(testing.io, location.path, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o644), sf.modeOf(stat));
    const preserved = try Io.Dir.cwd().readFileAlloc(testing.io, location.path, testing.allocator, .limited(MAX_BYTES));
    defer testing.allocator.free(preserved);
    try testing.expectEqualStrings(text, preserved);
}

test "symlinked config is rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const location = try TempConfig.init(&tmp);
    defer location.deinit();

    const target = try std.fs.path.join(testing.allocator, &.{ location.dir, "target.json" });
    defer testing.allocator.free(target);
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = target,
        .data = "{\"version\":1}",
        .flags = .{ .permissions = sf.mode_file },
    });
    try tmp.dir.symLink(testing.io, "target.json", "cfg/config.json", .{});

    const loaded = load(testing.io, testing.allocator, location.path);
    try testing.expectEqual(Status.unavailable, loaded.status);
    try testing.expectError(
        error.InsecureEntry,
        save(testing.io, location.path, settings_mod.Settings{}),
    );
}
