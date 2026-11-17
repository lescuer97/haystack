const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.addModule("shared", .{ .root_source_file = b.path("shared/root.zig"), .target = target, .optimize = optimize });
    const websocket = b.dependency("websocket", .{ .target = target, .optimize = optimize });
    const sqlite = b.dependency("sqlite", .{ .target = target, .optimize = optimize, .memsys5 = true, .zero_malloc = true, .omit_autoinit = true, .threadsafe = @as(u2, 1) }).module("sqlite");
    const server_mod = b.createModule(.{
        .root_source_file = b.path("server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "shared", .module = shared }, .{ .name = "websocket", .module = websocket.module("websocket") } },
    });
    server_mod.addImport("sqlite", sqlite);
    server_mod.link_libc = true;
    const server = b.addExecutable(.{ .name = "haystack_server", .root_module = server_mod });
    const install_server = b.addInstallArtifact(server, .{});
    b.step("server", "Build and install the local server").dependOn(&install_server.step);
    const run_server = b.addRunArtifact(server);
    run_server.addPassthruArgs();
    b.step("run-server", "Run the local server").dependOn(&run_server.step);
    const unit_mod = b.createModule(.{ .root_source_file = b.path("server/tests.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "shared", .module = shared }} });
    unit_mod.addImport("sqlite", sqlite);
    unit_mod.addImport("websocket", websocket.module("websocket"));
    unit_mod.link_libc = true;
    const unit_tests = b.addRunArtifact(b.addTest(.{ .root_module = unit_mod }));
    const shared_tests = b.addRunArtifact(b.addTest(.{ .root_module = shared }));
    const server_test_step = b.step("test-server", "Run socket-free server and shared unit tests");
    server_test_step.dependOn(&unit_tests.step);
    server_test_step.dependOn(&shared_tests.step);
    const bounded_ws_tests = b.addRunArtifact(b.addTest(.{ .root_module = websocket.module("bounded_tests"), .filters = &.{"bounded-memory"} }));
    server_test_step.dependOn(&bounded_ws_tests.step);
    const ws_memory_mod = b.createModule(.{ .root_source_file = b.path("server/ws_memory_tests.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "websocket", .module = websocket.module("websocket") }} });
    ws_memory_mod.addImport("shared", shared);
    ws_memory_mod.addImport("sqlite", sqlite);
    server_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ws_memory_mod, .filters = &.{"bounded-memory application"} })).step);
    const bench_mod = b.createModule(.{ .root_source_file = b.path("server/bench.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "shared", .module = shared }, .{ .name = "sqlite", .module = sqlite } } });
    const benchmark = b.addExecutable(.{ .name = "bench-server", .root_module = bench_mod });
    b.step("build-bench-server", "Build/install the opt-in socket-free benchmark without running it").dependOn(&b.addInstallArtifact(benchmark, .{}).step);
    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.addPassthruArgs();
    b.step("bench-server", "Run opt-in socket-free real-file benchmark (16..512 iterations, default 128)").dependOn(&run_benchmark.step);
    if (!(b.option(bool, "game", "Configure the game and Raylib (default true)") orelse true)) return;
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("haystack_game", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("shared", shared);

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .linkage = .dynamic, // Build raylib as a shared library
    });
    const raylib = raylib_dep.module("raylib"); // main raylib module
    const raygui = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library
    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "haystack_game",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "haystack_game" is the name you will use in your source code to
                // import this module (e.g. `@import("haystack_game")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "haystack_game", .module = mod },
            },
        }),
    });
    exe.root_module.linkLibrary(raylib_artifact);
    exe.root_module.addImport("shared", shared);
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.addImport("raygui", raygui);

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // Ship the game's visual assets next to the installed executable at
    // zig-out/bin/assets/.
    b.installDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .bin,
        .install_subdir = "assets",
    });

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&shared_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
