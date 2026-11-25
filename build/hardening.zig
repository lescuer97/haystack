const std = @import("std");

pub fn zigModule(module: *std.Build.Module, optimize: std.builtin.OptimizeMode) void {
    if (optimize == .debug) return;
    module.stack_protector = true;
    const target = module.resolved_target.?.result;
    // Zig 0.17 rejects explicit stack checking on the supported arm64 targets.
    // Emscripten checks the linear-memory stack at link time instead.
    if (target.os.tag == .linux and target.cpu.arch == .x86_64) module.stack_check = true;
}

pub fn executable(exe: *std.Build.Step.Compile, optimize: std.builtin.OptimizeMode) void {
    if (optimize == .debug) return;
    exe.pie = true;
    zigModule(exe.root_module, optimize);
}

pub fn cFlags(optimize: std.builtin.OptimizeMode, os: std.Target.Os.Tag) []const []const u8 {
    if (optimize == .debug) return &.{};
    return switch (os) {
        .linux => &.{ "-fstack-protector-strong", "-fstack-clash-protection" },
        .macos, .emscripten => &.{"-fstack-protector-strong"},
        else => unreachable,
    };
}

/// Preserve source-specific flags, including those from the pinned raylib graph.
pub fn cSources(module: *std.Build.Module, optimize: std.builtin.OptimizeMode, os: std.Target.Os.Tag) !void {
    const extra = cFlags(optimize, os);
    if (extra.len == 0) return;
    if (os != .emscripten) module.pic = true;
    for (module.link_objects.items) |object| {
        const flags = switch (object) {
            .c_source_file => |source| &source.flags,
            .c_source_files => |sources| &sources.flags,
            else => continue,
        };
        flags.* = try std.mem.concat(module.owner.allocator, []const u8, &.{ flags.*, extra });
    }
}
