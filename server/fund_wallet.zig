const std = @import("std");
const storage = @import("native_storage");
const Qr = storage.qr.Qr;
const Shutdown = @import("shutdown.zig").Shutdown;
const cdk = storage.wallet.cdk;
const c = cdk.c;

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const amount = try parseAmount(args);
    var amount_buf: [20]u8 = undefined;
    const amount_text = try std.fmt.bufPrint(&amount_buf, "{d}", .{amount});
    const locations = try storage.paths.resolveCurrentIdentity(init.gpa, .server);
    defer locations.deinit(init.gpa);
    try verifyWalletDir(init.io, locations.config_dir);
    var lock = try storage.instance_lock.acquire(init.io, locations.config_dir);
    defer lock.release(init.io);
    try verifyWalletDir(init.io, std.fs.path.dirname(locations.wallet_dir) orelse return error.InvalidPath);

    const paths = try storage.wallet.Paths.init(init.gpa, locations.wallet_dir);
    defer paths.deinit(init.gpa);
    var inspection = try storage.wallet.inspect(init.io, init.gpa, paths, true);
    defer inspection.close() catch {};
    const owner = if (inspection.wallet) |*w| w else return switch (inspection.state) {
        .not_initialized => error.WalletNotFound,
        .incomplete => error.IncompleteWallet,
        .ready => error.WalletNotReady,
    };
    const handle = try owner.borrowHandle();

    var shutdown = try Shutdown.install();
    defer shutdown.restore();
    // Production builds use Testnut; the existing build-time loopback fixture
    // is the only override. There is no runtime mint selector.
    try cdk.requireAppMint();
    var approval = c.cdk_wallet_add_mint(handle, cdk.app_mint.ptr);
    try storage.wallet.check(&approval);
    if (shutdown.isRequested()) return error.FundingInterrupted;

    const created = try quoteCall(init.gpa, handle, "create_deposit", amount_text);
    defer created.deinit();
    const quote = created.value;
    try quote.validate(amount_text);
    var confirmed = false;
    errdefer if (!confirmed) std.log.err("funding not confirmed for quote {s}; saved wallet state retained", .{quote.id});
    if (shutdown.isRequested()) return error.FundingInterrupted;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout.interface;
    try out.print("{s} — TEST FUNDS ONLY\nAmount: {d} msats\nQuote: {s}\n", .{ cdk.app_mint, amount, quote.id });
    try out.flush();
    switch (try quote.outcome()) {
        .issued => {},
        .waiting => {
            if (std.mem.eql(u8, quote.state, "UNPAID")) {
                try out.print("BOLT11: {s}\n\n", .{quote.invoice});
                const invoice = try init.gpa.dupeSentinel(u8, quote.invoice, 0);
                defer init.gpa.free(invoice);
                var qr = Qr{};
                if (qr.encode(invoice)) {
                    try printQr(out, &qr);
                } else {
                    try out.writeAll("QR unavailable; use the BOLT11 invoice above.\n");
                }
            }
            try out.writeAll("Waiting for local issuance (Ctrl-C to stop)...\n");
            try out.flush();
            try watch(init, handle, quote.id, amount_text, &shutdown);
        },
    }
    confirmed = true;
    try out.print("Issued: {d} msats credited to the server wallet.\n", .{amount});
    try out.flush();
}

fn verifyWalletDir(io: std.Io, path: []const u8) !void {
    storage.storage_fs.verifyOwnedDir(io, path) catch |err| switch (err) {
        error.FileNotFound => return error.WalletNotFound,
        else => return err,
    };
}

fn parseAmount(args: []const []const u8) !u64 {
    if (args.len != 1 or args[0].len == 0 or args[0].len > 20) return error.InvalidAmount;
    for (args[0]) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidAmount;
    const amount = std.fmt.parseInt(u64, args[0], 10) catch return error.InvalidAmount;
    if (amount == 0 or amount > std.math.maxInt(i64)) return error.InvalidAmount;
    return amount;
}

const Quote = struct {
    id: []const u8,
    mint_url: []const u8,
    invoice: []const u8,
    amount: ?[]const u8,
    unit: []const u8,
    state: []const u8,
    confirmed: bool,
    expired: bool,

    fn validate(self: Quote, amount: []const u8) !void {
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, self.mint_url, "/"), std.mem.trimEnd(u8, cdk.app_mint, "/")) or
            !std.mem.eql(u8, self.unit, "msat") or !std.mem.eql(u8, self.amount orelse "", amount))
            return error.QuoteDoesNotMatchRequestedFunding;
        if (!displayable(self.id) or !displayable(self.invoice)) return error.InvalidQuote;
    }

    fn displayable(text: []const u8) bool {
        if (text.len == 0) return false;
        for (text) |ch| if (!std.ascii.isPrint(ch)) return false;
        return true;
    }

    fn outcome(self: Quote) !enum { waiting, issued } {
        if (std.mem.eql(u8, self.state, "ISSUED")) {
            if (self.confirmed) return .issued;
            return error.IssuanceNotConfirmedLocally;
        }
        if (self.expired) return error.QuoteExpired;
        if (std.mem.eql(u8, self.state, "UNPAID") or std.mem.eql(u8, self.state, "PAID")) return .waiting;
        return error.InvalidQuoteState;
    }
};

