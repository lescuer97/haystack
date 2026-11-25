//! Native Bitcoin Core libsecp256k1, directly compiled by Zig.
const std = @import("std");

pub const Graph = struct {
    library: *std.Build.Step.Compile,
    bindings: *std.Build.Module,

    pub fn link(self: Graph, module: *std.Build.Module) void {
        module.addImport("secp256k1", self.bindings);
        module.linkLibrary(self.library);
    }
};

pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?Graph {
    const dep = b.lazyDependency("secp256k1", .{}) orelse return null;
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    module.addIncludePath(dep.path("include"));
    module.addIncludePath(dep.path("src"));
    module.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &.{ "src/secp256k1.c", "src/precomputed_ecmult.c", "src/precomputed_ecmult_gen.c" },
        .flags = &.{ "-std=c90", "-DENABLE_MODULE_EXTRAKEYS=1", "-DENABLE_MODULE_SCHNORRSIG=1", "-DECMULT_WINDOW_SIZE=15", "-DCOMB_BLOCKS=43", "-DCOMB_TEETH=6" },
    });
    @import("hardening.zig").cSources(module, optimize, target.result.os.tag) catch @panic("out of memory setting libsecp256k1 flags");
    const headers = b.addWriteFiles().add("haystack_secp256k1.h", "#include <secp256k1.h>\n#include <secp256k1_extrakeys.h>\n#include <secp256k1_schnorrsig.h>\n");
    const translated = b.addTranslateC(.{ .root_source_file = headers, .target = target, .optimize = optimize });
    translated.addIncludePath(dep.path("include"));
    return .{
        .library = b.addLibrary(.{ .name = "haystack_secp256k1", .linkage = .static, .root_module = module }),
        .bindings = translated.createModule(),
    };
}
