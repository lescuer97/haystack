//! Platform-neutral, blocking onboarding model. The adapter supplies events,
//! translates input, draws the layout, and performs returned effects.
//! Never copy an Onboarding value: it uniquely owns its mnemonic allocation.
const std = @import("std");

pub const Phase = enum { loading, choice, phrase_entry, restoring, restore_failed, restore_result, backup, completing, blocked, inactive };
pub const Step = enum { backup_seed };
pub const Control = enum { copy, checkbox, continue_button };
pub const Effect = enum { copy_requested, complete_requested, create_requested, paste_requested, restore_requested, retry_requested, generate_requested, finish_restore_requested };

pub const RestoreReport = struct {
    spendable_sats: u64,
    pending_sats: u64,
    spent_sats: u64,
    can_generate_new: bool,
};

/// `backup` transfers ownership even when the event is inappropriate for the
/// current phase. Its allocation must come from the allocator passed to init.
pub const Event = union(enum) {
    ready,
    backup: []u8,
    blocked,
    complete_success,
    complete_fail,
    choice: struct { recover_enabled: bool },
    resume_phrase_entry,
    resume_failed: struct { can_generate_new: bool },
    resume_result: RestoreReport,
    paste: []u8,
    invalid_phrase: u64,
    restore_finished: struct { attempt_id: u64, report: RestoreReport },
    restore_failed: struct { attempt_id: u64, can_generate_new: bool, stage_created: bool },
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return self.width > 0 and self.height > 0 and x >= self.x and y >= self.y and
            x < self.x + self.width and y < self.y + self.height;
    }
    pub fn centerX(self: Rect) f32 {
        return self.x + self.width / 2;
    }
    pub fn centerY(self: Rect) f32 {
        return self.y + self.height / 2;
    }
};

/// All rectangles are screen-space; seed is a multi-line wrapping area.
pub const Layout = struct {
    panel: Rect,
    title: Rect,
    seed: Rect,
    copy: Rect,
    checkbox: Rect,
    continue_button: Rect,
    message: Rect,

    pub fn hitTest(self: Layout, x: f32, y: f32) ?Control {
        if (self.copy.contains(x, y)) return .copy;
        if (self.checkbox.contains(x, y)) return .checkbox;
        if (self.continue_button.contains(x, y)) return .continue_button;
        return null;
    }
};

fn dimension(value: f32) f32 {
    return if (std.math.isFinite(value)) @max(value, 0) else 0;
}

/// Centre a 560x500 panel with 24px margins where possible. Scale the
/// contents down together on small viewports, keeping all areas contained.
pub fn calculateLayout(viewport_w: f32, viewport_h: f32) Layout {
    const w = dimension(viewport_w);
    const h = dimension(viewport_h);
    const pw = @min(560, @max(w - 48, w * 0.9));
    const ph = @min(500, @max(h - 48, h * 0.9));
    const panel = Rect{ .x = (w - pw) / 2, .y = (h - ph) / 2, .width = pw, .height = ph };
    const sx = pw / 560;
    const sy = ph / 500;
    const make = struct {
        fn rect(p: Rect, xscale: f32, yscale: f32, y: f32, height: f32) Rect {
            return .{ .x = p.x + 24 * xscale, .y = p.y + y * yscale, .width = 512 * xscale, .height = height * yscale };
        }
    }.rect;
    return .{
        .panel = panel,
        .title = make(panel, sx, sy, 24, 44),
        .seed = make(panel, sx, sy, 80, 160),
        .copy = make(panel, sx, sy, 252, 44),
        .checkbox = make(panel, sx, sy, 308, 44),
        .message = make(panel, sx, sy, 360, 40),
        .continue_button = make(panel, sx, sy, 416, 56),
    };
}

/// Adapter maps the corresponding src/input.zig fields into this value.
/// Escape is deliberately ignored; it can never dismiss the modal.
pub const FrameInput = struct {
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    viewport_w: f32 = 1000,
    viewport_h: f32 = 640,
    clicked: bool = false,
    up: bool = false,
    down: bool = false,
    confirm: bool = false,
    escape_clicked: bool = false,
    characters: [32]u21 = @splat(0),
    character_count: usize = 0,
    backspace: bool = false,
    paste_shortcut: bool = false,
};

