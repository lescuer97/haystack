//! Stable per-connection ownership; no borrowed request or context storage.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const sessions = @import("sessions.zig");
const application = @import("app.zig");
const App = application.App;

pub const Mailbox = struct {
    state: enum { idle, queued, executing, ready } = .idle,
    generation: u64 = 0,
    request: p.Request = undefined,
    session: sessions.Handle = undefined,
    abandoned: bool = false,
    close_after_reply: bool = false,
    reply: [p.max_response_bytes]u8 = undefined,
    len: usize = 0,
    completion: std.Io.Event = .unset,
};
pub const Record = struct { index: usize, generation: u64 };
pub const Work = struct { record: Record, request: p.Request, session: sessions.Handle };
pub const Batch = struct {
    records: [64]Record = undefined,
    len: usize = 0,
    next: usize = 0,
    start_ns: i128,
};

pub const Dispatcher = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cursor: usize = 0,
    stopping: bool = false,

    pub fn publish(self: *Dispatcher, box: *Mailbox, session: sessions.Handle, request: p.Request) !void {
        // Channel opens may borrow the WebSocket receive buffer.
        if (p.isChannel(std.meta.activeTag(request.operation))) return error.NotGameplayRequest;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.ServerStopping;
        if (box.state != .idle) return error.RequestPending;
        if (box.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        // Only the connection publishes, after its previous wait AND write ended.
        box.completion.reset();
        box.generation += 1;
        box.request = request;
        box.session = session;
        box.abandoned = false;
        box.close_after_reply = false;
        box.state = .queued;
    }

    pub fn beginBatch(self: *Dispatcher, slots: anytype, now_ns: i128) Batch {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var batch = Batch{ .start_ns = now_ns };
        std.debug.assert(slots.len <= batch.records.len);
        for (0..slots.len) |offset| {
            const index = (self.cursor + offset) % slots.len;
            const box = &slots[index].mailbox;
            if (box.state == .queued) {
                batch.records[batch.len] = .{ .index = index, .generation = box.generation };
                batch.len += 1;
            }
        }
        return batch;
    }

    /// Actual elapsed time is supplied by production's awake clock or a test clock.
    pub fn claimNext(self: *Dispatcher, slots: anytype, batch: *Batch, now_ns: i128) ?Work {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (now_ns - batch.start_ns >= shared.tick.interval_ns) return null;
        while (batch.next < batch.len) {
            const record = batch.records[batch.next];
            batch.next += 1;
            self.cursor = (record.index + 1) % slots.len;
            const box = &slots[record.index].mailbox;
            if (box.state != .queued or box.generation != record.generation) continue;
            box.state = .executing;
            return .{ .record = record, .request = box.request, .session = box.session };
        }
        return null;
    }

    /// Claimed execution has NO cancellation points. Registry locks are
    /// uncancelable, world actions are bounded RAM, and completion always signals.
    pub fn execute(self: *Dispatcher, app: *App, box: *Mailbox, work: Work) void {
        var close = false;
        const session = app.registry.get(work.session);
        if (session == null) {
            close = true;
            box.len = application.encodeCommonFailure(&box.reply, work.request, .invalid_request).len;
        } else switch (work.request.operation) {
            .update_location => |payload| {
                const req: p.RequestFor(.update_location) = .{ .request_id = work.request.request_id, .payload = payload };
                const outcome = app.handleLocation(work.session, req);
                close = outcome == .failed and app.registry.get(work.session) == null;
                const bytes = shared.wire.encodeReply(&box.reply, .update_location, req, outcome) catch unreachable;
                box.len = bytes.len;
            },
            .channel_requirements, .channel_open, .channel_payment, .channel_close => unreachable,
            inline .cut, .read_area => |payload, kind| {
                if (app.lease()) |context| {
                    defer app.release(context);
                    // Copy the encoded snapshot before returning the reusable context.
                    const bytes = context.handle(kind, .{ .request_id = work.request.request_id, .payload = payload }, session.?.pubkey);
                    @memcpy(box.reply[0..bytes.len], bytes);
                    box.len = bytes.len;
                } else {
                    box.len = application.encodeCommonFailure(&box.reply, work.request, .server_busy).len;
                }
            },
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(box.state == .executing and box.generation == work.record.generation);
        box.close_after_reply = close;
        box.state = .ready;
        box.completion.set(self.io);
    }

    /// Caller has ended its cancelable wait and any socket write. The reservation
    /// and session MUST remain owned until this returns, including cancellation.
    pub fn cleanup(self: *Dispatcher, box: *Mailbox) void {
        if (self.beginCleanup(box)) self.finishCleanup(box);
    }

    /// Split cleanup permits deterministic tests of the executing cancellation
    /// interleaving. A true result MUST be followed by finishCleanup before reuse.
    pub fn beginCleanup(self: *Dispatcher, box: *Mailbox) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (box.state == .executing) {
            box.abandoned = true;
            return true;
        }
        box.state = .idle;
        return false;
    }

    pub fn finishCleanup(self: *Dispatcher, box: *Mailbox) void {
        box.completion.waitUncancelable(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(box.state == .ready);
        box.state = .idle;
    }

    /// Tick exit cannot strand pending waiters. Already-ready replies stay owned
    /// by their connections. No execution is in flight when the sole owner exits.
    pub fn stop(self: *Dispatcher, slots: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stopping = true;
        for (slots) |*slot| {
            const box = &slot.mailbox;
            std.debug.assert(box.state != .executing);
            if (box.state != .queued) continue;
            box.len = application.encodeCommonFailure(&box.reply, box.request, .server_busy).len;
            box.close_after_reply = true;
            box.state = .ready;
            box.completion.set(self.io);
        }
    }
};
