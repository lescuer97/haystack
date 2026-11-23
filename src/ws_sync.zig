//! Shared frame-side reconciliation for desktop and browser connections.
const std = @import("std");
const shared = @import("shared");
const game_mod = @import("game.zig");
const frame_loop = @import("frame_loop.zig");
const world = @import("world.zig");
const protocol = shared.protocol;

pub const AreaCompletion = enum { snapshot, server_busy };

/// One bounded exchange per connection. The native worker guards this with
/// its mailbox mutex; the browser owns it on the event loop.
pub const AreaMailbox = union(enum) {
    idle,
    queued: world.ChunkRange,
    waiting,
    received: protocol.Snapshot,
    server_busy,

    pub fn request(self: *AreaMailbox, range: world.ChunkRange) bool {
        if (self.* != .idle) return false;
        self.* = .{ .queued = range };
        return true;
    }

    pub fn start(self: *AreaMailbox) ?world.ChunkRange {
        if (self.* != .queued) return null;
        const range = self.queued;
        self.* = .waiting;
        return range;
    }

    pub fn complete(self: *AreaMailbox, result: AreaCompletion, snapshot: *const protocol.Snapshot) void {
        std.debug.assert(self.* == .waiting);
        self.* = switch (result) {
            .snapshot => .{ .received = snapshot.* },
            .server_busy => .server_busy,
        };
    }

    pub fn take(self: *AreaMailbox, dest: *protocol.Snapshot) ?AreaCompletion {
        const result: AreaCompletion = switch (self.*) {
            .received => |*snapshot| blk: {
                dest.* = snapshot.*;
                break :blk .snapshot;
            },
            .server_busy => .server_busy,
            else => return null,
        };
        self.* = .idle;
        return result;
    }
};

// The server dispatches one gameplay request per connection at a time.
pub const PlayRequest = struct {
    id: protocol.Id,
    operation: Operation,

    pub const Operation = union(enum) { move: protocol.Location, area: world.ChunkRange };
    const Result = union(enum) { move: ?protocol.Location, area: AreaCompletion };

    pub fn encode(self: PlayRequest, out: []u8) ![]const u8 {
        return switch (self.operation) {
            .move => |pos| shared.wire.encodeRequest(out, .update_location, .{ .request_id = self.id, .payload = pos }),
            .area => |range| shared.wire.encodeRequest(out, .read_area, .{ .request_id = self.id, .payload = range }),
        };
    }

    pub fn decode(self: PlayRequest, bytes: []const u8, scratch: *protocol.Snapshot) !Result {
        return switch (self.operation) {
            .move => |pos| .{ .move = if (try shared.wire.decodeReply(bytes, .update_location, self.id, scratch) == .ok) pos else null },
            .area => |range| blk: {
                const outcome = try shared.wire.decodeReply(bytes, .read_area, self.id, scratch);
                switch (outcome) {
                    .failed => |failure| {
                        if (failure != .server_busy) return error.AreaRequestFailed;
                        break :blk .{ .area = .server_busy };
                    },
                    .ok => |snapshot| {
                        if (!std.meta.eql(range, snapshot.area)) return error.UnexpectedArea;
                        break :blk .{ .area = .snapshot };
                    },
                }
            },
        };
    }
};

pub const Status = enum { disabled, connecting, authenticating, ready, retrying, wallet_error, credentials_rejected };
pub const Snapshot = struct {
    status: Status = .disabled,
    session: u64 = 0,
    confirmed: shared.protocol.Location = shared.movement.spawn,
    pending: bool = false,
};

pub const Presentation = union(enum) {
    playing,
    loading_visible,
    disconnected: [:0]const u8,

    pub fn blocksInput(self: Presentation) bool {
        return self == .disconnected;
    }
};

