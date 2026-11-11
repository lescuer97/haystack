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

// `zig build test` collects tests from files referenced by this root module.
// Import every source file explicitly so no test file is silently skipped.
comptime {
    _ = @import("input.zig");
    _ = @import("camera.zig");
    _ = @import("game.zig");
    _ = @import("menu.zig");
    _ = @import("world.zig");
    _ = @import("rendering.zig");
}

pub fn main() anyerror!void {
    const use_debug_allocator = switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    };
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (use_debug_allocator) _ = debug_allocator.deinit();
    }
    const allocator = if (use_debug_allocator) debug_allocator.allocator() else std.heap.c_allocator;

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
    var game_state = try game_mod.GameState.init(
        allocator,
        @floatFromInt(rl.getScreenWidth()),
        @floatFromInt(rl.getScreenHeight()),
    );
    defer game_state.deinit();

    // Optional: HAYSTACK_SHOT=/path.png grabs a frame and exits (handy for CI).
    const shot_path: ?[:0]const u8 = if (std.c.getenv("HAYSTACK_SHOT")) |p| std.mem.span(p) else null;
    var shot_frames: i32 = if (shot_path != null) 5 else -1;
    var shot_pending = false;

    // ── frame loop ───────────────────────────────────────────────────────────
    // The reader owns the held-direction cadence across frames. It is not
    // global; this loop is its only owner.
    var input_reader = input.Reader{};

    while (!rl.windowShouldClose()) {
        const vw: f32 = @floatFromInt(rl.getScreenWidth());
        const vh: f32 = @floatFromInt(rl.getScreenHeight());

        // 1. collect input: this is the only stage that touches devices. dt
        //    only paces held directions; the camera still takes whole-tile
        //    requests. The menu's open state filters WASD out of directions.
        const frame_input = input_reader.read(rl.getFrameTime(), game_state.menu.opened);

        // 2. update persistent state from that input.
        try game_state.update(frame_input);

        // 3. calculate this frame's view. It is temporary; persistent state
        //    does not store a view.
        const view = try camera.calculate(game_state.camera, vw, vh);

        // 4. prepare the resident world chunks for that view.
        try game_state.streamChunks(view.chunks);

        // 5. render read-only state. Screenshot capture waits until after
        //    `endDrawing` presents the frame.
        rl.beginDrawing();
        rendering.draw(&game_state, view, vw, vh);
        rl.endDrawing();

        if (shot_frames >= 0) {
            if (shot_frames == 0) {
                shot_pending = true;
                break;
            }
            shot_frames -= 1;
        }
    }

    if (shot_pending) rl.takeScreenshot(shot_path.?);
}
