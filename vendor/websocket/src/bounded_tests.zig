// Test discovery only. The build and embedding callers MUST filter on
// "bounded-memory"; upstream's other tests include networking fixtures.
comptime {
    _ = @import("websocket.zig");
    _ = @import("server/rejection.zig");
    _ = @import("server/lifecycle.zig");
    _ = @import("server/thread_pool.zig");
}
