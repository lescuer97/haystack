const std = @import("std");

/// Native server graph only. Installation is explicit, never the default game.
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) void {
    const shared = @import("shared.zig").create(b, target, optimize);
    const websocket = b.dependency("websocket", .{ .target = target, .optimize = optimize });
    const sqlite = b.dependency("sqlite", .{ .target = target, .optimize = optimize, .memsys5 = true, .zero_malloc = true, .omit_autoinit = true, .threadsafe = @as(u2, 1) }).module("sqlite");
    const server_mod = b.createModule(.{
        .root_source_file = b.path("server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "shared", .module = shared }, .{ .name = "websocket", .module = websocket.module("websocket") } },
    });
    server_mod.addImport("sqlite", sqlite);
    server_mod.link_libc = true;
    const server = b.addExecutable(.{ .name = "haystack_server", .root_module = server_mod });
    const install_server = b.addInstallArtifact(server, .{});
    b.step("server", "Build and install the local server").dependOn(&install_server.step);
    const run_server = b.addRunArtifact(server);
    run_server.addPassthruArgs();
    b.step("run-server", "Run the local server").dependOn(&run_server.step);
    const unit_mod = b.createModule(.{ .root_source_file = b.path("server/tests.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "shared", .module = shared }} });
    unit_mod.addImport("sqlite", sqlite);
    unit_mod.addImport("websocket", websocket.module("websocket"));
    unit_mod.link_libc = true;
    const unit_tests = b.addRunArtifact(b.addTest(.{ .root_module = unit_mod }));
    const shared_tests = b.addRunArtifact(b.addTest(.{ .root_module = shared }));
    const server_test_step = b.step("test-server", "Run socket-free server and shared unit tests");
    server_test_step.dependOn(&unit_tests.step);
    server_test_step.dependOn(&shared_tests.step);
    const bounded_ws_tests = b.addRunArtifact(b.addTest(.{ .root_module = websocket.module("bounded_tests"), .filters = &.{"bounded-memory"} }));
    server_test_step.dependOn(&bounded_ws_tests.step);
    const ws_memory_mod = b.createModule(.{ .root_source_file = b.path("server/ws_memory_tests.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "websocket", .module = websocket.module("websocket") }} });
    ws_memory_mod.addImport("shared", shared);
    ws_memory_mod.addImport("sqlite", sqlite);
    server_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ws_memory_mod, .filters = &.{"bounded-memory application"} })).step);
    const bench_mod = b.createModule(.{ .root_source_file = b.path("server/bench.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "shared", .module = shared }, .{ .name = "sqlite", .module = sqlite } } });
    const benchmark = b.addExecutable(.{ .name = "bench-server", .root_module = bench_mod });
    b.step("build-bench-server", "Build/install the opt-in socket-free benchmark without running it").dependOn(&b.addInstallArtifact(benchmark, .{}).step);
    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.addPassthruArgs();
    b.step("bench-server", "Run opt-in socket-free real-file benchmark (16..512 iterations, default 128)").dependOn(&run_benchmark.step);
}
