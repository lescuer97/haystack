const std = @import("std");

// All phase transitions and condition predicates use this mutex. Completion is
// persistent, not a transient notification: idle and finished runs are completed.
pub const Completion = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    phase: enum { completed, starting, running } = .completed,

    pub fn beginLocked(self: *Completion) !void {
        if (self.phase != .completed) return error.AlreadyListening;
        self.phase = .starting;
    }

    pub fn readyLocked(self: *Completion, io: std.Io) void {
        std.debug.assert(self.phase == .starting);
        self.phase = .running;
        self.condition.broadcast(io);
    }

    pub fn completeLocked(self: *Completion, io: std.Io) void {
        std.debug.assert(self.phase != .completed);
        self.phase = .completed;
        self.condition.broadcast(io);
    }

    pub fn waitStartedLocked(self: *Completion, io: std.Io) void {
        self.waitStartedWithHooksLocked(io, struct {}{});
    }

    fn waitStartedWithHooksLocked(self: *Completion, io: std.Io, hooks: anytype) void {
        while (self.phase == .starting) {
            if (@hasDecl(@TypeOf(hooks), "beforeStartupWait")) hooks.beforeStartupWait();
            self.condition.waitUncancelable(io, &self.mutex);
        }
    }

    pub fn stopLocked(self: *Completion, io: std.Io, closer: anytype) void {
        self.stopWithHooksLocked(io, closer, struct {}{});
    }

    fn stopWithHooksLocked(self: *Completion, io: std.Io, closer: anytype, hooks: anytype) void {
        // A reserved listener thread may not have published its descriptors yet.
        self.waitStartedWithHooksLocked(io, hooks);
        if (self.phase == .completed) return;
        closer.close();
        while (self.phase != .completed) {
            if (@hasDecl(@TypeOf(hooks), "beforeWait")) hooks.beforeWait();
            self.condition.waitUncancelable(io, &self.mutex);
        }
    }
};

test "bounded-memory completion cannot be lost at stopper pre-wait boundary" {
    const Gate = @import("bounded_test_support.zig").Gate;
    const State = struct {
        completion: Completion = .{},
        before_wait: Gate = .{},
        completion_attempt: Gate = .{},
        published: std.atomic.Value(bool) = .init(false),
        returned: std.atomic.Value(bool) = .init(false),
        closes: usize = 0,
        const Self = @This();
        const Hooks = struct {
            state: *Self,
            pub fn beforeWait(self: @This()) void {
                // Exactly between the predicate check and atomic condition
                // wait; the stopper STILL owns the production protocol mutex.
                self.state.before_wait.arriveAndWait();
            }
        };

        pub fn close(self: *Self) void {
            self.closes += 1; // Mock descriptor operation only.
        }
        fn stop(self: *Self) void {
            const io = std.testing.io;
            self.completion.mutex.lockUncancelable(io);
            self.completion.stopWithHooksLocked(io, self, Hooks{ .state = self });
            self.completion.mutex.unlock(io);
            self.returned.store(true, .release);
        }
        fn complete(self: *Self) void {
            const io = std.testing.io;
            self.completion_attempt.notify();
            self.completion.mutex.lockUncancelable(io);
            self.completion.completeLocked(io);
            self.completion.mutex.unlock(io);
            self.published.store(true, .release);
        }
    };
    const io = std.testing.io;
    var state: State = .{};
    state.completion.mutex.lockUncancelable(io);
    try state.completion.beginLocked();
    state.completion.readyLocked(io);
    state.completion.mutex.unlock(io);
    {
        const stopper = try std.Thread.spawn(.{}, State.stop, .{&state});
        defer stopper.join();
        state.before_wait.waitArrived();
        const completer = std.Thread.spawn(.{}, State.complete, .{&state}) catch |err| {
            state.before_wait.release();
            state.complete();
            return err;
        };
        defer {
            state.before_wait.release();
            completer.join();
        }
        state.completion_attempt.waitArrived();
        // Completion cannot publish while the paused stopper owns the mutex.
        try std.testing.expect(!state.published.load(.acquire));
        try std.testing.expect(!state.returned.load(.acquire));
        state.before_wait.release();
    }
    try std.testing.expect(state.published.load(.acquire));
    try std.testing.expect(state.returned.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), state.closes);
    try std.testing.expectEqual(.completed, state.completion.phase);
}