pub const InputResult = struct {
    consumed: bool,
    effect: ?Effect = null,
};

pub const Onboarding = struct {
    allocator: std.mem.Allocator,
    phase: Phase = .loading,
    step: Step = .backup_seed,
    saved: bool = false,
    copy_requested: bool = false,
    retry_message: bool = false,
    selected: Control = .copy,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    secret: ?[]u8 = null,
    phrase: [1025]u8 = @splat(0),
    phrase_len: usize = 0,
    recover_enabled: bool = false,
    attempt_id: u64 = 0,
    report: ?RestoreReport = null,
    can_generate_new: bool = false,
    stage_created: bool = false,
    recovery_preparation_pending: bool = false,
    finishing_restore: bool = false,

    pub const checkbox_label = "I have saved my recovery words";
    pub const copy_feedback = "Copy requested";
    pub const completion_error = "Could not complete setup. Please try again.";

    pub fn init(allocator: std.mem.Allocator) Onboarding {
        return .{ .allocator = allocator };
    }

    /// The returned borrowed view is valid only until the next event or deinit.
    /// Adapters must not retain it or make unnecessary copies.
    pub fn mnemonic(self: *const Onboarding) ?[]const u8 {
        return if (self.secret) |secret| secret else null;
    }

    pub fn isBlocking(self: *const Onboarding) bool {
        return self.phase != .inactive;
    }

    fn destroySecret(self: *Onboarding, secret: []u8) void {
        std.crypto.secureZero(u8, secret);
        self.allocator.free(secret);
    }

    fn clearSecret(self: *Onboarding) void {
        if (self.secret) |secret| self.destroySecret(secret);
        self.secret = null;
    }

    fn clearPhrase(self: *Onboarding) void {
        std.crypto.secureZero(u8, &self.phrase);
        self.phrase_len = 0;
    }

    /// Borrowed until the next input/event; the adapter must copy synchronously.
    pub fn recoveryPhrase(self: *const Onboarding) []const u8 {
        return self.phrase[0..self.phrase_len];
    }

    fn normalize(self: *Onboarding) void {
        var write: usize = 0;
        var pending_space = false;
        for (self.phrase[0..self.phrase_len]) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 11 or c == 12) {
                pending_space = write != 0;
            } else {
                if (pending_space) {
                    self.phrase[write] = ' ';
                    write += 1;
                }
                self.phrase[write] = c;
                write += 1;
                pending_space = false;
            }
        }
        std.crypto.secureZero(u8, self.phrase[write..]);
        self.phrase_len = write;
    }

    pub fn deinit(self: *Onboarding) void {
        self.clearSecret();
        self.clearPhrase();
        self.phase = .inactive;
    }

    /// Out-of-order events are ignored; rejected backup payloads are scrubbed.
    /// A blocked event terminates any active session and destroys the secret.
    pub fn receive(self: *Onboarding, event: Event) void {
        switch (event) {
            .ready => if (self.phase == .loading) {
                self.phase = .inactive;
            },
            .backup => |secret| {
                if (self.phase == .loading) {
                    self.secret = secret;
                    self.phase = .backup;
                } else self.destroySecret(secret);
            },
            .blocked => if (self.phase != .inactive and self.phase != .blocked) {
                self.clearSecret();
                self.clearPhrase();
                self.phase = .blocked;
            },
            .complete_success => if (self.phase == .completing) {
                self.clearSecret();
                self.clearPhrase();
                self.phase = .inactive;
            },
            .complete_fail => if (self.phase == .completing) {
                self.phase = if (self.finishing_restore) .restore_result else .backup;
                self.retry_message = true;
            },
            .choice => |choice| if (self.phase == .loading) {
                self.recover_enabled = choice.recover_enabled;
                self.selected = .copy;
                self.phase = .choice;
            },
            .resume_phrase_entry => if (self.phase == .loading) {
                self.recover_enabled = true;
                self.stage_created = false;
                self.recovery_preparation_pending = true;
                self.selected = .copy;
                self.phase = .phrase_entry;
            },
            .resume_failed => |failure| if (self.phase == .loading) {
                self.stage_created = true;
                self.can_generate_new = failure.can_generate_new;
                self.selected = .copy;
                self.phase = .restore_failed;
            },
            .resume_result => |report| if (self.phase == .loading) {
                self.stage_created = true;
                self.report = report;
                self.can_generate_new = report.can_generate_new and report.spendable_sats == 0 and report.pending_sats == 0 and report.spent_sats == 0;
                self.selected = .copy;
                self.phase = .restore_result;
            },
            .paste => |payload| {
                defer self.destroySecret(payload);
                if (self.phase == .phrase_entry and payload.len <= 1024 and std.mem.indexOfScalar(u8, payload, 0) == null and std.unicode.utf8ValidateSlice(payload)) {
                    self.clearPhrase();
                    @memcpy(self.phrase[0..payload.len], payload);
                    self.phrase_len = payload.len;
                    self.normalize();
                }
            },
            .invalid_phrase => |id| if (self.phase == .restoring and id == self.attempt_id) {
                self.phase = .phrase_entry;
                self.retry_message = true;
            },
            .restore_failed => |failure| if (self.phase == .restoring and failure.attempt_id == self.attempt_id) {
                self.recovery_preparation_pending = false;
                self.stage_created = failure.stage_created;
                self.can_generate_new = failure.can_generate_new;
                if (failure.stage_created) self.clearPhrase();
                self.phase = .restore_failed;
                self.selected = .copy;
            },
            .restore_finished => |result| if (self.phase == .restoring and result.attempt_id == self.attempt_id) {
                self.recovery_preparation_pending = false;
                self.clearPhrase();
                self.report = result.report;
                self.stage_created = true;
                self.can_generate_new = result.report.can_generate_new and result.report.spendable_sats == 0 and result.report.pending_sats == 0 and result.report.spent_sats == 0;
                self.phase = .restore_result;
                self.selected = .copy;
            },
        }
    }

    fn hasFundsOrHistory(self: *const Onboarding) bool {
        const r = self.report orelse return false;
        return r.spendable_sats != 0 or r.pending_sats != 0 or r.spent_sats != 0;
    }

    fn startAttempt(self: *Onboarding, effect: Effect) Effect {
        self.attempt_id +%= 1;
        self.phase = .restoring;
        return effect;
    }

    fn activateRecovery(self: *Onboarding, control: Control) ?Effect {
        switch (self.phase) {
            .choice => switch (control) {
                .copy => {
                    self.phase = .loading;
                    return .create_requested;
                },
                .checkbox => if (self.recover_enabled) {
                    self.phase = .phrase_entry;
                    self.selected = .copy;
                },
                else => {},
            },
            .phrase_entry => switch (control) {
                .copy => return .paste_requested,
                .checkbox => {
                    self.normalize();
                    if (self.phrase_len != 0) return self.startAttempt(.restore_requested);
                },
                .continue_button => {
                    if (self.recovery_preparation_pending) return null;
                    self.clearPhrase();
                    self.phase = .choice;
                    self.selected = .checkbox;
                },
            },
            .restore_failed, .restore_result => switch (control) {
                .copy => {
                    if (self.phase == .restore_result and self.hasFundsOrHistory()) {
                        self.finishing_restore = true;
                        self.phase = .completing;
                        return .finish_restore_requested;
                    }
                    if (!self.stage_created) {
                        self.phase = .phrase_entry;
                        self.selected = .copy;
                        return null;
                    }
                    return self.startAttempt(.retry_requested);
                },
                .checkbox => {
                    if (self.phase == .restore_result and self.hasFundsOrHistory()) return self.startAttempt(.retry_requested);
                    if (self.can_generate_new) {
                        self.clearPhrase();
                        self.phase = .loading;
                        return .generate_requested;
                    }
                },
                else => {},
            },
            else => {},
        }
        return null;
    }

    fn activate(self: *Onboarding, control: Control) ?Effect {
        switch (control) {
            .copy => {
                self.copy_requested = true;
                return .copy_requested;
            },
            .checkbox => self.saved = !self.saved,
            .continue_button => if (self.saved) {
                self.phase = .completing;
                self.retry_message = false;
                return .complete_requested;
            },
        }
        return null;
    }

    /// Consume every frame while blocking, even loading, completing or blocked.
    /// Directions win over pointer movement; a click always activates its hit.
    pub fn applyInput(self: *Onboarding, frame: FrameInput) InputResult {
        const moved = frame.pointer_x != self.pointer_x or frame.pointer_y != self.pointer_y;
        self.pointer_x = frame.pointer_x;
        self.pointer_y = frame.pointer_y;
        if (!self.isBlocking()) return .{ .consumed = false };
        if (self.phase == .phrase_entry) {
            if (frame.paste_shortcut) return .{ .consumed = true, .effect = .paste_requested };
            if (frame.backspace and self.phrase_len > 0) {
                self.phrase_len -= 1;
                while (self.phrase_len > 0 and self.phrase[self.phrase_len] & 0xc0 == 0x80) self.phrase_len -= 1;
                std.crypto.secureZero(u8, self.phrase[self.phrase_len..]);
            }
            for (frame.characters[0..@min(frame.character_count, frame.characters.len)]) |c| {
                if (c == 0) continue;
                var buf: [4]u8 = undefined;
                defer std.crypto.secureZero(u8, &buf);
                const len = std.unicode.utf8Encode(c, &buf) catch continue;
                if (self.phrase_len + len > 1024) continue;
                @memcpy(self.phrase[self.phrase_len..][0..len], buf[0..len]);
                self.phrase_len += len;
            }
        }
        if (self.phase != .backup and self.phase != .choice and self.phase != .phrase_entry and self.phase != .restore_failed and self.phase != .restore_result) return .{ .consumed = true };

        const layout = calculateLayout(frame.viewport_w, frame.viewport_h);
        const navigated = frame.up != frame.down;
        if (navigated) {
            const index: usize = @backingInt(self.selected);
            self.selected = @fromBackingInt(@intCast(if (frame.up) (index + 2) % 3 else (index + 1) % 3));
        } else if (moved) {
            if (layout.hitTest(frame.pointer_x, frame.pointer_y)) |control| self.selected = control;
        }
        if (frame.clicked) {
            if (layout.hitTest(frame.pointer_x, frame.pointer_y)) |control| {
                self.selected = control;
                return .{ .consumed = true, .effect = if (self.phase == .backup) self.activate(control) else self.activateRecovery(control) };
            }
        } else if (frame.confirm) {
            return .{ .consumed = true, .effect = if (self.phase == .backup) self.activate(self.selected) else self.activateRecovery(self.selected) };
        }
        return .{ .consumed = true };
    }
};

