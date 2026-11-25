//! Winning cuts create durable debt; wallet issuance is a one-shot attempt.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const native = @import("native_storage");
const wallet = native.wallet_service.Headless;
const sf = native.storage_fs;
const Prize = @import("game_db.zig").Prize;
const Persistence = @import("persistence.zig").Persistence;
const log = std.log.scoped(.prizes);

pub const Tier = enum {
    refund,
    small,
    medium,
    big,
    rare,
    jackpot,

    pub fn amount(self: Tier, tool: p.tool) u64 {
        const price = tool.priceMsat();
        return switch (self) {
            .refund => price,
            .small => 2 * price,
            .medium => 5 * price,
            .big => 15 * price,
            .rare => 100 * price,
            .jackpot => 100_000,
        };
    }
};

const bucket_count = 1_000_000;
const jackpot_bucket = 67;

fn tierForBucket(bucket: u64) ?Tier {
    // Keep the jackpot on the same tiles when changing the regular tiers.
    if (bucket == jackpot_bucket) return .jackpot;
    if (bucket < jackpot_bucket) return null;
    return switch (bucket - jackpot_bucket - 1) {
        0...199_999 => .refund,
        200_000...299_999 => .small,
        300_000...339_999 => .medium,
        340_000...349_999 => .big,
        350_000...350_499 => .rare,
        else => null,
    };
}

pub fn canStock(amount_msat: u64) bool {
    for (p.tools) |tool| {
        for (std.enums.values(Tier)) |tier| {
            if (tier.amount(tool) == amount_msat) return true;
        }
    }
    return false;
}

pub fn canClaimStock(amount_msat: u64) bool {
    // Invoices created by a previous prize schedule can still be claimed.
    return canStock(amount_msat) or switch (amount_msat) {
        32, 64, 128, 256, 500, 512, 1024 => true,
        else => false,
    };
}

pub fn parseSeed(hex: ?[]const u8) !?[32]u8 {
    var seed: [32]u8 = undefined;
    const value = hex orelse return null;
    if (value.len != 2 * seed.len) return error.InvalidPrizeSeed;
    _ = std.fmt.hexToBytes(&seed, value) catch return error.InvalidPrizeSeed;
    return seed;
}

const seed_file_name = "prize-seed.bin";

/// Call with the server instance lock held, so first startup cannot replace another seed.
pub fn loadOrCreateSeed(io: std.Io, config_dir: []const u8, legacy_seed: ?[32]u8) ![32]u8 {
    const dir = try sf.openOwnedDir(io, config_dir, .{ .iterate = true });
    defer dir.close(io);

    const stat = dir.statFile(io, seed_file_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            var seed: [32]u8 = undefined;
            defer std.crypto.secureZero(u8, &seed);
            if (legacy_seed) |seed_value| seed = seed_value else try io.randomSecure(&seed);
            try sf.writeAtomicIn(dir, io, seed_file_name, &seed);
            return seed;
        },
        else => return err,
    };
    try sf.verifyFile(stat);
    const file = try dir.openFile(io, seed_file_name, .{ .follow_symlinks = false });
    defer file.close(io);
    const opened = try file.stat(io);
    try sf.verifyFile(opened);
    try sf.verifyNoExtendedAcl(file);
    var seed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    if (opened.size != seed.len) return error.InvalidPrizeSeed;
    var reader = file.reader(io, &.{});
    if (try reader.interface.readSliceShort(&seed) != seed.len) return error.InvalidPrizeSeed;
    if (legacy_seed) |seed_value| {
        if (!std.crypto.timing_safe.eql([32]u8, seed_value, seed)) return error.PrizeSeedMismatch;
    }
    // A previous startup may have renamed the seed but failed to sync the directory.
    try sf.syncDirectory(dir);
    return seed;
}

pub fn roll(secret: [32]u8, public_seed: [32]u8, x: i32, y: i32) ?Tier {
    var world_key: [32]u8 = undefined;
    var prf = std.crypto.hash.Blake3.init(.{ .key = secret });
    prf.update("haystack.prize-world-key.v2");
    prf.update(&public_seed);
    prf.final(&world_key);
    return tierForBucket(wallet.privateYield(world_key, x, y) % bucket_count);
}

pub fn deliver(storage: *Persistence, prize: Prize, sender: anytype, out: *[p.max_prize_token_bytes]u8) !?[]const u8 {
    const amount_msat = blk: {
        storage.disk_lock.lockUncancelable(storage.io);
        defer storage.disk_lock.unlock(storage.io);
        break :blk try storage.db.beginPrizeSend(prize);
    };
    // Only the wallet guard is held during FFI, not either world or disk lock.
    const sent = sender.sendPrize(amount_msat);
    defer sent.deinit();
    storage.disk_lock.lockUncancelable(storage.io);
    defer storage.disk_lock.unlock(storage.io);
    const token = sent.bytes();
    if (token) |bytes| {
        if (bytes.len != 0) {
            storage.db.recordPrizeSend(prize, .{ .issued = .{ .operation_id = sent.operation_id, .token = bytes } }) catch |err| {
                log.warn("cannot journal prize token at ({d},{d}): operation={s}", .{ prize.x, prize.y, std.fmt.bytesToHex(sent.operation_id, .lower) });
                return err;
            };
            if (sent.outcome == .token and bytes.len <= out.len) {
                @memcpy(out[0..bytes.len], bytes);
                return out[0..bytes.len];
            }
            log.warn("prize token requires manual delivery at ({d},{d})", .{ prize.x, prize.y });
            return null;
        }
    }
    if (sent.outcome == .no_funds) {
        try storage.db.recordPrizeSend(prize, .{ .no_token = sent.operation_id });
    } else {
        try storage.db.recordPrizeSend(prize, .{ .uncertain = sent.operation_id });
        log.warn("prize send requires manual reconciliation at ({d},{d})", .{ prize.x, prize.y });
    }
    return null;
}

