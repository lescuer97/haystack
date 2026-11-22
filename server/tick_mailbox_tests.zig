const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const ticks = @import("tick_mailbox.zig");
const Fixture = @import("fixture.zig").Fixture;
const transport = @import("transport.zig");
const t = std.testing;
const TestSlot = struct { mailbox: ticks.Mailbox = .{} };
const location = p.Request{ .request_id = @splat(0), .operation = .{ .update_location = .{ .x = 1, .y = 0 } } };
const read = p.Request{ .request_id = @splat(1), .operation = .{ .read_area = .{ .cx0 = 0, .cy0 = 0, .cx1 = 0, .cy1 = 0 } } };

fn cutRequest(id: u128, x: i32, y: i32) p.Request {
    const req = @import("world_state.zig").request(id, x, y);
    return .{ .request_id = req.request_id, .operation = .{ .cut = req.payload } };
}

fn reply(box: *const ticks.Mailbox, comptime kind: p.Kind, id: p.Id, snapshot: *p.Snapshot) !p.Outcome(kind) {
    return shared.wire.decodeReply(box.reply[0..box.len], kind, id, snapshot);
}

test "owned requests wait for tick; cut read and location copy replies before releasing context" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    const session = try app.registry.claim(@splat(2));
    var dispatcher = ticks.Dispatcher{ .io = t.io };
    var slots: [3]TestSlot = @splat(.{});
    var cut = cutRequest(8, 0, 0);
    try dispatcher.publish(&slots[0].mailbox, session, cut);
    cut.operation.cut.x = 1000;
    try dispatcher.publish(&slots[1].mailbox, session, read);
    try dispatcher.publish(&slots[2].mailbox, session, location);
    try t.expectEqual(@as(usize, 0), app.context.state.replay_count);
    try t.expectEqualDeep(shared.movement.spawn, app.registry.get(session).?.location.?);
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
    var snapshot: p.Snapshot = undefined;
    const cut_outcome = try reply(&slots[0].mailbox, .cut, cut.request_id, &snapshot);
    try t.expectEqualDeep(app.context.state.replays[0].result, cut_outcome);
    try t.expect((try reply(&slots[2].mailbox, .update_location, location.request_id, &snapshot)) == .ok);
    const area_reply = &slots[1].mailbox;
    const saved = (try reply(area_reply, .read_area, read.request_id, &snapshot)).ok.*;
    try t.expectEqualDeep(read.operation.read_area, saved.area);
    try t.expectEqual(@as(u16, 1), saved.count);
    const context = app.lease().?;
    _ = context.handle(.read_area, .{ .request_id = read.request_id, .payload = read.operation.read_area }, app.registry.get(session).?.pubkey);
    @memset(&context.response, 0xaa);
    app.release(context);
    try t.expectEqualDeep(saved, (try reply(area_reply, .read_area, read.request_id, &snapshot)).ok.*);
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
    try t.expectEqualDeep(shared.movement.spawn, app.registry.get(session).?.location.?);
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
    var snapshot: p.Snapshot = undefined;
    try t.expectEqual(p.AreaFailure.server_busy, (try reply(box, .read_area, read.request_id, &snapshot)).failed);
    try t.expect(!box.close_after_reply);
    dispatcher.cleanup(box);

    var blocked = location;
    blocked.operation.update_location.x = 2;
    try dispatcher.publish(box, session, blocked);
    batch = dispatcher.beginBatch(&slots, 0);
    dispatcher.execute(app, box, dispatcher.claimNext(&slots, &batch, 0).?);
    try t.expectEqual(p.LocationFailure.invalid_request, (try reply(box, .update_location, blocked.request_id, &snapshot)).failed);
    try t.expect(!box.close_after_reply);
    try t.expectEqualDeep(shared.movement.spawn, app.registry.get(session).?.location.?);
    dispatcher.cleanup(box);

    try dispatcher.publish(box, session, location);
    batch = dispatcher.beginBatch(&slots, 0);
    dispatcher.execute(app, box, dispatcher.claimNext(&slots, &batch, 0).?);
    try t.expect((try reply(box, .update_location, location.request_id, &snapshot)) == .ok);
    try t.expect(!box.close_after_reply);
    try t.expectEqualDeep(location.operation.update_location, app.registry.get(session).?.location.?);
    dispatcher.cleanup(box);
    app.release(held);

    app.registry.release(session);
    const replacement = try app.registry.claim(@splat(5));
    for ([_]p.Request{ location, read, cutRequest(2, 0, 0) }) |request| {
        try dispatcher.publish(box, session, request);
        batch = dispatcher.beginBatch(&slots, 0);
        dispatcher.execute(app, box, dispatcher.claimNext(&slots, &batch, 0).?);
        try t.expect(box.close_after_reply);
        switch (request.operation) {
            inline else => |_, kind| try t.expect((try reply(box, kind, request.request_id, &snapshot)).failed == .invalid_request),
        }
        dispatcher.cleanup(box);
    }
    try t.expectEqualDeep(shared.movement.spawn, app.registry.get(replacement).?.location.?);
    try t.expectEqual(@as(usize, 0), app.context.state.replay_count);
    box.generation = std.math.maxInt(u64);
    try t.expectError(error.GenerationExhausted, dispatcher.publish(box, replacement, read));
}

