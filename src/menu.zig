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
const wallet_ui = @import("wallet_ui.zig");

/// Upper bound on editable text, in UTF-8 bytes. The extra byte in the
/// backing array is the sentinel that makes `cString` possible.
pub const max_text_bytes: usize = 128;

pub const MenuPage = enum { Main, Wallet, Deposit, Invoice, History, Withdraw, Withdrawal };

/// Local menu actions. None of these touch a wallet, payment, or network layer;
/// they only change menu-local UI state.
pub const Action = enum { close_menu, balance, preset21, preset42, preset100, preset1000, deposit, previous, next, copy_invoice, review_withdrawal, confirm_withdrawal, cancel_withdrawal, review_again, paste_withdrawal, clear_withdrawal };

/// Editable fields. A field is a data key; its runtime value lives in `Menu`.
pub const InputField = enum { deposit_sats, withdrawal_invoice };

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
pub const TextField = BoundedTextField(max_text_bytes);
pub fn BoundedTextField(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        bytes: [capacity + 1]u8 = @splat(0),
        len: usize = 0,

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        /// Sentinel-terminated view for Raylib's text functions.
        pub fn cString(self: *const Self) [:0]const u8 {
            return self.bytes[0..self.len :0];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
            self.bytes[0] = 0;
        }

        /// Append one printable Unicode codepoint. Returns false for control
        /// characters, surrogate halves, out-of-range values, or a full buffer.
        pub fn appendCodepoint(self: *Self, codepoint: u21) bool {
            if (!isPrintable(codepoint)) return false;

            var encoded: [4]u8 = undefined;
            const encoded_len: usize = std.unicode.utf8Encode(codepoint, &encoded) catch return false;
            if (self.len + encoded_len > capacity) return false;

            @memcpy(self.bytes[self.len..][0..encoded_len], encoded[0..encoded_len]);
            self.len += encoded_len;
            self.bytes[self.len] = 0;
            return true;
        }

        /// Remove the last whole codepoint. Returns false when already empty.
        pub fn backspace(self: *Self) bool {
            if (self.len == 0) return false;

            var index = self.len - 1;
            while (index > 0 and (self.bytes[index] & 0xC0) == 0x80) {
                index -= 1;
            }
            self.len = index;
            self.bytes[self.len] = 0;
            return true;
        }
        pub fn replace(self: *Self, value: []const u8) bool {
            if (value.len > capacity) return false;
            const view = std.unicode.Utf8View.init(value) catch return false;
            var iter = view.iterator();
            while (iter.nextCodepoint()) |cp| if (!isPrintable(cp)) return false;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
            self.bytes[self.len] = 0;
            return true;
        }
    };
}

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
    .{ .action = .balance },
    .{ .navigate = .Deposit },
    .{ .navigate = .Withdraw },
    .{ .navigate = .History },
    .{ .navigate = .Main },
};
const deposit_items = [_]MenuItem{
    .{ .text_input = .deposit_sats },
    .{ .action = .preset21 },
    .{ .action = .preset42 },
    .{ .action = .preset100 },
    .{ .action = .preset1000 },
    .{ .action = .deposit },
    .{ .navigate = .Wallet },
};
const invoice_items = [_]MenuItem{ .{ .action = .copy_invoice }, .{ .navigate = .Deposit }, .{ .navigate = .Wallet } };
const history_items = [_]MenuItem{ .{ .action = .previous }, .{ .action = .next }, .{ .navigate = .Wallet } };
const history_previous_items = [_]MenuItem{ .{ .action = .previous }, .{ .navigate = .Wallet } };
const withdraw_items = [_]MenuItem{ .{ .text_input = .withdrawal_invoice }, .{ .action = .paste_withdrawal }, .{ .action = .clear_withdrawal }, .{ .action = .review_withdrawal }, .{ .navigate = .Wallet } };
const withdrawal_review_items = [_]MenuItem{ .{ .action = .confirm_withdrawal }, .{ .action = .cancel_withdrawal } };
const withdrawal_detail_items = [_]MenuItem{ .{ .action = .review_again }, .{ .navigate = .Wallet } };