test "bounded-memory persistent completion handles idle previous completion and startup failure" {
    const Gate = @import("bounded_test_support.zig").Gate;
    const State = struct {
        completion: Completion = .{},
        waiting: Gate = .{},
        closes: usize = 0,
        returned: bool = false,
        const Self = @This();
        const Hooks = struct {
            state: *Self,
            pub fn beforeWait(self: @This()) void {
                self.state.waiting.notify();
            }
            pub fn beforeStartupWait(self: @This()) void {
                self.state.waiting.notify();
            }
        };
        pub fn close(self: *Self) void {
            self.closes += 1;
        }
        fn stop(self: *Self) void {
            const io = std.testing.io;
            self.completion.mutex.lockUncancelable(io);
            self.completion.stopWithHooksLocked(io, self, Hooks{ .state = self });
            self.completion.mutex.unlock(io);
            self.returned = true;
        }
    };
    const io = std.testing.io;
    var state: State = .{};
    state.completion.mutex.lockUncancelable(io);
    // No active run: stop is a no-op, including repeated calls.
    state.completion.stopLocked(io, &state);
    state.completion.stopLocked(io, &state);
    // Normal completion BEFORE stop enters must also return without waiting.
    try state.completion.beginLocked();
    state.completion.readyLocked(io);
    state.completion.completeLocked(io);
    state.completion.stopLocked(io, &state);
    // This is also the production Thread.spawn failure/startup-error path:
    // the starting reservation completes without ever becoming ready.
    try state.completion.beginLocked();
    state.completion.completeLocked(io);
    state.completion.waitStartedLocked(io);
    state.completion.stopLocked(io, &state);
    state.completion.mutex.unlock(io);
    try std.testing.expectEqual(@as(usize, 0), state.closes);

    for ([_]bool{ false, true }) |startup_failure| {
        var waiting: State = .{};
        waiting.completion.mutex.lockUncancelable(io);
        try waiting.completion.beginLocked();
        try std.testing.expectError(error.AlreadyListening, waiting.completion.beginLocked());
        if (!startup_failure) waiting.completion.readyLocked(io);
        waiting.completion.mutex.unlock(io);
        {
            const stopper = try std.Thread.spawn(.{}, State.stop, .{&waiting});
            defer stopper.join();
            waiting.waiting.waitArrived();
            // Acquiring the same mutex after the hook notification ensures the
            // stopper has entered its atomic condition wait (no sleep needed).
            waiting.completion.mutex.lockUncancelable(io);
            const closes_before_completion = waiting.closes;
            waiting.completion.completeLocked(io);
            waiting.completion.mutex.unlock(io);
            try std.testing.expectEqual(@as(usize, if (startup_failure) 0 else 1), closes_before_completion);
        }
        try std.testing.expect(waiting.returned);
        try std.testing.expectEqual(.completed, waiting.completion.phase);
    }
}

test "bounded-memory startup handshake rechecks predicate after spurious notification" {
    const Gate = @import("bounded_test_support.zig").Gate;
    const State = struct {
        completion: Completion = .{},
        first_wait: Gate = .{},
        second_wait: Gate = .{},
        waits: usize = 0,
        returned: std.atomic.Value(bool) = .init(false),
        const Self = @This();
        const Hooks = struct {
            state: *Self,
            pub fn beforeStartupWait(self: @This()) void {
                self.state.waits += 1;
                if (self.state.waits == 1) self.state.first_wait.notify() else self.state.second_wait.notify();
            }
        };
        fn wait(self: *Self) void {
            const io = std.testing.io;
            self.completion.mutex.lockUncancelable(io);
            self.completion.waitStartedWithHooksLocked(io, Hooks{ .state = self });
            self.completion.mutex.unlock(io);
            self.returned.store(true, .release);
        }
    };
    const io = std.testing.io;
    for ([_]bool{ false, true }) |startup_failure| {
        var state: State = .{};
        state.completion.mutex.lockUncancelable(io);
        try state.completion.beginLocked();
        state.completion.mutex.unlock(io);
        {
            const waiter = try std.Thread.spawn(.{}, State.wait, .{&state});
            defer waiter.join();
            state.first_wait.waitArrived();
            state.completion.mutex.lockUncancelable(io);
            state.completion.condition.broadcast(io); // No readiness predicate change.
            state.completion.mutex.unlock(io);
            state.second_wait.waitArrived();
            // It has looped back into waiting instead of treating the signal
            // as readiness. Resolve startup before assertions can unwind.
            const returned_early = state.returned.load(.acquire);
            state.completion.mutex.lockUncancelable(io);
            if (startup_failure) state.completion.completeLocked(io) else state.completion.readyLocked(io);
            state.completion.mutex.unlock(io);
            try std.testing.expect(!returned_early);
        }
        try std.testing.expect(state.returned.load(.acquire));
        if (!startup_failure) {
            state.completion.mutex.lockUncancelable(io);
            state.completion.completeLocked(io);
            state.completion.mutex.unlock(io);
        }
    }
}

