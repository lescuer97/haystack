//! Database work belongs to connection and save tasks, never the tick.
const std = @import("std");
const p = @import("shared").protocol;
const GameDb = @import("game_db.zig").GameDb;
const WorldState = @import("world_state.zig").WorldState;
const sessions = @import("sessions.zig");
const addresses = @import("chunk_address.zig");
const ChunkAddress = addresses.ChunkAddress;
const log = std.log.scoped(.game_storage);

const save_interval: std.Io.Clock.Duration = .{ .raw = .fromSeconds(5), .clock = .awake };

fn nextSaveDeadline(deadline: std.Io.Clock.Timestamp, now: std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    // Stay on the original cadence, jumping over deadlines elapsed in the flush.
    const interval = save_interval.raw.nanoseconds;
    const elapsed = deadline.durationTo(now).raw.nanoseconds;
    const periods = 1 + @divFloor(@max(0, elapsed), interval);
    return deadline.addDuration(.{ .raw = .fromNanoseconds(periods * interval), .clock = save_interval.clock });
}

pub const Pins = struct {
    items: [p.max_area_chunks]ChunkAddress = undefined,
    len: usize = 0,
};

pub const Persistence = struct {
    io: std.Io,
    db: *GameDb,
    world: *WorldState,
    registry: *sessions.Registry,
    chunk_batch: []WorldState.DirtySnapshot,
    user_batch: []sessions.UserSnapshot,
    disk_lock: std.Io.Mutex = .init,
    world_lock: std.Io.Mutex = .init,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, db: *GameDb, world: *WorldState, registry: *sessions.Registry) !Persistence {
        const chunks = try allocator.alloc(WorldState.DirtySnapshot, WorldState.cache_capacity);
        errdefer allocator.free(chunks);
        const users = try allocator.alloc(sessions.UserSnapshot, sessions.user_capacity);
        errdefer allocator.free(users);
        try registry.enablePersistence(allocator);
        errdefer registry.disablePersistence(allocator);
        world.* = try WorldState.initPersistent(allocator);
        return .{ .io = io, .db = db, .world = world, .registry = registry, .chunk_batch = chunks, .user_batch = users };
    }

    pub fn deinit(self: *Persistence, allocator: std.mem.Allocator) void {
        self.world.deinit(allocator);
        self.registry.disablePersistence(allocator);
        allocator.free(self.user_batch);
        allocator.free(self.chunk_batch);
    }

    pub fn claim(self: *Persistence, key: sessions.Pubkey, deadline: std.Io.Clock.Timestamp) !sessions.Handle {
        // Serialize with flush so a reconnect cannot race dirty-record retirement.
        try self.disk_lock.lock(self.io);
        defer self.disk_lock.unlock(self.io);
        const user = self.db.loadUser(key) catch |err| {
            log.err("cannot load player: {s}", .{@errorName(err)});
            return err;
        };
        return self.registry.claimStored(key, deadline, user);
    }

    /// Called with the hoe lock held, after ledger admission. Never take that
    /// lock from a disk-locked path. Nothing changes in memory if the write fails.
    pub fn linkChannel(self: *Persistence, handle: sessions.Handle, previous: ?[32]u8, id: [32]u8) !void {
        try self.disk_lock.lock(self.io);
        defer self.disk_lock.unlock(self.io);
        var snapshot = try self.registry.storedUser(handle);
        if (std.meta.eql(snapshot.user.hoe_channel_id, @as(?[32]u8, id))) return;
        if (!std.meta.eql(snapshot.user.hoe_channel_id, previous)) return error.ChannelLinkChanged;
        snapshot.user.hoe_channel_id = id;
        try self.db.reopenIfPoisoned();
        try self.db.saveUser(snapshot.pubkey, snapshot.user);
        self.registry.publishChannelLink(snapshot);
    }

    pub fn prepare(self: *Persistence, request: p.Request) !Pins {
        var pins = Pins{};
        errdefer self.release(&pins);
        var wanted: [p.max_area_chunks]ChunkAddress = undefined;
        var len: usize = 0;
        switch (request.operation) {
            .cut => |tile| {
                wanted[0] = ChunkAddress.fromTile(tile.x, tile.y);
                len = 1;
            },
            .read_area => |area| {
                const size = p.areaGeometry(area) catch return pins; // Tick reports the precise protocol failure.
                var iter = addresses.AreaIterator.init(area, size);
                for (wanted[0..size.count]) |*addr| addr.* = iter.next().?;
                len = size.count;
            },
            else => return pins,
        }
        var remaining: usize = 0;
        {
            try self.world_lock.lock(self.io);
            defer self.world_lock.unlock(self.io);
            for (0..len) |i| {
                const addr = wanted[i];
                if (self.world.pin(addr)) {
                    append(&pins, addr);
                } else {
                    wanted[remaining] = addr;
                    remaining += 1;
                }
            }
        }
        if (remaining == 0) return pins;

        // Recheck under a single disk lock so a stale load cannot race a write
        // and eviction of the same address. Cache-only requests bypass this lock.
        try self.disk_lock.lock(self.io);
        defer self.disk_lock.unlock(self.io);
        var players: [64]p.Location = undefined;
        const locations = self.registry.activeLocations(&players);
        for (wanted[0..remaining]) |addr| {
            try self.io.checkCancel();
            {
                try self.world_lock.lock(self.io);
                defer self.world_lock.unlock(self.io);
                if (self.world.pin(addr)) {
                    append(&pins, addr);
                    continue;
                }
            }
            const bits = self.db.loadChunk(addr) catch |err| {
                log.err("cannot load chunk ({d},{d}): {s}", .{ addr.cx, addr.cy, @errorName(err) });
                return err;
            };
            try self.world_lock.lock(self.io);
            defer self.world_lock.unlock(self.io);
            if (!self.world.installPinned(addr, bits orelse @splat(0), locations)) return error.ChunkCacheBusy;
            append(&pins, addr);
        }
        return pins;
    }

    fn append(pins: *Pins, addr: ChunkAddress) void {
        pins.items[pins.len] = addr;
        pins.len += 1;
    }

    pub fn release(self: *Persistence, pins: *Pins) void {
        if (pins.len == 0) return;
        self.world_lock.lockUncancelable(self.io);
        defer self.world_lock.unlock(self.io);
        for (pins.items[0..pins.len]) |addr| self.world.unpin(addr);
        pins.len = 0;
        self.trimOverflowLocked();
    }

    fn trimOverflowLocked(self: *Persistence) void {
        if (!self.world.hasTrimmableOverflow()) return;
        // Same world -> registry lock order as the tick. No disk work here;
        // the tick only try-locks the world guard.
        var players: [64]p.Location = undefined;
        self.world.trimOverflow(self.registry.activeLocations(&players));
    }

    pub fn saveLoop(self: *Persistence) void {
        var deadline = std.Io.Clock.Timestamp.fromNow(self.io, save_interval);
        while (true) {
            deadline.wait(self.io) catch return;
            self.flush() catch |err| log.err("periodic save failed; edits remain pending: {s}", .{@errorName(err)});
            deadline = nextSaveDeadline(deadline, .now(self.io, .awake));
        }
    }

    pub fn flush(self: *Persistence) !void {
        self.disk_lock.lockUncancelable(self.io);
        defer self.disk_lock.unlock(self.io);
        const chunks = self.snapshotChunks();
        var committed = false;
        defer {
            self.world_lock.lockUncancelable(self.io);
            defer self.world_lock.unlock(self.io);
            for (chunks) |snapshot| {
                if (committed) _ = self.world.markSaved(snapshot) else self.world.markSaveFailed(snapshot);
            }
            if (committed) self.trimOverflowLocked();
        }
        const users = self.user_batch[0..self.registry.snapshotUsers(self.user_batch)];
        if (chunks.len == 0 and users.len == 0) return;

        try self.db.reopenIfPoisoned();
        try self.db.begin();
        errdefer self.db.rollback();
        for (chunks) |chunk| try self.db.saveChunk(chunk.address, chunk.bits);
        for (users) |user| try self.db.saveUser(user.pubkey, user.user);
        try self.db.commit();
        committed = true;
        self.registry.markUsersSaved(users);
        log.debug("game state saved: chunks={d}, players={d}", .{ chunks.len, users.len });
    }

    fn snapshotChunks(self: *Persistence) []const WorldState.DirtySnapshot {
        self.world_lock.lockUncancelable(self.io);
        defer self.world_lock.unlock(self.io);
        var cursor: usize = 0;
        var count: usize = 0;
        while (self.world.nextDirty(&cursor)) |chunk| {
            self.chunk_batch[count] = chunk;
            count += 1;
        }
        return self.chunk_batch[0..count];
    }
};

test "periodic saves keep their cadence and skip elapsed deadlines" {
    const deadline: std.Io.Clock.Timestamp = .{ .raw = .fromNanoseconds(5 * std.time.ns_per_s), .clock = .awake };
    for ([_][2]i96{ .{ 0, 5 }, .{ 2, 5 }, .{ 5, 10 }, .{ 12, 15 }, .{ 72, 75 } }) |example| {
        const now = deadline.addDuration(.{ .raw = .fromNanoseconds(example[0] * std.time.ns_per_s), .clock = .awake });
        const next = nextSaveDeadline(deadline, now);
        try std.testing.expectEqual(example[1] * std.time.ns_per_s, deadline.durationTo(next).raw.nanoseconds);
    }
}
