//! Single-tile movement against generated terrain, independent of chunk residency.
const std = @import("std");
const Location = @import("protocol.zig").Location;
const world = @import("world.zig");

pub const spawn: Location = .{ .x = 0, .y = 0 };

fn walkable(pos: Location) bool {
    return switch (world.sampleTile(world.public_seed, pos.x, pos.y)) {
        .grass, .dirt => true,
        .rock, .tree, .water => false,
    };
}

/// A diagonal also needs both side tiles clear. An unchanged position is a no-op.
pub fn canStep(from: Location, to: Location) bool {
    const dx = @as(i64, to.x) - from.x;
    const dy = @as(i64, to.y) - from.y;
    if (dx == 0 and dy == 0) return true;
    if (@abs(dx) > 1 or @abs(dy) > 1 or !walkable(to)) return false;
    if (dx == 0 or dy == 0) return true;
    return walkable(.{ .x = to.x, .y = from.y }) and
        walkable(.{ .x = from.x, .y = to.y });
}

test "walkable spawn and moves across a negative chunk boundary" {
    try std.testing.expect(walkable(spawn));
    try std.testing.expect(canStep(spawn, spawn));
    try std.testing.expect(canStep(.{ .x = -1, .y = -1 }, spawn));
    try std.testing.expect(canStep(spawn, .{ .x = -1, .y = 0 }));
    try std.testing.expect(canStep(.{ .x = 6, .y = 0 }, .{ .x = 7, .y = 0 })); // dirt
}

test "blocked destination and diagonals cannot cut corners" {
    const from: Location = .{ .x = 19, .y = 0 };
    const side: Location = .{ .x = 20, .y = 0 };
    const diagonal: Location = .{ .x = 20, .y = 1 };
    try std.testing.expect(walkable(from) and walkable(diagonal));
    try std.testing.expect(walkable(.{ .x = 19, .y = 1 }));
    try std.testing.expect(!canStep(from, side));
    try std.testing.expect(!canStep(from, diagonal));
    try std.testing.expect(!canStep(.{ .x = 26, .y = 1 }, .{ .x = 26, .y = 0 }));
}

test "multi-tile moves are rejected even at the coordinate extremes" {
    try std.testing.expect(!canStep(spawn, .{ .x = 2, .y = 0 }));
    try std.testing.expect(!canStep(.{ .x = std.math.minInt(i32), .y = 0 }, .{ .x = std.math.maxInt(i32), .y = 0 }));
}
