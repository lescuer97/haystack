//! Pure, bounded wallet presentation. Services own handles and source pagination.
const std = @import("std");
const qr_mod = @import("qr.zig");
pub const Operation = enum {
    open,
    snapshot,
    create,
    check,
    history,
    resume_saved,
    recover,
    poll,
    saved_invoice,
    prepare_withdrawal,
    confirm_withdrawal,
    cancel_withdrawal,
    saved_withdrawal,
    poll_withdrawals,

    pub fn isWithdrawal(self: Operation) bool {
        return switch (self) {
            .prepare_withdrawal, .confirm_withdrawal, .cancel_withdrawal, .saved_withdrawal, .poll_withdrawals => true,
            else => false,
        };
    }
};
pub const Request = struct { operation: Operation, argument: Text(4096) = .{}, serial: u32 };
pub fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity + 1]u8 = @splat(0),
        len: usize = 0,
        pub fn set(self: *@This(), value: []const u8) bool {
            if (value.len > capacity or std.mem.indexOfScalar(u8, value, 0) != null) return false;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
            self.bytes[self.len] = 0;
            return true;
        }
        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
        pub fn z(self: *const @This()) [:0]const u8 {
            return self.bytes[0..self.len :0];
        }
    };
}
pub const Row = struct { outgoing: bool = false, mint: Text(256) = .{}, id: Text(1024) = .{}, text: Text(512) = .{} };
pub const Recovery = enum { none, unknown, legacy_unknown };
// Ephemeral withdrawal presentation. CDK owns reservations, payments and recovery.
const withdrawal = struct {
    pub const Status = enum { prepared, pending, completed, failed, unsubmitted, unknown };
    pub const View = struct {
        operation_id: Text(1024) = .{},
        quote_id: Text(1024) = .{},
        invoice: Text(4096) = .{},
        amount: Text(20) = .{},
        fee_reserve: Text(20) = .{},
        swap_fee: Text(20) = .{},
        input_fee: Text(20) = .{},
        estimated_total: Text(20) = .{},
        quote_expiry: Text(20) = .{},
        invoice_expiry: Text(20) = .{},
        quote_state: Text(32) = .{},
        status: Status = .unknown,
        expired: bool = false,
        retry_review_allowed: bool = false,

        pub fn parse(value: std.json.Value, mint: []const u8, prepared: bool) !View {
            var result: View = .{};
            if (!std.mem.eql(u8, try requiredString(value, "mint_url"), mint) or !std.mem.eql(u8, try requiredString(value, "unit"), "msat")) return error.Invalid;
            try put(&result.quote_id, try requiredString(value, "quote_id"));
            try put(&result.invoice, try requiredString(value, "invoice"));
            try number(&result.amount, try requiredString(value, "amount"));
            try number(&result.quote_expiry, try requiredString(value, "quote_expiry"));
            if (prepared) {
                try put(&result.operation_id, try requiredString(value, "operation_id"));
                try number(&result.fee_reserve, try requiredString(value, "fee_reserve"));
                try number(&result.swap_fee, try requiredString(value, "swap_fee"));
                try number(&result.input_fee, try requiredString(value, "input_fee"));
                try number(&result.estimated_total, try requiredString(value, "estimated_total"));
                try number(&result.invoice_expiry, try requiredString(value, "invoice_expiry"));
                _ = try boolean(value, "requires_swap");
                result.status = .prepared;
            } else {
                try put(&result.quote_state, try requiredString(value, "quote_state"));
                result.status = std.meta.stringToEnum(Status, try requiredString(value, "payment_status")) orelse return error.Invalid;
                result.expired = try boolean(value, "expired");
                result.retry_review_allowed = try boolean(value, "retry_review_allowed");
                const expiry = value.object.get("invoice_expiry") orelse return error.Invalid;
                if (expiry != .null) try number(&result.invoice_expiry, try requiredString(value, "invoice_expiry"));
            }
            return result;
        }
        pub fn deadlinePassed(self: *const View, unix: u64) bool {
            for ([_][]const u8{ self.quote_expiry.slice(), self.invoice_expiry.slice() }) |text| {
                if (text.len != 0 and unix >= (std.fmt.parseInt(u64, text, 10) catch return true)) return true;
            }
            return false;
        }
    };
    fn requiredString(value: std.json.Value, key: []const u8) ![]const u8 {
        if (value != .object) return error.Invalid;
        const field = value.object.get(key) orelse return error.Invalid;
        return if (field == .string) field.string else error.Invalid;
    }
    fn boolean(value: std.json.Value, key: []const u8) !bool {
        const field = value.object.get(key) orelse return error.Invalid;
        return if (field == .bool) field.bool else error.Invalid;
    }
    fn put(target: anytype, text: []const u8) !void {
        if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return error.Invalid;
        for (text) |c| if (c < 32 or c == 127) return error.Invalid;
        if (!target.set(text)) return error.Invalid;
    }
    fn number(target: anytype, text: []const u8) !void {
        if (text.len == 0 or text.len > 20) return error.Invalid;
        for (text) |c| if (c < '0' or c > '9') return error.Invalid;
        _ = std.fmt.parseInt(u64, text, 10) catch return error.Invalid;
        try put(target, text);
    }
};

