//! Physical input collection.
//!
//! This is the only module that polls Raylib devices. It converts one frame of
//! device state into a small plain value. Game rules, camera movement, and
//! rendering never call `isKeyDown`/`isKeyPressed`/`isMouseButtonDown`/
//! `isMouseButtonPressed`/`getMouseDelta`/`getMousePosition`/`getCharPressed`/
//! `isGamepad*`/`getGamepad*` themselves.
//!
//! `Reader` is the tiny piece of persistent input state: it remembers the last
//! emitted direction and how long it has been held, so held keys and controller
//! input can produce one-tile steps on a shared cadence instead of depending on
//! the platform's keyboard auto-repeat. One timer serves every direction
//! consumer: the camera when the menu is closed and the menu when it is open.

const std = @import("std");
const rl = @import("raylib");

/// One shared step cadence for every held direction source: 10 tiles per
/// second. Keys, D-pad, and stick all step together, so a held diagonal keeps
/// both axes on the same grid.
const step_interval: f64 = 0.1;

/// Analog sticks have one deadzone per axis; diagonal deflection is not
/// normalized, so a full diagonal request still moves one tile on each axis.
const stick_deadzone: f32 = 0.25;

/// Only controller 0 is used.
const gamepad: i32 = 0;

/// Most typed Unicode codepoints collected in one frame. Menu text fields are
/// bounded, so the reader drains any extra characters and drops them instead of
/// queueing an unbounded backlog.
pub const max_frame_characters: usize = 32;

/// Everything the game needs to know about this frame's physical input.
///
/// Directions are independent one-tile requests. `Reader` emits at most one on
/// each held axis per step, on a shared 10 steps/s cadence; a diagonal request
/// moves one tile on both axes. Opposing requests on the same axis cancel. The
/// mouse-drag fields are raw pixel deltas for the frame; `dragging` lets the
/// camera give the mouse precedence over keyboard and controller.
///
/// `left`/`right`/`up`/`down` are shared by the camera and the menu. While the
/// menu is open `Reader` collects arrows, D-pad, and the left stick but not
/// WASD, so typing a name never moves the menu selection. `confirm` is a
/// keyboard Enter / gamepad bottom-face edge and is never derived from a held
/// state.
///
/// The pointer and viewport fields are already in screen space, the same space
/// menus are laid out in. `clicked`, `escape_clicked`, `confirm`, and
/// `backspace` are edges (backspace also includes keyboard auto-repeat). Typed
/// text is a bounded array so collection never allocates. Defaults describe the
/// starting window size, which lets tests build a frame without a display.
pub const FrameInput = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
    dragging: bool = false,
    drag_x: f32 = 0,
    drag_y: f32 = 0,
    toggle_grid: bool = false,
    toggle_borders: bool = false,
    escape_clicked: bool = false,
    confirm: bool = false,

    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    clicked: bool = false,
    viewport_w: f32 = 1000,
    viewport_h: f32 = 640,

    backspace: bool = false,
    characters: [max_frame_characters]u21 = @splat(0),
    character_count: usize = 0,
};