pub const Frame = struct {
    status: Status = .disabled,
    session: u64 = 0,
    area_pending: bool = false,
    loading_visible: bool = false,

    // Reconcile ready replies before input or rendering, even if the view needs rebuilding.
    pub fn apply(self: *Frame, network: Snapshot, connection: anytype, driver: *frame_loop.Driver, game: *game_mod.GameState) !Presentation {
        if ((self.status == .ready) != (network.status == .ready)) {
            driver.invalidateInput();
            game.camera.resetDrag();
            game.player_walking = false;
        }
        const new_session = network.status == .ready and (self.status != .ready or network.session != self.session);
        if (new_session or (self.status == .ready and network.status != .ready)) {
            game.world.invalidateCuts();
            self.area_pending = false;
            self.loading_visible = new_session;
        }
        self.status = network.status;
        if (network.status == .ready and (new_session or
            (!network.pending and !std.meta.eql(game.player_pos, network.confirmed))))
        {
            try game.camera.setTarget(network.confirmed.x, network.confirmed.y);
            game.camera.resetDrag();
            game.player_pos = network.confirmed;
            game.player_walking = false;
            driver.invalidateInput();
            driver.view = null;
        }
        self.session = network.session;
        driver.movement_blocked = network.pending;
        if (self.status == .ready and self.area_pending) {
            var reply: protocol.Snapshot = undefined;
            if (connection.takeArea(self.session, &reply)) |completion| {
                if (completion == .snapshot) game.world.applyCuts(&reply);
                // Busy leaves the chunks unsynced; plan again after the local frame.
                self.area_pending = false;
            }
        }
        return switch (network.status) {
            .disabled => .playing,
            .ready => if (self.loading_visible) .loading_visible else .playing,
            .connecting => .{ .disconnected = "Connecting to the game server..." },
            .authenticating => .{ .disconnected = "Authenticating your wallet..." },
            .retrying => .{ .disconnected = "Server unavailable. Retrying..." },
            .wallet_error => .{ .disconnected = "Could not sign with the wallet. Retrying..." },
            .credentials_rejected => .{ .disconnected = "Server rejected the wallet proof. Retrying..." },
        };
    }

    // Called after preparing the current view, including the restored camera.
    pub fn requestAreas(self: *Frame, connection: anytype, driver: *const frame_loop.Driver, w: *const world.World) void {
        if (self.status != .ready or self.area_pending) return;
        const view = driver.view orelse return;
        const limit = @TypeOf(connection.*).area_limit;
        const visible = w.nextCutArea(view.chunks, limit);
        self.loading_visible = visible != null and self.loading_visible;
        const range = visible orelse w.nextCutArea(world.residencyRange(view.chunks, if (view.minimap) |map| map.chunks else null), limit) orelse return;
        self.area_pending = connection.requestArea(self.session, range);
    }
};

