//! Platform-neutral, blocking onboarding model. The adapter supplies events,
//! translates input, draws the layout, and performs returned effects.
//! Never copy an Onboarding value: it uniquely owns its mnemonic allocation.
const std = @import("std");

pub const Phase = enum { loading, choice, phrase_entry, restoring, restore_failed, restore_result, backup, completing, blocked, inactive };
pub const Step = enum { backup_seed };
pub const Action = union(enum) { create_wallet, enter_recovery, paste_phrase, restore_phrase, back_to_choice, retry_recovery, generate_wallet, finish_restore, copy_seed, copy_word: u8, toggle_backup_saved, complete_backup };
pub const Control = struct { action: Action, label: [:0]const u8, rect: Rect, enabled: bool, kind: enum { button, checkbox, word } = .button };
pub const Controls = struct {
    items: [15]Control = undefined,
    len: usize = 0,
    fn add(self: *Controls, action: Action, label: [:0]const u8, rect: Rect, enabled: bool, kind: @FieldType(Control, "kind")) void {
        self.items[self.len] = .{ .action = action, .label = label, .rect = rect, .enabled = enabled, .kind = kind };
        self.len += 1;
    }
    pub fn find(self: *const Controls, action: Action) ?Control {
        for (self.items[0..self.len]) |control| if (std.meta.eql(control.action, action)) return control;
        return null;
    }
    pub fn hitTest(self: *const Controls, x: f32, y: f32) ?Control {
        for (self.items[0..self.len]) |control| if (control.rect.contains(x, y)) return control;
        return null;
    }
};
pub const Effect = union(enum) { copy_requested, copy_word_requested: u8, complete_requested, create_requested, paste_requested, restore_requested, retry_requested, generate_requested, finish_restore_requested };

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
    seed_words: Rect,
    copy: Rect,
    checkbox: Rect,
    continue_button: Rect,
    message: Rect,

    pub fn wordRect(self: Layout, index: u8) Rect {
        const gx = 8 * self.panel.width / 560;
        const gy = 6 * self.panel.height / 500;
        const width = (self.seed_words.width - 2 * gx) / 3;
        const height = (self.seed_words.height - 3 * gy) / 4;
        return .{ .x = self.seed_words.x + @as(f32, @floatFromInt(index % 3)) * (width + gx), .y = self.seed_words.y + @as(f32, @floatFromInt(index / 3)) * (height + gy), .width = width, .height = height };
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
        .seed_words = make(panel, sx, sy, 107, 133),
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
    copied_word: ?u8 = null,
    feedback_target: ?Action = null,
    feedback_expiry: f64 = 0,
    retry_message: bool = false,
    selected: ?Action = null,
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
    pub const copy_feedback = "copied!";
    pub const completion_error = "Could not complete setup. Please try again.";

    pub fn init(allocator: std.mem.Allocator) Onboarding {
        return .{ .allocator = allocator };
    }

    /// The returned borrowed view is valid only until the next event or deinit.
    /// Adapters must not retain it or make unnecessary copies.
    pub fn mnemonic(self: *const Onboarding) ?[]const u8 {
        return if (self.secret) |secret| secret else null;
    }

    pub fn mnemonicWord(self: *const Onboarding, index: u8) ?[]const u8 {
        if (index >= 12) return null;
        var words = std.mem.tokenizeScalar(u8, self.mnemonic() orelse return null, ' ');
        for (0..index) |_| _ = words.next() orelse return null;
        return words.next();
    }

    pub fn isBlocking(self: *const Onboarding) bool {
        return self.phase != .inactive;
    }

    pub fn hoverEnabled(self: *const Onboarding, layout: Layout, x: f32, y: f32) bool {
        const list = self.controls(layout);
        return if (list.hitTest(x, y)) |control| control.enabled else false;
    }

    pub fn markCopyHandedOff(self: *Onboarding, action: Action, now: f64) void {
        if (self.phase != .backup) return;
        switch (action) {
            .copy_seed => if (self.mnemonic() == null) return,
            .copy_word => |index| {
                if (self.mnemonicWord(index) == null) return;
                self.copied_word = index;
            },
            else => return,
        }
        self.feedback_target = action;
        self.feedback_expiry = now + 3;
    }

    pub fn expire(self: *Onboarding, now: f64) void {
        if (self.feedback_target != null and now >= self.feedback_expiry) self.feedback_target = null;
    }

    fn destroySecret(self: *Onboarding, secret: []u8) void {
        std.crypto.secureZero(u8, secret);
        self.allocator.free(secret);
    }

    fn clearSecret(self: *Onboarding) void {
        if (self.secret) |secret| self.destroySecret(secret);
        self.secret = null;
        self.copied_word = null;
        self.feedback_target = null;
        self.feedback_expiry = 0;
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
        self.selected = null;
    }

    /// Out-of-order events are ignored; rejected backup payloads are scrubbed.
    /// A blocked event terminates any active session and destroys the secret.
    pub fn receive(self: *Onboarding, event: Event) void {
        switch (event) {
            .ready => if (self.phase == .loading) {
                self.phase = .inactive;
                self.selected = null;
            },
            .backup => |secret| {
                if (self.phase == .loading) {
                    self.secret = secret;
                    self.phase = .backup;
                    self.selected = if (self.mnemonicWord(0) != null) .{ .copy_word = 0 } else .copy_seed;
                } else self.destroySecret(secret);
            },
            .blocked => if (self.phase != .inactive and self.phase != .blocked) {
                self.clearSecret();
                self.clearPhrase();
                self.phase = .blocked;
                self.selected = null;
            },
            .complete_success => if (self.phase == .completing) {
                self.clearSecret();
                self.clearPhrase();
                self.phase = .inactive;
                self.selected = null;
            },
            .complete_fail => if (self.phase == .completing) {
                self.phase = if (self.finishing_restore) .restore_result else .backup;
                self.retry_message = true;
                self.selected = if (self.finishing_restore) .finish_restore else .complete_backup;
            },
            .choice => |choice| if (self.phase == .loading) {
                self.recover_enabled = choice.recover_enabled;
                self.selected = .create_wallet;
                self.phase = .choice;
            },
            .resume_phrase_entry => if (self.phase == .loading) {
                self.recover_enabled = true;
                self.stage_created = false;
                self.recovery_preparation_pending = true;
                self.selected = .paste_phrase;
                self.phase = .phrase_entry;
            },
            .resume_failed => if (self.phase == .loading) {
                self.stage_created = true;
                self.can_generate_new = false;
                self.selected = .retry_recovery;
                self.phase = .restore_failed;
            },
            .resume_result => |report| if (self.phase == .loading) {
                self.stage_created = true;
                self.report = report;
                self.can_generate_new = report.can_generate_new and report.spendable_sats == 0 and report.pending_sats == 0 and report.spent_sats == 0;
                self.selected = if (self.hasFundsOrHistory()) .finish_restore else .retry_recovery;
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
                self.selected = .paste_phrase;
            },
            .restore_failed => |failure| if (self.phase == .restoring and failure.attempt_id == self.attempt_id) {
                self.recovery_preparation_pending = false;
                self.stage_created = failure.stage_created;
                self.can_generate_new = false;
                if (failure.stage_created) self.clearPhrase();
                self.phase = .restore_failed;
                self.selected = .retry_recovery;
            },
            .restore_finished => |result| if (self.phase == .restoring and result.attempt_id == self.attempt_id) {
                self.recovery_preparation_pending = false;
                self.clearPhrase();
                self.report = result.report;
                self.stage_created = true;
                self.can_generate_new = result.report.can_generate_new and result.report.spendable_sats == 0 and result.report.pending_sats == 0 and result.report.spent_sats == 0;
                self.phase = .restore_result;
                self.selected = if (self.hasFundsOrHistory()) .finish_restore else .retry_recovery;
            },
        }
    }

    fn hasFundsOrHistory(self: *const Onboarding) bool {
        const r = self.report orelse return false;
        return r.spendable_sats != 0 or r.pending_sats != 0 or r.spent_sats != 0;
    }

    pub fn controls(self: *const Onboarding, layout: Layout) Controls {
        var result = Controls{};
        switch (self.phase) {
            .choice => {
                result.add(.create_wallet, "Create new", layout.copy, true, .button);
                result.add(.enter_recovery, "Recover wallet", layout.checkbox, self.recover_enabled, .button);
            },
            .phrase_entry => {
                result.add(.paste_phrase, "Paste", layout.copy, true, .button);
                result.add(.restore_phrase, "Restore", layout.checkbox, std.mem.trim(u8, self.recoveryPhrase(), " \t\n\r\x0b\x0c").len != 0, .button);
                result.add(.back_to_choice, "Back", layout.continue_button, !self.recovery_preparation_pending, .button);
            },
            .restore_failed => result.add(.retry_recovery, "Retry", layout.copy, true, .button),
            .restore_result => {
                if (self.hasFundsOrHistory()) {
                    result.add(.finish_restore, "Continue", layout.copy, true, .button);
                    result.add(.retry_recovery, "Retry", layout.checkbox, true, .button);
                } else {
                    result.add(.retry_recovery, "Retry", layout.copy, true, .button);
                    result.add(.generate_wallet, "Generate new", layout.checkbox, self.can_generate_new and !self.hasFundsOrHistory(), .button);
                }
            },
            .backup => {
                for (0..12) |i| {
                    const index: u8 = @intCast(i);
                    if (self.mnemonicWord(index) == null) break;
                    result.add(.{ .copy_word = index }, "Copy word", layout.wordRect(index), true, .word);
                }
                result.add(.copy_seed, if (std.meta.eql(self.feedback_target, @as(?Action, .copy_seed))) copy_feedback else "Copy (optional)", layout.copy, true, .button);
                result.add(.toggle_backup_saved, if (self.saved) "[x] I have saved my recovery words" else "[ ] I have saved my recovery words", layout.checkbox, true, .checkbox);
                result.add(.complete_backup, "Continue", layout.continue_button, self.saved, .button);
            },
            else => {},
        }
        return result;
    }

    fn revalidateSelection(self: *Onboarding, list: *const Controls) void {
        if (self.selected) |action| if (list.find(action)) |control| {
            if (control.enabled) return;
        };
        self.selected = null;
        for (list.items[0..list.len]) |control| if (control.enabled) {
            self.selected = control.action;
            return;
        };
    }

    fn startAttempt(self: *Onboarding, effect: Effect) Effect {
        self.attempt_id +%= 1;
        self.phase = .restoring;
        self.selected = null;
        return effect;
    }

    pub fn activateAction(self: *Onboarding, action: Action) ?Effect {
        const list = self.controls(calculateLayout(1000, 640));
        const control = list.find(action) orelse return null;
        if (!control.enabled) return null;
        switch (action) {
            .create_wallet => {
                self.phase = .loading;
                self.selected = null;
                return .create_requested;
            },
            .enter_recovery => {
                self.phase = .phrase_entry;
                self.selected = .paste_phrase;
            },
            .paste_phrase => return .paste_requested,
            .restore_phrase => {
                self.normalize();
                return self.startAttempt(.restore_requested);
            },
            .back_to_choice => {
                self.clearPhrase();
                self.phase = .choice;
                self.selected = .enter_recovery;
            },
            .retry_recovery => {
                if (!self.stage_created) {
                    self.phase = .phrase_entry;
                    self.selected = .paste_phrase;
                    return null;
                }
                return self.startAttempt(.retry_requested);
            },
            .generate_wallet => {
                self.clearPhrase();
                self.phase = .loading;
                self.selected = null;
                return .generate_requested;
            },
            .finish_restore => {
                self.finishing_restore = true;
                self.phase = .completing;
                self.selected = null;
                self.retry_message = false;
                return .finish_restore_requested;
            },
            .copy_seed => return .copy_requested,
            .copy_word => |index| return .{ .copy_word_requested = index },
            .toggle_backup_saved => self.saved = !self.saved,
            .complete_backup => {
                self.finishing_restore = false;
                self.feedback_target = null;
                self.phase = .completing;
                self.selected = null;
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
            if (frame.paste_shortcut) return .{ .consumed = true, .effect = self.activateAction(.paste_phrase) };
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
        const list = self.controls(layout);
        const previous_selection = self.selected;
        self.revalidateSelection(&list);
        const selection_invalidated = !std.meta.eql(previous_selection, self.selected);
        var pointer_selected = false;
        const navigated = frame.up != frame.down;
        if (navigated) {
            if (self.selected) |selected| {
                var index: usize = 0;
                while (index < list.len and !std.meta.eql(list.items[index].action, selected)) : (index += 1) {}
                for (0..list.len) |_| {
                    index = if (frame.up) (index + list.len - 1) % list.len else (index + 1) % list.len;
                    if (list.items[index].enabled) {
                        self.selected = list.items[index].action;
                        break;
                    }
                }
            }
        } else if (moved) {
            if (list.hitTest(frame.pointer_x, frame.pointer_y)) |control| if (control.enabled) {
                self.selected = control.action;
                pointer_selected = true;
            };
        }
        if (frame.clicked) {
            if (list.hitTest(frame.pointer_x, frame.pointer_y)) |control| {
                if (control.enabled) self.selected = control.action;
                return .{ .consumed = true, .effect = self.activateAction(control.action) };
            }
        } else if (frame.confirm) {
            if (!navigated and !pointer_selected and selection_invalidated) return .{ .consumed = true };
            if (self.selected) |action| return .{ .consumed = true, .effect = self.activateAction(action) };
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
    model.selected = .complete_backup;
    try std.testing.expectEqual(@as(?Effect, null), model.applyInput(.{ .confirm = true }).effect);
    model.selected = .copy_seed;
    try std.testing.expectEqual(@as(?Effect, .copy_requested), model.applyInput(.{ .confirm = true }).effect);
    try std.testing.expect(model.feedback_target == null and !model.saved);
    model.selected = .toggle_backup_saved;
    _ = model.applyInput(.{ .confirm = true });
    try std.testing.expect(model.saved);
    model.selected = .complete_backup;
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
    }
    var model = Onboarding.init(std.testing.allocator);
    defer model.deinit();
    model.receive(.{ .backup = try std.testing.allocator.dupe(u8, "secret") });
    const layout = calculateLayout(1000, 640);
    const x = layout.checkbox.centerX();
    const y = layout.checkbox.centerY();
    _ = model.applyInput(.{ .pointer_x = x, .pointer_y = y });
    try std.testing.expectEqual(@as(?Action, .toggle_backup_saved), model.selected);
    _ = model.applyInput(.{ .pointer_x = x, .pointer_y = y, .down = true });
    _ = model.applyInput(.{ .pointer_x = x, .pointer_y = y });
    try std.testing.expectEqual(@as(?Action, .{ .copy_word = 0 }), model.selected);
    _ = model.applyInput(.{ .pointer_x = x, .pointer_y = y, .clicked = true });
    try std.testing.expect(model.saved);
    try std.testing.expectEqual(@as(?Action, .toggle_backup_saved), model.selected);
}

test "choice, phrase input, paste, invalid and stale events" {
    var m = Onboarding.init(std.testing.allocator);
    defer m.deinit();
    m.receive(.{ .choice = .{ .recover_enabled = false } });
    m.selected = .enter_recovery;
    try std.testing.expect(m.applyInput(.{ .confirm = true }).effect == null);
    try std.testing.expectEqual(Phase.choice, m.phase);
    m.recover_enabled = true;
    m.selected = .enter_recovery;
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
    m.selected = .restore_phrase;
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
    m.selected = .enter_recovery;
    _ = m.applyInput(.{ .confirm = true });
    const full = try std.testing.allocator.alloc(u8, 1024);
    @memset(full, 'a');
    m.receive(.{ .paste = full });
    var input = FrameInput{ .character_count = 1 };
    input.characters[0] = 'b';
    _ = m.applyInput(input);
    try std.testing.expectEqual(@as(usize, 1024), m.phrase_len);
    m.selected = .restore_phrase;
    _ = m.applyInput(.{ .confirm = true });
    const first = m.attempt_id;
    m.receive(.{ .restore_failed = .{ .attempt_id = first, .stage_created = true, .can_generate_new = true } });
    try std.testing.expect(!m.can_generate_new);
    try std.testing.expect(m.controls(calculateLayout(1000, 640)).find(.generate_wallet) == null);
    try std.testing.expectEqual(@as(usize, 0), m.phrase_len);
    m.selected = .generate_wallet;
    try std.testing.expect(m.applyInput(.{ .confirm = true }).effect == null);
    m.selected = .retry_recovery;
    try std.testing.expectEqual(@as(?Effect, .retry_requested), m.applyInput(.{ .confirm = true }).effect);
    m.receive(.{ .restore_finished = .{ .attempt_id = first, .report = .{ .spendable_sats = 0, .pending_sats = 0, .spent_sats = 0, .can_generate_new = true } } });
    try std.testing.expectEqual(Phase.restoring, m.phase);
    m.receive(.{ .restore_finished = .{ .attempt_id = m.attempt_id, .report = .{ .spendable_sats = 0, .pending_sats = 3, .spent_sats = 0, .can_generate_new = true } } });
    try std.testing.expect(!m.can_generate_new);
    m.selected = .retry_recovery;
    try std.testing.expectEqual(@as(?Effect, .retry_requested), m.applyInput(.{ .confirm = true }).effect);
    m.receive(.{ .restore_finished = .{ .attempt_id = m.attempt_id, .report = .{ .spendable_sats = 0, .pending_sats = 0, .spent_sats = 0, .can_generate_new = true } } });
    m.selected = .generate_wallet;
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
    failed.receive(.{ .resume_failed = .{ .can_generate_new = true } });
    try std.testing.expect(failed.phase == .restore_failed and failed.stage_created and !failed.can_generate_new);
    failed.can_generate_new = true;
    try std.testing.expect(failed.controls(calculateLayout(1000, 640)).find(.generate_wallet) == null);
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
    try std.testing.expectEqual(@as(?Effect, .paste_requested), resumed.applyInput(.{ .confirm = true }).effect);
    resumed.selected = .restore_phrase;
    try std.testing.expectEqual(@as(?Effect, .restore_requested), resumed.applyInput(.{ .confirm = true }).effect);
    resumed.receive(.{ .invalid_phrase = resumed.attempt_id });
    try std.testing.expect(resumed.recovery_preparation_pending);
    resumed.selected = .back_to_choice;
    _ = resumed.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(Phase.phrase_entry, resumed.phase);
    resumed.selected = .restore_phrase;
    _ = resumed.applyInput(.{ .confirm = true });
    resumed.receive(.{ .restore_failed = .{ .attempt_id = resumed.attempt_id +% 1, .can_generate_new = false, .stage_created = false } });
    try std.testing.expect(resumed.recovery_preparation_pending);
    resumed.receive(.{ .restore_failed = .{ .attempt_id = resumed.attempt_id, .can_generate_new = false, .stage_created = false } });
    try std.testing.expect(!resumed.recovery_preparation_pending);
    _ = resumed.applyInput(.{ .confirm = true });
    resumed.selected = .back_to_choice;
    _ = resumed.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(Phase.choice, resumed.phase);

    var normal = Onboarding.init(std.testing.allocator);
    defer normal.deinit();
    normal.receive(.{ .choice = .{ .recover_enabled = true } });
    normal.selected = .enter_recovery;
    _ = normal.applyInput(.{ .confirm = true });
    normal.selected = .back_to_choice;
    _ = normal.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(Phase.choice, normal.phase);
}

test "successful resumed recovery clears preparation pending" {
    var model = Onboarding.init(std.testing.allocator);
    defer model.deinit();
    model.receive(.resume_phrase_entry);
    model.receive(.{ .paste = try std.testing.allocator.dupe(u8, "one") });
    model.selected = .restore_phrase;
    _ = model.applyInput(.{ .confirm = true });
    model.receive(.{ .restore_finished = .{ .attempt_id = model.attempt_id, .report = .{ .spendable_sats = 0, .pending_sats = 0, .spent_sats = 0, .can_generate_new = false } } });
    try std.testing.expect(!model.recovery_preparation_pending);
    try std.testing.expectEqual(Phase.restore_result, model.phase);
}

test "semantic controls describe every phase and reject stale or disabled actions" {
    var m = Onboarding.init(std.testing.allocator);
    defer m.deinit();
    const layout = calculateLayout(1000, 640);
    try std.testing.expectEqual(@as(usize, 0), m.controls(layout).len);
    m.receive(.{ .choice = .{ .recover_enabled = false } });
    var list = m.controls(layout);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("Create new", list.items[0].label);
    try std.testing.expectEqualStrings("Recover wallet", list.items[1].label);
    try std.testing.expect(!list.items[1].enabled);
    try std.testing.expect(m.activateAction(.enter_recovery) == null);
    try std.testing.expect(m.activateAction(.copy_seed) == null);
    m.recover_enabled = true;
    _ = m.activateAction(.enter_recovery);
    list = m.controls(layout);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("Paste", list.items[0].label);
    try std.testing.expectEqualStrings("Restore", list.items[1].label);
    try std.testing.expectEqualStrings("Back", list.items[2].label);
    try std.testing.expect(!list.items[1].enabled);
    var input = FrameInput{ .character_count = 1 };
    input.characters[0] = ' ';
    _ = m.applyInput(input);
    try std.testing.expect(!m.controls(layout).items[1].enabled);
    try std.testing.expect(m.activateAction(.restore_phrase) == null);
    m.receive(.{ .paste = try std.testing.allocator.dupe(u8, "one") });
    try std.testing.expect(m.controls(layout).items[1].enabled);
    try std.testing.expectEqual(@as(?Effect, .restore_requested), m.activateAction(.restore_phrase));
    try std.testing.expectEqual(@as(usize, 0), m.controls(layout).len);
    m.receive(.{ .restore_failed = .{ .attempt_id = m.attempt_id, .stage_created = false, .can_generate_new = false } });
    list = m.controls(layout);
    try std.testing.expectEqualStrings("Retry", list.items[0].label);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expect(m.activateAction(.generate_wallet) == null);
    _ = m.activateAction(.retry_recovery);
    try std.testing.expectEqual(Phase.phrase_entry, m.phase);
    try std.testing.expectEqual(@as(?Action, .paste_phrase), m.selected);
    _ = m.activateAction(.restore_phrase);
    m.receive(.{ .restore_finished = .{ .attempt_id = m.attempt_id, .report = .{ .spendable_sats = 1, .pending_sats = 0, .spent_sats = 0, .can_generate_new = true } } });
    list = m.controls(layout);
    try std.testing.expectEqualStrings("Continue", list.items[0].label);
    try std.testing.expectEqualStrings("Retry", list.items[1].label);
    try std.testing.expectEqual(@as(?Action, .finish_restore), m.selected);
    try std.testing.expect(m.activateAction(.generate_wallet) == null);
    try std.testing.expectEqual(@as(?Effect, .finish_restore_requested), m.activateAction(.finish_restore));
    m.receive(.complete_fail);
    try std.testing.expectEqual(@as(?Action, .finish_restore), m.selected);
    try std.testing.expectEqual(@as(?Effect, .finish_restore_requested), m.applyInput(.{ .confirm = true }).effect);
}

test "backup controls and navigation use enabled semantic actions" {
    var m = Onboarding.init(std.testing.allocator);
    defer m.deinit();
    m.receive(.{ .backup = try std.testing.allocator.dupe(u8, "secret") });
    const layout = calculateLayout(1000, 640);
    var list = m.controls(layout);
    try std.testing.expectEqualStrings("Copy word", list.items[0].label);
    try std.testing.expectEqualStrings("Copy (optional)", list.items[1].label);
    try std.testing.expectEqualStrings("[ ] I have saved my recovery words", list.items[2].label);
    try std.testing.expectEqual(@FieldType(Control, "kind").checkbox, list.items[2].kind);
    try std.testing.expectEqualStrings("Continue", list.items[3].label);
    try std.testing.expect(!list.items[3].enabled);
    _ = m.applyInput(.{ .up = true });
    try std.testing.expectEqual(@as(?Action, .toggle_backup_saved), m.selected);
    _ = m.applyInput(.{ .down = true });
    try std.testing.expectEqual(@as(?Action, .{ .copy_word = 0 }), m.selected);
    _ = m.applyInput(.{ .pointer_x = layout.continue_button.centerX(), .pointer_y = layout.continue_button.centerY(), .clicked = true });
    try std.testing.expectEqual(@as(?Action, .{ .copy_word = 0 }), m.selected);
    _ = m.applyInput(.{ .pointer_x = layout.checkbox.centerX(), .pointer_y = layout.checkbox.centerY(), .clicked = true });
    list = m.controls(layout);
    try std.testing.expectEqualStrings("[x] I have saved my recovery words", list.items[2].label);
    try std.testing.expect(list.items[3].enabled);
    _ = m.applyInput(.{ .down = true });
    try std.testing.expectEqual(@as(?Action, .complete_backup), m.selected);
    try std.testing.expectEqual(@as(?Effect, .complete_requested), m.applyInput(.{ .confirm = true }).effect);
}

test "backup words have row major geometry, navigation and raw lookup" {
    var m = Onboarding.init(std.testing.allocator);
    defer m.deinit();
    m.receive(.{ .backup = try std.testing.allocator.dupe(u8, "one two three four five six seven eight nine ten eleven twelve") });
    const expected = [_][]const u8{ "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve" };
    for ([_][2]f32{ .{ 1000, 640 }, .{ 160, 100 }, .{ 1, 1 } }) |size| {
        const layout = calculateLayout(size[0], size[1]);
        const list = m.controls(layout);
        try std.testing.expectEqual(@as(usize, 15), list.len);
        for (expected, 0..) |word, i| {
            const index: u8 = @intCast(i);
            const rect = layout.wordRect(index);
            try std.testing.expectEqualStrings(word, m.mnemonicWord(index).?);
            try std.testing.expectEqualDeep(rect, list.items[i].rect);
            try std.testing.expectEqualDeep(@as(Action, .{ .copy_word = index }), list.hitTest(rect.centerX(), rect.centerY()).?.action);
            try std.testing.expect(rect.x >= layout.seed_words.x and rect.y >= layout.seed_words.y);
            try std.testing.expect(rect.x + rect.width <= layout.seed_words.x + layout.seed_words.width + 0.001);
            try std.testing.expect(rect.y + rect.height <= layout.seed_words.y + layout.seed_words.height + 0.001);
            if (i % 3 != 0) try std.testing.expect(rect.x > list.items[i - 1].rect.x + list.items[i - 1].rect.width);
            if (i >= 3) try std.testing.expect(rect.y > list.items[i - 3].rect.y + list.items[i - 3].rect.height);
        }
    }
    try std.testing.expect(m.mnemonicWord(12) == null);
    for (0..12) |i| {
        const index: u8 = @intCast(i);
        try std.testing.expectEqualDeep(@as(?Action, .{ .copy_word = index }), m.selected);
        try std.testing.expectEqualDeep(@as(?Effect, .{ .copy_word_requested = index }), m.applyInput(.{ .confirm = true }).effect);
        m.markCopyHandedOff(.{ .copy_word = index }, 0);
        try std.testing.expectEqual(@as(?u8, index), m.copied_word);
        _ = m.applyInput(.{ .down = true });
    }
    try std.testing.expectEqualDeep(@as(?Action, .copy_seed), m.selected);
    try std.testing.expectEqualDeep(@as(?Effect, .copy_requested), m.applyInput(.{ .confirm = true }).effect);
    try std.testing.expectEqual(@as(?u8, 11), m.copied_word);
    _ = m.applyInput(.{ .down = true });
    try std.testing.expectEqualDeep(@as(?Action, .toggle_backup_saved), m.selected);
    _ = m.applyInput(.{ .down = true });
    try std.testing.expectEqualDeep(@as(?Action, .{ .copy_word = 0 }), m.selected);
    const rect = calculateLayout(1000, 640).wordRect(4);
    try std.testing.expectEqualDeep(@as(?Effect, .{ .copy_word_requested = 4 }), m.applyInput(.{ .pointer_x = rect.centerX(), .pointer_y = rect.centerY(), .clicked = true }).effect);
    m.receive(.blocked);
    try std.testing.expect(m.copied_word == null and m.mnemonicWord(4) == null);
}

test "short backup hides missing words" {
    var m = Onboarding.init(std.testing.allocator);
    defer m.deinit();
    m.receive(.{ .backup = try std.testing.allocator.dupe(u8, " one  two three ") });
    const list = m.controls(calculateLayout(1000, 640));
    try std.testing.expectEqual(@as(usize, 6), list.len);
    try std.testing.expect(m.mnemonicWord(3) == null);
    try std.testing.expect(m.activateAction(.{ .copy_word = 3 }) == null);
    try std.testing.expectEqualStrings(" one  two three ", m.mnemonic().?);
}

test "copy handoff feedback expires and follows most recent successful target" {
    var m = Onboarding.init(std.testing.allocator);
    defer m.deinit();
    m.receive(.{ .backup = try std.testing.allocator.dupe(u8, "one two") });
    const layout = calculateLayout(1000, 640);
    const word = layout.wordRect(0);
    try std.testing.expectEqualDeep(@as(?Effect, .{ .copy_word_requested = 0 }), m.applyInput(.{ .pointer_x = word.centerX(), .pointer_y = word.centerY(), .clicked = true }).effect);
    try std.testing.expect(m.feedback_target == null and m.copied_word == null);
    m.markCopyHandedOff(.{ .copy_word = 0 }, 10);
    m.expire(12.999);
    try std.testing.expectEqualDeep(@as(?Action, .{ .copy_word = 0 }), m.feedback_target);
    m.markCopyHandedOff(.{ .copy_word = 0 }, 12);
    m.expire(13);
    try std.testing.expect(m.feedback_target != null);
    m.selected = .copy_seed;
    try std.testing.expectEqual(@as(?Effect, .copy_requested), m.applyInput(.{ .confirm = true }).effect);
    m.markCopyHandedOff(.copy_seed, 14);
    try std.testing.expectEqualStrings("copied!", m.controls(layout).find(.copy_seed).?.label);
    try std.testing.expectEqual(@as(?u8, 0), m.copied_word);
    m.markCopyHandedOff(.{ .copy_word = 9 }, 15);
    try std.testing.expectEqualDeep(@as(?Action, .copy_seed), m.feedback_target);
    m.expire(17);
    try std.testing.expect(m.feedback_target == null);
    try std.testing.expectEqualStrings("Copy (optional)", m.controls(layout).find(.copy_seed).?.label);
    try std.testing.expectEqual(@as(?u8, 0), m.copied_word);
    m.markCopyHandedOff(.{ .copy_word = 1 }, 18);
    try std.testing.expectEqualDeep(@as(?Action, .{ .copy_word = 1 }), m.feedback_target);
    m.receive(.blocked);
    try std.testing.expect(m.feedback_target == null and m.copied_word == null);
}

test "hover uses enabled controls in current phase" {
    var m = Onboarding.init(std.testing.allocator);
    defer m.deinit();
    const layout = calculateLayout(1000, 640);
    m.receive(.{ .choice = .{ .recover_enabled = false } });
    try std.testing.expect(m.hoverEnabled(layout, layout.copy.centerX(), layout.copy.centerY()));
    try std.testing.expect(!m.hoverEnabled(layout, layout.checkbox.centerX(), layout.checkbox.centerY()));
    try std.testing.expect(!m.hoverEnabled(layout, 0, 0));
    m.receive(.blocked);
    try std.testing.expect(!m.hoverEnabled(layout, layout.copy.centerX(), layout.copy.centerY()));
    var backup = Onboarding.init(std.testing.allocator);
    defer backup.deinit();
    backup.receive(.{ .backup = try std.testing.allocator.dupe(u8, "one two") });
    const word = layout.wordRect(0);
    try std.testing.expect(backup.hoverEnabled(layout, word.centerX(), word.centerY()));
    try std.testing.expect(backup.hoverEnabled(layout, layout.copy.centerX(), layout.copy.centerY()));
    try std.testing.expect(backup.hoverEnabled(layout, layout.checkbox.centerX(), layout.checkbox.centerY()));
    try std.testing.expect(!backup.hoverEnabled(layout, layout.continue_button.centerX(), layout.continue_button.centerY()));
    _ = backup.activateAction(.toggle_backup_saved);
    try std.testing.expect(backup.hoverEnabled(layout, layout.continue_button.centerX(), layout.continue_button.centerY()));
    _ = backup.activateAction(.complete_backup);
    try std.testing.expect(!backup.hoverEnabled(layout, layout.continue_button.centerX(), layout.continue_button.centerY()));
    backup.receive(.complete_success);
    try std.testing.expect(!backup.hoverEnabled(layout, word.centerX(), word.centerY()));
}
