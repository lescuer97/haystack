const std = @import("std");

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

pub fn bootstrap(b: *std.Build, options: Options, rust_target: []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "python3", "build-support/bootstrap.py", "rust", "--toolchain", options.toolchain, "--target", rust_target });
    run.setName(b.fmt("ensure Rust {s} and target {s}", .{ options.toolchain, rust_target }));
    run.setCwd(b.path("."));
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

pub fn hostRustTarget(b: *std.Build) ![]const u8 {
    const host = b.graph.host.result;
    if (host.os.tag != .linux) return error.NativeLinuxHostRequired;
    const arch: []const u8 = switch (host.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return error.UnsupportedRustHostArchitecture,
    };
    return b.fmt("{s}-unknown-linux-{s}", .{ arch, if (host.abi.isMusl()) @as([]const u8, "musl") else "gnu" });
}
