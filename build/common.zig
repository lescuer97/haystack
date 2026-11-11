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

/// Single source of truth for the pinned default Rust toolchain.
pub const default_toolchain = "1.99.0";

/// Build the exact setup command printed for missing-tool guidance.
///
/// The default hint stays unchanged. A selected non-default
/// `-Drust-toolchain=...` is appended so following the advice provisions the
/// toolchain the build actually checks; the platform flag supplied by `base` is
/// preserved.
pub fn setupCommand(b: *std.Build, base: []const u8, toolchain: []const u8) []const u8 {
    if (std.mem.eql(u8, toolchain, default_toolchain)) return base;
    return b.fmt("{s} -Drust-toolchain={s}", .{ base, toolchain });
}

/// Ordinary builds only CHECK the selected toolchain. The explicit `setup`
/// step is the sole path that may install missing Rust components.
pub const ToolMode = enum { check, provision };

/// Build and describe the Rust toolchain step for the selected platform graph.
///
/// `setup_command` is the exact command printed when a normal build finds a
/// missing or incompatible tool. The setup command itself is supplied by the
/// graph because its platform flag differs between desktop and Wasm.
pub fn rustTools(
    b: *std.Build,
    options: Options,
    rust_target: []const u8,
    host: ?std.Target,
    require_native_c: bool,
    mode: ToolMode,
    setup_command: []const u8,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "python3", "build-support/bootstrap.py", "rust", "--toolchain", options.toolchain, "--target", rust_target, "--setup-command", setup_command });
    run.setName(switch (mode) {
        .check => b.fmt("check installed Rust {s} and target {s}", .{ options.toolchain, rust_target }),
        .provision => b.fmt("provision Rust {s} and target {s}", .{ options.toolchain, rust_target }),
    });
    run.addArg(switch (mode) {
        .check => "--check",
        .provision => "--provision",
    });
    run.setCwd(b.path("."));
    if (host) |target| {
        run.addArgs(&.{ "--host-os", @tagName(target.os.tag), "--host-arch", @tagName(target.cpu.arch) });
    }
    if (require_native_c) run.addArg("--require-native-c");
    if (options.offline) run.addArg("--offline");
    // `rustup run` itself is non-installing; this also disables rustup's
    // deprecated implicit auto-install for Rustup invocations made by the
    // build (including the Cargo child and its rustc/rustdoc calls).
    run.setEnvironmentVariable("RUSTUP_AUTO_INSTALL", "0");
    run.has_side_effects = true;
    return run;
}

/// Cargo owns Rust dependency/incremental caching. Running it each build avoids
/// a stale archive when shared Rust sources change outside a crate directory.
///
/// `rustup run` (not `cargo +toolchain`) is deliberately used: `+toolchain` is
/// equivalent to `rustup run --install`, so it could install a missing
/// toolchain even after the check step. `rustup run` never installs unless
/// `--install` is passed, and it pins the nested rustc/rustdoc invocations via
/// RUSTUP_TOOLCHAIN.
pub fn cargo(b: *std.Build, options: Options, manifest: []const u8, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "rustup", "run", options.toolchain, "cargo" });
    run.addArgs(args);
    run.addArgs(&.{ "--locked", "--manifest-path", manifest });
    if (options.offline) run.addArg("--offline");
    run.setCwd(b.path("."));
    run.setEnvironmentVariable("RUSTUP_AUTO_INSTALL", "0");
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