test "backup confirmation, independent copy, retry and success" {
    var model = Onboarding.init(std.testing.allocator);
    defer model.deinit();
    try std.testing.expect(model.isBlocking());
    model.receive(.{ .backup = try std.testing.allocator.dupe(u8, "one two three") });
    try std.testing.expectEqual(Phase.backup, model.phase);
    model.selected = .continue_button;
    try std.testing.expectEqual(@as(?Effect, null), model.applyInput(.{ .confirm = true }).effect);
    model.selected = .copy;
    try std.testing.expectEqual(@as(?Effect, .copy_requested), model.applyInput(.{ .confirm = true }).effect);
    try std.testing.expect(model.copy_requested and !model.saved);
    model.selected = .checkbox;
    _ = model.applyInput(.{ .confirm = true });
    try std.testing.expect(model.saved);
    model.selected = .continue_button;
    try std.testing.expectEqual(@as(?Effect, .complete_requested), model.applyInput(.{ .confirm = true }).effect);
    try std.testing.expectEqual(Phase.completing, model.phase);
    try std.testing.expect(model.applyInput(.{ .escape_clicked = true }).consumed);
    model.receive(.complete_fail);
    try std.testing.expect(model.saved and model.retry_message);
    try std.testing.expectEqualStrings("one two three", model.mnemonic().?);
    try std.testing.expectEqual(@as(?Effect, .complete_requested), model.applyInput(.{ .confirm = true }).effect);
    model.receive(.complete_success);
    try std.testing.expectEqual(Phase.inactive, model.phase);
    try std.testing.expect(model.mnemonic() == null);
    try std.testing.expect(!model.applyInput(.{}).consumed);
}

