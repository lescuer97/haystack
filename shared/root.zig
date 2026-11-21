pub const world = @import("world.zig");
pub const protocol = @import("protocol.zig");
pub const wire = @import("wire.zig");
pub const tick = @import("tick.zig");
pub const movement = @import("movement.zig");
test {
    _ = world;
    _ = protocol;
    _ = wire;
    _ = tick;
    _ = movement;
}
