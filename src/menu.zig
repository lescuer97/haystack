//! Menu pages, their item data, and the small amount of runtime UI state that
//! menu input mutates.
//!
//! Pages are data: a page title plus a list of `MenuItem` tagged unions. Each
//! item is exactly one of three kinds:
//!
//! - `navigate`: open another page,
//! - `action`: run a local action,
//! - `text_input`: focus an editable field.
//!
//! `Menu` owns the values that change while it is open (current page, selected
//! row, focus, and text buffers). Rendering reads them; only `Menu` methods and
//! `GameState.update` change them. The module is Raylib-free so layout and
//! input rules stay headless-testable.

const std = @import("std");
const input = @import("input.zig");

/// Upper bound on a wallet display name, in UTF-8 bytes. The extra byte in the
/// backing array is the sentinel that makes `cString` possible.
pub const max_wallet_name_bytes: usize = 128;

pub const MenuPage = enum { Main, Wallet };

/// Local menu actions. None of these touch a wallet, payment, or network layer;
/// they only change menu-local UI state.
pub const Action = enum { close_menu, clear_wallet_name };

/// Editable fields. A field is a data key; its runtime value lives in `Menu`.
pub const InputField = enum { wallet_name };

/// One menu row. The tag decides what activation does, so adding a new kind
/// makes the exhaustive switches below require a decision.
pub const MenuItem = union(enum) {
    navigate: MenuPage,
    action: Action,
    text_input: InputField,
};

// ── editable text ────────────────────────────────────────────────────────────

/// Bounded UTF-8 text with no allocation. Appends and backspaces operate on
/// whole codepoints; `bytes[len]` is always the sentinel 0.
pub const TextField = struct {
    bytes: [max_wallet_name_bytes + 1]u8 = @splat(0),
    len: usize = 0,

    pub fn slice(self: *const TextField) []const u8 {
        return self.bytes[0..self.len];
    }

    /// Sentinel-terminated view for Raylib's text functions.
    pub fn cString(self: *const TextField) [:0]const u8 {
        return self.bytes[0..self.len :0];
    }

    pub fn clear(self: *TextField) void {
        self.len = 0;
        self.bytes[0] = 0;
    }

    /// Append one printable Unicode codepoint. Returns false for control
    /// characters, surrogate halves, out-of-range values, or a full buffer.
    pub fn appendCodepoint(self: *TextField, codepoint: u21) bool {
        if (!isPrintable(codepoint)) return false;

        var encoded: [4]u8 = undefined;
        const encoded_len: usize = std.unicode.utf8Encode(codepoint, &encoded) catch return false;
        if (self.len + encoded_len > max_wallet_name_bytes) return false;

        @memcpy(self.bytes[self.len..][0..encoded_len], encoded[0..encoded_len]);
        self.len += encoded_len;
        self.bytes[self.len] = 0;
        return true;
    }

    /// Remove the last whole codepoint. Returns false when already empty.
    pub fn backspace(self: *TextField) bool {
        if (self.len == 0) return false;

        var index = self.len - 1;
        while (index > 0 and (self.bytes[index] & 0xC0) == 0x80) {
            index -= 1;
        }
        self.len = index;
        self.bytes[self.len] = 0;
        return true;
    }
};

/// Printable text: no C0/C1 controls and no values outside Unicode. Surrogate
/// halves also pass this check but are rejected by `utf8Encode`.
fn isPrintable(codepoint: u21) bool {
    if (codepoint < 0x20) return false;
    if (codepoint >= 0x7F and codepoint <= 0x9F) return false;
    return codepoint <= 0x10FFFF;
}

// ── page data ────────────────────────────────────────────────────────────────

const main_items = [_]MenuItem{
    .{ .navigate = .Wallet },
    .{ .action = .close_menu },
};

const wallet_items = [_]MenuItem{
    .{ .text_input = .wallet_name },
    .{ .action = .clear_wallet_name },
    .{ .navigate = .Main },
};

pub fn pageTitle(page: MenuPage) [:0]const u8 {
    return switch (page) {
        .Main => "Main",
        .Wallet => "Wallet",
    };
}

pub fn pageItems(page: MenuPage) []const MenuItem {
    return switch (page) {
        .Main => &main_items,
        .Wallet => &wallet_items,
    };
}