pub fn pageTitle(page: MenuPage) [:0]const u8 {
    return switch (page) {
        .Main => "Main",
        .Wallet => "Wallet",
        .Deposit => "Deposit - sats",
        .Invoice => "Deposit - invoice",
        .History => "History",
        .Withdraw => "Withdraw - Lightning BOLT11",
        .Withdrawal => "Withdraw - review / saved payment",
    };
}

pub fn pageItems(page: MenuPage) []const MenuItem {
    return switch (page) {
        .Main => &main_items,
        .Wallet => &wallet_items,
        .Deposit => &deposit_items,
        .Invoice => &invoice_items,
        .History => &history_items,
        .Withdraw => &withdraw_items,
        .Withdrawal => &withdrawal_review_items,
    };
}

pub fn itemLabel(item: MenuItem) [:0]const u8 {
    return switch (item) {
        .navigate => |page| switch (page) {
            .Main => "Back to Main",
            .Wallet => "Wallet",
            .Deposit => "Deposit",
            .Invoice => "Saved invoice",
            .History => "History",
            .Withdraw => "Withdraw",
            .Withdrawal => "Saved withdrawal",
        },
        .action => |action| switch (action) {
            .close_menu => "Resume",
            .balance => "Balance (sat)",
            .preset21 => "21 sat",
            .preset42 => "42 sat",
            .preset100 => "100 sat",
            .preset1000 => "1000 sat",
            .deposit => "Deposit",
            .previous => "Previous",
            .next => "Next",
            .copy_invoice => "Copy invoice",
            .review_withdrawal => "Review",
            .confirm_withdrawal => "Withdraw",
            .cancel_withdrawal => "Cancel / Back",
            .review_again => "Review again",
            .paste_withdrawal => "Paste",
            .clear_withdrawal => "Clear",
        },
        .text_input => |field| switch (field) {
            .deposit_sats => "Custom sats",
            .withdrawal_invoice => "Lightning BOLT11 (up to 4096 bytes)",
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
    content: Rect = .{},
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
    return calculateLayoutCount(page, viewport_w, viewport_h, pageItems(page).len);
}
fn calculateLayoutCount(page: MenuPage, viewport_w: f32, viewport_h: f32, item_count: usize) Layout {
    const count = @min(item_count, max_items_per_page);
    const vw = viewportDimension(viewport_w);
    const vh = viewportDimension(viewport_h);

    const available_w = @max(vw - viewport_margin * 2, 1);
    const available_h = @max(vh - viewport_margin * 2, 1);
    const item_count_f: f32 = @floatFromInt(count);
    const gap_total = if (count > 1)
        @as(f32, @floatFromInt(count - 1)) * item_gap
    else
        0;
    const content_height: f32 = switch (page) {
        .Main => 0,
        .Wallet, .Deposit => 62,
        .Invoice => 340,
        .History => 352,
        .Withdraw => 62,
        .Withdrawal => 320,
    };
    const desired_width: f32 = if (page == .Invoice or page == .History or page == .Withdraw or page == .Withdrawal) 760 else desired_panel_width;
    const field_extra: f32 = if (page == .Withdraw) 112 else 0;
    const desired_h = panel_padding * 2 + title_height + content_height + field_extra +
        item_count_f * desired_item_height + gap_total;

    const panel = Rect{
        .x = (vw - @min(desired_width, available_w)) / 2,
        .y = (vh - @min(desired_h, available_h)) / 2,
        .width = @min(desired_width, available_w),
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

    const desired_rows = item_count_f * desired_item_height + gap_total + content_height + field_extra;
    const row_scale = if (desired_rows > 0)
        @min(rows_height / desired_rows, 1)
    else
        0;
    const item_h = desired_item_height * row_scale;
    const row_gap = item_gap * row_scale;
    const item_x = panel.x + pad_x;
    const item_w = @max(panel.width - pad_x * 2, 0);
    const first_item_y = panel.y + pad_y + title_h + content_height * row_scale;

    var result = Layout{
        .panel = panel,
        .title = .{
            .x = item_x,
            .y = panel.y + pad_y,
            .width = item_w,
            .height = title_h,
        },
        .item_count = count,
        .content = .{ .x = item_x, .y = panel.y + pad_y + title_h, .width = item_w, .height = content_height * row_scale },
    };

    var index: usize = 0;
    while (index < count) : (index += 1) {
        result.items[index] = .{
            .x = item_x,
            .y = first_item_y + @as(f32, @floatFromInt(index)) * (item_h + row_gap) + (if (index > 0) field_extra * row_scale else 0),
            .width = item_w,
            .height = item_h + (if (index == 0) field_extra * row_scale else 0),
        };
    }

    return result;
}

// ── runtime menu state ───────────────────────────────────────────────────────

pub const Menu = struct {
    wallet: wallet_ui.Model = .{},
    opened: bool = false,
    currentPage: MenuPage = .Main,
    focus: ?InputField = null,
    deposit_sats: TextField = .{},
    withdrawal_invoice: BoundedTextField(4096) = .{},
    paste_requested: bool = false,

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

        const layout = self.layoutFor(frame.viewport_w, frame.viewport_h);
        self.clampSelection();

        // 1. Directional navigation wins over pointer movement on the same
        //    frame. A held direction is a one-step request per frame (paced by
        //    input.Reader); idle frames change nothing.
        const navigated = self.applyDirection(&frame);

        // 2. A moving pointer may select the row under it, but only when no
        //    direction was requested this frame. Once the pointer stops, the
        //    stored selection stays put even if it sits over another row.
        if (!navigated and pointer_moved) {
            if (self.hitTest(layout, frame.pointer_x, frame.pointer_y)) |index| {
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
            if (self.hitTest(layout, frame.pointer_x, frame.pointer_y)) |index| {
                self.selected_index = index;
                self.activateIndex(index);
            } else {
                self.focus = null;
            }
        } else if (frame.confirm) {
            self.activateIndex(self.selected_index);
        }

        if (self.focus) |field| self.applyTyping(field, frame);
        return true;
    }

    pub fn open(self: *Menu) void {
        self.wallet.history_active = false;
        self.opened = true;
        self.currentPage = .Main;
        self.focus = null;
        self.selected_index = 0;
    }

    pub fn close(self: *Menu) void {
        self.wallet.leaveWithdrawal();
        self.withdrawal_invoice.clear();
        self.paste_requested = false;
        self.wallet.history_active = false;
        self.opened = false;
        self.focus = null;
    }

    pub fn isFocused(self: *const Menu, field: InputField) bool {
        const focused = self.focus orelse return false;
        return focused == field;
    }

    pub fn isSelected(self: *const Menu, index: usize) bool {
        return index + self.rowCount() == self.selected_index and index < self.items().len;
    }
    pub fn rowCount(self: *const Menu) usize {
        return if (self.currentPage == .History) self.wallet.row_count else 0;
    }
    pub fn items(self: *const Menu) []const MenuItem {
        if (self.currentPage == .Withdrawal) return if (self.wallet.reviewLive() or (self.wallet.pending and (self.wallet.operation == .prepare_withdrawal or self.wallet.operation == .cancel_withdrawal))) &withdrawal_review_items else &withdrawal_detail_items;
        if (self.currentPage != .History) return pageItems(self.currentPage);
        const previous = self.wallet.total_rows > 8 and self.wallet.desired_offset > 0;
        const next = @as(u64, self.wallet.desired_offset) + 8 < self.wallet.total_rows;
        return if (previous and next) &history_items else if (previous) &history_previous_items else if (next) history_items[1..] else history_items[2..];
    }
    pub fn itemCount(self: *const Menu) usize {
        return self.rowCount() + self.items().len;
    }
    pub fn layoutFor(self: *const Menu, w: f32, h: f32) Layout {
        return calculateLayoutCount(self.currentPage, w, h, self.items().len);
    }
    pub fn isRowSelected(self: *const Menu, row: usize) bool {
        return row < self.rowCount() and row == self.selected_index;
    }
    fn hitTest(self: *const Menu, layout: Layout, x: f32, y: f32) ?usize {
        if (layout.hitTest(x, y)) |index| return self.rowCount() + index;
        if (self.currentPage == .History and layout.content.height > 0 and layout.content.contains(x, y)) {
            const row: usize = @intFromFloat((y - layout.content.y) / (layout.content.height / 8));
            if (row < self.rowCount()) return row;
        }
        return null;
    }
    pub fn activateIndex(self: *Menu, index: usize) void {
        if (index < self.rowCount()) {
            if (self.wallet.openRow(index)) {
                self.currentPage = if (self.wallet.rows[index].outgoing) .Withdrawal else .Invoice;
                self.wallet.history_active = false;
                self.focus = null;
                self.selected_index = 0;
            }
        } else if (index - self.rowCount() < self.items().len) self.activate(self.items()[index - self.rowCount()]);
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

        const item_count = self.itemCount();
        if (item_count == 0) return false;

        self.selected_index = if (previous)
            (self.selected_index + item_count - 1) % item_count
        else
            (self.selected_index + 1) % item_count;
        self.focus = null;
        return true;
    }

    fn clampSelection(self: *Menu) void {
        const item_count = self.itemCount();
        if (item_count == 0 or self.selected_index >= item_count) self.selected_index = 0;
    }

    pub fn textField(self: *Menu, field: InputField) *TextField {
        return switch (field) {
            .deposit_sats => &self.deposit_sats,
            .withdrawal_invoice => unreachable,
        };
    }

    pub fn textFieldConst(self: *const Menu, field: InputField) *const TextField {
        return switch (field) {
            .deposit_sats => &self.deposit_sats,
            .withdrawal_invoice => unreachable,
        };
    }

    fn activate(self: *Menu, item: MenuItem) void {
        switch (item) {
            .navigate => |page| {
                if ((self.currentPage == .Withdraw or self.currentPage == .Withdrawal) and page != self.currentPage) {
                    self.wallet.leaveWithdrawal();
                    self.withdrawal_invoice.clear();
                    self.paste_requested = false;
                }
                if (page == .Deposit and self.wallet.invoice.len != 0 and !self.wallet.issued and !self.wallet.expired and self.currentPage == .Wallet) {
                    self.currentPage = .Invoice;
                } else self.currentPage = page;
                self.wallet.visit(self.currentPage == .History, page == .Wallet);
                self.focus = null;
                self.selected_index = 0;
            },
            .action => |action| switch (action) {
                .close_menu => self.close(),
                .balance => {},
                .preset21, .preset42, .preset100, .preset1000 => {
                    self.deposit_sats.clear();
                    const text = switch (action) {
                        .preset21 => "21",
                        .preset42 => "42",
                        .preset100 => "100",
                        else => "1000",
                    };
                    for (text) |c| _ = self.deposit_sats.appendCodepoint(c);
                    self.focus = null;
                },
                .deposit => {
                    self.focus = null;
                    if (self.wallet.create(self.deposit_sats.slice())) {
                        self.currentPage = .Invoice;
                        self.wallet.history_active = false;
                        self.selected_index = 0;
                    }
                },
                .previous => self.wallet.changePage(-1),
                .next => self.wallet.changePage(1),
                .copy_invoice => self.wallet.copy_requested = self.wallet.canCopyInvoice(),
                .review_withdrawal => {
                    self.focus = null;
                    if (self.wallet.prepareWithdrawal(self.withdrawal_invoice.slice())) {
                        self.currentPage = .Withdrawal;
                        self.selected_index = 0;
                    }
                },
                .confirm_withdrawal => {
                    _ = self.wallet.confirmWithdrawal();
                },
                .cancel_withdrawal => {
                    self.wallet.leaveWithdrawal();
                    self.withdrawal_invoice.clear();
                    self.currentPage = .Withdraw;
                    self.focus = null;
                    self.selected_index = 0;
                },
                .review_again => {
                    if (self.wallet.withdrawal.retry_review_allowed and !self.wallet.reviewLive() and !self.wallet.pending) {
                        _ = self.withdrawal_invoice.replace(self.wallet.withdrawal.invoice.slice());
                        self.currentPage = .Withdraw;
                        self.focus = null;
                        self.selected_index = 0;
                    }
                },
                .paste_withdrawal => {
                    self.focus = .withdrawal_invoice;
                    self.paste_requested = true;
                },
                .clear_withdrawal => {
                    self.withdrawal_invoice.clear();
                    self.focus = .withdrawal_invoice;
                },
            },
            .text_input => |field| {
                self.focus = field;
            },
        }
    }

    fn applyTyping(self: *Menu, field: InputField, frame: input.FrameInput) void {
        if (field == .withdrawal_invoice) {
            if (frame.paste_shortcut) {
                self.paste_requested = true;
                return;
            }
            for (frame.characters[0..@min(frame.character_count, frame.characters.len)]) |cp| _ = self.withdrawal_invoice.appendCodepoint(cp);
            if (frame.backspace) _ = self.withdrawal_invoice.backspace();
            return;
        }
        const text = self.textField(field);
        const count = @min(frame.character_count, frame.characters.len);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            _ = text.appendCodepoint(frame.characters[index]);
        }
        if (frame.backspace) _ = text.backspace();
    }
    pub fn pasteWithdrawal(self: *Menu, text: []const u8) bool {
        if (!self.opened or self.currentPage != .Withdraw or self.focus != .withdrawal_invoice) return false;
        const ok = self.withdrawal_invoice.replace(text);
        if (!ok) _ = self.wallet.message.set("Paste refused: use a complete printable invoice of at most 4096 bytes.");
        self.paste_requested = false;
        return ok;
    }
};

comptime {
    if (main_items.len > max_items_per_page)
        @compileError("Main page has more items than the fixed layout storage");
    if (wallet_items.len > max_items_per_page)
        @compileError("Wallet page has more items than the fixed layout storage");
}

// ── tests ────────────────────────────────────────────────────────────────────
test "wallet withdrawal and explicit confirmation use the Withdraw label" {
    try std.testing.expectEqualStrings("Withdraw", itemLabel(wallet_items[2]));
    try std.testing.expect(wallet_items[2] == .navigate and wallet_items[2].navigate == .Withdraw);
    try std.testing.expectEqualStrings("Withdraw", itemLabel(withdrawal_review_items[0]));
}
test "withdrawal paste is atomic UTF8 bounded and separate from deposit capacity" {
    var state = Menu{ .opened = true, .currentPage = .Withdraw, .focus = .withdrawal_invoice };
    const long = @as([4096]u8, @splat('x'));
    try std.testing.expect(state.pasteWithdrawal(&long));
    try std.testing.expect(!state.pasteWithdrawal(&@as([4097]u8, @splat('y'))));
    try std.testing.expectEqualStrings(&long, state.withdrawal_invoice.slice());
    for ([_][]const u8{ "a\nb", "a\x00b", "\xff", "a\x7fb" }) |bad| try std.testing.expect(!state.pasteWithdrawal(bad));
    try std.testing.expect(state.pasteWithdrawal("aé😀"));
    state.applyTyping(.withdrawal_invoice, .{ .backspace = true });
    try std.testing.expectEqualStrings("aé", state.withdrawal_invoice.slice());
    state.activate(.{ .action = .clear_withdrawal });
    try std.testing.expectEqualStrings("", state.withdrawal_invoice.slice());
    state.focus = .deposit_sats;
    try std.testing.expect(!state.pasteWithdrawal("invoice"));
    try std.testing.expectEqual(@as(usize, 129), state.deposit_sats.bytes.len);
    state.close();
    try std.testing.expectEqualStrings("", state.withdrawal_invoice.slice());
}
test "withdrawal field shares large wrapped geometry with hit testing on small viewports" {
    for ([_]f32{ 640, 200, 64, 1 }) |size| {
        const layout = calculateLayout(.Withdraw, size, size);
        try std.testing.expect(layout.items[0].height > layout.items[1].height);
        for (layout.items[0..layout.item_count], 0..) |rect, index| {
            try expectInside(rect, layout.panel);
            try std.testing.expect(rect.width > 0 and rect.height > 0);
            try std.testing.expectEqual(@as(?usize, index), layout.hitTest(rect.centerX(), rect.centerY()));
        }
    }
}

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
    try std.testing.expectEqual(@as(usize, 5), calculateLayout(.Wallet, 1000, 640).item_count);
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

test "Deposit clears hidden focus and disables duplicates; Withdraw navigation requests no work" {
    var state = Menu{ .opened = true, .currentPage = .Deposit, .focus = .deposit_sats };
    state.wallet.available = true;
    for ("21") |c| _ = state.deposit_sats.appendCodepoint(c);
    state.activate(.{ .action = .deposit });
    try std.testing.expectEqual(MenuPage.Invoice, state.currentPage);
    try std.testing.expectEqual(@as(?InputField, null), state.focus);
    try std.testing.expectEqual(@as(usize, 0), state.selected_index);
    const serial = state.wallet.serial;
    state.activate(.{ .action = .deposit });
    try std.testing.expectEqual(serial, state.wallet.serial);
    try typeText(&state, "7");
    try std.testing.expectEqualStrings("21", state.deposit_sats.slice());
    state.wallet.fail(serial, 0);
    try typeText(&state, "8");
    try std.testing.expectEqualStrings("21", state.deposit_sats.slice());
    state.wallet.request = null;
    state.activate(.{ .navigate = .Wallet });
    state.activate(pageItems(.Wallet)[2]);
    try std.testing.expectEqual(MenuPage.Withdraw, state.currentPage);
    try std.testing.expectEqual(@as(?InputField, null), state.focus);
    try typeText(&state, "9");
    try std.testing.expectEqualStrings("21", state.deposit_sats.slice());
    try std.testing.expectEqualStrings("", state.withdrawal_invoice.slice());
    try std.testing.expectEqual(serial, state.wallet.serial);
    try std.testing.expect(state.wallet.request == null);
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

test "Resume closes and preset replaces custom sats" {
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

    menu.currentPage = .Deposit;
    const wallet_layout = calculateLayout(.Deposit, 1000, 640);
    const field_point = itemCenter(wallet_layout, 0);
    _ = menu.applyInput(frameFor(field_point.x, field_point.y, 1000, 640));
    try typeText(&menu, "Ada");
    try std.testing.expectEqualStrings("Ada", menu.deposit_sats.slice());

    const clear_point = itemCenter(wallet_layout, 1);
    _ = menu.applyInput(frameFor(clear_point.x, clear_point.y, 1000, 640));
    try std.testing.expectEqualStrings("21", menu.deposit_sats.slice());
    try std.testing.expect(menu.opened);
}

test "typing only reaches a focused input field" {
    var menu = Menu{};
    _ = menu.applyInput(.{ .escape_clicked = true });

    // No focus on Main: keystrokes are consumed but ignored.
    try typeText(&menu, "ignored");
    try std.testing.expectEqualStrings("", menu.deposit_sats.slice());

    // Navigating to Wallet still leaves fields unfocused.
    const main_layout = calculateLayout(.Main, 1000, 640);
    const wallet_point = itemCenter(main_layout, 0);
    _ = menu.applyInput(frameFor(wallet_point.x, wallet_point.y, 1000, 640));
    try typeText(&menu, "still-ignored");
    try std.testing.expectEqualStrings("", menu.deposit_sats.slice());

    // Clicking the field gives it focus.
    menu.currentPage = .Deposit;
    const wallet_layout = calculateLayout(.Deposit, 1000, 640);
    const field_point = itemCenter(wallet_layout, 0);
    _ = menu.applyInput(frameFor(field_point.x, field_point.y, 1000, 640));
    try std.testing.expectEqual(@as(?InputField, .deposit_sats), menu.focus);
    try typeText(&menu, "Ada");
    try std.testing.expectEqualStrings("Ada", menu.deposit_sats.slice());

    // Clicking outside every item blurs; later typing is ignored.
    _ = menu.applyInput(frameFor(1, 1, 1000, 640));
    try std.testing.expectEqual(@as(?InputField, null), menu.focus);
    try typeText(&menu, "zzz");
    try std.testing.expectEqualStrings("Ada", menu.deposit_sats.slice());
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
    while (index < max_text_bytes) : (index += 1) {
        try std.testing.expect(full.appendCodepoint('x'));
    }
    try std.testing.expectEqual(max_text_bytes, full.len);
    try std.testing.expect(!full.appendCodepoint('y'));
    try std.testing.expectEqual(max_text_bytes, full.len);
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

    menu.currentPage = .Deposit;
    const wallet_layout = calculateLayout(.Deposit, 1000, 640);
    const field_point = itemCenter(wallet_layout, 0);
    _ = menu.applyInput(frameFor(field_point.x, field_point.y, 1000, 640));
    try std.testing.expectEqual(@as(?InputField, .deposit_sats), menu.focus);

    // Navigation blurs.
    const back_point = itemCenter(wallet_layout, pageItems(.Deposit).len - 1);
    _ = menu.applyInput(frameFor(back_point.x, back_point.y, 1000, 640));
    try std.testing.expectEqual(@as(?InputField, null), menu.focus);

    // Resume also blurs; reopening starts on Main with nothing focused.
    menu.activate(.{ .navigate = .Main });
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
    menu.currentPage = .Deposit;
    const field_point = itemCenter(calculateLayout(.Deposit, 1000, 640), 0);
    _ = menu.applyInput(frameFor(field_point.x, field_point.y, 1000, 640));
    try typeText(&menu, "Ada");

    const idle = input.FrameInput{ .viewport_w = 1000, .viewport_h = 640 };
    var frame_index: usize = 0;
    while (frame_index < 5) : (frame_index += 1) {
        try std.testing.expect(menu.applyInput(idle));
    }
    try std.testing.expect(menu.opened);
    try std.testing.expectEqual(MenuPage.Deposit, menu.currentPage);
    try std.testing.expectEqual(@as(?InputField, .deposit_sats), menu.focus);
    try std.testing.expectEqualStrings("Ada", menu.deposit_sats.slice());

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
    menu.currentPage = .Deposit;
    _ = menu.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(@as(?InputField, .deposit_sats), menu.focus);
    try typeText(&menu, "Ada");
    try std.testing.expectEqualStrings("Ada", menu.deposit_sats.slice());

    // Moving away blurs the field.
    _ = menu.applyInput(.{ .down = true });
    try std.testing.expectEqual(@as(?InputField, null), menu.focus);
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);

    // Selected action clears the name and leaves the menu open.
    _ = menu.applyInput(.{ .confirm = true });
    try std.testing.expectEqualStrings("21", menu.deposit_sats.slice());
    try std.testing.expect(menu.opened);

    // Back to Main, then Resume closes through the same action handler.
    menu.activate(.{ .navigate = .Main });
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
    menu.currentPage = .Deposit;
    const wallet_layout = calculateLayout(.Deposit, 1000, 640);
    const field = itemCenter(wallet_layout, 0);
    _ = menu.applyInput(.{
        .pointer_x = field.x,
        .pointer_y = field.y,
        .clicked = true,
    });
    try std.testing.expectEqual(@as(?InputField, .deposit_sats), menu.focus);
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
    menu.currentPage = .Deposit;
    _ = menu.applyInput(.{ .confirm = true }); // focus the name field
    try std.testing.expectEqual(@as(?InputField, .deposit_sats), menu.focus);

    // WASD and space type normally and never move the highlight.
    try typeText(&menu, "wasd xyz");
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
    try std.testing.expectEqualStrings("wasd xyz", menu.deposit_sats.slice());

    // A direction step blurs the field; later typing goes nowhere and still
    // does not move the highlight.
    _ = menu.applyInput(.{ .down = true });
    try std.testing.expectEqual(@as(?InputField, null), menu.focus);
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);
    try typeText(&menu, "ignored");
    try std.testing.expectEqualStrings("wasd xyz", menu.deposit_sats.slice());
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);
}

