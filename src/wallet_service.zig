//! Native wallet owners. Desktop uses a one-slot mailbox on its existing worker;
//! headless callers serialize synchronous operations on a single owned wallet.
const std = @import("std");
const wallet = @import("wallet.zig");
const ui = @import("wallet_ui.zig");
const commands = @import("wallet_commands.zig");
const sf = @import("storage_fs.zig");
const Locations = @import("paths.zig").Locations;
const receiver = @import("wallet_receiver.zig");
const protocol = @import("shared").protocol;
const cdk = wallet.cdk;

pub const LiveHoeChannel = receiver.LiveChannel;

/// Keep the instance lock and Paths alive through stop(). One game thread
/// owns mailbox submission and drains each accepted request's reply.
pub const Worker = struct {
    const Request = union(enum) { screen: ui.Request, hoe: commands.Request };

    paths: wallet.Paths,
    state: std.atomic.Value(enum(u8) { idle, request, result }) = .init(.idle),
    stopping: std.atomic.Value(bool) = .init(false),
    request: Request = undefined,
    hoe_result: commands.Result = undefined,
    result: commands.ScreenResult = .{},
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
    /// False means nothing queued. The caller that receives true owns the
    /// reply and must drain it, even if its transport session goes away.
    pub fn submitHoe(self: *Worker, request: commands.Request) bool {
        if (self.state.load(.acquire) != .idle) return false;
        self.request = .{ .hoe = request };
        self.state.store(.request, .release);
        return true;
    }

    /// Copies the result before releasing the shared slot. step() will not
    /// consume this result; always drain it, including after a disconnect.
    pub fn takeHoe(self: *Worker) ?commands.Result {
        if (self.state.load(.acquire) != .result or self.request != .hoe) return null;
        const completion = self.hoe_result;
        self.state.store(.idle, .release);
        return completion;
    }

    /// Reports accepted delivery, not idle polls or stale results. The loop
    /// invalidates input captured against the old actionable wallet content.
    pub fn step(self: *Worker, model: *ui.Model, now: f64) bool {
        var accepted = false;
        if (self.state.load(.acquire) == .result and self.request == .screen) {
            const serial = self.request.screen.serial;
            accepted = model.pending and serial == model.serial;
            if (self.ok) model.accept(serial, self.result.slice(), now, std.heap.page_allocator) else model.fail(serial, now);
            self.state.store(.idle, .release);
        }
        if (self.state.load(.acquire) == .idle) if (model.request) |request| {
            self.request = .{ .screen = request };
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
        var spilman: commands.State = .{};
        defer spilman.deinit(io);
        while (!self.stopping.load(.acquire)) {
            if (self.state.load(.acquire) != .request) {
                // ponytail: one sleeping worker, not a new thread per poll.
                io.sleep(.fromMilliseconds(20), .awake) catch {};
                continue;
            }
            switch (self.request) {
                .hoe => |request| self.hoe_result = spilman.execute(io, self.paths, &owner, request) catch |err| .{ .failed = err },
                .screen => |*request| self.ok = commands.executeScreen(io, self.paths, &owner, request, &self.result) catch false,
            }
            self.state.store(.result, .release);
        }
    }
};

test "delivery reports accepted results only, not idle polls or stale serials" {
    var worker = Worker{ .paths = undefined, .request = .{ .screen = .{ .operation = .open, .serial = 1 } } };
    var model = ui.Model{ .serial = 2, .pending = true };
    try std.testing.expect(!worker.step(&model, 0));
    worker.state.store(.result, .release);
    try std.testing.expect(!worker.step(&model, 0));
    try std.testing.expect(model.pending);
    worker.request.screen.serial = 2;
    worker.state.store(.result, .release);
    try std.testing.expect(worker.step(&model, 0));
    try std.testing.expect(!model.pending);
    try std.testing.expect(!worker.step(&model, 0));
}

test "wallet guard validates capacity for the selected tool before funding" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const wallet_path = try std.fmt.allocPrintSentinel(a, "{s}/wallet.sqlite", .{dir}, 0);
    const ledger_path = try std.fmt.allocPrintSentinel(a, "{s}/channels.sqlite", .{dir}, 0);
    var headless = try Headless.testing.openWithLedger(t.io, a, wallet_path, ledger_path);
    defer headless.close() catch unreachable;
    const guard = headless.tryAcquire().?;
    defer guard.release();
    const owner_hex = "034f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa";
    var owner: receiver.Pubkey = undefined;
    _ = try std.fmt.hexToBytes(&owner, owner_hex);
    const receiver_hex = std.fmt.bytesToHex(headless.receiverPubkey(3600).?, .lower);
    const now = headless.unixSeconds().?;
    for ([_]protocol.tool{ .axe, .hoe, .pickaxe }, [_]u64{ 2, 5, 10 }) |tool, price| {
        for ([_]u64{ price, price + 1 }) |capacity| {
            const params = try std.json.Stringify.valueAlloc(a, .{
                .capacity = capacity,
                .expiry_timestamp = now + 3600,
                .funding_token_amount = 64,
                .input_fee_ppk = 0,
                .keyset_id = "test",
                .maximum_amount = 64,
                .mint = "https://mint.example.com",
                .receiver_pubkey = receiver_hex[0..],
                .sender_pubkey = owner_hex,
                .setup_timestamp = now,
                .unit = "msat",
            }, .{});
            const request: receiver.Open = .{ .id = @splat(1), .params_json = params, .funding_proofs_json = "[]" };
            const expected = if (capacity == price) error.InvalidFundingProof else error.InvalidChannelParameters;
            try t.expectError(expected, guard.acceptToolFunded(owner, request, now, tool));
            if (tool == .hoe) try t.expectError(expected, guard.acceptFunded(owner, request, now));
            try t.expectEqual(null, try guard.lookup(owner, request.id, now));
        }
    }
    try t.expectError(error.ChannelNotFound, guard.closeChannel(owner, .{ .id = @splat(1) }, now));
}

