//! Application entry point: owns the allocator, the window, and the visibly
//! explicit frame loop.
//!
//! Display frames service real-time completions, poll raw input, and draw.
//! A loop-owned driver consumes ordered input at 20 Hz, dispatches effects
//! immediately, and caches the calculated view + viewport after streaming.
//! Native 120 FPS/browser rAF presentation draws latest state, no interpolation.
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

const game_mod = @import("game.zig");
const input = @import("input.zig");
const frame_loop = @import("frame_loop.zig");
const routeFrame = frame_loop.routeFrame;
const rendering = @import("rendering.zig");
const world = @import("world.zig");
const browser_storage = @import("browser_storage.zig");
const config = @import("config.zig");
const instance_lock = @import("instance_lock.zig");
const paths = @import("paths.zig");
const storage_fs = @import("storage_fs.zig");
const onboarding = @import("onboarding.zig");
const browser_onboarding = @import("browser_onboarding.zig");
const native_onboarding = if (builtin.os.tag != .emscripten) @import("onboarding_native.zig") else struct {};
const native_wallet = if (builtin.os.tag != .emscripten) @import("wallet.zig") else struct {};
const wallet_ui = @import("wallet_ui.zig");
const wallet_service = if (builtin.os.tag != .emscripten) @import("wallet_service.zig") else struct {};

// `zig build test` collects tests from files referenced by this root module.
// Import every source file explicitly so no test file is silently skipped.
comptime {
    _ = @import("input.zig");
    _ = @import("frame_loop.zig");
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
    _ = @import("onboarding.zig");
}

// ── browser lifetime ─────────────────────────────────────────────────────────

extern "c" fn emscripten_set_main_loop(callback: *const fn () callconv(.c) void, fps: c_int, simulate_infinite_loop: c_int) void;
extern "c" fn emscripten_cancel_main_loop() void;
extern "c" fn emscripten_get_element_css_size(target: [*:0]const u8, width: *f64, height: *f64) c_int;

extern "c" fn haystack_ui_result(ok: c_int) void;

// The browser build is a static archive, so explicitly export its C entry point.
comptime {
    if (builtin.os.tag == .emscripten) @export(&webMain, .{ .name = "main" });
    if (builtin.os.tag == .emscripten) @export(&browser_onboarding.link, .{ .name = "haystack_onboarding_link" });
}

/// Everything the browser callback needs between frames. It lives on the heap
/// for the whole browser session: Emscripten must never see a pointer to a
/// `webMain` stack frame that has already returned.
const BrowserContext = struct {
    game_state: game_mod.GameState,
    input_reader: input.Reader,
    driver: frame_loop.Driver = .{},
    model: onboarding.Onboarding,
    clipboard_identity: browser_onboarding.ClipboardIdentity = .{},
    recovery_paste_epoch: u64 = 0,
    withdrawal_paste_epoch: u64 = 0,
};

var browser_context: ?*BrowserContext = null;
var clipboard_mailbox: browser_onboarding.ClipboardMailbox = .{};
var withdrawal_clipboard: wallet_ui.Text(4096) = .{};
var withdrawal_clipboard_pending = false;
extern "c" fn haystack_wallet_unix_time() f64;
extern "c" fn haystack_onboarding_bind_input(*const fn (c_int, c_int, c_int, [*]u8, u32) callconv(.c) c_int, *const fn ([*c]const u8, u32) callconv(.c) void, *const fn (c_int) callconv(.c) void) void;
extern "c" fn haystack_onboarding_unbind_input() void;

fn syncClipboardTarget(ctx: *BrowserContext) void {
    const target: browser_onboarding.ClipboardTarget = if (ctx.model.isBlocking())
        if (ctx.model.phase == .phrase_entry) .{ .recovery = ctx.model.attempt_id } else .none
    else if (ctx.game_state.menu.opened and ctx.game_state.menu.currentPage == .Withdraw and ctx.game_state.menu.focus == .withdrawal_invoice)
        .withdrawal
    else
        .none;
    ctx.clipboard_identity.sync(target);
}

fn pasteProbe(ctx: *BrowserContext, ptr: [*]u8, cap: u32, code: c_int) c_int {
    if (cap < 8) return 0;
    syncClipboardTarget(ctx);
    std.mem.writeInt(u64, ptr[0..8], ctx.clipboard_identity.epoch, .little);
    return code;
}

