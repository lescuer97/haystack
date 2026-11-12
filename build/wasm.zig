const std = @import("std");
const rlz = @import("raylib_zig");
const common = @import("common.zig");
const emsdk_compat = @import("emsdk_compat.zig");

const wasm_setup_base = "zig build setup -Dplatform=wasm";

pub fn build(b: *std.Build, options: common.Options) !void {
    if (options.target.result.cpu.arch != .wasm32 or options.target.result.os.tag != .emscripten) {
        std.log.err("browser builds require wasm32-emscripten; omit -Dtarget when using -Dplatform=wasm", .{});
        return error.UnsupportedBrowserTarget;
    }
    const setup_command = common.setupCommand(b, wasm_setup_base, options.toolchain);
    const rust_check = common.rustTools(b, options, "wasm32-unknown-unknown", b.graph.host.result, false, .check, setup_command);
    const rust_setup = common.rustTools(b, options, "wasm32-unknown-unknown", b.graph.host.result, false, .provision, setup_command);
    const override = b.option([]const u8, "wasm-bindgen", "Optional override for the managed wasm-bindgen 0.2.130");
    // This path mirrors BINDGEN_VERSION in build-support/bootstrap.py; the
    // check/provision step validates the actual binary there.
    const tools_root = b.graph.path(.local_cache, "tools/wasm-bindgen-0.2.130");
    const bindgen_check = bindgenTools(b, options, tools_root, override, .check, setup_command);
    bindgen_check.step.dependOn(&rust_check.step);
    const bindgen_setup = bindgenTools(b, options, tools_root, override, .provision, setup_command);
    bindgen_setup.step.dependOn(&rust_setup.step);

    const wallet = common.cargo(b, options, "browser/wallet/Cargo.toml", &.{ "build", "--lib", "--target", "wasm32-unknown-unknown", "--target-dir", "browser/wallet/target" });
    // Apple's ar drops Wasm objects from the C archives used by ring and secp256k1-sys.
    const archiver = b.fmt("{s} ar", .{b.graph.zig_exe});
    wallet.setEnvironmentVariable("AR_wasm32_unknown_unknown", archiver);
    // ring tracks target CFLAGS but not AR, so changing archivers otherwise leaves
    // its old (possibly empty) archive cached across Cargo optimization profiles.
    const archiver_id = std.hash.Wyhash.hash(0, b.fmt("{s}:{s}", .{ archiver, @import("builtin").zig_version_string }));
    const cflags_key = "CFLAGS_wasm32_unknown_unknown";
    const previous_cflags = wallet.getEnvMap().get(cflags_key) orelse "";
    wallet.setEnvironmentVariable(cflags_key, b.fmt("{s} -DHAYSTACK_WASM_ARCHIVER_ID=0x{x}", .{ previous_cflags, archiver_id }));
    common.optimizeRust(wallet, options);
    wallet.setName("compile browser wallet and Spilman to Wasm");
    wallet.step.dependOn(&rust_check.step);
    const glue = if (override) |path|
        b.addSystemCommand(&.{path})
    else
        b.addRunFile(tools_root.path(b, if (b.graph.host.result.os.tag == .windows) "bin/wasm-bindgen.exe" else "bin/wasm-bindgen"));
    glue.setName("generate browser wallet JS bindings");
    glue.addArgs(&.{ "--target", "web", "--out-dir" });
    const generated_wallet = glue.addOutputDirectoryArg("wallet");
    glue.addFileArg(b.path(b.fmt("browser/wallet/target/wasm32-unknown-unknown/{s}/cdk_wallet_browser.wasm", .{options.profile()})));
    glue.step.dependOn(&bindgen_check.step);
    glue.step.dependOn(&wallet.step);
    const install_wallet = b.addInstallDirectory(.{ .source_dir = generated_wallet, .install_dir = .{ .custom = "wasm/wallet" }, .install_subdir = "" });
    b.getInstallStep().dependOn(&install_wallet.step);
    b.step("wallet", "Build and install the browser wallet module only").dependOn(&install_wallet.step);

    const raylib = b.dependency("raylib_zig", .{ .target = options.target, .optimize = options.optimize, .linkage = .static });
    const artifact = raylib.artifact("raylib");
    // Replace upstream's unconditional SDK update with pinned check/provision
    // steps. Detachment is isolated and verified by emsdk_compat.zig so a
    // changed upstream graph fails configuration instead of running an
    // installer during a normal build. The native graph never constructs this
    // dependency.
    try emsdk_compat.detachActivationStep(&artifact.step);
    const sdk_check = emsdkTools(b, try rlz.emsdk.path(b, ""), .check, options.offline, setup_command);
    const sdk_setup = emsdkTools(b, try rlz.emsdk.path(b, ""), .provision, options.offline, setup_command);
    artifact.step.dependOn(&sdk_check.step);
    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = options.target, .optimize = options.optimize, .link_libc = true });
    root.addImport("raylib", raylib.module("raylib"));
    root.linkLibrary(artifact);
    const renderer = b.addLibrary(.{ .name = "haystack_renderer", .linkage = .static, .root_module = root });
    var flags = rlz.emsdk.emccDefaultFlags(b.allocator, .{ .optimize = options.optimize, .asyncify = false, .fsanitize = false });
    if (options.optimize.runtimeSafety()) try flags.put("-fsanitize=undefined", {});
    var settings = rlz.emsdk.emccDefaultSettings(b.allocator, .{ .optimize = options.optimize });
    try settings.put("EXIT_RUNTIME", "0");
    const linked = try rlz.emsdk.emccStep(b, &.{}, &.{renderer}, .{
        .optimize = options.optimize,
        .flags = flags,
        .settings = settings,
        .shell_file_path = b.path("browser/game-shell.html"),
        .install_dir = .{ .custom = "wasm/renderer" },
        .out_file_name = "index.html",
        .js_library_path = b.path("browser/game-wallet.js"),
    });
    b.getInstallStep().dependOn(linked);
    b.step("renderer", "Build the browser renderer without the wallet").dependOn(linked);
    // The normal installed application is runtime-only: the root redirect, the
    // renderer (shell, JS and Wasm installed by `linked`) and the wallet module.
    // Wallet regression JS, the test fixture and deterministic vectors are
    // installed only by the test/test-mint targets through `test-assets`.
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("browser/index.html"), "wasm/index.html").step);
    b.step("wasm", "Build and install the complete Wasm application").dependOn(b.getInstallStep());
    b.step("browser", "Alias for the complete Wasm application in this platform graph").dependOn(b.getInstallStep());
    const setup = b.step("setup", "Provision pinned Rust, Wasm target, local wasm-bindgen and Emscripten (no application build)");
    setup.dependOn(&bindgen_setup.step);
    setup.dependOn(&sdk_setup.step);
    const port = b.option(u16, "port", "Local browser development-server port") orelse 8000;
    const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", b.fmt("{d}", .{port}), "--bind", "127.0.0.1", "--directory" });
    serve.addDirectoryArg(b.graph.path(.install_prefix, "wasm"));
    serve.step.dependOn(b.getInstallStep());
    b.step("run", "Build and serve the complete browser application (no fake mint)").dependOn(&serve.step);

    // Native helper compilation is EXPLICITLY test-only. A normal Wasm build
    // never builds this crate or links the desktop archive/system libraries.
    if (b.graph.host.result.os.tag == .linux) {
        // Shared by `test` and `test-mint`. These files are regression-test
        // inputs only, so a normal browser build never installs them.
        const test_assets = b.step("test-assets", "Install browser regression test fixtures (test/test-mint only)");
        for ([_][]const u8{ "app.js", "smoke.js", "spilman-negative.js", "live-channels.js", "test-faults.js", "fault-scenarios.js", "recovery.js", "wallet-test.html" }) |file| {
            test_assets.dependOn(&b.addInstallFile(b.path(b.fmt("browser/{s}", .{file})), b.fmt("wasm/{s}", .{file})).step);
        }
        test_assets.dependOn(&b.addInstallFile(b.path("src/testdata/spilman_vectors.json"), "wasm/spilman_vectors.json").step);
        const host = try common.hostRustTarget(b);
        const database = common.cargo(b, options, "browser/wallet/Cargo.toml", &.{ "test", "--target", host, "--target-dir", "browser/wallet/target" });
        database.step.dependOn(&rust_check.step);
        b.step("test-wallet", "Run browser database conformance tests on the host").dependOn(&database.step);
        const mint = common.cargo(b, options, "vendor/cdk-wallet-ffi/Cargo.toml", &.{ "build", "--example", "browser-test-mint", "--target", host, "--target-dir", "browser/wallet/target/test-mint" });
        mint.step.dependOn(&rust_check.step);
        const mint_exe = b.path(b.fmt("browser/wallet/target/test-mint/{s}/debug/examples/browser-test-mint", .{host}));
        const browser_tests = b.addSystemCommand(&.{ "python3", "build-support/test-browser.py", "--mint" });
        browser_tests.addFileArg(mint_exe);
        browser_tests.addArg("--directory");
        browser_tests.addDirectoryArg(b.graph.path(.install_prefix, "wasm"));
        browser_tests.addArg("--runner");
        browser_tests.addFileArg(b.path("browser/test.mjs"));
        // The non-interactive wallet host is a test fixture only. It is not part
        // of the normal installed application, whose default is the game.
        browser_tests.step.dependOn(test_assets);
        browser_tests.step.dependOn(&mint.step);
        browser_tests.step.dependOn(b.getInstallStep());
        const test_step = b.step("test", "Build, start an ephemeral fake mint, run Chromium and stop the mint");
        test_step.dependOn(&browser_tests.step);
        test_step.dependOn(&database.step);
        const run_mint = b.addRunFile(mint_exe);
        run_mint.addDirectoryArg(b.graph.path(.install_prefix, "wasm"));
        run_mint.step.dependOn(test_assets);
        run_mint.step.dependOn(&mint.step);
        run_mint.step.dependOn(b.getInstallStep());
        b.step("test-mint", "Build and serve the application with a localhost-only fake mint").dependOn(&run_mint.step);
    }
}

