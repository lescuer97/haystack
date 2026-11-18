//! One UI-free native CDK graph, shared by desktop and server.
const std = @import("std");
const common = @import("common.zig");
const platform = @import("platform.zig");

pub const Graph = struct {
    options: common.Options,
    policy: platform.Policy,
    preflight: ?*std.Build.Step.Run,
    check: *std.Build.Step.Run,
    rust: *std.Build.Step.Run,
    archive: std.Build.LazyPath,
    cdk: *std.Build.Module,

    pub fn link(self: Graph, module: *std.Build.Module) void {
        linkWallet(module, self.cdk, self.archive, self.policy);
    }
};

pub fn create(b: *std.Build, options_in: common.Options) !Graph {
    const host = b.graph.host.result;
    const policy = platform.resolve(host, options_in.target.result) catch |err| {
        reportUnsupportedTarget(err, host, options_in.target.result);
        return error.UnsupportedDesktopTarget;
    };
    var options = options_in;
    options.target = common.desktopTarget(b, options.target, policy);
    const preflight: ?*std.Build.Step.Run = if (policy.os == .macos) blk: {
        const run = b.addSystemCommand(&.{ "python3", "build-support/macos-preflight.py", "--deployment-target", common.macos_deployment_target, "--rust-target", policy.rust_target });
        run.setName("check native macOS ARM64 toolchain, SDK and deployment target");
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        break :blk run;
    } else null;
    const setup_command = common.setupCommand(b, "zig build setup", options.toolchain);
    const setup = common.rustTools(b, options, policy.rust_target, host, true, .provision, setup_command);
    if (preflight) |step| setup.step.dependOn(&step.step);
    b.step("setup", "Provision the pinned desktop Rust toolchain and validate native prerequisites (no application build)").dependOn(&setup.step);
    const check = common.rustTools(b, options, policy.rust_target, host, true, .check, setup_command);
    if (preflight) |step| check.step.dependOn(&step.step);
    const rust = common.cargo(b, options, "vendor/cdk-wallet-ffi/Cargo.toml", &.{ "build", "--lib", "--target", policy.rust_target, "--target-dir", "vendor/cdk-wallet-ffi/target" });
    common.optimizeRust(rust, options);
    common.applyDeploymentTarget(rust, options.target);
    common.unwindPanic(rust);
    rust.setName("build native wallet C ABI");
    rust.step.dependOn(&check.step);
    const archive = b.path(b.fmt("vendor/cdk-wallet-ffi/target/{s}/{s}/libcdk_wallet_ffi.a", .{ policy.rust_target, options.profile() }));
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/cdk-wallet-ffi/include/cdk_wallet.h"),
        .target = options.target,
        .optimize = options.optimize,
    });
    translate.addIncludePath(b.path("vendor/cdk-wallet-ffi/include"));
    if (preflight) |step| translate.step.dependOn(&step.step);
    const cdk = b.addModule("cdk", .{ .root_source_file = b.path("src/cdk.zig"), .target = options.target });
    const app_options = b.addOptions();
    const fixture = b.option([]const u8, "app-fixture-mint", "Explicit local fake mint URL for isolated application tests");
    if (fixture) |url| {
        if (!std.mem.startsWith(u8, url, "http://127.0.0.1:")) return error.InvalidFixtureMint;
        const port_text = if (std.mem.endsWith(u8, url, "/")) url[17 .. url.len - 1] else url[17..];
        const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidFixtureMint;
        if (port == 0 or !std.mem.eql(u8, port_text, b.fmt("{d}", .{port}))) return error.InvalidFixtureMint;
    }
    app_options.addOption([]const u8, "mint", fixture orelse "https://testnut.cashu.space/");
    cdk.addOptions("app_options", app_options);
    cdk.addImport("cdk_c", translate.addModule("cdk_c"));
    return .{ .options = options, .policy = policy, .preflight = preflight, .check = check, .rust = rust, .archive = archive, .cdk = cdk };
}

pub fn linkWallet(module: *std.Build.Module, cdk: *std.Build.Module, archive: std.Build.LazyPath, policy: platform.Policy) void {
    module.addImport("cdk", cdk);
    module.addObjectFile(archive);
    module.link_libc = true;
    for (policy.native_libraries) |name| module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    if (policy.os == .macos) {
        const b = module.owner;
        const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &b.graph.host.result) orelse
            @panic("macOS SDK not found for framework linking");
        module.addFrameworkPath(b.graph.cwdRelativePath(b.fmt("{s}/System/Library/Frameworks", .{sdk})));
        module.linkFramework("Security", .{});
        module.linkFramework("CoreFoundation", .{});
        module.linkFramework("Foundation", .{});
    }
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