test "history pagination only shows existing pages and rows precede Back" {
    var state = Menu{ .opened = true, .currentPage = .History };
    for ([_]struct { total: usize, offset: u32, previous: bool, next: bool }{
        .{ .total = 0, .offset = 0, .previous = false, .next = false },
        .{ .total = 9, .offset = 0, .previous = false, .next = true },
        .{ .total = 9, .offset = 8, .previous = true, .next = false },
        .{ .total = 17, .offset = 8, .previous = true, .next = true },
    }) |case| {
        state.wallet.total_rows = case.total;
        state.wallet.desired_offset = case.offset;
        const items = state.items();
        try std.testing.expectEqual(@as(usize, 1) + @intFromBool(case.previous) + @intFromBool(case.next), items.len);
        var previous = false;
        var next = false;
        for (items) |item| if (item == .action) {
            previous = previous or item.action == .previous;
            next = next or item.action == .next;
        };
        try std.testing.expectEqual(case.previous, previous);
        try std.testing.expectEqual(case.next, next);
    }
    state.wallet.row_count = 1;
    state.wallet.total_rows = 1;
    state.wallet.desired_offset = 0;
    state.selected_index = 1;
    _ = state.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(MenuPage.Wallet, state.currentPage);
    try std.testing.expectEqual(@as(usize, 5), wallet_items.len);
    try std.testing.expectEqual(@as(usize, 3), invoice_items.len);
}

