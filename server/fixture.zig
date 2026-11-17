//! Isolated real-file SQLite fixture. One process-global runtime at a time.
const std = @import("std");
const sql = @import("sqlite_runtime.zig");
const app = @import("app.zig");
pub const Fixture = struct {
    dir: std.Io.Dir,
    parent_dir: std.Io.Dir,
    sub_path: [16]u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    heap: []align(8) u8,
    buffers: []align(@alignOf(app.Layout)) u8,
    runtime: sql.Runtime,
    application: app.App,
    pub fn init() !Fixture {
        return initBudget(sql.default_budget);
    }
    pub fn initBudget(budget: usize) !Fixture {
        return initWith(std.testing.allocator, std.testing.io, budget);
    }
    pub fn initWith(allocator: std.mem.Allocator, io: std.Io, budget: usize) !Fixture {
        var random: [12]u8 = undefined;
        io.random(&random);
        var sub_path: [16]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&sub_path, &random);
        const parent_dir = try std.Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/tmp", .{});
        errdefer parent_dir.close(io);
        const dir = try parent_dir.createDirPathOpen(io, &sub_path, .{});
        errdefer {
            dir.close(io);
            parent_dir.deleteTree(io, &sub_path) catch {};
        }
        const path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/world.sqlite3", .{sub_path}, 0);
        errdefer allocator.free(path);
        const heap = try allocator.alignedAlloc(u8, .fromByteUnits(8), budget);
        errdefer allocator.free(heap);
        var runtime = try sql.Runtime.start(heap);
        errdefer runtime.stop();
        const buffers = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(app.Layout)), app.default_budget);
        errdefer allocator.free(buffers);
        const application = try app.App.init(io, path, buffers);
        return .{ .dir = dir, .parent_dir = parent_dir, .sub_path = sub_path, .io = io, .allocator = allocator, .path = path, .heap = heap, .buffers = buffers, .runtime = runtime, .application = application };
    }
    pub fn deinit(self: *Fixture) void {
        self.application.deinit();
        self.runtime.stop();
        self.allocator.free(self.buffers);
        self.allocator.free(self.heap);
        self.allocator.free(self.path);
        self.dir.close(self.io);
        self.parent_dir.deleteTree(self.io, &self.sub_path) catch {};
        self.parent_dir.close(self.io);
    }
};
