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
    });

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .linkage = .dynamic, // Build raylib as a shared library
    });
    const raylib = raylib_dep.module("raylib"); // main raylib module
    const raygui = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library

    // -------------------------------------------------------------------------
    // Vendored Rust `cdk-wallet-ffi` static library and its generated C header.
    // -------------------------------------------------------------------------
    // Native Linux libraries required by the Rust staticlib, verified with
    // `cargo rustc --release --locked --lib -- --print=native-static-libs`.
    // (Do not copy Iroh's macOS `-lSystem` flags.)
    //
    // The Rust staticlib is built with `panic = "unwind"` (required so the ABI
    // can `catch_unwind` panics instead of aborting), so its `_Unwind_*`
    // references must be resolved. This host ships `libunwind` (with a
    // `libunwind.so` dev symlink) rather than a `libgcc_s.so` symlink, so we
    // link `libunwind` explicitly.
    const native_libs = [_][]const u8{ "unwind", "pthread", "dl", "rt", "util", "m" };
    const rust_manifest = "vendor/cdk-wallet-ffi/Cargo.toml";
    const rust_static_lib = "vendor/cdk-wallet-ffi/target/release/libcdk_wallet_ffi.a";
    const rust_include_dir = "vendor/cdk-wallet-ffi/include";

    // Build the Rust staticlib (release) with the pinned toolchain, `--locked`.
    const rust_build = b.addSystemCommand(&.{
        "cargo",           "+stable",     "build", "--release", "--locked",
        "--manifest-path", rust_manifest,
    });
    rust_build.setCwd(b.path("."));
    rust_build.has_side_effects = true;

    // The `cdk` module exposes the generated C header. Zig 0.17 removed
    // `@cImport`, so the header is translated to a Zig module by the build
    // system (`b.addTranslateC`) and re-exported as `cdk.c`.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/cdk-wallet-ffi/include/cdk_wallet.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path(rust_include_dir));
    const cdk_c_mod = translate_c.addModule("cdk_c");

    const cdk_mod = b.addModule("cdk", .{
        .root_source_file = b.path("src/cdk.zig"),
        .target = target,
    });
    cdk_mod.addImport("cdk_c", cdk_c_mod);

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
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.addImport("raygui", raygui);

    // Link the vendored wallet FFI static library and expose the `cdk` module.
    exe.root_module.addImport("cdk", cdk_mod);
    exe.root_module.addObjectFile(b.path(rust_static_lib));
    exe.root_module.link_libc = true;
    for (native_libs) |name| {
        exe.root_module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    }
    exe.step.dependOn(&rust_build.step);

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
    // The executable links the Rust staticlib, so a clean `zig build test` must
    // build it first.
    exe_tests.step.dependOn(&rust_build.step);

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // -------------------------------------------------------------------------
    // Wallet-specific build steps.
    // -------------------------------------------------------------------------

    // `zig build wallet` just builds the vendored Rust static library.
    const wallet_step = b.step("wallet", "Build the vendored Rust wallet FFI static library");
    wallet_step.dependOn(&rust_build.step);

    // `zig build header-check` verifies the committed header matches the sources.
    const header_check = b.addSystemCommand(&.{
        "cargo",           "+stable",     "run",   "--locked",         "--features", "headers",
        "--manifest-path", rust_manifest, "--bin", "generate-headers", "--",         "--check",
    });
    header_check.setCwd(b.path("."));
    header_check.has_side_effects = true;
    const header_check_step = b.step("header-check", "Verify the generated C header is up to date");
    header_check_step.dependOn(&header_check.step);

    // `zig build test-wallet` runs the Rust test suite (policy + fake-mint
    // end-to-end) and the Zig C-ABI consumer test.
    const rust_test = b.addSystemCommand(&.{
        "cargo", "+stable", "test", "--locked", "--manifest-path", rust_manifest,
    });
    rust_test.setCwd(b.path("."));
    rust_test.has_side_effects = true;

    const wallet_test_mod = b.createModule(.{
        .root_source_file = b.path("src/wallet_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    wallet_test_mod.addImport("cdk", cdk_mod);
    wallet_test_mod.addObjectFile(b.path(rust_static_lib));
    wallet_test_mod.link_libc = true;
    for (native_libs) |name| {
        wallet_test_mod.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    }

    const wallet_tests = b.addTest(.{
        .root_module = wallet_test_mod,
    });
    wallet_tests.step.dependOn(&rust_build.step);
    const run_wallet_tests = b.addRunArtifact(wallet_tests);

    // `zig build test-spilman` runs the offline CDK ⇄ Spilman integration suite
    // (contract, handoff, and fixture-replay tests). It links the same static
    // library but has its own module so the two suites stay readable.
    const spilman_test_mod = b.createModule(.{
        .root_source_file = b.path("src/spilman_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    spilman_test_mod.addImport("cdk", cdk_mod);
    spilman_test_mod.addObjectFile(b.path(rust_static_lib));
    spilman_test_mod.link_libc = true;
    for (native_libs) |name| {
        spilman_test_mod.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    }

    const spilman_tests = b.addTest(.{
        .root_module = spilman_test_mod,
    });
    spilman_tests.step.dependOn(&rust_build.step);
    const run_spilman_tests = b.addRunArtifact(spilman_tests);

    const test_spilman_step = b.step(
        "test-spilman",
        "Run the offline CDK and Spilman channel C-ABI integration tests",
    );
    test_spilman_step.dependOn(&run_spilman_tests.step);

    const test_wallet_step = b.step("test-wallet", "Run the Rust wallet tests and the Zig C-ABI consumer test");
    test_wallet_step.dependOn(&header_check.step);
    test_wallet_step.dependOn(&rust_test.step);
    test_wallet_step.dependOn(&run_wallet_tests.step);
    test_wallet_step.dependOn(test_spilman_step);

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
