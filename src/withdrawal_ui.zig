//! Ephemeral presentation only. CDK owns reservations, payments and recovery.
const std = @import("std");
const Text = @import("wallet_ui.zig").Text;
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
        if (!std.mem.eql(u8, try string(value, "mint_url"), mint) or !std.mem.eql(u8, try string(value, "unit"), "sat")) return error.Invalid;
        try put(&result.quote_id, try string(value, "quote_id"));
        try put(&result.invoice, try string(value, "invoice"));
        try number(&result.amount, try string(value, "amount"));
        try number(&result.quote_expiry, try string(value, "quote_expiry"));
        if (prepared) {
            try put(&result.operation_id, try string(value, "operation_id"));
            try number(&result.fee_reserve, try string(value, "fee_reserve"));
            try number(&result.swap_fee, try string(value, "swap_fee"));
            try number(&result.input_fee, try string(value, "input_fee"));
            try number(&result.estimated_total, try string(value, "estimated_total"));
            try number(&result.invoice_expiry, try string(value, "invoice_expiry"));
            _ = try boolean(value, "requires_swap");
            result.status = .prepared;
        } else {
            try put(&result.quote_state, try string(value, "quote_state"));
            result.status = std.meta.stringToEnum(Status, try string(value, "payment_status")) orelse return error.Invalid;
            result.expired = try boolean(value, "expired");
            result.retry_review_allowed = try boolean(value, "retry_review_allowed");
            const expiry = value.object.get("invoice_expiry") orelse return error.Invalid;
            if (expiry != .null) try number(&result.invoice_expiry, try string(value, "invoice_expiry"));
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
pub fn string(value: std.json.Value, key: []const u8) ![]const u8 {
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
