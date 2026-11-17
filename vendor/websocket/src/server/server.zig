const std = @import("std");
const builtin = @import("builtin");

const posix = @import("../posix.zig");
const proto = @import("../proto.zig");
const buffer = @import("../buffer.zig");

const Io = std.Io;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const log = std.log.scoped(.websocket);

const OpCode = proto.OpCode;
const Reader = proto.Reader;
const Message = proto.Message;
pub const Handshake = @import("handshake.zig").Handshake;
const Compression = @import("../websocket.zig").Compression;
const FallbackAllocator = @import("fallback_allocator.zig").FallbackAllocator;
const lifecycle = @import("lifecycle.zig");

// The dispatcher has already stopped. Keep the loop and connection storage
// alive through queued callbacks AND their cleanup/rearm tails. A synchronous
// write can delay this join; shutdown never frees storage out from under it.
fn finishCallbacks(pool: anytype, base: anytype, loop: anytype) void {
    pool.stop();
    base.shutdown();
    pool.deinit();
    base.deinit();
    loop.deinit();
}

fn takeSignal(signal: *posix.fd_t) posix.fd_t {
    return @atomicRmw(posix.fd_t, signal, .Xchg, -1, .acq_rel);
}

fn closePublishedSignal(signal: *posix.fd_t) void {
    const fd = takeSignal(signal);
    if (fd != -1) posix.close(fd);
}

const ListenerOps = struct {
    pub fn open(_: ListenerOps, address: posix.Address) !posix.socket_t {
        var flags: u32 = posix.SOCK.STREAM | posix.CLOEXEC;
        if (!blockingMode()) flags |= posix.NONBLOCK;
        const protocol = if (address.any.family == posix.AF.UNIX) @as(u32, 0) else posix.IPPROTO.TCP;
        return posix.socket(address.any.family, flags, protocol);
    }

    pub fn configure(_: ListenerOps, socket: posix.socket_t, no_delay: bool) !void {
        if (no_delay) try posix.setsockopt(socket, posix.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));
        const option = if (@hasDecl(posix.SO, "REUSEPORT_LB")) posix.SO.REUSEPORT_LB else if (@hasDecl(posix.SO, "REUSEPORT")) posix.SO.REUSEPORT else posix.SO.REUSEADDR;
        try posix.setsockopt(socket, posix.SOL.SOCKET, option, &std.mem.toBytes(@as(c_int, 1)));
    }

    pub fn bind(_: ListenerOps, socket: posix.socket_t, address: posix.Address) !void {
        try posix.bind(socket, &address.any, address.getOsSockLen());
    }

    pub fn listen(_: ListenerOps, socket: posix.socket_t) !void {
        try posix.listen(socket, 1024);
    }

    pub fn close(_: ListenerOps, socket: posix.socket_t) void {
        posix.close(socket);
    }
};

const DEFAULT_MAX_CONN = 16_384;
const DEFAULT_BUFFER_SIZE = 2048;
const DEFAULT_MAX_MESSAGE_SIZE = 65_536;

const EMPTY_PONG = ([2]u8{ @backingInt(OpCode.pong), 0 })[0..];
// CLOSE, 2 length, code
const CLOSE_NORMAL = ([_]u8{ @backingInt(OpCode.close), 2, 3, 232 })[0..]; // code: 1000
const CLOSE_PROTOCOL_ERROR = ([_]u8{ @backingInt(OpCode.close), 2, 3, 234 })[0..]; //code: 1002

const force_blocking: bool = blk: {
    const build = @import("build");
    if (@hasDecl(build, "websocket_blocking")) {
        break :blk build.websocket_blocking;
    }
    break :blk false;
};

pub fn blockingMode() bool {
    if (force_blocking) {
        return true;
    }
    return switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => false,
        else => true,
    };
}

pub const Config = struct {
    port: u16 = 9882,
    address: []const u8 = "127.0.0.1",
    unix_path: ?[]const u8 = null,

    worker_count: ?u8 = null,

    max_conn: ?usize = null,
    max_message_size: ?usize = null,

    handshake: Config.Handshake = .{},
    thread_pool: ThreadPool = .{},
    buffers: Config.Buffers = .{},
    compression: ?Compression = null,

    pub const ThreadPool = struct {
        count: ?u16 = null,
        backlog: ?u32 = null,
        buffer_size: ?usize = null,
    };

    pub const Handshake = struct {
        timeout: u32 = 10,
        max_size: ?u16 = null,
        max_headers: ?u16 = null,
        max_res_headers: ?u16 = null,
        count: ?u16 = null,
    };

    pub const Buffers = struct {
        small_size: ?usize = null,
        small_pool: ?usize = null,
        large_size: ?usize = null,
        large_pool: ?u16 = null,
    };

    fn workerCount(self: *const Config) usize {
        if (comptime blockingMode()) {
            return 1;
        }
        return self.worker_count orelse 1;
    }
};

pub fn Server(comptime H: type) type {
    return struct {
        io: Io,
        config: Config,
        allocator: Allocator,

        _state: WorkerState,
        _signals: []posix.fd_t,
        _completion: lifecycle.Completion,

        const Self = @This();

        pub fn init(io: Io, allocator: Allocator, config: Config) !Self {
            if (blockingMode()) {
                if (config.buffers.small_pool) |p| {
                    if (p > 1) {
                        log.warn("blockingMode() cannot utilize a small buffer pool, using per-connection buffer instead", .{});
                    }
                }
            }

            if (config.compression != null) {
                log.err("Compression is disabled as part of the 0.15 upgrade. I do hope to re-enable it soon.", .{});
                return error.InvalidConfiguraion;
            }

            const signals = try allocator.alloc(posix.fd_t, config.workerCount());
            errdefer allocator.free(signals);
            @memset(signals, -1);

            var state = try WorkerState.init(io, allocator, config);
            errdefer state.deinit();

            return .{
                .io = io,
                ._completion = .{},
                ._state = state,
                ._signals = signals,
                .config = config,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self._state.deinit();
            self.allocator.free(self._signals);
        }

        pub fn listenInNewThread(self: *Self, ctx: anytype) !Thread {
            const io = self.io;
            const completion = &self._completion;
            completion.mutex.lockUncancelable(io);
            defer completion.mutex.unlock(io);
            // Reserve starting before spawning so neither this caller nor stop
            // can mistake the previous run's completed predicate for this run.
            try completion.beginLocked();
            const thrd = Thread.spawn(.{}, Self.listenReserved, .{ self, ctx }) catch |err| {
                completion.completeLocked(io);
                return err;
            };

            completion.waitStartedLocked(io);
            return thrd;
        }

        pub fn listen(self: *Self, ctx: anytype) !void {
            const io = self.io;
            const completion = &self._completion;
            {
                completion.mutex.lockUncancelable(io);
                defer completion.mutex.unlock(io);
                try completion.beginLocked();
            }
            return self.listenReserved(ctx);
        }

        fn listenReserved(self: *Self, ctx: anytype) !void {
            const io = self.io;
            const completion = &self._completion;
            completion.mutex.lockUncancelable(io);
            var locked = true;
            // Registered before resource guards: publish completion only after
            // all listener/callback joins and cleanup, including startup errors.
            defer {
                if (!locked) completion.mutex.lockUncancelable(io);
                completion.completeLocked(io);
                completion.mutex.unlock(io);
            }

            const config = &self.config;

            var no_delay = true;
            const address: posix.Address = blk: {
                if (config.unix_path) |path| {
                    if (comptime Io.net.has_unix_sockets == false) {
                        return error.UnixPathNotSupported;
                    }
                    no_delay = false;
                    Io.Dir.deleteFileAbsolute(io, path) catch {};
                    break :blk try posix.Address.initUnix(path);
                }

                const listen_port = config.port;
                const listen_address = config.address;
                break :blk try posix.Address.parseIp(listen_address, listen_port);
            };

            const socket = try lifecycle.openListener(address, no_delay, ListenerOps{});
            var own_socket = true;
            defer if (own_socket) posix.close(socket);

            const C = @TypeOf(ctx);

            if (comptime blockingMode()) {
                var w = try Blocking(H).init(io, self.allocator, &self._state);
                defer w.deinit();

                const thrd = try std.Thread.spawn(.{}, Blocking(H).run, .{ &w, socket, ctx });
                own_socket = false; // Server.stop now owns the blocking listener.
                log.info("starting blocking worker to listen on {f}", .{address});

                // this is what we'll shutdown when stop() is called
                self._signals[0] = socket;
                completion.readyLocked(io);
                locked = false;
                completion.mutex.unlock(io);
                thrd.join();
            } else {
                const W = NonBlocking(H, C);
                const Ops = struct {
                    io: Io,
                    allocator: Allocator,
                    state: *WorkerState,
                    ctx: C,
                    pub fn pipe(_: @This()) ![2]posix.fd_t {
                        return posix.pipe2(.{ .NONBLOCK = true });
                    }
                    pub fn close(_: @This(), fd: posix.fd_t) void {
                        posix.close(fd);
                    }
                    pub fn closeSignal(_: @This(), signal: *posix.fd_t) void {
                        closePublishedSignal(signal);
                    }
                    pub fn initWorker(ops: @This(), worker: *W) !void {
                        worker.* = try W.init(ops.io, ops.allocator, ops.state, ops.ctx);
                    }
                    pub fn start(_: @This(), worker: *W, listener: posix.fd_t, signal: posix.fd_t) !Thread {
                        return Thread.spawn(.{}, W.run, .{ worker, listener, signal });
                    }
                    pub fn join(_: @This(), thread: Thread) void {
                        thread.join();
                    }
                    pub fn deinitWorker(_: @This(), worker: *W) void {
                        worker.deinit();
                    }
                };
                const ops: Ops = .{ .io = io, .allocator = self.allocator, .state = &self._state, .ctx = ctx };
                var group = try lifecycle.WorkerGroup(W, Thread, posix.fd_t).init(self.allocator, self._signals, socket, ops);
                defer group.deinit(ops);

                log.info("starting nonblocking worker to listen on {f}", .{address});

                completion.readyLocked(io);
                locked = false;
                completion.mutex.unlock(io);

                group.join(ops);
            }
        }

        pub fn stop(self: *Self) void {
            const io = self.io;
            const completion = &self._completion;
            completion.mutex.lockUncancelable(io);
            defer completion.mutex.unlock(io);
            completion.stopLocked(io, struct {
                server: *Self,
                pub fn close(closer: @This()) void {
                    for (closer.server._signals) |*signal| {
                        const s = takeSignal(signal);
                        if (s == -1) continue;
                        if (blockingMode()) {
                            // Unblock accept on Linux in blocking mode.
                            posix.shutdown(s, .recv) catch {};
                        }
                        posix.close(s);
                    }
                }
            }{ .server = self });
        }
    };
}

// This is our Blocking worker. It's very different than NonBlocking and much simpler.
pub fn Blocking(comptime H: type) type {
    return struct {
        io: Io,
        allocator: Allocator,
        handshake_timeout: Timeout,
        connection_buffer_size: usize,
        conn_manager: ConnManager(H, false),
        handshake_pool: *Handshake.Pool,
        buffer_provider: *buffer.Provider,
        compression: ?Compression,

        const Timeout = struct {
            sec: u32,
            timeval: [@sizeOf(posix.timeval)]u8,

            // if sec is null, it means we want to cancel the timeout.
            fn init(sec: u32) Timeout {
                return .{
                    .sec = sec,
                    .timeval = std.mem.toBytes(posix.timeval{ .sec = @intCast(sec), .usec = 0 }),
                };
            }

            pub const none = std.mem.toBytes(posix.timeval{ .sec = 0, .usec = 0 });
        };

        const Self = @This();

        pub fn init(io: Io, allocator: Allocator, state: *WorkerState) !Self {
            const config = &state.config;

            var conn_manager = try ConnManager(H, false).init(io, allocator, config.compression);
            errdefer conn_manager.deinit();

            return .{
                .io = io,
                .conn_manager = conn_manager,
                .allocator = allocator,
                .compression = config.compression,
                .handshake_pool = state.handshake_pool,
                .buffer_provider = &state.buffer_provider,
                .handshake_timeout = Timeout.init(config.handshake.timeout),
                .connection_buffer_size = config.buffers.small_size orelse DEFAULT_BUFFER_SIZE,
            };
        }

        pub fn deinit(self: *Self) void {
            self.conn_manager.deinit();
        }

        pub fn run(self: *Self, listener: posix.socket_t, ctx: anytype) void {
            defer self.shutdown();
            while (true) {
                var address: posix.Address = undefined;
                var address_len: posix.socklen_t = @sizeOf(posix.Address);
                const socket = posix.accept(listener, &address.any, &address_len, posix.CLOEXEC) catch |err| {
                    if (err == error.ConnectionAborted or err == error.SocketNotListening or err == error.FileDescriptorNotASocket) {
                        log.info("received shutdown signal", .{});
                        return;
                    }
                    log.err("failed to accept socket: {}", .{err});
                    continue;
                };
                log.debug("({f}) connected", .{address});

                const thread = std.Thread.spawn(.{}, Self.handleConnection, .{ self, socket, address, ctx }) catch |err| {
                    posix.close(socket);
                    log.err("({f}) failed to spawn connection thread: {}", .{ address, err });
                    continue;
                };
                thread.detach();
            }
        }

        // Called in a thread started above in listen.
        // Wrapper around _handleConnection so that we can handle erros
        fn handleConnection(self: *Self, socket: posix.socket_t, address: posix.Address, ctx: anytype) void {
            self._handleConnection(socket, address, ctx) catch |err| {
                log.err("({f}) uncaught error in connection handler: {}", .{ address, err });
            };
        }

        fn _handleConnection(self: *Self, socket: posix.socket_t, address: posix.Address, ctx: anytype) !void {
            const io = self.io;
            const conn_manager = &self.conn_manager;
            const hc = try conn_manager.create(socket, address.toIOAddress(), timestamp(io));

            {
                // Do our handshake
                errdefer self.cleanupConn(hc);
                const timeout = self.handshake_timeout;
                const deadline = timestamp(io) + timeout.sec;
                try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout.timeval);

                while (true) {
                    const compression, const ok = handleHandshake(H, self, hc, ctx);
                    if (ok == false) {
                        self.cleanupConn(hc);
                        return;
                    }
                    if (hc.handler != null) {
                        // if we have a handler, the our handshake completed
                        if (compression) {
                            try conn_manager.setupCompression(hc);
                        }
                        break;
                    }
                    if (timestamp(io) > deadline) {
                        self.cleanupConn(hc);
                        return;
                    }
                }
            }

            return self.readLoop(hc);
        }

        // The readloop is extracted from _handleConnection so that it can be called
        // directly when integrating with an http server
        pub fn readLoop(self: *Self, hc: *HandlerConn(H)) !void {
            defer self.cleanupConn(hc);
            try posix.setsockopt(hc.socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &Timeout.none);

            // In BlockingMode, we always assign a reader for the duration of the connection
            // In scenarios where client rarely send data, this is going to use up an unecessary amount
            // of memory, but unlike nonblocking mode, we can't initialize the buffer just-in-time.
            const reader_buf = try self.allocator.alloc(u8, self.connection_buffer_size);
            defer self.allocator.free(reader_buf);

            hc.reader = Reader.init(reader_buf, self.buffer_provider, hc.compression);
            while (true) {
                if (handleClientData(H, hc, self.allocator, undefined) == false) {
                    break;
                }
            }
        }

        fn cleanupConn(self: *Self, hc: *HandlerConn(H)) void {
            hc.conn.closeSocket();
            self.conn_manager.cleanup(hc);
        }

        fn shutdown(self: *Self) void {
            var conn_manager = &self.conn_manager;
            conn_manager.shutdown(self);

            // wait up to 1 second for every connection to cleanly shutdown
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                if (conn_manager.count() == 0) {
                    return;
                }
                self.io.sleep(.fromMilliseconds(100), .awake) catch {};
            }
        }

        // called for each hc when shutting down
        fn shutdownCleanup(_: *Self, hc: *HandlerConn(H)) void {
            posix.shutdown(hc.socket, .recv) catch {};
        }
    };
}

