const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const ticks = @import("tick_mailbox.zig");
const Fixture = @import("fixture.zig").Fixture;
const transport = @import("transport.zig");
const t = std.testing;
const TestSlot = struct { mailbox: ticks.Mailbox = .{} };
const location = p.Request{ .request_id = @splat(0), .operation = .{ .update_location = .{ .x = 10, .y = -2 } } };
const read = p.Request{ .request_id = @splat(1), .operation = .{ .read_area = .{ .cx0 = 0, .cy0 = 0, .cx1 = 0, .cy1 = 0 } } };

test "owned requests wait for tick; cut read and location copy replies before releasing context" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    const session = try app.registry.claim(@splat(2));
    var dispatcher = ticks.Dispatcher{ .io = t.io };
    var slots: [3]TestSlot = @splat(.{});
    var cut = @import("world_state.zig").request(8, 0, 0);
    try dispatcher.publish(&slots[0].mailbox, session, cut);
    cut.operation.cut.x = 1000;
    try dispatcher.publish(&slots[1].mailbox, session, read);
    try dispatcher.publish(&slots[2].mailbox, session, location);
    try t.expectEqual(@as(usize, 0), app.context.state.replay_count);
    try t.expect(app.registry.get(session).?.location == null);
    var batch = dispatcher.beginBatch(&slots, 0);
    var count: usize = 0;
    while (dispatcher.claimNext(&slots, &batch, 0)) |work| {
        dispatcher.execute(app, &slots[work.record.index].mailbox, work);
        count += 1;
    }
    try t.expectEqual(@as(usize, 3), count);
    try t.expectEqual(@as(i32, 0), slots[0].mailbox.request.operation.cut.x);
    try t.expectEqual(@as(usize, 1), app.context.state.replay_count);
    try t.expectEqualDeep(location.operation.update_location, app.registry.get(session).?.location.?);
    const saved = slots[1].mailbox.reply;
    const context = app.lease().?;
    _ = context.handle(read);
    @memset(&context.response, 0xaa);
    app.release(context);
    try t.expectEqualSlices(u8, saved[0..slots[1].mailbox.len], slots[1].mailbox.reply[0..slots[1].mailbox.len]);
    for (&slots) |*slot| {
        try slot.mailbox.completion.wait(t.io);
        dispatcher.cleanup(&slot.mailbox);
    }
}

test "cutoff generations exclude new arrivals and same-slot republishes; pending cancellation never executes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    const session = try app.registry.claim(@splat(2));
    var dispatcher = ticks.Dispatcher{ .io = t.io };
    var slots: [2]TestSlot = @splat(.{});
    try dispatcher.publish(&slots[0].mailbox, session, location);
    var batch = dispatcher.beginBatch(&slots, 0);
    try dispatcher.publish(&slots[1].mailbox, session, read);
    try t.expectError(error.RequestPending, dispatcher.publish(&slots[0].mailbox, session, read));
    dispatcher.cleanup(&slots[0].mailbox);
    try dispatcher.publish(&slots[0].mailbox, session, read);
    try t.expect(dispatcher.claimNext(&slots, &batch, 0) == null);
    try t.expect(app.registry.get(session).?.location == null);
    batch = dispatcher.beginBatch(&slots, 50_000_000);
    const work = dispatcher.claimNext(&slots, &batch, 50_000_000).?;
    dispatcher.execute(app, &slots[work.record.index].mailbox, work);
    dispatcher.cleanup(&slots[work.record.index].mailbox);
    try dispatcher.publish(&slots[work.record.index].mailbox, session, location);
    const other = dispatcher.claimNext(&slots, &batch, 50_000_000).?;
    try t.expect(other.record.index != work.record.index);
    dispatcher.execute(app, &slots[other.record.index].mailbox, other);
    try t.expect(dispatcher.claimNext(&slots, &batch, 50_000_000) == null);
    for (&slots) |*slot| dispatcher.cleanup(&slot.mailbox);
}

test "soft 50ms budget resumes after serviced slot rather than starving tail" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    const session = try app.registry.claim(@splat(3));
    var dispatcher = ticks.Dispatcher{ .io = t.io };
    var slots: [64]TestSlot = @splat(.{});
    for (&slots) |*slot| try dispatcher.publish(&slot.mailbox, session, read);
    for (0..64) |index| {
        const start: i128 = @as(i128, @intCast(index)) * 100_000_000;
        var batch = dispatcher.beginBatch(&slots, start);
        const work = dispatcher.claimNext(&slots, &batch, start).?;
        try t.expectEqual(index, work.record.index);
        dispatcher.execute(app, &slots[index].mailbox, work);
        dispatcher.cleanup(&slots[index].mailbox);
        try dispatcher.publish(&slots[index].mailbox, session, read);
        try t.expect(dispatcher.claimNext(&slots, &batch, start + 50_000_000) == null);
    }
    for (&slots) |*slot| dispatcher.cleanup(&slot.mailbox);
}