fn clipboardProbe(kind: c_int, x: c_int, y: c_int, ptr: [*]u8, cap: u32) callconv(.c) c_int {
    const ctx = browser_context orelse return 0;
    if (cap > 4097) return 0;
    if (!ctx.model.isBlocking() and ctx.game_state.menu.opened and ctx.game_state.menu.currentPage == .Withdraw) {
        const state = &ctx.game_state.menu;
        if (kind == 2) return if (state.focus == .withdrawal_invoice) pasteProbe(ctx, ptr, cap, 16) else 0;
        const layout = state.layoutFor(ctx.driver.viewport_w, ctx.driver.viewport_h);
        const selected = if (kind == 1) state.selected_index else if (kind == 0)
            layout.hitTest(@as(f32, @floatFromInt(x)) * ctx.driver.viewport_w / 1_000_000, @as(f32, @floatFromInt(y)) * ctx.driver.viewport_h / 1_000_000) orelse return 0
        else
            return 0;
        if (selected != 1) return 0;
        if (state.focus != .withdrawal_invoice) ctx.driver.invalidateInput();
        state.focus = .withdrawal_invoice;
        return pasteProbe(ctx, ptr, cap, 16);
    }
    if (!ctx.model.isBlocking() and ctx.game_state.menu.opened and ctx.game_state.menu.currentPage == .Invoice) {
        const state = &ctx.game_state.menu;
        const layout = @import("menu.zig").calculateLayout(.Invoice, ctx.driver.viewport_w, ctx.driver.viewport_h);
        const selected = if (kind == 1) state.selected_index else if (kind == 0)
            layout.hitTest(@as(f32, @floatFromInt(x)) * ctx.driver.viewport_w / 1_000_000, @as(f32, @floatFromInt(y)) * ctx.driver.viewport_h / 1_000_000) orelse return 0
        else
            return 0;
        if (selected != 0 or !state.wallet.canCopyInvoice() or state.wallet.invoice.len >= cap) return 0;
        @memset(ptr[0..cap], 0);
        @memcpy(ptr[0..state.wallet.invoice.len], state.wallet.invoice.slice());
        return 15;
    }
    const code = browser_onboarding.probe(&ctx.model, kind, x, y, ctx.driver.viewport_w, ctx.driver.viewport_h, ptr[0..cap]);
    return if (code == 14) pasteProbe(ctx, ptr, cap, code) else code;
}
fn clipboardPaste(ptr: [*c]const u8, len: u32) callconv(.c) void {
    const ctx = browser_context orelse return;
    if (len > 4096 or (len > 0 and ptr == null)) return;
    syncClipboardTarget(ctx);
    if (!ctx.model.isBlocking()) {
        if (ctx.game_state.menu.opened and ctx.game_state.menu.currentPage == .Withdraw and ctx.game_state.menu.focus == .withdrawal_invoice) {
            withdrawal_clipboard_pending = withdrawal_clipboard.set(if (len == 0) "" else ptr[0..len]);
            if (withdrawal_clipboard_pending) ctx.withdrawal_paste_epoch = ctx.clipboard_identity.epoch;
        }
        return;
    }
    if (len > 1024) return;
    clipboard_mailbox.paste(if (len == 0) "" else ptr[0..len]);
    if (clipboard_mailbox.has_paste) ctx.recovery_paste_epoch = ctx.clipboard_identity.epoch;
}
fn clipboardCopied(code: c_int) callconv(.c) void {
    if (browser_context != null and code >= 1 and code <= 13) clipboard_mailbox.copied = code;
}
var storage_continuation_done = false;
var pending_browser_settings: game_mod.Settings = undefined;

fn webMain(_: c_int, _: [*c][*c]u8) callconv(.c) c_int {
    if (builtin.os.tag != .emscripten) return 0;
    browser_storage.start(&storageReady);
    return 0;
}

/// Startup gate: Web Lock plus asynchronous settings load. The JS side
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

    pending_browser_settings = loaded.settings;
    browser_onboarding.start(browserServiceReady) catch {
        stopBrowser();
        haystack_ui_result(0);
    };
}