fn NonBlocking(comptime H: type, comptime C: type) type {
    return struct {
        ctx: C,

        max_conn: usize,

        // KQueue or Epoll, depending on the platform
        loop: Loop,
        thread_pool: *ThreadPool,

        handshake_timeout: u32,
        handshake_pool: *Handshake.Pool,
        base: NonBlockingBase(H, true),
        compression: ?Compression,

        const Self = @This();
        const ThreadPool = @import("thread_pool.zig").ThreadPool(Self.dataAvailable);

        pub fn init(io: Io, allocator: Allocator, state: *WorkerState, ctx: C) !Self {
            var base = try NonBlockingBase(H, true).init(io, allocator, state);
            errdefer base.deinit();

            const loop = try Loop.init();
            errdefer loop.deinit();

            const config = &state.config;
            var thread_pool = try ThreadPool.init(io, allocator, .{
                .count = config.thread_pool.count orelse 4,
                .backlog = config.thread_pool.backlog orelse 500,
                .buffer_size = config.thread_pool.buffer_size orelse if (needsAllocator(H)) 32_768 else 0,
            });
            errdefer thread_pool.deinit();

            return .{
                .ctx = ctx,
                .loop = loop,
                .base = base,
                .thread_pool = thread_pool,
                .compression = config.compression,
                .handshake_pool = state.handshake_pool,
                .handshake_timeout = state.config.handshake.timeout,
                .max_conn = config.max_conn orelse DEFAULT_MAX_CONN,
            };
        }

        pub fn deinit(self: *Self) void {
            finishCallbacks(self.thread_pool, &self.base, &self.loop);
        }

        fn run(self: *Self, listener: posix.socket_t, signal: posix.fd_t) void {
            defer posix.close(signal); // Transferred by WorkerGroup only after spawn.
            const io = self.base.io;
            self.loop.monitorAccept(listener) catch |err| {
                log.err("failed to add monitor to listening socket: {}", .{err});
                return;
            };

            self.loop.monitorSignal(signal) catch |err| {
                log.err("failed to add monitor to signal pipe: {}", .{err});
                return;
            };

            const thread_pool = self.thread_pool;
            const conn_manager = &self.base.conn_manager;
            const handshake_timeout = self.handshake_timeout;

            var now = timestamp(io);
            var oldest_pending_start_time: ?u32 = null;
            while (true) {
                const handshake_cutoff = now - handshake_timeout;
                const timeout = self.prepareToWait(handshake_cutoff) orelse blk: {
                    if (oldest_pending_start_time) |started| {
                        break :blk if (started < handshake_cutoff) 1 else @as(i32, @intCast(started - handshake_cutoff));
                    }
                    break :blk null;
                };

                var it = self.loop.wait(timeout) catch |err| {
                    log.err("failed to wait on events: {}", .{err});
                    io.sleep(.fromMilliseconds(100), .awake) catch |err2| {
                        log.err("Failed to do a loop recovery sleep: {}", .{err2});
                    };
                    continue;
                };

                now = timestamp(io);
                oldest_pending_start_time = null;
                while (it.next()) |data| {
                    if (data == 0) {
                        self.accept(listener, now) catch |err| {
                            log.err("accept error: {}", .{err});
                            io.sleep(.fromMilliseconds(100), .awake) catch |err2| {
                                log.err("Failed to do a accept recovery sleep: {}", .{err2});
                            };
                        };
                        continue;
                    }

                    if (data == 1) {
                        // Stop dispatch only. deinit joins all queued/active
                        // callbacks before walking any connection storage.
                        return;
                    }

                    const hc: *HandlerConn(H) = @ptrFromInt(data);
                    conn_manager.dispatch(hc, &oldest_pending_start_time, .{});
                    // spawn can block: dispatch has already released cm.lock.
                    thread_pool.spawn(.{ self, hc });
                }
            }
        }

        // Enforces timeouts, and returns when the next timeout should be checked.
        fn prepareToWait(self: *Self, cutoff: u32) ?i32 {
            return self.base.conn_manager.retirePending(cutoff, RawHandshakeClose{});
        }

        fn accept(self: *Self, listener: posix.fd_t, now: u32) !void {
            const max_conn = self.max_conn;
            const conn_manager = &self.base.conn_manager;

            // A level-triggered listener must be drained even at capacity, but
            // bounded work leaves time for established connections in this batch.
            var batch: @import("rejection.zig").Batch = .{};
            while (batch.next()) {
                var address: posix.Address = undefined;
                var address_len: posix.socklen_t = @sizeOf(posix.Address);

                const socket = posix.accept(listener, &address.any, &address_len, posix.CLOEXEC | posix.NONBLOCK) catch |err| {
                    // When available, we use SO_REUSEPORT_LB or SO_REUSEPORT, so WouldBlock
                    // should not be possible in those cases, but if it isn't available
                    // this error should be ignored as it means another thread picked it up.
                    return if (err == error.WouldBlock) {} else err;
                };

                if (conn_manager.count() >= max_conn) {
                    @import("rejection.zig").reject(socket, @import("rejection.zig").Raw{});
                    continue;
                }

                log.debug("({f}) connected", .{address});

                {
                    errdefer posix.close(socket);
                    // socket is _probably_ in NONBLOCKING mode (it inherits
                    // the flag from the listening socket).
                    const flags = try posix.fcntl(socket, posix.F.GETFL, 0);
                    const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
                    if (flags & nonblocking == nonblocking) {
                        // Yup, it's in nonblocking mode. Disable that flag to
                        // put it in blocking mode.
                        _ = try posix.fcntl(socket, posix.F.SETFL, flags & ~nonblocking);
                    }
                }
                const hc = try self.base.newConn(socket, address.toIOAddress(), now);
                self.loop.monitorRead(hc, false) catch |err| {
                    self.base.cleanupConn(hc);
                    return err;
                };
            }
        }

        // Dispatch reserves the active record before enqueueing. Keep ownership
        // through parsing and the cleanup tail, then hand off under cm.lock.
        // Shutdown stops dispatch and joins callbacks before freeing records.
        fn dataAvailable(self: *Self, hc: *HandlerConn(H), thread_buf: []u8) void {
            return readCallback(self, hc, thread_buf, .{});
        }

        fn processRead(self: *Self, hc: *HandlerConn(H), thread_buf: []u8) bool {
            if (hc.handler == null) {
                return self.dataForHandshake(hc) catch |err| {
                    log.err("({f}) error processing handshake: {}", .{ hc.conn.address, err });
                    return false;
                };
            }
            return self.base.dataAvailable(hc, thread_buf);
        }

        fn cleanupRead(self: *Self, hc: *HandlerConn(H)) void {
            hc.conn.closeSocket();
            self.base.cleanupConn(hc);
        }

        fn dataForHandshake(self: *Self, hc: *HandlerConn(H)) !bool {
            var conn_manager = &self.base.conn_manager;
            const compression, const ok = handleHandshake(H, self, hc, self.ctx);
            if (ok == false) {
                return false;
            }

            if (compression) {
                try conn_manager.setupCompression(hc);
            }
            return true;
        }
    };
}

const RawHandshakeClose = struct {
    fn close(_: @This(), conn: *Conn) void {
        conn.closeSocket();
        log.debug("({f}) handshake timeout", .{conn.address});
    }
};

// Shared by production callbacks and socket-free ownership fixtures. Pending
// means no queued/running owner. Never take cleanup while holding cm.lock.
fn readCallback(worker: anytype, hc: anytype, thread_buf: []u8, hooks: anytype) void {
    const io = worker.base.io;
    const cm = &worker.base.conn_manager;
    const success = blk: {
        hc.cleanup.lockUncancelable(io);
        defer hc.cleanup.unlock(io);
        break :blk worker.processRead(hc, thread_buf);
    };
    if (!success or hc.conn.isClosed()) {
        worker.cleanupRead(hc);
        return;
    }
    if (@hasDecl(@TypeOf(hooks), "beforeHandoff")) hooks.beforeHandoff();
    cm.lock.lockUncancelable(io);
    worker.loop.monitorRead(hc, true) catch {
        // Still active and exclusively owned. Cleanup reacquires cm.lock.
        cm.lock.unlock(io);
        worker.cleanupRead(hc);
        return;
    };
    if (hc.handler == null) cm.inactiveLocked(hc);
    if (@hasDecl(@TypeOf(hooks), "published")) hooks.published();
    // Ownership handoff: no hc access (including cleanup unlocks) after this.
    cm.lock.unlock(io);
    return;
}

