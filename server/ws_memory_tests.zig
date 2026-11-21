//! Socket-free checks of the production managed reservation; no runtime tasks.
const std = @import("std");
const transport = @import("transport.zig");
const memory = @import("memory.zig");
const Buddy = memory.Buddy;
const config = @import("ws_config.zig");
const shared = @import("shared");

test "bounded-memory application slots reserve once reuse at capacity without upstream fallback" {
    const size = memory.default_ws_budget;
    const region = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(size), size);
    defer std.testing.allocator.free(region);
    var pool = try Buddy.init(region);
    {
        var server = try transport.Server.init(std.testing.io, pool.allocator());
        defer server.deinit();
        const used = pool.used;
        const calls = pool.allocation_calls;
        const slot_bytes = @sizeOf(transport.Slot) * config.max_connections;
        const slot_block = 1024 * 1024;
        // Check the raw footprint and the rounded Buddy allocation separately.
        try std.testing.expect(slot_bytes + pool.reserved <= slot_block);
        try std.testing.expectEqual(@as(usize, slot_block), used);
        try std.testing.expect(used + pool.reserved <= size);
        // Buddy retains no upstream allocator: managed steady state cannot fall back.
        for (0..256) |_| {
            var slots: [config.max_connections]*transport.Slot = undefined;
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
        const id: shared.protocol.Id = @splat(0);
        var snapshot: shared.protocol.Snapshot = undefined;
        for (0..128) |_| {
            try server.dispatch.publish(&slot.mailbox, session, .{
                .request_id = id,
                .operation = .{ .read_area = .{ .cx0 = 0, .cy0 = 0, .cx1 = 7, .cy1 = 7 } },
            });
            var batch = server.dispatch.beginBatch(server.slots, 0);
            const work = server.dispatch.claimNext(server.slots, &batch, 0).?;
            server.dispatch.execute(&fixture.application, &slot.mailbox, work);
            try slot.mailbox.completion.wait(std.testing.io);
            const reply = try shared.wire.decodeReply(slot.mailbox.reply[0..slot.mailbox.len], .read_area, id, &snapshot);
            try std.testing.expect(reply == .ok);
            try std.testing.expectEqual(shared.protocol.max_area_chunks, snapshot.count);
            server.dispatch.cleanup(&slot.mailbox);
        }
        server.release(slot);
        try std.testing.expectEqual(used, pool.used);
        try std.testing.expectEqual(calls, pool.allocation_calls);
        try std.testing.expectEqual(@as(usize, 0), pool.exhaustions);
        std.debug.print("BUDGET,ws_slot_bytes={d},ws_slots_bytes={d},ws_managed_highwater={d},ws_metadata={d}\n", .{ @sizeOf(transport.Slot), slot_bytes, pool.high_water, pool.reserved });
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