test "blocked is terminal and owned rejected secrets are freed" {
    var model = Onboarding.init(std.testing.allocator);
    defer model.deinit();
    model.receive(.{ .backup = try std.testing.allocator.dupe(u8, "secret") });
    model.receive(.blocked);
    try std.testing.expect(model.mnemonic() == null);
    model.receive(.{ .backup = try std.testing.allocator.dupe(u8, "rejected") });
    model.receive(.ready);
    try std.testing.expectEqual(Phase.blocked, model.phase);
    try std.testing.expect(model.applyInput(.{ .escape_clicked = true, .confirm = true }).consumed);
}

test "ready skips onboarding and deinit frees a live secret" {
    var ready = Onboarding.init(std.testing.allocator);
    defer ready.deinit();
    ready.receive(.ready);
    try std.testing.expect(!ready.isBlocking());
    var live = Onboarding.init(std.testing.allocator);
    live.receive(.{ .backup = try std.testing.allocator.dupe(u8, "secret") });
    live.deinit();
    try std.testing.expect(live.mnemonic() == null);
}

test "layout hit testing and pointer versus directional selection" {
    const sizes = [_][2]f32{ .{ 1000, 640 }, .{ 160, 100 }, .{ 1, 1 }, .{ 0, 0 } };
    for (sizes) |size| {
        const layout = calculateLayout(size[0], size[1]);
        try std.testing.expectApproxEqAbs(size[0] / 2, layout.panel.centerX(), 0.001);
        try std.testing.expectApproxEqAbs(size[1] / 2, layout.panel.centerY(), 0.001);
        for ([_]Rect{ layout.title, layout.seed, layout.copy, layout.checkbox, layout.message, layout.continue_button }) |rect| {
            try std.testing.expect(rect.x >= layout.panel.x and rect.y >= layout.panel.y);
            try std.testing.expect(rect.x + rect.width <= layout.panel.x + layout.panel.width + 0.001);
            try std.testing.expect(rect.y + rect.height <= layout.panel.y + layout.panel.height + 0.001);
        }
        if (size[0] > 0 and size[1] > 0) {
            try std.testing.expectEqual(@as(?Control, .copy), layout.hitTest(layout.copy.centerX(), layout.copy.centerY()));
            try std.testing.expectEqual(@as(?Control, .checkbox), layout.hitTest(layout.checkbox.centerX(), layout.checkbox.centerY()));
            try std.testing.expectEqual(@as(?Control, .continue_button), layout.hitTest(layout.continue_button.centerX(), layout.continue_button.centerY()));
        }
    }
    var model = Onboarding.init(std.testing.allocator);
    defer model.deinit();
    model.receive(.{ .backup = try std.testing.allocator.dupe(u8, "secret") });
    const layout = calculateLayout(1000, 640);
    const x = layout.checkbox.centerX();
    const y = layout.checkbox.centerY();
    _ = model.applyInput(.{ .pointer_x = x, .pointer_y = y });
    try std.testing.expectEqual(Control.checkbox, model.selected);
    _ = model.applyInput(.{ .pointer_x = x, .pointer_y = y, .down = true });
    _ = model.applyInput(.{ .pointer_x = x, .pointer_y = y });
    try std.testing.expectEqual(Control.continue_button, model.selected);
    _ = model.applyInput(.{ .pointer_x = x, .pointer_y = y, .clicked = true });
    try std.testing.expect(model.saved);
    try std.testing.expectEqual(Control.checkbox, model.selected);
}

