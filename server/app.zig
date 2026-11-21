//! One exclusively leased context, independent of callback thread affinity.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const WorldState = @import("world_state.zig").WorldState;
const actions = @import("actions.zig");
const sessions = @import("sessions.zig");
pub const default_budget = 64 * 1024;

pub const CommonFailure = enum { invalid_request, server_busy };

/// The caller supplies reply storage of at least p.max_response_bytes.
pub fn encodeCommonFailure(out: []u8, req: p.Request, failure: CommonFailure) []const u8 {
    return switch (req.operation) {
        inline else => |payload, kind| shared.wire.encodeReply(out, kind, .{
            .request_id = req.request_id,
            .payload = payload,
        }, .{ .failed = switch (failure) {
            .invalid_request => .invalid_request,
            .server_busy => .server_busy,
        } }) catch unreachable,
    };
}
pub const Context = struct {
    leased: bool = false,
    state: WorldState = .{},
    response: [p.max_response_bytes]u8 = undefined,
    snapshot: p.Snapshot = undefined,
    pub fn handle(self: *Context, comptime kind: p.Kind, req: p.RequestFor(kind)) []const u8 {
        const outcome = switch (kind) {
            .cut => actions.handleCut(&self.state, req),
            .read_area => actions.handleReadArea(&self.state, &self.snapshot, req),
            else => @compileError("only cut and read_area use the world context"),
            .channel_requirements, .channel_open, .channel_payment, .channel_close => @compileError("channel requests do not use the world context"),
        };
        return shared.wire.encodeReply(&self.response, kind, req, outcome) catch unreachable;
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
    pub fn handleLocation(self: *App, handle: sessions.Handle, req: p.RequestFor(.update_location)) p.Outcome(.update_location) {
        self.registry.update(handle, req.payload) catch return .{ .failed = .invalid_request };
        return .{ .ok = {} };
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