fn NonBlockingBase(comptime H: type, comptime MANAGE_HS: bool) type {
    return struct {
        io: Io,

        allocator: Allocator,

        buffer_provider: *buffer.Provider,

        // App can configure the use of a "small" buffer pool. This is the difference
        // between assigning a buffer to the connection just-in-time per message, or always
        small_buffer_pool: ?buffer.Pool,
        connection_buffer_size: usize,

        conn_manager: ConnManager(H, MANAGE_HS),

        const Self = @This();

        fn init(io: Io, allocator: Allocator, state: *WorkerState) !Self {
            const config = &state.config;

            var conn_manager = try ConnManager(H, MANAGE_HS).init(io, allocator, config.compression);
            errdefer conn_manager.deinit();
            try conn_manager.pool.addCapacity(allocator, config.max_conn orelse DEFAULT_MAX_CONN);
            conn_manager.limit = config.max_conn orelse DEFAULT_MAX_CONN;

            const connection_buffer_size = config.buffers.small_size orelse DEFAULT_BUFFER_SIZE;
            var small_buffer_pool: ?buffer.Pool = null;
            if ((config.buffers.small_pool orelse (config.max_conn orelse DEFAULT_MAX_CONN)) > 0) {
                const pool_count = config.buffers.small_pool orelse (config.max_conn orelse DEFAULT_MAX_CONN);
                small_buffer_pool = try buffer.Pool.init(io, allocator, pool_count, connection_buffer_size);
            }

            errdefer if (small_buffer_pool) |sbp| {
                sbp.deinit();
            };

            return .{
                .io = io,
                .allocator = allocator,
                .conn_manager = conn_manager,
                .small_buffer_pool = small_buffer_pool,
                .buffer_provider = &state.buffer_provider,
                .connection_buffer_size = connection_buffer_size,
            };
        }

        fn deinit(self: *Self) void {
            self.conn_manager.deinit();
            if (self.small_buffer_pool) |*sbp| {
                sbp.deinit();
            }
        }

        fn newConn(self: *Self, socket: posix.socket_t, address: Io.net.IpAddress, time: u32) !*HandlerConn(H) {
            return self.conn_manager.create(socket, address, time);
        }

        pub fn dataAvailable(self: *Self, hc: *HandlerConn(H), thread_buf: []u8) bool {
            return self._dataAvailable(hc, thread_buf) catch |err| {
                log.err("({f}) error processing client message: {}", .{ hc.conn.address, err });
                return false;
            };
        }

        fn _dataAvailable(self: *Self, hc: *HandlerConn(H), thread_buf: []u8) !bool {
            if (hc.reader == null) {
                const reader_buf = if (self.small_buffer_pool) |*sbp| try sbp.acquireOrCreate() else try self.allocator.alloc(u8, self.connection_buffer_size);
                hc.reader = Reader.init(reader_buf, self.buffer_provider, hc.compression);
            }
            const reader = &hc.reader.?;

            var fba = FixedBufferAllocator.init(thread_buf);
            const ok = handleClientData(H, hc, self.allocator, &fba);

            if (self.small_buffer_pool) |*sbp| {
                if (reader.isEmpty()) {
                    reader.deinit();
                    sbp.release(reader.static);
                    hc.reader = null;
                }
            }

            return ok;
        }

        fn cleanupConn(self: *Self, hc: *HandlerConn(H)) void {
            const io = self.io;
            {
                hc.cleanup.lockUncancelable(io);
                defer hc.cleanup.unlock(io);
                if (hc.reader) |*reader| {
                    reader.deinit();
                    if (self.small_buffer_pool) |*sbp| {
                        sbp.release(reader.static);
                    } else {
                        self.allocator.free(reader.static);
                    }
                    hc.reader = null;
                }
            }
            self.conn_manager.cleanup(hc);
        }

        fn shutdown(self: *Self) void {
            log.info("received shutdown signal", .{});
            self.shutdownWith(struct {
                fn close(_: @This(), hc: *HandlerConn(H)) void {
                    hc.conn.closeSocket();
                }
            }{});
        }

        // Called only after dispatch and callbacks have quiesced. No manager
        // lock is held across handler close hooks or per-connection cleanup.
        fn shutdownWith(self: *Self, closer: anytype) void {
            while (self.conn_manager.active.head) |hc| {
                closer.close(hc);
                self.cleanupConn(hc);
            }
            while (self.conn_manager.pending.head) |hc| {
                closer.close(hc);
                self.cleanupConn(hc);
            }
        }
    };
}

const Loop = switch (@import("builtin").os.tag) {
    .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => KQueue,
    .linux => EPoll,
    else => unreachable,
};

const KQueue = struct {
    q: i32,
    change_count: usize,
    change_buffer: [16]Kevent,
    event_list: [64]Kevent,

    const Kevent = posix.Kevent;

    fn init() !KQueue {
        return .{
            .q = try posix.kqueue(),
            .change_count = 0,
            .change_buffer = undefined,
            .event_list = undefined,
        };
    }

    fn deinit(self: KQueue) void {
        posix.close(self.q);
    }

    fn monitorAccept(self: *KQueue, fd: c_int) !void {
        try self.change(fd, 0, posix.system.EVFILT.READ, posix.system.EV.ADD);
    }

    fn monitorSignal(self: *KQueue, fd: c_int) !void {
        try self.change(fd, 1, posix.system.EVFILT.READ, posix.system.EV.ADD);
    }

    // Normally, we add the socket in the worker thread with rearm == false.
    // Because this is a DISPATCH, it'll only fire once until we rearm it which
    // we do by re-enabling it with rearm == true.
    // However, notice that the rearm path also has the EV.ADD flag. From the above
    // description, this should not be necessary.
    // But monitorRead where rearm == true is also used by our generic ServerLoop when
    // taking over a connection (say from httpz). Hence, we need the EV.ADD flag too.
    fn monitorRead(self: *KQueue, hc: anytype, comptime rearm: bool) !void {
        if (rearm == false) {
            return self.change(hc.socket, @intFromPtr(hc), posix.system.EVFILT.READ, posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.DISPATCH);
        }
        const event = Kevent{
            .ident = @intCast(hc.socket),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.DISPATCH,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(hc),
        };
        _ = try posix.kevent(self.q, &.{event}, &[_]Kevent{}, null);
    }

    fn change(self: *KQueue, fd: posix.fd_t, data: usize, filter: i16, flags: u16) !void {
        var change_count = self.change_count;
        var change_buffer = &self.change_buffer;

        if (change_count == change_buffer.len) {
            // calling this with an empty event_list will return immediate
            _ = try posix.kevent(self.q, change_buffer, &[_]Kevent{}, null);
            change_count = 0;
        }
        change_buffer[change_count] = .{
            .ident = @intCast(fd),
            .filter = filter,
            .flags = flags,
            .fflags = 0,
            .data = 0,
            .udata = data,
        };
        self.change_count = change_count + 1;
    }

    fn wait(self: *KQueue, timeout_sec: ?i32) !Iterator {
        const event_list = &self.event_list;
        const timeout: ?posix.timespec = if (timeout_sec) |ts| posix.timespec{ .sec = ts, .nsec = 0 } else null;
        const event_count = try posix.kevent(self.q, self.change_buffer[0..self.change_count], event_list, if (timeout) |ts| &ts else null);
        self.change_count = 0;

        return .{
            .index = 0,
            .events = event_list[0..event_count],
        };
    }

    const Iterator = struct {
        index: usize,
        events: []Kevent,

        fn next(self: *Iterator) ?usize {
            const index = self.index;
            const events = self.events;
            if (index == events.len) {
                return null;
            }
            self.index = index + 1;
            return self.events[index].udata;
        }
    };
};

const EPoll = struct {
    q: i32,
    event_list: [64]EpollEvent,

    const linux = std.os.linux;
    const EpollEvent = linux.epoll_event;

    fn init() !EPoll {
        return .{
            .event_list = undefined,
            .q = try posix.epoll_create1(0),
        };
    }

    fn deinit(self: EPoll) void {
        posix.close(self.q);
    }

    fn monitorAccept(self: *EPoll, fd: c_int) !void {
        var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .ptr = 0 } };
        return posix.epoll_ctl(self.q, linux.EPOLL.CTL_ADD, fd, &event);
    }

    fn monitorSignal(self: *EPoll, fd: c_int) !void {
        var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .ptr = 1 } };
        return posix.epoll_ctl(self.q, linux.EPOLL.CTL_ADD, fd, &event);
    }

    fn monitorRead(self: *EPoll, hc: anytype, comptime rearm: bool) !void {
        const op = if (rearm) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD;
        var event = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ONESHOT, .data = .{ .ptr = @intFromPtr(hc) } };
        return posix.epoll_ctl(self.q, op, hc.socket, &event);
    }

    fn wait(self: *EPoll, timeout_sec: ?i32) !Iterator {
        const event_list = &self.event_list;
        var timeout: i32 = -1;
        if (timeout_sec) |sec| {
            if (sec > 2147483) {
                // max supported timeout by epoll_wait.
                timeout = 2147483647;
            } else {
                timeout = sec * 1000;
            }
        }

        const event_count = posix.epoll_wait(self.q, event_list, timeout);
        return .{
            .index = 0,
            .events = event_list[0..event_count],
        };
    }

    const Iterator = struct {
        index: usize,
        events: []EpollEvent,

        fn next(self: *Iterator) ?usize {
            const index = self.index;
            const events = self.events;
            if (index == events.len) {
                return null;
            }
            self.index = index + 1;
            return self.events[index].data.ptr;
        }
    };
};

// We want to extract as much common logic as possible from the Blocking and
// NonBlockign workers. The code from this point on is meant to be used with
// both workers, independently from the blocking/nonblocking nonsense.

// Abstraction ontop of NonBlocking and Blocking. Exists solely for integration
// with httpz (or any other http library I guess.). Serves a similar purpose
// as Server, but doesn't accept/listen.
pub fn Worker(comptime H: type) type {
    return struct {
        worker: W,

        const Self = @This();
        const W = if (blockingMode()) Blocking(H) else NonBlockingBase(H, false);

        pub fn init(io: Io, allocator: Allocator, state: *WorkerState) !Self {
            return .{
                .worker = try W.init(io, allocator, state),
            };
        }

        pub fn deinit(self: *Self) void {
            self.worker.deinit();
        }

        pub fn createConn(self: *Self, socket: posix.socket_t, address: Io.net.IpAddress, now: u32) !*HandlerConn(H) {
            return self.worker.conn_manager.create(socket, address, now);
        }

        pub fn cleanupConn(self: *Self, hc: *HandlerConn(H)) void {
            self.worker.cleanupConn(hc);
        }

        pub fn canCompress(self: *const Self) bool {
            return self.worker.conn_manager.compression != null;
        }

        pub fn setupConnection(
            self: *Self,
            hc: *HandlerConn(H),
        ) !void {
            return self.worker.conn_manager.setupCompression(hc);
        }

        pub fn shutdown(self: *Self) void {
            self.worker.shutdown();
        }
    };
}

// These are things that both the Blocking and NonBlocking workers need. Just cleaner
// to have a single place for it. This could used to be directly in Server(H), with
// Server(H) having handshake_pool and buffer_provider fields, but it was extracted
// into its own struct for integration with webservers (i.e. httpz). The goal is
// that a webserver can have websocket support without starting a full Server.
pub const WorkerState = struct {
    config: Config,
    handshake_pool: *Handshake.Pool,
    buffer_provider: buffer.Provider,

    pub fn init(io: Io, allocator: Allocator, config: Config) !WorkerState {
        const handshake_pool_count = @max(config.handshake.count orelse 32, (config.max_conn orelse DEFAULT_MAX_CONN) * config.workerCount());
        const handshake_max_size = config.handshake.max_size orelse 1024;
        const handshake_max_headers = config.handshake.max_headers orelse 10;
        const handshake_max_res_headers = config.handshake.max_res_headers orelse 2;

        var handshake_pool = try Handshake.Pool.init(io, allocator, handshake_pool_count, handshake_max_size, handshake_max_headers, handshake_max_res_headers);
        errdefer handshake_pool.deinit();

        const max_message_size = config.max_message_size orelse DEFAULT_MAX_MESSAGE_SIZE;
        const large_buffer_pool = config.buffers.large_pool orelse 8;
        const large_buffer_size = config.buffers.large_size orelse @min((config.buffers.small_size orelse DEFAULT_BUFFER_SIZE) * 2, max_message_size);

        var buffer_provider = try buffer.Provider.init(io, allocator, .{
            .max = max_message_size,
            .size = large_buffer_size,
            .count = large_buffer_pool,
        });
        errdefer buffer_provider.deinit();

        return .{
            .config = config,
            .handshake_pool = handshake_pool,
            .buffer_provider = buffer_provider,
        };
    }

    pub fn deinit(self: *WorkerState) void {
        self.handshake_pool.deinit();
        self.buffer_provider.deinit();
    }
};