test "area replies reconcile before planning from the current view, with nonblocking busy retries" {
    const t = std.testing;
    const Connection = struct {
        pub const area_limit = 5;
        area: ?world.ChunkRange = null,
        reply: AreaMailbox = .idle,
        requests: usize = 0,

        pub fn requestArea(self: *@This(), _: u64, range: world.ChunkRange) bool {
            self.area = range;
            self.requests += 1;
            return true;
        }
        pub fn takeArea(self: *@This(), _: u64, dest: *protocol.Snapshot) ?AreaCompletion {
            return self.reply.take(dest);
        }
    };
    var game = try game_mod.GameState.init(t.allocator, 1000, 640);
    defer game.deinit();
    var driver: frame_loop.Driver = .{};
    defer driver.deinit();
    var frame: Frame = .{};
    var connection: Connection = .{};
    var network: Snapshot = .{ .status = .ready, .session = 1, .confirmed = .{ .x = -201, .y = 110 } };
    try t.expect(try frame.apply(network, &connection, &driver, &game) == .loading_visible);
    try t.expectEqual(network.confirmed, game.player_pos);
    try t.expectEqual(network.confirmed.x, game.camera.tile_x);
    try t.expectEqual(network.confirmed.y, game.camera.tile_y);
    frame.requestAreas(&connection, &driver, &game.world);
    try t.expect(connection.area == null);
    try driver.prepare(&game, 1000, 640);
    const visible = driver.view.?.chunks;
    frame.requestAreas(&connection, &driver, &game.world);
    const first = connection.area.?;
    try t.expect(visible.contains(first.cx0, first.cy0) and visible.contains(first.cx1, first.cy1));

    for (0..2) |attempt| {
        connection.reply = .server_busy;
        const presentation = try frame.apply(network, &connection, &driver, &game);
        try t.expect(presentation == .loading_visible);
        try t.expect(!presentation.blocksInput());
        try t.expect(!driver.movement_blocked);
        try t.expect(game.world.get(first.cx0, first.cy0).?.cuts == null);
        if (attempt == 1) {
            var escape: @import("input.zig").RawSample = .{ .frame = .{ .escape_clicked = true } };
            var privacy_blocked = false;
            driver.queue.push(&escape);
            try t.expect(try driver.advance(0, &game, null, null, &privacy_blocked));
            try t.expect(game.menu.opened);
        }
        frame.requestAreas(&connection, &driver, &game.world);
        try t.expectEqual(first, connection.area.?);
    }

    for (0..@intCast(visible.count())) |_| {
        if (!frame.loading_visible) break;
        const area = connection.area.?;
        try t.expect(visible.contains(area.cx0, area.cy0) and visible.contains(area.cx1, area.cy1));
        const geo = try protocol.areaGeometry(area);
        try t.expect(geo.count <= Connection.area_limit);
        connection.reply = .{ .received = .{ .area = area, .count = geo.count } };
        connection.reply.received.chunks[0][31] = 0x80;
        const requests_before = connection.requests;
        // A ready reply is applied before the frame even if it has no prepared view.
        driver.view = null;
        _ = try frame.apply(network, &connection, &driver, &game);
        try t.expect(game.world.get(area.cx0, area.cy0).?.isCut(255));
        try t.expectEqual(requests_before, connection.requests);
        try driver.prepare(&game, 1000, 640);
        frame.requestAreas(&connection, &driver, &game.world);
    }
    try t.expect(!frame.loading_visible);
    try t.expect(!visible.contains(connection.area.?.cx0, connection.area.?.cy0));
    try t.expect(game.world.get(first.cx0, first.cy0).?.isCut(255));
    try t.expect(try frame.apply(network, &connection, &driver, &game) == .playing);

    const prefetch = connection.area.?;
    const requests = connection.requests;
    connection.reply = .server_busy;
    try t.expect(try frame.apply(network, &connection, &driver, &game) == .playing);
    try t.expectEqual(requests, connection.requests);
    try t.expect(game.world.get(prefetch.cx0, prefetch.cy0).?.cuts == null);
    try t.expectEqual(network.session, frame.session);

    // A pan between reconciliation and planning changes which area comes next.
    try game.camera.setTarget(network.confirmed.x + world.CHUNK_TILES, network.confirmed.y);
    try driver.prepare(&game, 1000, 640);
    frame.requestAreas(&connection, &driver, &game.world);
    try t.expectEqual(requests + 1, connection.requests);
    const panned = connection.area.?;
    try t.expect(driver.view.?.chunks.contains(panned.cx0, panned.cy0));
    try t.expect(!std.meta.eql(prefetch, panned));

    // A fast reconnect can move directly from one ready session to the next.
    try t.expect(game.world.get(first.cx0, first.cy0).?.isCut(255));
    network.session += 1;
    try t.expect(try frame.apply(network, &connection, &driver, &game) == .loading_visible);
    try t.expect(game.world.get(first.cx0, first.cy0).?.isCut(255));
    try t.expect(!game.world.get(first.cx0, first.cy0).?.cutsSynced());
    try driver.prepare(&game, 1000, 640);
    frame.requestAreas(&connection, &driver, &game.world);
    try t.expectEqual(first, connection.area.?);
    connection.reply = .{ .received = .{ .area = first, .count = (try protocol.areaGeometry(first)).count } };
    connection.reply.received.chunks[0][31] = 0x80;
    _ = try frame.apply(network, &connection, &driver, &game);
    try t.expect(game.world.get(first.cx0, first.cy0).?.cutsSynced());
    try t.expect(game.world.get(first.cx0, first.cy0).?.isCut(255));

    network.status = .authenticating;
    try t.expect((try frame.apply(network, &connection, &driver, &game)).blocksInput());
    try t.expect(game.world.get(first.cx0, first.cy0).?.isCut(255));
    try t.expect(!game.world.get(first.cx0, first.cy0).?.cutsSynced());
    const requests_before_auth = connection.requests;
    frame.requestAreas(&connection, &driver, &game.world);
    try t.expectEqual(requests_before_auth, connection.requests);

    network.status = .ready;
    network.session += 1;
    network.confirmed = .{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32) };
    try t.expect(try frame.apply(network, &connection, &driver, &game) == .loading_visible);
    try t.expectEqual(network.confirmed, game.player_pos);
    try driver.prepare(&game, 1000, 640);
    const edge = driver.view.?.chunks;
    try t.expectEqual(protocol.max_chunk, edge.cx1);
    try t.expectEqual(protocol.min_chunk, edge.cy0);
    frame.requestAreas(&connection, &driver, &game.world);
    try t.expectEqual(requests_before_auth + 1, connection.requests);
    _ = try protocol.areaGeometry(connection.area.?);
}

