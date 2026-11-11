//! Physical input collection.
//!
//! This is the only module that polls Raylib devices. It converts one frame of
//! device state into a small plain value. Game rules, camera movement, and
//! rendering never call `isKeyDown`/`isKeyPressed`/`isMouseButtonDown`/
//! `getMouseDelta`/`isGamepad*`/`getGamepad*` themselves.
//!
//! `Reader` is the tiny piece of persistent input state: it remembers the last
//! emitted direction and how long that direction has been held, so held keys
//! and controller input can produce one-tile steps on a shared cadence instead
//! of depending on the platform's keyboard auto-repeat.

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

/// Everything the game needs to know about this frame's physical input.
///
/// Directions are independent one-tile requests. `Reader` emits at most one on
/// each held axis per step, on a shared 10 steps/s cadence; a diagonal request
/// moves one tile on both axes. Opposing requests on the same axis cancel. The
/// mouse-drag fields are raw pixel deltas for the frame; `dragging` lets the
/// camera give the mouse precedence over keyboard and controller.
pub const FrameInput = struct {
    pan_left: bool = false,
    pan_right: bool = false,
    pan_up: bool = false,
    pan_down: bool = false,
    dragging: bool = false,
    drag_x: f32 = 0,
    drag_y: f32 = 0,
    toggle_grid: bool = false,
    toggle_borders: bool = false,
};