pub fn itemLabel(item: MenuItem) [:0]const u8 {
    return switch (item) {
        .navigate => |page| switch (page) {
            .Main => "Back to Main",
            .Wallet => "Wallet",
        },
        .action => |action| switch (action) {
            .close_menu => "Resume",
            .clear_wallet_name => "Clear name",
        },
        .text_input => |field| switch (field) {
            .wallet_name => "Wallet name",
        },
    };
}

pub fn itemField(item: MenuItem) ?InputField {
    return switch (item) {
        .text_input => |field| field,
        .navigate, .action => null,
    };
}

// ── layout ───────────────────────────────────────────────────────────────────

/// Largest page the fixed layout storage can represent. Page arrays are
/// checked against this at comptime.
pub const max_items_per_page: usize = 8;

/// Screen-space rectangle, independent of Raylib so layout stays testable.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.width and
            py >= self.y and py <= self.y + self.height;
    }

    pub fn centerX(self: Rect) f32 {
        return self.x + self.width / 2;
    }

    pub fn centerY(self: Rect) f32 {
        return self.y + self.height / 2;
    }
};

const viewport_margin: f32 = 24;
const panel_padding: f32 = 20;
const desired_panel_width: f32 = 420;
const title_height: f32 = 44;
const desired_item_height: f32 = 56;
const item_gap: f32 = 10;

/// Geometry shared by hit testing and drawing. The item rectangles are
/// computed once from the page's item count and the current viewport, so a
/// click can never disagree with what was drawn.
pub const Layout = struct {
    panel: Rect = .{},
    title: Rect = .{},
    items: [max_items_per_page]Rect = @splat(.{}),
    item_count: usize = 0,

    pub fn itemRect(self: *const Layout, index: usize) ?Rect {
        if (index >= self.item_count) return null;
        return self.items[index];
    }

    pub fn hitTest(self: *const Layout, px: f32, py: f32) ?usize {
        var index: usize = 0;
        while (index < self.item_count) : (index += 1) {
            if (self.items[index].contains(px, py)) return index;
        }
        return null;
    }
};

fn viewportDimension(value: f32) f32 {
    return if (std.math.isFinite(value)) @max(value, 0) else 0;
}

/// Centre a page panel in the viewport and stack its item rows. Padding, title,
/// gaps, and row height all scale down with the panel, so every rectangle stays
/// inside the panel even on very small viewports. No scrolling is involved.
pub fn calculateLayout(page: MenuPage, viewport_w: f32, viewport_h: f32) Layout {
    const page_items = pageItems(page);
    const count = @min(page_items.len, max_items_per_page);
    const vw = viewportDimension(viewport_w);
    const vh = viewportDimension(viewport_h);

    const available_w = @max(vw - viewport_margin * 2, 1);
    const available_h = @max(vh - viewport_margin * 2, 1);
    const item_count_f: f32 = @floatFromInt(count);
    const gap_total = if (count > 1)
        @as(f32, @floatFromInt(count - 1)) * item_gap
    else
        0;
    const desired_h = panel_padding * 2 + title_height +
        item_count_f * desired_item_height + gap_total;

    const panel = Rect{
        .x = (vw - @min(desired_panel_width, available_w)) / 2,
        .y = (vh - @min(desired_h, available_h)) / 2,
        .width = @min(desired_panel_width, available_w),
        .height = @min(desired_h, available_h),
    };

    // Keep the normal roomy look when there is space, but shrink every
    // horizontal and vertical component with the panel instead of letting
    // fixed padding and gaps push rows outside it.
    const pad_x = @min(panel_padding, panel.width * 0.08);
    const pad_y = @min(panel_padding, panel.height * 0.10);
    const inner_h = @max(panel.height - pad_y * 2, 0);
    const title_h = @min(title_height, inner_h * 0.4);
    const rows_height = @max(inner_h - title_h, 0);

    const desired_rows = item_count_f * desired_item_height + gap_total;
    const row_scale = if (desired_rows > 0)
        @min(rows_height / desired_rows, 1)
    else
        0;
    const item_h = desired_item_height * row_scale;
    const row_gap = item_gap * row_scale;
    const item_x = panel.x + pad_x;
    const item_w = @max(panel.width - pad_x * 2, 0);
    const first_item_y = panel.y + pad_y + title_h;

    var result = Layout{
        .panel = panel,
        .title = .{
            .x = item_x,
            .y = panel.y + pad_y,
            .width = item_w,
            .height = title_h,
        },
        .item_count = count,
    };

    var index: usize = 0;
    while (index < count) : (index += 1) {
        result.items[index] = .{
            .x = item_x,
            .y = first_item_y + @as(f32, @floatFromInt(index)) * (item_h + row_gap),
            .width = item_w,
            .height = item_h,
        };
    }

    return result;
}

