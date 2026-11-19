//! Device polling only. The loop queues raw samples; modal filtering and repeat
//! happen at consumption, never at presentation frequency.
const std = @import("std");
const rl = @import("raylib");
const stick_deadzone: f32 = 0.25;
const gamepad: i32 = 0;
pub const max_frame_characters = 32;

/// Routed input contract shared by game, menu, camera, and device-free tests.
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
    paste_shortcut: bool = false,
    characters: [max_frame_characters]u21 = @splat(0),
    character_count: usize = 0,
};

pub const Directions = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
};

pub const RawSample = struct {
    frame: FrameInput = .{},
    wasd: Directions = .{},
    navigation: Directions = .{},

    pub fn scrub(self: *RawSample) void {
        std.crypto.secureZero(u21, &self.frame.characters);
        self.frame.character_count = 0;
    }

    /// No edge, text, or delta may survive in the reconciliation snapshot.
    pub fn continuous(self: RawSample) RawSample {
        return .{ .wasd = self.wasd, .navigation = self.navigation, .frame = .{
            .dragging = self.frame.dragging,
            .pointer_x = self.frame.pointer_x,
            .pointer_y = self.frame.pointer_y,
            .viewport_w = self.frame.viewport_w,
            .viewport_h = self.frame.viewport_h,
        } };
    }

    pub fn quiet(self: RawSample) bool {
        const f = self.frame;
        return !f.clicked and !f.escape_clicked and !f.confirm and !f.backspace and
            !f.paste_shortcut and !f.toggle_grid and !f.toggle_borders and
            f.character_count == 0 and f.drag_x == 0 and f.drag_y == 0;
    }
};

pub const Reader = struct {
    pub fn read(_: *Reader) RawSample {
        var sample = RawSample{};
        const held = &sample.frame;
        sample.navigation = .{ .left = rl.isKeyDown(.left), .right = rl.isKeyDown(.right), .up = rl.isKeyDown(.up), .down = rl.isKeyDown(.down) };
        sample.wasd = .{ .left = rl.isKeyDown(.a), .right = rl.isKeyDown(.d), .up = rl.isKeyDown(.w), .down = rl.isKeyDown(.s) };
        held.escape_clicked = rl.isKeyPressed(.escape);
        held.backspace = rl.isKeyPressed(.backspace) or rl.isKeyPressedRepeat(.backspace);
        held.paste_shortcut = (rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control) or rl.isKeyDown(.left_super) or rl.isKeyDown(.right_super)) and rl.isKeyPressed(.v);
        held.confirm = rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter);
        const pointer = rl.getMousePosition();
        held.pointer_x = pointer.x;
        held.pointer_y = pointer.y;
        held.clicked = rl.isMouseButtonPressed(.left);
        held.viewport_w = @floatFromInt(rl.getScreenWidth());
        held.viewport_h = @floatFromInt(rl.getScreenHeight());
        if (rl.isGamepadAvailable(gamepad)) {
            const x = stickAxis(rl.getGamepadAxisMovement(gamepad, .left_x));
            const y = stickAxis(rl.getGamepadAxisMovement(gamepad, .left_y));
            held.escape_clicked = held.escape_clicked or rl.isGamepadButtonPressed(gamepad, .middle_right);
            held.confirm = held.confirm or rl.isGamepadButtonPressed(gamepad, .right_face_down);
            const nav = &sample.navigation;
            nav.left = nav.left or rl.isGamepadButtonDown(gamepad, .left_face_left) or x < 0;
            nav.right = nav.right or rl.isGamepadButtonDown(gamepad, .left_face_right) or x > 0;
            nav.up = nav.up or rl.isGamepadButtonDown(gamepad, .left_face_up) or y < 0;
            nav.down = nav.down or rl.isGamepadButtonDown(gamepad, .left_face_down) or y > 0;
        }
        held.dragging = rl.isMouseButtonDown(.left);
        if (held.dragging) {
            const delta = rl.getMouseDelta();
            held.drag_x = delta.x;
            held.drag_y = delta.y;
        }
        held.toggle_grid = rl.isKeyPressed(.g);
        held.toggle_borders = rl.isKeyPressed(.b);
        while (true) {
            const cp = rl.getCharPressed();
            if (cp <= 0) break;
            if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) continue;
            if (held.character_count == max_frame_characters) continue;
            held.characters[held.character_count] = @intCast(cp);
            held.character_count += 1;
        }
        return sample;
    }
};