pub const Model = struct {
    withdrawal: withdrawal.View = .{},
    withdrawal_selected: Text(1024) = .{},
    withdrawal_request_id: Text(1024) = .{},
    withdrawal_cursor: Text(1024) = .{},
    withdrawal_loading: bool = false,
    abandon_review: bool = false,
    withdrawal_blocked: bool = false,
    prepare_unknown: bool = false,
    withdrawal_error_status: u8 = 0,
    withdrawal_error_operation: Operation = .prepare_withdrawal,
    next_withdrawal_poll: f64 = 2,
    withdrawal_backoff: f64 = 2,
    unix_now: u64 = 0,
    started: bool = false,
    available: bool = false,
    pending: bool = false,
    serial: u32 = 0,
    operation: Operation = .open,
    request: ?Request = null,
    queued: ?Request = null,
    balance_dirty: bool = false,
    history_dirty: bool = true,
    history_active: bool = false,
    history_next_expiry: ?u64 = null,
    resume_needed: bool = false,
    next_resume: f64 = 0,
    resume_backoff: f64 = 2,
    recover_needed: bool = false,
    recovery_pending: bool = false,
    selected_id: Text(1024) = .{},
    selection_loading: bool = false,
    recovery: Recovery = .none,
    balance: Text(100) = .{},
    mint: Text(256) = .{},
    message: Text(160) = .{},
    invoice: Text(4096) = .{},
    quote_id: Text(1024) = .{},
    check_id: Text(1024) = .{},
    quote_state: Text(32) = .{},
    sweep_cursor: Text(1024) = .{},
    check_turn: bool = false,
    expired: bool = false,
    next_recover: f64 = 0,
    recover_backoff: f64 = 2,
    qr: qr_mod.Qr = .{},
    next_check: f64 = 0,
    backoff: f64 = 2,
    issued: bool = false,
    copy_requested: bool = false,
    desired_offset: u32 = 0,
    pending_offset: u32 = 0,
    row_count: usize = 0,
    total_rows: usize = 0,
    history_error: bool = false,
    rows: [8]Row = @splat(.{}),

    pub fn enqueue(self: *Model, operation: Operation, argument: []const u8) bool {
        if (self.reviewLive() and operation != .confirm_withdrawal and operation != .cancel_withdrawal and operation != .snapshot and operation != .history and operation != .saved_withdrawal and operation != .saved_invoice) return false;
        if (self.queued != null or (operation != .open and !self.available)) return false;
        if (self.pending and self.operation != .poll and self.operation != .check and self.operation != .poll_withdrawals) return false;
        var req = Request{ .operation = operation, .serial = 0 };
        if (!req.argument.set(argument)) return false;
        if (operation == .history) {
            const offset = decimal(argument) catch return false;
            if (offset > std.math.maxInt(u32) or offset % 8 != 0) return false;
        }
        if (self.pending) {
            self.queued = req;
        } else self.publish(req);
        return true;
    }
    fn publish(self: *Model, request: Request) void {
        var req = request;
        req.serial = self.serial +% 1;
        self.serial = req.serial;
        if (req.operation == .check) _ = self.check_id.set(req.argument.slice());
        if (req.operation == .saved_withdrawal or req.operation == .confirm_withdrawal or req.operation == .cancel_withdrawal) _ = self.withdrawal_request_id.set(if (req.operation == .saved_withdrawal) req.argument.slice() else self.withdrawal.quote_id.slice());
        if (req.operation == .history) self.pending_offset = @intCast(decimal(req.argument.slice()) catch unreachable);
        self.operation = req.operation;
        self.request = req;
        self.pending = true;
    }
    fn publishQueued(self: *Model) void {
        // A transport must consume the published request before its slot is reused.
        if (self.pending or self.request != null) return;
        if (self.abandon_review and self.withdrawal.operation_id.len != 0) {
            self.queued = null;
            var req = Request{ .operation = .cancel_withdrawal, .serial = 0 };
            _ = req.argument.set(self.withdrawal.operation_id.slice());
            self.publish(req);
            return;
        }
        if (self.queued) |req| {
            self.queued = null;
            self.publish(req);
        }
    }
    pub fn tick(self: *Model, ready: bool, now: f64) void {
        if (!ready or self.pending) return;
        self.publishQueued();
        if (self.pending or self.queued != null) return;
        if (!self.started) {
            self.started = true;
            _ = self.message.set("Opening wallet...");
            _ = self.enqueue(.open, "");
        } else if (self.available) {
            if (self.history_active) {
                if (self.history_next_expiry) |expiry| {
                    if (self.unix_now > expiry) {
                        self.history_next_expiry = null;
                        self.history_dirty = true;
                    }
                }
            }
            if (self.reviewLive() or self.withdrawal_blocked) {
                if (self.balance_dirty) {
                    self.balance_dirty = false;
                    _ = self.enqueue(.snapshot, "");
                } else if (self.history_active and self.history_dirty) {
                    self.history_dirty = false;
                    var buf: [16]u8 = undefined;
                    _ = self.enqueue(.history, std.fmt.bufPrint(&buf, "{d}", .{self.desired_offset}) catch unreachable);
                }
                return;
            }
            if (self.recover_needed and now >= self.next_recover) {
                if (self.enqueue(.recover, "")) self.recover_needed = false;
            } else if (self.balance_dirty) {
                self.balance_dirty = false;
                _ = self.enqueue(.snapshot, "");
            } else if (self.resume_needed and now >= self.next_resume) {
                self.resume_needed = false;
                _ = self.enqueue(.resume_saved, "");
            } else if (self.history_active and self.history_dirty) {
                var buf: [16]u8 = undefined;
                const offset = std.fmt.bufPrint(&buf, "{d}", .{self.desired_offset}) catch unreachable;
                self.history_dirty = false;
                _ = self.enqueue(.history, offset);
            } else if (!self.selection_loading) {
                const deposit_due = !self.recovery_pending and now >= self.next_check;
                const withdrawal_due = now >= self.next_withdrawal_poll;
                // Serve the older deadline; equal deadlines retain the deposit's existing slot.
                if (withdrawal_due and (!deposit_due or self.next_withdrawal_poll < self.next_check)) {
                    _ = self.enqueue(.poll_withdrawals, self.withdrawal_cursor.slice());
                    return;
                }
                if (!deposit_due) return;
                self.check_turn = !self.check_turn;
                if (self.quote_id.len != 0 and !self.issued and !self.expired and !self.check_turn) {
                    _ = self.enqueue(.check, self.quote_id.slice());
                } else _ = self.enqueue(.poll, self.sweep_cursor.slice());
            }
        }
    }
    pub fn visit(self: *Model, history: bool, balance: bool) void {
        self.history_active = history;
        if (history) self.history_dirty = true;
        if (balance) self.balance_dirty = true;
    }
    pub fn create(self: *Model, text: []const u8) bool {
        if (self.reviewLive() or self.withdrawal_blocked) return false;
        _ = positiveMsats(text) catch {
            _ = self.message.set("Enter positive integer msats (no decimals).");
            return false;
        };
        if (self.recovery != .none or self.recovery_pending) {
            self.recoveryMessage();
            return false;
        }
        if (!self.enqueue(.create, text)) return false;
        _ = self.message.set("Creating saved invoice...");
        return true;
    }
    pub fn openRow(self: *Model, index: usize) bool {
        // A saved-row read must not overwrite the only cancellation token.
        if (self.reviewLive() or self.withdrawal_blocked) return false;
        if (index >= self.row_count) return false;
        const row = &self.rows[index];
        if (row.id.len == 0 or row.mint.len == 0 or !std.mem.eql(u8, row.mint.slice(), self.mint.slice())) {
            _ = self.message.set("Saved invoice opening is available only for this mint's deposits.");
            return false;
        }
        if (row.outgoing) {
            if (!self.enqueue(.saved_withdrawal, row.id.slice())) return false;
            self.clearWithdrawalError();
            self.withdrawal = .{};
            _ = self.withdrawal_selected.set(row.id.slice());
            self.withdrawal_loading = true;
            self.copy_requested = false;
            self.invoice = .{};
            self.quote_id = .{};
            self.qr = .{};
            _ = self.selected_id.set("withdrawal-selection");
            return true;
        }
        if (!self.enqueue(.saved_invoice, row.id.slice())) return false;
        self.clearWithdrawalError();
        self.withdrawal_selected = .{};
        self.withdrawal = .{};
        _ = self.selected_id.set(row.id.slice());
        self.selection_loading = true;
        self.invoice = .{};
        self.quote_id = .{};
        self.quote_state = .{};
        self.qr = .{};
        self.issued = false;
        self.expired = false;
        self.copy_requested = false;
        _ = self.message.set("Loading saved invoice...");
        return true;
    }
    pub fn canCopyInvoice(self: *const Model) bool {
        return !self.selection_loading and self.invoice.len != 0 and (self.selected_id.len == 0 or std.mem.eql(u8, self.selected_id.slice(), self.quote_id.slice()));
    }
    fn acceptsSelection(self: *const Model, id: []const u8) bool {
        return self.selected_id.len == 0 or std.mem.eql(u8, self.selected_id.slice(), id);
    }
    pub fn changePage(self: *Model, delta: i32) void {
        if (!self.available) return;
        if (delta < 0 and self.desired_offset >= 8) self.desired_offset -= 8;
        if (delta > 0 and @as(u64, self.desired_offset) + 8 < self.total_rows) self.desired_offset += 8;
        self.history_dirty = true;
    }
    pub fn fail(self: *Model, serial: u32, now: f64) void {
        if (!self.pending or serial != self.serial) return;
        self.pending = false;
        if (self.operation.isWithdrawal() and !(self.withdrawal_error_operation == .cancel_withdrawal and (self.reviewLive() or self.withdrawal_blocked))) self.clearWithdrawalError();
        self.invalidateMutation();
        switch (self.operation) {
            .prepare_withdrawal => {
                self.withdrawal_blocked = true;
                self.prepare_unknown = !self.abandon_review;
                _ = self.message.set(if (self.abandon_review) "Abandoned review outcome unknown; work paused. Restart for CDK recovery." else "Review outcome unknown. Back allows CDK recovery; do not retry automatically.");
            },
            .confirm_withdrawal => {
                self.withdrawal.operation_id = .{};
                self.abandon_review = false;
                _ = self.message.set("Payment outcome unknown; CDK will check saved work. Do not pay again.");
            },
            .cancel_withdrawal => {
                self.withdrawal_blocked = true;
                self.abandon_review = false;
                _ = self.message.set("Cancellation unconfirmed; funds may remain reserved. Conflicting work paused; restart for CDK recovery.");
            },
            .saved_withdrawal => {
                self.withdrawal_loading = false;
                _ = self.message.set("Saved withdrawal unavailable. Back and retry.");
            },
            .poll_withdrawals => self.withdrawalPollFailed(now),
            .saved_invoice => {
                self.selection_loading = false;
                _ = self.message.set("Selected saved invoice unavailable; copy disabled. Reopen to retry.");
            },
            .open => {
                self.available = false;
                _ = self.message.set("Wallet unavailable; data preserved.");
            },
            .history => {
                self.history_error = true;
                _ = self.message.set("History read failed; Back and retry. Wallet remains available.");
            },
            .resume_saved => {
                self.resume_needed = true;
                self.next_resume = now + self.resume_backoff;
                self.resume_backoff = @min(30, self.resume_backoff * 2);
                _ = self.message.set("Saved invoice read failed; current invoice retained; retrying automatically.");
            },
            .recover => {
                self.recover_needed = true;
                self.recover_backoff = @min(30, self.recover_backoff * 2);
                self.next_recover = now + self.recover_backoff;
                _ = self.message.set("Recovery read failed; retrying automatically.");
            },
            .snapshot => {
                _ = self.message.set("Balance read failed; last balance retained. Reopen Wallet to retry.");
            },
            .create => {
                self.recovery = .unknown;
                self.recover_needed = true;
                self.next_recover = now;
                _ = self.message.set("Creation failed; checking saved evidence without creating another invoice.");
            },
            .check => {
                self.backoff = @min(30, self.backoff * 2);
                self.next_check = now + self.backoff;
                _ = self.message.set("Payment check failed; saved invoice retained; retrying with backoff.");
            },
            .poll => self.pollFailed(now),
        }
        self.publishQueued();
    }
    pub fn accept(self: *Model, serial: u32, raw: []const u8, now: f64, allocator: std.mem.Allocator) void {
        if (!self.pending or serial != self.serial) return;
        if (raw.len > 128 * 1024) {
            self.fail(serial, now);
            return;
        }
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
            self.fail(serial, now);
            return;
        };
        defer parsed.deinit();
        self.deliver(parsed.value, now) catch {
            self.fail(serial, now);
            return;
        };
        self.pending = false;
        self.invalidateMutation();
        self.publishQueued();
    }
    fn deliver(self: *Model, value: std.json.Value, now: f64) !void {
        if (value != .object) return error.Invalid;
        if (self.operation.isWithdrawal()) if (value.object.get("operation_error")) |detail| {
            if (detail != .object) return error.Invalid;
            const status = detail.object.get("status") orelse return error.Invalid;
            const message = try withdrawal.requiredString(detail, "message");
            if (status != .integer or status.integer < 1 or status.integer > 27 or message.len > 160 or !std.unicode.utf8ValidateSlice(message)) return error.Invalid;
            for (message) |c| if (c < 32 or c == 127) return error.Invalid;
            self.withdrawalOperationFailed(@intCast(status.integer), now);
            return;
        };
        if (self.operation == .check or self.operation == .poll or self.operation == .recover) {
            if (value.object.get("wallet_changed")) |changed| {
                const pending = value.object.get("recovery_pending") orelse return error.Invalid;
                const status = try recoveryState(value);
                if (changed != .bool or pending != .bool) return error.Invalid;
                if (changed.bool) {
                    self.balance_dirty = true;
                    self.history_dirty = true;
                }
                self.recovery_pending = pending.bool;
                self.setRecovery(status, now);
                if (valueError(value)) {
                    const detail = value.object.get("error").?;
                    if (detail != .object) return error.Invalid;
                    const code = detail.object.get("status") orelse return error.Invalid;
                    const message = string(detail, "message") orelse return error.Invalid;
                    if (code != .integer or message.len > 256 or std.mem.indexOfScalar(u8, message, 0) != null) return error.Invalid;
                    if (self.operation == .poll) {
                        const cursor = value.object.get("cursor") orelse return error.Invalid;
                        if (cursor != .null) {
                            if (cursor != .string or cursor.string.len > 1024 or std.mem.indexOfScalar(u8, cursor.string, 0) != null) return error.Invalid;
                            _ = self.sweep_cursor.set(cursor.string);
                        }
                    }
                    if (self.operation == .poll or self.operation == .check) self.pollFailed(now);
                    if (self.operation == .recover) {
                        if (!self.recover_needed) {
                            self.recover_needed = true;
                            self.next_recover = now + self.recover_backoff;
                            self.recover_backoff = @min(30, self.recover_backoff * 2);
                        }
                        _ = self.message.set("Recovery remains pending; retrying with backoff.");
                    }
                    return;
                }
                if (self.operation == .check) {
                    const invoice = value.object.get("invoice") orelse return error.Invalid;
                    if (invoice != .null) {
                        const id = string(invoice, "id") orelse return error.Invalid;
                        if (!std.mem.eql(u8, id, self.check_id.slice())) return error.Invalid;
                        if (self.acceptsSelection(id)) try self.acceptInvoice(invoice, now);
                    }
                    return;
                }
            }
        }
        switch (self.operation) {
            .prepare_withdrawal => {
                self.withdrawal = try withdrawal.View.parse(value, self.mint.slice(), true);
                self.withdrawal_selected = .{};
                _ = self.message.set("Review fees, then explicitly Withdraw. Estimated total is not a guaranteed cap.");
            },
            .confirm_withdrawal, .saved_withdrawal => {
                const view = try withdrawal.View.parse(value, self.mint.slice(), false);
                if (!std.mem.eql(u8, view.quote_id.slice(), self.withdrawal_request_id.slice())) return error.Invalid;
                if (self.withdrawal_selected.len == 0 or std.mem.eql(u8, view.quote_id.slice(), self.withdrawal_selected.slice())) {
                    self.withdrawal = view;
                    if (!self.reviewLive() and !self.withdrawal_blocked) self.clearWithdrawalError();
                }
                self.withdrawal_loading = false;
                self.abandon_review = false;
                _ = self.message.set("Saved withdrawal; status comes from CDK. Pending checks continue with menu closed.");
            },
            .cancel_withdrawal => {
                const id = try withdrawal.requiredString(value, "quote_id");
                const cancelled = value.object.get("cancelled") orelse return error.Invalid;
                if (!std.mem.eql(u8, id, self.withdrawal_request_id.slice()) or cancelled != .bool or !cancelled.bool) return error.Invalid;
                self.withdrawal = .{};
                self.abandon_review = false;
                self.withdrawal_blocked = false;
                self.clearWithdrawalError();
                _ = self.message.set("Unsubmitted review cancelled; rereading wallet balance.");
            },
            .poll_withdrawals => {
                const cursor = try withdrawal.requiredString(value, "cursor");
                var checked_cursor: Text(1024) = .{};
                if (!checked_cursor.set(cursor)) return error.Invalid;
                const checked = value.object.get("checked_id") orelse return error.Invalid;
                if (checked != .null and (checked != .string or checked.string.len > 1024 or std.mem.indexOfScalar(u8, checked.string, 0) != null)) return error.Invalid;
                const pending = value.object.get("recovery_pending") orelse return error.Invalid;
                if (pending != .bool) return error.Invalid;
                const changed = value.object.get("wallet_changed") orelse std.json.Value{ .bool = false };
                if (changed != .bool) return error.Invalid;
                if (changed.bool) {
                    self.balance_dirty = true;
                    self.history_dirty = true;
                }
                self.recovery_pending = pending.bool;
                self.setRecovery(self.recovery, now);
                const item = value.object.get("withdrawal") orelse return error.Invalid;
                if (item != .null) {
                    const view = try withdrawal.View.parse(item, self.mint.slice(), false);
                    if (checked != .string or !std.mem.eql(u8, checked.string, view.quote_id.slice())) return error.Invalid;
                    // Old envelopes lacked wallet_changed; retain their conservative invalidation.
                    if (value.object.get("wallet_changed") == null) {
                        self.balance_dirty = true;
                        self.history_dirty = true;
                    }
                    if (!self.withdrawal_loading and std.mem.eql(u8, view.quote_id.slice(), self.withdrawal.quote_id.slice()) and (self.withdrawal_selected.len == 0 or std.mem.eql(u8, view.quote_id.slice(), self.withdrawal_selected.slice()))) self.withdrawal = view;
                }
                self.withdrawal_cursor = checked_cursor;
                if (valueError(value)) {
                    const detail = value.object.get("error").?;
                    const code = if (detail == .object) detail.object.get("status") orelse return error.Invalid else return error.Invalid;
                    const message = try withdrawal.requiredString(detail, "message");
                    if (code != .integer or message.len > 256 or std.mem.indexOfScalar(u8, message, 0) != null) return error.Invalid;
                    self.withdrawalPollFailed(now);
                } else {
                    // An inactive wallet needs no frame-by-frame empty sweeps. Active
                    // saved work still gets the normal two-second check cadence.
                    self.withdrawal_backoff = if (item == .null and !pending.bool and self.withdrawal.status != .pending) @min(30, self.withdrawal_backoff * 2) else 2;
                    self.next_withdrawal_poll = now + self.withdrawal_backoff;
                }
            },
            .saved_invoice => {
                const id = string(value, "id") orelse return error.Invalid;
                if (!self.acceptsSelection(id)) return error.Invalid;
                try self.acceptInvoice(value, now);
                self.selection_loading = false;
                self.next_check = now;
            },
            .open, .snapshot => {
                const mint = string(value, "mint_url") orelse return error.Invalid;
                if (self.mint.len != 0 and !std.mem.eql(u8, mint, self.mint.slice())) return error.Invalid;
                const msats = string(value, "msats") orelse return error.Invalid;
                _ = try decimal(msats);
                const recovery = try recoveryState(value);
                if (value.object.get("recovery_pending")) |pending| {
                    if (pending != .bool) return error.Invalid;
                    self.recovery_pending = pending.bool;
                }
                if (mint.len > 256) return error.Invalid;
                var buf: [100]u8 = undefined;
                _ = self.balance.set(try std.fmt.bufPrint(&buf, "{s} msat", .{msats}));
                _ = self.mint.set(mint);
                self.setRecovery(recovery, now);
                self.available = true;
                if (self.operation == .open) self.resume_needed = true;
                if (!self.withdrawal_blocked and !self.reviewLive() and self.withdrawal.quote_id.len == 0) {
                    if (self.issued) _ = self.message.set("Deposit minted. Balance reread from wallet.") else if (self.invoice.len == 0) _ = self.message.set("Experimental test funds only.");
                }
                self.recoveryMessage();
            },
            .create, .check => {
                if (self.operation == .check and !std.mem.eql(u8, string(value, "id") orelse return error.Invalid, self.check_id.slice())) return error.Invalid;
                if (self.operation == .check and !self.acceptsSelection(string(value, "id") orelse return error.Invalid)) return;
                if (self.operation == .create) self.selected_id = .{};
                const old_state = self.quote_state;
                const old_id = self.quote_id;
                const was_issued = self.issued;
                try self.acceptInvoice(value, now);
                if (self.operation == .create or !std.mem.eql(u8, old_id.slice(), self.quote_id.slice()) or !std.mem.eql(u8, old_state.slice(), self.quote_state.slice()) or was_issued != self.issued) self.history_dirty = true;
                if (self.issued and (!was_issued or !std.mem.eql(u8, old_id.slice(), self.quote_id.slice()))) self.balance_dirty = true;
                if (self.operation == .create) self.recover_needed = true;
            },
            .history => try self.acceptHistory(value),
            .resume_saved => {
                const invoice = value.object.get("invoice") orelse return error.Invalid;
                if (invoice == .null) {
                    if (value.object.get("error") != null) {
                        _ = self.message.set("Newest saved invoice exceeds display limit; retained in wallet, not deleted.");
                    } else {
                        _ = self.message.set("No unfinished saved invoices.");
                    }
                } else {
                    const id = string(invoice, "id") orelse return error.Invalid;
                    if (id.len == 0 or id.len > 1024 or std.mem.indexOfScalar(u8, id, 0) != null) return error.Invalid;
                    // A delayed startup retry must not replace a history
                    // selection made while the saved-invoice read backed off.
                    if (self.acceptsSelection(id) and (self.quote_id.len == 0 or std.mem.eql(u8, id, self.quote_id.slice()))) try self.acceptInvoice(invoice, now);
                }
                self.resume_needed = false;
                self.resume_backoff = 2;
                self.next_resume = 0;
                self.recoveryMessage();
            },
            .recover => {
                const status = try recoveryState(value);
                const application = value.object.get("wallet_changed") != null;
                const invoice = value.object.get("invoice") orelse return error.Invalid;
                if (invoice != .null) {
                    const id = string(invoice, "id") orelse return error.Invalid;
                    if (self.acceptsSelection(id) and (self.invoice.len == 0 or std.mem.eql(u8, id, self.quote_id.slice()))) {
                        const was_issued = self.issued;
                        try self.acceptInvoice(invoice, now);
                        if (!application and self.issued and !was_issued) self.balance_dirty = true;
                    } else {
                        // Local intent cleanup must not replace a saved invoice
                        // the user selected while reconciliation was pending.
                        const state = string(invoice, "state") orelse return error.Invalid;
                        const confirmed = invoice.object.get("confirmed") orelse return error.Invalid;
                        if (!application and std.ascii.eqlIgnoreCase(state, "ISSUED") and confirmed == .bool and confirmed.bool) self.balance_dirty = true;
                    }
                    if (!application) self.history_dirty = true;
                }
                self.setRecovery(status, now);
                if (status == .none) _ = self.message.set(if (self.recovery_pending) "CDK recovery remains pending; new requests paused." else "Deposit recovery checked; new creation is available.");
                if (valueError(value)) _ = self.message.set("Recovered saved invoice exceeds display limit; retained in wallet.");
                self.recoveryMessage();
            },
            .poll => {
                const application = value.object.get("wallet_changed") != null;
                const cursor = value.object.get("cursor") orelse return error.Invalid;
                if (cursor != .null and (cursor != .string or cursor.string.len > 1024 or std.mem.indexOfScalar(u8, cursor.string, 0) != null)) return error.Invalid;
                const invoice = value.object.get("invoice") orelse return error.Invalid;
                if (invoice != .null) {
                    const id = string(invoice, "id") orelse return error.Invalid;
                    if (self.acceptsSelection(id) and std.mem.eql(u8, id, self.quote_id.slice())) {
                        const was_issued = self.issued;
                        try self.acceptInvoice(invoice, now);
                        if (!application and self.issued and !was_issued) {
                            self.balance_dirty = true;
                            self.history_dirty = true;
                        }
                    } else {
                        const state = string(invoice, "state") orelse return error.Invalid;
                        const confirmed = invoice.object.get("confirmed") orelse return error.Invalid;
                        if (!application and std.ascii.eqlIgnoreCase(state, "ISSUED") and confirmed == .bool and confirmed.bool) {
                            self.balance_dirty = true;
                            self.history_dirty = true;
                            _ = self.message.set("Saved deposit minted; balance updated.");
                        }
                    }
                }
                _ = self.sweep_cursor.set(if (cursor == .null) "" else cursor.string);
                if (valueError(value)) self.pollFailed(now) else {
                    self.backoff = 2;
                    self.next_check = now + 2;
                }
            },
        }
    }
    fn pollFailed(self: *Model, now: f64) void {
        self.backoff = @min(30, self.backoff * 2);
        self.next_check = now + self.backoff;
        _ = self.message.set("Saved deposit check failed; retrying with backoff.");
    }
    fn withdrawalPollFailed(self: *Model, now: f64) void {
        self.withdrawal_backoff = @min(30, self.withdrawal_backoff * 2);
        self.next_withdrawal_poll = now + self.withdrawal_backoff;
    }
    fn withdrawalOperationFailed(self: *Model, status: u8, now: f64) void {
        self.withdrawal_error_status = status;
        self.withdrawal_error_operation = self.operation;
        self.balance_dirty = true;
        self.history_dirty = true;
        switch (self.operation) {
            .prepare_withdrawal => {
                // A definite Err did not create a new owned preparation. Never discard an existing token.
                self.withdrawal_blocked = self.reviewLive();
                self.prepare_unknown = false;
                self.abandon_review = false;
                if (!self.reviewLive()) {
                    self.recover_needed = true;
                    self.next_recover = now;
                }
            },
            .confirm_withdrawal => {
                if (status == 19 and self.reviewLive()) {
                    self.withdrawal_blocked = true;
                } else {
                    self.withdrawal.operation_id = .{};
                    self.abandon_review = false;
                    self.recover_needed = true;
                    self.next_recover = now;
                }
            },
            .cancel_withdrawal => {
                self.withdrawal_blocked = true;
                self.abandon_review = false;
            },
            .saved_withdrawal => self.withdrawal_loading = false,
            .poll_withdrawals => self.withdrawalPollFailed(now),
            else => unreachable,
        }
        _ = self.message.set(self.withdrawalFailureMessage());
    }
    pub fn withdrawalFailureMessage(self: *const Model) []const u8 {
        if (self.withdrawal_error_operation == .cancel_withdrawal) return "Cancellation failed; funds may remain reserved. Work paused; cancel again or restart for CDK recovery.";
        return withdrawalErrorMessage(self.withdrawal_error_status);
    }
    fn clearWithdrawalError(self: *Model) void {
        self.withdrawal_error_status = 0;
        self.withdrawal_error_operation = .prepare_withdrawal;
    }
    fn invalidateMutation(self: *Model) void {
        switch (self.operation) {
            .prepare_withdrawal, .confirm_withdrawal, .cancel_withdrawal => {
                self.balance_dirty = true;
                self.history_dirty = true;
                self.withdrawal_backoff = 2;
                self.next_withdrawal_poll = 0;
            },
            else => {},
        }
    }
    pub fn reviewLive(self: *const Model) bool {
        return self.withdrawal.operation_id.len != 0;
    }
    pub fn prepareWithdrawal(self: *Model, invoice: []const u8) bool {
        if (self.prepareWithdrawalReason(invoice)) |reason| {
            _ = self.message.set(reason);
            return false;
        }
        if (!self.enqueue(.prepare_withdrawal, invoice)) return false;
        self.withdrawal = .{};
        self.withdrawal_selected = .{};
        self.abandon_review = false;
        self.prepare_unknown = false;
        self.clearWithdrawalError();
        _ = self.message.set("Preparing CDK review; no payment submitted...");
        return true;
    }
    pub fn prepareWithdrawalReason(self: *const Model, invoice: []const u8) ?[]const u8 {
        if (!self.available) return "Wallet unavailable; wait for the wallet to open.";
        if (self.reviewLive()) return "An active review owns reserved funds. Cancel it before another review.";
        if (self.withdrawal_blocked) return "Review outcome unresolved; Back or restart as instructed before retrying.";
        if (self.recovery != .none or self.recovery_pending or self.recover_needed) return "Wallet recovering; wait for CDK before clicking Review again.";
        if (self.queued != null or (self.pending and self.operation != .poll and self.operation != .check and self.operation != .poll_withdrawals)) return "Wallet busy; wait, then click Review again.";
        if (invoice.len == 0) return "Paste or enter a complete Lightning BOLT11 invoice.";
        return null;
    }
    pub fn canPrepareWithdrawal(self: *const Model, invoice: []const u8) bool {
        return self.prepareWithdrawalReason(invoice) == null;
    }
    pub fn canConfirmWithdrawal(self: *const Model) bool {
        return self.reviewLive() and !self.abandon_review and !self.pending and self.queued == null and !self.withdrawal_blocked and self.withdrawal_selected.len == 0 and !self.withdrawal.expired and !self.withdrawal.deadlinePassed(self.unix_now);
    }
    pub fn confirmWithdrawal(self: *Model) bool {
        if (!self.canConfirmWithdrawal()) return false;
        return self.enqueue(.confirm_withdrawal, self.withdrawal.operation_id.slice());
    }
    pub fn leaveWithdrawal(self: *Model) void {
        if (self.queued) |req| if (req.operation == .prepare_withdrawal) {
            self.queued = null;
        };
        if ((self.pending and self.operation == .prepare_withdrawal) or self.reviewLive()) {
            if (self.pending and self.operation == .confirm_withdrawal) return;
            self.abandon_review = true;
            self.publishQueued();
        } else if (self.prepare_unknown) {
            self.withdrawal_blocked = false;
            self.prepare_unknown = false;
        }
    }
    fn recoveryMessage(self: *Model) void {
        if (self.recovery_pending and self.recovery == .none) _ = self.message.set("CDK recovery remains pending; new requests paused.");
        switch (self.recovery) {
            .none => {},
            .unknown => {
                _ = self.message.set("Creation outcome unknown; saved invoices and backup intact. New deposits are paused until the service reconciles.");
            },
            .legacy_unknown => {
                _ = self.message.set("Legacy creation outcome unknown; saved invoices and backup intact. New deposits are paused.");
            },
        }
    }
    fn setRecovery(self: *Model, status: Recovery, now: f64) void {
        self.recovery = status;
        if (status == .none and !self.recovery_pending) {
            self.recover_needed = false;
            self.next_recover = 0;
            self.recover_backoff = 2;
        } else if (!self.recover_needed) {
            // Reconcile local evidence only; an unknown result is not permission
            // to create again, nor a reason to retry at frame speed.
            self.recover_needed = true;
            self.next_recover = now + self.recover_backoff;
            self.recover_backoff = @min(30, self.recover_backoff * 2);
        }
    }
    fn acceptInvoice(self: *Model, value: std.json.Value, now: f64) !void {
        const id = string(value, "id") orelse return error.Invalid;
        const invoice = string(value, "invoice") orelse return error.Invalid;
        const state = string(value, "state") orelse return error.Invalid;
        const mint = string(value, "mint_url") orelse return error.Invalid;
        const expired = value.object.get("expired") orelse return error.Invalid;
        if (expired != .bool) return error.Invalid;
        if (self.mint.len == 0 or !std.mem.eql(u8, mint, self.mint.slice()) or id.len == 0 or id.len > 1024 or invoice.len == 0 or invoice.len > 4096 or state.len > 32 or std.mem.indexOfScalar(u8, id, 0) != null or std.mem.indexOfScalar(u8, invoice, 0) != null or std.mem.indexOfScalar(u8, state, 0) != null) return error.Invalid;
        if (!std.mem.eql(u8, invoice, self.invoice.slice())) {
            _ = self.invoice.set(invoice);
            _ = self.qr.encode(self.invoice.z());
        }
        _ = self.quote_id.set(id);
        _ = self.quote_state.set(state);
        const confirmed = value.object.get("confirmed") orelse .null;
        self.issued = std.ascii.eqlIgnoreCase(state, "ISSUED") and confirmed == .bool and confirmed.bool;
        self.expired = expired.bool;
        _ = self.message.set(if (self.issued) "Deposit minted; rereading balance..." else if (std.ascii.eqlIgnoreCase(state, "ISSUED")) "Issued remotely; local issuance unconfirmed. Saved work retained." else if (std.ascii.eqlIgnoreCase(state, "PAID")) "Paid; minting not yet confirmed." else "Waiting for payment; saved invoice.");
        self.backoff = 2;
        self.next_check = now + 2;
        self.recoveryMessage();
        if (self.expired) _ = self.message.set("Invoice expired; unpaid checks stopped. Saved work retained.");
    }
    fn acceptHistory(self: *Model, value: std.json.Value) !void {
        const offset = try decimal(string(value, "offset") orelse return error.Invalid);
        const total = try decimal(string(value, "total") orelse return error.Invalid);
        const limit = value.object.get("limit") orelse return error.Invalid;
        const rows = value.object.get("rows") orelse return error.Invalid;
        if (total > std.math.maxInt(u32) or offset % 8 != 0 or limit != .integer or limit.integer != 8 or rows != .array or rows.array.items.len > 8) return error.Invalid;
        const expected = if (total == 0) 0 else @min(@as(u64, self.pending_offset), (total - 1) / 8 * 8);
        if (offset != expected or rows.array.items.len != @min(8, total - offset)) return error.Invalid;
        var rendered: [8]Row = @splat(.{});
        var next_expiry: ?u64 = null;
        for (rows.array.items, 0..) |entry, index| {
            if (entry != .object) return error.Invalid;
            const direction = string(entry, "direction") orelse return error.Invalid;
            if (!std.mem.eql(u8, direction, "In") and !std.mem.eql(u8, direction, "Out")) return error.Invalid;
            rendered[index].outgoing = std.mem.eql(u8, direction, "Out");
            const status = try historyStatus(entry, rendered[index].outgoing);
            if (valueError(entry)) {
                _ = string(entry, "error") orelse return error.Invalid;
                const identity = string(entry, "identity") orelse return error.Invalid;
                if (identity.len != 64) return error.Invalid;
                _ = rendered[index].text.set("Saved quote exceeds display limit; retained in wallet");
                continue;
            }
            const id = string(entry, "id") orelse return error.Invalid;
            if (id.len == 0 or !rendered[index].id.set(id)) return error.Invalid;
            var buf: [512]u8 = undefined;
            var time_buf: [32]u8 = undefined;
            const time = if (string(entry, "created_at")) |text| formatTime(text, &time_buf) else "Time unknown";
            const mint = string(entry, "mint_url") orelse "Mint unknown";
            if (string(entry, "mint_url")) |owner| _ = rendered[index].mint.set(owner);
            if (!rendered[index].outgoing and !status.expired and std.mem.eql(u8, status.quote, "UNPAID")) {
                if (string(entry, "quote_expiry")) |text| {
                    const expiry = decimal(text) catch 0;
                    if (expiry != 0 and (next_expiry == null or expiry < next_expiry.?)) next_expiry = expiry;
                }
            }
            const line = std.fmt.bufPrint(&buf, "{s} | {s} {s} | {s}{s}{s}{s}\n{s}{s}", .{ time, string(entry, "amount") orelse "?", string(entry, "unit") orelse "?", status.quote, if (status.payment != null) " | " else "", status.payment orelse "", if (status.expired) " | EXPIRED" else "", mint, if (!std.mem.eql(u8, mint, self.mint.slice())) " (not refreshed)" else "" }) catch "Quote details exceed display limit; retained in wallet";
            _ = rendered[index].text.set(line);
        }
        self.rows = rendered;
        self.history_next_expiry = next_expiry;
        self.row_count = rows.array.items.len;
        self.total_rows = @intCast(total);
        if (self.desired_offset == self.pending_offset) self.desired_offset = @intCast(offset) else self.history_dirty = true;
        self.history_error = false;
    }
};
pub fn withdrawalErrorMessage(status: u8) []const u8 {
    return switch (status) {
        2 => "Invalid Lightning invoice. Use a valid amount-bearing BOLT11 invoice.",
        14 => "Insufficient funds. Wait for CDK recovery before reviewing another invoice.",
        19 => "Wallet recovery or an active review is pending. Cancel an active review or wait for CDK.",
        13 => "Withdrawal network request failed; CDK will check saved work. Do not pay again.",
        23 => "Withdrawal storage request failed; saved work may need CDK recovery.",
        else => "Withdrawal request failed; rereading CDK state before further action.",
    };
}
const HistoryStatus = struct { quote: []const u8, payment: ?[]const u8, expired: bool };