test "choice, phrase input, paste, invalid and stale events" {
    var m = Onboarding.init(std.testing.allocator);
    defer m.deinit();
    m.receive(.{ .choice = .{ .recover_enabled = false } });
    m.selected = .checkbox;
    try std.testing.expect(m.applyInput(.{ .confirm = true }).effect == null);
    try std.testing.expectEqual(Phase.choice, m.phase);
    m.recover_enabled = true;
    _ = m.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(Phase.phrase_entry, m.phase);
    var input = FrameInput{};
    input.characters[0..4].* = .{ 'a', ' ', 'b', 0xe9 };
    input.character_count = 4;
    _ = m.applyInput(input);
    _ = m.applyInput(.{ .backspace = true });
    try std.testing.expectEqualStrings("a b", m.recoveryPhrase());
    m.receive(.{ .paste = try std.testing.allocator.dupe(u8, "  one\t two\nthree  ") });
    try std.testing.expectEqualStrings("one two three", m.recoveryPhrase());
    m.receive(.{ .paste = try std.testing.allocator.dupe(u8, "bad\x00phrase") });
    m.receive(.{ .paste = try std.testing.allocator.dupe(u8, "\xff") });
    m.receive(.{ .paste = try std.testing.allocator.alloc(u8, 1025) });
    try std.testing.expectEqualStrings("one two three", m.recoveryPhrase());
    m.selected = .checkbox;
    try std.testing.expectEqual(@as(?Effect, .restore_requested), m.applyInput(.{ .confirm = true }).effect);
    m.receive(.{ .invalid_phrase = m.attempt_id + 1 });
    try std.testing.expectEqual(Phase.restoring, m.phase);
    m.receive(.{ .invalid_phrase = m.attempt_id });
    try std.testing.expectEqualStrings("one two three", m.recoveryPhrase());
    try std.testing.expectEqual(Phase.phrase_entry, m.phase);
    try std.testing.expect(m.applyInput(.{ .escape_clicked = true, .clicked = true }).consumed);
    m.receive(.blocked);
    try std.testing.expectEqual(@as(usize, 0), m.phrase_len);
    for (m.phrase) |c| try std.testing.expectEqual(@as(u8, 0), c);
}

