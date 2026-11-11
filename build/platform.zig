//! Pure native-platform policy shared by the desktop graph and its tests.
//!
//! Zig resolves the requested target and the host; this module decides whether
//! that combination is one of the supported native desktop configurations and
//! returns every platform-specific value the build needs. It has no `Build`
//! dependency, so the matrix can be unit-tested with synthetic host/target
//! pairs on any supported development machine.

const std = @import("std");

/// Minimum supported macOS deployment target for native Apple Silicon builds.
///
/// `F_OFD_SETLK` (the database lock used on macOS) is public in macOS 14+ SDK
/// headers, but this project declares macOS 15.0 because that is the oldest OS
/// its CI runner can actually exercise. The same value is applied to Zig,
/// raylib's C/Objective-C sources and Rust through `MACOSX_DEPLOYMENT_TARGET`.
pub const macos_deployment_target = "15.0";

pub const macos_deployment_version: std.SemanticVersion = .{ .major = 15, .minor = 0, .patch = 0 };

pub const linux_native_libraries: []const []const u8 = &.{ "unwind", "pthread", "dl", "rt", "util", "m" };
pub const macos_native_libraries: []const []const u8 = &.{ "System", "m" };

pub const Policy = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    abi: std.Target.Abi,
    /// Rust target triple matching the validated Zig target.
    rust_target: []const u8,
    /// Sole installed-tree runtime search path; there are no cache fallbacks.
    rpath: []const u8,
    /// Native libraries Rust's unwind/pthread requirements need linked.
    native_libraries: []const []const u8,
    /// Deployment target pinned for macOS. `null` on Linux.
    macos_deployment: ?std.SemanticVersion,
};

pub const ResolveError = error{
    /// The Zig host itself is not a supported native desktop platform.
    UnsupportedHost,
    UnsupportedHostArchitecture,
    UnsupportedHostAbi,
    /// A Wasm target was requested from the native desktop graph.
    WasmTarget,
    /// Zig resolved the target for a different OS/arch/ABI than the host.
    ForeignOperatingSystem,
    ForeignArchitecture,
    ForeignAbi,
    UnsupportedLinuxArchitecture,
    UnsupportedLinuxAbi,
    UnsupportedMacosArchitecture,
    UnsupportedMacosAbi,
    UnsupportedDeploymentTarget,
};

/// Resolve one effective native desktop policy.
///
/// `host` must be Zig's detected host (`b.graph.host.result`), never a guessed
/// `uname` value. `requested` is the resolved `-Dtarget` target. Only the exact
/// documented matrix is accepted; everything else fails here, before any tool
/// provisioning or compilation.
pub fn resolve(host: std.Target, requested: std.Target) ResolveError!Policy {
    if (requested.cpu.arch.isWasm()) return error.WasmTarget;

    try validateHost(host);

    if (requested.os.tag != host.os.tag) return error.ForeignOperatingSystem;
    if (requested.cpu.arch != host.cpu.arch) return error.ForeignArchitecture;
    if (requested.abi != host.abi) return error.ForeignAbi;

    return switch (requested.os.tag) {
        .linux => resolveLinux(requested),
        .macos => resolveMacos(requested),
        else => error.UnsupportedHost,
    };
}

fn validateHost(host: std.Target) ResolveError!void {
    switch (host.os.tag) {
        .linux => {
            switch (host.cpu.arch) {
                .x86_64, .aarch64 => {},
                else => return error.UnsupportedHostArchitecture,
            }
            if (host.abi != .gnu and host.abi != .musl) return error.UnsupportedHostAbi;
        },
        .macos => {
            if (host.cpu.arch != .aarch64) return error.UnsupportedHostArchitecture;
            if (host.abi != .none) return error.UnsupportedHostAbi;
        },
        else => return error.UnsupportedHost,
    }
}

fn resolveLinux(target: std.Target) ResolveError!Policy {
    const rust_target = switch (target.cpu.arch) {
        .x86_64 => switch (target.abi) {
            .gnu => "x86_64-unknown-linux-gnu",
            .musl => "x86_64-unknown-linux-musl",
            else => return error.UnsupportedLinuxAbi,
        },
        .aarch64 => switch (target.abi) {
            .gnu => "aarch64-unknown-linux-gnu",
            .musl => "aarch64-unknown-linux-musl",
            else => return error.UnsupportedLinuxAbi,
        },
        else => return error.UnsupportedLinuxArchitecture,
    };

    return .{
        .os = .linux,
        .arch = target.cpu.arch,
        .abi = target.abi,
        .rust_target = rust_target,
        .rpath = "$ORIGIN/../lib",
        .native_libraries = linux_native_libraries,
        .macos_deployment = null,
    };
}

