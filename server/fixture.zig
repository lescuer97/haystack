//! Isolated RAM-only application fixture.
const std = @import("std");
const app = @import("app.zig");
pub const Fixture = struct {
    allocator: std.mem.Allocator,
    buffers: []align(@alignOf(app.Layout)) u8,
    application: app.App,
    pub fn init() !Fixture {
        return initWith(std.testing.allocator, std.testing.io, app.default_budget);
    }
    pub fn initWith(allocator: std.mem.Allocator, io: std.Io, application_budget: usize) !Fixture {
        const buffers = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(app.Layout)), application_budget);
        errdefer allocator.free(buffers);
        return .{ .allocator = allocator, .buffers = buffers, .application = try app.App.init(io, buffers) };
    }
    pub fn deinit(self: *Fixture) void {
        self.application.deinit();
        self.allocator.free(self.buffers);
    }
};
