const std = @import("std");
const rlz = @import("raylib_zig");
const common = @import("common.zig");

pub fn build(b: *std.Build, options: common.Options) !void {
    if (options.target.result.cpu.arch != .wasm32 or options.target.result.os.tag != .emscripten) {
        std.log.err("browser builds require wasm32-emscripten; omit -Dtarget when using -Dplatform=wasm", .{});
        return error.UnsupportedBrowserTarget;
    }
    const rust = common.bootstrap(b, options, "wasm32-unknown-unknown", b.graph.host.result, false);
    const override = b.option([]const u8, "wasm-bindgen", "Optional override for the automatically managed wasm-bindgen 0.2.130");
    const tools_root = b.graph.path(.local_cache, "tools/wasm-bindgen-0.2.130");
    const tools = b.addSystemCommand(&.{ "python3", "build-support/bootstrap.py", "bindgen", "--toolchain", options.toolchain, "--root" });
    tools.addDirectoryArg(tools_root);
    tools.setName("ensure local wasm-bindgen 0.2.130");
    if (override) |path| tools.addArgs(&.{ "--override", path });
    if (options.offline) tools.addArg("--offline");
    tools.has_side_effects = true;
    tools.step.dependOn(&rust.step);

    const wallet = common.cargo(b, options, "browser/wallet/Cargo.toml", &.{ "build", "--lib", "--target", "wasm32-unknown-unknown", "--target-dir", "browser/wallet/target" });
    common.optimizeRust(wallet, options);
    wallet.setName("compile browser wallet and Spilman to Wasm");
    wallet.step.dependOn(&rust.step);
    const glue = if (override) |path|
        b.addSystemCommand(&.{path})
    else
        b.addRunFile(tools_root.path(b, if (b.graph.host.result.os.tag == .windows) "bin/wasm-bindgen.exe" else "bin/wasm-bindgen"));
    glue.setName("generate browser wallet JS bindings");
    glue.addArgs(&.{ "--target", "web", "--out-dir" });
    const generated_wallet = glue.addOutputDirectoryArg("wallet");
    glue.addFileArg(b.path(b.fmt("browser/wallet/target/wasm32-unknown-unknown/{s}/cdk_wallet_browser.wasm", .{options.profile()})));
    glue.step.dependOn(&tools.step);
    glue.step.dependOn(&wallet.step);
    const install_wallet = b.addInstallDirectory(.{ .source_dir = generated_wallet, .install_dir = .{ .custom = "wasm/wallet" }, .install_subdir = "" });
    b.getInstallStep().dependOn(&install_wallet.step);
    b.step("wallet", "Build and install the browser wallet module only").dependOn(&install_wallet.step);

    const raylib = b.dependency("raylib_zig", .{ .target = options.target, .optimize = options.optimize, .linkage = .static });
    const artifact = raylib.artifact("raylib");
    // Replace upstream's unconditional SDK update with a pinned, offline-aware
    // install-once check. The native graph never constructs this dependency.
    var i: usize = 0;
    while (i < artifact.step.dependencies.items.len) {
        if (std.mem.eql(u8, artifact.step.dependencies.items[i].name, "Activate EMSDK")) {
            _ = artifact.step.dependencies.orderedRemove(i);
        } else i += 1;
    }
    const sdk = b.addSystemCommand(&.{ "python3", "build-support/ensure-emsdk.py" });
    sdk.addDirectoryArg(try rlz.emsdk.path(b, ""));
    if (options.offline) sdk.addArg("--offline");
    sdk.setName("ensure Emscripten 4.0.19");
    artifact.step.dependOn(&sdk.step);
    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = options.target, .optimize = options.optimize, .link_libc = true });
    root.addImport("raylib", raylib.module("raylib"));
    root.linkLibrary(artifact);
    const renderer = b.addLibrary(.{ .name = "haystack_renderer", .linkage = .static, .root_module = root });
    var flags = rlz.emsdk.emccDefaultFlags(b.allocator, .{ .optimize = options.optimize, .asyncify = false, .fsanitize = false });
    if (options.optimize.runtimeSafety()) try flags.put("-fsanitize=undefined", {});
    const linked = try rlz.emsdk.emccStep(b, &.{}, &.{renderer}, .{
        .optimize = options.optimize,
        .flags = flags,
        .settings = rlz.emsdk.emccDefaultSettings(b.allocator, .{ .optimize = options.optimize }),
        .install_dir = .{ .custom = "wasm/renderer" },
        .out_file_name = "index.html",
    });
    b.getInstallStep().dependOn(linked);
    b.step("renderer", "Build the browser renderer without the wallet").dependOn(linked);
    for ([_][]const u8{ "index.html", "app.js", "smoke.js", "spilman-negative.js", "live-channels.js", "test-faults.js", "fault-scenarios.js", "recovery.js" }) |file| {
        b.getInstallStep().dependOn(&b.addInstallFile(b.path(b.fmt("browser/{s}", .{file})), b.fmt("wasm/{s}", .{file})).step);
    }
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("src/testdata/spilman_vectors.json"), "wasm/spilman_vectors.json").step);
    b.step("wasm", "Build and install the complete Wasm application").dependOn(b.getInstallStep());
    b.step("browser", "Alias for the complete Wasm application in this platform graph").dependOn(b.getInstallStep());
    const setup = b.step("setup", "Provision pinned Rust, Wasm target, local wasm-bindgen and Emscripten");
    setup.dependOn(&tools.step);
    setup.dependOn(&sdk.step);
    const port = b.option(u16, "port", "Local browser development-server port") orelse 8000;
    const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", b.fmt("{d}", .{port}), "--bind", "127.0.0.1", "--directory" });
    serve.addDirectoryArg(b.graph.path(.install_prefix, "wasm"));
    serve.step.dependOn(b.getInstallStep());
    b.step("run", "Build and serve the complete browser application (no fake mint)").dependOn(&serve.step);

    // Native helper compilation is EXPLICITLY test-only. A normal Wasm build
    // never builds this crate or links the desktop archive/system libraries.
    if (b.graph.host.result.os.tag == .linux) {
        const host = try common.hostRustTarget(b);
        const database = common.cargo(b, options, "browser/wallet/Cargo.toml", &.{ "test", "--target", host, "--target-dir", "browser/wallet/target" });
        database.step.dependOn(&rust.step);
        b.step("test-wallet", "Run browser database conformance tests on the host").dependOn(&database.step);
        const mint = common.cargo(b, options, "vendor/cdk-wallet-ffi/Cargo.toml", &.{ "build", "--example", "browser-test-mint", "--target", host, "--target-dir", "browser/wallet/target/test-mint" });
        mint.step.dependOn(&rust.step);
        const mint_exe = b.path(b.fmt("browser/wallet/target/test-mint/{s}/debug/examples/browser-test-mint", .{host}));
        const browser_tests = b.addSystemCommand(&.{ "python3", "build-support/test-browser.py", "--mint" });
        browser_tests.addFileArg(mint_exe);
        browser_tests.addArg("--directory");
        browser_tests.addDirectoryArg(b.graph.path(.install_prefix, "wasm"));
        browser_tests.addArg("--runner");
        browser_tests.addFileArg(b.path("browser/test.mjs"));
        browser_tests.step.dependOn(&mint.step);
        browser_tests.step.dependOn(b.getInstallStep());
        const test_step = b.step("test", "Build, start an ephemeral fake mint, run Chromium and stop the mint");
        test_step.dependOn(&browser_tests.step);
        test_step.dependOn(&database.step);
        const run_mint = b.addRunFile(mint_exe);
        run_mint.addDirectoryArg(b.graph.path(.install_prefix, "wasm"));
        run_mint.step.dependOn(&mint.step);
        run_mint.step.dependOn(b.getInstallStep());
        b.step("test-mint", "Build and serve the application with a localhost-only fake mint").dependOn(&run_mint.step);
    }
}
