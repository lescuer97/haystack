//! Synchronous write owns the context until complete. Error replies use fixed stack storage.
const ws = @import("websocket");
const wire = @import("shared").wire;
pub const App = @import("app.zig").App;
const sessions = @import("sessions.zig");
pub const Handler = struct {
    conn: *ws.Conn,
    app: *App,
    session: sessions.Handle,
    pub fn init(handshake: *ws.Handshake, conn: *ws.Conn, app: *App) !Handler {
        const key = try sessions.parsePubkey(handshake.url);
        // FIXME: verify pubkey ownership before using this identity for authorization.
        // Public, unverified keys permit key-squatting; this is not authentication.
        const session = try app.registry.claim(key);
        return .{ .conn = conn, .app = app, .session = session };
    }
    pub fn close(self: *Handler) void {
        self.app.registry.release(self.session);
    }
    pub fn clientMessage(self: *Handler, data: []u8, tpe: ws.MessageTextType) !void {
        var error_storage: [33]u8 = undefined;
        switch (wire.decodeMessage(data, tpe == .binary)) {
            .failure => |f| try self.conn.writeBin(wire.encode(&error_storage, f)),
            .request => |req| {
                if (req.operation == .update_location) {
                    const response = self.app.handleLocation(self.session, req);
                    try self.conn.writeBin(wire.encode(&error_storage, response));
                    if (response.result == .failure) return error.StaleSession;
                    return;
                }
                const context = self.app.lease() orelse {
                    try self.conn.writeBin(wire.encode(&error_storage, wire.failure(req.request_id, .database_busy)));
                    return;
                };
                defer self.app.release(context);
                try self.conn.writeBin(context.handle(req));
            },
        }
    }
};