const receiver_log = std.log.scoped(.hoe_channels);
pub const ChannelPhase = receiver.Phase;

/// Main holds the instance lock until close. Drain all request and settlement
/// tasks before closing this owner; do not copy it after opening.
pub const Headless = struct {
    io: std.Io,
    owner: wallet.Wallet,
    ledger: ?receiver.Ledger = null,
    mutex: std.Io.Mutex = .init,

    pub fn open(io: std.Io, allocator: std.mem.Allocator, locations: Locations, mode: ?Mode) !Headless {
        return openImpl(io, allocator, locations, mode, true);
    }

    fn openImpl(io: std.Io, allocator: std.mem.Allocator, locations: Locations, mode: ?Mode, comptime verify_mint: bool) !Headless {
        const mint: ?[:0]const u8 = if (mode != null) fixture_mint orelse return error.HoeRequiresFixtureMint else testnut_mint;
        const ledger_dir = if (mode != null) "hoe-fixture" else "hoe-testnut";
        const ledger_mode: ?Mode = if (mint != null) mode orelse try testnutMode(io, locations.wallet_dir, ledger_dir) else null;
        // Resuming a ledger must not provision a replacement wallet if it was lost.
        if (ledger_mode == .existing) try sf.verifyOwnedDir(io, locations.wallet_dir);
        if (verify_mint) try cdk.requireAppMint();
        var self: Headless = .{ .io = io, .owner = try openHeadlessWallet(io, allocator, locations) };
        errdefer self.close() catch {};
        if (mint) |selected| {
            const handle = try self.owner.borrowHandle();
            self.ledger = try openReceiver(io, allocator, locations.wallet_dir, ledger_dir, handle, selected, ledger_mode.?);
            // Keyset, proof and redemption calls require an approved mint. CDK treats
            // approval as a no-op on reopen. Only approve the selected test mint.
            if (verify_mint) {
                var approval = cdk.c.cdk_wallet_add_mint(handle, selected.ptr);
                wallet.check(&approval) catch return if (mode != null) error.HoeFixtureMintRegistrationFailed else error.HoeTestnutMintRegistrationFailed;
            }
        }
        return self;
    }

    pub const testing = if (@import("builtin").is_test) struct {
        pub fn openOffline(io: std.Io, allocator: std.mem.Allocator, locations: Locations, mode: ?Mode) !Headless {
            return openImpl(io, allocator, locations, mode, false);
        }

        pub fn openWithLedger(io: std.Io, allocator: std.mem.Allocator, wallet_path: [:0]const u8, ledger_path: [:0]const u8) !Headless {
            const seed: [cdk.seed_len]u8 = @splat(0x42);
            var self: Headless = .{ .io = io, .owner = try wallet.createWallet(&seed, wallet_path) };
            errdefer self.close() catch {};
            self.ledger = try receiver.Ledger.open(allocator, ledger_path, .create, try self.owner.borrowHandle(), "https://mint.example.com", @splat(0x22), .{ .max_lifetime_seconds = week_seconds });
            return self;
        }
    } else struct {};

    pub fn close(self: *Headless) !void {
        if (self.ledger) |*ledger| ledger.close();
        self.ledger = null;
        try self.owner.close();
    }

    pub fn hasReceiver(self: *const Headless) bool {
        return self.ledger != null;
    }

    /// Immutable quote data: reading it does not contend with mint I/O.
    pub fn receiverPubkey(self: *const Headless, lifetime_seconds: u64) ?receiver.Pubkey {
        const ledger = if (self.ledger) |*ledger| ledger else return null;
        return if (ledger.limits.max_lifetime_seconds >= lifetime_seconds) ledger.receiver_pubkey else null;
    }

    /// Hold across the associated profile link or prepared world mutation.
    /// This is the same lock used by settlement, not a second gameplay lock.
    pub fn tryAcquire(self: *Headless) ?Locked {
        if (!self.hasReceiver() or !self.mutex.tryLock()) return null;
        return .{ .headless = self };
    }

    pub const Locked = struct {
        headless: *Headless,

        pub fn release(self: Locked) void {
            self.headless.mutex.unlock(self.headless.io);
        }

        fn ledger(self: Locked) *receiver.Ledger {
            return &self.headless.ledger.?;
        }

        pub fn lookup(self: Locked, owner: receiver.Pubkey, id: receiver.Id, now: u64) !?receiver.Info {
            return self.ledger().lookup(owner, id, now);
        }

        pub fn loadLive(self: Locked, owner: receiver.Pubkey, id: receiver.Id, now: u64) !?receiver.LoadedChannel {
            return self.ledger().loadLive(owner, id, now);
        }

        pub fn acceptFunded(self: Locked, owner: receiver.Pubkey, request: receiver.Open, now: u64) !void {
            return self.acceptToolFunded(owner, request, now, .hoe);
        }

        pub fn acceptToolFunded(self: Locked, owner: receiver.Pubkey, request: receiver.Open, now: u64, tool: protocol.tool) !void {
            const store = self.ledger();
            const accepted = try store.acceptToolFunded(owner, request, now, tool);
            // Mint verification may have taken time. Do not link an inactive channel.
            const after = self.headless.unixSeconds() orelse return error.ClockUnavailable;
            if (accepted.expiry <= after or accepted.expiry - after <= store.limits.stop_payments_before_expiry_seconds)
                return error.ChannelNotActive;
        }

        pub fn acceptPayment(self: Locked, live: *LiveHoeChannel, payment: receiver.Payment, now: u64) !void {
            try self.ledger().acceptPayment(live, payment, now);
        }

        pub const Close = enum { pending, already_settled, newly_settled };

        pub fn closeChannel(self: Locked, owner: receiver.Pubkey, request: protocol.SpillmanChannelClosing, now: u64) !Close {
            const store = self.ledger();
            const id = request.id;
            const info = (try store.lookup(owner, id, now)) orelse return error.ChannelNotFound;
            // This comparison and the journal freeze both run under the same
            // wallet guard that serializes accepted payments.
            if (request.expected_balance_msat) |expected| {
                if (expected == 0 or expected != info.balance_msat or info.phase == .sender_refund_required)
                    return error.ChannelCloseBalanceMismatch;
            } else if (info.remaining() != 0 or info.balance_msat == 0) return error.ChannelNotDepleted;
            if (info.phase == .settled and info.wallet_redeemed) return .already_settled;
            return if (try store.settleAndRedeem(owner, id, now)) .newly_settled else .pending;
        }

        /// Only read the locally persisted receipt; never submit, recover or redeem a swap.
        pub fn senderProofs(self: Locked, owner: receiver.Pubkey, id: receiver.Id, allocator: std.mem.Allocator, max_proof_bytes: usize) !?[]const u8 {
            const receipt = (try self.ledger().loadSettlement(owner, id)) orelse return error.MissingSettlementReceipt;
            defer receipt.deinit();
            if (receipt.value.wallet_net_msat == null) return error.SettlementPending;
            if (receipt.value.sender_sum == 0) return null;
            const proofs = receipt.value.sender_proofs_json;
            if (proofs.len == 0 or proofs.len > max_proof_bytes) return error.InvalidSenderProofLength;
            return try allocator.dupe(u8, proofs);
        }
    };

    fn unixSeconds(self: *const Headless) ?u64 {
        return std.math.cast(u64, std.Io.Clock.real.now(self.io).toSeconds());
    }

    pub const SettlementObserver = struct {
        context: *anyopaque,
        notify: *const fn (*anyopaque, receiver.Pubkey, receiver.Id) void,
    };

    pub fn settlementLoop(self: *Headless, observer: SettlementObserver) std.Io.Cancelable!void {
        const ledger = if (self.ledger) |*ledger| ledger else return;
        while (true) {
            // Expired earned balances can race a sender refund; scan them first.
            try self.sweep(ledger, .due, observer);
            try self.sweep(ledger, .pending, observer);
            try self.io.sleep(.fromSeconds(15), .awake);
        }
    }

    fn sweep(self: *Headless, ledger: *receiver.Ledger, phase: enum { due, pending }, observer: SettlementObserver) std.Io.Cancelable!void {
        var after: ?receiver.Id = null;
        while (true) {
            try self.io.checkCancel();
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            const now = self.unixSeconds() orelse return;
            const next = switch (phase) {
                .due => ledger.nextDue(after, now),
                .pending => ledger.nextPending(after),
            };
            const entry = (next catch |err| {
                receiver_log.warn("settlement scan failed: {s}", .{@errorName(err)});
                return;
            }) orelse return;
            after = entry.id;
            // Journaled swaps are recovered, never reposted. Leave unresolved rows intact.
            const settled = ledger.settleAndRedeem(entry.owner, entry.id, now) catch |err| {
                receiver_log.warn("settlement attempt failed: {s}", .{@errorName(err)});
                continue;
            };
            if (settled) observer.notify(observer.context, entry.owner, entry.id);
        }
    }
};

