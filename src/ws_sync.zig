//! Shared frame-side reconciliation for desktop and browser connections.
const std = @import("std");
const shared = @import("shared");
const game_mod = @import("game.zig");
const frame_loop = @import("frame_loop.zig");
const world = @import("world.zig");
const protocol = shared.protocol;

pub const ToolChannel = struct {
    id: [32]u8,
    capacity_msats: u64,
    balance_msats: u64,
    player: [33]u8,
};
pub const ToolLogin = struct { player: [33]u8, channel: ?ToolChannel };
pub const ToolChannels = [protocol.tools.len]?ToolChannel;

pub fn toolStates(connection: anytype, session: u64) game_mod.ToolStates {
    var states: game_mod.ToolStates = @splat(.{});
    for (protocol.tools) |tool| {
        const login = connection.toolLogin(session, tool) orelse continue;
        states[@backingInt(tool)] = if (login.channel) |channel|
            .{ .uses_left = (channel.capacity_msats - channel.balance_msats) / tool.priceMsat(), .has_channel = true }
        else
            .{ .uses_left = 0 };
    }
    return states;
}

// Only an acknowledged, matching charge advances the cached login balance.
pub fn applyCutBalance(channels: *ToolChannels, tile: protocol.Cut, outcome: protocol.Outcome(.cut)) void {
    if (outcome != .ok or !outcome.ok.cut or outcome.ok.terrain != tile.tool.terrain() or
        outcome.ok.x != tile.x or outcome.ok.y != tile.y) return;
    const payment = tile.payment orelse return;
    if (channels[@backingInt(tile.tool)]) |*channel| {
        if (!std.mem.eql(u8, &channel.id, &payment.id) or payment.amount > channel.capacity_msats or
            payment.amount < channel.balance_msats or payment.amount - channel.balance_msats != tile.tool.priceMsat()) return;
        channel.balance_msats = payment.amount;
    }
}

test "tool uses are session-scoped and only a matching paid cut updates its slot" {
    const Connection = struct {
        channels: ToolChannels = @splat(null),

        fn toolLogin(self: *const @This(), session: u64, tool: protocol.tool) ?ToolLogin {
            if (session != 1) return null;
            return .{ .player = @splat(0), .channel = self.channels[@backingInt(tool)] };
        }
    };
    var connection: Connection = .{};
    const axe = @backingInt(protocol.tool.axe);
    const hoe = @backingInt(protocol.tool.hoe);
    connection.channels[axe] = .{ .id = @splat(1), .capacity_msats = 4, .balance_msats = 2, .player = @splat(0) };
    try std.testing.expectEqual(@as(?u64, null), toolStates(&connection, 0)[axe].uses_left);
    try std.testing.expectEqual(@as(?u64, 1), toolStates(&connection, 1)[axe].uses_left);
    try std.testing.expectEqual(@as(?u64, 0), toolStates(&connection, 1)[hoe].uses_left);
    try std.testing.expect(!toolStates(&connection, 1)[hoe].has_channel);
    const cut: protocol.Cut = .{ .x = 2, .y = 3, .tool = .axe, .payment = .{ .id = @splat(1), .amount = 4, .signature = @splat(0) } };
    const tile: protocol.State = .{ .x = 2, .y = 3, .terrain = .tree, .cut = true };
    applyCutBalance(&connection.channels, cut, .{ .failed = .{ .already_cut = tile } });
    try std.testing.expectEqual(@as(?u64, 1), toolStates(&connection, 1)[axe].uses_left);
    applyCutBalance(&connection.channels, cut, .{ .ok = tile });
    try std.testing.expectEqual(@as(?u64, 0), toolStates(&connection, 1)[axe].uses_left);
    try std.testing.expect(toolStates(&connection, 1)[axe].has_channel);
}

