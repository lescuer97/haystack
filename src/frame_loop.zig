//! Loop-owned 20 Hz driver. Presentation and real-time wallet plumbing live
//! outside this module. No interpolation, catch-up, device polling, or sleeps.
const std = @import("std");
const tick = @import("shared").tick;
const input = @import("input.zig");
const camera = @import("camera.zig");
const game_mod = @import("game.zig");
const onboarding = @import("onboarding.zig");
const menu_mod = @import("menu.zig");

pub const capacity = 64;
pub const EffectSink = struct {
    context: ?*anyopaque = null,
    dispatch: *const fn (?*anyopaque, *onboarding.Onboarding, onboarding.Effect) void,
    // Native clipboard work must run before the next ordered record too.
    after_input: ?*const fn (?*anyopaque, *game_mod.GameState) void = null,
};

pub const Queue = struct {
    samples: [capacity]input.RawSample = @splat(.{}),
    head: usize = 0,
    len: usize = 0,
    latest: input.RawSample = .{},

    /// Takes ownership of the sample, including on overflow. Drop newest WHOLE
    /// records, never merge edges. Reconciliation still sees physical releases.
    pub fn push(self: *Queue, sample: *input.RawSample) void {
        defer sample.scrub();
        self.latest = sample.continuous();
        if (self.len > 0) {
            const last = &self.samples[(self.head + self.len - 1) % capacity];
            if (sample.quiet() and last.quiet() and
                std.meta.eql(sample.wasd, last.wasd) and
                std.meta.eql(sample.navigation, last.navigation) and
                sample.frame.dragging == last.frame.dragging)
            {
                last.* = self.latest;
                return;
            }
        }
        if (self.len == capacity) return;
        self.samples[(self.head + self.len) % capacity] = sample.*;
        self.len += 1;
    }

    pub fn pop(self: *Queue) ?input.RawSample {
        if (self.len == 0) return null;
        const out = self.samples[self.head];
        self.samples[self.head].scrub();
        self.samples[self.head] = .{};
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        return out;
    }

    pub fn clear(self: *Queue) void {
        for (&self.samples) |*s| {
            s.scrub();
            s.* = .{};
        }
        self.head = 0;
        self.len = 0;
        self.latest = .{};
    }
};

const Routing = struct {
    phase: ?onboarding.Phase,
    attempt: u64,
    opened: bool,
    page: menu_mod.MenuPage,
    focus: ?menu_mod.InputField,
    confirm_withdrawal: bool,
    copy_invoice: bool,

    fn get(game: *const game_mod.GameState, model: ?*const onboarding.Onboarding) Routing {
        return .{ .phase = if (model) |m| m.phase else null, .attempt = if (model) |m| m.attempt_id else 0, .opened = game.menu.opened, .page = game.menu.currentPage, .focus = game.menu.focus, .confirm_withdrawal = game.menu.wallet.canConfirmWithdrawal(), .copy_invoice = game.menu.wallet.canCopyInvoice() };
    }
};

