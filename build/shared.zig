const std = @import("std");

/// Dependency-free terrain and wire contract, specialized for its consumer.
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("shared/root.zig"), .target = target, .optimize = optimize });
}