fn quoteCall(allocator: std.mem.Allocator, handle: *c.CdkWallet_t, operation: [:0]const u8, argument: []const u8) !std.json.Parsed(Quote) {
    const json = try std.json.Stringify.valueAlloc(allocator, .{ cdk.app_mint, argument }, .{});
    defer allocator.free(json);
    const args = try allocator.dupeSentinel(u8, json, 0);
    defer allocator.free(args);
    var result = c.cdk_wallet_quotes(handle, operation.ptr, args.ptr);
    defer c.cdk_string_free(result.value);
    storage.wallet.check(&result) catch switch (result.status) {
        c.CDK_STATUS_NETWORK_ERROR, c.CDK_STATUS_RECOVERY_PENDING => return error.QuoteRecoveryPending,
        else => {
            std.log.err("{s} failed (CDK status {d})", .{ operation, result.status });
            return error.CdkFailure;
        },
    };
    return std.json.parseFromSlice(Quote, allocator, std.mem.span(result.value orelse return error.InvalidQuote), .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

fn watch(init: std.process.Init, handle: *c.CdkWallet_t, id: []const u8, amount: []const u8, shutdown: *const Shutdown) !void {
    var failures: u8 = 0;
    while (!shutdown.isRequested()) {
        const checked = quoteCall(init.gpa, handle, "check_deposit", id) catch |err| {
            if (shutdown.isRequested()) return error.FundingInterrupted;
            if (err != error.QuoteRecoveryPending) return err;
            failures += 1;
            if (failures == 3) return err;
            try init.io.sleep(.fromSeconds(2), .awake);
            continue;
        };
        defer checked.deinit();
        failures = 0;
        try checked.value.validate(amount);
        if (!std.mem.eql(u8, checked.value.id, id)) return error.InvalidQuote;
        if (try checked.value.outcome() == .issued) return;
        if (!shutdown.isRequested()) try init.io.sleep(.fromSeconds(2), .awake);
    }
    return error.FundingInterrupted;
}

fn printQr(out: *std.Io.Writer, qr: *const Qr) !void {
    // One column per module, two modules per row. Explicit colors preserve the
    // four-module white quiet zone on both light and dark terminals.
    const colors = [_][]const u8{ "\x1b[97;107m ", "\x1b[30;107m▀", "\x1b[30;107m▄", "\x1b[30;40m " };
    const end = @as(c_int, qr.size()) + 4;
    var y: c_int = -4;
    while (y < end) : (y += 2) {
        var x: c_int = -4;
        while (x < end) : (x += 1) {
            const top: usize = @intFromBool(qr.dark(x, y));
            const bottom: usize = @intFromBool(qr.dark(x, y + 1));
            try out.writeAll(colors[top + 2 * bottom]);
        }
        try out.writeAll("\x1b[0m\n");
    }
}

test "fund-wallet accepts exactly one positive decimal msat amount" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 21), try parseAmount(&.{"00021"}));
    try t.expectError(error.InvalidAmount, parseAmount(&.{}));
    try t.expectError(error.InvalidAmount, parseAmount(&.{ "21", "sat" }));
    for ([_][]const u8{ "", "0", "-21", "+21", "2_1", "21msats", "2.1", "9223372036854775808" }) |bad| {
        try t.expectError(error.InvalidAmount, parseAmount(&.{bad}));
    }
}

test "fund-wallet requires locally confirmed issuance" {
    const t = std.testing;
    var quote: Quote = .{
        .id = "quote-id",
        .mint_url = cdk.app_mint,
        .invoice = "lnfake",
        .amount = "21",
        .unit = "msat",
        .state = "PAID",
        .confirmed = false,
        .expired = false,
    };
    try quote.validate("21");
    try t.expectError(error.QuoteDoesNotMatchRequestedFunding, quote.validate("22"));
    try t.expect(try quote.outcome() == .waiting);
    quote.expired = true;
    try t.expectError(error.QuoteExpired, quote.outcome());
    quote.state = "ISSUED";
    try t.expectError(error.IssuanceNotConfirmedLocally, quote.outcome());
    quote.confirmed = true;
    try t.expect(try quote.outcome() == .issued);
}