/// Persistent input timing. `main` owns one for the lifetime of the frame loop;
/// the camera and game state never see it. Nothing here is global.
pub const Reader = struct {
    /// Last effective signed direction, so a source change that keeps the same
    /// vector does not restart the cadence.
    last_dx: i8 = 0,
    last_dy: i8 = 0,
    /// Time accumulated toward the next step. Reset on neutral and kept
    /// modulo the interval after a step.
    elapsed: f64 = 0,

    /// Read all devices once for the current frame and gate held directions
    /// through `repeat`. `menu_opened` is the only modal context the reader
    /// needs: WASD is world-only, while arrows, D-pad, and the stick always
    /// contribute.
    pub fn read(self: *Reader, dt: f32, menu_opened: bool) FrameInput {
        var held = FrameInput{};

        held.left = heldDirection(rl.isKeyDown(.left), rl.isKeyDown(.a), menu_opened);
        held.right = heldDirection(rl.isKeyDown(.right), rl.isKeyDown(.d), menu_opened);
        held.up = heldDirection(rl.isKeyDown(.up), rl.isKeyDown(.w), menu_opened);
        held.down = heldDirection(rl.isKeyDown(.down), rl.isKeyDown(.s), menu_opened);

        // Escape is an edge, not a held state: it toggles the menu once per
        // press. The gamepad Start button is the same edge.
        held.escape_clicked = rl.isKeyPressed(.escape);
        held.backspace = rl.isKeyPressed(.backspace) or rl.isKeyPressedRepeat(.backspace);

        // Confirm is a keyboard/gamepad edge. Enter (main or keypad) and the
        // bottom face button (A/Cross) activate the selected row.
        held.confirm = rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter);

        const pointer = rl.getMousePosition();
        held.pointer_x = pointer.x;
        held.pointer_y = pointer.y;
        held.clicked = rl.isMouseButtonPressed(.left);
        held.viewport_w = @floatFromInt(rl.getScreenWidth());
        held.viewport_h = @floatFromInt(rl.getScreenHeight());

        if (rl.isGamepadAvailable(gamepad)) {
            const stick_x = stickAxis(rl.getGamepadAxisMovement(gamepad, .left_x));
            const stick_y = stickAxis(rl.getGamepadAxisMovement(gamepad, .left_y));

            // OR rather than assign: a keyboard Escape edge must survive the
            // gamepad poll and vice versa.
            held.escape_clicked = held.escape_clicked or
                rl.isGamepadButtonPressed(gamepad, .middle_right);
            held.confirm = held.confirm or
                rl.isGamepadButtonPressed(gamepad, .right_face_down);

            // OR every source per direction before cancellation: duplicate
            // bindings never multiply a step, and opposite sources cancel.
            held.left = held.left or
                rl.isGamepadButtonDown(gamepad, .left_face_left) or stick_x < 0;
            held.right = held.right or
                rl.isGamepadButtonDown(gamepad, .left_face_right) or stick_x > 0;
            held.up = held.up or
                rl.isGamepadButtonDown(gamepad, .left_face_up) or stick_y < 0;
            held.down = held.down or
                rl.isGamepadButtonDown(gamepad, .left_face_down) or stick_y > 0;
        }

        // Holding the left button drags the world with the cursor.
        held.dragging = rl.isMouseButtonDown(.left);
        if (held.dragging) {
            const delta = rl.getMouseDelta();
            held.drag_x = delta.x;
            held.drag_y = delta.y;
        }

        held.toggle_grid = rl.isKeyPressed(.g);
        held.toggle_borders = rl.isKeyPressed(.b);

        // Drain this frame's Unicode queue without allocating. Characters past
        // the fixed capacity are dropped, not carried into the next frame.
        while (true) {
            const codepoint = rl.getCharPressed();
            if (codepoint <= 0) break;
            if (codepoint > 0x10FFFF) continue;
            if (codepoint >= 0xD800 and codepoint <= 0xDFFF) continue;
            if (held.character_count == max_frame_characters) continue;
            held.characters[held.character_count] = @intCast(codepoint);
            held.character_count += 1;
        }

        return self.repeat(held, dt, menu_opened);
    }

    /// Turn raw held directions into at most one one-step request this frame.
    /// Pure with respect to hardware, so tests can drive it directly.
    ///
    /// Every non-direction field (pointer, clicks, viewport, typed text,
    /// confirm) is copied through unchanged on every path. One timer serves
    /// both modes. A mouse drag is a world gesture: with the menu closed it
    /// suppresses and resets the cadence, while with the menu open directions
    /// still navigate as the button is held.
    ///
    /// ponytail: at most one step per frame; missed whole steps after a stall
    /// are dropped rather than queued. If catch-up below 10 FPS ever matters,
    /// the upgrade is a step count plus a fixed update loop, not a bigger timer.
    fn repeat(self: *Reader, held: FrameInput, dt: f32, menu_opened: bool) FrameInput {
        var out = held;
        out.left = false;
        out.right = false;
        out.up = false;
        out.down = false;

        if (held.dragging and !menu_opened) {
            self.reset();
            return out;
        }

        // Cancel each axis before comparing vectors. All four flags held is
        // neutral, not a diagonal.
        const dx: i8 = @as(i8, @intFromBool(held.right)) -
            @as(i8, @intFromBool(held.left));
        const dy: i8 = @as(i8, @intFromBool(held.down)) -
            @as(i8, @intFromBool(held.up));

        if (dx == 0 and dy == 0) {
            self.reset();
            return out;
        }

        var emit = false;
        if (dx != self.last_dx or dy != self.last_dy) {
            // A new direction steps immediately; its frame's dt is not counted.
            self.last_dx = dx;
            self.last_dy = dy;
            self.elapsed = 0;
            emit = true;
        } else {
            if (std.math.isFinite(dt) and dt > 0) self.elapsed += @as(f64, dt);
            if (self.elapsed >= step_interval) {
                // Keep only the overshoot; a long stall cannot queue a burst.
                self.elapsed = @mod(self.elapsed, step_interval);
                emit = true;
            }
        }

        if (emit) {
            out.left = dx < 0;
            out.right = dx > 0;
            out.up = dy < 0;
            out.down = dy > 0;
        }
        return out;
    }

    fn reset(self: *Reader) void {
        self.last_dx = 0;
        self.last_dy = 0;
        self.elapsed = 0;
    }
};