pub const AuthRestore = struct {
    location: protocol.Location,
    channels: ToolChannels = @splat(null),
    player: ?[33]u8 = null,

    pub fn fromReply(reply: protocol.AuthOutcome, player: [33]u8) ?AuthRestore {
        var channels: ToolChannels = @splat(null);
        const location = switch (reply) {
            .failed => return null,
            .ok => |location| location,
            .ok_with_hoe_channel => |success| blk: {
                channels[@backingInt(protocol.tool.hoe)] = .{
                    .id = success.hoe_channel_id,
                    .capacity_msats = success.hoe_channel_capacity_msat,
                    .balance_msats = success.hoe_channel_balance_msat,
                    .player = player,
                };
                break :blk success.location;
            },
            .ok_with_tool_channels => |success| blk: {
                for (success.channels, &channels) |entry, *out| if (entry) |channel| {
                    out.* = .{
                        .id = channel.id,
                        .capacity_msats = channel.capacity_msat,
                        .balance_msats = channel.balance_msat,
                        .player = player,
                    };
                };
                break :blk success.location;
            },
        };
        return .{ .location = location, .channels = channels, .player = player };
    }
};

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

const PrizeNotice = @import("wallet_ui.zig").PrizeNotice;
pub const PrizeInbox = struct {
    const capacity = 4;
    notices: [capacity]PrizeNotice = undefined,
    head: usize = 0,
    count: usize = 0,
    deferred: bool = false,

    pub fn push(self: *PrizeInbox, tile: protocol.Location, bytes: []const u8) !void {
        if (bytes.len == 0 or bytes.len > protocol.max_prize_token_bytes or std.mem.indexOfScalar(u8, bytes, 0) != null)
            return error.InvalidPrizeToken;
        if (self.count == capacity) {
            // Do not disconnect before the accepted batch can be collected and ACKed.
            // These unacknowledged prizes remain eligible for server redelivery.
            self.deferred = true;
            return;
        }
        const notice = &self.notices[(self.head + self.count) % capacity];
        notice.* = .{ .tile = tile, .token = .{} };
        _ = notice.token.set(bytes);
        self.count += 1;
    }

    pub fn take(self: *PrizeInbox) ?PrizeNotice {
        if (self.count == 0) return null;
        const notice = self.notices[self.head];
        std.crypto.secureZero(u8, std.mem.asBytes(&self.notices[self.head]));
        self.head = (self.head + 1) % capacity;
        self.count -= 1;
        return notice;
    }

    pub fn takeDeferred(self: *PrizeInbox) bool {
        defer self.deferred = false;
        return self.deferred;
    }

    pub fn clear(self: *PrizeInbox) void {
        for (0..self.count) |i| std.crypto.secureZero(u8, std.mem.asBytes(&self.notices[(self.head + i) % capacity]));
        self.head = 0;
        self.count = 0;
        self.deferred = false;
    }
};

test "prize inbox owns borrowed frame bytes and clears on disconnect" {
    const t = std.testing;
    var inbox: PrizeInbox = .{};
    defer inbox.clear();
    const tile: protocol.Location = .{ .x = -1, .y = 2 };
    var token = "cashuBtest".*;
    try inbox.push(tile, &token);
    @memset(&token, 0);
    const notice = inbox.take().?;
    try t.expectEqual(tile, notice.tile);
    try t.expectEqualStrings("cashuBtest", notice.token.slice());
    try inbox.push(tile, notice.token.slice());
    inbox.clear();
    try t.expect(inbox.take() == null);
}

test "prize inbox keeps a bounded FIFO batch and defers the excess until reconnect" {
    const t = std.testing;
    var inbox: PrizeInbox = .{};
    defer inbox.clear();
    const token: [protocol.max_prize_token_bytes]u8 = @splat('x');
    for (0..PrizeInbox.capacity + 1) |i| try inbox.push(.{ .x = @intCast(i), .y = 0 }, &token);
    try t.expect(inbox.takeDeferred());
    try t.expect(!inbox.takeDeferred());
    for (0..PrizeInbox.capacity) |i| {
        const notice = inbox.take().?;
        try t.expectEqual(@as(i32, @intCast(i)), notice.tile.x);
        try t.expectEqualStrings(&token, notice.token.slice());
    }
    try t.expect(inbox.take() == null);
    inbox.clear();
    const deferred: protocol.Location = .{ .x = PrizeInbox.capacity, .y = 0 };
    try inbox.push(deferred, &token);
    try t.expectEqual(deferred, inbox.take().?.tile);
    try t.expect(!inbox.takeDeferred());
}

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
