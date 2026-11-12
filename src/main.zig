//! Application entry point: owns the allocator, the window, and the visibly
//! explicit frame loop.
//!
//! Frame order:
//!   1. collect input into a plain value,
//!   2. apply it to persistent `GameState`,
//!   3. calculate the temporary camera view,
//!   4. prepare (stream) the chunks that view needs,
//!   5. render read-only state.
//!
//! The same stages run on native and in the browser. The native build drives
//! them from a blocking loop; the browser build exports a C `main` and lets
//! Emscripten call one frame at a time so the page stays responsive.
//!
//! `main` also owns teardown. Defers run in reverse order, so the world is
//! released before the Raylib window closes and before the debug allocator
//! checks for leaks.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

const camera = @import("camera.zig");
const game_mod = @import("game.zig");
const input = @import("input.zig");
const rendering = @import("rendering.zig");
const world = @import("world.zig");
const browser_storage = @import("browser_storage.zig");
const config = @import("config.zig");
const instance_lock = @import("instance_lock.zig");
const paths = @import("paths.zig");
const storage_fs = @import("storage_fs.zig");

// `zig build test` collects tests from files referenced by this root module.
// Import every source file explicitly so no test file is silently skipped.
comptime {
    _ = @import("input.zig");
    _ = @import("camera.zig");
    _ = @import("game.zig");
    _ = @import("menu.zig");
    _ = @import("world.zig");
    _ = @import("rendering.zig");
    _ = @import("settings.zig");
    _ = @import("paths.zig");
    _ = @import("storage_fs.zig");
    _ = @import("content_key.zig");
    _ = @import("config.zig");
    _ = @import("content.zig");
    _ = @import("instance_lock.zig");
    _ = @import("browser_storage.zig");
    _ = @import("storage_home_test.zig");
}

// ── browser lifetime ─────────────────────────────────────────────────────────

extern "c" fn emscripten_set_main_loop(callback: *const fn () callconv(.c) void, fps: c_int, simulate_infinite_loop: c_int) void;
extern "c" fn emscripten_cancel_main_loop() void;
extern "c" fn emscripten_get_element_css_size(target: [*:0]const u8, width: *f64, height: *f64) c_int;

// Provided by the combined browser JS library (`game-wallet.js` plus the
// separate `game-storage.js`; `build/wasm.zig` concatenates them for the one
// Emscripten `--js-library` hook). Start returns immediately; the ready callback
// is invoked exactly once from the JS async continuation.
extern "c" fn haystack_wallet_smoke_start(callback: *const fn (ok: c_int) callconv(.c) void) void;
extern "c" fn haystack_ui_result(ok: c_int) void;

// The browser build is a static archive, so explicitly export its C entry point.
comptime {
    if (builtin.os.tag == .emscripten) @export(&webMain, .{ .name = "main" });
}

/// Everything the browser callback needs between frames. It lives on the heap
/// for the whole browser session: Emscripten must never see a pointer to a
/// `webMain` stack frame that has already returned.
const BrowserContext = struct {
    game_state: game_mod.GameState,
    input_reader: input.Reader,
};

var browser_context: ?*BrowserContext = null;
var wallet_continuation_done = false;
var storage_continuation_done = false;

fn webMain(_: c_int, _: [*c][*c]u8) callconv(.c) c_int {
    // The browser must prove the wallet bridge runs before any game context or
    // main loop exists. Start the async task and return immediately; the
    // single-shot continuation below creates the window and frame loop only on
    // success. This function never blocks and never enables Asyncify.
    if (builtin.os.tag != .emscripten) return 0;
    haystack_wallet_smoke_start(&walletReady);
    return 0;
}

/// Exactly one invocation is allowed even if the JS side or a repeated kickoff
/// tries again. A value of 1 means the disposable wallet was opened, checked,
/// closed, freed and cleaned up successfully; 0 is a generic failure.
fn walletReady(ok: c_int) callconv(.c) void {
    if (wallet_continuation_done) return;
    wallet_continuation_done = true;

    if (ok == 0) {
        std.log.err("wallet smoke failed: unable to start game", .{});
        haystack_ui_result(0);
        return;
    }

    // Settings live in IndexedDB and are guarded by a Web Lock. Both are
    // asynchronous; this second single-shot callback runs after the wallet
    // gate succeeded and before any game state or frame loop is created.
    browser_storage.start(&storageReady);
}

