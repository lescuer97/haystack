//! UI-free native storage surface for the headless server.
pub const paths = @import("paths.zig");
pub const wallet = @import("wallet.zig");
pub const storage_fs = @import("storage_fs.zig");
pub const instance_lock = @import("instance_lock.zig");

test {
    _ = paths;
    _ = storage_fs;
    _ = instance_lock;
}