// ── runtime menu state ───────────────────────────────────────────────────────

pub const Menu = struct {
    opened: bool = false,
    currentPage: MenuPage = .Main,
    focus: ?InputField = null,
    wallet_name: TextField = .{},

    /// Persistent row highlight. Opening a page selects its first row; it then
    /// moves only when a menu direction step or moving pointer selects another
    /// row. Activation does not move it (except through page navigation).
    selected_index: usize = 0,

    /// Last screen-space pointer position. Comparing it with the previous frame
    /// tells us whether the pointer moved; a stationary pointer must not keep
    /// stealing a keyboard/gamepad selection. It is a runtime input value, not
    /// menu data.
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,

    /// Apply one frame of already-collected input. Returns true when the frame
    /// belongs to the menu and must not reach the world: while open, and on the
    /// frame that opens or closes it.
    pub fn applyInput(self: *Menu, frame: input.FrameInput) bool {
        const pointer_moved = frame.pointer_x != self.pointer_x or
            frame.pointer_y != self.pointer_y;
        self.pointer_x = frame.pointer_x;
        self.pointer_y = frame.pointer_y;

        if (frame.escape_clicked) {
            if (self.opened) {
                self.close();
            } else {
                self.open();
            }
            return true;
        }
        if (!self.opened) return false;

        const layout = calculateLayout(self.currentPage, frame.viewport_w, frame.viewport_h);
        const items = pageItems(self.currentPage);
        self.clampSelection();

        // 1. Directional navigation wins over pointer movement on the same
        //    frame. A held direction is a one-step request per frame (paced by
        //    input.Reader); idle frames change nothing.
        const navigated = self.applyDirection(&frame);

        // 2. A moving pointer may select the row under it, but only when no
        //    direction was requested this frame. Once the pointer stops, the
        //    stored selection stays put even if it sits over another row.
        if (!navigated and pointer_moved) {
            if (layout.hitTest(frame.pointer_x, frame.pointer_y)) |index| {
                if (index != self.selected_index) {
                    self.selected_index = index;
                    self.focus = null;
                }
            }
        }

        // 3. A click selects and activates the clicked row; anywhere else
        //    blurs the field without clearing the highlight. A confirm edge
        //    activates the currently selected row through the same handler.
        if (frame.clicked) {
            if (layout.hitTest(frame.pointer_x, frame.pointer_y)) |index| {
                self.selected_index = index;
                self.activate(items[index]);
            } else {
                self.focus = null;
            }
        } else if (frame.confirm) {
            self.activate(items[self.selected_index]);
        }

        if (self.focus) |field| self.applyTyping(field, frame);
        return true;
    }

    pub fn open(self: *Menu) void {
        self.opened = true;
        self.currentPage = .Main;
        self.focus = null;
        self.selected_index = 0;
    }

    pub fn close(self: *Menu) void {
        self.opened = false;
        self.focus = null;
    }

    pub fn isFocused(self: *const Menu, field: InputField) bool {
        const focused = self.focus orelse return false;
        return focused == field;
    }

    pub fn isSelected(self: *const Menu, index: usize) bool {
        return index == self.selected_index and index < pageItems(self.currentPage).len;
    }

    /// Move the highlight by one row. Up/Left request the previous row and
    /// Down/Right the next, wrapping at both ends. The vertical list has one
    /// axis, so at most one row moves per frame: a diagonal where both sides
    /// point the same way still steps once, and opposing requests cancel. Any
    /// real step blurs the edited field so typing cannot reach a stale one.
    fn applyDirection(self: *Menu, frame: *const input.FrameInput) bool {
        const previous = frame.left or frame.up;
        const next = frame.right or frame.down;
        if (previous == next) return false; // no request, or two opposing ones

        const item_count = pageItems(self.currentPage).len;
        if (item_count == 0) return false;

        self.selected_index = if (previous)
            (self.selected_index + item_count - 1) % item_count
        else
            (self.selected_index + 1) % item_count;
        self.focus = null;
        return true;
    }

    fn clampSelection(self: *Menu) void {
        const item_count = pageItems(self.currentPage).len;
        if (item_count == 0 or self.selected_index >= item_count) self.selected_index = 0;
    }

    pub fn textField(self: *Menu, field: InputField) *TextField {
        return switch (field) {
            .wallet_name => &self.wallet_name,
        };
    }

    pub fn textFieldConst(self: *const Menu, field: InputField) *const TextField {
        return switch (field) {
            .wallet_name => &self.wallet_name,
        };
    }

    fn activate(self: *Menu, item: MenuItem) void {
        switch (item) {
            .navigate => |page| {
                self.currentPage = page;
                self.focus = null;
                self.selected_index = 0;
            },
            .action => |action| switch (action) {
                .close_menu => self.close(),
                .clear_wallet_name => self.wallet_name.clear(),
            },
            .text_input => |field| {
                self.focus = field;
            },
        }
    }

    fn applyTyping(self: *Menu, field: InputField, frame: input.FrameInput) void {
        const text = self.textField(field);
        const count = @min(frame.character_count, frame.characters.len);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            _ = text.appendCodepoint(frame.characters[index]);
        }
        if (frame.backspace) _ = text.backspace();
    }
};

