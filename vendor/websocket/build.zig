const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket_module = b.addModule("websocket", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("src/websocket.zig"),
    });

    {
        const options = b.addOptions();
        options.addOption(bool, "websocket_blocking", false);
        websocket_module.addOptions("build", options);
    }

    const bounded_module = b.addModule("bounded_tests", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("src/bounded_tests.zig"),
    });
    const bounded_options = b.addOptions();
    bounded_options.addOption(bool, "websocket_blocking", false);
    bounded_module.addOptions("build", bounded_options);
    const bounded_tests = b.addTest(.{
        .root_module = bounded_module,
        .filters = &.{"bounded-memory"},
    });
    const bounded_step = b.step("test-bounded", "Run only socket-free bounded-memory tests");
    bounded_step.dependOn(&b.addRunArtifact(bounded_tests).step);

    {
        // run tests
        const tests = b.addTest(.{
            .root_module = websocket_module,
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });
        const force_blocking = b.option(bool, "force_blocking", "Force blocking mode") orelse false;
        const options = b.addOptions();
        options.addOption(bool, "websocket_blocking", force_blocking);
        tests.root_module.addOptions("build", options);

        const run_test = b.addRunArtifact(tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_test.step);
    }
}