pub fn openListener(address: anytype, no_delay: bool, ops: anytype) !@typeInfo(@TypeOf(ops.open(address))).error_union.payload {
    const socket = try ops.open(address);
    errdefer ops.close(socket);
    try ops.configure(socket, no_delay);
    try ops.bind(socket, address);
    try ops.listen(socket);
    return socket;
}

// Ownership after start(): the thread owns the read end; this group owns the
// worker and thread handle. Published writers can be closed by Server.stop or
// this group; ops.closeSignal must atomically take/invalidate their ownership.
// Failed startup closes writers, joins, then destroys workers. Normal join also
// closes any writer left behind by a listener that returned without stop().
pub fn WorkerGroup(comptime W: type, comptime T: type, comptime Fd: type) type {
    return struct {
        allocator: std.mem.Allocator,
        workers: []W,
        threads: []T,
        signals: []Fd,
        started: usize = 0,
        initialized: usize = 0,
        joined: bool = false,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, signals: []Fd, listener: Fd, ops: anytype) !Self {
            const threads = try allocator.alloc(T, signals.len);
            errdefer allocator.free(threads);
            const workers = try allocator.alloc(W, signals.len);
            errdefer allocator.free(workers);
            var group: Self = .{ .allocator = allocator, .workers = workers, .threads = threads, .signals = signals };
            errdefer {
                group.stopAndJoin(ops);
                for (workers[0..group.initialized]) |*worker| ops.deinitWorker(worker);
            }
            for (0..signals.len) |i| {
                const pipe = try ops.pipe();
                var own_read = true;
                var own_write = true;
                defer if (own_read) ops.close(pipe[0]);
                defer if (own_write) ops.close(pipe[1]);

                try ops.initWorker(&workers[i]);
                group.initialized += 1;
                threads[i] = try ops.start(&workers[i], listener, pipe[0]);
                own_read = false;
                signals[i] = pipe[1];
                own_write = false;
                group.started += 1;
            }
            return group;
        }

        pub fn join(self: *Self, ops: anytype) void {
            if (self.joined) return;
            for (self.threads[0..self.started]) |thread| ops.join(thread);
            self.joined = true;
            for (self.signals[0..self.started]) |*signal| ops.closeSignal(signal);
        }

        fn stopAndJoin(self: *Self, ops: anytype) void {
            if (self.joined) return;
            for (self.signals[0..self.started]) |*signal| ops.closeSignal(signal);
            self.join(ops);
        }

        pub fn deinit(self: *Self, ops: anytype) void {
            self.stopAndJoin(ops);
            for (self.workers[0..self.initialized]) |*worker| ops.deinitWorker(worker);
            self.allocator.free(self.workers);
            self.allocator.free(self.threads);
        }
    };
}

test "bounded-memory listener guard closes exactly once on every prebind startup failure" {
    const Mock = struct {
        stage: enum { open, configure, bind, listen, success },
        resource: ?*u8 = null,
        closes: usize = 0,

        pub fn open(self: *@This(), _: u8) !usize {
            if (self.stage == .open) return error.InjectedFailure;
            self.resource = try std.testing.allocator.create(u8);
            return 1;
        }
        pub fn configure(self: *@This(), _: usize, _: bool) !void {
            if (self.stage == .configure) return error.InjectedFailure;
        }
        pub fn bind(self: *@This(), _: usize, _: u8) !void {
            if (self.stage == .bind) return error.InjectedFailure;
        }
        pub fn listen(self: *@This(), _: usize) !void {
            if (self.stage == .listen) return error.InjectedFailure;
        }
        pub fn close(self: *@This(), fd: usize) void {
            std.debug.assert(fd == 1 and self.closes == 0);
            self.closes += 1;
            std.testing.allocator.destroy(self.resource.?);
            self.resource = null;
        }
    };
    inline for (std.meta.tags(@FieldType(Mock, "stage"))) |stage| {
        var mock: Mock = .{ .stage = stage };
        if (stage == .success) {
            const fd = try openListener(@as(u8, 0), true, &mock);
            try std.testing.expectEqual(@as(usize, 0), mock.closes);
            mock.close(fd); // Ownership transferred to caller only on success.
        } else {
            try std.testing.expectError(error.InjectedFailure, openListener(@as(u8, 0), true, &mock));
        }
        try std.testing.expectEqual(@as(usize, if (stage == .open) 0 else 1), mock.closes);
        try std.testing.expectEqual(null, mock.resource);
    }
}