/// One key direction: an arrow always contributes, while its WASD equivalent
/// only contributes when no menu is open (so letters stay typing keys).
fn heldDirection(arrow: bool, wasd: bool, menu_opened: bool) bool {
    return arrow or (wasd and !menu_opened);
}

/// Map one analog axis to a held digital direction. Non-finite values are
/// neutral so a broken device cannot move the camera.
fn stickAxis(value: f32) i8 {
    if (!std.math.isFinite(value)) return 0;
    if (value <= -stick_deadzone) return -1;
    if (value >= stick_deadzone) return 1;
    return 0;
}

// ── tests ────────────────────────────────────────────────────────────────────

test "held diagonal steps both axes immediately then on one cadence" {
    var reader = Reader{};
    const held = FrameInput{ .right = true, .down = true };

    var frame = reader.repeat(held, 0.016, false);
    try std.testing.expect(frame.right);
    try std.testing.expect(frame.down);
    try std.testing.expect(!frame.left);
    try std.testing.expect(!frame.up);

    // The immediate step did not count its frame's dt.
    frame = reader.repeat(held, 0.05, false);
    try std.testing.expect(!frame.right and !frame.down);

    // Both axes cross the shared 0.1 s cadence together.
    frame = reader.repeat(held, 0.06, false);
    try std.testing.expect(frame.right and frame.down);
}

test "same effective vector keeps its cadence and retains overshoot" {
    var reader = Reader{};
    _ = reader.repeat(.{ .right = true }, 0, false);

    // Keyboard, D-pad, and stick are already merged into the same flag, so a
    // source switch that keeps the vector also takes this branch: no reset.
    // 0.12 s emits once and keeps about 0.02 s for the next step.
    var frame = reader.repeat(.{ .right = true }, 0.12, false);
    try std.testing.expect(frame.right);
    frame = reader.repeat(.{ .right = true }, 0.07, false);
    try std.testing.expect(!frame.right);
    frame = reader.repeat(.{ .right = true }, 0.02, false);
    try std.testing.expect(frame.right);
}

test "changing direction steps immediately while neutral or drag resets" {
    var reader = Reader{};
    var frame = reader.repeat(.{ .right = true }, 0, false);
    try std.testing.expect(frame.right);
    frame = reader.repeat(.{ .right = true }, 0.06, false);
    try std.testing.expect(!frame.right);

    // The new diagonal emits at once, without counting this frame's dt.
    frame = reader.repeat(.{ .right = true, .down = true }, 0.01, false);
    try std.testing.expect(frame.right and frame.down and !frame.up);

    // Release resets the timer, so the next press steps immediately.
    frame = reader.repeat(.{}, 0.01, false);
    try std.testing.expect(!frame.right and !frame.down);
    frame = reader.repeat(.{ .down = true }, 0.01, false);
    try std.testing.expect(frame.down);

    // Dragging emits no directions, resets the cadence, and passes deltas on.
    frame = reader.repeat(.{ .left = true, .dragging = true, .drag_x = 8 }, 0.01, false);
    try std.testing.expect(!frame.left);
    try std.testing.expect(frame.dragging);
    try std.testing.expectEqual(@as(f32, 8), frame.drag_x);
    frame = reader.repeat(.{ .left = true }, 0.01, false);
    try std.testing.expect(frame.left);
}

