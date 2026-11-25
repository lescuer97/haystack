const std = @import("std");
const common = @import("build/common.zig");

const Platform = enum { desktop, wasm };

pub fn build(b: *std.Build) !void {
    const requested = b.option(Platform, "platform", "Build desktop (default) or the complete browser Wasm application");
    const standalone = b.option(bool, "standalone", "Install the native desktop client as one executable with embedded assets") orelse false;
    const standalone_smoke = b.option(bool, "standalone-smoke", "Enable the offline runtime smoke fixture in a standalone test build") orelse false;
    const target = b.standardTargetOptions(.{
        .default_target = if (requested == .wasm)
            .{ .cpu_arch = .wasm32, .os_tag = .emscripten }
        else if (standalone)
            .{ .cpu_model = .baseline }
        else
            .{},
    });
    // Wasm is selected only by the explicit platform flag. A Wasm -Dtarget
    // alone must never infer the browser graph.
    const platform = requested orelse .desktop;
    if (requested == null and target.result.cpu.arch.isWasm()) {
        std.log.err(
            "browser builds require explicit -Dplatform=wasm; -Dtarget alone does not select the Wasm graph. Run `zig build -Dplatform=wasm -Dtarget=wasm32-emscripten`.",
            .{},
        );
        return error.WasmRequiresPlatform;
    }
    const game = b.option(bool, "game", "Configure the game (default true; native server wallet is always configured)") orelse true;
    if (standalone and (platform != .desktop or !game)) {
        std.log.err("-Dstandalone requires the native desktop game; omit it for Wasm or -Dgame=false", .{});
        return error.StandaloneRequiresDesktopGame;
    }
    if (standalone_smoke and !standalone) {
        std.log.err("-Dstandalone-smoke requires -Dstandalone", .{});
        return error.SmokeRequiresStandalone;
    }
    const optimize: std.builtin.Optimize = b.option(std.builtin.Optimize, "optimize", "Debug, ReleaseSafe, ReleaseFast or ReleaseSmall (Wasm defaults to ReleaseSmall)") orelse switch (b.graph.release_mode) {
        .off => if (platform == .wasm) .small else if (standalone) .safe else .debug,
        .any => if (platform == .wasm) .small else .safe,
        .small => .small,
        .safe => .safe,
        .fast => .fast,
    };
    const toolchain = b.option([]const u8, "rust-toolchain", b.fmt("Rustup toolchain (default: pinned {s})", .{common.default_toolchain})) orelse common.default_toolchain;
    const offline = b.option(bool, "offline", "Forbid tool downloads and Cargo network access") orelse false;
    if (platform == .wasm and !game) {
        std.log.err("-Dplatform=wasm requires -Dgame=true; server-only builds use the native desktop configuration", .{});
        return error.ServerOnlyRequiresNativePlatform;
    }
    if (platform == .desktop and target.result.cpu.arch.isWasm()) {
        std.log.err("native desktop/server builds cannot target Wasm; browser builds require -Dplatform=wasm and -Dgame=true", .{});
        return error.UnsupportedDesktopTarget;
    }
    const options: common.Options = .{
        .target = target,
        .optimize = optimize,
        .toolchain = toolchain,
        .offline = offline,
    };
    const native = if (platform == .desktop) try @import("build/native_wallet.zig").create(b, options) else null;
    // Standalone is a client-only profile; the independent server retains its
    // ordinary native CPU and optimization defaults in a separate invocation.
    if (!standalone) {
        if (native) |graph| try @import("build/server.zig").build(b, graph);
    }
    if (!game) return;
    const build_tests = b.addSystemCommand(&.{ "python3", "-m", "unittest", "discover", "-s", "build-support", "-p", "test_*.py" });
    build_tests.setCwd(b.path("."));
    const platform_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/platform.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    build_tests.step.dependOn(&b.addRunArtifact(platform_tests).step);
    const emsdk_compat_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/emsdk_compat.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    build_tests.step.dependOn(&b.addRunArtifact(emsdk_compat_tests).step);
    b.step("test-build", "Test platform graph isolation, explicit setup/check contracts, the upstream Emscripten adapter and the native target matrix").dependOn(&build_tests.step);
    const qr_portability = b.step("test-qr-portability", "Cross-compile the shared C QR encoder for supported native architectures (no SDK install or runtime claim)");
    for ([_][]const u8{ "x86_64-linux-gnu", "aarch64-linux-gnu", "aarch64-macos.15.0" }) |triple| {
        const compile = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-target", triple, "-std=c99", "-Wall", "-Wextra", "-Werror", "-c" });
        compile.addFileArg(b.path("vendor/qrcodegen/qrcodegen.c"));
        compile.addFileInput(b.path("vendor/qrcodegen/qrcodegen.h"));
        compile.addArg("-o");
        _ = compile.addOutputFileArg(b.fmt("qr-{s}.o", .{triple}));
        qr_portability.dependOn(&compile.step);
    }

    // Explicit only: unittest discovery in the filtered package must not
    // recursively launch another package build.
    const package_check = b.addSystemCommand(&.{ "python3", "build-support/check_package.py", "--zig", b.graph.zig_exe, "--rust-toolchain", options.toolchain, "--global-cache" });
    package_check.addDirectoryArg(b.graph.path(.global_cache, ""));
    package_check.addArg("--local-cache");
    package_check.addDirectoryArg(b.graph.path(.local_cache, ""));
    package_check.setCwd(b.path("."));
    package_check.has_side_effects = true;
    b.step("test-package", "Check Zig-filtered source package and build server/browser offline (warmed caches required)").dependOn(&package_check.step);

    // Deliberately configure ONE graph. Desktop never initializes browser
    // toolchains; Wasm never translates/links the native C ABI or desktop raylib.
    switch (platform) {
        .desktop => try @import("build/desktop.zig").build(b, native.?, standalone, standalone_smoke),
        .wasm => try @import("build/wasm.zig").build(b, options),
    }
}