fn bindgenTools(
    b: *std.Build,
    options: common.Options,
    root: std.Build.LazyPath,
    override: ?[]const u8,
    mode: common.ToolMode,
    setup_command: []const u8,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "python3", "build-support/bootstrap.py", "bindgen", "--toolchain", options.toolchain, "--root" });
    run.addDirectoryArg(root);
    run.addArg(switch (mode) {
        .check => "--check",
        .provision => "--provision",
    });
    run.setName(switch (mode) {
        .check => "check local wasm-bindgen 0.2.130",
        .provision => "provision local wasm-bindgen 0.2.130",
    });
    if (override) |path| run.addArgs(&.{ "--override", path });
    if (options.offline) run.addArg("--offline");
    run.addArgs(&.{ "--setup-command", setup_command });
    run.has_side_effects = true;
    return run;
}

fn emsdkTools(
    b: *std.Build,
    root: std.Build.LazyPath,
    mode: common.ToolMode,
    offline: bool,
    setup_command: []const u8,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "python3", "build-support/ensure-emsdk.py" });
    run.addDirectoryArg(root);
    run.addArg(switch (mode) {
        .check => "--check",
        .provision => "--provision",
    });
    run.setName(switch (mode) {
        .check => "check Emscripten 4.0.19",
        .provision => "provision Emscripten 4.0.19",
    });
    if (offline) run.addArg("--offline");
    run.addArgs(&.{ "--setup-command", setup_command });
    run.has_side_effects = true;
    return run;
}