test "opposing held directions cancel and reset the cadence" {
    var reader = Reader{};
    _ = reader.repeat(.{ .right = true }, 0, false);

    // A long frame while cancelled must not queue a step on either axis. All
    // four held is neutral, not a diagonal.
    const cancelled = reader.repeat(.{
        .left = true,
        .right = true,
        .up = true,
        .down = true,
    }, 0.3, false);
    try std.testing.expect(!cancelled.left and !cancelled.right);
    try std.testing.expect(!cancelled.up and !cancelled.down);

    // The reset timer makes the next real diagonal immediate on both axes.
    const again = reader.repeat(.{ .right = true, .down = true }, 0, false);
    try std.testing.expect(again.right and again.down);
}

test "invalid dt never advances the cadence" {
    var reader = Reader{};
    _ = reader.repeat(.{ .left = true }, 0, false);

    const bad = [_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };
    for (bad) |dt| {
        const frame = reader.repeat(.{ .left = true }, dt, false);
        try std.testing.expect(!frame.left);
    }

    const frame = reader.repeat(.{ .left = true }, 0.1, false);
    try std.testing.expect(frame.left);
}

test "a long stall emits one step and drops the backlog" {
    var reader = Reader{};
    _ = reader.repeat(.{ .up = true }, 0, false);

    // 0.35 s is several intervals, but only one request is emitted per frame.
    var frame = reader.repeat(.{ .up = true }, 0.35, false);
    try std.testing.expect(frame.up);
    frame = reader.repeat(.{ .up = true }, 0.001, false);
    try std.testing.expect(!frame.up);

    // The remainder from 0.35 s still counts toward the next step.
    frame = reader.repeat(.{ .up = true }, 0.06, false);
    try std.testing.expect(frame.up);
}

test "repeat preserves UI fields on emit, wait, neutral, and drag paths" {
    var reader = Reader{};
    var held = FrameInput{
        .right = true,
        .escape_clicked = true,
        .confirm = true,
        .clicked = true,
        .pointer_x = 12.5,
        .pointer_y = -4,
        .viewport_w = 1280,
        .viewport_h = 720,
        .backspace = true,
        .character_count = 2,
    };
    held.characters[0] = 'a';
    held.characters[1] = 0x1F600;

    // New direction: the direction flag is emitted, UI fields are untouched.
    var frame = reader.repeat(held, 0, false);
    try std.testing.expect(frame.right);
    try expectSameUi(held, frame);

    // Same direction before the cadence: no direction flag, UI fields intact.
    frame = reader.repeat(held, 0.01, false);
    try std.testing.expect(!frame.right);
    try expectSameUi(held, frame);

    // Neutral release takes its own early return.
    const neutral = FrameInput{
        .escape_clicked = true,
        .confirm = true,
        .clicked = true,
        .pointer_x = 7,
        .pointer_y = 9,
        .viewport_w = 800,
        .viewport_h = 600,
        .backspace = true,
        .character_count = 1,
    };
    frame = reader.repeat(neutral, 0.5, false);
    try std.testing.expect(!frame.left and !frame.right and !frame.up and !frame.down);
    try expectSameUi(neutral, frame);

    // Dragging also early-returns, but must carry the deltas and UI fields.
    var drag = held;
    drag.dragging = true;
    drag.drag_x = 4;
    drag.drag_y = -6;
    frame = reader.repeat(drag, 0.5, false);
    try std.testing.expect(!frame.right);
    try std.testing.expect(frame.dragging);
    try std.testing.expectEqual(@as(f32, 4), frame.drag_x);
    try std.testing.expectEqual(@as(f32, -6), frame.drag_y);
    try expectSameUi(drag, frame);
}