fn resolveMacos(target: std.Target) ResolveError!Policy {
    if (target.cpu.arch != .aarch64) return error.UnsupportedMacosArchitecture;
    if (target.abi != .none) return error.UnsupportedMacosAbi;

    // The default is macOS 15.0. An explicit newer minimum is accepted but the
    // build still pins the same 15.0 floor for Zig, raylib and Rust so all three
    // use one deployment target. An explicit older minimum is unsupported.
    const range = target.os.version_range.semver;
    if (range.min.order(macos_deployment_version) == .lt) return error.UnsupportedDeploymentTarget;

    return .{
        .os = .macos,
        .arch = target.cpu.arch,
        .abi = target.abi,
        .rust_target = "aarch64-apple-darwin",
        .rpath = "@loader_path/../lib",
        .native_libraries = macos_native_libraries,
        .macos_deployment = macos_deployment_version,
    };
}

fn resolveQuery(query: std.Target.Query) !std.Target {
    return std.zig.system.resolveTargetQuery(std.testing.io, query);
}

test "Linux x86_64 glibc is the exact GNU policy" {
    const target = try resolveQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    const policy = try resolve(target, target);
    try std.testing.expectEqual(std.Target.Os.Tag.linux, policy.os);
    try std.testing.expectEqual(std.Target.Cpu.Arch.x86_64, policy.arch);
    try std.testing.expectEqual(std.Target.Abi.gnu, policy.abi);
    try std.testing.expectEqualStrings("x86_64-unknown-linux-gnu", policy.rust_target);
    try std.testing.expectEqualStrings("$ORIGIN/../lib", policy.rpath);
    try std.testing.expectEqual(@as(?std.SemanticVersion, null), policy.macos_deployment);
    try std.testing.expectEqualStrings("unwind", policy.native_libraries[0]);
}

test "Linux aarch64 musl is the exact musl policy" {
    const target = try resolveQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl });
    const policy = try resolve(target, target);
    try std.testing.expectEqual(std.Target.Cpu.Arch.aarch64, policy.arch);
    try std.testing.expectEqual(std.Target.Abi.musl, policy.abi);
    try std.testing.expectEqualStrings("aarch64-unknown-linux-musl", policy.rust_target);
}

test "Linux glibc host cannot silently become a musl target" {
    const host = try resolveQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    const target = try resolveQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl });
    try std.testing.expectError(error.ForeignAbi, resolve(host, target));
}

test "Apple Silicon macOS is the only supported macOS target" {
    const target = try resolveQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const policy = try resolve(target, target);
    try std.testing.expectEqual(std.Target.Os.Tag.macos, policy.os);
    try std.testing.expectEqual(std.Target.Cpu.Arch.aarch64, policy.arch);
    try std.testing.expectEqual(std.Target.Abi.none, policy.abi);
    try std.testing.expectEqualStrings("aarch64-apple-darwin", policy.rust_target);
    try std.testing.expectEqualStrings("@loader_path/../lib", policy.rpath);
    try std.testing.expectEqual(macos_deployment_version, policy.macos_deployment.?);
}

test "Intel macOS host is rejected before any tool provisioning" {
    const target = try resolveQuery(.{ .cpu_arch = .x86_64, .os_tag = .macos });
    try std.testing.expectError(error.UnsupportedHostArchitecture, resolve(target, target));
}

test "macOS target with a non-Darwin ABI is rejected" {
    const host = try resolveQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    var target = host;
    target.abi = .gnu;
    try std.testing.expectError(error.ForeignAbi, resolve(host, target));
}

test "macOS deployment target below 15.0 is rejected" {
    const host = try resolveQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const target = try resolveQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } },
    });
    try std.testing.expectError(error.UnsupportedDeploymentTarget, resolve(host, target));
}

test "foreign desktop operating systems are rejected" {
    const host = try resolveQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    const target = try resolveQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc });
    try std.testing.expectError(error.ForeignOperatingSystem, resolve(host, target));
}

test "unsupported native hosts are rejected" {
    const target = try resolveQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc });
    try std.testing.expectError(error.UnsupportedHost, resolve(target, target));
}

test "foreign architectures are rejected" {
    const host = try resolveQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    const target = try resolveQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu });
    try std.testing.expectError(error.ForeignArchitecture, resolve(host, target));
}

test "Wasm targets never select a native desktop policy" {
    const host = try resolveQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    const target = try resolveQuery(.{ .cpu_arch = .wasm32, .os_tag = .emscripten });
    try std.testing.expectError(error.WasmTarget, resolve(host, target));
}
