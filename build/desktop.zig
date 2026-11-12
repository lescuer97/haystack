const std = @import("std");
const common = @import("common.zig");
const platform = @import("platform.zig");

const raylib_library_name = "raylib";

pub fn build(b: *std.Build, options_in: common.Options) !void {
    const host = b.graph.host.result;
    const policy = platform.resolve(host, options_in.target.result) catch |err| {
        reportUnsupportedTarget(err, host, options_in.target.result);
        return error.UnsupportedDesktopTarget;
    };

    var options = options_in;
    options.target = common.desktopTarget(b, options.target, policy);
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

    // The preflight is part of THIS graph only and is a prerequisite of every
    // native Rust/C compilation below. It never runs for Wasm configuration.
    const preflight: ?*std.Build.Step.Run = if (macos) blk: {
        const run = b.addSystemCommand(&.{ "python3", "build-support/macos-preflight.py", "--deployment-target", common.macos_deployment_target, "--rust-target", policy.rust_target });
        run.setName("check native macOS ARM64 toolchain, SDK and deployment target");
        run.setCwd(b.path("."));
        // The selected Xcode/SDK can change without the command line changing.
        run.has_side_effects = true;
        break :blk run;
    } else null;

    const setup_command = common.setupCommand(b, "zig build setup", options.toolchain);
    const setup = common.rustTools(b, options, policy.rust_target, host, true, .provision, setup_command);
    if (preflight) |step| setup.step.dependOn(&step.step);
    b.step("setup", "Provision the pinned desktop Rust toolchain and validate native prerequisites (no application build)").dependOn(&setup.step);

    const check = common.rustTools(b, options, policy.rust_target, host, true, .check, setup_command);
    if (preflight) |step| check.step.dependOn(&step.step);

    const manifest = "vendor/cdk-wallet-ffi/Cargo.toml";
    const rust = common.cargo(b, options, manifest, &.{ "build", "--lib", "--target", policy.rust_target, "--target-dir", "vendor/cdk-wallet-ffi/target" });
    common.optimizeRust(rust, options);
    common.applyDeploymentTarget(rust, target);
    common.unwindPanic(rust);
    rust.setName("build desktop wallet C ABI");
    rust.step.dependOn(&check.step);
    const archive = b.path(b.fmt("vendor/cdk-wallet-ffi/target/{s}/{s}/libcdk_wallet_ffi.a", .{ policy.rust_target, options.profile() }));

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/cdk-wallet-ffi/include/cdk_wallet.h"),
        .target = target,
        .optimize = options.optimize,
    });
    translate.addIncludePath(b.path("vendor/cdk-wallet-ffi/include"));
    if (preflight) |step| translate.step.dependOn(&step.step);
    const cdk = b.addModule("cdk", .{ .root_source_file = b.path("src/cdk.zig"), .target = target });
    cdk.addImport("cdk_c", translate.addModule("cdk_c"));
    const mod = b.addModule("haystack_game", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = options.optimize });
    const raylib = b.dependency("raylib_zig", .{ .target = target, .optimize = options.optimize, .linkage = .dynamic });
    const raylib_artifact = raylib.artifact(raylib_library_name);
    const raylib_module = raylib.module(raylib_library_name);
    if (macos) raylib_artifact.install_name = "@rpath/libraylib.dylib";
    if (preflight) |step| raylib_artifact.step.dependOn(&step.step);
    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = options.optimize });
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
    // Run the *installed* executable, not the cache artifact: the installed
    // binary records only `$ORIGIN/../lib` (Linux) or `@loader_path/../lib`
    // (macOS), so it must execute next to its installed raylib.
    const run = b.addRunFile(b.graph.path(.install_prefix, "desktop/bin/haystack_game"));
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the installed desktop application").dependOn(&run.step);

    const test_step = b.step("test", "Run desktop application tests");
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

