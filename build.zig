const std = @import("std");
const common = @import("build/common.zig");

const Platform = enum { desktop, wasm };

pub fn build(b: *std.Build) !void {
    const requested = b.option(Platform, "platform", "Build desktop (default) or the complete browser Wasm application");
    const target = b.standardTargetOptions(.{
        .default_target = if (requested == .wasm)
            .{ .cpu_arch = .wasm32, .os_tag = .emscripten }
        else
            .{},
    });
    const platform = requested orelse if (target.result.cpu.arch == .wasm32 or target.result.cpu.arch == .wasm64)
        Platform.wasm
    else
        Platform.desktop;
    const optimize: std.builtin.Optimize = b.option(std.builtin.Optimize, "optimize", "Debug, ReleaseSafe, ReleaseFast or ReleaseSmall (Wasm defaults to ReleaseSmall)") orelse switch (b.graph.release_mode) {
        .off => if (platform == .wasm) .small else .debug,
        .any => if (platform == .wasm) .small else .safe,
        .small => .small,
        .safe => .safe,
        .fast => .fast,
    };
    const options: common.Options = .{
        .target = target,
        .optimize = optimize,
        .toolchain = b.option([]const u8, "rust-toolchain", "Rustup toolchain (default: pinned 1.99.0)") orelse "1.99.0",
        .offline = b.option(bool, "offline", "Forbid tool downloads and Cargo network access") orelse false,
    };
    const build_tests = b.addSystemCommand(&.{ "python3", "-m", "unittest", "discover", "-s", "build-support", "-p", "test_*.py" });
    build_tests.setCwd(b.path("."));
    b.step("test-build", "Test platform graph isolation and cached/offline tool provisioning").dependOn(&build_tests.step);

    // Deliberately configure ONE graph. Desktop never initializes browser
    // toolchains; Wasm never translates/links the native C ABI or desktop raylib.
    switch (platform) {
        .desktop => try @import("build/desktop.zig").build(b, options),
        .wasm => try @import("build/wasm.zig").build(b, options),
    }
}

