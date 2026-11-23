const std = @import("std");
const shared = @import("shared");
const sqlite = @import("sqlite").c;
const p = shared.protocol;
const GameDb = @import("game_db.zig").GameDb;
const ChunkAddress = @import("chunk_address.zig").ChunkAddress;
const Persistence = @import("persistence.zig").Persistence;
const sessions = @import("sessions.zig");
const WorldState = @import("world_state.zig").WorldState;
const t = std.testing;

const key: sessions.Pubkey = @splat(0xa5);
const cut: p.RequestFor(.cut) = .{ .request_id = @splat(1), .payload = .{ .x = -1, .y = 0 } };
const area: shared.world.ChunkRange = .{ .cx0 = -1, .cy0 = 0, .cx1 = -1, .cy1 = 0 };
const cut_address: ChunkAddress = .{ .cx = area.cx0, .cy = area.cy0 };
const cut_bits: [32]u8 = .{ 0, 0x80 } ++ @as([30]u8, @splat(0));

const Game = struct {
    db: GameDb,
    world: WorldState,
    registry: sessions.Registry,
    persistence: Persistence,

    fn open(self: *Game, path: [:0]const u8) !void {
        self.db = try GameDb.open(path);
        errdefer self.db.close();
        self.registry = .{ .io = t.io };
        self.persistence = try Persistence.init(t.io, t.allocator, &self.db, &self.world, &self.registry);
    }

    fn close(self: *Game) void {
        self.persistence.deinit(t.allocator);
        self.db.close();
    }

    fn claimPlayer(self: *Game) !sessions.Handle {
        const deadline: std.Io.Clock.Timestamp = .fromNow(t.io, .{ .raw = .fromSeconds(60), .clock = .awake });
        const handle = try self.persistence.claim(key, deadline);
        self.registry.confirm(handle);
        return handle;
    }

    fn cutAndMove(self: *Game) !p.Location {
        const handle = try self.claimPlayer();
        defer self.registry.release(handle);
        {
            var pins = try self.persistence.prepare(.{ .request_id = cut.request_id, .operation = .{ .cut = cut.payload } });
            defer self.persistence.release(&pins);
            try t.expectEqual(@as(usize, 1), pins.len);
            try t.expectEqual(cut_address, pins.items[0]);
            try t.expectEqual(@as(usize, 1), self.world.chunk_count);
            try t.expect((try self.world.cut(cut)) == .ok);
        }

        const from = self.registry.get(handle).?.location.?;
        for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |delta| {
            const to: p.Location = .{ .x = from.x + delta[0], .y = from.y + delta[1] };
            if (shared.movement.canStep(from, to)) {
                try self.registry.update(handle, to);
                return to;
            }
        }
        return error.NoCardinalExit;
    }
};

fn tempPath(tmp: *const t.TmpDir) ![:0]const u8 {
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    return std.fmt.allocPrintSentinel(t.allocator, "{s}/game.sqlite3", .{dir}, 0);
}

test "persistence restores a player and lazily loads the cut bitmap after reopen" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp);
    defer t.allocator.free(path);

    const moved = saved: {
        var game: Game = undefined;
        try game.open(path);
        defer game.close();
        try t.expectEqual(@as(usize, 0), game.world.chunk_count);
        const moved = try game.cutAndMove();
        try game.persistence.flush();
        break :saved moved;
    };

    var game: Game = undefined;
    try game.open(path);
    defer game.close();
    try t.expectEqual(@as(usize, 0), game.world.chunk_count);
    const handle = try game.claimPlayer();
    defer game.registry.release(handle);
    try t.expectEqualDeep(@as(?p.Location, moved), game.registry.get(handle).?.location);
    var users: [1]sessions.UserSnapshot = undefined;
    try t.expectEqual(@as(usize, 0), game.registry.snapshotUsers(&users));
    try t.expectEqual(@as(usize, 0), game.world.chunk_count);

    var pins = try game.persistence.prepare(.{ .request_id = @splat(2), .operation = .{ .read_area = area } });
    defer game.persistence.release(&pins);
    try t.expectEqual(@as(usize, 1), pins.len);
    try t.expectEqual(@as(usize, 1), game.world.chunk_count);
    var snapshot: p.Snapshot = undefined;
    try game.world.readArea(area, &snapshot);
    try t.expectEqual(@as(u16, 1), snapshot.count);
    try t.expectEqual(cut_bits, snapshot.chunks[0]);
}