test "legacy prize seed is optional and only accepts exactly 32 bytes of hex" {
    const t = std.testing;
    try t.expectEqual(null, try parseSeed(null));
    try t.expectError(error.InvalidPrizeSeed, parseSeed(""));
    const invalid: [64]u8 = @splat('z');
    const oversized: [65]u8 = @splat('a');
    const valid = std.fmt.bytesToHex(@as([32]u8, @splat(0xab)), .upper);
    try t.expectError(error.InvalidPrizeSeed, parseSeed(&invalid));
    try t.expectError(error.InvalidPrizeSeed, parseSeed(&oversized));
    try t.expectEqual(@as([32]u8, @splat(0xab)), (try parseSeed(&valid)).?);
}

test "first startup generates a private prize seed and restarts reuse it" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "server", sf.mode_dir);
    const path = try tmp.dir.realPathFileAlloc(t.io, "server", t.allocator);
    defer t.allocator.free(path);

    const first = try loadOrCreateSeed(t.io, path, null);
    const stat = try tmp.dir.statFile(t.io, "server/" ++ seed_file_name, .{ .follow_symlinks = false });
    try sf.verifyFile(stat);
    try t.expectEqual(32, stat.size);
    try t.expectEqual(first, try loadOrCreateSeed(t.io, path, null));
}

test "prize seed migration preserves the legacy seed and rejects changes or malformed storage" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "server", sf.mode_dir);
    const path = try tmp.dir.realPathFileAlloc(t.io, "server", t.allocator);
    defer t.allocator.free(path);
    const legacy: [32]u8 = @splat(0xab);

    try t.expectEqual(legacy, try loadOrCreateSeed(t.io, path, legacy));
    try t.expectEqual(legacy, try loadOrCreateSeed(t.io, path, legacy));
    try t.expectError(error.PrizeSeedMismatch, loadOrCreateSeed(t.io, path, @splat(0xcd)));
    try t.expectEqual(legacy, try loadOrCreateSeed(t.io, path, null));

    const entry = "server/" ++ seed_file_name;
    try tmp.dir.writeFile(t.io, .{ .sub_path = entry, .data = "truncated" });
    try t.expectError(error.InvalidPrizeSeed, loadOrCreateSeed(t.io, path, legacy));
    try tmp.dir.deleteFile(t.io, entry);
    try tmp.dir.symLink(t.io, "missing", entry, .{});
    try t.expectError(error.InsecureEntry, loadOrCreateSeed(t.io, path, null));
}

test "slot prize frequencies and payouts keep a house edge for every tool" {
    const t = std.testing;
    var counts = std.EnumArray(Tier, u64).initFill(0);
    for (0..bucket_count) |bucket| {
        if (tierForBucket(bucket)) |tier| counts.getPtr(tier).* += 1;
    }
    try t.expectEqual(200_000, counts.get(.refund));
    try t.expectEqual(100_000, counts.get(.small));
    try t.expectEqual(40_000, counts.get(.medium));
    try t.expectEqual(10_000, counts.get(.big));
    try t.expectEqual(500, counts.get(.rare));
    try t.expectEqual(1, counts.get(.jackpot));
    for (p.tools) |tool| {
        const price = tool.priceMsat();
        try t.expectEqual(100_000, Tier.jackpot.amount(tool));
        var regular_payout: u64 = 0;
        for ([_]Tier{ .refund, .small, .medium, .big, .rare }, [_]u64{ 1, 2, 5, 15, 100 }) |tier, multiplier| {
            try t.expectEqual(price * multiplier, tier.amount(tool));
            try t.expect(canStock(tier.amount(tool)));
            regular_payout += counts.get(tier) * tier.amount(tool);
        }
        const spend = bucket_count * price;
        try t.expectEqual(spend * 4 / 5, regular_payout);
        try t.expect(regular_payout + counts.get(.jackpot) * Tier.jackpot.amount(tool) < spend);
    }
    try t.expect(canStock(100_000));
    try t.expect(!canStock(1024) and canClaimStock(1024));
    try t.expect(!canClaimStock(100_001));
}