fn historyStatus(entry: std.json.Value, outgoing: bool) !HistoryStatus {
    const expired = if (entry.object.get("expired")) |field| blk: {
        if (field != .bool) return error.Invalid;
        break :blk field.bool;
    } else false;
    const payment_status = if (entry.object.get("payment_status")) |field| blk: {
        if (field != .string or field.string.len == 0 or field.string.len > 32) return error.Invalid;
        for (field.string) |c| if (c < 32 or c >= 127) return error.Invalid;
        break :blk field.string;
    } else null;
    const payment = if (outgoing) blk: {
        const status = payment_status orelse break :blk null;
        const known = std.meta.stringToEnum(withdrawal.Status, status) orelse break :blk status;
        break :blk switch (known) {
            .prepared => "Prepared",
            .pending => "Pending",
            .completed => "Completed",
            .failed => "Failed",
            .unsubmitted => "Unsubmitted",
            .unknown => "Unknown",
        };
    } else null;
    return .{ .quote = string(entry, "state") orelse "?", .payment = payment, .expired = expired };
}
fn valueError(value: std.json.Value) bool {
    const field = value.object.get("error") orelse return false;
    return field != .null;
}
fn recoveryState(value: std.json.Value) !Recovery {
    return std.meta.stringToEnum(Recovery, string(value, "creation_recovery") orelse return error.Invalid) orelse error.Invalid;
}
fn string(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}
fn decimal(text: []const u8) !u64 {
    if (text.len == 0 or text.len > 20) return error.InvalidAmount;
    for (text) |c| if (c < '0' or c > '9') return error.InvalidAmount;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidAmount;
}
pub fn positiveMsats(text: []const u8) !u64 {
    const amount = try decimal(text);
    if (amount == 0 or amount > std.math.maxInt(i64)) return error.InvalidAmount;
    return amount;
}
fn formatTime(text: []const u8, buf: []u8) []const u8 {
    const seconds = decimal(text) catch return "Time unknown";
    if (seconds > 253402300799) return "Time unknown";
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const clock = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ day.year, month.month.numeric(), month.day_index + 1, clock.getHoursIntoDay(), clock.getMinutesIntoHour() }) catch "Time unknown";
}

const screen = "{\"mint_url\":\"https://testnut.cashu.space\",\"msats\":\"0\",\"creation_recovery\":\"none\",\"recovery_pending\":false}";
const unpaid = "{\"id\":\"saved\",\"invoice\":\"lnbc210n1test\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"UNPAID\",\"confirmed\":false,\"expired\":false}";
const update_error = "\"error\":{\"status\":7,\"message\":\"saved quote unavailable\"},\"invoice\":null,\"creation_recovery\":\"none\",\"recovery_pending\":false";
const prepared_withdrawal = "{\"operation_id\":\"operation-uuid\",\"quote_id\":\"out-A\",\"mint_url\":\"https://testnut.cashu.space\",\"invoice\":\"lnbc-normalized\",\"unit\":\"msat\",\"amount\":\"100001\",\"fee_reserve\":\"2000\",\"swap_fee\":\"1000\",\"input_fee\":\"1000\",\"estimated_total\":\"104001\",\"quote_expiry\":\"200\",\"invoice_expiry\":\"300\",\"requires_swap\":true}";

test "operation withdrawal classification preserves wire ordinals" {
    const cases = [_]struct { operation: Operation, withdrawal: bool }{
        .{ .operation = .open, .withdrawal = false },
        .{ .operation = .snapshot, .withdrawal = false },
        .{ .operation = .create, .withdrawal = false },
        .{ .operation = .check, .withdrawal = false },
        .{ .operation = .history, .withdrawal = false },
        .{ .operation = .resume_saved, .withdrawal = false },
        .{ .operation = .recover, .withdrawal = false },
        .{ .operation = .poll, .withdrawal = false },
        .{ .operation = .saved_invoice, .withdrawal = false },
        .{ .operation = .prepare_withdrawal, .withdrawal = true },
        .{ .operation = .confirm_withdrawal, .withdrawal = true },
        .{ .operation = .cancel_withdrawal, .withdrawal = true },
        .{ .operation = .saved_withdrawal, .withdrawal = true },
        .{ .operation = .poll_withdrawals, .withdrawal = true },
    };
    try std.testing.expectEqual(@typeInfo(Operation).@"enum".field_names.len, cases.len);
    for (cases, 0..) |case, ordinal| {
        try std.testing.expectEqual(ordinal, @as(usize, @backingInt(case.operation)));
        try std.testing.expectEqual(case.withdrawal, case.operation.isWithdrawal());
    }
}

