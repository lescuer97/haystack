const std = @import("std");
const common = @import("common.zig");

pub fn build(b: *std.Build, options: common.Options) !void {
    const host = b.graph.host.result;
    const target = options.target;
    if (target.result.os.tag != .linux or target.result.os.tag != host.os.tag or
        target.result.cpu.arch != host.cpu.arch or target.result.abi != host.abi)
    {
        std.log.err("desktop currently supports native Linux only; use -Dplatform=wasm for the browser build", .{});
        return error.UnsupportedDesktopTarget;
    }
    const rust_target = try common.hostRustTarget(b);
    const setup = common.bootstrap(b, options, rust_target);
    b.step("setup", "Ensure the pinned desktop Rust toolchain (no Wasm tools)").dependOn(&setup.step);
    const manifest = "vendor/cdk-wallet-ffi/Cargo.toml";
    const rust = common.cargo(b, options, manifest, &.{ "build", "--lib", "--target", rust_target, "--target-dir", "vendor/cdk-wallet-ffi/target" });
    common.optimizeRust(rust, options);
    rust.setEnvironmentVariable("CARGO_PROFILE_RELEASE_PANIC", "unwind");
    rust.setEnvironmentVariable("CARGO_PROFILE_DEV_PANIC", "unwind");
    rust.setName("build desktop wallet C ABI");
    rust.step.dependOn(&setup.step);
    const archive = b.path(b.fmt("vendor/cdk-wallet-ffi/target/{s}/{s}/libcdk_wallet_ffi.a", .{ rust_target, options.profile() }));

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/cdk-wallet-ffi/include/cdk_wallet.h"),
        .target = target,
        .optimize = options.optimize,
    });
    translate.addIncludePath(b.path("vendor/cdk-wallet-ffi/include"));
    const cdk = b.addModule("cdk", .{ .root_source_file = b.path("src/cdk.zig"), .target = target });
    cdk.addImport("cdk_c", translate.addModule("cdk_c"));
    const mod = b.addModule("haystack_game", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = options.optimize });
    const raylib = b.dependency("raylib_zig", .{ .target = target, .optimize = options.optimize, .linkage = .dynamic });
    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = options.optimize });
    root.addImport("haystack_game", mod);
    root.addImport("raylib", raylib.module("raylib"));
    root.addImport("raygui", raylib.module("raygui"));
    root.linkLibrary(raylib.artifact("raylib"));
    root.addRPathSpecial("$ORIGIN/../lib");
    linkWallet(root, cdk, archive);
    const exe = b.addExecutable(.{ .name = "haystack_game", .root_module = root });
    exe.step.dependOn(&rust.step);
    const installed = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "desktop/bin" } } });
    b.getInstallStep().dependOn(&installed.step);
    const installed_raylib = b.addInstallArtifact(raylib.artifact("raylib"), .{ .dest_dir = .{ .override = .{ .custom = "desktop/lib" } }, .h_dir = .disabled });
    b.getInstallStep().dependOn(&installed_raylib.step);
    // Ship the game's visual assets next to the installed desktop executable
    // at zig-out/desktop/bin/assets/. The directory is a checkout-level,
    // gitignored asset source; a clean clone must populate it before install.
    b.installDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .{ .custom = "desktop/bin" },
        .install_subdir = "assets",
    });
    b.step("desktop", "Build and install the desktop application only").dependOn(b.getInstallStep());
    b.step("wallet", "Build only the desktop Rust C ABI").dependOn(&rust.step);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the desktop application").dependOn(&run.step);

    const test_step = b.step("test", "Run desktop application tests");
    const module_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
    const app_tests = b.addTest(.{ .root_module = root });
    app_tests.step.dependOn(&rust.step);
    test_step.dependOn(&b.addRunArtifact(app_tests).step);

    const headers = common.cargo(b, options, manifest, &.{ "run", "--features", "headers", "--bin", "generate-headers", "--target", rust_target, "--target-dir", "vendor/cdk-wallet-ffi/target" });
    headers.addArgs(&.{ "--", "--check" });
    headers.step.dependOn(&setup.step);
    b.step("header-check", "Verify the committed native C header").dependOn(&headers.step);
    const rust_tests = common.cargo(b, options, manifest, &.{ "test", "--target", rust_target, "--target-dir", "vendor/cdk-wallet-ffi/target" });
    rust_tests.step.dependOn(&setup.step);
    const wallet_tests = abiTests(b, options, "src/wallet_test.zig", cdk, archive, &rust.step);
    const spilman_tests = abiTests(b, options, "src/spilman_test.zig", cdk, archive, &rust.step);
    b.step("test-spilman", "Run native Spilman C-ABI integration tests").dependOn(&spilman_tests.step);
    const tests = b.step("test-wallet", "Run native Rust tests, header check and Zig C-ABI suites");
    tests.dependOn(&headers.step);
    tests.dependOn(&rust_tests.step);
    tests.dependOn(&wallet_tests.step);
    tests.dependOn(&spilman_tests.step);
}

fn linkWallet(module: *std.Build.Module, cdk: *std.Build.Module, archive: std.Build.LazyPath) void {
    module.addImport("cdk", cdk);
    module.addObjectFile(archive);
    module.link_libc = true;
    // The C ABI contains panics with unwind; Zig must resolve Rust's unwind
    // symbols. These are native Linux libraries, never browser link inputs.
    for ([_][]const u8{ "unwind", "pthread", "dl", "rt", "util", "m" }) |name| {
        module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    }
}

fn abiTests(b: *std.Build, options: common.Options, source: []const u8, cdk: *std.Build.Module, archive: std.Build.LazyPath, rust: *std.Build.Step) *std.Build.Step.Run {
    const module = b.createModule(.{ .root_source_file = b.path(source), .target = options.target, .optimize = options.optimize });
    linkWallet(module, cdk, archive);
    const tests = b.addTest(.{ .root_module = module });
    tests.step.dependOn(rust);
    return b.addRunArtifact(tests);
}