comptime {
    if (main_items.len > max_items_per_page)
        @compileError("Main page has more items than the fixed layout storage");
    if (wallet_items.len > max_items_per_page)
        @compileError("Wallet page has more items than the fixed layout storage");
}

// ── tests ────────────────────────────────────────────────────────────────────

fn itemCenter(layout: Layout, index: usize) struct { x: f32, y: f32 } {
    const rect = layout.items[index];
    return .{ .x = rect.centerX(), .y = rect.centerY() };
}

fn frameFor(x: f32, y: f32, viewport_w: f32, viewport_h: f32) input.FrameInput {
    return .{
        .pointer_x = x,
        .pointer_y = y,
        .viewport_w = viewport_w,
        .viewport_h = viewport_h,
        .clicked = true,
    };
}

fn typeText(menu: *Menu, text: []const u8) !void {
    var frame = input.FrameInput{
        .viewport_w = 1000,
        .viewport_h = 640,
    };
    var iter = std.unicode.Utf8View.init(text) catch unreachable;
    var codepoints = iter.iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        try std.testing.expect(frame.character_count < frame.characters.len);
        frame.characters[frame.character_count] = codepoint;
        frame.character_count += 1;
    }
    _ = menu.applyInput(frame);
}

fn expectNear(expected: f32, actual: f32, tolerance: f32) !void {
    try std.testing.expect(@abs(expected - actual) <= tolerance);
}

fn expectInside(rect: Rect, container: Rect) !void {
    const epsilon: f32 = 0.0001;
    try std.testing.expect(rect.x >= container.x - epsilon);
    try std.testing.expect(rect.y >= container.y - epsilon);
    try std.testing.expect(rect.x + rect.width <= container.x + container.width + epsilon);
    try std.testing.expect(rect.y + rect.height <= container.y + container.height + epsilon);
}

test "layout centres a page and keeps every rect inside the panel" {
    const pages = [_]MenuPage{ .Main, .Wallet };
    const viewports = [_]struct { w: f32, h: f32 }{
        .{ .w = 1000, .h = 640 },
        .{ .w = 800, .h = 600 },
        .{ .w = 640, .h = 480 },
        .{ .w = 320, .h = 200 },
        .{ .w = 160, .h = 100 },
        .{ .w = 64, .h = 64 },
        .{ .w = 1, .h = 1 },
        .{ .w = 0, .h = 0 },
    };

    for (viewports) |viewport| {
        for (pages) |page| {
            const layout = calculateLayout(page, viewport.w, viewport.h);

            // A zero viewport still produces finite, contained geometry; it
            // just cannot be centred on a positive space or used for clicks.
            if (viewport.w > 0 and viewport.h > 0) {
                try expectNear(viewport.w / 2, layout.panel.centerX(), 0.01);
                try expectNear(viewport.h / 2, layout.panel.centerY(), 0.01);
                try std.testing.expect(layout.panel.x >= 0);
                try std.testing.expect(layout.panel.y >= 0);
                try std.testing.expect(layout.panel.x + layout.panel.width <= viewport.w);
                try std.testing.expect(layout.panel.y + layout.panel.height <= viewport.h);
            }

            try std.testing.expectEqual(pageItems(page).len, layout.item_count);
            try std.testing.expect(layout.title.width > 0 and layout.title.height > 0);
            try expectInside(layout.title, layout.panel);

            var index: usize = 0;
            while (index < layout.item_count) : (index += 1) {
                const rect = layout.itemRect(index).?;
                try std.testing.expect(rect.width > 0 and rect.height > 0);

                // Every row, including on tiny viewports, stays inside the
                // panel; containment is never skipped by viewport size.
                try expectInside(rect, layout.panel);

                // The row centre maps back to the row that was laid out.
                const center = itemCenter(layout, index);
                try std.testing.expectEqual(@as(?usize, index), layout.hitTest(center.x, center.y));

                // The row above the first one must not capture its clicks.
                if (index > 0) {
                    const previous = layout.items[index - 1];
                    try std.testing.expect(!previous.contains(center.x, center.y));
                }
            }

            // Empty space outside the panel hits nothing.
            try std.testing.expectEqual(@as(?usize, null), layout.hitTest(-1, -1));
        }
    }

    try std.testing.expectEqual(@as(usize, 2), calculateLayout(.Main, 1000, 640).item_count);
    try std.testing.expectEqual(@as(usize, 3), calculateLayout(.Wallet, 1000, 640).item_count);
}