test "prepared withdrawal requires a boolean swap flag without retaining it" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, prepared_withdrawal, .{});
    defer parsed.deinit();
    const mint = "https://testnut.cashu.space";
    const expected = try withdrawal.View.parse(parsed.value, mint, true);
    for ([_]bool{ true, false }) |flag| {
        parsed.value.object.getPtr("requires_swap").?.* = .{ .bool = flag };
        const actual = try withdrawal.View.parse(parsed.value, mint, true);
        try std.testing.expectEqualDeep(expected, actual);
    }
    parsed.value.object.getPtr("unit").?.* = .{ .string = "sat" };
    try std.testing.expectError(error.Invalid, withdrawal.View.parse(parsed.value, mint, true));
    parsed.value.object.getPtr("unit").?.* = .{ .string = "msat" };
    parsed.value.object.getPtr("requires_swap").?.* = .{ .string = "false" };
    try std.testing.expectError(error.Invalid, withdrawal.View.parse(parsed.value, mint, true));
    try std.testing.expect(parsed.value.object.swapRemove("requires_swap"));
    try std.testing.expectError(error.Invalid, withdrawal.View.parse(parsed.value, mint, true));
}
const saved_withdrawal = "{\"quote_id\":\"out-A\",\"mint_url\":\"https://testnut.cashu.space\",\"invoice\":\"lnbc-normalized\",\"unit\":\"msat\",\"amount\":\"100000\",\"quote_state\":\"UNPAID\",\"payment_status\":\"pending\",\"quote_expiry\":\"200\",\"invoice_expiry\":\"300\",\"expired\":false,\"retry_review_allowed\":false}";
fn withdrawalModel() Model {
    var model = Model{ .started = true, .available = true, .history_dirty = false, .unix_now = 100 };
    _ = model.mint.set("https://testnut.cashu.space");
    _ = model.balance.set("500000 msat");
    return model;
}
test "withdrawal readiness explains gates and never queues deferred user authorization" {
    var model = withdrawalModel();
    try std.testing.expect(!model.canPrepareWithdrawal(""));
    model.recovery_pending = true;
    try std.testing.expect(!model.prepareWithdrawal("invoice"));
    try std.testing.expect(std.mem.indexOf(u8, model.message.slice(), "recovering") != null);
    try std.testing.expect(model.request == null and model.queued == null);
    model.recovery_pending = false;
    try std.testing.expect(model.canPrepareWithdrawal("invoice"));
    try std.testing.expect(model.request == null); // A new explicit click is still required.
}
test "definite invalid and insufficient preparation errors after close allow only CDK recovery" {
    for ([_]u8{ 2, 14 }) |status| {
        var model = withdrawalModel();
        try std.testing.expect(model.prepareWithdrawal("invoice"));
        model.request = null;
        model.leaveWithdrawal();
        var buf: [256]u8 = undefined;
        const raw = try std.fmt.bufPrint(&buf, "{{\"operation_error\":{{\"status\":{d},\"message\":\"Withdrawal request failed\"}}}}", .{status});
        model.accept(model.serial, raw, 1, std.testing.allocator);
        try std.testing.expect(!model.withdrawal_blocked and !model.abandon_review and !model.prepare_unknown);
        try std.testing.expect(model.balance_dirty and model.history_dirty and model.recover_needed);
        try std.testing.expectEqual(status, model.withdrawal_error_status);
        try std.testing.expect(!model.canPrepareWithdrawal("invoice"));
        model.tick(true, 1);
        try std.testing.expect(model.operation == .recover);
        model.request = null;
        model.accept(model.serial, "{\"wallet_changed\":false,\"recovery_pending\":true,\"creation_recovery\":\"none\",\"invoice\":null}", 1, std.testing.allocator);
        try std.testing.expect(model.recovery_pending and !model.canPrepareWithdrawal("invoice"));
        model.tick(true, 1);
        try std.testing.expect(model.operation == .snapshot);
        model.request = null;
        model.accept(model.serial, "{\"mint_url\":\"https://testnut.cashu.space\",\"msats\":\"500000\",\"recovery_pending\":true,\"creation_recovery\":\"none\"}", 1, std.testing.allocator);
        const deadline = model.next_recover;
        model.tick(true, deadline);
        try std.testing.expect(model.operation == .recover);
        model.request = null;
        model.accept(model.serial, "{\"wallet_changed\":false,\"recovery_pending\":false,\"creation_recovery\":\"none\",\"invoice\":null}", deadline, std.testing.allocator);
        try std.testing.expect(model.canPrepareWithdrawal("invoice") and !model.pending and model.request == null);
        try std.testing.expectEqualStrings("500000 msat", model.balance.slice());
    }
}
test "lost preparation reply after close remains conservatively paused and malformed errors are not definite" {
    for ([_][]const u8{
        "{}",                                                           "{\"operation_error\":{\"status\":0,\"message\":\"failed\"}}",
        "{\"operation_error\":{\"status\":28,\"message\":\"failed\"}}", "{\"operation_error\":{\"status\":\"2\",\"message\":\"failed\"}}",
        "{\"operation_error\":{\"status\":2,\"message\":null}}",        "{\"operation_error\":{\"status\":2,\"message\":\"bad\\u0000message\"}}",
    }) |raw| {
        var model = withdrawalModel();
        try std.testing.expect(model.prepareWithdrawal("invoice"));
        model.request = null;
        model.leaveWithdrawal();
        model.accept(model.serial, raw, 0, std.testing.allocator);
        try std.testing.expect(model.withdrawal_blocked and !model.prepare_unknown and !model.canPrepareWithdrawal("invoice"));
        model.leaveWithdrawal();
        model.balance_dirty = false;
        model.tick(true, 100);
        try std.testing.expect(model.withdrawal_blocked and !model.pending);
        try std.testing.expect(std.mem.indexOf(u8, model.message.slice(), "Restart") != null);
    }
}
test "typed active-review error preserves the cancellation token and all mutations invalidate reads" {
    var model = withdrawalModel();
    try std.testing.expect(model.prepareWithdrawal("invoice"));
    model.request = null;
    model.accept(model.serial, prepared_withdrawal, 0, std.testing.allocator);
    try std.testing.expect(model.confirmWithdrawal());
    model.request = null;
    model.balance_dirty = false;
    model.history_dirty = false;
    model.accept(model.serial, "{\"operation_error\":{\"status\":19,\"message\":\"Withdrawal request failed\"}}", 1, std.testing.allocator);
    try std.testing.expect(model.reviewLive() and model.withdrawal_blocked and model.balance_dirty and model.history_dirty);
    try std.testing.expectEqualStrings("operation-uuid", model.withdrawal.operation_id.slice());
    model.leaveWithdrawal();
    try std.testing.expect(model.operation == .cancel_withdrawal and model.pending);
    model.request = null;
    model.accept(model.serial, "{\"operation_error\":{\"status\":13,\"message\":\"Withdrawal request failed\"}}", 2, std.testing.allocator);
    try std.testing.expect(model.reviewLive() and model.withdrawal_blocked and !model.abandon_review);
    try std.testing.expect(std.mem.indexOf(u8, model.withdrawalFailureMessage(), "funds may remain reserved") != null);
    model.balance_dirty = false;
    model.tick(true, 100);
    try std.testing.expect(!model.pending);
}
test "explicit cancellation retry clears typed errors only after matching validated success" {
    for ([_]u8{ 13, 23 }) |status| {
        var model = withdrawalModel();
        try std.testing.expect(model.prepareWithdrawal("invoice"));
        model.request = null;
        model.accept(model.serial, prepared_withdrawal, 0, std.testing.allocator);
        model.leaveWithdrawal();
        model.request = null;
        var buf: [128]u8 = undefined;
        model.accept(model.serial, try std.fmt.bufPrint(&buf, "{{\"operation_error\":{{\"status\":{d},\"message\":\"failed\"}}}}", .{status}), 1, std.testing.allocator);
        try std.testing.expect(model.reviewLive() and model.withdrawal_blocked and !model.abandon_review);
        try std.testing.expectEqual(status, model.withdrawal_error_status);
        try std.testing.expectEqual(Operation.cancel_withdrawal, model.withdrawal_error_operation);
        try std.testing.expect(std.mem.startsWith(u8, model.withdrawalFailureMessage(), "Cancellation failed"));
        const live = model.withdrawal;

        // Background reads cannot resolve the outstanding cancellation.
        try std.testing.expect(model.enqueue(.snapshot, ""));
        model.request = null;
        model.accept(model.serial, screen, 2, std.testing.allocator);
        try std.testing.expect(model.enqueue(.history, "0"));
        model.request = null;
        model.accept(model.serial, "{\"offset\":\"0\",\"total\":\"1\",\"limit\":8,\"rows\":[" ++ history_row ++ "]}", 2, std.testing.allocator);
        try std.testing.expect(!model.openRow(0));
        try std.testing.expect(!model.prepareWithdrawal("other"));
        try std.testing.expectEqualDeep(live, model.withdrawal);
        try std.testing.expectEqual(status, model.withdrawal_error_status);
        try std.testing.expectEqual(Operation.cancel_withdrawal, model.withdrawal_error_operation);

        for ([_][]const u8{ "{\"quote_id\":\"wrong\",\"cancelled\":true}", "{\"quote_id\":\"out-A\",\"cancelled\":false}", "{\"quote_id\":\"out-A\",\"cancelled\":\"true\"}", "{}" }) |invalid| {
            model.leaveWithdrawal();
            try std.testing.expect(model.pending and model.operation == .cancel_withdrawal);
            try std.testing.expectEqualStrings("operation-uuid", model.request.?.argument.slice());
            model.request = null;
            model.accept(model.serial, invalid, 3, std.testing.allocator);
            try std.testing.expectEqualDeep(live, model.withdrawal);
            try std.testing.expect(model.withdrawal_blocked and !model.abandon_review and !model.canConfirmWithdrawal());
            try std.testing.expectEqual(status, model.withdrawal_error_status);
            try std.testing.expect(!std.mem.startsWith(u8, model.message.slice(), "Unsubmitted review cancelled"));
        }
        model.balance_dirty = false;
        model.history_dirty = false;
        model.tick(true, 100);
        try std.testing.expect(!model.pending); // No automatic cancellation retry.
        model.leaveWithdrawal();
        model.request = null;
        model.accept(model.serial, "{\"quote_id\":\"out-A\",\"cancelled\":true}", 4, std.testing.allocator);
        try std.testing.expect(!model.reviewLive() and !model.withdrawal_blocked and !model.abandon_review);
        try std.testing.expectEqual(@as(u8, 0), model.withdrawal_error_status);
        try std.testing.expectEqual(Operation.prepare_withdrawal, model.withdrawal_error_operation);
        try std.testing.expectEqualStrings("Unsubmitted review cancelled; rereading wallet balance.", model.message.slice());
        try std.testing.expect(model.openRow(0));
        model.request = null;
        model.accept(model.serial, unpaid, 5, std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), model.withdrawal_error_status);
        try std.testing.expect(model.prepareWithdrawal("new-invoice"));
        try std.testing.expectEqual(Operation.prepare_withdrawal, model.withdrawal_error_operation);
    }
}

test "accepted history selection scopes obsolete withdrawal errors but rejected selection preserves them" {
    for ([_]bool{ false, true }) |outgoing| {
        var model = withdrawalModel();
        model.row_count = 1;
        model.rows[0].outgoing = outgoing;
        _ = model.rows[0].id.set(if (outgoing) "out-A" else "saved");
        _ = model.rows[0].mint.set(model.mint.slice());
        try std.testing.expect(model.enqueue(.saved_withdrawal, "old"));
        model.request = null;
        const old_serial = model.serial;
        model.accept(old_serial, "{\"operation_error\":{\"status\":13,\"message\":\"failed\"}}", 0, std.testing.allocator);
        try std.testing.expect(model.enqueue(.history, "0"));
        try std.testing.expect(!model.openRow(0));
        try std.testing.expectEqual(@as(u8, 13), model.withdrawal_error_status);
        try std.testing.expectEqual(Operation.saved_withdrawal, model.withdrawal_error_operation);
        model.request = null;
        model.fail(model.serial, 1);
        try std.testing.expect(model.openRow(0));
        try std.testing.expectEqual(@as(u8, 0), model.withdrawal_error_status);
        try std.testing.expectEqual(Operation.prepare_withdrawal, model.withdrawal_error_operation);
        model.request = null;
        const selected_serial = model.serial;
        model.accept(old_serial, "{\"operation_error\":{\"status\":23,\"message\":\"old failure\"}}", 2, std.testing.allocator);
        try std.testing.expect(model.pending and model.serial == selected_serial and model.withdrawal_error_status == 0);
        model.accept(selected_serial, if (outgoing) saved_withdrawal else unpaid, 2, std.testing.allocator);
        try std.testing.expect(!model.pending and model.withdrawal_error_status == 0);
        if (outgoing) {
            // A same-selection retry can recover without opening a new row.
            try std.testing.expect(model.enqueue(.saved_withdrawal, "out-A"));
            model.request = null;
            model.accept(model.serial, "{\"operation_error\":{\"status\":23,\"message\":\"new failure\"}}", 3, std.testing.allocator);
            model.accept(old_serial, saved_withdrawal, 3, std.testing.allocator);
            try std.testing.expectEqual(@as(u8, 23), model.withdrawal_error_status);
            try std.testing.expectEqual(Operation.saved_withdrawal, model.withdrawal_error_operation);
            try std.testing.expect(model.enqueue(.saved_withdrawal, "out-A"));
            model.request = null;
            model.accept(model.serial, saved_withdrawal, 4, std.testing.allocator);
            try std.testing.expectEqual(@as(u8, 0), model.withdrawal_error_status);
            try std.testing.expectEqual(Operation.prepare_withdrawal, model.withdrawal_error_operation);
        }
    }
}

test "unrelated withdrawal poll success retains unresolved cancellation error context" {
    var model = withdrawalModel();
    try std.testing.expect(model.prepareWithdrawal("invoice"));
    model.request = null;
    model.accept(model.serial, prepared_withdrawal, 0, std.testing.allocator);
    model.leaveWithdrawal();
    model.request = null;
    model.accept(model.serial, "{\"operation_error\":{\"status\":23,\"message\":\"failed\"}}", 1, std.testing.allocator);
    // The scheduler refuses polling a live review. Also exercise delivery of
    // background results independently: success is not cancellation evidence.
    try std.testing.expect(!model.enqueue(.poll_withdrawals, ""));
    const live = model.withdrawal;
    model.operation = .poll_withdrawals;
    model.pending = true;
    model.accept(model.serial, "{\"cursor\":\"other\",\"checked_id\":null,\"withdrawal\":null,\"wallet_changed\":false,\"recovery_pending\":false}", 2, std.testing.allocator);
    try std.testing.expectEqualDeep(live, model.withdrawal);
    try std.testing.expect(model.withdrawal_blocked);
    try std.testing.expectEqual(@as(u8, 23), model.withdrawal_error_status);
    try std.testing.expectEqual(Operation.cancel_withdrawal, model.withdrawal_error_operation);
}