fn browserServiceReady(ok: bool) void {
    if (!ok) {
        stopBrowser();
        haystack_ui_result(0);
        return;
    }
    // Do not build any game state before the storage gate succeeds. Initialization
    // failures still clean up every partially-created resource and fail closed.
    startBrowser(pending_browser_settings) catch |err| {
        std.log.err("browser initialization failed: {s}", .{@errorName(err)});
        stopBrowser();
        haystack_ui_result(0);
        return;
    };
    _ = browser_onboarding.request("inspect", "{}") catch {
        browser_context.?.model.receive(.blocked);
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
    if (!rl.isWindowReady()) {
        std.log.err("window initialization failed", .{});
        return error.WindowInitializationFailed;
    }
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
        .model = onboarding.Onboarding.init(allocator),
    };
    errdefer ctx.game_state.deinit();
    errdefer ctx.model.deinit();

    browser_context = ctx;
    clipboard_mailbox.clear();
    withdrawal_clipboard = .{};
    withdrawal_clipboard_pending = false;
    haystack_onboarding_bind_input(clipboardProbe, clipboardPaste, clipboardCopied);
}

/// One browser frame. Errors cannot cross the C callback boundary, so a failure
/// logs and tears everything down exactly once. `browser_context` is cleared
/// before any resource is released; later callbacks return immediately.
fn browserFrame() callconv(.c) void {
    const ctx = browser_context orelse return;

    // Never call raylib's `windowShouldClose` here. The pinned web backend
    // implements it with a blocking `emscripten_sleep` that is forbidden
    // inside `emscripten_set_main_loop` (and aborts with asyncify disabled).
    // Browser lifetime is owned by the page/main loop instead.
    if (browser_onboarding.take()) |value| {
        var result = value;
        defer std.crypto.secureZero(u8, &result.bytes);
        browser_onboarding.deliver(&result, &ctx.model);
        ctx.driver.invalidateInput();
    }
    syncClipboardTarget(ctx);
    if (clipboard_mailbox.has_paste and (ctx.clipboard_identity.target != .recovery or ctx.recovery_paste_epoch != ctx.clipboard_identity.epoch)) {
        std.crypto.secureZero(u8, &clipboard_mailbox.bytes);
        clipboard_mailbox.len = 0;
        clipboard_mailbox.has_paste = false;
    }
    if (clipboard_mailbox.has_paste and ctx.model.phase == .phrase_entry) ctx.driver.invalidateInput();
    clipboard_mailbox.consume(&ctx.model, rl.getTime());
    if (withdrawal_clipboard_pending) {
        ctx.driver.invalidateInput();
        if (ctx.clipboard_identity.target == .withdrawal and ctx.withdrawal_paste_epoch == ctx.clipboard_identity.epoch) _ = ctx.game_state.menu.pasteWithdrawal(withdrawal_clipboard.slice());
        std.crypto.secureZero(u8, &withdrawal_clipboard.bytes);
        withdrawal_clipboard.len = 0;
        withdrawal_clipboard_pending = false;
    }
    ctx.model.expire(rl.getTime());
    const wallet_model = &ctx.game_state.menu.wallet;
    const unix = haystack_wallet_unix_time();
    if (std.math.isFinite(unix) and unix >= 0 and unix < 253402300800) wallet_model.unix_now = @intFromFloat(unix);
    ctx.game_state.menu.paste_requested = false; // Browser reads only in the trusted gesture handler.
    if (browser_onboarding.stepWallet(wallet_model, !ctx.model.isBlocking(), rl.getTime())) ctx.driver.invalidateInput();
    stepFrame(
        &ctx.game_state,
        &ctx.input_reader,
        &ctx.driver,
        browser_settings_persister,
        &ctx.model,
        .{ .context = ctx, .dispatch = browserDispatch, .after_input = browserAfterInput },
    ) catch |err| {
        std.log.err("browser frame failed: {s}", .{@errorName(err)});
        stopBrowser();
        return;
    };
}

fn browserDispatch(context: ?*anyopaque, model: *onboarding.Onboarding, effect: onboarding.Effect) void {
    const ctx: *BrowserContext = @ptrCast(@alignCast(context.?));
    syncClipboardTarget(ctx);
    browserEffect(model, effect);
    syncClipboardTarget(ctx);
}

