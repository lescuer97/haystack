//! Socket-free checks of the production managed reservation; no runtime tasks.
const std = @import("std");
const transport = @import("transport.zig");
const Buddy = @import("memory.zig").Buddy;

test "bounded-memory application slots reserve once reuse at capacity without upstream fallback" {
    const size = 4 * 1024 * 1024;
    const region = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(size), size);
    defer std.testing.allocator.free(region);
    var pool = try Buddy.init(region);
    {
        var server = try transport.Server.init(std.testing.io, pool.allocator());
        defer server.deinit();
        const used = pool.used;
        const calls = pool.allocation_calls;
        try std.testing.expectEqual(@as(usize, 1024 * 1024), used);
        // Buddy retains no upstream allocator: managed steady state cannot fall back.
        for (0..256) |_| {
            var slots: [64]*transport.Slot = undefined;
            for (&slots) |*slot| slot.* = server.reserve().?;
            try std.testing.expect(server.reserve() == null);
            server.release(slots[17]);
            try std.testing.expect(server.reserve().? == slots[17]);
            for (slots) |slot| server.release(slot);
        }
        var fixture = try @import("fixture.zig").Fixture.init();
        defer fixture.deinit();
        const session = try fixture.application.registry.claim(@splat(3));
        const slot = server.reserve().?;
        for (0..128) |_| {
            try server.dispatch.publish(&slot.mailbox, session, .{
                .request_id = @splat(0),
                .operation = .{ .read_area = .{ .cx0 = 0, .cy0 = 0, .cx1 = 7, .cy1 = 7 } },
            });
            var batch = server.dispatch.beginBatch(server.slots, 0);
            const work = server.dispatch.claimNext(server.slots, &batch, 0).?;
            server.dispatch.execute(&fixture.application, &slot.mailbox, work);
            try slot.mailbox.completion.wait(std.testing.io);
            server.dispatch.cleanup(&slot.mailbox);
        }
        server.release(slot);
        try std.testing.expectEqual(used, pool.used);
        try std.testing.expectEqual(calls, pool.allocation_calls);
        try std.testing.expectEqual(@as(usize, 0), pool.exhaustions);
        std.debug.print("BUDGET,ws_slot_bytes={d},ws_slots_bytes={d},ws_managed_highwater={d},ws_metadata={d}\n", .{ @sizeOf(transport.Slot), 64 * @sizeOf(transport.Slot), pool.high_water, pool.reserved });
    }
    try std.testing.expectEqual(@as(usize, 0), pool.used);
}

test "bounded-memory application insufficient WS startup reserve fails and reclaims" {
    const size = 4096;
    const region = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(size), size);
    defer std.testing.allocator.free(region);
    var pool = try Buddy.init(region);
    try std.testing.expectError(error.OutOfMemory, transport.Server.init(std.testing.io, pool.allocator()));
    try std.testing.expectEqual(@as(usize, 0), pool.used);
}