pub const Driver = struct {
    schedule: tick.Schedule = .{},
    queue: Queue = .{},
    repeat: input.Repeater = .{},
    view: ?camera.View = null,
    viewport_w: f32 = 1000,
    viewport_h: f32 = 640,
    routing: ?Routing = null,

    pub fn deinit(self: *Driver) void {
        self.queue.clear();
        self.repeat = .{};
    }

    /// Explicit for accepted external content replacements. Not called for
    /// input-driven modal changes: later records must see those in order.
    pub fn invalidateInput(self: *Driver) void {
        self.queue.clear();
        self.repeat = .{};
    }

    /// Backstop called BEFORE capture, also on skipped ticks.
    pub fn observeRouting(self: *Driver, game: *const game_mod.GameState, model: ?*const onboarding.Onboarding) void {
        const current = Routing.get(game, model);
        if (self.routing) |old| if (!std.meta.eql(old, current)) self.invalidateInput();
        self.routing = current;
    }

    pub fn prepare(self: *Driver, game: *game_mod.GameState, width: f32, height: f32) !void {
        const view = try camera.calculate(game.camera, width, height);
        try game.streamChunks(view.chunks);
        self.view = view;
        self.viewport_w = width;
        self.viewport_h = height;
    }

    /// No time-based animations currently exist. If added, advance them ONCE
    /// here using tick.dt_seconds, not once per drained input record.
    pub fn advance(self: *Driver, seconds: f64, game: *game_mod.GameState, model: ?*onboarding.Onboarding, sink: ?EffectSink, privacy_blocked: *bool) !bool {
        const now = clockNanoseconds(seconds) orelse return false;
        if (!self.schedule.poll(now)) return false;
        self.repeat.beginTick();
        while (self.queue.pop()) |value| {
            var sample = value;
            defer sample.scrub();
            try self.consume(sample, game, model, sink, privacy_blocked);
        }
        // Includes a dropped release, but NEVER a dropped edge/text/delta.
        try self.consume(self.queue.latest, game, model, sink, privacy_blocked);
        try self.prepare(game, self.queue.latest.frame.viewport_w, self.queue.latest.frame.viewport_h);
        self.routing = Routing.get(game, model);
        return true;
    }

    fn consume(self: *Driver, sample: input.RawSample, game: *game_mod.GameState, model: ?*onboarding.Onboarding, sink: ?EffectSink, privacy_blocked: *bool) !void {
        if (model) |m| privacy_blocked.* = privacy_blocked.* or m.isBlocking();
        const modal = game.menu.opened or (if (model) |m| m.isBlocking() else false);
        var frame = self.repeat.route(sample, modal);
        defer std.crypto.secureZero(u21, &frame.characters);
        const effect = try routeFrame(game, model, frame);
        if (model) |m| {
            privacy_blocked.* = privacy_blocked.* or m.isBlocking();
            if (effect) |e| if (sink) |s| s.dispatch(s.context, m, e);
            privacy_blocked.* = privacy_blocked.* or m.isBlocking();
        }
        if (sink) |s| if (s.after_input) |after| after(s.context, game);
    }

    pub fn skipPast(self: *Driver, seconds: f64) void {
        if (clockNanoseconds(seconds)) |now| self.schedule.skipPast(now);
    }
};

pub fn clockNanoseconds(seconds: f64) ?i128 {
    if (!std.math.isFinite(seconds) or seconds < 0) return null;
    const ns = seconds * std.time.ns_per_s;
    // maxInt(i128) rounds UP in f64. Use the exclusive power-of-two bound.
    if (!std.math.isFinite(ns) or ns >= 0x1p127) return null;
    return @intFromFloat(ns);
}

pub fn routeFrame(game: *game_mod.GameState, model: ?*onboarding.Onboarding, frame: input.FrameInput) !?onboarding.Effect {
    if (model) |m| {
        const result = m.applyInput(.{
            .pointer_x = frame.pointer_x,
            .pointer_y = frame.pointer_y,
            .viewport_w = frame.viewport_w,
            .viewport_h = frame.viewport_h,
            .clicked = frame.clicked,
            .up = frame.up,
            .down = frame.down,
            .confirm = frame.confirm,
            .escape_clicked = frame.escape_clicked,
            .characters = frame.characters,
            .character_count = frame.character_count,
            .backspace = frame.backspace,
            .paste_shortcut = frame.paste_shortcut,
        });
        if (result.consumed) return result.effect;
    }
    try game.update(frame);
    return null;
}

test "finite clock adapter bounds before conversion" {
    for ([_]f64{ -1, std.math.nan(f64), std.math.inf(f64), 0x1p127 }) |bad| try std.testing.expect(clockNanoseconds(bad) == null);
    try std.testing.expectEqual(@as(?i128, 50_000_000), clockNanoseconds(0.05));
}

test "bounded ordered queue scrubs consumed dropped and discarded recovery text" {
    var q = Queue{};
    for (0..capacity) |_| {
        var s = input.RawSample{ .frame = .{ .character_count = 1, .confirm = true } };
        s.frame.characters[0] = 's';
        q.push(&s);
        try std.testing.expect(std.mem.allEqual(u21, &s.frame.characters, 0));
    }
    var dropped = input.RawSample{ .frame = .{ .escape_clicked = true, .character_count = 1 } };
    dropped.frame.characters[0] = 'x';
    q.push(&dropped);
    try std.testing.expectEqual(capacity, q.len);
    try std.testing.expect(std.mem.allEqual(u21, &dropped.frame.characters, 0));
    try std.testing.expect(q.latest.quiet());
    var first = q.pop().?;
    first.scrub();
    try std.testing.expect(std.mem.allEqual(u21, &q.samples[0].frame.characters, 0));
    q.clear();
    for (q.samples) |s| try std.testing.expect(std.mem.allEqual(u21, &s.frame.characters, 0));
}

