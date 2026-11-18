const std = @import("std");
const s = @import("sessions.zig");
const Location = @import("shared").protocol.Location;
test "registry bounded capacity unknown origin extremes stale and repeated cleanup" {
    var registry = s.Registry{ .io = std.testing.io };
    var handles: [64]s.Handle = undefined;
    for (&handles, 0..) |*handle, i| {
        handle.* = try registry.claim(@splat(@intCast(i)));
        try std.testing.expect(registry.get(handle.*).?.location == null);
    }
    try std.testing.expectError(error.SessionCapacity, registry.claim(@splat(64)));
    const old = handles[0];
    try registry.update(old, .{ .x = 0, .y = 0 });
    try std.testing.expectEqualDeep(@as(?Location, .{ .x = 0, .y = 0 }), registry.get(old).?.location);
    try std.testing.expectError(error.DuplicatePubkey, registry.claim(@splat(0)));
    registry.release(old);
    const fresh = try registry.claim(@splat(0));
    try std.testing.expect(registry.get(fresh).?.location == null);
    registry.release(old);
    try std.testing.expectError(error.StaleSession, registry.update(old, .{ .x = 1, .y = 2 }));
    try registry.update(fresh, .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32) });
    const copy = registry.get(fresh).?;
    try registry.update(fresh, .{ .x = -1, .y = -2 });
    try std.testing.expectEqual(std.math.minInt(i32), copy.location.?.x);
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
    try registry.update(winner, .{ .x = 12, .y = -34 });
    try std.testing.expectError(error.DuplicatePubkey, registry.claim(@splat(7)));
    try std.testing.expectEqualDeep(@as(?Location, .{ .x = 12, .y = -34 }), registry.get(winner).?.location);
    registry.release(winner);
}