/// Second startup gate: Web Lock plus asynchronous settings load. The JS side
/// already converted storage failures into built-in defaults, except for the
/// lock, which is a startup failure just like a second desktop process.
fn storageReady(
    status_code: c_int,
    tile_grid: c_int,
    chunk_borders: c_int,
    autosave_blocked: c_int,
) callconv(.c) void {
    _ = autosave_blocked;
    if (storage_continuation_done) return;
    storage_continuation_done = true;

    const loaded = browser_storage.decode(status_code, tile_grid, chunk_borders);
    switch (loaded.status) {
        .locked => {
            std.log.err("browser storage: another game tab already owns this origin", .{});
            haystack_ui_result(0);
            return;
        },
        .malformed, .newer_version => std.log.warn(
            "browser storage: configuration preserved and autosave disabled status={s}",
            .{@tagName(loaded.status)},
        ),
        .unavailable => std.log.warn("browser storage: configuration unavailable; using built-in settings", .{}),
        .ready => {},
    }

    const settings = loaded.settings;

    // Do not build any game state before both gates succeed. Initialization
    // failures still clean up every partially-created resource and fail closed.
    startBrowser(settings) catch |err| {
        std.log.err("browser initialization failed: {s}", .{@errorName(err)});
        stopBrowser();
        haystack_ui_result(0);
        return;
    };
    haystack_ui_result(1);
    // In an async continuation `simulate_infinite_loop` must be 0: the loop
    // starts on the next animation frame and this call returns immediately.
    emscripten_set_main_loop(browserFrame, 0, 0);
}

/// The viewport the canvas already occupies. Raylib's web backend rescales its
/// canvas/renderbuffer from window.innerWidth/innerHeight on resize; passing
/// the real viewport here avoids starting at a stale fixed 1000x640 size.
const Viewport = struct { width: c_int, height: c_int };

fn viewportSize() Viewport {
    if (builtin.os.tag == .emscripten) {
        var width: f64 = 0;
        var height: f64 = 0;
        if (emscripten_get_element_css_size("#canvas", &width, &height) == 0 and
            width >= 1 and height >= 1 and width <= 16384 and height <= 16384)
        {
            return .{
                .width = @intFromFloat(width),
                .height = @intFromFloat(height),
            };
        }
    }
    return .{ .width = 1000, .height = 640 };
}

fn startBrowser(settings: game_mod.Settings) !void {
    const viewport = viewportSize();
    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(viewport.width, viewport.height, "haystack — chunk streaming test");
    errdefer rl.closeWindow();
    // The browser's requestAnimationFrame loop controls pacing. A nonzero
    // raylib target would make EndDrawing sleep inside the callback.
    rl.setTargetFPS(0);

    // Escape toggles the menu, so it must not also be Raylib's quit key.
    rl.setExitKey(.null);

    const allocator = std.heap.c_allocator;
    const ctx = try allocator.create(BrowserContext);
    errdefer allocator.destroy(ctx);

    ctx.* = .{
        .game_state = try game_mod.GameState.initWithSettings(
            allocator,
            @floatFromInt(rl.getScreenWidth()),
            @floatFromInt(rl.getScreenHeight()),
            settings,
        ),
        .input_reader = .{},
    };
    errdefer ctx.game_state.deinit();

    browser_context = ctx;
}

/// One browser frame. Errors cannot cross the C callback boundary, so a failure
/// logs and tears everything down exactly once. `browser_context` is cleared
/// before any resource is released; later callbacks return immediately.
fn browserFrame() callconv(.c) void {
    const ctx = browser_context orelse return;

    // Never call raylib's `windowShouldClose` here. The pinned web backend
    // implements it with a blocking `emscripten_sleep` that is forbidden
    // inside `emscripten_set_main_loop` (and aborts with asyncify disabled).
    // Browser lifetime is owned by the page/main loop instead. Both startup
    // gates (wallet and storage/lock) have already succeeded.
    stepFrame(
        &ctx.game_state,
        &ctx.input_reader,
        null,
        browser_settings_persister,
    ) catch |err| {
        std.log.err("browser frame failed: {s}", .{@errorName(err)});
        stopBrowser();
        return;
    };
}