// In the Blocking worker, all the state could be stored on the spawn'd threads
// stack. The only reason we use a HandlerConn(H) in there is to be able to re-use
// code with the NonBlocking worker.
//
// For the NonBlocking worker, HandlerConn(H) is critical as it contains all the
// state for a connection. It lives on the heap, a pointer is registered into
// the event loop, and passed back when data is ready to read.
// * If handler is null, it means we haven't done our handshake yet.
// * If handler is null AND handshake is null, it means we havent' received
//   any data yet (we delay creating the handshake state until we at least have
//   some data ready).
pub fn HandlerConn(comptime H: type) type {
    return struct {
        state: State,
        conn: Conn,
        handler: ?H,
        reader: ?Reader,
        socket: posix.socket_t, // denormalization from conn.stream.handle
        handshake: ?*Handshake.State,
        cleanup: Io.Mutex = .init,
        compression: ?Compression = null,
        next: ?*HandlerConn(H) = null,
        prev: ?*HandlerConn(H) = null,

        const State = enum {
            handshake,
            active,
        };
    };
}

pub fn ConnManager(comptime H: type, comptime MANAGE_HS: bool) type {
    return struct {
        io: Io,
        lock: Io.Mutex,
        allocator: Allocator,
        active: List(HandlerConn(H)),
        pending: List(HandlerConn(H)),
        pool: std.heap.MemoryPool(HandlerConn(H)),
        compression: ?Compression,
        compression_pool: std.heap.MemoryPool(Conn.Compression),
        limit: usize = std.math.maxInt(usize),

        const Self = @This();

        pub fn init(io: Io, allocator: Allocator, compression: ?Compression) !Self {
            var pool: std.heap.MemoryPool(HandlerConn(H)) = .empty;
            errdefer pool.deinit(allocator);

            var compression_pool: std.heap.MemoryPool(Conn.Compression) = .empty;
            errdefer compression_pool.deinit(allocator);

            return .{
                .io = io,
                .lock = .init,
                .pool = pool,
                .active = .{},
                .pending = .{},
                .allocator = allocator,
                .compression = compression,
                .compression_pool = compression_pool,
            };
        }

        pub fn deinit(self: *Self) void {
            self.pool.deinit(self.allocator);
            self.compression_pool.deinit(self.allocator);
        }

        pub fn count(self: *Self) usize {
            const io = self.io;
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            if (MANAGE_HS == false) {
                return self.active.len;
            }
            return self.active.len + self.pending.len;
        }

        pub fn create(self: *Self, socket: posix.socket_t, address: Io.net.IpAddress, now: u32) !*HandlerConn(H) {
            const io = self.io;
            errdefer posix.close(socket);

            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);

            const hc = try self.acquireRecord();
            hc.* = .{
                .state = if (MANAGE_HS) .handshake else .active,
                .socket = socket,
                .handler = null,
                .handshake = null,
                .reader = null,
                .compression = null,
                .conn = .{
                    .io = io,
                    ._closed = false,
                    .started = now,
                    .address = address,
                    .stream = .{ .socket = .{ .handle = socket, .address = address } },
                    .compression = null,
                },
            };

            if (comptime MANAGE_HS) {
                // Still waiting for a handshake. Only care about this with the full
                // NonBlocking worker
                self.pending.insert(hc);
            } else {
                self.active.insert(hc);
            }
            return hc;
        }

        // Caller holds lock (or is a single-threaded, socket-free unit test).
        fn acquireRecord(self: *Self) !*HandlerConn(H) {
            if (self.active.len + self.pending.len >= self.limit) return error.OutOfMemory;
            return self.pool.create(self.allocator);
        }

        pub fn activate(self: *Self, hc: *HandlerConn(H)) void {
            const io = self.io;
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            self.activateLocked(hc);
        }

        fn activateLocked(self: *Self, hc: *HandlerConn(H)) void {
            std.debug.assert(MANAGE_HS == true);
            std.debug.assert(hc.state == .handshake);
            self.pending.remove(hc);
            self.active.insert(hc);
            hc.state = .active;
        }

        fn inactiveLocked(self: *Self, hc: *HandlerConn(H)) void {
            std.debug.assert(MANAGE_HS == true);

            // this should only be called when we need more data to complete the handshake
            // which should only happen on an active connection
            std.debug.assert(hc.state == .active);

            hc.state = .handshake;
            self.active.remove(hc);
            self.pending.insert(hc);
        }

        fn dispatch(self: *Self, hc: *HandlerConn(H), oldest: *?u32, hooks: anytype) void {
            const io = self.io;
            if (@hasDecl(@TypeOf(hooks), "beforeLock")) hooks.beforeLock();
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            // Established readiness must also wait for the previous handoff.
            if (hc.state == .handshake) {
                oldest.* = if (oldest.*) |s| @min(s, hc.conn.started) else hc.conn.started;
                self.activateLocked(hc);
            }
        }

        fn retirePending(self: *Self, cutoff: u32, ops: anytype) ?i32 {
            const io = self.io;
            if (@hasDecl(@TypeOf(ops), "beforeLock")) ops.beforeLock();
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            var next = self.pending.head;
            while (next) |hc| {
                const started = hc.conn.started;
                if (started > cutoff) return @intCast(started - cutoff);
                next = hc.next;
                // Pending records have no callback owner; no cleanup mutex needed.
                ops.close(&hc.conn);
                if (hc.handshake) |h| h.release();
                self.pending.remove(hc);
                self.pool.destroy(hc);
            }
            return null;
        }

        pub fn cleanup(self: *Self, hc: *HandlerConn(H)) void {
            if (hc.handshake) |h| {
                h.release();
            }

            if (hc.reader) |*r| {
                r.deinit();
            }

            if (hc.handler) |*h| {
                if (comptime std.meta.hasFn(H, "close")) {
                    h.close();
                }
                hc.handler = null;
            }

            if (hc.conn.compression) |c| {
                c.writer.deinit();
            }

            const io = self.io;
            self.lock.lockUncancelable(io);
            if (hc.state == .active) {
                self.active.remove(hc);
            } else {
                self.pending.remove(hc);
            }

            if (hc.conn.compression) |c| {
                self.compression_pool.destroy(c);
            }

            self.pool.destroy(hc);
            self.lock.unlock(io);
        }

        fn setupCompression(self: *Self, hc: *HandlerConn(H)) !void {
            const config = self.compression orelse return;

            hc.compression = config;

            if (config.write_threshold == null) {
                // if write_treshold is null, then we never want to compress
                // outgoing messages. We don't need to set the conn.compression
                // field.
                // We'll still [potentially] decompress incoming messages, but
                // that's set on the proto.
                return;
            }

            const compression = try self.compression_pool.create(self.allocator);
            errdefer self.compression_pool.destroy(compression);

            compression.* = .{
                .allocator = self.allocator,
                .write_treshold = config.write_threshold.?,
                .retain_writer = config.retain_write_buffer,
                .writer = std.Io.Writer.Allocating.init(self.allocator),
            };
            hc.conn.compression = compression;
        }

        pub fn shutdown(self: *Self, worker: anytype) void {
            const io = self.io;
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);

            shutdownList(io, self.active.head, worker);
            shutdownList(io, self.pending.head, worker);
        }

        // This is sloppy and leaves things in an unrecoverable state. To keep
        // things clean, we should call self.cleanup(hc) on each entry in the list
        // but that does a bunch of things we don't need if we know that we're
        // shutting down - like returning data to the pools, and popping items
        // out of the list.
        fn shutdownList(io: Io, head: ?*HandlerConn(H), worker: anytype) void {
            var next_node = head;
            while (next_node) |hc| {
                if (comptime std.meta.hasFn(H, "close")) {
                    hc.cleanup.lockUncancelable(io);
                    defer hc.cleanup.unlock(io);
                    if (hc.handler) |*h| {
                        h.close();
                        hc.handler = null;
                    }
                }

                worker.shutdownCleanup(hc);
                const conn = &hc.conn;
                conn.closeSocket();
                next_node = hc.next;
            }
        }
    };
}

// This is what actually gets exposed to the app
pub const Conn = struct {
    io: Io,
    _closed: bool,
    _fd_closed: bool = false,
    started: u32,
    stream: Io.net.Stream,
    address: Io.net.IpAddress,
    lock: Io.Mutex = .init,
    compression: ?*Conn.Compression = null,

    const Compression = struct {
        allocator: Allocator,
        retain_writer: bool,
        write_treshold: usize,
        writer: std.Io.Writer.Allocating,
    };

    pub fn isClosed(self: *Conn) bool {
        // don't use lock to protect _closed. `isClosed` is called from
        // the worker thread and we don't want that potentially blocked while
        // a write is going on.
        return @atomicLoad(bool, &self._closed, .monotonic);
    }

    pub fn writeBin(self: *Conn, data: []const u8) !void {
        return self.writeFrame(.binary, data);
    }

    pub fn writeText(self: *Conn, data: []const u8) !void {
        return self.writeFrame(.text, data);
    }

    pub fn write(self: *Conn, data: []const u8) !void {
        return self.writeFrame(.text, data);
    }

    pub fn writePing(self: *Conn, data: []u8) !void {
        return self.writeFrame(.ping, data);
    }

    pub fn writePong(self: *Conn, data: []u8) !void {
        return self.writeFrame(.pong, data);
    }

    const CloseOpts = struct {
        code: u16 = 1000,
        reason: []const u8 = "",
    };

    /// Sends a close frame and closes the connection. Safe to call from any
    /// thread: the socket is only shut down here, which wakes the thread that
    /// owns the connection.
    pub fn close(self: *Conn, opts: CloseOpts) !void {
        if (self.isClosed()) {
            return;
        }
        defer self.shutdownSocket();

        const reason = opts.reason;
        if (reason.len == 0) {
            var buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &buf, opts.code, .big);
            return self.writeFrame(.close, &buf);
        }

        if (reason.len > 123) {
            return error.ReasonTooLong;
        }

        var buf: [4]u8 = undefined;
        buf[0] = @backingInt(OpCode.close);
        buf[1] = @intCast(reason.len + 2);
        std.mem.writeInt(u16, buf[2..], opts.code, .big);

        var vec = [2]posix.iovec_const{
            .{ .len = buf.len, .base = &buf },
            .{ .len = reason.len, .base = reason.ptr },
        };

        try writeAllIOVec(self, &vec);
    }

    pub fn writeFrame(self: *Conn, op_code: OpCode, data: []const u8) !void {
        const payload = data;

        // Zig 0.15 compression disabled
        const compressed = false;
        // if (self.compression) |c| {
        //     if (data.len >= c.write_treshold) {
        //         compressed = true;
        //         var compressor = std.compress.flate.Compress.init(&c.writer.writer, &.{}, .{});
        //         try compressor.writer.writeAll(data);
        //         try compressor.writer.flush();
        //         const all = c.writer.written();
        //         payload = all[0 .. all.len - 4];
        //     }
        // }

        // defer if (compressed) {
        //     const c = self.compression.?;
        //     if (c.retain_writer) {
        //         c.writer.clearRetainingCapacity();
        //     } else {
        //         c.writer.deinit();
        //         c.writer = std.Io.Writer.Allocating.init(c.allocator);
        //     }
        // };

        // maximum possible prefix length. op_code + length_type + 8byte length
        var buf: [10]u8 = undefined;
        const header = proto.writeFrameHeader(&buf, op_code, payload.len, compressed);

        if (payload.len == 0) {
            const io = self.io;
            var writer = self.stream.writer(io, &.{});

            // no body, just write the header
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            return writer.interface.writeAll(header);
        }

        var vec = [2]posix.iovec_const{
            .{ .len = header.len, .base = header.ptr },
            .{ .len = payload.len, .base = payload.ptr },
        };

        return self.writeAllIOVec(&vec);
    }

    pub fn writeFramed(self: *Conn, data: []const u8) !void {
        const io = self.io;
        var writer = self.stream.writer(io, &.{});
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        try writer.interface.writeAll(data);
    }

    fn writeAllIOVec(self: *Conn, vec: []posix.iovec_const) !void {
        const io = self.io;
        const socket = self.stream.socket.handle;

        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        var i: usize = 0;
        while (true) {
            var n = try posix.writev(socket, vec[i..]);
            while (n >= vec[i].len) {
                n -= vec[i].len;
                i += 1;
                if (i >= vec.len) return;
            }
            vec[i].base += n;
            vec[i].len -= n;
        }
    }

    pub fn writeBuffer(self: *Conn, allocator: Allocator, op_code: OpCode) Writer {
        return .{
            .conn = self,
            .buf = .empty,
            .op_code = op_code,
            .allocator = allocator,
            .interface = .{
                .vtable = &.{ .drain = Writer.drain },
                .buffer = &.{},
            },
        };
    }

    // Can be called from any thread. Marks the connection as closed and shuts
    // the socket down.
    fn shutdownSocket(self: *Conn) void {
        if (@atomicRmw(bool, &self._closed, .Xchg, true, .monotonic) == true) {
            return;
        }
        const io = self.io;
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (@atomicLoad(bool, &self._fd_closed, .monotonic) == false) {
            posix.shutdown(self.stream.socket.handle, .both) catch {};
        }
    }

    // Called by the thread that owns the connection (or the server, when
    // stopping) once it's done with it. Releases the socket's file descriptor.
    // Safe to call more than once.
    fn closeSocket(self: *Conn) void {
        @atomicStore(bool, &self._closed, true, .monotonic);
        if (@atomicRmw(bool, &self._fd_closed, .Xchg, true, .monotonic) == true) {
            return;
        }
        const socket = self.stream.socket.handle;

        // Only we close the descriptor, so it's still ours to shut down without
        // the lock.
        posix.shutdown(socket, .both) catch {};

        const io = self.io;
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        posix.close(socket);
    }

    pub const Writer = struct {
        conn: *Conn,
        op_code: OpCode,
        allocator: Allocator,
        buf: std.ArrayList(u8),
        interface: std.Io.Writer,

        pub const Error = Allocator.Error;

        pub fn deinit(self: *Writer) void {
            self.buf.deinit(self.allocator);
        }

        pub fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
            _ = splat;
            const self: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
            self.buf.appendSlice(self.allocator, data[0]) catch return error.WriteFailed;
            return data[0].len;
        }

        pub fn send(self: *Writer) !void {
            return self.conn.writeFrame(self.op_code, self.buf.items) catch error.WriteFailed;
        }
    };
};