test "escape opens on Main and closes again" {
    var menu = Menu{};
    try std.testing.expect(!menu.applyInput(.{}));
    try std.testing.expect(!menu.opened);

    try std.testing.expect(menu.applyInput(.{ .escape_clicked = true }));
    try std.testing.expect(menu.opened);
    try std.testing.expectEqual(MenuPage.Main, menu.currentPage);
    try std.testing.expectEqual(@as(?InputField, null), menu.focus);

    try std.testing.expect(menu.applyInput(.{ .escape_clicked = true }));
    try std.testing.expect(!menu.opened);

    // Reopening after visiting Wallet returns to Main.
    _ = menu.applyInput(.{ .escape_clicked = true });
    const wallet = calculateLayout(.Main, 1000, 640);
    const wallet_point = itemCenter(wallet, 0);
    _ = menu.applyInput(frameFor(wallet_point.x, wallet_point.y, 1000, 640));
    try std.testing.expectEqual(MenuPage.Wallet, menu.currentPage);
    _ = menu.applyInput(.{ .escape_clicked = true });
    _ = menu.applyInput(.{ .escape_clicked = true });
    try std.testing.expectEqual(MenuPage.Main, menu.currentPage);
}

test "Main navigates to Wallet and Back returns to Main" {
    var menu = Menu{};
    _ = menu.applyInput(.{ .escape_clicked = true });

    const main_layout = calculateLayout(.Main, 1000, 640);
    const wallet_point = itemCenter(main_layout, 0);
    try std.testing.expect(menu.applyInput(frameFor(wallet_point.x, wallet_point.y, 1000, 640)));
    try std.testing.expectEqual(MenuPage.Wallet, menu.currentPage);

    const wallet_layout = calculateLayout(.Wallet, 1000, 640);
    const back_index = pageItems(.Wallet).len - 1;
    const back_point = itemCenter(wallet_layout, back_index);
    _ = menu.applyInput(frameFor(back_point.x, back_point.y, 1000, 640));
    try std.testing.expectEqual(MenuPage.Main, menu.currentPage);
}

test "Resume closes and Clear name empties the field" {
    var menu = Menu{};
    _ = menu.applyInput(.{ .escape_clicked = true });

    const main_layout = calculateLayout(.Main, 1000, 640);
    const resume_index = pageItems(.Main).len - 1;
    const resume_point = itemCenter(main_layout, resume_index);
    _ = menu.applyInput(frameFor(resume_point.x, resume_point.y, 1000, 640));
    try std.testing.expect(!menu.opened);

    _ = menu.applyInput(.{ .escape_clicked = true });
    const wallet_button = itemCenter(calculateLayout(.Main, 1000, 640), 0);
    _ = menu.applyInput(frameFor(wallet_button.x, wallet_button.y, 1000, 640));

    const wallet_layout = calculateLayout(.Wallet, 1000, 640);
    const field_point = itemCenter(wallet_layout, 0);
    _ = menu.applyInput(frameFor(field_point.x, field_point.y, 1000, 640));
    try typeText(&menu, "Ada");
    try std.testing.expectEqualStrings("Ada", menu.wallet_name.slice());

    const clear_point = itemCenter(wallet_layout, 1);
    _ = menu.applyInput(frameFor(clear_point.x, clear_point.y, 1000, 640));
    try std.testing.expectEqualStrings("", menu.wallet_name.slice());
    try std.testing.expect(menu.opened);
}

