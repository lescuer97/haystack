//! Pure, bounded wallet presentation. Services own handles and source pagination.
const std = @import("std");
const qr_mod = @import("qr.zig");
pub const Operation = enum { open, snapshot, create, check, history, resume_saved, recover, poll, saved_invoice };
pub const Request = struct { operation: Operation, argument: Text(1024) = .{}, serial: u32 };
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
pub const Model = struct {
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
    page: usize = 0,
    desired_offset: u32 = 0,
    pending_offset: u32 = 0,
    row_count: usize = 0,
    total_rows: usize = 0,
    history_error: bool = false,
    rows: [8]Row = @splat(.{}),

    pub fn enqueue(self: *Model, operation: Operation, argument: []const u8) bool {
        if (self.queued != null or (operation != .open and !self.available)) return false;
        if (self.pending and self.operation != .poll and self.operation != .check) return false;
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
        if (req.operation == .history) self.pending_offset = @intCast(decimal(req.argument.slice()) catch unreachable);
        self.operation = req.operation;
        self.request = req;
        self.pending = true;
    }
    fn publishQueued(self: *Model) void {
        // A transport must consume the published request before its slot is reused.
        if (self.pending or self.request != null) return;
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
            } else if (!self.selection_loading and !self.recovery_pending and now >= self.next_check) {
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
        _ = positiveSats(text) catch {
            _ = self.message.set("Enter positive integer sats (no decimals).");
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
        if (index >= self.row_count) return false;
        const row = &self.rows[index];
        if (row.outgoing or row.id.len == 0 or row.mint.len == 0 or !std.mem.eql(u8, row.mint.slice(), self.mint.slice())) {
            _ = self.message.set("Saved invoice opening is available only for this mint's deposits.");
            return false;
        }
        if (!self.enqueue(.saved_invoice, row.id.slice())) return false;
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
    pub fn changePage(self: *Model, delta: i32, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (!self.available) return;
        if (delta < 0 and self.desired_offset >= 8) self.desired_offset -= 8;
        if (delta > 0 and @as(u64, self.desired_offset) + 8 < self.total_rows) self.desired_offset += 8;
        self.history_dirty = true;
    }
    pub fn fail(self: *Model, serial: u32, now: f64) void {
        if (!self.pending or serial != self.serial) return;
        self.pending = false;
        switch (self.operation) {
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
        self.publishQueued();
    }
    fn deliver(self: *Model, value: std.json.Value, now: f64) !void {
        if (value != .object) return error.Invalid;
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
                const sats = string(value, "sats") orelse return error.Invalid;
                _ = try decimal(sats);
                const recovery = try recoveryState(value);
                if (value.object.get("recovery_pending")) |pending| {
                    if (pending != .bool) return error.Invalid;
                    self.recovery_pending = pending.bool;
                }
                if (mint.len > 256) return error.Invalid;
                var buf: [100]u8 = undefined;
                _ = self.balance.set(try std.fmt.bufPrint(&buf, "{s} sat", .{sats}));
                _ = self.mint.set(mint);
                self.setRecovery(recovery, now);
                self.available = true;
                if (self.operation == .open) self.resume_needed = true;
                if (self.issued) _ = self.message.set("Deposit minted. Balance reread from wallet.") else if (self.invoice.len == 0) _ = self.message.set("Experimental test funds only.");
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
                if (status == .none) _ = self.message.set("Deposit recovery checked; new creation is available.");
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
    fn recoveryMessage(self: *Model) void {
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
        for (rows.array.items, 0..) |entry, index| {
            if (entry != .object) return error.Invalid;
            const direction = string(entry, "direction") orelse return error.Invalid;
            if (!std.mem.eql(u8, direction, "In") and !std.mem.eql(u8, direction, "Out")) return error.Invalid;
            rendered[index].outgoing = std.mem.eql(u8, direction, "Out");
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
            const line = std.fmt.bufPrint(&buf, "{s} | {s} {s} | {s}\n{s}{s}", .{ time, string(entry, "amount") orelse "?", string(entry, "unit") orelse "?", string(entry, "state") orelse "?", mint, if (!std.mem.eql(u8, mint, self.mint.slice())) " (not refreshed)" else "" }) catch "Quote details exceed display limit; retained in wallet";
            _ = rendered[index].text.set(line);
        }
        self.rows = rendered;
        self.row_count = rows.array.items.len;
        self.total_rows = @intCast(total);
        self.page = @intCast(offset / 8);
        if (self.desired_offset == self.pending_offset) self.desired_offset = @intCast(offset) else self.history_dirty = true;
        self.history_error = false;
    }
};
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
pub fn positiveSats(text: []const u8) !u64 {
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

const screen = "{\"mint_url\":\"https://testnut.cashu.space\",\"sats\":\"0\",\"creation_recovery\":\"none\",\"recovery_pending\":false}";
const unpaid = "{\"id\":\"saved\",\"invoice\":\"lnbc210n1test\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"UNPAID\",\"confirmed\":false,\"expired\":false}";
const update_error = "\"error\":{\"status\":7,\"message\":\"saved quote unavailable\"},\"invoice\":null,\"creation_recovery\":\"none\",\"recovery_pending\":false";

test "application poll errors advance selected cursors and preserve global recovery cursor" {
    var model = Model{ .started = true, .available = true, .history_active = true, .history_dirty = false };
    _ = model.mint.set("https://testnut.cashu.space");
    _ = model.balance.set("0 sat");
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
        _ = model.balance.set("7 sat");
        try std.testing.expect(model.enqueue(.saved_invoice, "saved"));
        model.request = null;
        model.accept(model.serial, unpaid, 0, std.testing.allocator);
        try std.testing.expect(model.enqueue(op, "saved"));
        model.request = null;
        model.accept(model.serial, "{\"wallet_changed\":true,\"recovery_pending\":false,\"creation_recovery\":\"none\",\"cursor\":\"saved\",\"error\":null,\"invoice\":" ++ remote_issued ++ "}", 1, std.testing.allocator);
        try std.testing.expect(model.balance_dirty and model.history_dirty and !model.issued);
        try std.testing.expectEqualStrings("7 sat", model.balance.slice());
        try std.testing.expectEqualStrings("ISSUED", model.quote_state.slice());
        try std.testing.expect(std.mem.indexOf(u8, model.message.slice(), "local issuance unconfirmed") != null);
        model.tick(true, 1);
        try std.testing.expect(model.pending and model.operation == .snapshot);
        model.request = null;
        model.accept(model.serial, screen, 1, std.testing.allocator);
        try std.testing.expectEqualStrings("0 sat", model.balance.slice());
        try std.testing.expect(!model.issued);
        model.tick(true, 1);
        try std.testing.expect(model.pending and model.operation == .history);
        model.request = null;
        model.accept(model.serial, "{\"offset\":\"0\",\"total\":\"1\",\"limit\":8,\"rows\":[{\"direction\":\"In\",\"id\":\"saved\",\"mint_url\":\"https://testnut.cashu.space\",\"state\":\"ISSUED\",\"unit\":\"sat\"}]}", 1, std.testing.allocator);
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
        _ = model.balance.set("7 sat");
        _ = model.rows[0].id.set("saved");
        _ = model.rows[0].mint.set(model.mint.slice());
        try std.testing.expect(model.enqueue(op, "A"));
        const serial = model.serial;
        try std.testing.expect(model.openRow(0));
        try std.testing.expect(model.selection_loading and !model.canCopyInvoice() and model.invoice.len == 0);
        model.request = null;
        model.accept(serial, "{\"wallet_changed\":true,\"recovery_pending\":true,\"creation_recovery\":\"none\",\"invoice\":null,\"cursor\":null,\"error\":{\"status\":7,\"message\":\"failed after partial recovery\"}}", 1, std.testing.allocator);
        try std.testing.expect(model.balance_dirty and model.history_dirty and model.recover_needed);
        try std.testing.expectEqualStrings("7 sat", model.balance.slice());
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
    model.tick(true, 0);
    model.accept(model.serial, "{\"mint_url\":\"https://testnut.cashu.space\",\"sats\":\"0\",\"creation_recovery\":\"none\",\"recovery_pending\":true}", 0, std.testing.allocator);
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
    model.accept(model.serial, "{\"mint_url\":\"https://testnut.cashu.space\",\"sats\":\"21\",\"creation_recovery\":\"none\",\"recovery_pending\":true}", 2, std.testing.allocator);
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
test "decimal sats checked at UI boundary" {
    for ([_][]const u8{ "", "0", "-1", "+1", "1.1", "1e3", " 1", "18446744073709551616", "9223372036854775808" }) |bad| try std.testing.expectError(error.InvalidAmount, positiveSats(bad));
    try std.testing.expectEqual(@as(u64, 42), try positiveSats("42"));
}
test "unchanged unpaid checks do not request balance or history; issued rereads actual balance" {
    var model = Model{};
    model.tick(true, 0);
    model.accept(model.serial, screen, 0, std.testing.allocator);
    model.resume_needed = false;
    _ = model.enqueue(.create, "21");
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
    try std.testing.expectEqualStrings("0 sat", model.balance.slice());
    model.tick(true, 20);
    try std.testing.expect(model.operation == .snapshot);
    model.accept(model.serial, "{\"mint_url\":\"https://testnut.cashu.space\",\"sats\":\"19\",\"creation_recovery\":\"none\"}", 20, std.testing.allocator);
    try std.testing.expectEqualStrings("19 sat", model.balance.slice());
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
    model.changePage(1, std.testing.allocator);
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
    try std.testing.expectEqual(@as(usize, 0), model.page);
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
    _ = model.enqueue(.create, "21");
    model.accept(model.serial, unpaid, 0, std.testing.allocator);
    model.recover_needed = false;
    for ([_]Operation{ .history, .resume_saved, .recover, .snapshot, .check, .poll }) |op| {
        try std.testing.expect(model.enqueue(op, if (op == .history) "0" else ""));
        model.fail(model.serial, 0);
        try std.testing.expect(model.available);
        try std.testing.expectEqualStrings("saved", model.quote_id.slice());
        try std.testing.expectEqualStrings("0 sat", model.balance.slice());
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
    _ = model.enqueue(.create, "21");
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
    model.accept(model.serial, "{\"offset\":\"0\",\"total\":\"1\",\"limit\":8,\"rows\":[{\"id\":\"saved\",\"direction\":\"Out\",\"amount\":\"42\",\"unit\":\"sat\",\"state\":\"UNPAID\",\"created_at\":null,\"mint_url\":null}]}", 0, std.testing.allocator);
    try std.testing.expect(model.rows[0].outgoing and model.row_count == 1);
    try std.testing.expect(std.mem.indexOf(u8, model.rows[0].text.slice(), "Time unknown | 42 sat | UNPAID") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.rows[0].text.slice(), "Mint unknown (not refreshed)") != null);
    var time: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01 00:00 UTC", formatTime("0", &time));
    try std.testing.expect(!model.openRow(1));
    try std.testing.expect(!model.openRow(0));
    try std.testing.expect(!model.pending);
}

test "expired invoice is marked and only background sweeps run" {
    var model = Model{};
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
    model.tick(true, 0);
    model.accept(model.serial, screen, 0, std.testing.allocator);
    model.resume_needed = false;
    try std.testing.expect(model.create("21"));
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
    try std.testing.expect(!model.create("21"));
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
    try std.testing.expect(model.create("21"));
    try std.testing.expectEqualStrings("Creating saved invoice...", model.message.slice());
    try std.testing.expect(!model.create("42"));
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
    try std.testing.expectEqualStrings("21", model.request.?.argument.slice());
    try std.testing.expect(!model.create("100"));
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
    model.changePage(1, std.testing.allocator);
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
    try std.testing.expect(model.create("21"));
    model.fail(model.serial, 0);
    try std.testing.expect(!model.pending and model.queued != null);
    model.tick(true, 0);
    try std.testing.expectEqualDeep(request, model.request.?);
    try std.testing.expect(!model.create("42"));
    model.request = null;
    model.tick(true, 0);
    try std.testing.expect(model.pending and model.queued == null and model.operation == .create);
}

test "unknown startup and cleanup outcomes retry local recovery on bounded deadlines" {
    for ([_][]const u8{ "unknown", "legacy_unknown" }) |status| {
        var model = Model{};
        model.tick(true, 0);
        var buf: [256]u8 = undefined;
        const snapshot = try std.fmt.bufPrint(&buf, "{{\"mint_url\":\"https://testnut.cashu.space\",\"sats\":\"0\",\"creation_recovery\":\"{s}\"}}", .{status});
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
            try std.testing.expect(!model.create("21"));
            now = deadline;
        }
        try std.testing.expectEqual(@as(f64, 30), model.next_recover - now);
        if (std.mem.eql(u8, status, "legacy_unknown")) continue;
        // Cleanup failure can return a usable invoice together with unknown.
        model.tick(true, model.next_recover);
        model.accept(model.serial, "{\"creation_recovery\":\"unknown\",\"invoice\":" ++ unpaid ++ "}", now + 30, std.testing.allocator);
        try std.testing.expectEqualStrings("saved", model.quote_id.slice());
        try std.testing.expect(model.invoice.len != 0 and !model.create("21"));
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
    _ = model.balance.set("7 sat");
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
    try std.testing.expect(!model.create("21"));
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
    try std.testing.expectEqualStrings("7 sat", model.balance.slice());
    try std.testing.expect(!model.pending and model.queued == null);
    model.tick(true, deadline);
    try std.testing.expect(model.operation == .snapshot); // Reread, never increment or create.
}

const history_row = "{\"id\":\"saved\",\"direction\":\"In\",\"mint_url\":\"https://testnut.cashu.space\",\"amount\":\"21\",\"unit\":\"sat\",\"state\":\"UNPAID\"}";
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

test "history activation refuses outgoing other-mint and unknown-owner id collisions" {
    var model = Model{ .available = true, .row_count = 1 };
    _ = model.mint.set("https://testnut.cashu.space");
    _ = model.invoice.set("old-invoice");
    _ = model.rows[0].id.set("saved");
    _ = model.rows[0].mint.set(model.mint.slice());
    model.rows[0].outgoing = true;
    try std.testing.expect(!model.openRow(0));
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
    model.changePage(1, std.testing.allocator);
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