test "quiet coalescing keeps held changes and drag release order" {
    var q = Queue{};
    defer q.clear();
    var s = input.RawSample{ .navigation = .{ .right = true } };
    q.push(&s);
    s.frame.pointer_x = 42;
    q.push(&s);
    try std.testing.expectEqual(@as(usize, 1), q.len);
    try std.testing.expectEqual(@as(f32, 42), q.samples[0].frame.pointer_x);
    s.frame.dragging = true;
    s.frame.drag_x = 3;
    q.push(&s);
    s.frame.drag_x = 0;
    s.frame.dragging = false;
    q.push(&s);
    try std.testing.expectEqual(@as(usize, 3), q.len);
}

test "120 and 144 presentation frames produce the same twenty updates and ten steps" {
    for ([_]usize{ 120, 144 }) |fps| {
        var driver = Driver{};
        defer driver.deinit();
        var game = try game_mod.GameState.init(std.testing.allocator, 1000, 640);
        defer game.deinit();
        var updates: usize = 0;
        var privacy = false;
        for (0..fps) |i| {
            var s = input.RawSample{ .navigation = .{ .right = true } };
            driver.queue.push(&s);
            updates += @intFromBool(try driver.advance(@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(fps)), &game, null, null, &privacy));
        }
        try std.testing.expectEqual(@as(usize, 20), updates);
        try std.testing.expectEqual(@as(i32, 10), game.camera.tile_x);
    }
}

fn pushFrame(driver: *Driver, frame: input.FrameInput) void {
    var sample = input.RawSample{ .frame = frame };
    driver.queue.push(&sample);
}

test "no between-tick updates; initial preparation and viewport remain coherent" {
    var d = Driver{};
    defer d.deinit();
    var g = try game_mod.GameState.init(std.testing.allocator, 1000, 640);
    defer g.deinit();
    var privacy = false;
    try d.prepare(&g, 1000, 640);
    pushFrame(&d, .{ .toggle_grid = true, .viewport_w = 1200, .viewport_h = 700 });
    const settings = g.settings;
    try std.testing.expect(!try d.advance(std.math.nan(f64), &g, null, null, &privacy));
    try std.testing.expect(std.meta.eql(settings, g.settings));
    try std.testing.expect(d.view != null and d.viewport_w == 1000);
    try std.testing.expect(try d.advance(0, &g, null, null, &privacy));
    try std.testing.expect(d.viewport_w == 1200 and d.viewport_h == 700);
    const view = d.view.?;
    pushFrame(&d, .{ .toggle_grid = true, .viewport_w = 800 });
    try std.testing.expect(!try d.advance(0.049, &g, null, null, &privacy));
    try std.testing.expect(std.meta.eql(view, d.view.?));
    try std.testing.expect(d.viewport_w == 1200);
    try std.testing.expect(try d.advance(0.05, &g, null, null, &privacy));
    try std.testing.expect(std.meta.eql(settings, g.settings));
    try std.testing.expect(d.viewport_w == 800);
}

test "short tap survives release and many taps permit at most one step per tick" {
    var d = Driver{};
    defer d.deinit();
    var g = try game_mod.GameState.init(std.testing.allocator, 1000, 640);
    defer g.deinit();
    var privacy = false;
    for (0..8) |_| {
        var s = input.RawSample{ .navigation = .{ .right = true, .down = true } };
        d.queue.push(&s);
        s.navigation = .{};
        d.queue.push(&s);
    }
    _ = try d.advance(0, &g, null, null, &privacy);
    try std.testing.expect(g.camera.tile_x == 1 and g.camera.tile_y == 1);
    _ = try d.advance(10, &g, null, null, &privacy);
    try std.testing.expect(g.camera.tile_x == 1 and g.camera.tile_y == 1);
    var held = input.RawSample{ .navigation = .{ .right = true } };
    d.queue.push(&held);
    _ = try d.advance(10.05, &g, null, null, &privacy);
    try std.testing.expectEqual(@as(i32, 2), g.camera.tile_x);
    d.skipPast(30);
    try std.testing.expect(!try d.advance(30, &g, null, null, &privacy));
    try std.testing.expectEqual(@as(i32, 2), g.camera.tile_x);
}