test "prize roll is deterministic and scoped to the public world seed and coordinates" {
    const t = std.testing;
    const secret: [32]u8 = @splat(0x96);
    const world = shared.world.public_seed;
    var changed = world;
    changed[31] ^= 1;
    var count: usize = 0;
    var differs = false;
    for (0..20000) |i| {
        const x: i32 = -@as(i32, @intCast(i));
        const tier = roll(secret, world, x, -7) orelse continue;
        count += 1;
        try t.expectEqual(tier, roll(secret, world, x, -7).?);
        differs = differs or tier != roll(secret, changed, x, -7);
    }
    try t.expect(count > 6600 and count < 7400 and differs);
}

test "prize delivery journals intent before wallet I/O and never reissues a token" {
    const t = std.testing;
    const GameDb = @import("game_db.zig").GameDb;
    const Fake = struct {
        const Result = struct {
            outcome: enum { token, no_funds, uncertain },
            token: ?[]const u8 = null,
            operation_id: [16]u8 = @splat(7),

            pub fn bytes(self: @This()) ?[]const u8 {
                return self.token;
            }
            pub fn deinit(_: @This()) void {}
        };
        storage: *Persistence,
        reader: *native.sqlite.Db,
        x: i32,
        amount_msat: u64,
        result: Result,
        calls: usize = 0,

        pub fn sendPrize(self: *@This(), amount: u64) Result {
            self.calls += 1;
            t.expectEqual(self.amount_msat, amount) catch unreachable;
            t.expect(self.storage.world_lock.tryLock()) catch unreachable;
            self.storage.world_lock.unlock(t.io);
            t.expect(self.storage.disk_lock.tryLock()) catch unreachable;
            self.storage.disk_lock.unlock(t.io);
            const stmt = self.reader.prepare("SELECT state, token FROM pending_prizes WHERE x = ?1") catch unreachable;
            defer stmt.finalize();
            stmt.bindInt(1, self.x) catch unreachable;
            t.expect(stmt.next() catch unreachable) catch unreachable;
            t.expect(stmt.textEquals(0, "sending") and stmt.isNull(1)) catch unreachable;
            return self.result;
        }
    };
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.joinZ(a, &.{ dir, "game.sqlite" });
    var db = try GameDb.open(path);
    defer db.close();
    const reader = try native.sqlite.Db.open(path, .read_write_no_mutex, false);
    defer reader.close();
    // Delivery only needs the database and its guards, not a loaded world cache.
    var storage: Persistence = .{ .io = t.io, .db = &db, .world = undefined, .registry = undefined, .chunk_batch = &.{}, .user_batch = &.{} };
    const oversized: [p.max_prize_token_bytes + 1]u8 = @splat('x');
    const cases = [_]struct { result: Fake.Result, state: []const u8, fail_write: bool = false }{
        .{ .result = .{ .outcome = .token, .token = "cashu-test-exact-bytes" }, .state = "issued" },
        .{ .result = .{ .outcome = .no_funds }, .state = "unfunded" },
        .{ .result = .{ .outcome = .uncertain }, .state = "sending" },
        .{ .result = .{ .outcome = .token, .token = &oversized }, .state = "issued" },
        .{ .result = .{ .outcome = .token, .token = "never-returned" }, .state = "sending", .fail_write = true },
    };
    for (cases, 0..) |case, i| {
        const prize: Prize = .{ .x = @intCast(i), .y = 0, .owner = @splat(3) };
        const amount_msat = @as(u64, 16) << @intCast(i);
        try db.commitPrizeCut(prize, @splat(0xff), amount_msat);
        if (case.fail_write) try reader.exec("CREATE TRIGGER reject_token BEFORE UPDATE OF token ON pending_prizes BEGIN SELECT raise(ABORT, 'test'); END");
        var fake: Fake = .{ .storage = &storage, .reader = reader, .x = prize.x, .amount_msat = amount_msat, .result = case.result };
        var out: [p.max_prize_token_bytes]u8 = @splat(0);
        if (case.fail_write) {
            try t.expectError(error.SqliteConstraint, deliver(&storage, prize, &fake, &out));
            try t.expectEqual(@as(u8, 0), out[0]);
        } else {
            const token = try deliver(&storage, prize, &fake, &out);
            if (i == 0) try t.expectEqualStrings(case.result.token.?, token.?) else try t.expectEqual(null, token);
        }
        try t.expectError(error.PrizeStateConflict, deliver(&storage, prize, &fake, &out));
        try t.expectEqual(1, fake.calls);
        const stmt = try reader.prepare("SELECT owner, amount_msat, state, operation_id, token FROM pending_prizes WHERE x = ?1");
        defer stmt.finalize();
        try stmt.bindInt(1, prize.x);
        try t.expect(try stmt.next());
        try t.expectEqual(prize.owner, try stmt.blob(33, 0));
        try t.expectEqual(amount_msat, try stmt.uint(1));
        try t.expect(stmt.textEquals(2, case.state));
        if (!case.fail_write) try t.expectEqual(case.result.operation_id, try stmt.blob(16, 3));
        if (std.mem.eql(u8, case.state, "issued")) {
            try t.expectEqualSlices(u8, case.result.token.?, try stmt.blobSlice(4));
        } else try t.expect(stmt.isNull(4));
    }
}