test "withdrawal poll metadata rejects malformed present booleans before invalidating unchanged state" {
    for ([_][]const u8{ "\"wallet_changed\":\"true\",\"recovery_pending\":false", "\"wallet_changed\":false,\"recovery_pending\":null" }) |fields| {
        var model = withdrawalModel();
        try std.testing.expect(model.enqueue(.poll_withdrawals, "old"));
        model.request = null;
        var buf: [256]u8 = undefined;
        model.accept(model.serial, try std.fmt.bufPrint(&buf, "{{\"cursor\":\"next\",\"checked_id\":null,\"withdrawal\":null,{s}}}", .{fields}), 1, std.testing.allocator);
        try std.testing.expect(!model.balance_dirty and !model.history_dirty and !model.recovery_pending);
        try std.testing.expectEqualStrings("", model.withdrawal_cursor.slice());
    }
}
test "withdrawal error metadata advances cursors and prioritizes actual wallet rereads and recovery" {
    var model = withdrawalModel();
    try std.testing.expect(model.enqueue(.poll_withdrawals, "old"));
    model.request = null;
    model.accept(model.serial, "{\"cursor\":\"candidate\",\"checked_id\":\"candidate\",\"withdrawal\":null,\"wallet_changed\":true,\"recovery_pending\":true,\"error\":{\"status\":13,\"message\":\"unavailable\"}}", 1, std.testing.allocator);
    try std.testing.expect(model.balance_dirty and model.history_dirty and model.recovery_pending and model.recover_needed);
    try std.testing.expectEqualStrings("candidate", model.withdrawal_cursor.slice());
    try std.testing.expectEqualStrings("500000 msat", model.balance.slice());
    model.tick(true, 1);
    try std.testing.expect(model.operation == .snapshot);
    model.request = null;
    model.accept(model.serial, "{\"mint_url\":\"https://testnut.cashu.space\",\"msats\":\"478000\",\"recovery_pending\":true,\"creation_recovery\":\"none\"}", 1, std.testing.allocator);
    try std.testing.expectEqualStrings("478000 msat", model.balance.slice());
    model.tick(true, model.next_recover);
    try std.testing.expect(model.operation == .recover);
}
test "fast empty withdrawal sweeps preserve prior deposit cadence and all three deposit visits within twelve seconds" {
    var model = withdrawalModel();
    _ = model.quote_id.set("saved");
    var deposits: usize = 0;
    var withdrawals: usize = 0;
    for (0..121) |frame| {
        const now = @as(f64, @floatFromInt(frame)) / 10;
        const deposit_deadline = model.next_check;
        model.tick(true, now);
        if (!model.pending) continue;
        model.request = null;
        switch (model.operation) {
            .poll => {
                deposits += 1;
                const id = ([_][]const u8{ "A", "B", "C" })[@min(deposits - 1, 2)];
                var buf: [64]u8 = undefined;
                model.accept(model.serial, try std.fmt.bufPrint(&buf, "{{\"cursor\":\"{s}\",\"invoice\":null}}", .{id}), now, std.testing.allocator);
            },
            .check => model.accept(model.serial, unpaid, now, std.testing.allocator),
            .poll_withdrawals => {
                withdrawals += 1;
                const history_dirty = model.history_dirty;
                const balance_dirty = model.balance_dirty;
                model.accept(model.serial, "{\"cursor\":\"\",\"checked_id\":null,\"withdrawal\":null,\"wallet_changed\":false,\"recovery_pending\":false}", now, std.testing.allocator);
                try std.testing.expectEqual(deposit_deadline, model.next_check);
                try std.testing.expectEqual(history_dirty, model.history_dirty);
                try std.testing.expectEqual(balance_dirty, model.balance_dirty);
                try std.testing.expect(model.next_withdrawal_poll - now >= 2 and model.next_withdrawal_poll - now <= 30);
            },
            else => return error.UnexpectedOperation,
        }
    }
    try std.testing.expect(deposits >= 3 and withdrawals >= 2 and withdrawals <= 6);
}
test "history preserves CDK quote state alongside reported payment status and expiry" {
    const cases = [_]struct { fields: []const u8, label: []const u8 }{
        .{ .fields = "\"direction\":\"Out\",\"state\":\"PENDING\",\"payment_status\":\"pending\",\"expired\":false", .label = "PENDING | Pending" },
        .{ .fields = "\"direction\":\"Out\",\"state\":\"UNPAID\",\"payment_status\":\"pending\",\"expired\":false", .label = "UNPAID | Pending" },
        .{ .fields = "\"direction\":\"Out\",\"state\":\"PAID\",\"payment_status\":\"completed\",\"expired\":false", .label = "PAID | Completed" },
        .{ .fields = "\"direction\":\"Out\",\"state\":\"UNPAID\",\"payment_status\":\"unsubmitted\",\"expired\":true", .label = "UNPAID | Unsubmitted | EXPIRED" },
        .{ .fields = "\"direction\":\"In\",\"state\":\"UNPAID\",\"expired\":true", .label = "UNPAID | EXPIRED" },
        .{ .fields = "\"direction\":\"In\",\"state\":\"UNPAID\",\"expired\":false", .label = "UNPAID" },
        .{ .fields = "\"direction\":\"Out\",\"state\":\"UNPAID\"", .label = "UNPAID" },
        .{ .fields = "\"direction\":\"Out\",\"state\":\"PAID\",\"payment_status\":\"unknown\",\"expired\":false", .label = "PAID | Unknown" },
        .{ .fields = "\"direction\":\"Out\",\"state\":\"PAID\",\"payment_status\":\"future-status\",\"expired\":false", .label = "PAID | future-status" },
    };
    for (cases) |case| {
        var model = withdrawalModel();
        try std.testing.expect(model.enqueue(.history, "0"));
        model.request = null;
        var buf: [1024]u8 = undefined;
        const raw = try std.fmt.bufPrint(&buf, "{{\"offset\":\"0\",\"total\":\"1\",\"limit\":8,\"rows\":[{{\"id\":\"saved\",\"amount\":\"21000\",\"unit\":\"msat\",\"mint_url\":\"https://testnut.cashu.space\",{s}}}]}}", .{case.fields});
        model.accept(model.serial, raw, 0, std.testing.allocator);
        try std.testing.expect(!model.history_error and model.row_count == 1);
        var expected: [64]u8 = undefined;
        const state = try std.fmt.bufPrint(&expected, "21000 msat | {s}\n", .{case.label});
        try std.testing.expect(std.mem.indexOf(u8, model.rows[0].text.slice(), state) != null);
    }
}
test "open history rereads local quote state after the next unpaid deposit expires" {
    var model = withdrawalModel();
    model.next_check = 2;
    model.visit(true, false);
    model.tick(true, 0);
    try std.testing.expectEqual(Operation.history, model.request.?.operation);
    model.request = null;
    const prefix = "{\"offset\":\"0\",\"total\":\"1\",\"limit\":8,\"rows\":[{\"id\":\"saved\",\"direction\":\"In\",\"state\":\"UNPAID\",\"quote_expiry\":\"200\",\"expired\":";
    model.accept(model.serial, prefix ++ "false}]}", 0, std.testing.allocator);
    model.unix_now = 200;
    model.tick(true, 0);
    try std.testing.expect(model.request == null);
    model.unix_now = 201;
    model.tick(true, 0);
    try std.testing.expectEqual(Operation.history, model.request.?.operation);
    model.request = null;
    model.accept(model.serial, prefix ++ "true}]}", 0, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, model.rows[0].text.slice(), "| UNPAID | EXPIRED\n") != null);
    model.tick(true, 0);
    try std.testing.expect(model.request == null);
}

test "malformed present history projection fields fail atomically and retain previous rows" {
    const invalid = [_][]const u8{
        "\"expired\":null",        "\"expired\":1",                           "\"expired\":\"true\"",
        "\"payment_status\":null", "\"payment_status\":false",                "\"payment_status\":1",
        "\"payment_status\":\"\"", "\"payment_status\":\"bad\\u0000status\"", "\"payment_status\":\"" ++ @as([33]u8, @splat('x')) ++ "\"",
    };
    for ([_][]const u8{ "In", "Out" }) |direction| {
        for (invalid) |field| {
            var model = withdrawalModel();
            model.row_count = 1;
            _ = model.rows[0].text.set("previous row");
            try std.testing.expect(model.enqueue(.history, "0"));
            model.request = null;
            var buf: [1024]u8 = undefined;
            const raw = try std.fmt.bufPrint(&buf, "{{\"offset\":\"0\",\"total\":\"1\",\"limit\":8,\"rows\":[{{\"id\":\"saved\",\"direction\":\"{s}\",{s}}}]}}", .{ direction, field });
            model.accept(model.serial, raw, 0, std.testing.allocator);
            try std.testing.expect(model.history_error and model.row_count == 1);
            try std.testing.expectEqualStrings("previous row", model.rows[0].text.slice());
        }
    }
}
test "history activation never drops a live cancellation token or details on rejected enqueue" {
    for ([_]bool{ false, true }) |outgoing| {
        var model = withdrawalModel();
        model.row_count = 1;
        model.rows[0].outgoing = outgoing;
        _ = model.rows[0].id.set("saved");
        _ = model.rows[0].mint.set(model.mint.slice());
        try std.testing.expect(model.prepareWithdrawal("invoice"));
        model.request = null;
        model.accept(model.serial, prepared_withdrawal, 0, std.testing.allocator);
        const live = model.withdrawal;
        try std.testing.expect(!model.openRow(0));
        try std.testing.expectEqualDeep(live, model.withdrawal);
        model.withdrawal_blocked = true;
        try std.testing.expect(!model.openRow(0));
        try std.testing.expectEqualDeep(live, model.withdrawal);

        model.withdrawal.operation_id = .{};
        model.withdrawal_blocked = false;
        _ = model.withdrawal_selected.set("out-A");
        const saved = model.withdrawal;
        try std.testing.expect(model.enqueue(.history, "0"));
        const published = model.request.?;
        try std.testing.expect(!model.openRow(0));
        try std.testing.expectEqualDeep(saved, model.withdrawal);
        try std.testing.expectEqualStrings("out-A", model.withdrawal_selected.slice());
        try std.testing.expectEqualDeep(published, model.request.?);
    }
}
test "withdrawal review is explicit single-use and pauses conflicting background work" {
    var model = withdrawalModel();
    try std.testing.expect(model.prepareWithdrawal("lnbc-input"));
    model.request = null;
    model.accept(model.serial, prepared_withdrawal, 0, std.testing.allocator);
    try std.testing.expect(model.reviewLive() and model.balance_dirty and model.history_dirty);
    try std.testing.expectEqualStrings("104001", model.withdrawal.estimated_total.slice());
    try std.testing.expectEqualStrings("100001", model.withdrawal.amount.slice());
    try std.testing.expectEqualStrings("2000", model.withdrawal.fee_reserve.slice());
    try std.testing.expectEqualStrings("1000", model.withdrawal.swap_fee.slice());
    try std.testing.expectEqualStrings("1000", model.withdrawal.input_fee.slice());
    try std.testing.expectEqualStrings("200", model.withdrawal.quote_expiry.slice());
    try std.testing.expectEqualStrings("300", model.withdrawal.invoice_expiry.slice());
    try std.testing.expectEqualStrings("500000 msat", model.balance.slice());
    model.balance_dirty = false;
    model.recover_needed = true;
    model.resume_needed = true;
    model.tick(true, 100);
    try std.testing.expect(!model.pending);
    try std.testing.expect(!model.create("21000") and !model.enqueue(.poll, "") and !model.enqueue(.poll_withdrawals, ""));
    try std.testing.expect(model.confirmWithdrawal());
    try std.testing.expect(!model.confirmWithdrawal());
    try std.testing.expectEqualStrings("operation-uuid", model.request.?.argument.slice());
    model.request = null;
    model.leaveWithdrawal(); // Closing submitted payment does not cancel it.
    model.accept(model.serial, saved_withdrawal, 101, std.testing.allocator);
    try std.testing.expect(!model.reviewLive() and !model.confirmWithdrawal());
    try std.testing.expect(model.withdrawal.status == .pending and model.balance_dirty);
}
test "closing an inflight preparation cancels before queued or background work" {
    var model = withdrawalModel();
    try std.testing.expect(model.prepareWithdrawal("lnbc-input"));
    const serial = model.serial;
    model.request = null;
    model.leaveWithdrawal();
    model.tick(true, 99);
    try std.testing.expect(model.pending and model.operation == .prepare_withdrawal);
    model.accept(serial, prepared_withdrawal, 99, std.testing.allocator);
    try std.testing.expect(model.pending and model.operation == .cancel_withdrawal and !model.canConfirmWithdrawal());
    try std.testing.expectEqualStrings("operation-uuid", model.request.?.argument.slice());
    model.request = null;
    model.accept(model.serial, "{\"quote_id\":\"out-A\",\"cancelled\":true}", 100, std.testing.allocator);
    try std.testing.expect(!model.reviewLive() and !model.abandon_review and model.balance_dirty);
}
test "cross-mint review metadata is rejected atomically and still invalidates financial reads" {
    var model = withdrawalModel();
    _ = model.mint.set("https://other.example/");
    try std.testing.expect(model.prepareWithdrawal("invoice"));
    model.request = null;
    model.accept(model.serial, prepared_withdrawal, 0, std.testing.allocator);
    try std.testing.expect(!model.reviewLive() and model.withdrawal.quote_id.len == 0 and model.withdrawal_blocked);
    try std.testing.expect(model.balance_dirty and model.history_dirty);
    try std.testing.expect(!model.confirmWithdrawal());
}
test "failed cancel keeps conflicting work paused without inventing available funds" {
    var model = withdrawalModel();
    try std.testing.expect(model.prepareWithdrawal("lnbc-input"));
    model.request = null;
    model.accept(model.serial, prepared_withdrawal, 0, std.testing.allocator);
    model.leaveWithdrawal();
    model.request = null;
    model.fail(model.serial, 1);
    model.balance_dirty = false;
    model.tick(true, 100);
    try std.testing.expect(model.withdrawal_blocked and !model.pending and !model.confirmWithdrawal() and !model.create("1"));
    try std.testing.expectEqualStrings("500000 msat", model.balance.slice());
}
test "unknown preparation needs explicit Back even after balance reread changed the current operation" {
    var model = withdrawalModel();
    try std.testing.expect(model.prepareWithdrawal("invalid-invoice"));
    model.request = null;
    model.fail(model.serial, 1);
    model.tick(true, 1);
    try std.testing.expect(model.operation == .snapshot and model.prepare_unknown);
    model.request = null;
    model.accept(model.serial, screen, 1, std.testing.allocator);
    try std.testing.expect(model.withdrawal_blocked and !model.prepareWithdrawal("invoice"));
    model.leaveWithdrawal();
    try std.testing.expect(!model.withdrawal_blocked and !model.prepare_unknown);
    try std.testing.expect(model.prepareWithdrawal("invoice"));
}
test "expiry only disables review confirmation, saved pending remains pending after deadline" {
    var model = withdrawalModel();
    try std.testing.expect(model.prepareWithdrawal("invoice"));
    model.request = null;
    model.accept(model.serial, prepared_withdrawal, 0, std.testing.allocator);
    model.unix_now = 200;
    try std.testing.expect(!model.canConfirmWithdrawal());
    model.leaveWithdrawal();
    model.request = null;
    model.accept(model.serial, "{\"quote_id\":\"out-A\",\"cancelled\":true}", 0, std.testing.allocator);
    try std.testing.expect(model.enqueue(.saved_withdrawal, "out-A"));
    model.request = null;
    model.accept(model.serial, saved_withdrawal, 1000, std.testing.allocator);
    try std.testing.expect(model.withdrawal.status == .pending and !model.withdrawal.expired and !model.confirmWithdrawal());
}
test "large queued withdrawal input is immutable and cancellation never loses its slot" {
    var model = withdrawalModel();
    try std.testing.expect(model.enqueue(.poll_withdrawals, "cursor"));
    var invoice: [4096]u8 = @splat('x');
    try std.testing.expect(model.prepareWithdrawal(&invoice));
    @memset(&invoice, 'z');
    const serial = model.serial;
    model.request = null;
    model.accept(serial, "{\"cursor\":\"next\",\"checked_id\":null,\"withdrawal\":null,\"recovery_pending\":false}", 0, std.testing.allocator);
    try std.testing.expect(model.pending and model.operation == .prepare_withdrawal);
    try std.testing.expectEqualStrings(&@as([4096]u8, @splat('x')), model.request.?.argument.slice());
    model.leaveWithdrawal();
    model.request = null;
    model.accept(model.serial, prepared_withdrawal, 0, std.testing.allocator);
    try std.testing.expect(model.operation == .cancel_withdrawal);
}
test "withdrawal poll cursor advances on error without clobbering a newer history selection" {
    var model = withdrawalModel();
    model.row_count = 1;
    model.rows[0].outgoing = true;
    _ = model.rows[0].mint.set(model.mint.slice());
    _ = model.rows[0].id.set("out-B");
    try std.testing.expect(model.enqueue(.poll_withdrawals, "old"));
    try std.testing.expect(model.openRow(0));
    try std.testing.expect(model.withdrawal.invoice.len == 0 and !model.canCopyInvoice());
    model.request = null;
    model.accept(model.serial, "{\"cursor\":\"out-A\",\"checked_id\":\"out-A\",\"withdrawal\":" ++ saved_withdrawal ++ ",\"recovery_pending\":true,\"error\":{\"status\":7,\"message\":\"pending\"}}", 1, std.testing.allocator);
    try std.testing.expectEqualStrings("out-A", model.withdrawal_cursor.slice());
    try std.testing.expect(model.operation == .saved_withdrawal and model.withdrawal.invoice.len == 0);
    model.request = null;
    model.accept(model.serial, saved_withdrawal, 1, std.testing.allocator); // Wrong quote for published B request.
    try std.testing.expect(model.withdrawal.invoice.len == 0 and !model.confirmWithdrawal());
}
test "bounded scheduler alternates withdrawal sweeps without empty balance loops or deposit recovery starvation" {
    var model = withdrawalModel();
    model.tick(true, 0);
    try std.testing.expect(model.operation == .poll);
    model.request = null;
    model.accept(model.serial, "{\"cursor\":null,\"invoice\":null}", 0, std.testing.allocator);
    model.tick(true, 1.99);
    try std.testing.expect(!model.pending);
    model.tick(true, 2);
    try std.testing.expect(model.operation == .poll); // Equal due times preserve the original deposit slot.
    model.request = null;
    model.accept(model.serial, "{\"cursor\":null,\"invoice\":null}", 2, std.testing.allocator);
    model.tick(true, 2.1);
    try std.testing.expect(model.operation == .poll_withdrawals);
    model.request = null;
    model.accept(model.serial, "{\"cursor\":\"\",\"checked_id\":null,\"withdrawal\":null,\"wallet_changed\":false,\"recovery_pending\":false}", 2.1, std.testing.allocator);
    try std.testing.expect(!model.balance_dirty and !model.history_dirty);
    model.recovery_pending = true;
    model.tick(true, 6.1);
    try std.testing.expect(model.pending and model.operation == .poll_withdrawals);
    model.request = null;
    model.fail(model.serial, 6.1);
    try std.testing.expectEqual(@as(f64, 14.1), model.next_withdrawal_poll);
    model.tick(true, 14);
    try std.testing.expect(!model.pending);
}