/// One allowance per executed tick, not per queued record or elapsed wall time.
pub const Repeater = struct {
    dx: i8 = 0,
    dy: i8 = 0,
    cooldown: u2 = 0,
    used: bool = false,

    pub fn beginTick(self: *Repeater) void {
        self.used = false;
        if (self.cooldown > 0) self.cooldown -= 1;
    }

    pub fn route(self: *Repeater, sample: RawSample, modal: bool) FrameInput {
        var out = sample.frame;
        out.left = false;
        out.right = false;
        out.up = false;
        out.down = false;
        const nav = sample.navigation;
        const wasd = sample.wasd;
        const dx: i8 = @as(i8, @intFromBool(nav.right or (!modal and wasd.right))) - @as(i8, @intFromBool(nav.left or (!modal and wasd.left)));
        const dy: i8 = @as(i8, @intFromBool(nav.down or (!modal and wasd.down))) - @as(i8, @intFromBool(nav.up or (!modal and wasd.up)));
        if ((sample.frame.dragging and !modal) or (dx == 0 and dy == 0)) {
            self.dx = 0;
            self.dy = 0;
            self.cooldown = 0;
            // A world drag suppresses every later direction in this tick.
            if (sample.frame.dragging and !modal) self.used = true;
            return out;
        }
        const changed = dx != self.dx or dy != self.dy;
        self.dx = dx;
        self.dy = dy;
        // A change after this tick's allowance was spent waits for the next
        // tick, not for the previous vector's remaining repeat cooldown.
        if (changed) self.cooldown = 0;
        if (!self.used and (changed or self.cooldown == 0)) {
            out.left = dx < 0;
            out.right = dx > 0;
            out.up = dy < 0;
            out.down = dy > 0;
            self.used = true;
            self.cooldown = 2;
        }
        return out;
    }
};

fn stickAxis(value: f32) i8 {
    if (!std.math.isFinite(value)) return 0;
    if (value <= -stick_deadzone) return -1;
    if (value >= stick_deadzone) return 1;
    return 0;
}

test "held diagonals share ten steps per second; stalls cannot catch up" {
    var repeat = Repeater{};
    var steps: usize = 0;
    for (0..20) |_| {
        repeat.beginTick();
        const f = repeat.route(.{ .navigation = .{ .right = true, .down = true } }, false);
        try std.testing.expectEqual(f.right, f.down);
        steps += @intFromBool(f.right);
    }
    try std.testing.expectEqual(@as(usize, 10), steps);
}

test "one direction allowance covers changes taps opposing neutral and drag" {
    var r = Repeater{};
    r.beginTick();
    try std.testing.expect(r.route(.{ .wasd = .{ .right = true } }, false).right);
    _ = r.route(.{}, false);
    try std.testing.expect(!r.route(.{ .navigation = .{ .left = true } }, false).left);
    r.beginTick();
    try std.testing.expect(!r.route(.{ .navigation = .{ .left = true, .right = true } }, false).right);
    try std.testing.expect(r.route(.{ .navigation = .{ .left = true } }, false).left);
    r.beginTick();
    const drag = r.route(.{ .frame = .{ .dragging = true, .drag_x = 8 }, .navigation = .{ .down = true } }, false);
    try std.testing.expect(!drag.down and drag.drag_x == 8);
    try std.testing.expect(!r.route(.{ .navigation = .{ .down = true } }, false).down);
    r.beginTick();
    try std.testing.expect(r.route(.{ .navigation = .{ .down = true }, .frame = .{ .dragging = true } }, true).down);
}

test "modal WASD filtering and non-direction fields survive all repeat paths" {
    var r = Repeater{};
    var s = RawSample{ .wasd = .{ .down = true }, .frame = .{ .confirm = true, .escape_clicked = true, .backspace = true, .clicked = true, .paste_shortcut = true, .toggle_grid = true, .toggle_borders = true, .pointer_x = 12, .pointer_y = 9, .viewport_w = 800, .viewport_h = 600, .character_count = 2 } };
    s.frame.characters[0] = 'a';
    s.frame.characters[1] = 0x1F600;
    for (0..4) |_| {
        r.beginTick();
        const f = r.route(s, true);
        try std.testing.expect(std.meta.eql(s.frame, f));
    }
    s.navigation.right = true;
    for (0..4) |i| {
        r.beginTick();
        var f = r.route(s, true);
        try std.testing.expectEqual(i % 2 == 0, f.right);
        f.right = false;
        try std.testing.expect(std.meta.eql(s.frame, f));
    }
    s.frame.dragging = true;
    s.frame.drag_y = -6;
    r.beginTick();
    var f = r.route(s, false);
    f.left = s.frame.left;
    f.right = s.frame.right;
    f.up = s.frame.up;
    f.down = s.frame.down;
    try std.testing.expect(std.meta.eql(s.frame, f));
}

test "source changes preserve cadence; deferred vector changes get next tick" {
    var r = Repeater{};
    r.beginTick();
    try std.testing.expect(r.route(.{ .wasd = .{ .right = true } }, false).right);
    // Same vector from a different source does not restart repeat.
    r.beginTick();
    try std.testing.expect(!r.route(.{ .navigation = .{ .right = true } }, false).right);
    r.beginTick();
    try std.testing.expect(r.route(.{ .navigation = .{ .right = true } }, false).right);
    try std.testing.expect(!r.route(.{ .navigation = .{ .left = true, .down = true } }, false).left);
    r.beginTick();
    const latest = r.route(.{ .navigation = .{ .left = true, .down = true } }, false);
    try std.testing.expect(latest.left and latest.down);
}

test "independent stick deadzones reject nonfinite values" {
    for ([_]f32{ 0, 0.24, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |v| try std.testing.expectEqual(@as(i8, 0), stickAxis(v));
    try std.testing.expectEqual(@as(i8, 1), stickAxis(0.25));
    try std.testing.expectEqual(@as(i8, -1), stickAxis(-0.25));
    try std.testing.expect(stickAxis(-1) < 0 and stickAxis(1) > 0);
}
