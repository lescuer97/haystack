const std = @import("std");
const platform = @import("platform.zig");

pub const macos_deployment_target = platform.macos_deployment_target;
pub const macos_deployment_version = platform.macos_deployment_version;

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    toolchain: []const u8,
    offline: bool,

    pub fn release(self: Options) bool {
        return self.optimize != .debug;
    }
    pub fn profile(self: Options) []const u8 {
        return if (self.release()) "release" else "debug";
    }
};

pub fn bootstrap(b: *std.Build, options: Options, rust_target: []const u8, host: ?std.Target, require_native_c: bool) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "python3", "build-support/bootstrap.py", "rust", "--toolchain", options.toolchain, "--target", rust_target });
    run.setName(b.fmt("ensure Rust {s} and target {s}", .{ options.toolchain, rust_target }));
    run.setCwd(b.path("."));
    if (host) |target| {
        run.addArgs(&.{ "--host-os", @tagName(target.os.tag), "--host-arch", @tagName(target.cpu.arch) });
    }
    if (require_native_c) run.addArg("--require-native-c");
    if (options.offline) run.addArg("--offline");
    run.has_side_effects = true;
    return run;
}

/// Cargo owns Rust dependency/incremental caching. Running it each build avoids
/// a stale archive when shared Rust sources change outside a crate directory.
pub fn cargo(b: *std.Build, options: Options, manifest: []const u8, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "cargo", b.fmt("+{s}", .{options.toolchain}) });
    run.addArgs(args);
    run.addArgs(&.{ "--locked", "--manifest-path", manifest });
    if (options.offline) run.addArg("--offline");
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    return run;
}

pub fn optimizeRust(run: *std.Build.Step.Run, options: Options) void {
    if (!options.release()) return;
    run.addArg("--release");
    run.setEnvironmentVariable("CARGO_PROFILE_RELEASE_OPT_LEVEL", switch (options.optimize) {
        .small => "s",
        .fast => "3",
        .safe => "2",
        .debug => unreachable,
    });
    run.setEnvironmentVariable("CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS", if (options.optimize == .safe) "true" else "false");
}

/// Keep Cargo's dev and release profiles panic-unwind. The C ABI relies on
/// `catch_unwind`, and native Rust tests must exercise the same profile the
/// staticlib is built with; a release test run must not silently become aborting
/// (the crate has a `panic = "abort"` compile error for that reason).
pub fn unwindPanic(run: *std.Build.Step.Run) void {
    run.setEnvironmentVariable("CARGO_PROFILE_RELEASE_PANIC", "unwind");
    run.setEnvironmentVariable("CARGO_PROFILE_DEV_PANIC", "unwind");
}

/// Resolve the effective native desktop target.
///
/// The policy pins the documented macOS deployment target even when the host
/// SDK/OS is newer. Linux (and configuration-time rejections of other targets)
/// are left untouched.
pub fn desktopTarget(b: *std.Build, requested: std.Build.ResolvedTarget, policy: platform.Policy) std.Build.ResolvedTarget {
    const deployment = policy.macos_deployment orelse return requested;
    var query = requested.query;
    query.os_version_min = .{ .semver = deployment };
    return b.resolveTargetQuery(query);
}

/// Apply the fixed macOS deployment target to Cargo/Rust build scripts and the
/// C compiler they invoke. No-op on Linux. The SDK itself is left to rustc's
/// xcrun discovery (`xcrun --sdk macosx --show-sdk-path`), which the macOS
/// preflight validates; no global SDKROOT is required.
pub fn applyDeploymentTarget(run: *std.Build.Step.Run, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .macos) {
        run.setEnvironmentVariable("MACOSX_DEPLOYMENT_TARGET", macos_deployment_target);
    }
}

/// Test-fixture helper: the native Rust triple for a host-only build.
///
/// The desktop graph calls `platform.resolve` once and uses that policy for the
/// Rust target, Zig target, native libraries and rpath. This helper exists only
/// for the Linux-only native browser-database/fake-mint test fixtures; it never
/// affects a normal desktop or browser build.
pub fn hostRustTarget(b: *std.Build) ![]const u8 {
    const host = b.graph.host.result;
    const policy = platform.resolve(host, host) catch return error.UnsupportedNativeHost;
    return policy.rust_target;
}
