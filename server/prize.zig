//! Winning cuts create durable debt; wallet issuance is a one-shot attempt.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const wallet = @import("native_storage").wallet_service.Headless;
const Prize = @import("game_db.zig").Prize;
const Persistence = @import("persistence.zig").Persistence;
const log = std.log.scoped(.prizes);

pub const amount_msat = 500;
const odds = 2000;

pub fn parseSeed(hex: ?[]const u8) !?[32]u8 {
    var seed: [32]u8 = undefined;
    const value = hex orelse return null;
    if (value.len != 2 * seed.len) return error.InvalidPrizeSeed;
    _ = std.fmt.hexToBytes(&seed, value) catch return error.InvalidPrizeSeed;
    return seed;
}

pub fn wins(secret: [32]u8, public_seed: [32]u8, x: i32, y: i32) bool {
    var world_key: [32]u8 = undefined;
    var prf = std.crypto.hash.Blake3.init(.{ .key = secret });
    prf.update("haystack.prize-world-key.v1");
    prf.update(&public_seed);
    prf.final(&world_key);
    const roll = wallet.privateYield(world_key, x, y);
    return roll % odds == 0;
}

pub fn deliver(storage: *Persistence, prize: Prize, sender: anytype, out: *[p.max_prize_token_bytes]u8) !?[]const u8 {
    {
        storage.disk_lock.lockUncancelable(storage.io);
        defer storage.disk_lock.unlock(storage.io);
        try storage.db.recordPrizeSend(prize, .intent);
    }
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

test "prize seed is optional and only accepts exactly 32 bytes of hex" {
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
        if (!wins(secret, world, x, -7)) continue;
        count += 1;
        try t.expect(wins(secret, world, x, -7));
        differs = differs or !wins(secret, changed, x, -7);
    }
    try t.expect(count > 0 and count < 30 and differs);
}

test "prize delivery journals intent before wallet I/O and never reissues a token" {
    const t = std.testing;
    const native = @import("native_storage");
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
        result: Result,
        calls: usize = 0,

        pub fn sendPrize(self: *@This(), amount: u64) Result {
            self.calls += 1;
            t.expectEqual(amount_msat, amount) catch unreachable;
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
        try db.commitPrizeCut(prize, @splat(0xff), amount_msat);
        if (case.fail_write) try reader.exec("CREATE TRIGGER reject_token BEFORE UPDATE OF token ON pending_prizes BEGIN SELECT raise(ABORT, 'test'); END");
        var fake: Fake = .{ .storage = &storage, .reader = reader, .x = prize.x, .result = case.result };
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