fn expectSameUi(expected: FrameInput, actual: FrameInput) !void {
    try std.testing.expectEqual(expected.escape_clicked, actual.escape_clicked);
    try std.testing.expectEqual(expected.confirm, actual.confirm);
    try std.testing.expectEqual(expected.clicked, actual.clicked);
    try std.testing.expectEqual(expected.pointer_x, actual.pointer_x);
    try std.testing.expectEqual(expected.pointer_y, actual.pointer_y);
    try std.testing.expectEqual(expected.viewport_w, actual.viewport_w);
    try std.testing.expectEqual(expected.viewport_h, actual.viewport_h);
    try std.testing.expectEqual(expected.backspace, actual.backspace);
    try std.testing.expectEqual(expected.character_count, actual.character_count);
    try std.testing.expectEqualSlices(u21, &expected.characters, &actual.characters);
    try std.testing.expectEqual(expected.toggle_grid, actual.toggle_grid);
    try std.testing.expectEqual(expected.toggle_borders, actual.toggle_borders);
}

test "one cadence serves both modes and drag only suppresses the world" {
    var reader = Reader{};

    // A held direction steps immediately in the world...
    var frame = reader.repeat(.{ .down = true }, 0, false);
    try std.testing.expect(frame.down);

    // ...and the same vector continues the same timer after the menu opens.
    frame = reader.repeat(.{ .down = true }, 0.05, true);
    try std.testing.expect(!frame.down);
    frame = reader.repeat(.{ .down = true }, 0.05, true);
    try std.testing.expect(frame.down);

    // Dragging is a world gesture: with the menu open the button can stay held
    // while directions keep navigating.
    var menu_reader = Reader{};
    frame = menu_reader.repeat(.{ .down = true, .dragging = true }, 0, true);
    try std.testing.expect(frame.down and frame.dragging);

    // With the menu closed the same drag suppresses and resets the cadence.
    var world_reader = Reader{};
    frame = world_reader.repeat(.{
        .left = true,
        .dragging = true,
        .drag_x = 8,
    }, 0, false);
    try std.testing.expect(!frame.left and frame.dragging);
    try std.testing.expectEqual(@as(f32, 8), frame.drag_x);
    frame = world_reader.repeat(.{ .left = true }, 0, false);
    try std.testing.expect(frame.left);
}

test "WASD contributes only while the menu is closed" {
    // Arrow keys always contribute, including alongside a filtered WASD key.
    try std.testing.expect(heldDirection(true, false, true));
    try std.testing.expect(heldDirection(true, true, true));

    // A WASD key is invisible to the menu, so typing cannot move the highlight.
    try std.testing.expect(!heldDirection(false, true, true));

    // With the menu closed WASD is an ordinary world direction.
    try std.testing.expect(heldDirection(false, true, false));
}

test "stick axes use independent deadzones and reject non-finite values" {
    try std.testing.expectEqual(@as(i8, 0), stickAxis(0));
    try std.testing.expectEqual(@as(i8, 0), stickAxis(0.24));
    try std.testing.expectEqual(@as(i8, 1), stickAxis(0.25));
    try std.testing.expectEqual(@as(i8, -1), stickAxis(-0.25));
    try std.testing.expectEqual(@as(i8, 1), stickAxis(1));
    try std.testing.expectEqual(@as(i8, 0), stickAxis(std.math.nan(f32)));
    try std.testing.expectEqual(@as(i8, 0), stickAxis(std.math.inf(f32)));
    try std.testing.expectEqual(@as(i8, 0), stickAxis(-std.math.inf(f32)));

    // Only the deflected axis requests a tile: deflection is per axis, not a
    // normalized magnitude.
    const x = stickAxis(-0.9);
    const y = stickAxis(0.1);
    try std.testing.expect(x < 0);
    try std.testing.expectEqual(@as(i8, 0), y);

    // A full diagonal requests one tile on both axes.
    var held = FrameInput{};
    held.left = stickAxis(-1) < 0;
    held.down = stickAxis(1) > 0;
    var reader = Reader{};
    const frame = reader.repeat(held, 0, false);
    try std.testing.expect(frame.left and frame.down);
}
