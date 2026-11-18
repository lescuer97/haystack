const std = @import("std");

/// Native server graph only. Installation is explicit, never the default game.
pub fn build(b: *std.Build, native: @import("native_wallet.zig").Graph) void {
    const target = native.options.target;
    const optimize = native.options.optimize;
    const storage = b.createModule(.{ .root_source_file = b.path("src/native_storage.zig"), .target = target, .optimize = optimize, .link_libc = true });
    storage.addImport("cdk", native.cdk);
    const shared = @import("shared.zig").create(b, target, optimize);
    const websocket = b.dependency("websocket", .{ .target = target, .optimize = optimize });
    const sqlite_dep = b.dependency("sqlite", .{ .target = target, .optimize = optimize, .server_namespace = true, .memsys5 = true, .zero_malloc = true, .omit_autoinit = true, .threadsafe = @as(u2, 1) });
    const sqlite = sqlite_dep.module("sqlite");
    if (native.preflight) |step| sqlite_dep.artifact("sqlite").step.dependOn(&step.step);
    const namespace = b.addSystemCommand(&.{ "python3", "build-support/check_server_namespace.py" });
    namespace.addFileArg(sqlite_dep.namedLazyPath("sqlite_archive"));
    namespace.addFileArg(sqlite_dep.namedLazyPath("sqlite_header"));
    namespace.addFileArg(sqlite_dep.namedLazyPath("sqlite_bindings"));
    namespace.addFileArg(b.path("vendor/zig-sqlite/c/server_namespace.h"));
    const server_mod = b.createModule(.{
        .root_source_file = b.path("server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "shared", .module = shared }, .{ .name = "websocket", .module = websocket.module("websocket") } },
    });
    server_mod.addImport("sqlite", sqlite);
    server_mod.addImport("native_storage", storage);
    native.link(server_mod);
    server_mod.link_libc = true;
    const server = b.addExecutable(.{ .name = "haystack_server", .root_module = server_mod });
    server.step.dependOn(&native.rust.step);
    server.step.dependOn(&namespace.step);
    const install_server = b.addInstallArtifact(server, .{});
    b.step("server", "Build and install the local server").dependOn(&install_server.step);
    const run_server = b.addRunArtifact(server);
    run_server.addPassthruArgs();
    b.step("run-server", "Run the local server").dependOn(&run_server.step);
    const unit_mod = b.createModule(.{ .root_source_file = b.path("server/tests.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "shared", .module = shared }} });
    unit_mod.addImport("sqlite", sqlite);
    unit_mod.addImport("native_storage", storage);
    native.link(unit_mod);
    unit_mod.addImport("websocket", websocket.module("websocket"));
    unit_mod.link_libc = true;
    const unit_binary = b.addTest(.{ .root_module = unit_mod });
    unit_binary.step.dependOn(&native.rust.step);
    const unit_tests = b.addRunArtifact(unit_binary);
    const shared_tests = b.addRunArtifact(b.addTest(.{ .root_module = shared }));
    const server_test_step = b.step("test-server", "Run socket-free server and shared unit tests");
    server_test_step.dependOn(&unit_tests.step);
    server_test_step.dependOn(&namespace.step);
    server_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = storage })).step);
    server_test_step.dependOn(&shared_tests.step);
    const bounded_ws_tests = b.addRunArtifact(b.addTest(.{ .root_module = websocket.module("bounded_tests"), .filters = &.{"bounded-memory"} }));
    server_test_step.dependOn(&bounded_ws_tests.step);
    const ws_memory_mod = b.createModule(.{ .root_source_file = b.path("server/ws_memory_tests.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "websocket", .module = websocket.module("websocket") }} });
    ws_memory_mod.addImport("shared", shared);
    ws_memory_mod.addImport("sqlite", sqlite);
    ws_memory_mod.addImport("native_storage", storage);
    server_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ws_memory_mod, .filters = &.{"bounded-memory application"} })).step);
    const bench_mod = b.createModule(.{ .root_source_file = b.path("server/bench.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "shared", .module = shared }, .{ .name = "sqlite", .module = sqlite } } });
    bench_mod.addImport("native_storage", storage);
    const benchmark = b.addExecutable(.{ .name = "bench-server", .root_module = bench_mod });
    benchmark.step.dependOn(&namespace.step);
    b.step("build-bench-server", "Build/install the opt-in socket-free benchmark without running it").dependOn(&b.addInstallArtifact(benchmark, .{}).step);
    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.addPassthruArgs();
    b.step("bench-server", "Run opt-in socket-free real-file benchmark (16..512 iterations, default 128)").dependOn(&run_benchmark.step);
}
