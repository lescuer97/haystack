//! Shared production/component-test transport limits; no application or SQLite dependency.
pub const config: @import("websocket").Config = .{
    .address = "127.0.0.1",
    .port = 9224,
    .worker_count = 1,
    .max_conn = 64,
    .max_message_size = 128,
    .handshake = .{ .timeout = 5, .max_size = 8192, .max_headers = 32 },
    .thread_pool = .{ .count = 4, .backlog = 64, .buffer_size = 0 },
    .buffers = .{ .small_size = 2048, .small_pool = 64, .large_size = 128, .large_pool = 64 },
};