fn handleHandshake(comptime H: type, worker: anytype, hc: *HandlerConn(H), ctx: anytype) struct { bool, bool } {
    return _handleHandshake(H, worker, hc, ctx) catch |err| {
        log.warn("({f}) uncaugh error processing handshake: {}", .{ hc.conn.address, err });
        return .{ false, false };
    };
}

fn _handleHandshake(comptime H: type, worker: anytype, hc: *HandlerConn(H), ctx: anytype) !struct { bool, bool } {
    std.debug.assert(hc.handler == null);

    var state = hc.handshake orelse blk: {
        const s = try worker.handshake_pool.acquire();
        hc.handshake = s;
        break :blk s;
    };

    var buf = state.buf;
    var conn = &hc.conn;
    const len = state.len;

    if (len == buf.len) {
        log.warn("({f}) handshake request exceeded maximum configured size ({d})", .{ conn.address, buf.len });
        return .{ false, false };
    }

    const n = posix.read(hc.socket, buf[len..]) catch |err| {
        if (err == error.ConnectionResetByPeer) {
            log.debug("({f}) handshake connection closed: {}", .{ conn.address, err });
        } else if (std.mem.eql(u8, @errorName(err), "WouldBlock")) {
            // `error.WouldBlock` isn't in posix.read's error set on Windows,
            // but we still want to recognize it on POSIX where it represents
            // a handshake timeout.
            std.debug.assert(blockingMode());
            log.debug("({f}) handshake timeout", .{conn.address});
        } else {
            log.warn("({f}) handshake error reading from socket: {}", .{ conn.address, err });
        }
        return .{ false, false };
    };

    if (n == 0) {
        log.debug("({f}) handshake connection closed", .{conn.address});
        return .{ false, false };
    }

    state.len = len + n;
    var handshake = Handshake.parse(state) catch |err| {
        log.debug("({f}) error parsing handshake: {}", .{ conn.address, err });
        respondToHandshakeError(conn, err);
        return .{ false, false };
    } orelse {
        // we need more data
        return .{ false, true };
    };

    const compression = handshake.compression != null and worker.compression != null;
    defer state.release();
    hc.handshake = null;

    // After this, the app has access to &hc.conn, so any access to the
    // conn has to be synchronized (which the conn does internally).

    const handler = H.init(&handshake, conn, ctx) catch |err| {
        if (comptime std.meta.hasFn(H, "handshakeErrorResponse")) {
            preHandOffWrite(H.handshakeErrorResponse(err));
        } else {
            respondToHandshakeError(conn, err);
        }
        log.debug("({f}) " ++ @typeName(H) ++ ".init rejected request {}", .{ conn.address, err });
        return .{ false, false };
    };

    hc.handler = handler;

    var reply_buf: [2048]u8 = undefined;
    const handshake_reply = try Handshake.createReply(handshake.key, handshake.res_headers, compression, &reply_buf);
    try conn.writeFramed(handshake_reply);

    if (comptime std.meta.hasFn(H, "afterInit")) {
        const params = @typeInfo(@TypeOf(H.afterInit)).@"fn".param_types;
        const res = if (params.len == 1) hc.handler.?.afterInit() else hc.handler.?.afterInit(ctx);
        res catch |err| {
            log.debug("({f}) " ++ @typeName(H) ++ ".afterInit error: {}", .{ conn.address, err });
            return .{ false, false };
        };
    }

    log.debug("({f}) connection successfully upgraded", .{conn.address});
    return .{ compression, true };
}

fn handleClientData(comptime H: type, hc: *HandlerConn(H), allocator: Allocator, fba: *FixedBufferAllocator) bool {
    std.debug.assert(hc.handshake == null);
    return _handleClientData(H, hc, allocator, fba) catch |err| {
        log.warn("({f}) uncaugh error handling incoming data: {}", .{ hc.conn.address, err });
        return false;
    };
}

fn _handleClientData(comptime H: type, hc: *HandlerConn(H), allocator: Allocator, fba: *FixedBufferAllocator) !bool {
    var conn = &hc.conn;
    var reader = &hc.reader.?;
    reader.fill(conn.stream.socket.handle) catch |err| {
        switch (err) {
            error.Closed, error.ConnectionResetByPeer => log.debug("({f}) connection closed: {}", .{ conn.address, err }),
            else => log.warn("({f}) error reading from connection: {}", .{ conn.address, err }),
        }
        return false;
    };

    const handler = &hc.handler.?;
    while (true) {
        const has_more, const message = reader.read() catch |err| {
            switch (err) {
                error.LargeControl => conn.writeFramed(CLOSE_PROTOCOL_ERROR) catch {},
                error.ReservedFlags => conn.writeFramed(CLOSE_PROTOCOL_ERROR) catch {},
                error.CompressionDisabled => conn.writeFramed(CLOSE_PROTOCOL_ERROR) catch {},
                error.CompressionError => conn.writeFramed(CLOSE_PROTOCOL_ERROR) catch {},
                else => {},
            }
            log.debug("({f}) invalid websocket packet: {}", .{ conn.address, err });
            return false;
        } orelse {
            // everything is fine, we just need more data
            return true;
        };

        const message_type = message.type;
        defer reader.done(message_type);

        log.debug("({f}) received {s} message", .{ hc.conn.address, @tagName(message_type) });
        switch (message_type) {
            .text, .binary => {
                const params = @typeInfo(@TypeOf(H.clientMessage)).@"fn".param_types;
                const needs_allocator = comptime needsAllocator(H);

                var arena: std.heap.ArenaAllocator = undefined;
                var fallback_allocator: FallbackAllocator = undefined;
                var aa: Allocator = undefined;

                if (comptime needs_allocator) {
                    arena = std.heap.ArenaAllocator.init(allocator);
                    if (comptime blockingMode()) {
                        aa = arena.allocator();
                    } else {
                        fallback_allocator = FallbackAllocator{
                            .fba = fba,
                            .fallback = arena.allocator(),
                            .fixed = fba.allocator(),
                        };
                        aa = fallback_allocator.allocator();
                    }
                }

                defer if (comptime needs_allocator) {
                    arena.deinit();
                };

                switch (comptime params.len) {
                    2 => handler.clientMessage(message.data) catch return false,
                    3 => if (needs_allocator) {
                        handler.clientMessage(aa, message.data) catch return false;
                    } else {
                        handler.clientMessage(message.data, if (message_type == .text) .text else .binary) catch return false;
                    },
                    4 => handler.clientMessage(aa, message.data, if (message_type == .text) .text else .binary) catch return false,
                    else => @compileError(@typeName(H) ++ ".clientMessage has invalid parameter count"),
                }
            },
            .pong => if (comptime std.meta.hasFn(H, "clientPong")) {
                try handler.clientPong(message.data);
            },
            .ping => {
                const data = message.data;
                if (comptime std.meta.hasFn(H, "clientPing")) {
                    try handler.clientPing(data);
                } else if (data.len == 0) {
                    try hc.conn.writeFramed(EMPTY_PONG);
                } else {
                    try hc.conn.writeFrame(.pong, data);
                }
            },
            .close => {
                const data = message.data;
                if (comptime std.meta.hasFn(H, "clientClose")) {
                    try handler.clientClose(data);
                    return false;
                }

                const l = data.len;
                if (l == 0) {
                    try conn.close(.{});
                    return false;
                }

                if (l == 1) {
                    // close with a payload always has to have at least a 2-byte payload,
                    // since a 2-byte code is required
                    try conn.writeFramed(CLOSE_PROTOCOL_ERROR);
                    return false;
                }

                const code = @as(u16, @intCast(data[1])) | (@as(u16, @intCast(data[0])) << 8);
                if (code < 1000 or code == 1004 or code == 1005 or code == 1006 or (code > 1013 and code < 3000)) {
                    try conn.writeFramed(CLOSE_PROTOCOL_ERROR);
                    return false;
                }

                if (l == 2) {
                    try conn.writeFramed(CLOSE_NORMAL);
                    return false;
                }

                const payload = data[2..];
                if (!std.unicode.utf8ValidateSlice(payload)) {
                    // if we have a payload, it must be UTF8 (why?!)
                    try conn.writeFramed(CLOSE_PROTOCOL_ERROR);
                } else {
                    try conn.close(.{});
                }
                return false;
            },
        }

        if (conn.isClosed()) {
            return false;
        }

        if (has_more == false) {
            // we don't have more data ready to be processed in our buffer
            // back to our caller for more data
            return true;
        }
    }
}

fn needsAllocator(comptime H: type) bool {
    const params = @typeInfo(@TypeOf(H.clientMessage)).@"fn".param_types;
    return comptime params[1] == Allocator;
}

fn respondToHandshakeError(conn: *Conn, err: anyerror) void {
    const response = switch (err) {
        error.Close => return,
        error.RequestTooLarge => buildError(400, "too large"),
        error.Timeout, error.WouldBlock => buildError(400, "timeout"),
        error.InvalidProtocol => buildError(400, "invalid protocol"),
        error.InvalidRequestLine => buildError(400, "invalid requestline"),
        error.InvalidHeader => buildError(400, "invalid header"),
        error.InvalidUpgrade => buildError(400, "invalid upgrade"),
        error.InvalidVersion => buildError(400, "invalid version"),
        error.InvalidConnection => buildError(400, "invalid connection"),
        error.MissingHeaders => buildError(400, "missingheaders"),
        error.Empty => buildError(400, "invalid request"),
        else => buildError(400, "unknown"),
    };
    preHandOffWrite(conn, response);
}

