const std = @import("std");
const s = @import("sessions.zig");
const game_db = @import("game_db.zig");
const shared = @import("shared");
const Location = shared.protocol.Location;
const spawn = shared.movement.spawn;
test "registry bounded capacity spawn stale and repeated cleanup" {
    var registry = s.Registry{ .io = std.testing.io };
    var handles: [64]s.Handle = undefined;
    for (&handles, 0..) |*handle, i| {
        handle.* = try registry.claim(@splat(@intCast(i)));
        try std.testing.expectEqualDeep(@as(?Location, spawn), registry.get(handle.*).?.location);
    }
    try std.testing.expectError(error.SessionCapacity, registry.claim(@splat(64)));
    const old = handles[0];
    try registry.update(old, .{ .x = 1, .y = 0 });
    try std.testing.expectError(error.DuplicatePubkey, registry.claim(@splat(0)));
    registry.release(old);
    const fresh = try registry.claim(@splat(0));
    try std.testing.expectEqualDeep(@as(?Location, spawn), registry.get(fresh).?.location);
    registry.release(old);
    try std.testing.expectError(error.StaleSession, registry.update(old, .{ .x = 1, .y = 2 }));

    const invalid = s.Handle{ .index = std.math.maxInt(usize), .generation = fresh.generation };
    registry.release(invalid);
    try std.testing.expect(registry.get(invalid) == null);
    try std.testing.expectError(error.StaleSession, registry.update(invalid, .{ .x = 0, .y = 0 }));
    registry.release(fresh);
    for (handles) |handle| {
        registry.release(handle);
        registry.release(handle);
    }
    for (registry.slots) |slot| {
        try std.testing.expect(!slot.occupied and slot.location == null);
        try std.testing.expectEqualDeep(@as(s.Pubkey, @splat(0)), slot.pubkey);
    }
    registry.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.GenerationExhausted, registry.claim(@splat(0)));
}
test "location rejects a jump from spawn and a blocked tile without advancing" {
    var registry = s.Registry{ .io = std.testing.io };
    const handle = try registry.claim(@splat(0));
    defer registry.release(handle);

    try std.testing.expectError(error.BlockedMovement, registry.update(handle, .{ .x = 19, .y = 0 }));
    try std.testing.expectEqualDeep(@as(?Location, spawn), registry.get(handle).?.location);
    for (1..20) |x| try registry.update(handle, .{ .x = @intCast(x), .y = 0 });
    try std.testing.expectError(error.BlockedMovement, registry.update(handle, .{ .x = 20, .y = 0 }));
    try std.testing.expectError(error.BlockedMovement, registry.update(handle, .{ .x = 20, .y = 1 }));
    try std.testing.expectEqualDeep(@as(?Location, .{ .x = 19, .y = 0 }), registry.get(handle).?.location);
    try registry.update(handle, .{ .x = 19, .y = 1 });
    try std.testing.expectEqualDeep(@as(?Location, .{ .x = 19, .y = 1 }), registry.get(handle).?.location);
}

test "durable movement reaches and restores the i32 edges without wrapping" {
    var db = try game_db.GameDb.open(":memory:");
    defer db.close();
    var registry = s.Registry{ .io = std.testing.io };
    try registry.enablePersistence(std.testing.allocator);
    defer registry.disablePersistence(std.testing.allocator);
    const key: s.Pubkey = @splat(1);
    const low = std.math.minInt(i32);
    const high = std.math.maxInt(i32);

    for ([_]i32{ low, high }) |limit| {
        const from, const edge = find: {
            for (0..4096) |y| {
                const edge: Location = .{ .x = limit, .y = @intCast(y) };
                const from: Location = .{ .x = if (limit == low) low + 1 else high - 1, .y = edge.y };
                if (shared.movement.canStep(edge, from) and shared.movement.canStep(from, edge)) break :find .{ from, edge };
            }
            return error.NoWalkableBoundary;
        };
        const channel: [32]u8 = @splat(0x42);
        try db.saveUser(key, .{ .location = from, .channel_id = channel });
        const handle = try registry.claimStored(key, deadline(), try db.loadUser(key));
        try std.testing.expectEqualDeep(from, registry.get(handle).?.location.?);
        try registry.update(handle, edge);
        var pending: [1]s.UserSnapshot = undefined;
        try std.testing.expectEqual(@as(usize, 1), registry.snapshotUsers(&pending));
        const updated = pending[0];
        try std.testing.expectEqualDeep(game_db.User{ .location = edge, .channel_id = channel }, updated.user);

        const wrapped: Location = .{ .x = if (limit == low) high else low, .y = edge.y };
        try std.testing.expectError(error.BlockedMovement, registry.update(handle, wrapped));
        try std.testing.expectEqualDeep(edge, registry.get(handle).?.location.?);
        try std.testing.expectEqual(@as(usize, 1), registry.snapshotUsers(&pending));
        try std.testing.expectEqualDeep(updated, pending[0]);
        try db.saveUser(key, updated.user);
        registry.markUsersSaved(&pending);
        registry.release(handle);

        const restored = try registry.claimStored(key, deadline(), try db.loadUser(key));
        try std.testing.expectEqualDeep(edge, registry.get(restored).?.location.?);
        try std.testing.expectEqual(@as(usize, 0), registry.snapshotUsers(&pending));
        registry.release(restored);
    }
}