test "bounded-memory listener worker startup unwinds arrays pipes workers and thread handoff" {
    const Worker = struct { buffer: []u8, started: bool = false, joined: bool = false };
    const Handle = struct { read: usize, worker: *Worker };
    const Mock = struct {
        allocator: std.mem.Allocator,
        stage: enum { arrays, pipe, worker, spawn, success },
        fail_index: usize,
        pipe_index: usize = 0,
        worker_index: usize = 0,
        spawn_index: usize = 0,
        next_fd: usize = 1,
        closed: [5]bool = @splat(false),
        joins: usize = 0,
        starts: usize = 0,
        destroyed: usize = 0,
        early_return: bool = false,

        pub fn pipe(self: *@This()) ![2]usize {
            const index = self.pipe_index;
            self.pipe_index += 1;
            if (self.stage == .pipe and index == self.fail_index) return error.InjectedFailure;
            const read = self.next_fd;
            self.next_fd += 2;
            return .{ read, read + 1 };
        }
        pub fn close(self: *@This(), fd: usize) void {
            std.debug.assert(fd > 0 and fd < self.next_fd and !self.closed[fd]);
            self.closed[fd] = true;
        }
        pub fn closeSignal(self: *@This(), signal: *usize) void {
            if (signal.* == 0) return;
            self.close(signal.*);
            signal.* = 0;
        }
        pub fn initWorker(self: *@This(), worker: *Worker) !void {
            const index = self.worker_index;
            self.worker_index += 1;
            const buffer = try self.allocator.alloc(u8, 32);
            errdefer self.allocator.free(buffer);
            if (self.stage == .worker and index == self.fail_index) return error.InjectedFailure;
            worker.* = .{ .buffer = buffer };
        }
        pub fn start(self: *@This(), worker: *Worker, _: usize, read: usize) !Handle {
            const index = self.spawn_index;
            self.spawn_index += 1;
            if (self.stage == .spawn and index == self.fail_index) return error.InjectedFailure;
            worker.started = true;
            self.starts += 1;
            return .{ .read = read, .worker = worker };
        }
        pub fn join(self: *@This(), thread: Handle) void {
            // Stop must be signalled before join. The mock thread owns its
            // read end after a successful spawn, just like NonBlocking.run.
            std.debug.assert(self.early_return or self.closed[thread.read + 1]);
            self.close(thread.read);
            std.debug.assert(!thread.worker.joined);
            thread.worker.joined = true;
            self.joins += 1;
        }
        pub fn deinitWorker(self: *@This(), worker: *Worker) void {
            std.debug.assert(self.joins == self.starts);
            std.debug.assert(!worker.started or worker.joined);
            self.allocator.free(worker.buffer);
            self.destroyed += 1;
        }
    };
    inline for (std.meta.tags(@FieldType(Mock, "stage"))) |stage| {
        for (0..2) |fail_index| {
            var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{
                .fail_index = if (stage == .arrays) fail_index else std.math.maxInt(usize),
            });
            var mock: Mock = .{ .allocator = tracking.allocator(), .stage = stage, .fail_index = fail_index, .early_return = stage == .success and fail_index == 1 };
            var signals: [2]usize = undefined;
            const Group = WorkerGroup(Worker, Handle, usize);
            if (stage == .success) {
                var group = try Group.init(tracking.allocator(), &signals, 0, &mock);
                if (!mock.early_return) for (&signals) |*fd| mock.closeSignal(fd); // Simulated Server.stop.
                group.join(&mock);
                group.deinit(&mock);
                try std.testing.expectEqual(@as(usize, 2), mock.joins);
                try std.testing.expectEqual(@as(usize, 2), mock.destroyed);
            } else {
                try std.testing.expectError(if (stage == .arrays) error.OutOfMemory else error.InjectedFailure, Group.init(tracking.allocator(), &signals, 0, &mock));
                try std.testing.expectEqual(if (stage == .arrays) @as(usize, 0) else fail_index, mock.joins);
            }
            for (1..mock.next_fd) |fd| try std.testing.expect(mock.closed[fd]);
            try std.testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
        }
    }
}