test "application poll errors advance selected cursors and preserve global recovery cursor" {
    var model = Model{ .started = true, .available = true, .history_active = true, .history_dirty = false };
    model.next_withdrawal_poll = std.math.inf(f64); // Isolate the deposit error deadline.
    _ = model.mint.set("https://testnut.cashu.space");
    _ = model.balance.set("0 msat");
    try std.testing.expect(model.enqueue(.poll, ""));
    model.request = null;
    model.accept(model.serial, "{\"wallet_changed\":true,\"cursor\":\"A\"," ++ update_error ++ "}", 1, std.testing.allocator);
    try std.testing.expectEqualStrings("A", model.sweep_cursor.slice());
    try std.testing.expect(model.balance_dirty and model.history_dirty);
    const deadline = model.next_check;
    model.tick(true, 1);
    try std.testing.expect(model.operation == .snapshot and model.pending);
    model.request = null;
    model.accept(model.serial, screen, 1, std.testing.allocator);
    model.tick(true, 1);
    try std.testing.expect(model.operation == .history and model.pending);
    model.request = null;
    model.accept(model.serial, "{\"offset\":\"0\",\"total\":\"0\",\"limit\":8,\"rows\":[]}", 1, std.testing.allocator);
    model.tick(true, deadline - 0.01);
    try std.testing.expect(!model.pending);
    model.tick(true, deadline);
    try std.testing.expect(model.pending and model.operation == .poll);
    try std.testing.expectEqualStrings("A", model.request.?.argument.slice());
    model.request = null;
    model.accept(model.serial, "{\"wallet_changed\":false,\"recovery_pending\":false,\"creation_recovery\":\"none\",\"cursor\":\"B\",\"error\":null,\"invoice\":{\"id\":\"B\",\"invoice\":\"invoice-B\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"UNPAID\",\"confirmed\":false,\"expired\":false}}", deadline, std.testing.allocator);
    try std.testing.expectEqualStrings("B", model.sweep_cursor.slice());
    try std.testing.expect(!model.balance_dirty and !model.history_dirty);
    // The opaque cursor used for oversized quotes must progress just like A.
    try std.testing.expect(model.enqueue(.poll, "B"));
    model.request = null;
    model.accept(model.serial, "{\"wallet_changed\":false,\"cursor\":\"cursor-v1:oversized\"," ++ update_error ++ "}", deadline, std.testing.allocator);
    try std.testing.expectEqualStrings("cursor-v1:oversized", model.sweep_cursor.slice());
    try std.testing.expect(model.enqueue(.poll, model.sweep_cursor.slice()));
    model.request = null;
    model.accept(model.serial, "{\"wallet_changed\":true,\"recovery_pending\":true,\"creation_recovery\":\"none\",\"cursor\":null,\"invoice\":null,\"error\":{\"status\":7,\"message\":\"global recovery pending\"}}", deadline, std.testing.allocator);
    try std.testing.expectEqualStrings("cursor-v1:oversized", model.sweep_cursor.slice());
    try std.testing.expect(model.recover_needed and model.balance_dirty and model.history_dirty);
    // Successful empty sweeps, unlike global errors, still reset the cursor.
    try std.testing.expect(model.enqueue(.poll, model.sweep_cursor.slice()));
    model.request = null;
    model.accept(model.serial, "{\"wallet_changed\":false,\"recovery_pending\":false,\"creation_recovery\":\"none\",\"cursor\":null,\"invoice\":null,\"error\":null}", deadline, std.testing.allocator);
    try std.testing.expectEqualStrings("", model.sweep_cursor.slice());
}

test "malformed application poll error or cursor never advances the sweep" {
    const invalid_replies = [_][]const u8{
        "{\"wallet_changed\":false,\"cursor\":17," ++ update_error ++ "}",
        "{\"wallet_changed\":false,\"cursor\":\"bad\\u0000cursor\"," ++ update_error ++ "}",
        "{\"wallet_changed\":false," ++ update_error ++ "}",
        "{\"wallet_changed\":false,\"cursor\":\"A\",\"recovery_pending\":false,\"creation_recovery\":\"none\",\"error\":{\"status\":\"7\",\"message\":\"invalid\"}}",
        "{\"wallet_changed\":false,\"cursor\":\"A\",\"recovery_pending\":false,\"creation_recovery\":\"none\",\"error\":\"invalid\"}",
        "{\"wallet_changed\":false,\"cursor\":\"" ++ @as([1025]u8, @splat('x')) ++ "\"," ++ update_error ++ "}",
    };
    for (invalid_replies) |reply| {
        var model = Model{ .started = true, .available = true, .history_dirty = false };
        _ = model.sweep_cursor.set("previous");
        try std.testing.expect(model.enqueue(.poll, "previous"));
        model.request = null;
        model.accept(model.serial +% 1, "{\"wallet_changed\":true,\"cursor\":\"A\"," ++ update_error ++ "}", 1, std.testing.allocator);
        try std.testing.expect(model.pending and !model.balance_dirty and !model.history_dirty);
        model.accept(model.serial, reply, 1, std.testing.allocator);
        try std.testing.expect(!model.pending and model.next_check > 1);
        try std.testing.expectEqualStrings("previous", model.sweep_cursor.slice());
    }
}

test "remote Issued without local transaction invalidates history but never claims minted funds" {
    const remote_issued = "{\"id\":\"saved\",\"invoice\":\"lnbc210n1test\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"ISSUED\",\"confirmed\":false,\"expired\":false}";
    for ([_]Operation{ .check, .poll }) |op| {
        var model = Model{ .started = true, .available = true, .history_active = true, .history_dirty = false };
        _ = model.mint.set("https://testnut.cashu.space");
        _ = model.balance.set("7000 msat");
        try std.testing.expect(model.enqueue(.saved_invoice, "saved"));
        model.request = null;
        model.accept(model.serial, unpaid, 0, std.testing.allocator);
        try std.testing.expect(model.enqueue(op, "saved"));
        model.request = null;
        model.accept(model.serial, "{\"wallet_changed\":true,\"recovery_pending\":false,\"creation_recovery\":\"none\",\"cursor\":\"saved\",\"error\":null,\"invoice\":" ++ remote_issued ++ "}", 1, std.testing.allocator);
        try std.testing.expect(model.balance_dirty and model.history_dirty and !model.issued);
        try std.testing.expectEqualStrings("7000 msat", model.balance.slice());
        try std.testing.expectEqualStrings("ISSUED", model.quote_state.slice());
        try std.testing.expect(std.mem.indexOf(u8, model.message.slice(), "local issuance unconfirmed") != null);
        model.tick(true, 1);
        try std.testing.expect(model.pending and model.operation == .snapshot);
        model.request = null;
        model.accept(model.serial, screen, 1, std.testing.allocator);
        try std.testing.expectEqualStrings("0 msat", model.balance.slice());
        try std.testing.expect(!model.issued);
        model.tick(true, 1);
        try std.testing.expect(model.pending and model.operation == .history);
        model.request = null;
        model.accept(model.serial, "{\"offset\":\"0\",\"total\":\"1\",\"limit\":8,\"rows\":[{\"direction\":\"In\",\"id\":\"saved\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"ISSUED\",\"unit\":\"msat\"}]}", 1, std.testing.allocator);
        try std.testing.expect(!model.history_dirty and !model.history_error);
        try std.testing.expect(std.mem.indexOf(u8, model.rows[0].text.slice(), "ISSUED") != null);
    }
}

test "application metadata survives stale selection and operational error without speculative balances" {
    for ([_]Operation{ .check, .poll }) |op| {
        var model = Model{ .started = true, .available = true, .row_count = 1, .history_dirty = false };
        _ = model.mint.set("https://testnut.cashu.space");
        _ = model.invoice.set("invoice-A");
        _ = model.quote_id.set("A");
        _ = model.balance.set("7000 msat");
        _ = model.rows[0].id.set("saved");
        _ = model.rows[0].mint.set(model.mint.slice());
        try std.testing.expect(model.enqueue(op, "A"));
        const serial = model.serial;
        try std.testing.expect(model.openRow(0));
        try std.testing.expect(model.selection_loading and !model.canCopyInvoice() and model.invoice.len == 0);
        model.request = null;
        model.accept(serial, "{\"wallet_changed\":true,\"recovery_pending\":true,\"creation_recovery\":\"none\",\"invoice\":null,\"cursor\":null,\"error\":{\"status\":7,\"message\":\"failed after partial recovery\"}}", 1, std.testing.allocator);
        try std.testing.expect(model.balance_dirty and model.history_dirty and model.recover_needed);
        try std.testing.expectEqualStrings("7000 msat", model.balance.slice());
        try std.testing.expect(model.operation == .saved_invoice and model.pending and !model.canCopyInvoice());
        model.request = null;
        model.fail(model.serial, 1);
        try std.testing.expect(!model.canCopyInvoice() and model.invoice.len == 0);
        try std.testing.expect(model.enqueue(.resume_saved, ""));
        model.accept(model.serial, "{\"invoice\":{\"id\":\"A\",\"invoice\":\"invoice-A\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"UNPAID\",\"expired\":false}}", 2, std.testing.allocator);
        try std.testing.expect(!model.canCopyInvoice());
        try std.testing.expect(model.openRow(0));
        model.accept(model.serial, unpaid, 2, std.testing.allocator);
        try std.testing.expect(model.canCopyInvoice());
        try std.testing.expectEqualStrings("saved", model.quote_id.slice());
    }
}

