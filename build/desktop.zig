const std = @import("std");
const common = @import("common.zig");
const platform = @import("platform.zig");

const raylib_library_name = "raylib";

pub fn build(b: *std.Build, native: @import("native_wallet.zig").Graph) !void {
    const options = native.options;
    const policy = native.policy;
    const target = options.target;
    const macos = policy.os == .macos;

    std.log.info(
        "desktop: {s}-{s}-{s}, Rust {s}, optimize {s}, output desktop/bin/haystack_game",
        .{
            @tagName(policy.arch),
            @tagName(policy.os),
            @tagName(policy.abi),
            policy.rust_target,
            @tagName(options.optimize),
        },
    );

    const preflight = native.preflight;
    const check = native.check;
    const manifest = "vendor/cdk-wallet-ffi/Cargo.toml";
    const rust = native.rust;
    const archive = native.archive;
    const cdk = native.cdk;
    const mod = b.addModule("haystack_game", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = options.optimize });
    const shared = @import("shared.zig").create(b, target, options.optimize);
    mod.addImport("shared", shared);
    const raylib = b.dependency("raylib_zig", .{ .target = target, .optimize = options.optimize, .linkage = .dynamic });
    const raylib_artifact = raylib.artifact(raylib_library_name);
    const raylib_module = raylib.module(raylib_library_name);
    if (macos) raylib_artifact.install_name = "@rpath/libraylib.dylib";
    if (preflight) |step| raylib_artifact.step.dependOn(&step.step);
    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = options.optimize });
    root.addImport("shared", shared);
    const websocket = b.lazyDependency("websocket", .{ .target = target, .optimize = options.optimize }) orelse return;
    root.addImport("websocket", websocket.module("websocket"));
    const secp = @import("secp256k1.zig").create(b, target, options.optimize) orelse return;
    secp.link(root);
    root.addCSourceFile(.{ .file = b.path("vendor/qrcodegen/qrcodegen.c"), .flags = &.{"-std=c99"} });
    root.addImport("haystack_game", mod);
    root.addImport("raylib", raylib_module);
    root.addImport("raygui", raylib.module("raygui"));
    root.addRPathSpecial(policy.rpath);
    // Link raylib by name from its build directory instead of linking the
    // artifact path directly. Zig records a cache-directory rpath for dynamic
    // library inputs reached through the imported raylib module; that would
    // precede the installed-tree rpath and make the shipped binary depend on a
    // build cache. Detach that direct link first, then link the same library by
    // name from its emitted directory.
    detachArtifactLink(raylib_module, raylib_artifact);
    root.addLibraryPath(raylib_artifact.getEmittedBin().dirname());
    root.linkSystemLibrary(raylib_library_name, .{ .use_pkg_config = .no });
    linkWallet(root, cdk, archive, policy);
    const exe = b.addExecutable(.{ .name = "haystack_game", .root_module = root });
    // We add exactly one relocatable rpath above; do not add cache fallbacks.
    exe.each_lib_rpath = false;
    exe.step.dependOn(&rust.step);
    exe.step.dependOn(&raylib_artifact.step);
    if (preflight) |step| exe.step.dependOn(&step.step);
    const installed = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "desktop/bin" } } });
    b.getInstallStep().dependOn(&installed.step);
    const installed_raylib = b.addInstallArtifact(raylib_artifact, .{ .dest_dir = .{ .override = .{ .custom = "desktop/lib" } }, .h_dir = .disabled });
    b.getInstallStep().dependOn(&installed_raylib.step);
    // Ship assets next to the installed executable. Music is tracked; a clean
    // clone still needs to populate the gitignored visual assets.
    b.installDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .{ .custom = "desktop/bin" },
        .install_subdir = "assets",
    });
    b.step("desktop", "Build and install the desktop application only").dependOn(b.getInstallStep());
    b.step("wallet", "Build only the desktop Rust C ABI").dependOn(&rust.step);
    // Run the *installed* executable, not the cache artifact: the installed
    // binary records only `$ORIGIN/../lib` (Linux) or `@loader_path/../lib`
    // (macOS), so it must execute next to its installed raylib.
    const run = b.addRunFile(b.graph.path(.install_prefix, "desktop/bin/haystack_game"));
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the installed desktop application").dependOn(&run.step);

    const test_step = b.step("test", "Run desktop application tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = shared })).step);
    if (preflight) |step| test_step.dependOn(&step.step);
    const module_tests = b.addTest(.{ .root_module = mod });
    if (preflight) |step| module_tests.step.dependOn(&step.step);
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
    const app_tests = b.addTest(.{ .root_module = root });
    if (preflight) |step| app_tests.step.dependOn(&step.step);
    app_tests.step.dependOn(&rust.step);
    test_step.dependOn(&b.addRunArtifact(app_tests).step);
    const wallet_storage_tests = abiTests(b, options, "src/wallet_storage_test.zig", cdk, archive, &rust.step, policy);
    test_step.dependOn(&wallet_storage_tests.step);

    const headers = common.cargo(b, options, manifest, &.{ "run", "--features", "headers", "--bin", "generate-headers", "--target", policy.rust_target, "--target-dir", "vendor/cdk-wallet-ffi/target" });
    headers.addArgs(&.{ "--", "--check" });
    headers.step.dependOn(&check.step);
    common.applyDeploymentTarget(headers, target);
    // Header rendering is independent of Cargo's optimization profile; keep
    // this check in the dev profile and do not add release/panic overrides.
    b.step("header-check", "Verify the committed native C header").dependOn(&headers.step);
    const rust_tests = common.cargo(b, options, manifest, &.{ "test", "--target", policy.rust_target, "--target-dir", "vendor/cdk-wallet-ffi/target" });
    rust_tests.step.dependOn(&check.step);
    common.applyDeploymentTarget(rust_tests, target);
    // Native tests must use the same release profile, overflow checks and
    // unwind panics as the artifact/staticlib selected by -Doptimize.
    common.optimizeRust(rust_tests, options);
    common.unwindPanic(rust_tests);
    const wallet_tests = abiTests(b, options, "src/wallet_test.zig", cdk, archive, &rust.step, policy);
    const spilman_tests = abiTests(b, options, "src/spilman_test.zig", cdk, archive, &rust.step, policy);
    b.step("test-spilman", "Run native Spilman C-ABI integration tests").dependOn(&spilman_tests.step);
    const tests = b.step("test-wallet", "Run native Rust tests, header check and Zig C-ABI suites");
    tests.dependOn(&headers.step);
    tests.dependOn(&rust_tests.step);
    tests.dependOn(&wallet_tests.step);
    tests.dependOn(&wallet_storage_tests.step);
    tests.dependOn(&spilman_tests.step);
}