test "capacity and recovery outcomes gate destructive actions" {
    var m = Onboarding.init(std.testing.allocator);
    defer m.deinit();
    m.receive(.{ .choice = .{ .recover_enabled = true } });
    m.selected = .checkbox;
    _ = m.applyInput(.{ .confirm = true });
    const full = try std.testing.allocator.alloc(u8, 1024);
    @memset(full, 'a');
    m.receive(.{ .paste = full });
    var input = FrameInput{ .character_count = 1 };
    input.characters[0] = 'b';
    _ = m.applyInput(input);
    try std.testing.expectEqual(@as(usize, 1024), m.phrase_len);
    m.selected = .checkbox;
    _ = m.applyInput(.{ .confirm = true });
    const first = m.attempt_id;
    m.receive(.{ .restore_failed = .{ .attempt_id = first, .stage_created = true, .can_generate_new = false } });
    try std.testing.expectEqual(@as(usize, 0), m.phrase_len);
    m.selected = .checkbox;
    try std.testing.expect(m.applyInput(.{ .confirm = true }).effect == null);
    m.selected = .copy;
    try std.testing.expectEqual(@as(?Effect, .retry_requested), m.applyInput(.{ .confirm = true }).effect);
    m.receive(.{ .restore_finished = .{ .attempt_id = first, .report = .{ .spendable_sats = 0, .pending_sats = 0, .spent_sats = 0, .can_generate_new = true } } });
    try std.testing.expectEqual(Phase.restoring, m.phase);
    m.receive(.{ .restore_finished = .{ .attempt_id = m.attempt_id, .report = .{ .spendable_sats = 0, .pending_sats = 3, .spent_sats = 0, .can_generate_new = true } } });
    try std.testing.expect(!m.can_generate_new);
    m.selected = .checkbox;
    try std.testing.expectEqual(@as(?Effect, .retry_requested), m.applyInput(.{ .confirm = true }).effect);
    m.receive(.{ .restore_finished = .{ .attempt_id = m.attempt_id, .report = .{ .spendable_sats = 0, .pending_sats = 0, .spent_sats = 0, .can_generate_new = true } } });
    m.selected = .checkbox;
    try std.testing.expectEqual(@as(?Effect, .generate_requested), m.applyInput(.{ .confirm = true }).effect);
    try std.testing.expectEqual(Phase.loading, m.phase);
}

