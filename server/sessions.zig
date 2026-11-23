//! Bounded verified sessions and pending player state for batched persistence.
const std = @import("std");
const shared = @import("shared");
const game_db = @import("game_db.zig");
const LiveHoeChannel = @import("native_storage").wallet_service.LiveHoeChannel;
const Location = shared.protocol.Location;
const Tool = shared.protocol.tool;
pub const Pubkey = [33]u8;
pub const SettlementQueue = std.Io.Queue([32]u8);
pub const Handle = struct { index: usize, generation: u64 };
pub const SessionSnapshot = struct {
    pubkey: Pubkey,
    location: ?Location,
    hoe_channel_id: ?[32]u8 = null,
    axe_channel_id: ?[32]u8 = null,
    pickaxe_channel_id: ?[32]u8 = null,

    /// Profile pointer only; validate it against the channel ledger before use.
    pub fn channelId(self: SessionSnapshot, tool: Tool) ?[32]u8 {
        return switch (tool) {
            .hoe => self.hoe_channel_id,
            .axe => self.axe_channel_id,
            .pickaxe => self.pickaxe_channel_id,
        };
    }
};
pub const user_capacity = 1024;
pub const UserSnapshot = struct { pubkey: Pubkey, user: game_db.User, index: usize };

pub const Registry = struct {
    const Slot = struct {
        occupied: bool = false,
        generation: u64 = 0,
        pubkey: Pubkey = @splat(0),
        location: ?Location = null,
        user_index: ?usize = null,
        channels: std.EnumArray(Tool, ?*LiveHoeChannel) = .initFill(null),
        settlements: ?*SettlementQueue = null,

        fn clearChannels(self: *Slot) void {
            for (&self.channels.values) |*channel| {
                if (channel.*) |live| live.deinit();
                channel.* = null;
            }
        }
    };
    const UserRecord = struct {
        pubkey: Pubkey,
        user: game_db.User,
        active: bool = true,
        dirty: bool = false,
        provisional: bool,
    };
    const Claim = enum { ephemeral, durable };

    io: std.Io,
    mutex: std.Io.Mutex = .init,
    generation: u64 = 0,
    slots: [64]Slot = @splat(.{}),
    users: []?UserRecord = &.{},

    /// Allocates the durable records once. Disable with the same allocator.
    pub fn enablePersistence(self: *Registry, allocator: std.mem.Allocator) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.users.len != 0) return;
        const users = try allocator.alloc(?UserRecord, user_capacity);
        @memset(users, null);
        self.users = users;
    }

    /// Flush pending users before disabling. Existing sessions become ephemeral.
    pub fn disablePersistence(self: *Registry, allocator: std.mem.Allocator) void {
        const users = detach: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.users.len == 0) return;
            for (&self.slots) |*slot| {
                slot.user_index = null;
                slot.clearChannels();
            }
            const users = self.users;
            self.users = &.{};
            break :detach users;
        };
        allocator.free(users);
    }

    pub fn claim(self: *Registry, key: Pubkey) !Handle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.claimLocked(key, null, .ephemeral, null);
    }
    pub fn claimBefore(self: *Registry, key: Pubkey, deadline: std.Io.Clock.Timestamp) !Handle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.claimLocked(key, deadline, .ephemeral, null);
    }
    /// Requires enabled persistence. Hold the disk lock from loadUser through this claim.
    /// A new user is provisional until confirm; loaded users start clean.
    pub fn claimStored(self: *Registry, key: Pubkey, deadline: std.Io.Clock.Timestamp, stored: ?game_db.User) !Handle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.users.len == 0) return error.PersistenceDisabled;
        return self.claimLocked(key, deadline, .durable, stored);
    }
    fn claimLocked(self: *Registry, key: Pubkey, deadline: ?std.Io.Clock.Timestamp, comptime kind: Claim, stored: ?game_db.User) !Handle {
        var free: ?usize = null;
        for (&self.slots, 0..) |*slot, i| {
            if (slot.occupied) {
                if (std.mem.eql(u8, &slot.pubkey, &key)) return error.DuplicatePubkey;
            } else if (free == null) free = i;
        }
        const index = free orelse return error.SessionCapacity;
        if (self.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        var location = shared.movement.spawn;
        var user_index: ?usize = null;
        var initial_user: ?game_db.User = null;
        if (kind == .durable) {
            const i = try self.findUserIndex(key);
            user_index = i;
            if (self.users[i]) |record| {
                location = record.user.location;
            } else {
                const user = stored orelse game_db.User{ .location = randomSpawn(self.io) };
                initial_user = user;
                location = user.location;
            }
        }

        if (deadline) |end| {
            if (std.Io.Clock.Timestamp.now(self.io, end.clock).compare(.gte, end)) return error.DeadlineExpired;
        }
        if (kind == .durable) {
            const i = user_index.?;
            if (initial_user) |user| {
                self.users[i] = .{ .pubkey = key, .user = user, .provisional = stored == null };
            } else {
                self.users[i].?.active = true;
            }
        }
        self.generation += 1;
        self.slots[index] = .{ .occupied = true, .generation = self.generation, .pubkey = key, .location = location, .user_index = user_index };
        return .{ .index = index, .generation = self.generation };
    }
    fn findUserIndex(self: *const Registry, key: Pubkey) !usize {
        var free: ?usize = null;
        for (self.users, 0..) |*entry, i| {
            if (entry.*) |*record| {
                if (std.mem.eql(u8, &record.pubkey, &key)) return i;
            } else if (free == null) free = i;
        }
        return free orelse error.UserCapacity;
    }

    fn slotFor(self: *Registry, handle: Handle) ?*Slot {
        if (handle.index >= self.slots.len) return null;
        const slot = &self.slots[handle.index];
        return if (slot.occupied and slot.generation == handle.generation) slot else null;
    }
    pub fn confirm(self: *Registry, handle: Handle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.confirmLocked(handle);
    }
    /// Publish a provisional user only if the completed auth phase is still within its deadline.
    pub fn confirmBefore(self: *Registry, handle: Handle, deadline: std.Io.Clock.Timestamp) error{DeadlineExpired}!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (std.Io.Clock.Timestamp.now(self.io, deadline.clock).compare(.gte, deadline)) return error.DeadlineExpired;
        self.confirmLocked(handle);
    }
    fn confirmLocked(self: *Registry, handle: Handle) void {
        const slot = self.slotFor(handle) orelse return;
        const index = slot.user_index orelse return;
        const record = &self.users[index].?;
        if (!record.provisional) return;
        record.provisional = false;
        record.dirty = true;
    }
    pub fn release(self: *Registry, handle: Handle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = self.slotFor(handle) orelse return;
        if (slot.user_index) |i| {
            if (self.users[i].?.dirty) {
                self.users[i].?.active = false;
            } else {
                self.users[i] = null;
            }
        }
        slot.clearChannels();
        slot.* = .{};
    }
    pub fn update(self: *Registry, handle: Handle, location: Location) !void {
        return self.updateMovement(handle, location, {}, false);
    }

    /// The caller must keep state readable while movement is checked.
    pub fn updateWithWorld(self: *Registry, handle: Handle, location: Location, state: anytype) !void {
        return self.updateMovement(handle, location, state, true);
    }

    fn updateMovement(self: *Registry, handle: Handle, location: Location, state: anytype, comptime with_world: bool) !void {
        const move = capture: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const slot = self.slotFor(handle) orelse return error.StaleSession;
            const from = slot.location.?;
            const allowed = if (with_world)
                shared.movement.canStepWith(from, location, state)
            else
                shared.movement.canStep(from, location);
            if (!allowed) return error.BlockedMovement;
            if (from.x == location.x and from.y == location.y) return;
            if (slot.user_index) |i| {
                const record = &self.users[i].?;
                if (!record.provisional) record.dirty = true;
                record.user.location = location;
            }
            slot.location = location;
            break :capture .{ .from = from, .pubkey = slot.pubkey };
        };
        std.log.scoped(.gameplay).debug("move pubkey={s} tile=({d},{d}) -> ({d},{d})", .{
            std.fmt.bytesToHex(move.pubkey, .lower),
            move.from.x,
            move.from.y,
            location.x,
            location.y,
        });
    }
    pub fn get(self: *Registry, handle: Handle) ?SessionSnapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = self.slotFor(handle) orelse return null;
        var snapshot: SessionSnapshot = .{ .pubkey = slot.pubkey, .location = slot.location };
        if (slot.user_index) |i| {
            const user = &self.users[i].?.user;
            snapshot.hoe_channel_id = user.channelId(.hoe);
            snapshot.axe_channel_id = user.channelId(.axe);
            snapshot.pickaxe_channel_id = user.channelId(.pickaxe);
        }
        return snapshot;
    }
    // Only the owning connection task borrows the channel. The registry lock
    // protects publication; no background task touches the borrowed pointer.
    pub fn toolChannel(self: *Registry, handle: Handle, tool: Tool) ?*LiveHoeChannel {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return (self.slotFor(handle) orelse return null).channels.get(tool);
    }

    /// Takes ownership even if the slot is stale. A live channel belongs to one slot and tool.
    pub fn setToolChannel(self: *Registry, handle: Handle, tool: Tool, channel: ?*LiveHoeChannel) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = self.slotFor(handle) orelse {
            if (channel) |live| live.deinit();
            return;
        };
        const current = slot.channels.getPtr(tool);
        if (current.* == channel) return;
        if (current.*) |live| live.deinit();
        current.* = channel;
    }

    pub fn hoeChannel(self: *Registry, handle: Handle) ?*LiveHoeChannel {
        return self.toolChannel(handle, .hoe);
    }

    pub fn setHoeChannel(self: *Registry, handle: Handle, channel: ?*LiveHoeChannel) void {
        self.setToolChannel(handle, .hoe, channel);
    }

    /// Only the confirmed connection installs a queue. Detach it before the
    /// connection's stack goes away; both operations share the publisher lock.
    pub fn setSettlementQueue(self: *Registry, handle: Handle, queue: ?*SettlementQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = self.slotFor(handle) orelse return;
        slot.settlements = queue;
    }

    pub fn notifySettlement(self: *Registry, owner: Pubkey, id: [32]u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.slots) |*slot| {
            if (!slot.occupied or !std.mem.eql(u8, &slot.pubkey, &owner)) continue;
            if (slot.settlements) |queue| {
                // Notices are hints. A stalled or disconnected client recovers by ID.
                _ = queue.putUncancelable(self.io, &.{id}, 0) catch 0;
            }
            return;
        }
    }

    pub fn clearSlots(self: *Registry) void {
        for (&self.slots) |*slot| slot.clearChannels();
        self.slots = @splat(.{});
    }

    pub fn storedUser(self: *Registry, handle: Handle) !UserSnapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = self.slotFor(handle) orelse return error.StaleSession;
        const index = slot.user_index orelse return error.PersistenceDisabled;
        const record = &self.users[index].?;
        if (record.provisional) return error.UnconfirmedUser;
        return .{ .pubkey = record.pubkey, .user = record.user, .index = index };
    }

    /// Publish only the channel from the committed snapshot. A concurrent move
    /// stays dirty, even if the session disconnected while the disk write ran.
    /// The disk lock excludes claims and other saves until publication.
    pub fn publishToolChannelLink(self: *Registry, tool: Tool, saved: UserSnapshot) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = &self.users[saved.index];
        if (entry.*) |*record| {
            std.debug.assert(std.mem.eql(u8, &record.pubkey, &saved.pubkey));
            record.user.setChannelId(tool, saved.user.channelId(tool));
            record.dirty = !std.meta.eql(record.user.location, saved.user.location);
            if (!record.active and !record.dirty) entry.* = null;
        }
    }

    pub fn publishChannelLink(self: *Registry, saved: UserSnapshot) void {
        self.publishToolChannelLink(.hoe, saved);
    }

    pub fn activeLocations(self: *Registry, out: *[64]Location) []const Location {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (&self.slots) |*slot| {
            if (!slot.occupied) continue;
            out[count] = slot.location.?;
            count += 1;
        }
        return out[0..count];
    }
    /// Copies pending users into caller-owned memory and returns the number written.
    /// Keep the disk lock across snapshot, DB transaction, and markUsersSaved.
    pub fn snapshotUsers(self: *Registry, out: []UserSnapshot) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.users, 0..) |*entry, i| {
            if (count == out.len) break;
            if (entry.*) |*record| {
                if (!record.dirty) continue;
                out[count] = .{ .pubkey = record.pubkey, .user = record.user, .index = i };
                count += 1;
            }
        }
        return count;
    }
    /// Acknowledge snapshots only after commit. State that differs from the committed copy remains dirty.
    pub fn markUsersSaved(self: *Registry, snapshots: []const UserSnapshot) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (snapshots) |snapshot| {
            if (snapshot.index >= self.users.len) continue;
            const entry = &self.users[snapshot.index];
            if (entry.*) |*record| {
                if (!std.mem.eql(u8, &record.pubkey, &snapshot.pubkey) or !std.meta.eql(record.user, snapshot.user)) continue;
                if (record.active) {
                    record.dirty = false;
                } else {
                    entry.* = null;
                }
            }
        }
    }
};

fn randomSpawn(io: std.Io) Location {
    const world = shared.world;
    const min = -4 * world.CHUNK_TILES;
    const end = 5 * world.CHUNK_TILES;
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (0..32) |_| {
        const candidate: Location = .{
            .x = random.intRangeLessThanBiased(i32, min, end),
            .y = random.intRangeLessThanBiased(i32, min, end),
        };
        switch (world.sampleTile(world.public_seed, candidate.x, candidate.y)) {
            .grass, .dirt => {},
            .rock, .tree, .water => continue,
        }
        // TODO: Avoid spawning on an occupied tile.
        for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |delta| {
            if (shared.movement.canStep(candidate, .{ .x = candidate.x + delta[0], .y = candidate.y + delta[1] })) return candidate;
        }
    }
    return shared.movement.spawn;
}