pub const Mode = enum { provision, existing };

// The build graph only emits this prefix for an explicit -Dapp-fixture-mint
// (which it validates as http://127.0.0.1:PORT with an optional trailing slash).
// CDK's MintUrl serializes this already-lowercase URL without the slash.
pub const fixture_mint: ?[:0]const u8 = if (std.mem.startsWith(u8, cdk.app_mint, "http://127.0.0.1:"))
    std.mem.trimEnd(u8, cdk.app_mint, "/") ++ ""
else
    null;

const testnut_url = "https://testnut.cashu.space";
const testnut_mint: ?[:0]const u8 = if (std.mem.eql(u8, cdk.app_mint, testnut_url ++ "/") or
    std.mem.eql(u8, cdk.app_mint, testnut_url)) testnut_url else null;
const ledger_name = "channels.sqlite";
const week_seconds = 7 * 24 * 60 * 60;

fn testnutMode(io: std.Io, wallet_dir: []const u8, ledger_dir: []const u8) !Mode {
    const data_dir = std.fs.path.dirname(wallet_dir) orelse return error.InvalidPath;
    const root = sf.openOwnedDir(io, data_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return .provision,
        else => return err,
    };
    defer root.close(io);
    // An entry of any kind counts as existing, even a dangling symlink. Never
    // decide to provision based on the SQLite file; it may have been lost.
    _ = root.statFile(io, ledger_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .provision,
        else => return err,
    };
    return .existing;
}

