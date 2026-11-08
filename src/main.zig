const std = @import("std");
const builtin = @import("builtin");

const chunk_debug = @import("render/chunk_debug.zig");

// `zig build test` only collects tests from files referenced here; without
// this the renderer's streaming tests are compiled but never executed.
comptime {
    _ = @import("render/chunk_debug.zig");
}

pub fn main() anyerror!void {
    const use_debug_allocator = switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    };
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (use_debug_allocator) _ = debug_allocator.deinit();
    }
    const allocator = if (use_debug_allocator) debug_allocator.allocator() else std.heap.c_allocator;

    // Temporary: chunk/tile border test render.
    // Persistent containers need individual frees when they grow. The world
    // owns its chunk pool and releases everything when the scene closes.
    try chunk_debug.run(allocator);
}