test "ordered Escape then WASD typing confirm cannot navigate the menu" {
    var d = Driver{};
    defer d.deinit();
    var g = try game_mod.GameState.init(std.testing.allocator, 1000, 640);
    defer g.deinit();
    var privacy = false;
    pushFrame(&d, .{ .escape_clicked = true });
    var letter = input.RawSample{ .wasd = .{ .down = true }, .frame = .{ .character_count = 1 } };
    letter.frame.characters[0] = 's';
    d.queue.push(&letter);
    pushFrame(&d, .{ .confirm = true });
    _ = try d.advance(0, &g, null, null, &privacy);
    try std.testing.expect(g.menu.opened and g.menu.currentPage == .Wallet);
    try std.testing.expectEqual(@as(i32, 0), g.camera.tile_y);
    // Input-driven transitions do not flush the remaining ordered edges.
    pushFrame(&d, .{ .escape_clicked = true });
    pushFrame(&d, .{ .escape_clicked = true });
    const was_open = g.menu.opened;
    _ = try d.advance(0.05, &g, null, null, &privacy);
    try std.testing.expectEqual(was_open, g.menu.opened);
}

test "typing backspace toggle multiplicity and drag release remain ordered" {
    var d = Driver{};
    defer d.deinit();
    var g = try game_mod.GameState.init(std.testing.allocator, 1000, 640);
    defer g.deinit();
    var m = onboarding.Onboarding.init(std.testing.allocator);
    defer m.deinit();
    m.receive(.resume_phrase_entry);
    var privacy = false;
    var text = input.FrameInput{ .character_count = 2 };
    text.characters[0..2].* = .{ 'a', 'b' };
    pushFrame(&d, text);
    pushFrame(&d, .{ .backspace = true });
    text.characters[0] = 'c';
    text.character_count = 1;
    pushFrame(&d, text);
    _ = try d.advance(0, &g, &m, null, &privacy);
    try std.testing.expectEqualStrings("ac", m.recoveryPhrase());
    try std.testing.expect(privacy);
    m.phase = .inactive;
    d.observeRouting(&g, &m);
    const settings = g.settings;
    pushFrame(&d, .{ .toggle_grid = true, .toggle_borders = true, .dragging = true, .drag_x = -20 });
    pushFrame(&d, .{ .toggle_grid = true, .toggle_borders = true });
    pushFrame(&d, .{ .dragging = true, .drag_x = -20 });
    _ = try d.advance(0.05, &g, &m, null, &privacy);
    try std.testing.expect(std.meta.eql(settings, g.settings));
    try std.testing.expectEqual(@as(i32, 0), g.camera.tile_x);
    try std.testing.expectEqual(@as(f64, 20), g.camera.drag_remainder_x);
}

test "overflow drops newest edges but reconciles held and mouse release" {
    var d = Driver{};
    defer d.deinit();
    var g = try game_mod.GameState.init(std.testing.allocator, 1000, 640);
    defer g.deinit();
    var privacy = false;
    const grid = g.settings.debug.tile_grid;
    for (0..capacity) |_| {
        var s = input.RawSample{ .navigation = .{ .right = true }, .frame = .{ .dragging = true, .drag_x = -0.25 } };
        d.queue.push(&s);
    }
    pushFrame(&d, .{ .toggle_grid = true }); // dropped, release still reconciles
    _ = try d.advance(0, &g, null, null, &privacy);
    try std.testing.expectEqual(grid, g.settings.debug.tile_grid);
    try std.testing.expectEqual(@as(f64, 0), g.camera.drag_remainder_x);
    _ = try d.advance(0.1, &g, null, null, &privacy);
    try std.testing.expectEqual(@as(i32, 0), g.camera.tile_x);
}

test "async completion invalidates old modal input even on skipped ticks" {
    var d = Driver{};
    defer d.deinit();
    var g = try game_mod.GameState.init(std.testing.allocator, 1000, 640);
    defer g.deinit();
    var m = onboarding.Onboarding.init(std.testing.allocator);
    defer m.deinit();
    var privacy = m.isBlocking(); // captured BEFORE external completion
    d.observeRouting(&g, &m);
    _ = try d.advance(0, &g, &m, null, &privacy);
    pushFrame(&d, .{ .escape_clicked = true, .toggle_grid = true });
    m.receive(.ready);
    d.observeRouting(&g, &m); // before capture, not behind tick permission
    try std.testing.expectEqual(@as(usize, 0), d.queue.len);
    try std.testing.expect(!try d.advance(0.01, &g, &m, null, &privacy));
    try std.testing.expect(privacy and !g.menu.opened);
    const settings = g.settings;
    _ = try d.advance(0.05, &g, &m, null, &privacy);
    try std.testing.expect(std.meta.eql(settings, g.settings));
    try std.testing.expect(!g.menu.opened);
    // Content replacement without phase changes uses explicit invalidation.
    pushFrame(&d, .{ .confirm = true });
    d.invalidateInput();
    try std.testing.expect(d.queue.len == 0 and d.repeat.cooldown == 0);
}