test "typing only reaches a focused input field" {
    var menu = Menu{};
    _ = menu.applyInput(.{ .escape_clicked = true });

    // No focus on Main: keystrokes are consumed but ignored.
    try typeText(&menu, "ignored");
    try std.testing.expectEqualStrings("", menu.wallet_name.slice());

    // Navigating to Wallet still leaves fields unfocused.
    const main_layout = calculateLayout(.Main, 1000, 640);
    const wallet_point = itemCenter(main_layout, 0);
    _ = menu.applyInput(frameFor(wallet_point.x, wallet_point.y, 1000, 640));
    try typeText(&menu, "still-ignored");
    try std.testing.expectEqualStrings("", menu.wallet_name.slice());

    // Clicking the field gives it focus.
    const wallet_layout = calculateLayout(.Wallet, 1000, 640);
    const field_point = itemCenter(wallet_layout, 0);
    _ = menu.applyInput(frameFor(field_point.x, field_point.y, 1000, 640));
    try std.testing.expectEqual(@as(?InputField, .wallet_name), menu.focus);
    try typeText(&menu, "Ada");
    try std.testing.expectEqualStrings("Ada", menu.wallet_name.slice());

    // Clicking outside every item blurs; later typing is ignored.
    _ = menu.applyInput(frameFor(1, 1, 1000, 640));
    try std.testing.expectEqual(@as(?InputField, null), menu.focus);
    try typeText(&menu, "zzz");
    try std.testing.expectEqualStrings("Ada", menu.wallet_name.slice());
}

test "Unicode text appends, backspaces, and respects capacity" {
    var text = TextField{};
    try std.testing.expect(text.appendCodepoint('a'));
    try std.testing.expect(text.appendCodepoint(0x00E9)); // é
    try std.testing.expect(text.appendCodepoint(0x1F600)); // 😀
    try std.testing.expectEqualStrings("a\u{e9}\u{1F600}", text.slice());
    try std.testing.expectEqual(@as(usize, 7), text.len);

    // One backspace removes the whole four-byte emoji, then the two-byte é.
    try std.testing.expect(text.backspace());
    try std.testing.expectEqualStrings("a\u{e9}", text.slice());
    try std.testing.expect(text.backspace());
    try std.testing.expectEqualStrings("a", text.slice());
    try std.testing.expect(text.backspace());
    try std.testing.expectEqualStrings("", text.slice());
    try std.testing.expect(!text.backspace());

    // Capacity is measured in UTF-8 bytes; overflow is refused without
    // corrupting the existing text.
    var full = TextField{};
    var index: usize = 0;
    while (index < max_wallet_name_bytes) : (index += 1) {
        try std.testing.expect(full.appendCodepoint('x'));
    }
    try std.testing.expectEqual(max_wallet_name_bytes, full.len);
    try std.testing.expect(!full.appendCodepoint('y'));
    try std.testing.expectEqual(max_wallet_name_bytes, full.len);
    try std.testing.expect(full.backspace());
    try std.testing.expect(full.appendCodepoint('y'));

    // Controls, surrogates, and out-of-Unicode values are not printable.
    var rejects = TextField{};
    const rejected = [_]u21{ 0, '\n', 0x7F, 0x85, 0xD800, 0x110000 };
    for (rejected) |codepoint| {
        try std.testing.expect(!rejects.appendCodepoint(codepoint));
    }
    try std.testing.expectEqualStrings("", rejects.slice());
}

test "focus resets on navigation and close" {
    var menu = Menu{};
    _ = menu.applyInput(.{ .escape_clicked = true });

    const main_layout = calculateLayout(.Main, 1000, 640);
    const wallet_point = itemCenter(main_layout, 0);
    _ = menu.applyInput(frameFor(wallet_point.x, wallet_point.y, 1000, 640));

    const wallet_layout = calculateLayout(.Wallet, 1000, 640);
    const field_point = itemCenter(wallet_layout, 0);
    _ = menu.applyInput(frameFor(field_point.x, field_point.y, 1000, 640));
    try std.testing.expectEqual(@as(?InputField, .wallet_name), menu.focus);

    // Navigation blurs.
    const back_point = itemCenter(wallet_layout, pageItems(.Wallet).len - 1);
    _ = menu.applyInput(frameFor(back_point.x, back_point.y, 1000, 640));
    try std.testing.expectEqual(@as(?InputField, null), menu.focus);

    // Resume also blurs; reopening starts on Main with nothing focused.
    const resume_point = itemCenter(calculateLayout(.Main, 1000, 640), 1);
    _ = menu.applyInput(frameFor(resume_point.x, resume_point.y, 1000, 640));
    try std.testing.expect(!menu.opened);
    try std.testing.expectEqual(@as(?InputField, null), menu.focus);
    _ = menu.applyInput(.{ .escape_clicked = true });
    try std.testing.expectEqual(MenuPage.Main, menu.currentPage);
    try std.testing.expectEqual(@as(?InputField, null), menu.focus);
}