fn reportUnsupportedTarget(err: platform.ResolveError, host: std.Target, requested: std.Target) void {
    switch (err) {
        error.WasmTarget => std.log.err(
            "Wasm target {s}-{s} cannot use the desktop graph; browser builds require explicit -Dplatform=wasm",
            .{ @tagName(requested.cpu.arch), @tagName(requested.os.tag) },
        ),
        error.ForeignOperatingSystem,
        error.ForeignArchitecture,
        error.ForeignAbi,
        => std.log.err(
            "desktop requires the native target; got {s}-{s}-{s} on a {s}-{s}-{s} host. Cross-compilation is unsupported; use -Dplatform=wasm for browser builds",
            .{
                @tagName(requested.cpu.arch), @tagName(requested.os.tag), @tagName(requested.abi),
                @tagName(host.cpu.arch),      @tagName(host.os.tag),      @tagName(host.abi),
            },
        ),
        error.UnsupportedHost => std.log.err(
            "desktop supports native Linux x86_64/aarch64 or Apple Silicon macOS only; detected host {s}-{s}-{s}",
            .{ @tagName(host.cpu.arch), @tagName(host.os.tag), @tagName(host.abi) },
        ),
        error.UnsupportedHostArchitecture => std.log.err(
            "desktop host architecture {s} on {s} is unsupported; use Linux x86_64/aarch64 or Apple Silicon macOS",
            .{ @tagName(host.cpu.arch), @tagName(host.os.tag) },
        ),
        error.UnsupportedHostAbi => std.log.err(
            "desktop host ABI {s} on {s} is unsupported; Linux requires glibc (gnu) or musl and macOS uses its native ABI",
            .{ @tagName(host.abi), @tagName(host.os.tag) },
        ),
        error.UnsupportedLinuxArchitecture => std.log.err(
            "desktop supports native Linux x86_64/aarch64 only; got {s}",
            .{@tagName(requested.cpu.arch)},
        ),
        error.UnsupportedLinuxAbi => std.log.err(
            "desktop Linux requires an exact glibc (gnu) or musl ABI; got {s}",
            .{@tagName(requested.abi)},
        ),
        error.UnsupportedMacosArchitecture => std.log.err(
            "desktop macOS support is native Apple Silicon (aarch64) only; Intel and universal builds are not supported",
            .{},
        ),
        error.UnsupportedMacosAbi => std.log.err(
            "desktop macOS requires the native Darwin ABI; got {s}",
            .{@tagName(requested.abi)},
        ),
        error.UnsupportedDeploymentTarget => std.log.err(
            "macOS deployment target must be {s} or newer; this build pins {s} for Zig, raylib and Rust",
            .{ platform.macos_deployment_target, platform.macos_deployment_target },
        ),
    }
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

fn linkWallet(module: *std.Build.Module, cdk: *std.Build.Module, archive: std.Build.LazyPath, policy: platform.Policy) void {
    module.addImport("cdk", cdk);
    module.addObjectFile(archive);
    module.link_libc = true;
    // The C ABI contains panics with unwind; Zig must resolve Rust's unwind
    // symbols. These are native platform libraries, never browser link inputs.
    for (policy.native_libraries) |name| {
        module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    }
    // The vendored Rust crate's macOS entropy path references the Security
    // framework. A static archive carries no link flags, so the final Zig
    // link must name the framework explicitly.
    if (policy.os == .macos) {
        const b = module.owner;
        const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &b.graph.host.result) orelse
            @panic("macOS SDK not found for framework linking");
        const frameworks = b.fmt("{s}/System/Library/Frameworks", .{sdk});
        module.addFrameworkPath(b.graph.cwdRelativePath(frameworks));
        module.linkFramework("Security", .{});
        module.linkFramework("CoreFoundation", .{});
        module.linkFramework("Foundation", .{});
    }
}

fn abiTests(b: *std.Build, options: common.Options, source: []const u8, cdk: *std.Build.Module, archive: std.Build.LazyPath, rust: *std.Build.Step, policy: platform.Policy) *std.Build.Step.Run {
    const module = b.createModule(.{ .root_source_file = b.path(source), .target = options.target, .optimize = options.optimize });
    linkWallet(module, cdk, archive, policy);
    const tests = b.addTest(.{ .root_module = module });
    tests.step.dependOn(rust);
    return b.addRunArtifact(tests);
}