test "area replies must match both the request id and rectangle" {
    const t = std.testing;
    const area: world.ChunkRange = .{ .cx0 = -1, .cy0 = 5, .cx1 = -1, .cy1 = 5 };
    var request: PlayRequest = .{ .id = @splat(1), .operation = .{ .area = area } };
    const snapshot: protocol.Snapshot = .{ .area = area, .count = 1 };
    var out: [protocol.max_response_bytes]u8 = undefined;
    const bytes = try shared.wire.encodeReply(&out, .read_area, .{ .request_id = request.id, .payload = area }, .{ .ok = &snapshot });
    var scratch: protocol.Snapshot = undefined;
    try t.expectEqual(AreaCompletion.snapshot, (try request.decode(bytes, &scratch)).area);
    try t.expectEqualDeep(snapshot, scratch);
    request.operation.area = area.expanded(1);
    try t.expectError(error.UnexpectedArea, request.decode(bytes, &scratch));
    request.id[0] = 2;
    try t.expectError(error.UnexpectedRequestId, request.decode(bytes, &scratch));
}

test "only a correlated server_busy area failure is retryable" {
    const t = std.testing;
    const area: world.ChunkRange = .{ .cx0 = 0, .cy0 = 0, .cx1 = 0, .cy1 = 0 };
    var request: PlayRequest = .{ .id = @splat(1), .operation = .{ .area = area } };
    var out: [protocol.max_response_bytes]u8 = undefined;
    var scratch: protocol.Snapshot = undefined;
    const req: protocol.RequestFor(.read_area) = .{ .request_id = request.id, .payload = area };
    const busy = try shared.wire.encodeReply(&out, .read_area, req, .{ .failed = .server_busy });
    try t.expectEqual(AreaCompletion.server_busy, (try request.decode(busy, &scratch)).area);
    request.id[0] = 2;
    try t.expectError(error.UnexpectedRequestId, request.decode(busy, &scratch));
    request.id = req.request_id;
    const invalid = try shared.wire.encodeReply(&out, .read_area, req, .{ .failed = .invalid_area });
    try t.expectError(error.AreaRequestFailed, request.decode(invalid, &scratch));
}