test "external menu focus and attempt changes invalidate before capture not every observation" {
    var d = Driver{};
    defer d.deinit();
    var g = try game_mod.GameState.init(std.testing.allocator, 1000, 640);
    defer g.deinit();
    var m = onboarding.Onboarding.init(std.testing.allocator);
    defer m.deinit();
    m.phase = .inactive;
    g.menu.opened = true;
    g.menu.currentPage = .Withdraw;
    d.observeRouting(&g, &m);
    pushFrame(&d, .{ .escape_clicked = true });
    d.observeRouting(&g, &m);
    try std.testing.expectEqual(@as(usize, 1), d.queue.len);
    g.menu.focus = .withdrawal_invoice; // trusted external target replacement
    d.observeRouting(&g, &m);
    try std.testing.expectEqual(@as(usize, 0), d.queue.len);
    pushFrame(&d, .{ .confirm = true });
    m.attempt_id += 1;
    d.observeRouting(&g, &m);
    try std.testing.expectEqual(@as(usize, 0), d.queue.len);
}

test "each effect is immediate including paste before typing and restore payload" {
    const Recorder = struct {
        order: [3]onboarding.Effect = undefined,
        len: usize = 0,
        payload: [32]u8 = @splat(0),
        payload_len: usize = 0,

        fn dispatch(context: ?*anyopaque, model: *onboarding.Onboarding, effect: onboarding.Effect) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.order[self.len] = effect;
            self.len += 1;
            switch (effect) {
                .paste_requested => model.receive(.{ .paste = model.allocator.dupe(u8, "one") catch unreachable }),
                .restore_requested => {
                    self.payload_len = model.recoveryPhrase().len;
                    @memcpy(self.payload[0..self.payload_len], model.recoveryPhrase());
                    // A synchronous failure permits later records to edit.
                    model.receive(.{ .invalid_phrase = model.attempt_id });
                },
                else => {},
            }
        }
    };
    var d = Driver{};
    defer d.deinit();
    var g = try game_mod.GameState.init(std.testing.allocator, 1000, 640);
    defer g.deinit();
    var m = onboarding.Onboarding.init(std.testing.allocator);
    defer m.deinit();
    m.receive(.resume_phrase_entry);
    var privacy = false;
    var recorder = Recorder{};
    defer std.crypto.secureZero(u8, &recorder.payload);
    const sink = EffectSink{ .context = &recorder, .dispatch = Recorder.dispatch };
    pushFrame(&d, .{ .paste_shortcut = true });
    var text = input.FrameInput{ .character_count = 1 };
    text.characters[0] = 'x';
    pushFrame(&d, text);
    const restore = m.controls(onboarding.calculateLayout(1000, 640)).find(.restore_phrase).?.rect;
    pushFrame(&d, .{ .clicked = true, .pointer_x = restore.centerX(), .pointer_y = restore.centerY() });
    pushFrame(&d, .{ .backspace = true });
    pushFrame(&d, .{ .paste_shortcut = true });
    _ = try d.advance(0, &g, &m, sink, &privacy);
    try std.testing.expectEqual(@as(usize, 3), recorder.len);
    try std.testing.expect(recorder.order[0] == .paste_requested and recorder.order[1] == .restore_requested and recorder.order[2] == .paste_requested);
    try std.testing.expectEqualStrings("onex", recorder.payload[0..recorder.payload_len]);
    try std.testing.expectEqualStrings("one", m.recoveryPhrase());
}

test "screenshot privacy latches intermediate blocking transitions before effects" {
    const Complete = struct {
        fn dispatch(_: ?*anyopaque, model: *onboarding.Onboarding, _: onboarding.Effect) void {
            model.receive(.complete_success); // destroys mnemonic before draw
        }
    };
    var d = Driver{};
    defer d.deinit();
    var g = try game_mod.GameState.init(std.testing.allocator, 1000, 640);
    defer g.deinit();
    var m = onboarding.Onboarding.init(std.testing.allocator);
    defer m.deinit();
    m.receive(.{ .backup = try std.testing.allocator.dupe(u8, "secret") });
    m.saved = true;
    m.selected = .complete_backup;
    var privacy = false;
    pushFrame(&d, .{ .confirm = true });
    _ = try d.advance(0, &g, &m, .{ .dispatch = Complete.dispatch }, &privacy);
    try std.testing.expect(m.phase == .inactive and m.mnemonic() == null);
    try std.testing.expect(privacy);
}