fn buildError(comptime status: u16, comptime err: []const u8) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 {d} \r\nConnection: Close\r\nError: {s}\r\nContent-Length: 0\r\n\r\n", .{ status, err });
}

fn preHandOffWrite(conn: *Conn, response: []const u8) void {
    const io = conn.io;

    // "preHandOff" means we haven't given the application handler a reference
    // to *Conn yet. In theory, this means we don't need to worry about thread-safety
    // However, it is possible for the worker to be stopped while we're doing this
    // which causes issues unless we lock
    conn.lock.lockUncancelable(io);
    defer conn.lock.unlock(io);

    if (conn.isClosed()) {
        return;
    }

    const socket = conn.stream.socket.handle;
    const timeout = std.mem.toBytes(posix.timeval{ .sec = 5, .usec = 0 });
    posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout) catch return;

    var pos: usize = 0;
    while (pos < response.len) {
        const n = posix.write(socket, response[pos..]) catch return;
        if (n == 0) {
            // closed
            return;
        }
        pos += n;
    }
}

fn timestamp(io: Io) u32 {
    return @intCast(Io.Timestamp.now(io, .awake).toSeconds());
}

// intrusive doubly-linked list with count, not thread safe
fn List(comptime T: type) type {
    return struct {
        len: usize = 0,
        head: ?*T = null,
        tail: ?*T = null,

        const Self = @This();

        pub fn insert(self: *Self, node: *T) void {
            if (self.tail) |tail| {
                tail.next = node;
                node.prev = tail;
                self.tail = node;
            } else {
                self.head = node;
                self.tail = node;
            }
            self.len += 1;
            node.next = null;
        }

        pub fn remove(self: *Self, node: *T) void {
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = node.next;
            }

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = node.prev;
            }
            node.prev = null;
            node.next = null;
            self.len -= 1;
        }
    };
}

const t = @import("../t.zig");

const OwnershipFixture = struct {
    const H = struct {};
    const HC = HandlerConn(H);
    const Gate = @import("bounded_test_support.zig").Gate;
    const Base = struct {
        io: Io = t.io,
        conn_manager: ConnManager(H, true),
        closes: usize = 0,
        cleanups: usize = 0,

        fn cleanupConn(self: *@This(), hc: *HC) void {
            // Match NonBlockingBase cleanup's per-record lock before manager
            // cleanup. This also catches a cleanup defer surviving the tail.
            hc.cleanup.lockUncancelable(self.io);
            hc.cleanup.unlock(self.io);
            self.closes += 1;
            hc.conn._closed = true;
            self.cleanups += 1;
            self.conn_manager.cleanup(hc);
        }
    };
    const MockLoop = struct {
        fail: bool = false,
        rearms: usize = 0,
        fn monitorRead(self: *@This(), hc: *HC, rearm: bool) !void {
            std.debug.assert(rearm);
            std.debug.assert(hc.state == .active);
            self.rearms += 1;
            if (self.fail) return error.MockRearm;
        }
    };
    base: Base,
    loop: MockLoop = .{},
    success: bool = true,
    closed: bool = false,
    before: ?*Gate = null,
    published: ?*Gate = null,
    returned: ?*Gate = null,

    fn init() !OwnershipFixture {
        var cm = try ConnManager(H, true).init(t.io, t.allocator, null);
        errdefer cm.deinit();
        try cm.pool.addCapacity(t.allocator, 1);
        cm.limit = 1;
        return .{ .base = .{ .conn_manager = cm } };
    }

    fn record(self: *@This()) !*HC {
        const cm = &self.base.conn_manager;
        const hc = try cm.acquireRecord();
        hc.* = .{
            .state = .handshake,
            .socket = undefined,
            .conn = .{ .io = t.io, ._closed = false, .started = 10, .stream = undefined, .address = undefined },
            .handler = null,
            .reader = null,
            .handshake = null,
        };
        cm.pending.insert(hc);
        return hc;
    }

    fn processRead(self: *@This(), hc: *HC, _: []u8) bool {
        if (self.closed) hc.conn._closed = true;
        return self.success;
    }

    fn cleanupRead(self: *@This(), hc: *HC) void {
        const cm = &self.base.conn_manager;
        cm.lock.lockUncancelable(t.io);
        std.debug.assert(hc.state == .active);
        std.debug.assert(cm.pending.len == 0);
        cm.lock.unlock(t.io);
        self.base.cleanupConn(hc);
    }

    fn beforeHandoff(self: *@This()) void {
        if (self.before) |gate| gate.arriveAndWait();
    }

    const Hooks = struct {
        fixture: *OwnershipFixture,
        pub fn beforeHandoff(self: @This()) void {
            self.fixture.beforeHandoff();
        }
        pub fn published(self: @This()) void {
            if (self.fixture.published) |gate| gate.arriveAndWait();
        }
    };

    fn callback(self: *@This(), hc: *HC) void {
        readCallback(self, hc, &.{}, Hooks{ .fixture = self });
        // Deliberately keep the old stack alive without accessing hc.
        if (self.returned) |gate| gate.arriveAndWait();
    }

    const Timeout = struct {
        fixture: *OwnershipFixture,
        attempting: ?*Gate = null,
        done: ?*Gate = null,
        pub fn beforeLock(self: @This()) void {
            if (self.attempting) |gate| gate.notify();
        }
        fn close(self: @This(), conn: *Conn) void {
            self.fixture.base.closes += 1;
            conn._closed = true;
        }
        fn run(self: @This()) void {
            _ = self.fixture.base.conn_manager.retirePending(20, self);
            if (self.done) |gate| gate.notify();
        }
    };

    const Dispatch = struct {
        fixture: *OwnershipFixture,
        hc: *HC,
        attempting: *Gate,
        done: *Gate,
        pub fn beforeLock(self: @This()) void {
            self.attempting.notify();
        }
        fn run(self: @This()) void {
            var oldest: ?u32 = null;
            self.fixture.base.conn_manager.dispatch(self.hc, &oldest, self);
            self.done.notify();
        }
    };

    fn expectBlocked(gate: *Gate) !void {
        gate.mutex.lockUncancelable(t.io);
        defer gate.mutex.unlock(t.io);
        try t.expectEqual(false, gate.arrived);
    }
};

test "bounded-memory handshake queued and running owners survive expired cutoff until final handoff" {
    const F = OwnershipFixture;
    const handshakes = try Handshake.Pool.init(t.io, t.allocator, 1, 256, 4, 4);
    defer handshakes.deinit();
    var f = try F.init();
    defer f.base.conn_manager.deinit();
    const cm = &f.base.conn_manager;
    const hc = try f.record();
    hc.handshake = try handshakes.acquire();
    var oldest: ?u32 = null;
    cm.dispatch(hc, &oldest, .{});
    try t.expectEqual(@as(?u32, 10), oldest);
    // Dispatched but not yet running, already beyond the five-second deadline.
    (F.Timeout{ .fixture = &f }).run();
    try t.expectEqual(@as(usize, 1), cm.active.len);
    try t.expectError(error.OutOfMemory, cm.acquireRecord());
    var before: F.Gate = .{};
    var returned: F.Gate = .{};
    f.before = &before;
    f.returned = &returned;
    const thread = try Thread.spawn(.{}, F.callback, .{ &f, hc });
    before.waitArrived();
    (F.Timeout{ .fixture = &f }).run();
    try t.expectEqual(@as(usize, 1), cm.active.len);
    try t.expectEqual(@as(usize, 0), f.base.closes);
    try t.expectEqual(@as(usize, 0), handshakes.available);
    try t.expectError(error.OutOfMemory, cm.acquireRecord());
    before.release();
    returned.waitArrived();
    (F.Timeout{ .fixture = &f }).run();
    (F.Timeout{ .fixture = &f }).run();
    try t.expectEqual(@as(usize, 1), f.base.closes);
    try t.expectEqual(@as(usize, 1), handshakes.available);
    try t.expectEqual(@as(usize, 0), cm.count());
    const reused = try f.record();
    try t.expectEqual(hc, reused);
    reused.conn.started = 99;
    returned.release();
    thread.join();
    try t.expectEqual(@as(u32, 99), reused.conn.started);
    try t.expectEqual(@as(usize, 1), cm.pending.len);
    f.base.cleanupConn(reused);
}

test "bounded-memory handshake publication excludes timeout and immediate readiness until unlock" {
    const F = OwnershipFixture;
    // Test each winner deterministically, not two contenders racing by chance.
    for (0..3) |scenario| {
        const readiness_wins = scenario != 0;
        var f = try F.init();
        defer f.base.conn_manager.deinit();
        const cm = &f.base.conn_manager;
        const hc = try f.record();
        var oldest: ?u32 = null;
        cm.dispatch(hc, &oldest, .{});
        // Established connections must use the same dispatch lock, even though
        // they never enter pending or update handshake timeout bookkeeping.
        if (scenario == 2) hc.handler = .{};
        var published: F.Gate = .{};
        var returned: F.Gate = .{};
        var attempting: F.Gate = .{};
        var done: F.Gate = .{};
        f.published = &published;
        f.returned = &returned;
        const callback = try Thread.spawn(.{}, F.callback, .{ &f, hc });
        published.waitArrived();
        try t.expectEqual(@as(usize, 1), f.loop.rearms);
        const contender = if (readiness_wins)
            try Thread.spawn(.{}, F.Dispatch.run, .{F.Dispatch{ .fixture = &f, .hc = hc, .attempting = &attempting, .done = &done }})
        else
            try Thread.spawn(.{}, F.Timeout.run, .{F.Timeout{ .fixture = &f, .attempting = &attempting, .done = &done }});
        attempting.waitArrived();
        try F.expectBlocked(&done);
        published.release();
        done.waitArrived();
        contender.join();
        returned.waitArrived();
        if (readiness_wins) {
            (F.Timeout{ .fixture = &f }).run();
            try t.expectEqual(@as(usize, 1), cm.active.len);
            try t.expectEqual(@as(usize, 0), f.base.closes);
            // New callback can clean and recycle while the old stack is alive.
            f.base.cleanupConn(hc);
        } else {
            try t.expectEqual(@as(usize, 1), f.base.closes);
        }
        const reused = try f.record();
        try t.expectEqual(hc, reused);
        returned.release();
        callback.join();
        try t.expectEqual(@as(usize, 1), cm.pending.len);
        f.base.cleanupConn(reused);
    }
}

test "bounded-memory handshake parse closed and rearm failures retain one cleanup owner" {
    const F = OwnershipFixture;
    const handshakes = try Handshake.Pool.init(t.io, t.allocator, 1, 256, 4, 4);
    defer handshakes.deinit();
    for (0..3) |failure| {
        var f = try F.init();
        defer f.base.conn_manager.deinit();
        const cm = &f.base.conn_manager;
        const hc = try f.record();
        hc.handshake = try handshakes.acquire();
        var oldest: ?u32 = null;
        cm.dispatch(hc, &oldest, .{});
        f.success = failure != 0;
        f.closed = failure == 1;
        f.loop.fail = failure == 2;
        f.callback(hc);
        try t.expectEqual(@as(usize, 1), f.base.cleanups);
        try t.expectEqual(@as(usize, 1), f.base.closes);
        try t.expectEqual(@as(usize, 1), handshakes.available);
        try t.expectEqual(@as(usize, if (failure == 2) 1 else 0), f.loop.rearms);
        try t.expectEqual(@as(usize, 0), cm.count());
        (F.Timeout{ .fixture = &f }).run();
        try t.expectEqual(@as(usize, 1), f.base.closes);
        const reused = try f.record();
        try t.expectEqual(hc, reused);
        // The old cleanup mutex was released before any recycling.
        reused.cleanup.lockUncancelable(t.io);
        reused.cleanup.unlock(t.io);
        f.base.cleanupConn(reused);
    }
}

var test_thread: Thread = undefined;
var test_server: Server(TestHandler) = undefined;
var global_test_allocator = std.heap.DebugAllocator(.{}){};

