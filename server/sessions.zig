//! Ephemeral, bounded verified connection identity and latest tile location.
const std = @import("std");
const shared = @import("shared");
const Location = shared.protocol.Location;
pub const Pubkey = [33]u8;
pub const Handle = struct { index: usize, generation: u64 };
pub const SessionSnapshot = struct { pubkey: Pubkey, location: ?Location };

pub const Registry = struct {
    const Slot = struct {
        occupied: bool = false,
        generation: u64 = 0,
        pubkey: Pubkey = @splat(0),
        location: ?Location = null,
    };
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    generation: u64 = 0,
    slots: [64]Slot = @splat(.{}),

    pub fn claim(self: *Registry, key: Pubkey) !Handle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.claimLocked(key, null);
    }
    pub fn claimBefore(self: *Registry, key: Pubkey, deadline: std.Io.Clock.Timestamp) !Handle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.claimLocked(key, deadline);
    }
    fn claimLocked(self: *Registry, key: Pubkey, deadline: ?std.Io.Clock.Timestamp) !Handle {
        var free: ?usize = null;
        for (&self.slots, 0..) |*slot, i| {
            if (slot.occupied) {
                if (std.mem.eql(u8, &slot.pubkey, &key)) return error.DuplicatePubkey;
            } else if (free == null) free = i;
        }
        const index = free orelse return error.SessionCapacity;
        if (self.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        if (deadline) |end| {
            if (std.Io.Clock.Timestamp.now(self.io, end.clock).compare(.gte, end)) return error.DeadlineExpired;
        }
        self.generation += 1;
        // TODO: Persist player positions by authenticated key and return the
        // restored position to the client when creating a new session.
        self.slots[index] = .{ .occupied = true, .generation = self.generation, .pubkey = key, .location = shared.movement.spawn };
        return .{ .index = index, .generation = self.generation };
    }
    fn slotFor(self: *Registry, handle: Handle) ?*Slot {
        if (handle.index >= self.slots.len) return null;
        const slot = &self.slots[handle.index];
        return if (slot.occupied and slot.generation == handle.generation) slot else null;
    }
    pub fn release(self: *Registry, handle: Handle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.slotFor(handle)) |slot| slot.* = .{};
    }
    pub fn update(self: *Registry, handle: Handle, location: Location) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = self.slotFor(handle) orelse return error.StaleSession;
        if (!shared.movement.canStep(slot.location.?, location)) return error.BlockedMovement;
        slot.location = location;
    }
    pub fn get(self: *Registry, handle: Handle) ?SessionSnapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = self.slotFor(handle) orelse return null;
        return .{ .pubkey = slot.pubkey, .location = slot.location };
    }
};