test "history keyboard and pointer selection open a saved invoice" {
    var state = Menu{ .opened = true, .currentPage = .History };
    state.wallet.available = true;
    state.wallet.row_count = 1;
    _ = state.wallet.mint.set("https://testnut.cashu.space");
    _ = state.wallet.rows[0].mint.set(state.wallet.mint.slice());
    _ = state.wallet.rows[0].id.set("saved");
    _ = state.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(MenuPage.Invoice, state.currentPage);
    try std.testing.expect(state.wallet.pending and state.wallet.operation == .saved_invoice);
    try std.testing.expectEqualStrings("saved", state.wallet.request.?.argument.slice());
    state.wallet.pending = false;
    state.currentPage = .History;
    const layout = state.layoutFor(1000, 640);
    _ = state.applyInput(frameFor(layout.content.centerX(), layout.content.y + layout.content.height / 16, 1000, 640));
    try std.testing.expectEqual(MenuPage.Invoice, state.currentPage);
}

test "invoice Back uses third row and expired Deposit navigation returns to amount entry" {
    var state = Menu{ .opened = true, .currentPage = .Invoice, .selected_index = 2 };
    _ = state.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(MenuPage.Wallet, state.currentPage);
    _ = state.wallet.invoice.set("lnbc-saved");
    state.wallet.expired = true;
    state.activate(.{ .navigate = .Deposit });
    try std.testing.expectEqual(MenuPage.Deposit, state.currentPage);
    state.currentPage = .Wallet;
    state.wallet.expired = false;
    state.activate(.{ .navigate = .Deposit });
    try std.testing.expectEqual(MenuPage.Invoice, state.currentPage);
}