test "bounded-memory prewarm 64 pending and active connections and recycle all storage" {
    const H = struct {};
    var tracking = std.testing.FailingAllocator.init(t.allocator, .{});
    const allocator = tracking.allocator();
    var state = try WorkerState.init(t.io, allocator, .{
        .max_conn = 64,
        .max_message_size = 128,
        .handshake = .{ .timeout = 5, .max_size = 8192, .max_headers = 32 },
        .buffers = .{ .small_size = 256, .large_size = 128, .large_pool = 64 },
    });
    defer state.deinit();
    var base = try NonBlockingBase(H, true).init(t.io, allocator, &state);
    defer base.deinit();
    try t.expectEqual(@as(usize, 64), state.handshake_pool.available);
    try t.expectEqual(@as(usize, 64), base.small_buffer_pool.?.available);
    // Freeze upstream allocation after prewarming. No descriptor is created,
    // closed or passed to an OS call in this test.
    tracking.fail_index = tracking.alloc_index;
    var records: [64]*HandlerConn(H) = undefined;
    const fragment = [_]u8{ 0x02, 0x84, 0, 0, 0, 0, 'p', 'a', 'r', 't' };
    for (0..16) |_| {
        for (&records, 0..) |*record, index| {
            const hc = try base.conn_manager.acquireRecord();
            hc.* = .{
                .state = .handshake,
                .socket = undefined,
                .conn = .{ .io = t.io, ._closed = true, .started = 0, .stream = undefined, .address = undefined },
                .handler = null,
                .handshake = try state.handshake_pool.acquire(),
                .reader = Reader.init(base.small_buffer_pool.?.acquire().?, &state.buffer_provider, null),
            };
            base.conn_manager.pending.insert(hc);
            if (index % 2 == 0) base.conn_manager.activate(hc);
            @memcpy(hc.reader.?.static[0..fragment.len], &fragment);
            hc.reader.?.pos = fragment.len;
            try t.expectEqual(null, try hc.reader.?.read());
            record.* = hc;
        }
        try t.expectEqual(@as(usize, 64), base.conn_manager.count());
        try t.expectEqual(@as(usize, 32), base.conn_manager.pending.len);
        try t.expectEqual(@as(usize, 0), state.buffer_provider.pool.available);
        try t.expectError(error.OutOfMemory, state.handshake_pool.acquire());
        try t.expectError(error.OutOfMemory, base.conn_manager.acquireRecord());
        for (records) |hc| base.cleanupConn(hc);
        try t.expectEqual(@as(usize, 0), base.conn_manager.count());
        try t.expectEqual(@as(usize, 64), base.small_buffer_pool.?.available);
        try t.expectEqual(@as(usize, 64), state.handshake_pool.available);
        try t.expectEqual(@as(usize, 64), state.buffer_provider.pool.available);
    }
}

test "bounded-memory connection cleanup reclaims simultaneous fragment and incomplete large buffer" {
    const H = struct {};
    var tracking = std.testing.FailingAllocator.init(t.allocator, .{});
    const allocator = tracking.allocator();
    var state = try WorkerState.init(t.io, allocator, .{
        .max_conn = 1,
        .max_message_size = 128,
        .handshake = .{ .count = 1 },
        .buffers = .{ .small_size = 16, .large_pool = 0 },
    });
    defer state.deinit();
    var base = try NonBlockingBase(H, true).init(t.io, allocator, &state);
    defer base.deinit();
    const retained = tracking.allocated_bytes - tracking.freed_bytes;
    for (0..128) |_| {
        const hc = try base.conn_manager.pool.create(allocator);
        hc.* = .{
            .state = .handshake,
            .socket = undefined,
            .conn = .{ .io = t.io, ._closed = true, .started = 0, .stream = undefined, .address = undefined },
            .handler = null,
            .handshake = null,
            .reader = Reader.init(base.small_buffer_pool.?.acquire().?, &state.buffer_provider, null),
        };
        base.conn_manager.pending.insert(hc);
        const fragment = [_]u8{ 0x02, 0x84, 0, 0, 0, 0, 'p', 'a', 'r', 't' };
        @memcpy(hc.reader.?.static[0..fragment.len], &fragment);
        hc.reader.?.pos = fragment.len;
        try t.expectEqual(null, try hc.reader.?.read());
        const continuation = [_]u8{ 0x80, 128 | 124, 0, 0, 0, 0 };
        @memcpy(hc.reader.?.static[0..continuation.len], &continuation);
        hc.reader.?.pos = continuation.len;
        try t.expectEqual(null, try hc.reader.?.read());
        base.cleanupConn(hc);
        try t.expectEqual(retained, tracking.allocated_bytes - tracking.freed_bytes);
        try t.expectEqual(@as(usize, 1), base.small_buffer_pool.?.available);
    }
}

fn boundedStartup(allocator: Allocator) !void {
    var state = try WorkerState.init(t.io, allocator, .{
        .max_conn = 2,
        .buffers = .{ .large_pool = 2, .small_size = 16 },
        .handshake = .{ .count = 2 },
    });
    defer state.deinit();
    var base = try NonBlockingBase(struct {}, true).init(t.io, allocator, &state);
    defer base.deinit();
}

test "bounded-memory startup allocation failures reclaim partially prewarmed pools" {
    try std.testing.checkAllAllocationFailures(t.allocator, boundedStartup, .{});
}

test "bounded-memory listener admission path compiles without running sockets" {
    var signal: posix.fd_t = 17; // Mock ownership token; never closed.
    try t.expectEqual(@as(posix.fd_t, 17), takeSignal(&signal));
    try t.expectEqual(@as(posix.fd_t, -1), takeSignal(&signal));
    const W = NonBlocking(struct {}, void);
    const accept: *const fn (*W, posix.fd_t, u32) anyerror!void = W.accept;
    std.mem.doNotOptimizeAway(accept);
    const Check = struct {
        const Handler = struct {
            pub fn init(_: *const Handshake, _: *Conn, _: void) !@This() {
                return .{};
            }
            pub fn clientMessage(_: *@This(), _: []const u8, _: Message.TextType) !void {}
        };
        fn listen(server: *Server(Handler)) !void {
            try server.listen({});
        }
        fn background(server: *Server(Handler)) !Thread {
            return server.listenInNewThread({});
        }
        fn stop(server: *Server(Handler)) void {
            server.stop();
        }
    };
    const listen: *const fn (*Server(Check.Handler)) anyerror!void = Check.listen;
    std.mem.doNotOptimizeAway(listen);
    const background: *const fn (*Server(Check.Handler)) anyerror!Thread = Check.background;
    std.mem.doNotOptimizeAway(background);
    const stop: *const fn (*Server(Check.Handler)) void = Check.stop;
    std.mem.doNotOptimizeAway(stop);
}

test "bounded-memory teardown waits for active queued and post-callback-tail references" {
    const Gate = @import("bounded_test_support.zig").Gate;
    const H = struct {
        closes: *usize,
        pub fn close(self: *@This()) void {
            self.closes.* += 1;
        }
    };
    const HC = HandlerConn(H);
    const Base = NonBlockingBase(H, true);
    const Jobs = struct {
        records: [2]*HC,
        loop_alive: *std.atomic.Value(bool),
        first: Gate = .{},
        tail: Gate = .{},
        queued: Gate = .{},
        finished: std.atomic.Value(usize) = .init(0),

        fn callback(self: *@This(), index: u8, thread_buffer: []u8) void {
            const hc = self.records[index];
            const static = hc.reader.?.static;
            const fragment = hc.reader.?.fragment.?.buf.data;
            thread_buffer[0] = 99;
            if (index == 0) self.first.arriveAndWait() else self.queued.arriveAndWait();
            std.debug.assert(static[6] == 'p' and fragment[0] == 'p');
            std.debug.assert(hc.reader != null and hc.handshake != null);
            std.debug.assert(self.loop_alive.load(.acquire));
            if (index == 0) {
                // The application callback is over, but dataAvailable's
                // cleanup/rearm tail still owns the reader, HC and event loop.
                self.tail.arriveAndWait();
            }
            std.debug.assert(static[6] == 'p' and fragment[0] == 'p');
            std.debug.assert(hc.reader != null and thread_buffer[0] == 99);
            std.debug.assert(self.loop_alive.load(.acquire));
            _ = self.finished.fetchAdd(1, .release);
        }
    };
    const Pool = @import("thread_pool.zig").ThreadPool(Jobs.callback);
    const PoolOwner = struct {
        pool: *Pool,
        stopping: *Gate,
        pub fn stop(self: *@This()) void {
            self.stopping.notify();
            self.pool.stop();
        }
        pub fn deinit(self: *@This()) void {
            self.pool.deinit();
        }
    };
    const Resources = struct {
        base: *Base,
        jobs: *Jobs,
        socket_closes: *usize,
        reclaimed: *std.atomic.Value(bool),
        pub fn shutdown(self: *@This()) void {
            std.debug.assert(self.jobs.finished.load(.acquire) == 2);
            self.base.shutdownWith(struct {
                count: *usize,
                fn close(closer: @This(), _: *HC) void {
                    closer.count.* += 1; // Mock FD close, never an OS call.
                }
            }{ .count = self.socket_closes });
            std.debug.assert(self.base.conn_manager.count() == 0);
            std.debug.assert(self.base.small_buffer_pool.?.available == 2);
            std.debug.assert(self.base.buffer_provider.pool.available == 2);
        }
        pub fn deinit(self: *@This()) void {
            self.base.deinit();
            self.reclaimed.store(true, .release);
        }
    };
    const MockLoop = struct {
        alive: *std.atomic.Value(bool),
        reclaimed: *std.atomic.Value(bool),
        pub fn deinit(self: *@This()) void {
            std.debug.assert(self.reclaimed.load(.acquire));
            self.alive.store(false, .release);
        }
    };
    const Teardown = struct {
        fn run(pool: *PoolOwner, resources: *Resources, loop: *MockLoop) void {
            finishCallbacks(pool, resources, loop);
        }
    };

    var tracking = std.testing.FailingAllocator.init(t.allocator, .{});
    defer std.debug.assert(tracking.allocated_bytes == tracking.freed_bytes);
    const allocator = tracking.allocator();
    var state = try WorkerState.init(t.io, allocator, .{
        .max_conn = 2,
        .max_message_size = 128,
        .handshake = .{ .count = 2 },
        .buffers = .{ .small_size = 16, .large_size = 128, .large_pool = 2 },
    });
    defer state.deinit();
    var base = try Base.init(t.io, allocator, &state);
    var own_base = true;
    defer if (own_base) base.deinit();
    var handler_closes: usize = 0;
    var records: [2]*HC = undefined;
    for (&records) |*record| {
        const hc = try base.conn_manager.acquireRecord();
        hc.* = .{
            .state = .handshake,
            .socket = undefined,
            .conn = .{ .io = t.io, ._closed = true, ._fd_closed = true, .started = 0, .stream = undefined, .address = undefined },
            .handler = .{ .closes = &handler_closes },
            .handshake = try state.handshake_pool.acquire(),
            .reader = Reader.init(base.small_buffer_pool.?.acquire().?, &state.buffer_provider, null),
        };
        base.conn_manager.pending.insert(hc);
        const fragment = [_]u8{ 0x02, 0x84, 0, 0, 0, 0, 'p', 'a', 'r', 't' };
        @memcpy(hc.reader.?.static[0..fragment.len], &fragment);
        hc.reader.?.pos = fragment.len;
        try t.expectEqual(null, try hc.reader.?.read());
        record.* = hc;
    }
    base.conn_manager.activate(records[0]);
    var loop_alive: std.atomic.Value(bool) = .init(true);
    var reclaimed: std.atomic.Value(bool) = .init(false);
    var jobs: Jobs = .{ .records = records, .loop_alive = &loop_alive };
    const pool = try Pool.init(t.io, allocator, .{ .count = 1, .backlog = 2, .buffer_size = 16 });
    var own_pool = true;
    defer if (own_pool) pool.deinit();
    defer {
        jobs.first.release();
        jobs.tail.release();
        jobs.queued.release();
    }
    var stopping: Gate = .{};
    var owner: PoolOwner = .{ .pool = pool, .stopping = &stopping };
    var socket_closes: usize = 0;
    var resources: Resources = .{ .base = &base, .jobs = &jobs, .socket_closes = &socket_closes, .reclaimed = &reclaimed };
    var loop: MockLoop = .{ .alive = &loop_alive, .reclaimed = &reclaimed };
    pool.spawn(.{ &jobs, 0 });
    jobs.first.waitArrived();
    pool.spawn(.{ &jobs, 1 });
    {
        const teardown = try Thread.spawn(.{}, Teardown.run, .{ &owner, &resources, &loop });
        own_pool = false;
        own_base = false;
        defer {
            jobs.first.release();
            jobs.tail.release();
            jobs.queued.release();
            teardown.join();
        }
        stopping.waitArrived();
        try t.expectEqual(false, reclaimed.load(.acquire));
        try t.expectEqual(true, loop_alive.load(.acquire));
        try t.expectEqual(@as(usize, 0), state.handshake_pool.available);
        jobs.first.release();
        jobs.tail.waitArrived();
        try t.expectEqual(false, reclaimed.load(.acquire));
        try t.expectEqual(true, loop_alive.load(.acquire));
        try t.expectEqual(@as(usize, 0), base.small_buffer_pool.?.available);
        jobs.tail.release();
        jobs.queued.waitArrived();
        try t.expectEqual(false, reclaimed.load(.acquire));
        try t.expectEqual(true, loop_alive.load(.acquire));
        jobs.queued.release();
    }
    try t.expectEqual(true, reclaimed.load(.acquire));
    try t.expectEqual(false, loop_alive.load(.acquire));
    try t.expectEqual(@as(usize, 2), jobs.finished.load(.acquire));
    try t.expectEqual(@as(usize, 2), socket_closes);
    try t.expectEqual(@as(usize, 2), handler_closes);
    try t.expectEqual(@as(usize, 2), state.handshake_pool.available);
}