test "two barrier synchronized duplicate claims exactly one winner preserves known location" {
    var registry = s.Registry{ .io = std.testing.io };
    const Worker = struct {
        registry: *s.Registry,
        ready: *std.atomic.Value(u32),
        go: *std.atomic.Value(bool),
        handle: ?s.Handle = null,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .release);
            while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
            self.handle = self.registry.claim(@splat(7)) catch |err| {
                self.err = err;
                return;
            };
        }
    };
    var ready = std.atomic.Value(u32).init(0);
    var go = std.atomic.Value(bool).init(false);
    var a = Worker{ .registry = &registry, .ready = &ready, .go = &go };
    var b = Worker{ .registry = &registry, .ready = &ready, .go = &go };
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{&a});
    const t2 = std.Thread.spawn(.{}, Worker.run, .{&b}) catch |err| {
        go.store(true, .release);
        t1.join();
        return err;
    };
    while (ready.load(.acquire) != 2) std.atomic.spinLoopHint();
    go.store(true, .release);
    t1.join();
    t2.join();
    try std.testing.expect((a.handle != null) != (b.handle != null));
    try std.testing.expectEqual(error.DuplicatePubkey, (if (a.handle == null) a.err else b.err).?);
    const winner = a.handle orelse b.handle.?;
    try registry.update(winner, .{ .x = 1, .y = 0 });
    try std.testing.expectError(error.DuplicatePubkey, registry.claim(@splat(7)));
    try std.testing.expectEqualDeep(@as(?Location, .{ .x = 1, .y = 0 }), registry.get(winner).?.location);
    registry.release(winner);
}

fn deadline() std.Io.Clock.Timestamp {
    return .fromNow(std.testing.io, .{ .raw = .fromSeconds(60), .clock = .awake });
}

test "durable users restore pending state and only acknowledge matching saved values" {
    var db = try game_db.GameDb.open(":memory:");
    defer db.close();
    var registry = s.Registry{ .io = std.testing.io };
    try registry.enablePersistence(std.testing.allocator);
    defer registry.disablePersistence(std.testing.allocator);
    const key: s.Pubkey = @splat(7);
    const stored: game_db.User = .{ .location = spawn, .channel_id = @splat(42) };
    try db.saveUser(key, stored);

    const first = try registry.claimStored(key, deadline(), try db.loadUser(key));
    try std.testing.expectEqualDeep(@as(?Location, spawn), registry.get(first).?.location);
    var batch: [1]s.UserSnapshot = undefined;
    try std.testing.expectEqual(@as(usize, 0), registry.snapshotUsers(&batch));
    registry.confirm(first);
    try std.testing.expectEqual(@as(usize, 0), registry.snapshotUsers(&batch));
    const step: Location = .{ .x = 1, .y = 0 };
    try registry.update(first, step);
    try std.testing.expectEqual(@as(usize, 1), registry.snapshotUsers(&batch));
    try std.testing.expectEqualDeep(game_db.User{ .location = step, .channel_id = stored.channel_id }, batch[0].user);
    const initial = batch[0];
    try registry.update(first, step);
    try std.testing.expectError(error.BlockedMovement, registry.update(first, .{ .x = 20, .y = 0 }));
    try std.testing.expectEqual(@as(usize, 1), registry.snapshotUsers(&batch));
    try std.testing.expectEqualDeep(initial, batch[0]);

    try db.begin();
    try db.saveUser(initial.pubkey, initial.user);
    const moved: Location = .{ .x = 2, .y = 0 };
    try registry.update(first, moved);
    registry.release(first);
    try db.commit();
    registry.markUsersSaved(&.{initial});
    try std.testing.expectEqual(@as(usize, 1), registry.snapshotUsers(&batch));

    try std.testing.expectEqualDeep(game_db.User{ .location = moved, .channel_id = stored.channel_id }, batch[0].user);

    const legacy = try registry.claimBefore(key, deadline());
    try std.testing.expectEqualDeep(@as(?Location, spawn), registry.get(legacy).?.location);
    registry.confirm(legacy);
    try registry.update(legacy, .{ .x = -1, .y = 0 });
    registry.release(legacy);
    const second = try registry.claimStored(key, deadline(), try db.loadUser(key));
    registry.confirm(second);
    try std.testing.expectEqualDeep(@as(?Location, moved), registry.get(second).?.location);
    try std.testing.expectError(error.DuplicatePubkey, registry.claimStored(key, deadline(), stored));
    try std.testing.expectError(error.StaleSession, registry.update(first, spawn));
    registry.release(first);
    try db.begin();
    try db.saveUser(batch[0].pubkey, batch[0].user);
    try registry.update(second, step);
    try registry.update(second, moved);
    try db.commit();
    registry.markUsersSaved(&batch); // Returning to the committed position needs no second write.
    try std.testing.expectEqual(@as(usize, 0), registry.snapshotUsers(&batch));
    registry.release(second);

    try std.testing.expectEqualDeep(@as(?game_db.User, batch[0].user), try db.loadUser(key));
    const third = try registry.claimStored(key, deadline(), try db.loadUser(key));
    try std.testing.expectEqualDeep(@as(?Location, moved), registry.get(third).?.location);
    registry.confirm(third);
    try std.testing.expectEqual(@as(usize, 0), registry.snapshotUsers(&batch));
    try registry.update(third, step);
    registry.release(third);
    registry.markUsersSaved(&batch); // Old snapshot cannot clear the reused record for the same key.
    try std.testing.expectEqual(@as(usize, 1), registry.snapshotUsers(&batch));
    try std.testing.expectEqualDeep(step, batch[0].user.location);
}