fn stopBrowser() void {
    const ctx = browser_context orelse return;
    browser_context = null;

    emscripten_cancel_main_loop();
    ctx.game_state.deinit();
    std.heap.c_allocator.destroy(ctx);
    rl.closeWindow();
}

// ── settings persistence hook ────────────────────────────────────────────────

/// Called once per frame in which a debug toggle actually changed state.
/// Desktop writes synchronously; the browser queues an IndexedDB operation and
/// returns immediately. The callback never runs for a frame the menu consumed
/// or for an idle frame.
const SettingsPersister = struct {
    context: ?*anyopaque,
    save: *const fn (?*anyopaque, game_mod.Settings) void,
};

const NativePersistence = struct {
    path: []const u8,
    enabled: bool,
};

fn nativeSaveSettings(context: ?*anyopaque, settings: game_mod.Settings) void {
    const persistence: *NativePersistence = @ptrCast(@alignCast(context.?));
    if (!persistence.enabled) return;

    config.save(
        std.Io.Threaded.global_single_threaded.io(),
        persistence.path,
        settings,
    ) catch |err| {
        std.log.err(
            "config: save failed path={s} error={s}; autosave disabled",
            .{ persistence.path, @errorName(err) },
        );
        persistence.enabled = false;
    };
}

fn browserSaveSettings(_: ?*anyopaque, settings: game_mod.Settings) void {
    // Fire-and-forget by design: no await or blocking call is allowed in the
    // frame callback, and Asyncify is disabled.
    browser_storage.save(settings.debug.tile_grid, settings.debug.chunk_borders);
}

const browser_settings_persister: SettingsPersister = .{
    .context = null,
    .save = browserSaveSettings,
};

// ── shared frame stages ──────────────────────────────────────────────────────

/// Run one complete frame for either platform. Persistent state and the input
/// reader are borrowed; the browser owns them in `BrowserContext`, the native
/// loop owns them in `main`. `shot_path` is captured inside the drawing pass
/// (before presentation) so the image is not a post-swap black frame.
fn stepFrame(
    game_state: *game_mod.GameState,
    input_reader: *input.Reader,
    shot_path: ?[:0]const u8,
    persister: ?SettingsPersister,
) !void {
    const vw: f32 = @floatFromInt(rl.getScreenWidth());
    const vh: f32 = @floatFromInt(rl.getScreenHeight());

    // 1. collect input: this is the only stage that touches devices. dt only
    //    paces held directions; the camera still takes whole-tile requests.
    //    The menu's open state filters WASD out of directions.
    const frame_input = input_reader.read(rl.getFrameTime(), game_state.menu.opened);

    // 2. update persistent state from that input.
    const settings_before = game_state.settings;
    try game_state.update(frame_input);

    // A save follows an actual toggle only; modal frames and idle frames leave
    // the settings untouched and produce no write.
    if (persister) |hook| {
        if (!std.meta.eql(settings_before, game_state.settings)) {
            hook.save(hook.context, game_state.settings);
        }
    }

    // 3. calculate this frame's view. It is temporary; persistent state does
    //    not store a view.
    const view = try camera.calculate(game_state.camera, vw, vh);

    // 4. prepare the resident world chunks for that view.
    try game_state.streamChunks(view.chunks);

    // 5. render read-only state. The caller owns presentation timing.
    rl.beginDrawing();
    rendering.draw(game_state, view, vw, vh);
    // Capture after drawing and before `endDrawing` swaps/presents, otherwise
    // the framebuffer read is the cleared back buffer (a black screenshot).
    // The 2D overlay (HUD/minimap) is still batched at this point;
    // flush it explicitly so it is present in the captured image. Only the
    // requested screenshot frame pays this cost.
    if (shot_path) |path| {
        rl.gl.rlDrawRenderBatchActive();
        rl.takeScreenshot(path);
    }
    rl.endDrawing();
}