test "tests:beforeAll" {
    test_server = try Server(TestHandler).init(t.io, global_test_allocator.allocator(), .{
        .port = 9292,
        .address = "127.0.0.1",
    });
    test_thread = try test_server.listenInNewThread({});
}

test "tests:afterAll" {
    test_server.stop();
    test_thread.join();
    test_server.deinit();
    try t.expectEqual(0, global_test_allocator.detectLeaks());
}

test "Server: invalid handshake" {
    const stream = try testStream(false);
    defer stream.close(t.io);

    var writer = stream.writer(t.io, &.{});
    try writer.interface.writeAll("GET / HTTP/1.1\r\n\r\n");

    var buf: [1024]u8 = undefined;

    var pos: usize = 0;
    while (pos < buf.len) {
        const n = try posix.read(stream.socket.handle, buf[pos..]);
        if (n == 0) {
            break;
        }
        pos += n;
    } else {
        unreachable;
    }

    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nError: missingheaders\r\nContent-Length: 0\r\n\r\n", buf[0..pos]);
}

test "Server: read and write" {
    const stream = try testStream(true);
    defer stream.close(t.io);

    var writer = stream.writer(t.io, &.{});
    try writer.interface.writeAll(&proto.frame(.text, "over"));

    var buf: [12]u8 = undefined;
    _ = try posix.read(stream.socket.handle, &buf);
    try t.expectSlice(u8, &.{ 129, 4, '9', '0', '0', '0' }, buf[0..6]);
}

test "Server: clientMessage allocator" {
    const stream = try testStream(true);
    defer stream.close(t.io);

    var writer = stream.writer(t.io, &.{});
    try writer.interface.writeAll(&proto.frame(.text, "dyn"));

    var buf: [12]u8 = undefined;
    _ = try posix.read(stream.socket.handle, &buf);
    try t.expectSlice(u8, &.{ 129, 10, 'o', 'v', 'e', 'r', ' ', '9', '0', '0', '0', '!' }, buf[0..12]);
}

test "Server: clientMessage writer" {
    const stream = try testStream(true);
    defer stream.close(t.io);

    var writer = stream.writer(t.io, &.{});
    try writer.interface.writeAll(&proto.frame(.text, "writer"));

    var buf: [9]u8 = undefined;
    _ = try posix.read(stream.socket.handle, &buf);
    try t.expectSlice(u8, &.{ 129, 7, '9', '0', '0', '0', '!', '!', '!' }, buf[0..9]);
}

// Same as above, but client doesn't shutdown the connection
// When afterAll is runs and things are shutdown, this should still be properly cleaned up
test "Server: dirty clientMessage allocator" {
    const stream = try testStream(true);

    var writer = stream.writer(t.io, &.{});
    try writer.interface.writeAll(&proto.frame(.text, "dyn"));

    var buf: [12]u8 = undefined;
    _ = try posix.read(stream.socket.handle, &buf);
    try t.expectSlice(u8, &.{ 129, 10, 'o', 'v', 'e', 'r', ' ', '9', '0', '0', '0', '!' }, buf[0..12]);
}

test "Conn: close" {
    {
        // plain close
        const stream = try testStream(true);
        defer stream.close(t.io);

        var writer = stream.writer(t.io, &.{});
        try writer.interface.writeAll(&proto.frame(.text, "close1"));

        var buf: [4]u8 = undefined;
        var reader = stream.reader(t.io, &.{});
        _ = try reader.interface.readSliceShort(&buf);
        try t.expectSlice(u8, &.{ 136, 2, 3, 232 }, buf[0..4]);
    }

    {
        // close with code
        const stream = try testStream(true);
        defer stream.close(t.io);
        var writer = stream.writer(t.io, &.{});
        try writer.interface.writeAll(&proto.frame(.text, "close2"));

        var buf: [4]u8 = undefined;
        var reader = stream.reader(t.io, &.{});
        _ = try reader.interface.readSliceShort(&buf);
        try t.expectSlice(u8, &.{ 136, 2, 0, 0x7b }, buf[0..4]);
    }

    {
        // close with reason
        const stream = try testStream(true);
        defer stream.close(t.io);
        var writer = stream.writer(t.io, &.{});
        try writer.interface.writeAll(&proto.frame(.text, "close3"));

        var buf: [7]u8 = undefined;
        var reader = stream.reader(t.io, &.{});
        _ = try reader.interface.readSliceShort(&buf);
        try t.expectSlice(u8, &.{ 136, 5, 0, 0xea, 'b', 'y', 'e' }, buf[0..7]);
    }
}

fn testStream(handshake: bool) !Io.net.Stream {
    const address = try Io.net.IpAddress.parse("127.0.0.1", 9292);
    const stream = try address.connect(t.io, .{ .mode = .stream });

    const socket = stream.socket.handle;
    const timeout = std.mem.toBytes(posix.timeval{ .sec = 0, .usec = 20_000 });
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);

    if (handshake == false) {
        return stream;
    }
    var buf: [1024]u8 = undefined;

    var writer = stream.writer(t.io, &buf);
    try writer.interface.writeAll("GET / HTTP/1.1\r\ncontent-length: 0\r\nupgrade: websocket\r\nsec-websocket-version: 13\r\nconnection: upgrade\r\nsec-websocket-key: my-key\r\n\r\n");
    try writer.interface.flush();

    var pos: usize = 0;
    while (pos < buf.len) {
        const n = try posix.read(socket, buf[0..]);
        if (n == 0) break;

        pos += n;
        if (std.mem.endsWith(u8, buf[0..pos], "\r\n\r\n")) {
            break;
        }
    } else {
        unreachable;
    }

    try t.expectString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-Websocket-Accept: L8KGBs4w2MNLLzhfzlVoM0scCIE=\r\n\r\n", buf[0..pos]);

    return stream;
}

const TestHandler = struct {
    conn: *Conn,
    close_later: bool = false,

    pub fn init(h: *const Handshake, conn: *Conn, _: void) !TestHandler {
        try t.expectString("upgrade", h.headers.get("connection").?);
        return .{
            .conn = conn,
        };
    }

    pub fn afterInit(self: *TestHandler) !void {
        _ = self;
    }

    pub fn clientMessage(
        self: *TestHandler,
        allocator: Allocator,
        data: []const u8,
    ) !void {
        if (std.mem.eql(u8, data, "over")) {
            return self.conn.writeText("9000");
        }
        if (std.mem.eql(u8, data, "dyn")) {
            return self.conn.writeText(try std.fmt.allocPrint(allocator, "over {d}!", .{9000}));
        }
        if (std.mem.eql(u8, data, "writer")) {
            var wb = self.conn.writeBuffer(allocator, .text);
            try wb.interface.print("{d}!!!", .{9000});
            return wb.send();
        }
        if (std.mem.eql(u8, data, "ping")) {
            var buf = [_]u8{ 'a', '-', 'p', 'i', 'n', 'g' };
            return self.conn.writePing(&buf);
        }
        if (std.mem.eql(u8, data, "pong")) {
            var buf = [_]u8{ 'a', '-', 'p', 'o', 'n', 'g' };
            return self.conn.writePong(&buf);
        }
        if (std.mem.eql(u8, data, "close1")) {
            return self.conn.close(.{});
        }
        if (std.mem.eql(u8, data, "close2")) {
            return self.conn.close(.{ .code = 123 });
        }
        if (std.mem.eql(u8, data, "close3")) {
            return self.conn.close(.{ .code = 234, .reason = "bye" });
        }
        if (std.mem.eql(u8, data, "close-later")) {
            self.close_later = true;
            close_later.conn.store(self.conn, .release);
        }
    }

    pub fn close(self: *TestHandler) void {
        if (self.close_later) {
            close_later.handler_closed.store(true, .release);
        }
    }
};

// The "close-later" connection: its conn, for another thread to close, and
// whether the worker went on to close its handler.
const close_later = struct {
    var conn = std.atomic.Value(?*Conn).init(null);
    var handler_closed = std.atomic.Value(bool).init(false);
};

test "Conn: close from a thread that doesn't own the connection" {
    const stream = try testStream(true);
    defer stream.close(t.io);

    var writer = stream.writer(t.io, &.{});
    try writer.interface.writeAll(&proto.frame(.text, "close-later"));

    var waited_ms: u32 = 0;
    const conn = while (waited_ms < 2000) : (waited_ms += 1) {
        if (close_later.conn.load(.acquire)) |c| break c;
        try t.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.HandlerNeverRan;

    // Let the worker finish with the message and go back to waiting on the
    // socket, so that nothing but our close can wake it.
    try t.io.sleep(.fromMilliseconds(50), .awake);

    try conn.close(.{ .code = 4003, .reason = "late" });

    var buf: [8]u8 = undefined;
    var reader = stream.reader(t.io, &.{});
    try reader.interface.readSliceAll(&buf);
    try t.expectSlice(u8, &.{ 136, 6, 0x0f, 0xa3, 'l', 'a', 't', 'e' }, &buf);

    // The connection's owner must have been woken up and cleaned up. Had the
    // socket been closed out from under it, it would never hear of it again.
    waited_ms = 0;
    while (close_later.handler_closed.load(.acquire) == false) : (waited_ms += 1) {
        if (waited_ms == 2000) return error.HandlerNeverClosed;
        try t.io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "List" {
    var list = List(TestNode){};
    try expectList(&.{}, list);

    var n1 = TestNode{ .id = 1 };
    list.insert(&n1);
    try expectList(&.{1}, list);

    list.remove(&n1);
    try expectList(&.{}, list);

    var n2 = TestNode{ .id = 2 };
    list.insert(&n2);
    list.insert(&n1);
    try expectList(&.{ 2, 1 }, list);

    var n3 = TestNode{ .id = 3 };
    list.insert(&n3);
    try expectList(&.{ 2, 1, 3 }, list);

    list.remove(&n1);
    try expectList(&.{ 2, 3 }, list);

    list.insert(&n1);
    try expectList(&.{ 2, 3, 1 }, list);

    list.remove(&n2);
    try expectList(&.{ 3, 1 }, list);

    list.remove(&n1);
    try expectList(&.{3}, list);

    list.remove(&n3);
    try expectList(&.{}, list);
}

const TestNode = struct {
    id: i32,
    next: ?*TestNode = null,
    prev: ?*TestNode = null,
};

fn expectList(expected: []const i32, list: List(TestNode)) !void {
    if (expected.len == 0) {
        try t.expectEqual(null, list.head);
        try t.expectEqual(null, list.tail);
        return;
    }

    var i: usize = 0;
    var next = list.head;
    while (next) |node| {
        try t.expectEqual(expected[i], node.id);
        i += 1;
        next = node.next;
    }
    try t.expectEqual(expected.len, i);

    i = expected.len;
    var prev = list.tail;
    while (prev) |node| {
        i -= 1;
        try t.expectEqual(expected[i], node.id);
        prev = node.prev;
    }
    try t.expectEqual(0, i);
}
