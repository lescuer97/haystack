//! Process-wide SIGINT/SIGTERM watcher for Linux and macOS.
const std = @import("std");
const posix = std.posix;

pub const Shutdown = struct {
    previous_int: posix.Sigaction,
    previous_term: posix.Sigaction,

    var installed: std.atomic.Value(bool) = .init(false);
    var requested: std.atomic.Value(bool) = .init(false);

    /// Installs one process-wide watcher. The caller owns the returned handle
    /// and must restore it once, after all wait tasks have been drained.
    pub fn install() error{AlreadyInstalled}!Shutdown {
        if (installed.swap(true, .acquire)) return error.AlreadyInstalled;
        requested.store(false, .monotonic);

        const action: posix.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        var self: Shutdown = undefined;
        posix.sigaction(.INT, &action, &self.previous_int);
        posix.sigaction(.TERM, &action, &self.previous_term);
        return self;
    }

    pub fn restore(self: *Shutdown) void {
        posix.sigaction(.TERM, &self.previous_term, null);
        posix.sigaction(.INT, &self.previous_int, null);
        installed.store(false, .release);
    }

    pub fn isRequested(_: *const Shutdown) bool {
        return requested.load(.monotonic);
    }

    /// Returns once either signal has been observed, or with error.Canceled
    /// if the waiting task is canceled. A signal stays latched for this install.
    pub fn wait(_: *const Shutdown, io: std.Io) std.Io.Cancelable!void {
        while (!requested.load(.monotonic)) {
            try io.sleep(.fromMilliseconds(20), .awake);
        }
        try io.checkCancel();
    }

    fn onSignal(_: posix.SIG) callconv(.c) void {
        requested.store(true, .monotonic);
    }
};

test "SIGINT and SIGTERM latch shutdown and previous handlers are restored" {
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    var old_int: posix.Sigaction = undefined;
    posix.sigaction(.INT, &ignore, &old_int);
    defer posix.sigaction(.INT, &old_int, null);
    var old_term: posix.Sigaction = undefined;
    posix.sigaction(.TERM, &ignore, &old_term);
    defer posix.sigaction(.TERM, &old_term, null);

    for ([_]posix.SIG{ .INT, .TERM }) |sig| {
        {
            var signals = try Shutdown.install();
            defer signals.restore();
            try std.testing.expectError(error.AlreadyInstalled, Shutdown.install());
            try std.testing.expect(!Shutdown.requested.load(.monotonic));
            try posix.raise(sig);
            try std.testing.expect(Shutdown.requested.load(.monotonic));
            try signals.wait(std.testing.io);
        }
        for ([_]posix.SIG{ .INT, .TERM }) |restored_sig| {
            var action: posix.Sigaction = undefined;
            posix.sigaction(restored_sig, null, &action);
            try std.testing.expectEqual(posix.SIG.IGN, action.handler.handler);
        }
    }
}

test "wait can be canceled without a signal" {
    var signals = try Shutdown.install();
    defer signals.restore();

    const io = std.testing.io;
    var pending = try io.concurrent(Shutdown.wait, .{ &signals, io });
    try std.testing.expectError(error.Canceled, pending.cancel(io));
}
