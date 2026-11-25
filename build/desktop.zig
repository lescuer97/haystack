const std = @import("std");
const common = @import("common.zig");
const platform = @import("platform.zig");
const hardening = @import("hardening.zig");

const raylib_library_name = "raylib";

pub fn build(b: *std.Build, native: @import("native_wallet.zig").Graph, standalone: bool, standalone_smoke: bool) !void {
    const options = native.options;
    const policy = native.policy;
    const target = options.target;
    const macos = policy.os == .macos;

    const bin_dir = if (standalone) "desktop-standalone" else "desktop/bin";
    std.log.info(
        "desktop: {s}-{s}-{s}, Rust {s}, optimize {s}, output {s}/haystack_game",
        .{
            @tagName(policy.arch),
            @tagName(policy.os),
            @tagName(policy.abi),
            policy.rust_target,
            @tagName(options.optimize),
            bin_dir,
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
    const linkage: std.builtin.LinkMode = if (standalone) .static else .dynamic;
    const raylib = b.dependency("raylib_zig", .{ .target = target, .optimize = options.optimize, .linkage = linkage });
    const raylib_artifact = raylib.artifact(raylib_library_name);
    const raylib_module = raylib.module(raylib_library_name);
    try hardening.cSources(raylib_artifact.root_module, options.optimize);
    if (macos and !standalone) raylib_artifact.install_name = "@rpath/libraylib.dylib";
    if (preflight) |step| raylib_artifact.step.dependOn(&step.step);
    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = options.optimize });
    root.addImport("shared", shared);
    common.addAssetOptions(b, root, standalone, standalone_smoke);
    const asset_check = if (standalone) addStandaloneAssets(b, root) else null;
    common.addCutSoundAssets(b, root, asset_check);
    const websocket = b.lazyDependency("websocket", .{ .target = target, .optimize = options.optimize }) orelse return;
    root.addImport("websocket", websocket.module("websocket"));
    const secp = @import("secp256k1.zig").create(b, target, options.optimize) orelse return;
    secp.link(root);
    const sqlite = (b.lazyDependency("zig_sqlite", .{
        .target = target,
        .optimize = options.optimize,
        .server_namespace = true,
        .c_hardening_flags = hardening.cFlags(options.optimize, target.result),
    }) orelse return).module("sqlite");
    root.addImport("sqlite", sqlite);
    root.addCSourceFile(.{ .file = b.path("vendor/qrcodegen/qrcodegen.c"), .flags = &.{"-std=c99"} });
    root.addImport("haystack_game", mod);
    root.addImport("raylib", raylib_module);
    root.addImport("raygui", raylib.module("raygui"));
    // The bindings already link the static raylib artifact. For the shared
    // build, link by name instead so Zig doesn't inject a cache-directory rpath.
    if (!standalone) {
        root.addRPathSpecial(policy.rpath);
        detachArtifactLink(raylib_module, raylib_artifact);
        root.addLibraryPath(raylib_artifact.getEmittedBin().dirname());
        root.linkSystemLibrary(raylib_library_name, .{ .use_pkg_config = .no });
    }
    linkWallet(root, cdk, archive, policy);
    const exe = b.addExecutable(.{ .name = "haystack_game", .root_module = root });
    try hardening.cSources(root, options.optimize);
    hardening.executable(exe, options.optimize);
    // Do not add cache fallbacks to either flavor.
    exe.each_lib_rpath = false;
    exe.step.dependOn(&rust.step);
    exe.step.dependOn(&raylib_artifact.step);
    if (preflight) |step| exe.step.dependOn(&step.step);
    if (asset_check) |step| exe.step.dependOn(&step.step);
    if (standalone) {
        const unstripped = exe.getEmittedBin();
        const stripped = stripStandalone(b, unstripped, macos);
        const installed = b.addInstallFile(stripped, b.fmt("{s}/haystack_game", .{bin_dir}));
        b.getInstallStep().dependOn(&installed.step);
        const debug = b.addInstallFile(unstripped, "desktop-standalone-debug/haystack_game");
        b.getInstallStep().dependOn(&debug.step);
        b.step("standalone-debug", "Save the matching unstripped standalone executable for debugging").dependOn(&debug.step);
    } else {
        const installed = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = bin_dir } } });
        b.getInstallStep().dependOn(&installed.step);
        const installed_raylib = b.addInstallArtifact(raylib_artifact, .{ .dest_dir = .{ .override = .{ .custom = "desktop/lib" } }, .h_dir = .disabled });
        b.getInstallStep().dependOn(&installed_raylib.step);
        b.installDirectory(.{
            .source_dir = b.path("assets"),
            .install_dir = .{ .custom = bin_dir },
            .install_subdir = "assets",
            .exclude_extensions = &.{ "sfx/snip.wav", "sfx/fail.wav", "sfx/reward.wav" },
        });
    }
    b.step("desktop", "Build and install the desktop application only").dependOn(b.getInstallStep());
    b.step("wallet", "Build only the desktop Rust C ABI").dependOn(&rust.step);
    // Run the installed executable in both modes; the shared build needs
    // its installed raylib at the relative rpath, not in the cache.
    const run = b.addRunFile(b.graph.path(.install_prefix, b.fmt("{s}/haystack_game", .{bin_dir})));
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
    if (asset_check) |step| app_tests.step.dependOn(&step.step);
    test_step.dependOn(&b.addRunArtifact(app_tests).step);
    const wallet_storage_module = b.createModule(.{ .root_source_file = b.path("src/wallet_storage_test.zig"), .target = target, .optimize = options.optimize });
    wallet_storage_module.addImport("shared", shared);
    wallet_storage_module.addImport("sqlite", sqlite);
    secp.link(wallet_storage_module);
    wallet_storage_module.addCSourceFile(.{ .file = b.path("vendor/qrcodegen/qrcodegen.c"), .flags = &.{"-std=c99"} });
    native.link(wallet_storage_module);
    const wallet_storage_unit_tests = b.addTest(.{ .root_module = wallet_storage_module });
    wallet_storage_unit_tests.step.dependOn(&rust.step);
    const wallet_storage_tests = b.addRunArtifact(wallet_storage_unit_tests);
    test_step.dependOn(&wallet_storage_tests.step);
    const spilman_module = b.createModule(.{ .root_source_file = b.path("src/hoe_wallet_ops.zig"), .target = target, .optimize = options.optimize });
    spilman_module.addImport("shared", shared);
    native.link(spilman_module);
    const spilman_unit_tests = b.addTest(.{ .root_module = spilman_module });
    spilman_unit_tests.step.dependOn(&rust.step);
    const spilman_unit_step = b.step("test-spilman-storage", "Run offline desktop Spilman storage and funding unit tests");
    spilman_unit_step.dependOn(&b.addRunArtifact(spilman_unit_tests).step);
    test_step.dependOn(spilman_unit_step);

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

