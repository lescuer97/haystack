//! One native worker owns the handle from open through close. Mailbox capacity
//! is one: request/result publication uses release/acquire, never detached work.
const std = @import("std");
const wallet = @import("wallet.zig");
const ui = @import("wallet_ui.zig");
const onboarding = @import("onboarding.zig");
const native_onboarding = @import("onboarding_native.zig");
pub const NativeOperation = enum { start, create, restore, retry, complete, generate, finish_restore, retry_open };
pub const Worker = struct {
    paths: wallet.Paths,
    native: ?native_onboarding.Native = null,
    state: std.atomic.Value(enum(u8) { idle, request, result }) = .init(.idle),
    stopping: std.atomic.Value(bool) = .init(false),
    kind: enum { wallet, onboarding } = .wallet,
    request: ui.Request = undefined,
    result: ui.Text(128 * 1024) = .{},
    operation: NativeOperation = .start,
    attempt_id: u64 = 0,
    phrase: ?[]u8 = null,
    event: onboarding.Event = .blocked,
    fail_open: std.atomic.Value(bool) = .init(false),
    ok: bool = false,
    thread: std.Thread = undefined,

    pub fn start(paths: wallet.Paths) !*Worker {
        const self = try std.heap.page_allocator.create(Worker);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{ .paths = paths };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn startNative(native: native_onboarding.Native) !*Worker {
        const self = try std.heap.page_allocator.create(Worker);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{ .paths = native.paths, .native = native, .kind = .onboarding, .operation = .start };
        self.state.store(.request, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn stop(self: *Worker) void {
        self.stopping.store(true, .release);
        self.thread.join();
        self.clearPayload();
        std.heap.page_allocator.destroy(self);
    }
    fn clearPayload(self: *Worker) void {
        if (self.phrase) |phrase| {
            std.crypto.secureZero(u8, phrase);
            std.heap.page_allocator.free(phrase);
            self.phrase = null;
        }
        if (self.kind == .onboarding and self.state.load(.acquire) == .result and self.event == .backup) {
            std.crypto.secureZero(u8, self.event.backup);
            std.heap.page_allocator.free(self.event.backup);
            self.event = .blocked;
        }
    }
    /// Capture the phrase on the input thread, before the next queued input.
    pub fn submit(self: *Worker, operation: NativeOperation, model: *const onboarding.Onboarding) !void {
        if (self.state.load(.acquire) != .idle) return error.Busy;
        const phrase = if (operation == .restore) try std.heap.page_allocator.dupe(u8, model.recoveryPhrase()) else null;
        self.kind = .onboarding;
        self.operation = operation;
        self.attempt_id = model.attempt_id;
        self.phrase = phrase;
        self.state.store(.request, .release);
    }
    pub fn stepOnboarding(self: *Worker, model: *onboarding.Onboarding) bool {
        if (self.state.load(.acquire) != .result or self.kind != .onboarding) return false;
        const before = model.phase;
        if (self.event == .backup) {
            if (model.allocator.dupe(u8, self.event.backup)) |copy| model.receive(.{ .backup = copy }) else |_| model.receive(.blocked);
        } else model.receive(self.event);
        self.clearPayload();
        self.state.store(.idle, .release);
        return before != model.phase;
    }
    /// Reports accepted delivery, not idle polls or stale results. The loop
    /// invalidates input captured against the old actionable wallet content.
    pub fn step(self: *Worker, model: *ui.Model, now: f64) bool {
        var accepted = false;
        if (self.state.load(.acquire) == .result and self.kind == .wallet) {
            accepted = model.pending and self.request.serial == model.serial;
            if (self.ok) model.accept(self.request.serial, self.result.slice(), now, std.heap.page_allocator) else model.fail(self.request.serial, now);
            self.state.store(.idle, .release);
        }
        if (self.state.load(.acquire) == .idle) if (model.request) |request| {
            self.kind = .wallet;
            self.request = request;
            model.request = null;
            self.state.store(.request, .release);
        };
        return accepted;
    }
    fn run(self: *Worker) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const io = threaded.io();
        var owner: ?wallet.Wallet = null;
        defer if (owner) |*h| h.close() catch {};
        while (true) {
            if (self.state.load(.acquire) != .request) {
                if (self.stopping.load(.acquire)) break;
                // ponytail: one sleeping worker, not a new thread per poll.
                io.sleep(.fromMilliseconds(20), .awake) catch {};
                continue;
            }
            if (self.kind == .onboarding) {
                var native = self.native.?;
                native.io = io;
                native.allocator = std.heap.page_allocator;
                self.event = self.executeOnboarding(&native, &owner) catch |err| if (err == error.InvalidMnemonic)
                    .{ .invalid_phrase = self.attempt_id }
                else if (self.operation == .complete or self.operation == .finish_restore)
                    .complete_fail
                else
                    .blocked;
                if (self.phrase) |phrase| {
                    std.crypto.secureZero(u8, phrase);
                    std.heap.page_allocator.free(phrase);
                    self.phrase = null;
                }
            } else {
                self.ok = false;
                self.execute(io, &owner) catch {};
            }
            self.state.store(.result, .release);
        }
    }
    fn openOwner(self: *Worker, io: std.Io, owner: *?wallet.Wallet) !void {
        if (self.fail_open.load(.acquire)) return error.Unavailable;
        const inspection = try wallet.inspect(io, std.heap.page_allocator, self.paths, true);
        owner.* = inspection.wallet orelse return error.Unavailable;
    }
    fn executeOnboarding(self: *Worker, native: *native_onboarding.Native, owner: *?wallet.Wallet) !onboarding.Event {
        const event: onboarding.Event = switch (self.operation) {
            .start => try native.start(),
            .create => try native.createNew(),
            .restore => try native.restore(self.phrase.?, self.attempt_id),
            .retry => try native.retry(self.attempt_id),
            .generate => try native.generateNew(),
            .complete => blk: {
                try native.complete();
                break :blk .complete_success;
            },
            .finish_restore => blk: {
                try native.finishRestore();
                break :blk .complete_success;
            },
            .retry_open => .open_success,
        };
        if (event == .ready or event == .complete_success or event == .open_success) {
            self.openOwner(native.io, owner) catch return .open_failed;
        }
        return event;
    }
    fn execute(self: *Worker, io: std.Io, owner: *?wallet.Wallet) !void {
        const allocator = std.heap.page_allocator;
        if (self.request.operation == .open) {
            if (owner.* == null) try self.openOwner(io, owner);
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

test "delivery reports accepted results only, not idle polls or stale serials" {
    var worker = Worker{ .paths = undefined, .thread = undefined, .request = .{ .operation = .open, .serial = 1 } };
    var model = ui.Model{ .serial = 2, .pending = true };
    try std.testing.expect(!worker.step(&model, 0));
    worker.state.store(.result, .release);
    try std.testing.expect(!worker.step(&model, 0));
    try std.testing.expect(model.pending);
    worker.request.serial = 2;
    worker.state.store(.result, .release);
    try std.testing.expect(worker.step(&model, 0));
    try std.testing.expect(!model.pending);
    try std.testing.expect(!worker.step(&model, 0));
}

test "restore command captures phrase immediately and rejects busy mailbox" {
    var worker = Worker{ .paths = undefined };
    var model = onboarding.Onboarding.init(std.testing.allocator);
    defer model.deinit();
    model.receive(.{ .choice = .{ .recover_enabled = true } });
    _ = model.activateAction(.enter_recovery);
    model.receive(.{ .paste = try std.testing.allocator.dupe(u8, "first phrase") });
    _ = model.activateAction(.restore_phrase);
    try worker.submit(.restore, &model);
    try std.testing.expectEqualStrings("first phrase", worker.phrase.?);
    try std.testing.expectError(error.Busy, worker.submit(.retry, &model));
    model.phrase[0] = 'X';
    try std.testing.expectEqualStrings("first phrase", worker.phrase.?);
    worker.clearPayload();
}