fn browserAfterInput(context: ?*anyopaque, _: *game_mod.GameState) void {
    const ctx: *BrowserContext = @ptrCast(@alignCast(context.?));
    syncClipboardTarget(ctx);
}

fn browserEffect(model: *onboarding.Onboarding, effect: onboarding.Effect) void {
    const op: []const u8 = switch (effect) {
        .create_requested => "create",
        .restore_requested => "restore",
        .retry_requested => "retry",
        .generate_requested => "generate",
        .complete_requested => "complete_backup",
        .finish_restore_requested => "finish_restore",
        .retry_open_requested => "retry_open",
        .copy_requested, .copy_word_requested, .paste_requested => return,
    };
    if (effect == .restore_requested) {
        const args = std.json.Stringify.valueAlloc(model.allocator, .{ .phrase = model.recoveryPhrase() }, .{}) catch {
            model.receive(.blocked);
            return;
        };
        defer {
            std.crypto.secureZero(u8, args);
            model.allocator.free(args);
        }
        _ = browser_onboarding.request(op, args) catch {
            model.receive(.blocked);
        };
    } else {
        _ = browser_onboarding.request(op, "{}") catch {
            if (effect == .retry_open_requested) {
                model.receive(.open_failed);
            } else if (effect == .complete_requested or effect == .finish_restore_requested) {
                model.receive(.complete_fail);
            } else if (effect == .retry_requested and model.stage_created) {
                model.receive(.{ .restore_failed = .{ .attempt_id = model.attempt_id, .stage_created = true, .can_generate_new = false } });
            } else {
                model.receive(.blocked);
            }
        };
    }
}

