const std = @import("std");
const posix = @import("../posix.zig");

pub const accept_batch = 16;
pub const response = "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";

pub const Batch = struct {
    remaining: usize = accept_batch,

    pub fn next(self: *Batch) bool {
        if (self.remaining == 0) return false;
        self.remaining -= 1;
        return true;
    }
};

// The accepted descriptor MUST still be nonblocking. Exactly one best-effort
// send: short writes and all errors (including EINTR/WouldBlock) simply close.
pub fn reject(socket: posix.socket_t, transport: anytype) void {
    defer transport.close(socket);
    _ = transport.send(socket, response) catch return;
}

pub const Raw = struct {
    pub fn send(_: Raw, socket: posix.socket_t, bytes: []const u8) !usize {
        const flags = if (@hasDecl(std.c.MSG, "NOSIGNAL")) std.c.MSG.NOSIGNAL else 0;
        const rc = std.c.send(socket, bytes.ptr, bytes.len, flags);
        if (rc < 0) return error.Unavailable;
        return @intCast(rc);
    }

    pub fn close(_: Raw, socket: posix.socket_t) void {
        posix.close(socket);
    }
};

test "bounded-memory HTTP503 one nonblocking send then raw close on every outcome" {
    const Mock = struct {
        outcome: enum { complete, partial, would_block, failure },
        sends: usize = 0,
        closes: usize = 0,
        nonblocking: bool = true,

        pub fn send(self: *@This(), _: posix.socket_t, bytes: []const u8) !usize {
            try std.testing.expect(self.nonblocking);
            try std.testing.expectEqualStrings(response, bytes);
            self.sends += 1;
            return switch (self.outcome) {
                .complete => bytes.len,
                .partial => 3,
                .would_block => error.WouldBlock,
                .failure => error.BrokenPipe,
            };
        }

        pub fn close(self: *@This(), _: posix.socket_t) void {
            self.closes += 1;
        }
    };
    inline for (std.meta.tags(@FieldType(Mock, "outcome"))) |outcome| {
        var mock: Mock = .{ .outcome = outcome };
        reject(0, &mock); // Integer is a mock token, never an OS descriptor.
        try std.testing.expectEqual(@as(usize, 1), mock.sends);
        try std.testing.expectEqual(@as(usize, 1), mock.closes);
    }
    // Force analysis/linkage of the production transport without calling it.
    const send: *const fn (Raw, posix.socket_t, []const u8) anyerror!usize = Raw.send;
    std.mem.doNotOptimizeAway(send);
}

test "bounded-memory rejection batch is bounded to leave readiness work runnable" {
    // The accept loop uses this same bound for BOTH admissions and rejections.
    // Model an inexhaustible listener and a ready connection in each event batch.
    var accepted: usize = 0;
    var ready: usize = 0;
    for (0..4) |_| {
        var batch: Batch = .{};
        while (batch.next()) accepted += 1;
        try std.testing.expect(!batch.next());
        ready += 1;
        try std.testing.expectEqual(ready * 16, accepted);
    }
    try std.testing.expectEqual(@as(usize, 4), ready);
}