test "outgoing history opens only withdrawal detail and other mint activation retains History" {
    var state = Menu{ .opened = true, .currentPage = .History };
    state.wallet.available = true;
    state.wallet.row_count = 1;
    _ = state.wallet.mint.set("https://testnut.cashu.space");
    _ = state.wallet.invoice.set("old-invoice");
    _ = state.wallet.rows[0].id.set("saved");
    _ = state.wallet.rows[0].mint.set(state.wallet.mint.slice());
    state.wallet.rows[0].outgoing = true;
    _ = state.applyInput(.{ .confirm = true });
    try std.testing.expectEqual(MenuPage.Withdrawal, state.currentPage);
    try std.testing.expect(state.wallet.operation == .saved_withdrawal);
    try std.testing.expectEqualStrings("", state.wallet.invoice.slice());
    state.wallet.request = null;
    state.wallet.fail(state.wallet.serial, 0);
    state.currentPage = .History;
    state.wallet.rows[0].outgoing = false;
    _ = state.wallet.rows[0].mint.set("https://other.example");
    const layout = state.layoutFor(1000, 640);
    _ = state.applyInput(frameFor(layout.content.centerX(), layout.content.y + layout.content.height / 16, 1000, 640));
    try std.testing.expectEqual(MenuPage.History, state.currentPage);
    try std.testing.expect(!state.wallet.pending);
    try std.testing.expectEqualStrings("", state.wallet.invoice.slice());
}