// ── native entry point ──────────────────────────────────────────────────────

pub fn main() anyerror!void {
    // Browser builds enter through the exported `webMain` and never reach the
    // blocking loop below.
    if (builtin.os.tag == .emscripten) return;

    const use_debug_allocator = switch (builtin.mode) {
        .debug, .safe => true,
        .fast, .small => false,
    };
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (use_debug_allocator) _ = debug_allocator.deinit();
    }
    const allocator = if (use_debug_allocator) debug_allocator.allocator() else std.heap.c_allocator;

    // ── storage root, single-instance lock and settings ─────────────────────
    // Filesystem work happens before the window is created, so a second process
    // fails without flashing a window. Resolving the user directories is the
    // only hard failure here; configuration failures below are non-fatal.
    const io = std.Io.Threaded.global_single_threaded.io();
    const locations = paths.resolveCurrent(allocator) catch |err| {
        std.log.err("storage: cannot determine haystack directories error={s}", .{@errorName(err)});
        return err;
    };
    defer locations.deinit(allocator);

    // A clean HOME may not contain ~/.config or ~/.local/share yet. Create only
    // the standard parent directories that are missing; existing ones are never
    // chmodded or rewritten. Haystack-owned directories are created later with
    // the strict 0700 policy.
    storage_fs.ensureStandardParents(io, locations.standard_parents) catch |err| {
        std.log.err("storage: cannot prepare standard directories error={s}", .{@errorName(err)});
        return err;
    };

    var storage_lock = instance_lock.acquire(io, locations.config_dir) catch |err| {
        switch (err) {
            error.AlreadyRunning => std.log.err(
                "haystack is already running for storage root {s}",
                .{locations.config_dir},
            ),
            else => std.log.err(
                "storage: cannot acquire single-instance lock path={s} error={s}",
                .{ locations.config_dir, @errorName(err) },
            ),
        }
        return err;
    };
    defer storage_lock.release(io);

    const loaded_config = config.load(io, allocator, locations.config_path);
    if (!loaded_config.autosaveAllowed()) {
        std.log.warn(
            "config: starting with built-in settings and autosave disabled status={s}",
            .{@tagName(loaded_config.status)},
        );
    }
    var persistence = NativePersistence{
        .path = locations.config_path,
        .enabled = loaded_config.autosaveAllowed(),
    };
    const persister = SettingsPersister{ .context = &persistence, .save = nativeSaveSettings };

    // ── window ───────────────────────────────────────────────────────────────
    const screen_w = 1000;
    const screen_h = 640;

    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(screen_w, screen_h, "haystack — chunk streaming test");
    defer rl.closeWindow();
    rl.setTargetFPS(rendering.target_fps);

    // Escape toggles the menu, so it must not also be Raylib's quit key.
    rl.setExitKey(.null);

    // ── persistent state ─────────────────────────────────────────────────────
    // The initial view is calculated from the window size so the chunk pool
    // starts with enough slots for the first prefetch ring. `main` owns this
    // value and releases it before the window closes.
    var game_state = try game_mod.GameState.initWithSettings(
        allocator,
        @floatFromInt(rl.getScreenWidth()),
        @floatFromInt(rl.getScreenHeight()),
        loaded_config.settings,
    );
    defer game_state.deinit();

    // Optional: HAYSTACK_SHOT=/path.png grabs a frame and exits (handy for CI).
    const shot_path: ?[:0]const u8 = if (std.c.getenv("HAYSTACK_SHOT")) |p| std.mem.span(p) else null;
    var shot_frames: i32 = if (shot_path != null) 5 else -1;

    // ── frame loop ───────────────────────────────────────────────────────────
    // The reader owns the held-direction cadence across frames. It is not
    // global; this loop is its only owner.
    var input_reader = input.Reader{};

    while (!rl.windowShouldClose()) {
        // Capture on the last requested frame, inside stepFrame's drawing pass.
        try stepFrame(
            &game_state,
            &input_reader,
            if (shot_frames == 0) shot_path else null,
            persister,
        );

        if (shot_frames >= 0) {
            if (shot_frames == 0) break;
            shot_frames -= 1;
        }
    }
}
