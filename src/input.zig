//! Physical input collection.
//!
//! This is the only module that polls Raylib devices. It converts one frame of
//! device state into a small plain value. Game rules, camera movement, and
//! rendering never call `isKeyDown`/`getMouseDelta` themselves.

const rl = @import("raylib");

/// Everything the game needs to know about this frame's physical input.
///
/// Directions are independent boolean requests, not a collapsed axis or speed.
/// The camera applies them in the original order so opposing keys keep the old
/// sequential f32 behaviour, including its rounding at large coordinates. The
/// mouse-drag fields are raw pixel deltas for the frame; `dragging` lets the
/// camera give the mouse precedence over the keyboard.
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

/// Read all devices once for the current frame.
pub fn read() FrameInput {
    var frame = FrameInput{};

    frame.pan_left = rl.isKeyDown(.left) or rl.isKeyDown(.a);
    frame.pan_right = rl.isKeyDown(.right) or rl.isKeyDown(.d);
    frame.pan_up = rl.isKeyDown(.up) or rl.isKeyDown(.w);
    frame.pan_down = rl.isKeyDown(.down) or rl.isKeyDown(.s);

    // Holding the left button drags the world with the cursor.
    frame.dragging = rl.isMouseButtonDown(.left);
    if (frame.dragging) {
        const delta = rl.getMouseDelta();
        frame.drag_x = delta.x;
        frame.drag_y = delta.y;
    }

    frame.toggle_grid = rl.isKeyPressed(.g);
    frame.toggle_borders = rl.isKeyPressed(.b);

    return frame;
}