/// Persistent input timing. `main` owns one for the lifetime of the frame loop;
/// the camera and game state never see it. Nothing here is global.
pub const Reader = struct {
    /// Last effective signed direction, so a source change that keeps the same
    /// vector does not restart the cadence.
    last_dx: i8 = 0,
    last_dy: i8 = 0,
    /// Time accumulated toward the next step. Reset on neutral/drag and kept
    /// modulo the interval after a step.
    elapsed: f64 = 0,

    /// Read all devices once for the current frame and gate held directions
    /// through `repeat`.
    pub fn read(self: *Reader, dt: f32) FrameInput {
        var held = FrameInput{};

        held.pan_left = rl.isKeyDown(.left) or rl.isKeyDown(.a);
        held.pan_right = rl.isKeyDown(.right) or rl.isKeyDown(.d);
        held.pan_up = rl.isKeyDown(.up) or rl.isKeyDown(.w);
        held.pan_down = rl.isKeyDown(.down) or rl.isKeyDown(.s);

        if (rl.isGamepadAvailable(gamepad)) {
            const stick_x = stickAxis(rl.getGamepadAxisMovement(gamepad, .left_x));
            const stick_y = stickAxis(rl.getGamepadAxisMovement(gamepad, .left_y));

            // OR every source per direction before cancellation: duplicate
            // bindings never multiply a step, and opposite sources cancel.
            held.pan_left = held.pan_left or
                rl.isGamepadButtonDown(gamepad, .left_face_left) or stick_x < 0;
            held.pan_right = held.pan_right or
                rl.isGamepadButtonDown(gamepad, .left_face_right) or stick_x > 0;
            held.pan_up = held.pan_up or
                rl.isGamepadButtonDown(gamepad, .left_face_up) or stick_y < 0;
            held.pan_down = held.pan_down or
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

        return self.repeat(held, dt);
    }

    /// Turn raw held directions into at most one one-tile request this frame.
    /// Pure with respect to hardware, so tests can drive it directly.
    ///
    /// ponytail: at most one step per frame; missed whole steps after a stall
    /// are dropped rather than queued. If catch-up below 10 FPS ever matters,
    /// the upgrade is a step count plus a fixed update loop, not a bigger timer.
    fn repeat(self: *Reader, held: FrameInput, dt: f32) FrameInput {
        var out = FrameInput{
            .dragging = held.dragging,
            .drag_x = held.drag_x,
            .drag_y = held.drag_y,
            .toggle_grid = held.toggle_grid,
            .toggle_borders = held.toggle_borders,
        };

        // Cancel each axis before comparing vectors. All four flags held is
        // neutral, not a diagonal.
        const dx: i8 = @as(i8, @intFromBool(held.pan_right)) -
            @as(i8, @intFromBool(held.pan_left));
        const dy: i8 = @as(i8, @intFromBool(held.pan_down)) -
            @as(i8, @intFromBool(held.pan_up));

        if (held.dragging or (dx == 0 and dy == 0)) {
            self.last_dx = 0;
            self.last_dy = 0;
            self.elapsed = 0;
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

        if (!emit) return out;

        out.pan_left = dx < 0;
        out.pan_right = dx > 0;
        out.pan_up = dy < 0;
        out.pan_down = dy > 0;
        return out;
    }
};

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
    const held = FrameInput{ .pan_right = true, .pan_down = true };

    var frame = reader.repeat(held, 0.016);
    try std.testing.expect(frame.pan_right);
    try std.testing.expect(frame.pan_down);
    try std.testing.expect(!frame.pan_left);
    try std.testing.expect(!frame.pan_up);

    // The immediate step did not count its frame's dt.
    frame = reader.repeat(held, 0.05);
    try std.testing.expect(!frame.pan_right and !frame.pan_down);

    // Both axes cross the shared 0.1 s cadence together.
    frame = reader.repeat(held, 0.06);
    try std.testing.expect(frame.pan_right and frame.pan_down);
}

test "same effective vector keeps its cadence and retains overshoot" {
    var reader = Reader{};
    _ = reader.repeat(.{ .pan_right = true }, 0);

    // Keyboard, D-pad, and stick are already merged into the same flag, so a
    // source switch that keeps the vector also takes this branch: no reset.
    // 0.12 s emits once and keeps about 0.02 s for the next step.
    var frame = reader.repeat(.{ .pan_right = true }, 0.12);
    try std.testing.expect(frame.pan_right);
    frame = reader.repeat(.{ .pan_right = true }, 0.07);
    try std.testing.expect(!frame.pan_right);
    frame = reader.repeat(.{ .pan_right = true }, 0.02);
    try std.testing.expect(frame.pan_right);
}

test "changing direction steps immediately while neutral or drag resets" {
    var reader = Reader{};
    var frame = reader.repeat(.{ .pan_right = true }, 0);
    try std.testing.expect(frame.pan_right);
    frame = reader.repeat(.{ .pan_right = true }, 0.06);
    try std.testing.expect(!frame.pan_right);

    // The new diagonal emits at once, without counting this frame's dt.
    frame = reader.repeat(.{ .pan_right = true, .pan_down = true }, 0.01);
    try std.testing.expect(frame.pan_right and frame.pan_down and !frame.pan_up);

    // Release resets the timer, so the next press steps immediately.
    frame = reader.repeat(.{}, 0.01);
    try std.testing.expect(!frame.pan_right and !frame.pan_down);
    frame = reader.repeat(.{ .pan_down = true }, 0.01);
    try std.testing.expect(frame.pan_down);

    // Dragging emits no directions, resets the cadence, and passes deltas on.
    frame = reader.repeat(.{ .pan_left = true, .dragging = true, .drag_x = 8 }, 0.01);
    try std.testing.expect(!frame.pan_left);
    try std.testing.expect(frame.dragging);
    try std.testing.expectEqual(@as(f32, 8), frame.drag_x);
    frame = reader.repeat(.{ .pan_left = true }, 0.01);
    try std.testing.expect(frame.pan_left);
}

test "opposing held directions cancel and reset the cadence" {
    var reader = Reader{};
    _ = reader.repeat(.{ .pan_right = true }, 0);

    // A long frame while cancelled must not queue a step on either axis.
    const cancelled = reader.repeat(.{ .pan_left = true, .pan_right = true }, 0.3);
    try std.testing.expect(!cancelled.pan_left and !cancelled.pan_right);

    // The reset timer makes the next real press immediate.
    const again = reader.repeat(.{ .pan_right = true }, 0);
    try std.testing.expect(again.pan_right);
}

test "invalid dt never advances the cadence" {
    var reader = Reader{};
    _ = reader.repeat(.{ .pan_left = true }, 0);

    const bad = [_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };
    for (bad) |dt| {
        const frame = reader.repeat(.{ .pan_left = true }, dt);
        try std.testing.expect(!frame.pan_left);
    }

    const frame = reader.repeat(.{ .pan_left = true }, 0.1);
    try std.testing.expect(frame.pan_left);
}

test "a long stall emits one step and drops the backlog" {
    var reader = Reader{};
    _ = reader.repeat(.{ .pan_up = true }, 0);

    // 0.35 s is several intervals, but only one request is emitted per frame.
    var frame = reader.repeat(.{ .pan_up = true }, 0.35);
    try std.testing.expect(frame.pan_up);
    frame = reader.repeat(.{ .pan_up = true }, 0.001);
    try std.testing.expect(!frame.pan_up);

    // The remainder from 0.35 s still counts toward the next step.
    frame = reader.repeat(.{ .pan_up = true }, 0.06);
    try std.testing.expect(frame.pan_up);
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
    held.pan_left = stickAxis(-1) < 0;
    held.pan_down = stickAxis(1) > 0;
    var reader = Reader{};
    const frame = reader.repeat(held, 0);
    try std.testing.expect(frame.pan_left and frame.pan_down);
}