test "non-input frames leave menu state untouched but stay consumed" {
    var menu = Menu{};
    _ = menu.applyInput(.{ .escape_clicked = true });

    const wallet_point = itemCenter(calculateLayout(.Main, 1000, 640), 0);
    _ = menu.applyInput(frameFor(wallet_point.x, wallet_point.y, 1000, 640));
    const field_point = itemCenter(calculateLayout(.Wallet, 1000, 640), 0);
    _ = menu.applyInput(frameFor(field_point.x, field_point.y, 1000, 640));
    try typeText(&menu, "Ada");

    const idle = input.FrameInput{ .viewport_w = 1000, .viewport_h = 640 };
    var frame_index: usize = 0;
    while (frame_index < 5) : (frame_index += 1) {
        try std.testing.expect(menu.applyInput(idle));
    }
    try std.testing.expect(menu.opened);
    try std.testing.expectEqual(MenuPage.Wallet, menu.currentPage);
    try std.testing.expectEqual(@as(?InputField, .wallet_name), menu.focus);
    try std.testing.expectEqualStrings("Ada", menu.wallet_name.slice());

    // A closed menu does not consume unrelated frames.
    _ = menu.applyInput(.{ .escape_clicked = true });
    try std.testing.expect(!menu.applyInput(idle));
}

test "opening and page changes select the first row" {
    var menu = Menu{};
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);

    _ = menu.applyInput(.{ .escape_clicked = true });
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);

    // Move away, then move back to row 0 and navigate with confirm.
    _ = menu.applyInput(.{ .down = true });
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);
    _ = menu.applyInput(.{ .up = true });
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);

    _ = menu.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(MenuPage.Wallet, menu.currentPage);
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);

    // Closing and reopening returns to Main and selects row 0 again.
    _ = menu.applyInput(.{ .down = true });
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);
    _ = menu.applyInput(.{ .escape_clicked = true });
    _ = menu.applyInput(.{ .escape_clicked = true });
    try std.testing.expectEqual(MenuPage.Main, menu.currentPage);
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
}

test "directions wrap in both axes and idle frames preserve the highlight" {
    var menu = Menu{};
    _ = menu.applyInput(.{ .escape_clicked = true });

    // Main has two rows: Down and Right mean next, Up and Left mean previous.
    _ = menu.applyInput(.{ .down = true });
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);
    _ = menu.applyInput(.{ .right = true }); // wrap next -> 0
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
    _ = menu.applyInput(.{ .up = true }); // wrap previous -> 1
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);
    _ = menu.applyInput(.{ .left = true }); // previous -> 0
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);

    // Releasing every direction leaves the highlight where it was.
    var idle: usize = 0;
    while (idle < 5) : (idle += 1) {
        _ = menu.applyInput(.{});
        try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
    }
}

test "diagonal directions step once and opposing directions cancel" {
    var menu = Menu{};
    _ = menu.applyInput(.{ .escape_clicked = true });

    // Up+Left both mean previous: one row back, not two.
    _ = menu.applyInput(.{ .up = true, .left = true });
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index); // 0 -> wrap 1

    // Down+Right both mean next: one row forward.
    _ = menu.applyInput(.{ .down = true, .right = true });
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index); // 1 -> wrap 0

    // Opposite pairs cancel, including a vertical/horizontal pair.
    _ = menu.applyInput(.{ .up = true, .down = true });
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
    _ = menu.applyInput(.{ .left = true, .right = true });
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
    _ = menu.applyInput(.{ .up = true, .right = true });
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
    _ = menu.applyInput(.{ .down = true, .left = true });
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
}