test "busy reply and stale sessions on all operations preserve bounded world semantics" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    const session = try app.registry.claim(@splat(4));
    var dispatcher = ticks.Dispatcher{ .io = t.io };
    var slots: [1]TestSlot = @splat(.{});
    const box = &slots[0].mailbox;
    try dispatcher.publish(box, session, read);
    const held = app.lease().?;
    var batch = dispatcher.beginBatch(&slots, 0);
    dispatcher.execute(app, box, dispatcher.claimNext(&slots, &batch, 0).?);
    app.release(held);
    var expected: [33]u8 = undefined;
    try t.expectEqualSlices(u8, shared.wire.encode(&expected, shared.wire.failure(read.request_id, .server_busy)), box.reply[0..box.len]);
    dispatcher.cleanup(box);
    app.registry.release(session);
    const replacement = try app.registry.claim(@splat(5));
    for ([_]p.Request{ location, read, @import("world_state.zig").request(2, 0, 0) }) |request| {
        try dispatcher.publish(box, session, request);
        batch = dispatcher.beginBatch(&slots, 0);
        dispatcher.execute(app, box, dispatcher.claimNext(&slots, &batch, 0).?);
        try t.expect(box.close_after_reply);
        dispatcher.cleanup(box);
    }
    try t.expect(app.registry.get(replacement).?.location == null);
    try t.expectEqual(@as(usize, 0), app.context.state.replay_count);
    box.generation = std.math.maxInt(u64);
    try t.expectError(error.GenerationExhausted, dispatcher.publish(box, replacement, read));
}

test "fixed writer emits unchanged location bytes and cleans ready mailbox on write failure" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var dispatcher = ticks.Dispatcher{ .io = t.io };
    var slots: [1]TestSlot = @splat(.{});
    const box = &slots[0].mailbox;
    const session = try fixture.application.registry.claim(@splat(6));
    var input = std.Io.Reader.fixed("");
    var bytes: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var ws = std.http.Server.WebSocket{ .input = &input, .output = &output, .key = "" };
    var handler = try transport.Handler.init(&ws, &fixture.application);
    handler.session = session;
    handler.authenticated = true;
    handler.dispatch = &dispatcher;
    handler.mailbox = box;
    defer handler.close();
    try dispatcher.publish(box, session, location);
    var batch = dispatcher.beginBatch(&slots, 0);
    dispatcher.execute(&fixture.application, box, dispatcher.claimNext(&slots, &batch, 0).?);
    try handler.finishReply();
    var payload: [20]u8 = undefined;
    const encoded = shared.wire.encode(&payload, .{ .request_id = location.request_id, .result = .location_updated });
    try t.expectEqualSlices(u8, &.{ 0x82, 20 }, output.buffered()[0..2]);
    try t.expectEqualSlices(u8, encoded, output.buffered()[2..]);
    try dispatcher.publish(box, session, location);
    try t.expect(!box.completion.isSet());
    batch = dispatcher.beginBatch(&slots, 0);
    dispatcher.execute(&fixture.application, box, dispatcher.claimNext(&slots, &batch, 0).?);
    ws.output = @constCast(&std.Io.Writer.failing);
    try t.expectError(error.WriteFailed, handler.finishReply());
    try t.expectEqual(.idle, box.state);
}

test "group cancellation joins queued and executing cleanup before session release without stranded waiters" {
    for ([_]bool{ false, true }) |executing| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const app = &fixture.application;
        const session = try app.registry.claim(@splat(7));
        var dispatcher = ticks.Dispatcher{ .io = t.io };
        var slots: [1]TestSlot = @splat(.{});
        const box = &slots[0].mailbox;
        try dispatcher.publish(box, session, location);
        var batch = dispatcher.beginBatch(&slots, 0);
        const work = if (executing) dispatcher.claimNext(&slots, &batch, 0) else null;
        const Tasks = struct {
            started: std.Io.Event = .unset,
            owner_started: std.Io.Event = .unset,
            cleanup_started: std.Io.Event = .unset,
            valid_session: bool = false,
            fn connection(self: *@This(), d: *ticks.Dispatcher, b: *ticks.Mailbox, a: *transport.App, s: @import("sessions.zig").Handle) void {
                defer a.registry.release(s);
                self.started.set(d.io);
                b.completion.wait(d.io) catch {};
                const executing_cleanup = d.beginCleanup(b);
                self.cleanup_started.set(d.io);
                if (executing_cleanup) d.finishCleanup(b);
            }
            fn owner(self: *@This(), d: *ticks.Dispatcher, b: *ticks.Mailbox, a: *transport.App, w: ticks.Work) void {
                self.owner_started.set(d.io);
                // Explicit test seam pauses BETWEEN claim and the noncancelable
                // production execute; cancellation must still finish execution.
                self.cleanup_started.waitUncancelable(d.io);
                self.valid_session = a.registry.get(w.session) != null;
                d.execute(a, b, w);
            }
        };
        var tasks = Tasks{};
        var group: std.Io.Group = .init;
        defer group.cancel(t.io);
        try group.concurrent(t.io, Tasks.connection, .{ &tasks, &dispatcher, box, app, session });
        tasks.started.waitUncancelable(t.io);
        if (work) |w| {
            group.concurrent(t.io, Tasks.owner, .{ &tasks, &dispatcher, box, app, w }) catch |err| {
                dispatcher.execute(app, box, w);
                return err;
            };
            tasks.owner_started.waitUncancelable(t.io);
        }
        group.cancel(t.io);
        try t.expectEqual(.idle, box.state);
        try t.expect(app.registry.get(session) == null);
        if (executing) {
            try t.expect(tasks.valid_session);
            try t.expect(box.abandoned);
            try t.expect(box.completion.isSet());
        } else {
            try t.expect(dispatcher.claimNext(&slots, &batch, 0) == null);
        }
    }
}