test "fixed writer emits a typed location reply and cleans ready mailbox on write failure" {
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
    var payload: [p.max_response_bytes]u8 = undefined;
    const encoded = try shared.wire.encodeReply(&payload, .update_location, .{
        .request_id = location.request_id,
        .payload = location.operation.update_location,
    }, .{ .ok = {} });
    try t.expect(encoded.len <= 125);
    try t.expectEqualSlices(u8, &.{ 0x82, @intCast(encoded.len) }, output.buffered()[0..2]);
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
    var snapshot: p.Snapshot = undefined;
    try t.expectEqual(p.AreaFailure.server_busy, (try reply(box, .read_area, read.request_id, &snapshot)).failed);
    dispatcher.cleanup(box);
    try t.expectEqual(@as(u64, 1), box.generation);
    try t.expectError(error.ServerStopping, dispatcher.publish(box, session, read));
}

test "full replay history evicts the oldest admission through tick handoff" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    const session = try app.registry.claim(@splat(8));
    const world_state = @import("world_state.zig");
    const capacity = world_state.WorldState.capacity;
    const state = &app.context.state;
    const first = try state.cut(world_state.request(0, 0, 0));
    try t.expect(first == .ok);
    for (1..capacity) |id| _ = try state.cut(world_state.request(id, 0, 0));
    var expected: p.Snapshot = undefined;
    try state.readArea(read.operation.read_area, &expected);

    var dispatcher = ticks.Dispatcher{ .io = t.io };
    var slots: [1]TestSlot = @splat(.{});
    const box = &slots[0].mailbox;
    const cases = [_]struct { req: p.Request, cut: ?p.Outcome(.cut) }{
        .{ .req = cutRequest(0, 0, 0), .cut = first },
        .{ .req = cutRequest(capacity, 0, 0), .cut = .{ .failed = .{ .already_cut = first.ok } } },
        .{ .req = read, .cut = null },
        .{ .req = cutRequest(1, 1, 0), .cut = .{ .failed = .request_id_conflict } },
        .{ .req = cutRequest(0, 0, 0), .cut = .{ .failed = .{ .already_cut = first.ok } } },
    };
    for (cases) |case| {
        const req = case.req;
        try dispatcher.publish(box, session, req);
        var batch = dispatcher.beginBatch(&slots, 0);
        dispatcher.execute(app, box, dispatcher.claimNext(&slots, &batch, 0).?);
        var snapshot: p.Snapshot = undefined;
        if (case.cut) |outcome| {
            try t.expectEqualDeep(outcome, try reply(box, .cut, req.request_id, &snapshot));
        } else {
            try t.expectEqualDeep(expected, (try reply(box, .read_area, req.request_id, &snapshot)).ok.*);
        }
        try t.expect(!box.close_after_reply);
        dispatcher.cleanup(box);
    }
    try t.expectEqual(capacity, state.replay_count);
    try t.expect(state.replayCut(world_state.request(1, 0, 0)) == null);
}

test "prepared cut replay survives ring eviction and still validates the session" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.application;
    const session = try app.registry.claim(@splat(9));
    const world_state = @import("world_state.zig");
    const state = &app.context.state;
    const req = world_state.request(0, 0, 0);
    const first = try state.cut(req);
    try t.expect(first == .ok);
    for (1..world_state.WorldState.capacity) |id| _ = try state.cut(world_state.request(id, 0, 0));
    const replay = state.replayCut(req).?;

    var dispatcher = ticks.Dispatcher{ .io = t.io };
    var slots: [1]TestSlot = @splat(.{});
    const box = &slots[0].mailbox;
    const request = cutRequest(0, 0, 0);
    try dispatcher.publishPrepared(box, session, request, replay);
    _ = try state.cut(world_state.request(world_state.WorldState.capacity, 0, 0));
    try t.expect(state.replayCut(req) == null);
    var batch = dispatcher.beginBatch(&slots, 0);
    dispatcher.execute(app, box, dispatcher.claimNext(&slots, &batch, 0).?);
    var snapshot: p.Snapshot = undefined;
    try t.expectEqualDeep(first, try reply(box, .cut, req.request_id, &snapshot));
    try t.expect(state.replayCut(req) == null);
    dispatcher.cleanup(box);

    try dispatcher.publishPrepared(box, session, request, replay);
    app.registry.release(session);
    batch = dispatcher.beginBatch(&slots, 0);
    dispatcher.execute(app, box, dispatcher.claimNext(&slots, &batch, 0).?);
    try t.expect((try reply(box, .cut, req.request_id, &snapshot)).failed == .invalid_request);
    try t.expect(box.close_after_reply);
    dispatcher.cleanup(box);
}