test "local deposit input and invoice copy remain active during background polling" {
    var state = Menu{ .opened = true, .currentPage = .Deposit };
    state.wallet.available = true;
    try std.testing.expect(state.wallet.enqueue(.poll, ""));
    state.activate(.{ .action = .preset42 });
    try std.testing.expectEqualStrings("42", state.deposit_sats.slice());
    state.activate(.{ .text_input = .deposit_sats });
    try std.testing.expectEqual(@as(?InputField, .deposit_sats), state.focus);
    try typeText(&state, "1");
    try std.testing.expectEqualStrings("421", state.deposit_sats.slice());
    state.applyTyping(.deposit_sats, .{ .backspace = true });
    try std.testing.expectEqualStrings("42", state.deposit_sats.slice());
    _ = state.wallet.invoice.set("lnbc-saved");
    state.activate(.{ .action = .copy_invoice });
    try std.testing.expect(state.wallet.copy_requested);
    state.activate(.{ .action = .deposit });
    try std.testing.expectEqual(MenuPage.Invoice, state.currentPage);
    try std.testing.expect(state.wallet.queued.?.operation == .create);
    state.currentPage = .Deposit;
    state.activate(.{ .action = .deposit });
    try std.testing.expectEqual(MenuPage.Deposit, state.currentPage);
}
