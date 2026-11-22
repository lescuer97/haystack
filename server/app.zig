//! One exclusively leased context, independent of callback thread affinity.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const WorldState = @import("world_state.zig").WorldState;
const actions = @import("actions.zig");
const sessions = @import("sessions.zig");
const Persistence = @import("persistence.zig").Persistence;
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
    pub fn handle(self: *Context, comptime kind: p.Kind, req: p.RequestFor(kind), pubkey: sessions.Pubkey) []const u8 {
        const replays_before = self.state.replay_next;
        const outcome = switch (kind) {
            .cut => actions.handleCut(&self.state, req),
            .read_area => actions.handleReadArea(&self.state, &self.snapshot, req),
            else => @compileError("only cut and read_area use the world context"),
            .channel_requirements, .channel_open, .channel_payment, .channel_close => @compileError("channel requests do not use the world context"),
        };
        if (comptime std.log.logEnabled(.debug, .gameplay)) {
            const log = std.log.scoped(.gameplay);
            if (outcome == .ok) switch (kind) {
                // A cached success doesn't cut the tile again.
                .cut => if (self.state.replay_next != replays_before) {
                    log.debug("cut pubkey={s} tile=({d},{d})", .{ std.fmt.bytesToHex(pubkey, .lower), req.payload.x, req.payload.y });
                },
                .read_area => log.debug("read_area pubkey={s} chunks=({d},{d})..({d},{d})", .{
                    std.fmt.bytesToHex(pubkey, .lower),
                    req.payload.cx0,
                    req.payload.cy0,
                    req.payload.cx1,
                    req.payload.cy1,
                }),
                else => unreachable,
            };
        }
        return shared.wire.encodeReply(&self.response, kind, req, outcome) catch unreachable;
    }
};
pub const Layout = struct { context: Context, registry: sessions.Registry };
pub const App = struct {
    /// Borrowed from main, never closed here; fixtures need not provision one.
    wallet: ?*const @import("wallet.zig").Wallet = null,
    persistence: ?*Persistence = null,
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
    pub fn retainedCut(self: *App, req: p.Request) !?p.Outcome(.cut) {
        const storage = self.persistence orelse return null;
        const tile = switch (req.operation) {
            .cut => |tile| tile,
            else => return null,
        };
        try storage.world_lock.lock(storage.io);
        defer storage.world_lock.unlock(storage.io);
        return self.context.state.replayCut(.{ .request_id = req.request_id, .payload = tile });
    }
    pub fn lease(self: *App) ?*Context {
        const context = self.context;
        if (@cmpxchgStrong(bool, &context.leased, false, true, .acquire, .monotonic) != null) return null;
        if (self.persistence) |storage| {
            // Cache maintenance never makes the tick wait, even without disk I/O.
            if (!storage.world_lock.tryLock()) {
                @atomicStore(bool, &context.leased, false, .release);
                return null;
            }
        }
        return context;
    }
    pub fn release(self: *App, context: *Context) void {
        if (self.persistence) |storage| storage.world_lock.unlock(storage.io);
        @atomicStore(bool, &context.leased, false, .release);
    }
};
