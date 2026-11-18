//! One exclusively leased context, independent of callback thread affinity.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const WorldState = @import("world_state.zig").WorldState;
const actions = @import("actions.zig");
const sessions = @import("sessions.zig");
pub const default_budget = 64 * 1024;
pub const Context = struct {
    leased: bool = false,
    state: WorldState = .{},
    response: [p.max_response_bytes]u8 = undefined,
    snapshot: p.Snapshot = undefined,
    pub fn handle(self: *Context, req: p.Request) []const u8 {
        return shared.wire.encode(&self.response, actions.handle(&self.state, &self.snapshot, req));
    }
};
pub const Layout = struct { context: Context, registry: sessions.Registry };
pub const App = struct {
    /// Borrowed from main, never closed here; fixtures need not provision one.
    wallet: ?*const @import("wallet.zig").Wallet = null,
    context: *Context,
    registry: *sessions.Registry,
    pub fn init(io: std.Io, buffers: []align(@alignOf(Layout)) u8) !App {
        if (buffers.len < @sizeOf(Layout)) return error.InsufficientApplicationBudget;
        const layout: *Layout = @ptrCast(buffers.ptr);
        layout.registry = .{ .io = io };
        const context = &layout.context;
        context.* = .{};
        return .{ .context = context, .registry = &layout.registry };
    }
    pub fn deinit(self: *App) void {
        // The server drains callbacks before destroying the application.
        self.registry.slots = @splat(.{});
    }
    pub fn handleLocation(self: *App, handle: sessions.Handle, req: p.Request) p.Response {
        if (req.operation != .update_location) return shared.wire.failure(req.request_id, .invalid_request);
        self.registry.update(handle, req.operation.update_location) catch return shared.wire.failure(req.request_id, .invalid_request);
        return .{ .request_id = req.request_id, .result = .location_updated };
    }
    pub fn lease(self: *App) ?*Context {
        const context = self.context;
        if (@cmpxchgStrong(bool, &context.leased, false, true, .acquire, .monotonic) != null) return null;
        return context;
    }
    pub fn release(self: *App, context: *Context) void {
        _ = self;
        @atomicStore(bool, &context.leased, false, .release);
    }
};
