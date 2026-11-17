//! One native worker owns the handle from open through close. Mailbox capacity
//! is one: request/result publication uses release/acquire, never detached work.
const std = @import("std");
const wallet = @import("wallet.zig");
const ui = @import("wallet_ui.zig");
pub const Worker = struct {
    paths: wallet.Paths,
    state: std.atomic.Value(enum(u8) { idle, request, result }) = .init(.idle),
    stopping: std.atomic.Value(bool) = .init(false),
    request: ui.Request = undefined,
    result: ui.Text(128 * 1024) = .{},
    ok: bool = false,
    thread: std.Thread = undefined,

    pub fn start(paths: wallet.Paths) !*Worker {
        const self = try std.heap.page_allocator.create(Worker);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{ .paths = paths };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn stop(self: *Worker) void {
        self.stopping.store(true, .release);
        self.thread.join();
        std.heap.page_allocator.destroy(self);
    }
    pub fn step(self: *Worker, model: *ui.Model, now: f64) void {
        if (self.state.load(.acquire) == .result) {
            if (self.ok) model.accept(self.request.serial, self.result.slice(), now, std.heap.page_allocator) else model.fail(self.request.serial, now);
            self.state.store(.idle, .release);
        }
        if (self.state.load(.acquire) == .idle) if (model.request) |request| {
            self.request = request;
            model.request = null;
            self.state.store(.request, .release);
        };
    }
    fn run(self: *Worker) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const io = threaded.io();
        var owner: ?wallet.Wallet = null;
        defer if (owner) |*h| h.close() catch {};
        while (!self.stopping.load(.acquire)) {
            if (self.state.load(.acquire) != .request) {
                // ponytail: one sleeping worker, not a new thread per poll.
                io.sleep(.fromMilliseconds(20), .awake) catch {};
                continue;
            }
            self.ok = false;
            self.execute(io, &owner) catch {};
            self.state.store(.result, .release);
        }
    }
    fn execute(self: *Worker, io: std.Io, owner: *?wallet.Wallet) !void {
        const allocator = std.heap.page_allocator;
        if (self.request.operation == .open) {
            if (owner.* != null) return error.AlreadyOpen;
            const inspection = try wallet.inspect(io, allocator, self.paths, true);
            owner.* = inspection.wallet orelse return error.Unavailable;
        }
        const handle = if (owner.*) |*w| try w.borrowHandle() else return error.Unavailable;
        if (self.request.operation == .create) {
            var added = wallet.cdk.c.cdk_wallet_add_mint(handle, wallet.cdk.app_mint.ptr);
            try wallet.check(&added);
        }
        const operation: [:0]const u8 = switch (self.request.operation) {
            .open, .snapshot => "wallet_screen",
            .create => "create_deposit",
            .check, .recover, .poll => "deposit_update",
            .saved_invoice => "saved_invoice",
            .history => "quote_history_page",
            .resume_saved => "resume_deposit",
            .prepare_withdrawal => "prepare_withdrawal",
            .confirm_withdrawal => "confirm_withdrawal",
            .cancel_withdrawal => "cancel_withdrawal",
            .saved_withdrawal => "saved_withdrawal",
            .poll_withdrawals => "poll_withdrawals",
        };
        const args = if (self.request.operation == .check or self.request.operation == .poll or self.request.operation == .recover)
            try std.json.Stringify.valueAlloc(allocator, .{ wallet.cdk.app_mint, @tagName(self.request.operation), self.request.argument.slice() }, .{})
        else if (self.request.operation == .history)
            try std.json.Stringify.valueAlloc(allocator, .{self.request.argument.slice()}, .{})
        else if (self.request.operation == .open or self.request.operation == .snapshot or self.request.operation == .resume_saved)
            try std.json.Stringify.valueAlloc(allocator, .{wallet.cdk.app_mint}, .{})
        else
            try std.json.Stringify.valueAlloc(allocator, .{ wallet.cdk.app_mint, self.request.argument.slice() }, .{});
        defer allocator.free(args);
        const args_z = try allocator.dupeSentinel(u8, args, 0);
        defer allocator.free(args_z);
        var result = wallet.cdk.c.cdk_wallet_quotes(handle, operation.ptr, args_z.ptr);
        defer wallet.cdk.c.cdk_string_free(result.value);
        if (self.request.operation.isWithdrawal() and result.status >= 1 and result.status <= 27) {
            // check consumes only the Rust-owned error; the payload is freed by the defer above.
            wallet.check(&result) catch {};
            var buf: [256]u8 = undefined;
            self.ok = self.result.set(try std.fmt.bufPrint(&buf, "{{\"operation_error\":{{\"status\":{d},\"message\":\"Withdrawal request failed\"}}}}", .{result.status}));
            return;
        }
        try wallet.check(&result);
        const value = result.value orelse return error.Unavailable;
        self.ok = self.result.set(std.mem.span(@as([*:0]const u8, @ptrCast(value))));
    }
};