fn stripStandalone(b: *std.Build, unstripped: std.Build.LazyPath, macos: bool) std.Build.LazyPath {
    const strip = if (macos)
        // Stripping modifies the Mach-O bytes covered by its ad-hoc signature.
        b.addSystemCommand(&.{ "sh", "-c", "xcrun strip -S -x -o \"$1\" \"$2\" && /usr/bin/codesign --force --sign - \"$1\"", "strip-and-sign" })
    else
        b.addSystemCommand(&.{ "strip", "--strip-unneeded", "-o" });
    strip.setName("strip standalone executable for distribution");
    const stripped = strip.addOutputFileArg("haystack_game");
    strip.addFileArg(unstripped);
    return stripped;
}

fn addStandaloneAssets(b: *std.Build, root: *std.Build.Module) *std.Build.Step.Run {
    const check = b.addSystemCommand(&.{ "python3", "build-support/standalone_assets.py", "check" });
    check.setName("check required standalone assets");
    check.setCwd(b.path("."));
    check.has_side_effects = true;
    for (@import("../src/atlas_assets.zig").all) |atlas| addAsset(b, root, check, atlas.path);
    for (@import("../src/soundtrack_tracks.zig").paths) |path| addAsset(b, root, check, path);
    return check;
}

fn addAsset(b: *std.Build, root: *std.Build.Module, check: *std.Build.Step.Run, path: []const u8) void {
    check.addArg(path);
    root.addAnonymousImport(path, .{ .root_source_file = b.path(path) });
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

    linkWallet(module, cdk, archive, policy);
    const tests = b.addTest(.{ .root_module = module });
    tests.step.dependOn(rust);
    return b.addRunArtifact(tests);
}
