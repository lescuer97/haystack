const std = @import("std");

/// Native server graph only. Installation is explicit, never the default game.
pub fn build(b: *std.Build, native: @import("native_wallet.zig").Graph) void {
    const target = native.options.target;
    const optimize = native.options.optimize;
    const secp = @import("secp256k1.zig").create(b, target, optimize) orelse return;
    const storage = b.createModule(.{ .root_source_file = b.path("src/native_storage.zig"), .target = target, .optimize = optimize, .link_libc = true });
    storage.addImport("cdk", native.cdk);
    const shared = @import("shared.zig").create(b, target, optimize);
    const server_mod = b.createModule(.{
        .root_source_file = b.path("server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "shared", .module = shared }},
    });
    server_mod.addImport("native_storage", storage);
    native.link(server_mod);
    secp.link(server_mod);
    server_mod.link_libc = true;
    const server = b.addExecutable(.{ .name = "haystack_server", .root_module = server_mod });
    server.step.dependOn(&native.rust.step);
    const install_server = b.addInstallArtifact(server, .{});
    b.step("server", "Build and install the local server").dependOn(&install_server.step);
    const run_server = b.addRunArtifact(server);
    run_server.addPassthruArgs();
    b.step("run-server", "Run the local server").dependOn(&run_server.step);
    const unit_mod = b.createModule(.{ .root_source_file = b.path("server/tests.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "shared", .module = shared }} });
    unit_mod.addImport("native_storage", storage);
    unit_mod.addAnonymousImport("spilman_vectors.json", .{ .root_source_file = b.path("src/testdata/spilman_vectors.json") });
    native.link(unit_mod);
    secp.link(unit_mod);
    unit_mod.link_libc = true;
    const unit_binary = b.addTest(.{ .root_module = unit_mod });
    unit_binary.step.dependOn(&native.rust.step);
    const unit_tests = b.addRunArtifact(unit_binary);
    const shared_tests = b.addRunArtifact(b.addTest(.{ .root_module = shared }));
    const server_test_step = b.step("test-server", "Run socket-free server and shared unit tests");
    server_test_step.dependOn(&unit_tests.step);
    server_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = storage })).step);
    server_test_step.dependOn(&shared_tests.step);
    const ws_memory_mod = b.createModule(.{ .root_source_file = b.path("server/ws_memory_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    ws_memory_mod.addImport("shared", shared);
    ws_memory_mod.addImport("native_storage", storage);
    secp.link(ws_memory_mod);
    server_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ws_memory_mod, .filters = &.{"bounded-memory application"} })).step);
}