test "persistence keeps the chunk and user pending after a busy flush and saves both on retry" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp);
    defer t.allocator.free(path);

    var game: Game = undefined;
    try game.open(path);
    defer game.close();
    const moved = try game.cutAndMove();
    var users: [1]sessions.UserSnapshot = undefined;
    {
        var blocker = try GameDb.open(path);
        defer blocker.close();
        try blocker.begin();
        defer blocker.rollback();

        try t.expectError(error.SqliteBusy, game.persistence.flush());
        try t.expectEqual(null, try blocker.loadChunk(cut_address));
        try t.expectEqual(null, try blocker.loadUser(key));
        try t.expectEqual(@as(usize, 1), game.registry.snapshotUsers(&users));
        try t.expectEqual(key, users[0].pubkey);
        try t.expectEqualDeep(moved, users[0].user.location);
        var cursor: usize = 0;
        const chunk = game.world.nextDirty(&cursor) orelse return error.MissingPendingChunk;
        defer game.world.markSaveFailed(chunk);
        try t.expectEqual(cut_address, chunk.address);
        try t.expectEqual(cut_bits, chunk.bits);
    }

    try game.persistence.flush();
    try t.expectEqual(@as(?[32]u8, cut_bits), try game.db.loadChunk(cut_address));
    const user = (try game.db.loadUser(key)) orelse return error.MissingSavedUser;
    try t.expectEqualDeep(moved, user.location);
    try t.expectEqual(@as(usize, 0), game.registry.snapshotUsers(&users));
    var cursor: usize = 0;
    try t.expectEqual(null, game.world.nextDirty(&cursor));
}

test "persistence drains overflow on connection release and on successful save" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp);
    defer t.allocator.free(path);
    var game: Game = undefined;
    try game.open(path);
    defer game.close();

    const base = WorldState.cache_base_capacity;
    for (0..base + 1) |i| try t.expect(game.world.installPinned(.{ .cx = @intCast(i), .cy = 0 }, @splat(0), &.{}));
    var dirty = try game.persistence.prepare(.{ .request_id = cut.request_id, .operation = .{ .cut = cut.payload } });
    try t.expect((try game.world.cut(cut)) == .ok);
    game.persistence.release(&dirty);
    try t.expectEqual(base + 2, game.world.chunk_count); // Releasing a dirty row cannot free it.

    const clean_addr: ChunkAddress = .{ .cx = 0, .cy = 0 };
    try t.expect(game.world.pin(clean_addr));
    var clean = @import("persistence.zig").Pins{};
    clean.items[0] = clean_addr;
    clean.len = 1;
    game.persistence.release(&clean);
    try t.expectEqual(base + 2, game.world.chunk_count); // One pin remains.
    clean.len = 1;
    game.persistence.release(&clean);
    try t.expectEqual(base + 1, game.world.chunk_count);
    try t.expect(!game.world.pin(clean_addr));

    // The dirty row is beyond the new occupancy, with a hole before it.
    // A failed write must not drain it; a committed write does.
    {
        var blocker = try GameDb.open(path);
        defer blocker.close();
        try blocker.begin();
        defer blocker.rollback();
        try t.expectError(error.SqliteBusy, game.persistence.flush());
        try t.expectEqual(base + 1, game.world.chunk_count);
    }
    try game.persistence.flush();
    try t.expectEqual(base, game.world.chunk_count);
    try t.expect(!game.world.pin(cut_address));
    try t.expectEqual(@as(?[32]u8, cut_bits), try game.db.loadChunk(cut_address));
}