fn openReceiver(io: std.Io, allocator: std.mem.Allocator, wallet_dir: []const u8, ledger_dir: []const u8, handle: *cdk.c.CdkWallet_t, mint: [:0]const u8, mode: Mode) !receiver.Ledger {
    const data_dir = std.fs.path.dirname(wallet_dir) orelse return error.InvalidPath;
    const root = try sf.openOwnedDir(io, data_dir, .{ .iterate = true });
    defer root.close(io);
    const dir_path = try std.fs.path.join(allocator, &.{ data_dir, ledger_dir });
    defer allocator.free(dir_path);
    const db_path = try std.fs.path.joinZ(allocator, &.{ dir_path, ledger_name });
    defer allocator.free(db_path);

    var secret: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    const domain = if (std.mem.eql(u8, mint, testnut_url))
        "haystack/server/hoe-testnut-receiver/v1"
    else
        "haystack/server/hoe-fixture-receiver/v1";
    try deriveReceiver(io, allocator, wallet_dir, domain, &secret);

    // Never reset an existing directory, even if its ledger is empty, missing,
    // or left incomplete by a failed provision. Existing mode never creates it.
    if (mode == .provision) try root.createDir(io, ledger_dir, sf.mode_dir);
    const dir = try sf.openOwnedDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    const file = switch (mode) {
        .provision => try dir.createFile(io, ledger_name, .{ .exclusive = true, .permissions = sf.mode_file }),
        .existing => blk: {
            try sf.verifyFile(try dir.statFile(io, ledger_name, .{ .follow_symlinks = false }));
            break :blk try dir.openFile(io, ledger_name, .{ .mode = .read_write, .follow_symlinks = false });
        },
    };
    defer file.close(io);
    const stat = try file.stat(io);
    try sf.verifyFile(stat);
    try sf.verifyNoExtendedAcl(file);
    if (mode == .existing and stat.size == 0) return error.InvalidChannelDatabase;

    var ledger = try receiver.Ledger.open(allocator, db_path, if (mode == .provision) .create else .existing, handle, mint, secret, .{ .max_lifetime_seconds = week_seconds });
    errdefer ledger.close();
    // SQLite commits with synchronous=EXTRA. Flush the file and directory chain
    // before injection, including on restart after a previous failed flush.
    try file.sync(io);
    try sf.syncDirectory(dir);
    try sf.syncDirectory(root);

    return ledger;
}