test "cancelled ready reply is discarded before a reserved slot is reused" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var server = try transport.Server.init(t.io, t.allocator);
    defer server.deinit();
    const app = &fixture.application;
    const session = try app.registry.claim(@splat(9));
    const slot = server.reserve().?;
    try server.dispatch.publish(&slot.mailbox, session, read);
    var batch = server.dispatch.beginBatch(server.slots, 0);
    server.dispatch.execute(app, &slot.mailbox, server.dispatch.claimNext(server.slots, &batch, 0).?);
    const generation = slot.mailbox.generation;
    const Writer = struct {
        started: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        fn run(self: *@This(), s: *transport.Server, owned: *transport.Slot) void {
            defer s.release(owned);
            defer s.dispatch.cleanup(&owned.mailbox);
            owned.mailbox.completion.wait(s.io) catch unreachable;
            self.started.set(s.io);
            // Socket-free cancellable write-phase seam, with the ready reply
            // retained until this wait ends. No socket or custom writer engine.
            self.gate.wait(s.io) catch {};
        }
    };
    var writer = Writer{};
    var group: std.Io.Group = .init;
    defer group.cancel(t.io);
    try group.concurrent(t.io, Writer.run, .{ &writer, &server, slot });
    writer.started.waitUncancelable(t.io);
    group.cancel(t.io);
    const reused = server.reserve().?;
    defer server.release(reused);
    try t.expectEqual(slot, reused);
    try t.expectEqual(.idle, reused.mailbox.state);
    try server.dispatch.publish(&reused.mailbox, session, location);
    try t.expectEqual(generation + 1, reused.mailbox.generation);
    try t.expect(!reused.mailbox.completion.isSet());
    server.dispatch.cleanup(&reused.mailbox);
}

test "stopping wakes queued work; ready cancellation and slot reuse retain monotonic generation" {
    var dispatcher = ticks.Dispatcher{ .io = t.io };
    var slots: [1]TestSlot = @splat(.{});
    const box = &slots[0].mailbox;
    const session = @import("sessions.zig").Handle{ .index = 0, .generation = 1 };
    try dispatcher.publish(box, session, read);
    dispatcher.stop(&slots);
    try box.completion.wait(t.io);
    try t.expect(box.close_after_reply);
    dispatcher.cleanup(box);
    try t.expectEqual(@as(u64, 1), box.generation);
    try t.expectError(error.ServerStopping, dispatcher.publish(box, session, read));
}

test "full replay store still permits reads and replay while new cuts stay busy through tick handoff" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    const session = try app.registry.claim(@splat(8));
    const request = @import("world_state.zig").request;
    for (0..512) |id| _ = try app.context.state.cut(request(id, 0, 0));
    const original = app.context.state;
    var dispatcher = ticks.Dispatcher{ .io = t.io };
    var slots: [1]TestSlot = @splat(.{});
    const box = &slots[0].mailbox;
    for ([_]p.Request{ request(512, 0, 0), read, request(0, 0, 0) }, 0..) |req, index| {
        try dispatcher.publish(box, session, req);
        var batch = dispatcher.beginBatch(&slots, 0);
        dispatcher.execute(app, box, dispatcher.claimNext(&slots, &batch, 0).?);
        var expected: [p.max_response_bytes]u8 = undefined;
        const bytes = if (index == 0)
            shared.wire.encode(&expected, shared.wire.failure(req.request_id, .server_busy))
        else blk: {
            const context = app.lease().?;
            defer app.release(context);
            const encoded = context.handle(req);
            @memcpy(expected[0..encoded.len], encoded);
            break :blk expected[0..encoded.len];
        };
        try t.expectEqualSlices(u8, bytes, box.reply[0..box.len]);
        dispatcher.cleanup(box);
    }
    try t.expectEqual(original.chunk_count, app.context.state.chunk_count);
    try t.expectEqual(original.replay_count, app.context.state.replay_count);
    try t.expectEqualDeep(original.replays, app.context.state.replays);
    for (original.chunks[0..original.chunk_count], app.context.state.chunks[0..original.chunk_count]) |before, after|
        try t.expectEqualDeep(before, after);
}