test "pending mint recovery with no creation intent respects bounded deadline and unchanged updates do not refresh" {
    var model = Model{};
    model.next_withdrawal_poll = std.math.inf(f64);
    model.tick(true, 0);
    model.accept(model.serial, "{\"mint_url\":\"https://testnut.cashu.space\",\"msats\":\"0\",\"creation_recovery\":\"none\",\"recovery_pending\":true}", 0, std.testing.allocator);
    model.resume_needed = false;
    model.history_dirty = false;
    model.request = null;
    model.tick(true, 1);
    try std.testing.expect(!model.pending and model.recover_needed);
    model.tick(true, 2);
    try std.testing.expect(model.pending and model.operation == .recover);
    model.request = null;
    model.accept(model.serial, "{\"wallet_changed\":true,\"recovery_pending\":true,\"creation_recovery\":\"none\",\"invoice\":null,\"cursor\":null,\"error\":{\"status\":7,\"message\":\"pending\"}}", 2, std.testing.allocator);
    const deadline = model.next_recover;
    model.tick(true, 2);
    try std.testing.expect(model.operation == .snapshot);
    model.request = null;
    model.accept(model.serial, "{\"mint_url\":\"https://testnut.cashu.space\",\"msats\":\"21000\",\"creation_recovery\":\"none\",\"recovery_pending\":true}", 2, std.testing.allocator);
    model.tick(true, deadline - 0.01);
    try std.testing.expect(!model.pending and model.next_recover == deadline);
    model.tick(true, deadline);
    model.request = null;
    model.accept(model.serial, "{\"wallet_changed\":false,\"recovery_pending\":false,\"creation_recovery\":\"none\",\"invoice\":null,\"cursor\":null,\"error\":null}", deadline, std.testing.allocator);
    model.history_dirty = false;
    try std.testing.expect(model.enqueue(.check, "saved"));
    model.accept(model.serial, "{\"wallet_changed\":false,\"recovery_pending\":false,\"creation_recovery\":\"none\",\"invoice\":" ++ unpaid ++ ",\"cursor\":null,\"error\":null}", deadline, std.testing.allocator);
    try std.testing.expect(!model.balance_dirty and !model.history_dirty);
    for ([_]Operation{ .poll, .recover }) |op| {
        try std.testing.expect(model.enqueue(op, ""));
        model.accept(model.serial, "{\"wallet_changed\":false,\"recovery_pending\":false,\"creation_recovery\":\"none\",\"invoice\":" ++ unpaid ++ ",\"cursor\":null,\"error\":null}", deadline, std.testing.allocator);
        try std.testing.expect(!model.balance_dirty and !model.history_dirty);
    }
}
test "deposit accepts integer msats without scaling or rounding" {
    for ([_][]const u8{ "", "0", "-1", "+1", "1.1", "1e3", " 1", "18446744073709551616", "9223372036854775808" }) |bad| try std.testing.expectError(error.InvalidAmount, positiveMsats(bad));
    try std.testing.expectEqual(@as(u64, 1), try positiveMsats("1"));
    var model = withdrawalModel();
    try std.testing.expect(model.create("42001"));
    try std.testing.expectEqualStrings("42001", model.request.?.argument.slice());
}
test "unchanged unpaid checks do not request balance or history; issued rereads actual balance" {
    var model = Model{};
    model.next_withdrawal_poll = std.math.inf(f64); // Isolate deposit scheduling.
    model.tick(true, 0);
    model.accept(model.serial, screen, 0, std.testing.allocator);
    model.resume_needed = false;
    _ = model.enqueue(.create, "21000");
    model.accept(model.serial, unpaid, 0, std.testing.allocator);
    model.recover_needed = false;
    model.history_active = true;
    model.history_dirty = false;
    for (1..5) |index| {
        const now: f64 = @floatFromInt(index * 3);
        model.tick(true, now);
        try std.testing.expect(model.operation == (if (index % 2 == 1) Operation.poll else Operation.check) and model.pending);
        model.accept(model.serial, if (model.operation == .poll) "{\"cursor\":\"saved\",\"invoice\":" ++ unpaid ++ "}" else unpaid, now, std.testing.allocator);
        try std.testing.expect(!model.balance_dirty and !model.history_dirty);
    }
    model.tick(true, 20);
    model.accept(model.serial, "{\"cursor\":\"saved\",\"invoice\":{\"id\":\"saved\",\"invoice\":\"lnbc210n1test\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"ISSUED\",\"confirmed\":true,\"expired\":false}}", 20, std.testing.allocator);
    try std.testing.expect(model.balance_dirty and model.history_dirty);
    try std.testing.expectEqualStrings("0 msat", model.balance.slice());
    model.tick(true, 20);
    try std.testing.expect(model.operation == .snapshot);
    model.accept(model.serial, "{\"mint_url\":\"https://testnut.cashu.space\",\"msats\":\"19000\",\"creation_recovery\":\"none\"}", 20, std.testing.allocator);
    try std.testing.expectEqualStrings("19000 msat", model.balance.slice());
}
test "history paging keeps published offset immutable and validates clamp and stale callbacks" {
    var model = Model{};
    model.tick(true, 0);
    model.visit(true, false);
    model.accept(model.serial, screen, 0, std.testing.allocator);
    model.resume_needed = false;
    model.tick(true, 0);
    try std.testing.expect(model.operation == .history);
    const serial = model.serial;
    model.changePage(1);
    try std.testing.expectEqual(@as(u32, 0), model.pending_offset);
    model.accept(serial + 1, "{}", 0, std.testing.allocator);
    try std.testing.expect(model.pending);
    model.accept(serial, "{\"offset\":\"8\",\"total\":\"9\",\"limit\":8,\"rows\":[]}", 0, std.testing.allocator);
    try std.testing.expect(model.available and model.history_error and !model.pending);
    model.desired_offset = 800;
    model.history_dirty = true;
    model.next_check = 2;
    model.tick(true, 0);
    model.accept(model.serial, "{\"offset\":\"0\",\"total\":\"0\",\"limit\":8,\"rows\":[]}", 0, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), model.desired_offset);
    try std.testing.expectEqual(@as(usize, 0), model.row_count);
    model.visit(false, false);
    model.history_dirty = true;
    model.tick(true, 0);
    try std.testing.expect(!model.pending);
}
test "scoped read failures retain wallet, invoice and balance" {
    var model = Model{};
    model.tick(true, 0);
    model.accept(model.serial, screen, 0, std.testing.allocator);
    model.resume_needed = false;
    _ = model.enqueue(.create, "21000");
    model.accept(model.serial, unpaid, 0, std.testing.allocator);
    model.recover_needed = false;
    for ([_]Operation{ .history, .resume_saved, .recover, .snapshot, .check, .poll }) |op| {
        try std.testing.expect(model.enqueue(op, if (op == .history) "0" else ""));
        model.fail(model.serial, 0);
        try std.testing.expect(model.available);
        try std.testing.expectEqualStrings("saved", model.quote_id.slice());
        try std.testing.expectEqualStrings("0 msat", model.balance.slice());
    }
    _ = model.enqueue(.resume_saved, "");
    model.accept(model.serial, "{\"invoice\":null,\"error\":\"too long\"}", 0, std.testing.allocator);
    try std.testing.expectEqualStrings("saved", model.quote_id.slice());
}

test "resume accepts newest saved invoice without a cursor" {
    var model = Model{};
    model.tick(true, 0);
    model.accept(model.serial, screen, 0, std.testing.allocator);
    model.tick(true, 0);
    try std.testing.expect(model.operation == .resume_saved);
    try std.testing.expectEqualStrings("", model.request.?.argument.slice());
    model.accept(model.serial, "{\"invoice\":" ++ unpaid ++ "}", 0, std.testing.allocator);
    try std.testing.expectEqualStrings("saved", model.quote_id.slice());
    try std.testing.expect(!model.pending);
}

test "retried startup resume preserves a history selection and completes its backoff" {
    var model = Model{};
    model.tick(true, 0);
    model.accept(model.serial, screen, 0, std.testing.allocator);
    model.tick(true, 0);
    try std.testing.expect(model.operation == .resume_saved);
    model.fail(model.serial, 0);
    try std.testing.expect(model.resume_needed and model.next_resume == 2 and model.resume_backoff == 4);

    // The user selects B from History before the startup read retries.
    try std.testing.expect(model.enqueue(.history, "0"));
    model.accept(model.serial, "{\"offset\":\"0\",\"total\":\"1\",\"limit\":8,\"rows\":[{\"id\":\"selected-B\",\"direction\":\"In\",\"mint_url\":\"https://testnut.cashu.space\"}]}", 1, std.testing.allocator);
    try std.testing.expect(model.openRow(0));
    model.accept(model.serial, "{\"id\":\"selected-B\",\"invoice\":\"lnbc-selected-B\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"PAID\",\"confirmed\":false,\"expired\":true}", 1, std.testing.allocator);
    const selected_id = model.quote_id;
    const selected_invoice = model.invoice;
    const selected_qr = model.qr;
    const selected_state = model.quote_state;
    const selected_expired = model.expired;
    const selected_issued = model.issued;

    model.tick(true, 2);
    try std.testing.expect(model.operation == .resume_saved and model.pending);
    const resumed_a = "{\"invoice\":{\"id\":\"saved-A\",\"invoice\":\"lnbc-saved-A\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"ISSUED\",\"confirmed\":true,\"expired\":false}}";
    for ([_][]const u8{ resumed_a, "{\"invoice\":null}", "{\"invoice\":null,\"error\":\"too long\"}" }, 0..) |reply, index| {
        if (index != 0) try std.testing.expect(model.enqueue(.resume_saved, ""));
        model.accept(model.serial, reply, 2, std.testing.allocator);
        try std.testing.expect(!model.pending and !model.resume_needed);
        try std.testing.expectEqual(@as(f64, 2), model.resume_backoff);
        try std.testing.expectEqual(@as(f64, 0), model.next_resume);
        try std.testing.expectEqualDeep(selected_id, model.quote_id);
        try std.testing.expectEqualDeep(selected_invoice, model.invoice);
        try std.testing.expectEqualDeep(selected_qr, model.qr);
        try std.testing.expectEqualDeep(selected_state, model.quote_state);
        try std.testing.expectEqual(selected_expired, model.expired);
        try std.testing.expectEqual(selected_issued, model.issued);
    }
}

test "locally confirmed Issued transition refreshes balance even when state was already Issued" {
    var model = Model{};
    model.tick(true, 0);
    model.accept(model.serial, screen, 0, std.testing.allocator);
    model.resume_needed = false;
    _ = model.enqueue(.create, "21000");
    const unconfirmed = "{\"id\":\"saved\",\"invoice\":\"lnbc210n1test\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"ISSUED\",\"confirmed\":false,\"expired\":false}";
    model.accept(model.serial, unconfirmed, 0, std.testing.allocator);
    model.recover_needed = false;
    try std.testing.expect(!model.issued and !model.balance_dirty);
    model.check_turn = true;
    model.tick(true, 3);
    model.accept(model.serial, "{\"id\":\"saved\",\"invoice\":\"lnbc210n1test\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"ISSUED\",\"confirmed\":true,\"expired\":false}", 3, std.testing.allocator);
    try std.testing.expect(model.issued and model.balance_dirty);
    model.tick(true, 3);
    try std.testing.expect(model.operation == .snapshot);
}

test "bounded history renders real times and unknown owners without opening unsupported rows" {
    var model = Model{};
    model.tick(true, 0);
    model.accept(model.serial, screen, 0, std.testing.allocator);
    model.resume_needed = false;
    model.visit(true, false);
    model.tick(true, 0);
    model.accept(model.serial, "{\"offset\":\"0\",\"total\":\"1\",\"limit\":8,\"rows\":[{\"id\":\"saved\",\"direction\":\"Out\",\"amount\":\"42000\",\"unit\":\"msat\",\"state\":\"UNPAID\",\"created_at\":null,\"mint_url\":null}]}", 0, std.testing.allocator);
    try std.testing.expect(model.rows[0].outgoing and model.row_count == 1);
    try std.testing.expect(std.mem.indexOf(u8, model.rows[0].text.slice(), "Time unknown | 42000 msat | UNPAID") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.rows[0].text.slice(), "Mint unknown (not refreshed)") != null);
    var time: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01 00:00 UTC", formatTime("0", &time));
    try std.testing.expect(!model.openRow(1));
    try std.testing.expect(!model.openRow(0));
    try std.testing.expect(!model.pending);
}

test "expired invoice is marked and only background sweeps run" {
    var model = Model{};
    model.next_withdrawal_poll = std.math.inf(f64);
    model.tick(true, 0);
    model.accept(model.serial, screen, 0, std.testing.allocator);
    model.tick(true, 0);
    model.accept(model.serial, "{\"invoice\":{\"id\":\"saved\",\"invoice\":\"lnbc210n1test\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"UNPAID\",\"confirmed\":false,\"expired\":true}}", 0, std.testing.allocator);
    try std.testing.expect(model.expired and !model.issued);
    try std.testing.expectEqualStrings("Invoice expired; unpaid checks stopped. Saved work retained.", model.message.slice());
    for (1..5) |slot| {
        const now: f64 = @floatFromInt(slot * 3);
        model.tick(true, now);
        try std.testing.expect(model.pending and model.operation == .poll);
        model.accept(model.serial, "{\"cursor\":null,\"invoice\":null}", now, std.testing.allocator);
    }
}

test "poll confirmed issuance dirties balance and history, errors preserve cursor and back off" {
    var model = Model{};
    model.tick(true, 0);
    model.accept(model.serial, screen, 0, std.testing.allocator);
    model.resume_needed = false;
    model.history_dirty = false;
    _ = model.enqueue(.poll, "");
    model.accept(model.serial, "{\"cursor\":\"other\",\"invoice\":{\"id\":\"other\",\"invoice\":\"lnbc210n1test\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"ISSUED\",\"confirmed\":false,\"expired\":false}}", 0, std.testing.allocator);
    try std.testing.expect(!model.balance_dirty and !model.history_dirty);
    _ = model.enqueue(.poll, "other");
    model.accept(model.serial, "{\"cursor\":\"other\",\"invoice\":{\"id\":\"other\",\"invoice\":\"lnbc210n1test\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"ISSUED\",\"confirmed\":true,\"expired\":false}}", 2, std.testing.allocator);
    try std.testing.expect(model.balance_dirty and model.history_dirty);
    try std.testing.expectEqualStrings("Saved deposit minted; balance updated.", model.message.slice());
    _ = model.enqueue(.poll, "other");
    model.accept(model.serial, "{\"cursor\":\"failed\",\"invoice\":null,\"error\":\"offline\"}", 4, std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 8), model.next_check);
    try std.testing.expectEqualStrings("failed", model.sweep_cursor.slice());
    _ = model.enqueue(.poll, "failed");
    model.fail(model.serial, 8);
    try std.testing.expectEqual(@as(f64, 16), model.next_check);
    try std.testing.expect(model.available);
}

test "creation failure retries local recovery automatically with bounded backoff" {
    var model = Model{};
    model.next_withdrawal_poll = std.math.inf(f64);
    model.tick(true, 0);
    model.accept(model.serial, screen, 0, std.testing.allocator);
    model.resume_needed = false;
    try std.testing.expect(model.create("21000"));
    model.fail(model.serial, 1);
    try std.testing.expect(model.recovery == .unknown and model.recover_needed);
    model.tick(true, 1);
    try std.testing.expect(model.pending and model.operation == .recover);
    model.fail(model.serial, 1);
    try std.testing.expectEqual(@as(f64, 5), model.next_recover);
    model.next_check = 100;
    model.tick(true, 4);
    try std.testing.expect(!model.pending);
    model.tick(true, 5);
    try std.testing.expect(model.operation == .recover and model.pending);
    model.fail(model.serial, 5);
    try std.testing.expectEqual(@as(f64, 13), model.next_recover);
    try std.testing.expect(!model.create("21000"));
    try std.testing.expect(!model.pending);
    model.tick(true, 13);
    model.accept(model.serial, "{\"creation_recovery\":\"none\",\"invoice\":null}", 13, std.testing.allocator);
    try std.testing.expect(model.recovery == .none and !model.recover_needed);
    try std.testing.expectEqual(@as(f64, 2), model.recover_backoff);
}

test "poll completes before one queued create publishes with a fresh serial" {
    var model = Model{ .available = true };
    try std.testing.expect(model.enqueue(.poll, ""));
    const serial = model.serial;
    const request = model.request.?;
    try std.testing.expect(model.create("21000"));
    try std.testing.expectEqualStrings("Creating saved invoice...", model.message.slice());
    try std.testing.expect(!model.create("42000"));
    try std.testing.expectEqual(serial, model.serial);
    try std.testing.expectEqualDeep(request, model.request.?);
    try std.testing.expectEqual(Operation.poll, model.operation);
    model.request = null; // Transport consumes the published request.
    model.accept(serial, "{\"cursor\":\"completed\",\"invoice\":null}", 3, std.testing.allocator);
    try std.testing.expectEqualStrings("completed", model.sweep_cursor.slice());
    try std.testing.expectEqual(@as(f64, 5), model.next_check);
    try std.testing.expect(model.pending and model.queued == null);
    try std.testing.expectEqual(Operation.create, model.operation);
    try std.testing.expectEqual(serial +% 1, model.request.?.serial);
    try std.testing.expectEqualStrings("21000", model.request.?.argument.slice());
    try std.testing.expect(!model.create("100000"));
    model.accept(serial, "{}", 4, std.testing.allocator);
    try std.testing.expect(model.pending and model.operation == .create);
}