fn cardinalExit(location: Location) ?Location {
    for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |delta| {
        const next: Location = .{ .x = location.x + delta[0], .y = location.y + delta[1] };
        if (shared.movement.canStep(location, next)) return next;
    }
    return null;
}

test "new durable users are not saved until auth is confirmed" {
    var registry = s.Registry{ .io = std.testing.io };
    try registry.enablePersistence(std.testing.allocator);
    defer registry.disablePersistence(std.testing.allocator);
    var batch: [1]s.UserSnapshot = undefined;
    const key: s.Pubkey = @splat(5);

    const failed = try registry.claimStored(key, deadline(), null);
    try std.testing.expectEqual(@as(usize, 0), registry.snapshotUsers(&batch));
    registry.release(failed);
    try std.testing.expectEqual(@as(usize, 0), registry.snapshotUsers(&batch));

    const accepted = try registry.claimStored(key, deadline(), null);
    registry.confirm(failed); // A stale handle must not confirm a reused session slot.
    const next = cardinalExit(registry.get(accepted).?.location.?) orelse return error.NoCardinalExit;
    try registry.update(accepted, next);
    try std.testing.expectEqual(@as(usize, 0), registry.snapshotUsers(&batch));
    registry.confirm(accepted);
    try std.testing.expectEqual(@as(usize, 1), registry.snapshotUsers(&batch));
    try std.testing.expectEqualDeep(key, batch[0].pubkey);
    try std.testing.expectEqualDeep(next, batch[0].user.location);
    registry.markUsersSaved(&batch);
    registry.confirm(accepted);
    registry.release(accepted);
    try std.testing.expectEqual(@as(usize, 0), registry.snapshotUsers(&batch));
}

test "durable spawn is within the starting chunks and has a cardinal exit" {
    var registry = s.Registry{ .io = std.testing.io };
    try registry.enablePersistence(std.testing.allocator);
    defer registry.disablePersistence(std.testing.allocator);
    try std.testing.expectError(error.DeadlineExpired, registry.claimStored(@splat(0), .now(std.testing.io, .awake), null));
    var snapshot: [1]s.UserSnapshot = undefined;
    try std.testing.expectEqual(@as(usize, 0), registry.snapshotUsers(&snapshot));

    var locations: [64]Location = undefined;
    var handles: [64]s.Handle = undefined;
    for (&handles, 0..) |*handle, i| {
        handle.* = try registry.claimStored(@splat(@intCast(i)), deadline(), null);
        registry.confirm(handle.*);
    }
    const world = shared.world;
    const active = registry.activeLocations(&locations);
    try std.testing.expectEqual(handles.len, active.len);
    for (handles, active) |handle, location| {
        try std.testing.expectEqualDeep(registry.get(handle).?.location.?, location);
        const cx = @divFloor(location.x, world.CHUNK_TILES);
        const cy = @divFloor(location.y, world.CHUNK_TILES);
        try std.testing.expect(cx >= -4 and cx <= 4 and cy >= -4 and cy <= 4);
        const tile = world.sampleTile(world.public_seed, location.x, location.y);
        try std.testing.expect(tile == .grass or tile == .dirt);
        try std.testing.expect(cardinalExit(location) != null);
        registry.release(handle);
    }
    try std.testing.expectEqual(@as(usize, 0), registry.activeLocations(&locations).len);
    try std.testing.expectEqual(@as(usize, 1), registry.snapshotUsers(&snapshot));
}