fn deriveReceiver(io: std.Io, allocator: std.mem.Allocator, wallet_dir: []const u8, domain: []const u8, secret: *[32]u8) !void {
    const paths = try wallet.Paths.init(allocator, wallet_dir);
    defer paths.deinit(allocator);
    const phrase = try wallet.readMnemonic(io, allocator, paths);
    defer {
        std.crypto.secureZero(u8, phrase);
        allocator.free(phrase);
    }
    const phrase_z = try allocator.dupeSentinel(u8, phrase, 0);
    defer {
        std.crypto.secureZero(u8, phrase_z);
        allocator.free(phrase_z);
    }
    var result = cdk.c.cdk_mnemonic_to_seed(phrase_z.ptr);
    defer cdk.c.cdk_bytes_free(result.bytes);
    try wallet.check(&result);
    if (result.bytes.len != cdk.seed_len) return error.CdkFailure;

    // This domain is part of the persisted ledger identity; do not change it.
    // Ledger.open rejects an invalid secp256k1 scalar rather than using it.
    std.crypto.auth.hmac.sha2.HmacSha256.create(secret, domain, result.bytes.ptr[0..cdk.seed_len]);
}

/// Test-only failure at a specific parent, after the pair was committed.
pub var testFailParentSyncPath: ?[]const u8 = null;
pub var testSyncObserver: ?*const fn ([]const u8) void = null;

fn openHeadlessWallet(io: std.Io, allocator: std.mem.Allocator, locations: Locations) !wallet.Wallet {
    const paths = try wallet.Paths.init(allocator, locations.wallet_dir);
    defer paths.deinit(allocator);
    // Validate the managed data root even when the final wallet is absent.
    try sf.ensureOwnedDir(io, std.fs.path.dirname(paths.dir) orelse return error.InvalidPath);
    var inspected = try wallet.inspect(io, allocator, paths, true);
    errdefer inspected.close() catch {};
    switch (inspected.state) {
        .incomplete => return error.IncompleteWallet,
        .not_initialized => {
            // create refuses even an existing empty directory; never repair it.
            const created = try wallet.create(io, allocator, paths);
            const durability = created.durability;
            created.deinit(allocator);
            if (durability != .durable) return error.WalletDurabilityUnknown;
            inspected = try wallet.inspect(io, allocator, paths, true);
        },
        .ready => {},
    }
    try wallet.syncDurability(io, paths);
    try syncParents(io, locations);
    return inspected.wallet orelse error.WalletNotReady;
}

/// Repeat bottom-up on every restart, including HOME when standard parents
/// were newly created. Standard parents may be symlinks, unlike managed roots.
fn syncParents(io: std.Io, locations: Locations) !void {
    try syncPath(io, locations.config_dir, true);
    try syncPath(io, std.fs.path.dirname(locations.config_dir) orelse return error.InvalidPath, false);
    var i = locations.standard_parents.len;
    while (i > 0) {
        i -= 1;
        const path = locations.standard_parents[i];
        try syncPath(io, path, false);
        try syncPath(io, std.fs.path.dirname(path) orelse return error.InvalidPath, false);
    }
}

fn syncPath(io: std.Io, path: []const u8, managed: bool) !void {
    const dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true, .follow_symlinks = !managed });
    defer dir.close(io);
    if (@import("builtin").is_test) if (testFailParentSyncPath) |failed| {
        if (std.mem.eql(u8, path, failed)) return error.SyncFailed;
    };
    try sf.syncDirectory(dir);
    if (@import("builtin").is_test) if (testSyncObserver) |observe| observe(path);
}