/// Remove the raylib bindings module's direct artifact link so the executable
/// can link the same shared library by name without Zig adding the artifact's
/// cache directory as an rpath. The compile dependency is re-established on the
/// executable and the artifact remains in the install graph.
fn detachArtifactLink(module: *std.Build.Module, artifact: *std.Build.Step.Compile) void {
    var i: usize = 0;
    while (i < module.link_objects.items.len) {
        const object = module.link_objects.items[i];
        if (object == .other_step and object.other_step == artifact) {
            _ = module.link_objects.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

const linkWallet = @import("native_wallet.zig").linkWallet;

fn abiTests(b: *std.Build, options: common.Options, source: []const u8, cdk: *std.Build.Module, archive: std.Build.LazyPath, rust: *std.Build.Step, policy: platform.Policy) *std.Build.Step.Run {
    const module = b.createModule(.{ .root_source_file = b.path(source), .target = options.target, .optimize = options.optimize });
    if (std.mem.eql(u8, source, "src/wallet_storage_test.zig")) module.addCSourceFile(.{ .file = b.path("vendor/qrcodegen/qrcodegen.c"), .flags = &.{"-std=c99"} });
    linkWallet(module, cdk, archive, policy);
    const tests = b.addTest(.{ .root_module = module });
    tests.step.dependOn(rust);
    return b.addRunArtifact(tests);
}