test "persistence prepares rectangular areas in snapshot bitmap order" {
    var game: Game = undefined;
    try game.open(":memory:");
    defer game.close();
    const rectangle: shared.world.ChunkRange = .{ .cx0 = -2, .cy0 = -1, .cx1 = 0, .cy1 = 0 };
    const ordered = [_]ChunkAddress{
        .{ .cx = -2, .cy = -1 }, .{ .cx = -1, .cy = -1 }, .{ .cx = 0, .cy = -1 },
        .{ .cx = -2, .cy = 0 },  .{ .cx = -1, .cy = 0 },  .{ .cx = 0, .cy = 0 },
    };
    for (ordered, 1..) |addr, i| try game.db.saveChunk(addr, @splat(@intCast(i)));
    var pins = try game.persistence.prepare(.{ .request_id = @splat(0), .operation = .{ .read_area = rectangle } });
    defer game.persistence.release(&pins);
    try t.expectEqualSlices(ChunkAddress, &ordered, pins.items[0..pins.len]);
    var snapshot: p.Snapshot = undefined;
    try game.world.readArea(rectangle, &snapshot);
    try t.expectEqual(ordered.len, snapshot.count);
    for (snapshot.chunks[0..snapshot.count], 1..) |bits, i| {
        try t.expectEqual(@as([32]u8, @splat(@intCast(i))), bits);
    }
}

fn failUserWriteAndRollback(_: ?*anyopaque, action: c_int, arg: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
    if (arg == null) return sqlite.SQLITE_OK;
    const name = std.mem.span(arg);
    if ((action == sqlite.SQLITE_INSERT and std.mem.eql(u8, name, "game_users")) or
        (action == sqlite.SQLITE_TRANSACTION and std.mem.eql(u8, name, "ROLLBACK"))) return sqlite.SQLITE_DENY;
    return sqlite.SQLITE_OK;
}

test "persistence discards a connection that cannot roll back and retries both pending edits" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp);
    defer t.allocator.free(path);

    var game: Game = undefined;
    try game.open(path);
    defer game.close();
    const kept_address: ChunkAddress = .{ .cx = 42, .cy = -7 };
    const kept_bits: [32]u8 = @splat(0xe1);
    try game.db.saveChunk(kept_address, kept_bits);
    const moved = try game.cutAndMove();
    // The chunk upsert succeeds before the authorizer denies the user upsert
    // and explicit rollback. The fault is local to that connection.
    try t.expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_set_authorizer(@ptrCast(game.db.db.?), failUserWriteAndRollback, null));
    try t.expectError(error.SqliteFailure, game.persistence.flush());
    try t.expectError(error.GameDatabasePoisoned, game.db.loadChunk(cut_address));
    {
        var observer = try GameDb.open(path);
        defer observer.close();
        try observer.begin(); // The failed transaction didn't retain the write lock.
        defer observer.rollback();
        try t.expectEqual(null, try observer.loadChunk(cut_address));
        try t.expectEqual(null, try observer.loadUser(key));
    }

    // A failed reopen must not create a fresh database or retire this batch.
    try tmp.dir.rename("game.sqlite3", tmp.dir, "original.sqlite3", t.io);
    try t.expectError(error.SqliteCannotOpen, game.persistence.flush());
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "game.sqlite3", .{}));
    try tmp.dir.rename("original.sqlite3", tmp.dir, "game.sqlite3", t.io);

    try game.persistence.flush();
    try t.expectEqual(cut_bits, (try game.db.loadChunk(cut_address)).?);
    try t.expectEqual(kept_bits, (try game.db.loadChunk(kept_address)).?);
    try t.expectEqual(moved, (try game.db.loadUser(key)).?.location);
    var users: [1]sessions.UserSnapshot = undefined;
    try t.expectEqual(@as(usize, 0), game.registry.snapshotUsers(&users));
    var cursor: usize = 0;
    try t.expectEqual(null, game.world.nextDirty(&cursor));
}
