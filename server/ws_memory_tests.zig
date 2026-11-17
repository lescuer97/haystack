//! Socket-free integration of the actual supplied recycler and WebSocket memory components.
const std = @import("std");
const ws = @import("websocket");
const Buddy = @import("memory.zig").Buddy;
const config = @import("ws_config.zig").config;
test "bounded-memory application recycler prewarms WS components without upstream fallback" {
    const size = 4 * 1024 * 1024;
    const Guard = struct {
        frozen: bool = false,
        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.frozen) @panic("upstream allocation after ready");
            return std.testing.allocator.rawAlloc(len, alignment, ret);
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ret);
        }
    };
    var guard = Guard{};
    const upstream = std.mem.Allocator{ .ptr = &guard, .vtable = &.{ .alloc = Guard.alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = Guard.free } };
    const region = try upstream.alignedAlloc(u8, .fromByteUnits(size), size);
    defer upstream.free(region);
    var pool = try Buddy.init(region);
    const allocator = pool.allocator();
    guard.frozen = true;
    {
        var state = try ws.server.WorkerState.init(std.testing.io, allocator, config);
        defer state.deinit();
        var connections = try ws.server.ConnManager(@import("transport.zig").Handler, true).init(std.testing.io, allocator, null);
        defer connections.deinit();
        try connections.pool.addCapacity(allocator, config.max_conn.?);
        var records: [64]*ws.server.HandlerConn(@import("transport.zig").Handler) = undefined;
        for (&records) |*record| record.* = try connections.pool.create(allocator);
        for (records) |record| connections.pool.destroy(record);
        var reads = try ws.buffer.Pool.init(std.testing.io, allocator, config.buffers.small_pool.?, config.buffers.small_size.?);
        defer reads.deinit();
        const scratch = try allocator.alloc(u8, config.thread_pool.count.? * config.thread_pool.buffer_size.?);
        defer allocator.free(scratch);
        var handshakes: [64]*ws.Handshake.State = undefined;
        for (&handshakes) |*handshake| handshake.* = try state.handshake_pool.acquire();
        for (handshakes) |handshake| handshake.release();
        const prewarmed_used = pool.used;
        const prewarmed_high_water = pool.high_water;
        const prewarmed_exhaustions = pool.exhaustions;
        const prewarmed_allocations = pool.allocation_calls;
        for (0..256) |_| {
            var buffers: [64]ws.buffer.Buffer = undefined;
            for (&buffers) |*buffer| buffer.* = try state.buffer_provider.alloc(128);
            try std.testing.expectEqual(prewarmed_used, pool.used);
            try std.testing.expectEqual(prewarmed_high_water, pool.high_water);
            for (buffers) |buffer| state.buffer_provider.release(buffer);
        }
        try std.testing.expectEqual(prewarmed_exhaustions, pool.exhaustions);
        try std.testing.expectEqual(prewarmed_allocations, pool.allocation_calls);
        try std.testing.expectError(error.TooLarge, state.buffer_provider.alloc(129));
        std.debug.print("BUDGET,ws_component_highwater={d},ws_metadata={d},ws_exhaustions={d}\n", .{ pool.high_water, pool.reserved, pool.exhaustions });
    }
    try std.testing.expectEqual(@as(usize, 0), pool.used);
}
test "bounded-memory application insufficient WS startup reserve fails and reclaims" {
    const size = 4096;
    const region = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(size), size);
    defer std.testing.allocator.free(region);
    var pool = try Buddy.init(region);
    try std.testing.expectError(error.OutOfMemory, ws.server.WorkerState.init(std.testing.io, pool.allocator(), config));
    try std.testing.expectEqual(@as(usize, 0), pool.used);
}
