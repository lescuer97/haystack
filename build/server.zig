const std = @import("std");
const hardening = @import("hardening.zig");

/// Native server graph only. Installation is explicit, never the default game.
pub fn build(b: *std.Build, native: @import("native_wallet.zig").Graph) !void {
    const target = native.options.target;
    const optimize = native.options.optimize;
    const secp = @import("secp256k1.zig").create(b, target, optimize) orelse return;
    const sqlite = (b.lazyDependency("zig_sqlite", .{
        .target = target,
        .optimize = optimize,
        .server_namespace = true,
        .c_hardening_flags = hardening.cFlags(optimize, target.result),
    }) orelse return).module("sqlite");
    const storage = b.createModule(.{ .root_source_file = b.path("src/native_storage.zig"), .target = target, .optimize = optimize, .link_libc = true });
    storage.addImport("cdk", native.cdk);
    // Namespaced Zig SQLite serves gameplay and the receiver's metadata and
    // read-only queries; Spilman commits channel state through its own storage.
    storage.addImport("sqlite", sqlite);
    const shared = @import("shared.zig").create(b, target, optimize);
    storage.addImport("shared", shared);
    storage.addCSourceFile(.{ .file = b.path("vendor/qrcodegen/qrcodegen.c"), .flags = &.{"-std=c99"} });
    try hardening.cSources(storage, optimize);
    const server_mod = b.createModule(.{
        .root_source_file = b.path("server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "shared", .module = shared }},
    });
    native.link(server_mod);
    secp.link(server_mod);
    server_mod.link_libc = true;
    const server = b.addExecutable(.{ .name = "haystack_server", .root_module = server_mod });
    hardening.executable(server, optimize);
    server.step.dependOn(&native.rust.step);
    const install_server = b.addInstallArtifact(server, .{});
    b.step("server", "Build and install the local server").dependOn(&install_server.step);
    const run_server = b.addRunArtifact(server);
    run_server.addPassthruArgs();
    b.step("run-server", "Run the local server").dependOn(&run_server.step);
    const bench_mod = b.createModule(.{ .root_source_file = b.path("server/chunk_read_bench.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "shared", .module = shared }} });
    native.link(bench_mod);
    const bench = b.addExecutable(.{ .name = "haystack_chunk_read_bench", .root_module = bench_mod });
    bench.step.dependOn(&native.rust.step);
    b.step("bench-chunk-reads", "Benchmark on-demand SQLite and cached RAM chunk reads").dependOn(&b.addRunArtifact(bench).step);
    const unit_mod = b.createModule(.{ .root_source_file = b.path("server/tests.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "shared", .module = shared }} });
    unit_mod.addImport("sqlite", sqlite); // Raw SQL fixtures in persistence tests.
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
    const receiver_mod = b.createModule(.{ .root_source_file = b.path("src/wallet_receiver.zig"), .target = target, .optimize = optimize });
    receiver_mod.addImport("sqlite", sqlite);
    receiver_mod.addImport("shared", shared);
    native.link(receiver_mod);
    const receiver_tests = b.addTest(.{ .root_module = receiver_mod });
    receiver_tests.step.dependOn(&native.rust.step);
    server_test_step.dependOn(&b.addRunArtifact(receiver_tests).step);
    const game_db_mod = b.createModule(.{ .root_source_file = b.path("server/game_db.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "shared", .module = shared }} });
    // Keep the focused test separate, but use the same SQLite provider as production.
    native.link(game_db_mod);
    const game_db_binary = b.addTest(.{ .root_module = game_db_mod });
    game_db_binary.step.dependOn(&native.rust.step);
    const game_db_tests = b.addRunArtifact(game_db_binary);
    b.step("test-game-db", "Run the gameplay SQLite storage tests").dependOn(&game_db_tests.step);
    server_test_step.dependOn(&game_db_tests.step);
    const ws_memory_mod = b.createModule(.{ .root_source_file = b.path("server/ws_memory_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    ws_memory_mod.addImport("shared", shared);
    native.link(ws_memory_mod);
    secp.link(ws_memory_mod);
    for ([_]*std.Build.Module{ server_mod, bench_mod, unit_mod, game_db_mod, ws_memory_mod }) |mod| {
        mod.addImport("native_storage", storage);
    }
    const ws_memory_binary = b.addTest(.{ .root_module = ws_memory_mod, .filters = &.{"bounded-memory application"} });
    ws_memory_binary.step.dependOn(&native.rust.step);
    server_test_step.dependOn(&b.addRunArtifact(ws_memory_binary).step);
}