test "confirm navigates, runs actions, and focuses a text input" {
    var menu = Menu{};
    _ = menu.applyInput(.{ .escape_clicked = true });

    // Selected row 0 is Wallet navigation.
    _ = menu.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(MenuPage.Wallet, menu.currentPage);
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);

    // Selected row 0 is the text input: confirm focuses it.
    _ = menu.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(@as(?InputField, .wallet_name), menu.focus);
    try typeText(&menu, "Ada");
    try std.testing.expectEqualStrings("Ada", menu.wallet_name.slice());

    // Moving away blurs the field.
    _ = menu.applyInput(.{ .down = true });
    try std.testing.expectEqual(@as(?InputField, null), menu.focus);
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);

    // Selected action clears the name and leaves the menu open.
    _ = menu.applyInput(.{ .confirm = true });
    try std.testing.expectEqualStrings("", menu.wallet_name.slice());
    try std.testing.expect(menu.opened);

    // Back to Main, then Resume closes through the same action handler.
    _ = menu.applyInput(.{ .down = true }); // 1 -> 2 (Back to Main)
    _ = menu.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(MenuPage.Main, menu.currentPage);
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
    _ = menu.applyInput(.{ .down = true }); // 0 -> 1 (Resume)
    _ = menu.applyInput(.{ .confirm = true });
    try std.testing.expect(!menu.opened);
}

test "mouse movement selects a row and clicks activate it" {
    var menu = Menu{};
    _ = menu.applyInput(.{ .escape_clicked = true });

    const main_layout = calculateLayout(.Main, 1000, 640);
    const first = itemCenter(main_layout, 0);
    const second = itemCenter(main_layout, 1);

    // A moving pointer over the row selects it without activating.
    _ = menu.applyInput(.{ .pointer_x = second.x, .pointer_y = second.y });
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);
    try std.testing.expect(menu.opened);

    // Clicking the other row selects and activates it (Wallet navigation).
    _ = menu.applyInput(.{
        .pointer_x = first.x,
        .pointer_y = first.y,
        .clicked = true,
    });
    try std.testing.expectEqual(MenuPage.Wallet, menu.currentPage);
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);

    // Clicking the field focuses it; clicking outside blurs but keeps the
    // highlight.
    const wallet_layout = calculateLayout(.Wallet, 1000, 640);
    const field = itemCenter(wallet_layout, 0);
    _ = menu.applyInput(.{
        .pointer_x = field.x,
        .pointer_y = field.y,
        .clicked = true,
    });
    try std.testing.expectEqual(@as(?InputField, .wallet_name), menu.focus);
    _ = menu.applyInput(.{ .pointer_x = 1, .pointer_y = 1, .clicked = true });
    try std.testing.expectEqual(@as(?InputField, null), menu.focus);
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
}

test "a stationary pointer cannot steal the directional selection" {
    var menu = Menu{};
    _ = menu.applyInput(.{ .escape_clicked = true });

    const main_layout = calculateLayout(.Main, 1000, 640);
    const first = itemCenter(main_layout, 0);
    const second = itemCenter(main_layout, 1);

    // The first frame moves the pointer over row 1, which selects it.
    _ = menu.applyInput(.{ .pointer_x = second.x, .pointer_y = second.y });
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);

    // A direction moves the highlight to row 0 while the pointer keeps sitting
    // over row 1. Direction wins that frame.
    _ = menu.applyInput(.{ .pointer_x = second.x, .pointer_y = second.y, .up = true });
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);

    // Idle frames with the same stationary pointer must not move it back.
    var idle: usize = 0;
    while (idle < 5) : (idle += 1) {
        _ = menu.applyInput(.{ .pointer_x = second.x, .pointer_y = second.y });
        try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
    }

    // A pointer that actually moves onto row 1 selects it again.
    _ = menu.applyInput(.{ .pointer_x = first.x + 1, .pointer_y = first.y });
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
    _ = menu.applyInput(.{ .pointer_x = second.x, .pointer_y = second.y });
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);
}

test "typing letters do not navigate and moving away clears focus" {
    var menu = Menu{};
    _ = menu.applyInput(.{ .escape_clicked = true });
    _ = menu.applyInput(.{ .confirm = true }); // Wallet navigation
    _ = menu.applyInput(.{ .confirm = true }); // focus the name field
    try std.testing.expectEqual(@as(?InputField, .wallet_name), menu.focus);

    // WASD and space type normally and never move the highlight.
    try typeText(&menu, "wasd xyz");
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
    try std.testing.expectEqualStrings("wasd xyz", menu.wallet_name.slice());

    // A direction step blurs the field; later typing goes nowhere and still
    // does not move the highlight.
    _ = menu.applyInput(.{ .down = true });
    try std.testing.expectEqual(@as(?InputField, null), menu.focus);
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);
    try typeText(&menu, "ignored");
    try std.testing.expectEqualStrings("wasd xyz", menu.wallet_name.slice());
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);
}