test "recovery resume events initialize only loading model" {
    var model = Onboarding.init(std.testing.allocator);
    defer model.deinit();
    model.receive(.resume_phrase_entry);
    try std.testing.expect(model.phase == .phrase_entry and !model.stage_created);
    model.receive(.{ .resume_failed = .{ .can_generate_new = true } });
    try std.testing.expect(model.phase == .phrase_entry);
    var failed = Onboarding.init(std.testing.allocator);
    defer failed.deinit();
    failed.receive(.{ .resume_failed = .{ .can_generate_new = false } });
    try std.testing.expect(failed.phase == .restore_failed and failed.stage_created and !failed.can_generate_new);
    var result = Onboarding.init(std.testing.allocator);
    defer result.deinit();
    result.receive(.{ .resume_result = .{ .spendable_sats = 0, .pending_sats = 1, .spent_sats = 0, .can_generate_new = true } });
    try std.testing.expect(result.phase == .restore_result and result.stage_created and !result.can_generate_new);
}

test "back is disabled for pending recovery preparation only" {
    var resumed = Onboarding.init(std.testing.allocator);
    defer resumed.deinit();
    resumed.receive(.resume_phrase_entry);
    resumed.receive(.{ .paste = try std.testing.allocator.dupe(u8, "one two") });
    const back = calculateLayout(1000, 640).continue_button;
    try std.testing.expect(resumed.applyInput(.{ .pointer_x = back.centerX(), .pointer_y = back.centerY(), .clicked = true }).effect == null);
    try std.testing.expectEqual(Phase.phrase_entry, resumed.phase);
    try std.testing.expectEqualStrings("one two", resumed.recoveryPhrase());
    try std.testing.expect(resumed.applyInput(.{ .confirm = true }).effect == null);
    resumed.selected = .checkbox;
    try std.testing.expectEqual(@as(?Effect, .restore_requested), resumed.applyInput(.{ .confirm = true }).effect);
    resumed.receive(.{ .invalid_phrase = resumed.attempt_id });
    try std.testing.expect(resumed.recovery_preparation_pending);
    resumed.selected = .continue_button;
    _ = resumed.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(Phase.phrase_entry, resumed.phase);
    resumed.selected = .checkbox;
    _ = resumed.applyInput(.{ .confirm = true });
    resumed.receive(.{ .restore_failed = .{ .attempt_id = resumed.attempt_id +% 1, .can_generate_new = false, .stage_created = false } });
    try std.testing.expect(resumed.recovery_preparation_pending);
    resumed.receive(.{ .restore_failed = .{ .attempt_id = resumed.attempt_id, .can_generate_new = false, .stage_created = false } });
    try std.testing.expect(!resumed.recovery_preparation_pending);
    _ = resumed.applyInput(.{ .confirm = true });
    resumed.selected = .continue_button;
    _ = resumed.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(Phase.choice, resumed.phase);

    var normal = Onboarding.init(std.testing.allocator);
    defer normal.deinit();
    normal.receive(.{ .choice = .{ .recover_enabled = true } });
    normal.selected = .checkbox;
    _ = normal.applyInput(.{ .confirm = true });
    normal.selected = .continue_button;
    _ = normal.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(Phase.choice, normal.phase);
}

test "successful resumed recovery clears preparation pending" {
    var model = Onboarding.init(std.testing.allocator);
    defer model.deinit();
    model.receive(.resume_phrase_entry);
    model.receive(.{ .paste = try std.testing.allocator.dupe(u8, "one") });
    model.selected = .checkbox;
    _ = model.applyInput(.{ .confirm = true });
    model.receive(.{ .restore_finished = .{ .attempt_id = model.attempt_id, .report = .{ .spendable_sats = 0, .pending_sats = 0, .spent_sats = 0, .can_generate_new = false } } });
    try std.testing.expect(!model.recovery_preparation_pending);
    try std.testing.expectEqual(Phase.restore_result, model.phase);
}