fn keyFor(i: usize) s.Pubkey {
    var key: s.Pubkey = @splat(0);
    std.mem.writeInt(u32, key[0..4], @intCast(i), .little);
    return key;
}

test "durable capacity reserves room for active moves and reclaims saved records" {
    var registry = s.Registry{ .io = std.testing.io };
    try registry.enablePersistence(std.testing.allocator);
    defer registry.disablePersistence(std.testing.allocator);
    const stored: game_db.User = .{ .location = spawn };
    const active = try registry.claimStored(keyFor(0), deadline(), stored);
    registry.confirm(active);
    for (1..s.user_capacity) |i| {
        const handle = try registry.claimStored(keyFor(i), deadline(), null);
        registry.confirm(handle);
        registry.release(handle);
    }
    const extra = keyFor(s.user_capacity);
    try std.testing.expectError(error.UserCapacity, registry.claimStored(extra, deadline(), stored));
    const legacy = try registry.claim(extra);
    registry.release(legacy);
    const resumed = try registry.claimStored(keyFor(1), deadline(), null);
    registry.release(resumed);

    try registry.update(active, .{ .x = 1, .y = 0 });
    const batch = try std.testing.allocator.alloc(s.UserSnapshot, s.user_capacity);
    defer std.testing.allocator.free(batch);
    try std.testing.expectEqual(s.user_capacity, registry.snapshotUsers(batch));
    registry.markUsersSaved(batch[1..2]); // A saved disconnected record frees one reservation.
    const provisional = try registry.claimStored(extra, deadline(), null);
    try std.testing.expectError(error.UserCapacity, registry.claimStored(keyFor(s.user_capacity + 1), deadline(), stored));
    registry.release(provisional); // Failed auth frees the reservation without saving.
    const accepted = try registry.claimStored(extra, deadline(), null);
    registry.confirm(accepted);
    registry.release(accepted);
    try std.testing.expectError(error.UserCapacity, registry.claimStored(keyFor(s.user_capacity + 1), deadline(), stored));
    registry.markUsersSaved(batch[0..1]); // A saved active record stays reserved until release.
    try std.testing.expectError(error.UserCapacity, registry.claimStored(keyFor(s.user_capacity + 1), deadline(), stored));
    registry.release(active);
    const next = try registry.claimStored(keyFor(s.user_capacity + 1), deadline(), stored);
    registry.release(next);
}

test "persistence storage is opt-in and can be disabled and re-enabled" {
    const allocator = std.testing.allocator;
    var registry = s.Registry{ .io = std.testing.io };
    defer registry.disablePersistence(allocator);
    const key: s.Pubkey = @splat(1);
    const stored: game_db.User = .{ .location = spawn };
    try std.testing.expectError(error.PersistenceDisabled, registry.claimStored(key, deadline(), stored));
    try std.testing.expectError(error.OutOfMemory, registry.enablePersistence(std.testing.failing_allocator));
    try std.testing.expectError(error.PersistenceDisabled, registry.claimStored(key, deadline(), stored));

    try registry.enablePersistence(allocator);
    const first = try registry.claimStored(key, deadline(), stored);
    try registry.update(first, .{ .x = 1, .y = 0 });
    var batch: [1]s.UserSnapshot = undefined;
    try std.testing.expectEqual(@as(usize, 1), registry.snapshotUsers(&batch));
    try registry.enablePersistence(allocator); // Already enabled; retain existing records.
    try std.testing.expectEqual(@as(usize, 1), registry.snapshotUsers(&batch));
    const old = batch[0];
    registry.disablePersistence(allocator);
    registry.disablePersistence(allocator);
    try std.testing.expectEqual(@as(usize, 0), registry.snapshotUsers(&batch));
    registry.markUsersSaved(&.{old});
    try std.testing.expectError(error.PersistenceDisabled, registry.claimStored(@splat(2), deadline(), stored));
    try registry.update(first, spawn);

    try registry.enablePersistence(allocator);
    try registry.update(first, .{ .x = 1, .y = 0 });
    try std.testing.expectEqual(@as(usize, 0), registry.snapshotUsers(&batch));
    registry.release(first);
    const second = try registry.claimStored(key, deadline(), stored);
    const updated: Location = .{ .x = -1, .y = 0 };
    try registry.update(second, updated);
    registry.markUsersSaved(&.{old});
    try std.testing.expectEqual(@as(usize, 1), registry.snapshotUsers(&batch));
    try std.testing.expectEqualDeep(updated, batch[0].user.location);
    registry.markUsersSaved(&batch);
    registry.release(second);
}