fn stopBrowser() void {
    const ctx = browser_context;
    browser_context = null;
    browser_onboarding.close();
    const context = ctx orelse return;

    haystack_onboarding_unbind_input();
    clipboard_mailbox.clear();
    withdrawal_clipboard = .{};
    withdrawal_clipboard_pending = false;

    emscripten_cancel_main_loop();
    context.model.deinit();
    context.driver.deinit();
    context.game_state.deinit();
    std.heap.c_allocator.destroy(context);
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

/// Run one presentation frame for either platform, with at most one due tick.
/// State, driver and input reader are borrowed from `BrowserContext` or native
/// `main`.
fn stepFrame(
    game_state: *game_mod.GameState,
    input_reader: *input.Reader,
    driver: *frame_loop.Driver,
    persister: ?SettingsPersister,
    model: ?*onboarding.Onboarding,
    sink: ?frame_loop.EffectSink,
) !void {
    const vw: f32 = @floatFromInt(rl.getScreenWidth());
    const vh: f32 = @floatFromInt(rl.getScreenHeight());

    driver.observeRouting(game_state, model);
    var sample = input_reader.read();
    driver.queue.push(&sample);
    // Initial preparation is safe even with an invalid startup clock: no
    // simulation input is consumed, but drawing never uses an undefined view.
    const settings_before = game_state.settings;
    const advanced = try driver.advance(rl.getTime(), game_state, model, sink);
    if (driver.view == null) try driver.prepare(game_state, vw, vh);

    // A save follows an actual toggle only; modal frames and idle frames leave
    // the settings untouched and produce no write.
    if (persister) |hook| {
        if (!std.meta.eql(settings_before, game_state.settings)) {
            hook.save(hook.context, game_state.settings);
        }
    }

    if (advanced) driver.skipPast(rl.getTime());

    // 5. render read-only state. The caller owns presentation timing.
    rl.beginDrawing();
    rendering.draw(game_state, driver.view.?, driver.viewport_w, driver.viewport_h, model);
    rl.endDrawing();
}

test "onboarding consumes game input including the completion transition" {
    var game = try game_mod.GameState.init(std.testing.allocator, 1000, 640);
    defer game.deinit();
    var model = onboarding.Onboarding.init(std.testing.allocator);
    defer model.deinit();
    model.receive(.{ .backup = try std.testing.allocator.dupe(u8, "test words") });
    const camera_before = game.camera;
    const settings_before = game.settings;
    const frame = input.FrameInput{ .right = true, .dragging = true, .drag_x = -64, .toggle_grid = true, .toggle_borders = true, .escape_clicked = true, .confirm = true };
    model.saved = true;
    model.selected = .complete_backup;
    try std.testing.expectEqual(@as(?onboarding.Effect, .complete_requested), try routeFrame(&game, &model, frame));
    try std.testing.expectEqual(onboarding.Phase.completing, model.phase);
    try std.testing.expect(std.meta.eql(camera_before, game.camera));
    try std.testing.expect(std.meta.eql(settings_before, game.settings));
    try std.testing.expect(!game.menu.opened);
    model.receive(.complete_success);
    _ = try routeFrame(&game, &model, .{ .right = true });
    try std.testing.expectEqual(@as(i32, 1), game.camera.tile_x);
}

test "paste shortcut routes only in phrase entry and consumes its character" {
    var game = try game_mod.GameState.init(std.testing.allocator, 1000, 640);
    defer game.deinit();
    var model = onboarding.Onboarding.init(std.testing.allocator);
    defer model.deinit();
    model.receive(.{ .choice = .{ .recover_enabled = true } });
    var frame = input.FrameInput{ .paste_shortcut = true, .character_count = 1, .right = true };
    frame.characters[0] = 'v';
    try std.testing.expectEqual(@as(?onboarding.Effect, null), try routeFrame(&game, &model, frame));
    model.selected = .enter_recovery;
    _ = try routeFrame(&game, &model, .{ .confirm = true });
    try std.testing.expectEqual(@as(?onboarding.Effect, .paste_requested), try routeFrame(&game, &model, frame));
    try std.testing.expectEqualStrings("", model.recoveryPhrase());
    try std.testing.expectEqual(@as(i32, 0), game.camera.tile_x);
    model.phase = .restoring;
    try std.testing.expectEqual(@as(?onboarding.Effect, null), try routeFrame(&game, &model, frame));
}

// ── native entry point ──────────────────────────────────────────────────────

extern "c" fn GetClipboardText() ?[*:0]const u8;

fn pasteRecovery(model: *onboarding.Onboarding, allocator: std.mem.Allocator) void {
    // The raylib Zig wrapper spans the entire string, so use the underlying
    // nullable C API to bound the read before constructing a slice.
    const text = GetClipboardText() orelse return;
    var len: usize = 0;
    while (len <= 1024 and text[len] != 0) : (len += 1) {}
    if (len == 0 or len > 1024) return;
    const payload = allocator.dupe(u8, text[0..len]) catch return;
    model.receive(.{ .paste = payload });
}
fn pasteWithdrawal(state: *@import("menu.zig").Menu) void {
    state.paste_requested = false;
    const text = GetClipboardText() orelse return;
    var len: usize = 0;
    while (len <= 4096 and text[len] != 0) : (len += 1) {}
    if (len > 4096) {
        _ = state.wallet.message.set("Paste refused: invoice exceeds 4096 bytes.");
        return;
    }
    _ = state.pasteWithdrawal(text[0..len]);
}

const NativeEffects = struct {
    allocator: std.mem.Allocator,
    worker: *wallet_service.Worker,

    fn dispatch(context: ?*anyopaque, model: *onboarding.Onboarding, action: onboarding.Effect) void {
        const self: *NativeEffects = @ptrCast(@alignCast(context.?));
        const allocator = self.allocator;
        switch (action) {
            .copy_requested => if (model.mnemonic()) |secret| {
                if (allocator.allocSentinel(u8, secret.len, 0)) |copy| {
                    defer allocator.free(copy);
                    defer std.crypto.secureZero(u8, copy.ptr[0 .. copy.len + 1]);
                    @memcpy(copy, secret);
                    rl.setClipboardText(copy);
                    model.markCopyHandedOff(.copy_seed, rl.getTime());
                } else |_| {
                    std.log.warn("wallet: clipboard request unavailable", .{});
                }
            },
            .copy_word_requested => |index| if (model.mnemonicWord(index)) |word| {
                if (word.len <= 1024) if (allocator.allocSentinel(u8, word.len, 0)) |copy| {
                    defer allocator.free(copy);
                    defer std.crypto.secureZero(u8, copy.ptr[0 .. copy.len + 1]);
                    @memcpy(copy, word);
                    rl.setClipboardText(copy);
                    model.markCopyHandedOff(.{ .copy_word = index }, rl.getTime());
                } else |_| {
                    std.log.warn("wallet: clipboard request unavailable", .{});
                };
            },
            .paste_requested => pasteRecovery(model, allocator),
            .complete_requested, .create_requested, .restore_requested, .retry_requested, .retry_open_requested, .generate_requested, .finish_restore_requested => {
                const operation: wallet_service.NativeOperation = switch (action) {
                    .complete_requested => .complete,
                    .create_requested => .create,
                    .restore_requested => .restore,
                    .retry_requested => .retry,
                    .retry_open_requested => .retry_open,
                    .generate_requested => .generate,
                    .finish_restore_requested => .finish_restore,
                    else => unreachable,
                };
                self.worker.submit(operation, model) catch {
                    model.receive(if (operation == .complete or operation == .finish_restore) .complete_fail else if (operation == .retry_open) .open_failed else .blocked);
                };
            },
        }
    }

    fn afterInput(_: ?*anyopaque, game: *game_mod.GameState) void {
        if (game.menu.paste_requested) pasteWithdrawal(&game.menu);
        if (game.menu.wallet.copy_requested) {
            game.menu.wallet.copy_requested = false;
            if (game.menu.wallet.canCopyInvoice()) rl.setClipboardText(game.menu.wallet.invoice.z());
        }
    }
};

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

    const wallet_paths = try native_wallet.Paths.init(allocator, locations.wallet_dir);
    defer wallet_paths.deinit(allocator);
    const native = native_onboarding.Native{
        .io = io,
        .allocator = allocator,
        .config_dir = locations.config_dir,
        .paths = wallet_paths,
        .standard_parents = locations.standard_parents,
    };
    // One worker exists before the window; startup inspection runs asynchronously.
    const wallet_worker = try wallet_service.Worker.startNative(native);
    defer wallet_worker.stop();

    // ── window ───────────────────────────────────────────────────────────────
    const screen_w = 1000;
    const screen_h = 640;

    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(screen_w, screen_h, "haystack — chunk streaming test");
    if (!rl.isWindowReady()) {
        std.log.err("window initialization failed", .{});
        return error.WindowInitializationFailed;
    }
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

    var model = onboarding.Onboarding.init(allocator);
    defer model.deinit();
    // ── frame loop ───────────────────────────────────────────────────────────
    // Input queue, repeat and derived view belong to this loop, not GameState.
    var input_reader = input.Reader{};
    var driver = frame_loop.Driver{};
    defer driver.deinit();
    var effects = NativeEffects{ .allocator = allocator, .worker = wallet_worker };
    var onboarding_hand_cursor = false;

    while (!rl.windowShouldClose()) {
        const unix = std.Io.Clock.real.now(io).toSeconds();
        if (unix >= 0) game_state.menu.wallet.unix_now = @intCast(unix);
        if (!model.isBlocking() and game_state.menu.paste_requested) {
            driver.invalidateInput();
            pasteWithdrawal(&game_state.menu);
        }
        game_state.menu.wallet.tick(!model.isBlocking(), rl.getTime());
        if (wallet_worker.stepOnboarding(&model)) driver.invalidateInput();
        if (wallet_worker.step(&game_state.menu.wallet, rl.getTime())) driver.invalidateInput();
        if (game_state.menu.wallet.copy_requested) {
            game_state.menu.wallet.copy_requested = false;
            if (game_state.menu.wallet.canCopyInvoice()) rl.setClipboardText(game_state.menu.wallet.invoice.z());
        }
        model.expire(rl.getTime());
        try stepFrame(
            &game_state,
            &input_reader,
            &driver,
            persister,
            &model,
            .{ .context = &effects, .dispatch = NativeEffects.dispatch, .after_input = NativeEffects.afterInput },
        );

        const layout = onboarding.calculateLayout(driver.viewport_w, driver.viewport_h);
        const hand = model.hoverEnabled(layout, model.pointer_x, model.pointer_y);
        if (hand != onboarding_hand_cursor) {
            rl.setMouseCursor(if (hand) .pointing_hand else .default);
            onboarding_hand_cursor = hand;
        }
    }
}
