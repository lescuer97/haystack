//! Four exclusively leased contexts, independent of callback thread affinity.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const Storage = @import("storage.zig").Storage;
const actions = @import("actions.zig");
const sessions = @import("sessions.zig");
pub const default_budget = 64 * 1024;
pub const Context = struct {
    leased: bool = false,
    db: Storage,
    response: [p.max_response_bytes]u8 = undefined,
    snapshot: p.Snapshot = undefined,
    pub fn handle(self: *Context, req: p.Request) []const u8 {
        return shared.wire.encode(&self.response, actions.handle(&self.db, &self.snapshot, req));
    }
};
pub const Layout = struct { contexts: [4]Context, registry: sessions.Registry };
pub const App = struct {
    database_path: [:0]const u8,
    contexts: *[4]Context,
    registry: *sessions.Registry,
    pub fn init(io: std.Io, path: [:0]const u8, buffers: []align(@alignOf(Layout)) u8) !App {
        if (buffers.len < @sizeOf(Layout)) return error.InsufficientApplicationBudget;
        const layout: *Layout = @ptrCast(buffers.ptr);
        layout.registry = .{ .io = io };
        const contexts = &layout.contexts;
        var initialized: usize = 0;
        errdefer for (contexts[0..initialized]) |*context| context.db.close();
        for (contexts, 0..) |*context, i| {
            context.* = .{ .db = try Storage.open(path) };
            initialized += 1;
            if (i == 0) try context.db.initialize();
            try context.db.ready();
        }
        return .{ .database_path = path, .contexts = contexts, .registry = &layout.registry };
    }
    pub fn deinit(self: *App) void {
        for (self.contexts) |*context| context.db.close();
        // The server drains callbacks before destroying the application.
        self.registry.slots = @splat(.{});
    }
    pub fn handleLocation(self: *App, handle: sessions.Handle, req: p.Request) p.Response {
        if (req.operation != .update_location) return shared.wire.failure(req.request_id, .invalid_request);
        self.registry.update(handle, req.operation.update_location) catch return shared.wire.failure(req.request_id, .invalid_request);
        return .{ .request_id = req.request_id, .result = .location_updated };
    }
    pub fn lease(self: *App) ?*Context {
        for (self.contexts) |*context| {
            if (@cmpxchgStrong(bool, &context.leased, false, true, .acquire, .monotonic) != null) continue;
            if (context.db.poisoned) {
                self.release(context);
                continue;
            }
            return context;
        }
        return null;
    }
    pub fn release(self: *App, context: *Context) void {
        if (context.db.poisoned) {
            context.db.close();
            context.db = Storage.open(self.database_path) catch {
                @atomicStore(bool, &context.leased, false, .release);
                return;
            };
            context.db.ready() catch {
                context.db.close();
            };
        }
        @atomicStore(bool, &context.leased, false, .release);
    }
};