test "blocking operations reject deferred requests and background failure drains once" {
    for ([_]Operation{ .create, .history, .resume_saved, .recover, .snapshot, .open }) |op| {
        var model = Model{ .available = true };
        try std.testing.expect(model.enqueue(op, if (op == .history) "0" else ""));
        try std.testing.expect(!model.enqueue(.check, "saved"));
        try std.testing.expect(model.queued == null);
    }
    for ([_]Operation{ .poll, .check }) |op| {
        var model = Model{ .available = true };
        try std.testing.expect(model.enqueue(op, "active"));
        const serial = model.serial;
        try std.testing.expect(model.enqueue(.check, "next"));
        try std.testing.expect(!model.enqueue(.check, "lost"));
        if (op == .check) try std.testing.expectEqualStrings("active", model.check_id.slice());
        model.request = null;
        model.fail(serial, 0);
        try std.testing.expect(model.pending and model.queued == null);
        try std.testing.expectEqualStrings("next", model.check_id.slice());
        try std.testing.expectEqual(serial +% 1, model.serial);
        model.fail(serial, 0);
        try std.testing.expect(model.pending);
        model.request = null;
        model.fail(model.serial, 0);
        try std.testing.expect(!model.pending and model.queued == null);
    }
}

test "saved history row queues behind poll and check without changing active metadata" {
    for ([_]Operation{ .poll, .check }) |op| {
        var model = Model{ .available = true, .row_count = 1 };
        _ = model.mint.set("https://testnut.cashu.space");
        _ = model.rows[0].id.set("saved");
        _ = model.rows[0].mint.set(model.mint.slice());
        try std.testing.expect(model.enqueue(op, "active"));
        const serial = model.serial;
        try std.testing.expect(model.openRow(0));
        model.request = null;
        const active = "{\"id\":\"active\",\"invoice\":\"lnbc-active\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"UNPAID\",\"confirmed\":false,\"expired\":false}";
        model.accept(serial, if (op == .poll) "{\"cursor\":\"active\",\"invoice\":null}" else active, 0, std.testing.allocator);
        try std.testing.expectEqualStrings("", model.quote_id.slice());
        try std.testing.expect(model.pending and model.operation == .saved_invoice);
        try std.testing.expectEqualStrings("saved", model.selected_id.slice());
        try std.testing.expect(!model.canCopyInvoice());
        model.request = null;
        model.accept(model.serial, unpaid, 1, std.testing.allocator);
        try std.testing.expect(!model.pending);
        try std.testing.expectEqualStrings("saved", model.quote_id.slice());
    }
}

test "page changes during poll defer history fetch and queued history validates before publish" {
    var model = Model{ .started = true, .available = true, .history_active = true, .total_rows = 17 };
    try std.testing.expect(model.enqueue(.poll, ""));
    model.changePage(1);
    try std.testing.expectEqual(@as(u32, 8), model.desired_offset);
    try std.testing.expect(model.history_dirty);
    try std.testing.expectEqual(@as(u32, 0), model.pending_offset);
    model.request = null;
    model.accept(model.serial, "{\"cursor\":null,\"invoice\":null}", 0, std.testing.allocator);
    model.tick(true, 0);
    try std.testing.expect(model.pending and model.operation == .history);
    try std.testing.expectEqualStrings("8", model.request.?.argument.slice());
    try std.testing.expectEqual(@as(u32, 8), model.pending_offset);

    var queued = Model{ .available = true, .pending_offset = 16 };
    try std.testing.expect(queued.enqueue(.poll, ""));
    for ([_][]const u8{ "bad", "1", "4294967296" }) |bad| try std.testing.expect(!queued.enqueue(.history, bad));
    try std.testing.expect(queued.enqueue(.history, "8"));
    try std.testing.expectEqual(@as(u32, 16), queued.pending_offset);
    queued.request = null;
    queued.fail(queued.serial, 0);
    try std.testing.expectEqual(@as(u32, 8), queued.pending_offset);
}

test "deferred slot never overwrites an unconsumed published request" {
    var model = Model{ .started = true, .available = true };
    try std.testing.expect(model.enqueue(.poll, ""));
    const request = model.request.?;
    try std.testing.expect(model.create("21000"));
    model.fail(model.serial, 0);
    try std.testing.expect(!model.pending and model.queued != null);
    model.tick(true, 0);
    try std.testing.expectEqualDeep(request, model.request.?);
    try std.testing.expect(!model.create("42000"));
    model.request = null;
    model.tick(true, 0);
    try std.testing.expect(model.pending and model.queued == null and model.operation == .create);
}

test "unknown startup and cleanup outcomes retry local recovery on bounded deadlines" {
    for ([_][]const u8{ "unknown", "legacy_unknown" }) |status| {
        var model = Model{};
        model.next_withdrawal_poll = std.math.inf(f64);
        model.tick(true, 0);
        var buf: [256]u8 = undefined;
        const snapshot = try std.fmt.bufPrint(&buf, "{{\"mint_url\":\"https://testnut.cashu.space\",\"msats\":\"0\",\"creation_recovery\":\"{s}\"}}", .{status});
        model.accept(model.serial, snapshot, 0, std.testing.allocator);
        model.resume_needed = false;
        model.next_check = 10000;
        try std.testing.expect(model.recover_needed and model.next_recover == 2);
        var now: f64 = 0;
        for (0..8) |_| {
            const deadline = model.next_recover;
            try std.testing.expect(deadline > now and deadline - now <= 30);
            model.tick(true, deadline - 0.01);
            try std.testing.expect(!model.pending);
            model.tick(true, deadline);
            try std.testing.expect(model.pending and model.operation == .recover);
            const reply = try std.fmt.bufPrint(&buf, "{{\"creation_recovery\":\"{s}\",\"invoice\":null}}", .{status});
            model.accept(model.serial, reply, deadline, std.testing.allocator);
            try std.testing.expect(!model.create("21000"));
            now = deadline;
        }
        try std.testing.expectEqual(@as(f64, 30), model.next_recover - now);
        if (std.mem.eql(u8, status, "legacy_unknown")) continue;
        // Cleanup failure can return a usable invoice together with unknown.
        model.tick(true, model.next_recover);
        model.accept(model.serial, "{\"creation_recovery\":\"unknown\",\"invoice\":" ++ unpaid ++ "}", now + 30, std.testing.allocator);
        try std.testing.expectEqualStrings("saved", model.quote_id.slice());
        try std.testing.expect(model.invoice.len != 0 and !model.create("21000"));
        try std.testing.expect(model.enqueue(.check, "saved"));
        model.accept(model.serial, unpaid, now + 31, std.testing.allocator);
        try std.testing.expect(model.recovery == .unknown);
        try std.testing.expect(model.enqueue(.poll, ""));
        model.accept(model.serial, "{\"cursor\":null,\"invoice\":null}", now + 32, std.testing.allocator);
        try std.testing.expect(model.recovery == .unknown and model.recover_needed);
        model.tick(true, model.next_recover);
        model.accept(model.serial, "{\"creation_recovery\":\"none\",\"invoice\":null}", now + 60, std.testing.allocator);
        try std.testing.expect(model.recovery == .none and !model.recover_needed);
        try std.testing.expectEqual(@as(f64, 2), model.recover_backoff);
        try std.testing.expectEqualStrings("saved", model.quote_id.slice());
        try std.testing.expect(!model.pending); // No replacement creation POST.
    }
}

test "local recovery preserves a different selected invoice while reconciling the creation gate" {
    var model = Model{ .started = true, .available = true };
    _ = model.mint.set("https://testnut.cashu.space");
    _ = model.balance.set("7000 msat");
    try std.testing.expect(model.enqueue(.check, "selected-B"));
    model.accept(model.serial, "{\"id\":\"selected-B\",\"invoice\":\"lnbc-selected-B\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"UNPAID\",\"confirmed\":false,\"expired\":false}", 0, std.testing.allocator);
    const selected_qr = model.qr;
    model.history_dirty = false;
    model.setRecovery(.unknown, 0);
    model.tick(true, model.next_recover);
    try std.testing.expect(model.operation == .recover and model.pending);
    model.accept(model.serial, "{\"creation_recovery\":\"unknown\",\"invoice\":" ++ unpaid ++ "}", 2, std.testing.allocator);
    try std.testing.expectEqualStrings("selected-B", model.quote_id.slice());
    try std.testing.expectEqualStrings("lnbc-selected-B", model.invoice.slice());
    try std.testing.expectEqualDeep(selected_qr, model.qr);
    try std.testing.expect(model.recovery == .unknown and model.recover_needed and model.next_recover > 2);
    try std.testing.expect(!model.balance_dirty and !model.issued);
    try std.testing.expect(!model.create("21000"));
    model.history_dirty = false;
    const deadline = model.next_recover;
    model.tick(true, deadline);
    try std.testing.expect(model.operation == .recover and model.pending);
    model.accept(model.serial, "{\"creation_recovery\":\"none\",\"invoice\":{\"id\":\"saved\",\"invoice\":\"lnbc210n1test\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"ISSUED\",\"confirmed\":true,\"expired\":false}}", deadline, std.testing.allocator);
    try std.testing.expectEqualStrings("selected-B", model.quote_id.slice());
    try std.testing.expectEqualStrings("lnbc-selected-B", model.invoice.slice());
    try std.testing.expectEqualDeep(selected_qr, model.qr);
    try std.testing.expectEqualStrings("UNPAID", model.quote_state.slice());
    try std.testing.expect(!model.issued and !model.expired);
    try std.testing.expect(model.recovery == .none and !model.recover_needed);
    try std.testing.expectEqual(@as(f64, 2), model.recover_backoff);
    try std.testing.expectEqual(@as(f64, 0), model.next_recover);
    try std.testing.expect(model.balance_dirty and model.history_dirty);
    try std.testing.expectEqualStrings("7000 msat", model.balance.slice());
    try std.testing.expect(!model.pending and model.queued == null);
    model.tick(true, deadline);
    try std.testing.expect(model.operation == .snapshot); // Reread, never increment or create.
}

const history_row = "{\"id\":\"saved\",\"direction\":\"In\",\"mint_url\":\"https://testnut.cashu.space\",\"amount\":\"21000\",\"unit\":\"msat\",\"state\":\"UNPAID\"}";
const placeholder_row = "{\"direction\":\"In\",\"identity\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"error\":\"Saved quote exceeds display limit\"}";
const seven_history_rows = history_row ++ "," ++ history_row ++ "," ++ history_row ++ "," ++ history_row ++ "," ++ history_row ++ "," ++ history_row ++ "," ++ history_row;

test "history placeholders preserve seven normal rows and malformed normal ids still fail" {
    var model = Model{ .started = true, .available = true };
    _ = model.mint.set("https://testnut.cashu.space");
    try std.testing.expect(model.enqueue(.history, "0"));
    model.accept(model.serial, "{\"offset\":\"0\",\"total\":\"8\",\"limit\":8,\"rows\":[" ++ seven_history_rows ++ "," ++ placeholder_row ++ "]}", 0, std.testing.allocator);
    try std.testing.expect(!model.history_error and model.row_count == 8);
    try std.testing.expect(!model.openRow(7));
    try std.testing.expect(model.rows[7].text.len != 0);
    for (model.rows[0..7]) |row| try std.testing.expectEqualStrings("saved", row.id.slice());
    try std.testing.expect(model.openRow(0));
    model.accept(model.serial, unpaid, 0, std.testing.allocator);
    for ([_][]const u8{ "{\"direction\":\"In\"}", "{\"direction\":\"In\",\"id\":\"\"}", "{\"direction\":\"In\",\"id\":\"bad\\u0000id\"}" }) |row| {
        try std.testing.expect(model.enqueue(.history, "0"));
        var buf: [256]u8 = undefined;
        model.accept(model.serial, try std.fmt.bufPrint(&buf, "{{\"offset\":\"0\",\"total\":\"1\",\"limit\":8,\"rows\":[{s}]}}", .{row}), 0, std.testing.allocator);
        try std.testing.expect(model.history_error and model.row_count == 8);
    }
    const oversized = try std.testing.allocator.alloc(u8, 128 * 1024 + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expect(model.enqueue(.history, "0"));
    model.accept(model.serial, oversized, 0, std.testing.allocator);
    try std.testing.expect(model.history_error and model.row_count == 8);
}

test "history activation refuses other-mint and unknown-owner id collisions" {
    var model = Model{ .available = true, .row_count = 1 };
    _ = model.mint.set("https://testnut.cashu.space");
    _ = model.invoice.set("old-invoice");
    _ = model.rows[0].id.set("saved");
    _ = model.rows[0].mint.set(model.mint.slice());
    model.rows[0].outgoing = false;
    _ = model.rows[0].mint.set("https://other.example");
    try std.testing.expect(!model.openRow(0));
    _ = model.rows[0].mint.set("");
    try std.testing.expect(!model.openRow(0));
    try std.testing.expect(!model.pending and model.queued == null);
    try std.testing.expectEqualStrings("old-invoice", model.invoice.slice());
    _ = model.rows[0].mint.set(model.mint.slice());
    try std.testing.expect(model.openRow(0));
    try std.testing.expectEqualStrings("saved", model.request.?.argument.slice());
}

test "pending history completion preserves a newer page target and follows up" {
    var model = Model{ .started = true, .available = true, .history_active = true, .total_rows = 24, .desired_offset = 8 };
    model.tick(true, 0);
    try std.testing.expect(model.operation == .history and model.pending_offset == 8);
    const serial = model.serial;
    model.changePage(1);
    try std.testing.expectEqual(@as(u32, 16), model.desired_offset);
    model.accept(serial + 1, "{}", 0, std.testing.allocator);
    try std.testing.expect(model.pending);
    model.accept(serial, "{\"offset\":\"8\",\"total\":\"24\",\"limit\":8,\"rows\":[" ++ seven_history_rows ++ "," ++ history_row ++ "]}", 0, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 16), model.desired_offset);
    try std.testing.expect(model.history_dirty);
    model.tick(true, 0);
    try std.testing.expect(model.operation == .history and model.pending_offset == 16);
    model.accept(model.serial, "{\"offset\":\"0\",\"total\":\"1\",\"limit\":8,\"rows\":[" ++ history_row ++ "]}", 0, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), model.desired_offset);
    model.desired_offset = 8;
    model.history_dirty = true;
    model.tick(true, 0);
    model.accept(model.serial, "{\"offset\":\"0\",\"total\":\"0\",\"limit\":8,\"rows\":[]}", 0, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), model.desired_offset);
    try std.testing.expect(!model.history_error and model.row_count == 0);
}

test "persistent resume failures back off while checks and sweeps continue" {
    var model = Model{};
    model.next_withdrawal_poll = std.math.inf(f64);
    model.tick(true, 0);
    model.accept(model.serial, screen, 0, std.testing.allocator);
    _ = model.quote_id.set("saved");
    var resumes: usize = 0;
    var checks: usize = 0;
    var sweeps: usize = 0;
    for (0..1000) |frame| {
        const now = @as(f64, @floatFromInt(frame)) / 100;
        model.tick(true, now);
        if (!model.pending) continue;
        switch (model.operation) {
            .resume_saved => {
                resumes += 1;
                model.fail(model.serial, now);
                try std.testing.expect(model.next_resume > now and model.next_resume - now <= 30);
            },
            .check => {
                checks += 1;
                model.accept(model.serial, unpaid, now, std.testing.allocator);
            },
            .poll => {
                sweeps += 1;
                model.accept(model.serial, "{\"cursor\":null,\"invoice\":null}", now, std.testing.allocator);
            },
            else => return error.UnexpectedOperation,
        }
    }
    try std.testing.expect(resumes == 3 and checks > 0 and sweeps > 0);
    model.tick(true, model.next_resume);
    try std.testing.expect(model.operation == .resume_saved);
    model.accept(model.serial, "{\"invoice\":" ++ unpaid ++ "}", model.next_resume, std.testing.allocator);
    try std.testing.expect(!model.resume_needed and model.resume_backoff == 2 and model.next_resume == 0);
}
