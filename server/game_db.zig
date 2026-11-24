//! Gameplay-only SQLite storage. The caller serializes access and is responsible
//! for passing authenticated public keys; this layer only stores their raw bytes.
const std = @import("std");
const sqlite = @import("native_storage").sqlite;
const shared = @import("shared");
const protocol = shared.protocol;
const world = shared.world;
const ChunkAddress = @import("chunk_address.zig").ChunkAddress;

pub const User = struct {
    location: protocol.Location,
    hoe_channel_id: ?[32]u8 = null,
    axe_channel_id: ?[32]u8 = null,
    pickaxe_channel_id: ?[32]u8 = null,

    pub fn channelId(self: User, tool: protocol.tool) ?[32]u8 {
        return switch (tool) {
            .hoe => self.hoe_channel_id,
            .axe => self.axe_channel_id,
            .pickaxe => self.pickaxe_channel_id,
        };
    }

    pub fn setChannelId(self: *User, tool: protocol.tool, id: ?[32]u8) void {
        switch (tool) {
            .hoe => self.hoe_channel_id = id,
            .axe => self.axe_channel_id = id,
            .pickaxe => self.pickaxe_channel_id = id,
        }
    }
};

pub const Prize = struct {
    x: i32,
    y: i32,
    owner: [33]u8,
};

pub const GameDb = struct {
    db: ?*sqlite.Db,
    path: [:0]const u8,

    const load_chunk_sql = "SELECT bits FROM game_chunks WHERE cx = ?1 AND cy = ?2";
    const user_columns = "x, y, hoe_channel_id, axe_channel_id, pickaxe_channel_id";
    const load_user_sql = "SELECT " ++ user_columns ++ " FROM game_users WHERE pubkey = ?1";

    /// Borrows path until close so a poisoned connection can be reopened.
    pub fn open(path: [:0]const u8) !GameDb {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidGameDatabasePath;
        return openPath(path, true);
    }

    fn openPath(path: [:0]const u8, create: bool) !GameDb {
        const db = sqlite.Db.open(path, .read_write_no_mutex, create) catch |err| return gameDbError(err);
        var self: GameDb = .{ .db = db, .path = path };
        errdefer self.close();
        // With a rollback journal, also sync its directory after the commit unlink.
        self.exec("PRAGMA synchronous = EXTRA") catch |err| return gameDbError(err);
        self.initSchema(create) catch |err| return gameDbError(err);
        return self;
    }

    pub fn close(self: *GameDb) void {
        if (self.db) |db| db.close();
        self.* = undefined;
    }

    pub fn reopenIfPoisoned(self: *GameDb) !void {
        if (self.db != null) return;
        // Never replace a missing or emptied database with a fresh one on retry.
        self.* = try openPath(self.path, false);
    }

    pub fn loadChunk(self: *GameDb, address: ChunkAddress) !?[32]u8 {
        const stmt = try self.prepare(load_chunk_sql);
        defer stmt.finalize();
        try stmt.bindInt(1, address.cx);
        try stmt.bindInt(2, address.cy);
        if (!try stmt.next()) return null;
        const bits = try stmt.blob(32, 0);
        try stmt.finish();
        return bits;
    }

    pub fn loadUser(self: *GameDb, key: [33]u8) !?User {
        const stmt = try self.prepare(load_user_sql);
        defer stmt.finalize();
        try stmt.bindBlob(1, &key);
        if (!try stmt.next()) return null;
        const user = try readUser(stmt);
        try stmt.finish();
        return user;
    }

    pub fn begin(self: *GameDb) !void {
        try self.exec("BEGIN IMMEDIATE");
    }

    pub fn commit(self: *GameDb) !void {
        try self.exec("COMMIT");
    }

    pub fn rollback(self: *GameDb) void {
        const db = self.db orelse return;
        if (db.autocommit()) return;
        self.exec("ROLLBACK") catch {
            // Discard the connection so nothing can later commit this failed batch.
            db.close();
            self.db = null;
        };
    }

    pub fn saveChunk(self: *GameDb, address: ChunkAddress, bits: [32]u8) !void {
        if (!chunkCoordsValid(address.cx, address.cy)) return error.InvalidGameDatabase;
        const stmt = try self.prepare(
            \\INSERT INTO game_chunks (cx, cy, bits) VALUES (?1, ?2, ?3)
            \\ON CONFLICT (cx, cy) DO UPDATE SET bits = excluded.bits
        );
        defer stmt.finalize();
        try stmt.bindInt(1, address.cx);
        try stmt.bindInt(2, address.cy);
        try stmt.bindBlob(3, &bits);
        try stmt.finish();
    }

    pub fn saveUser(self: *GameDb, key: [33]u8, user: User) !void {
        const stmt = try self.prepare(
            \\INSERT INTO game_users (pubkey, x, y, hoe_channel_id, axe_channel_id, pickaxe_channel_id)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            \\ON CONFLICT (pubkey) DO UPDATE SET x = excluded.x, y = excluded.y,
            \\    hoe_channel_id = excluded.hoe_channel_id, axe_channel_id = excluded.axe_channel_id,
            \\    pickaxe_channel_id = excluded.pickaxe_channel_id
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &key);
        try stmt.bindInt(2, user.location.x);
        try stmt.bindInt(3, user.location.y);
        inline for (.{ .hoe, .axe, .pickaxe }, 4..) |tool, param| {
            if (user.channelId(tool)) |id| {
                try stmt.bindBlob(param, &id);
            } else {
                try stmt.bindNull(param);
            }
        }
        try stmt.finish();
    }

    /// Caller holds the disk lock. Neither the bitmap nor the debt may commit alone.
    pub fn commitPrizeCut(self: *GameDb, prize: Prize, bits: [32]u8, amount_msat: u64) !void {
        try self.reopenIfPoisoned();
        try self.begin();
        errdefer self.rollback();
        try self.saveChunk(ChunkAddress.fromTile(prize.x, prize.y), bits);
        const stmt = try self.prepare("INSERT INTO pending_prizes (x, y, owner, amount_msat, state) VALUES (?1, ?2, ?3, ?4, 'owed')");
        defer stmt.finalize();
        try bindPrize(stmt, prize);
        try stmt.bindUInt(4, amount_msat);
        try stmt.finish();
        try self.commit();
    }

    /// Every transition is its own durable write. An interrupted send remains
    /// in 'sending' for manual reconciliation, even when no operation ID made it back.
    pub fn recordPrizeSend(self: *GameDb, prize: Prize, change: union(enum) {
        intent,
        no_token: [16]u8,
        uncertain: [16]u8,
        issued: struct { operation_id: [16]u8, token: []const u8 },
    }) !void {
        try self.reopenIfPoisoned();
        const stmt = try self.prepare(switch (change) {
            .intent => "UPDATE pending_prizes SET state = 'sending' WHERE x = ?1 AND y = ?2 AND owner = ?3 AND state = 'owed'",
            .no_token => "UPDATE pending_prizes SET state = 'unfunded', operation_id = ?4 WHERE x = ?1 AND y = ?2 AND owner = ?3 AND state = 'sending'",
            .uncertain => "UPDATE pending_prizes SET operation_id = ?4 WHERE x = ?1 AND y = ?2 AND owner = ?3 AND state = 'sending'",
            .issued => "UPDATE pending_prizes SET state = 'issued', operation_id = ?4, token = ?5 WHERE x = ?1 AND y = ?2 AND owner = ?3 AND state = 'sending'",
        });
        defer stmt.finalize();
        try bindPrize(stmt, prize);
        switch (change) {
            .intent => {},
            .no_token, .uncertain => |id| try stmt.bindBlob(4, &id),
            .issued => |issued| {
                try stmt.bindBlob(4, &issued.operation_id);
                try stmt.bindBlob(5, issued.token);
            },
        }
        try stmt.finish();
        if (self.db.?.changes() != 1) return error.PrizeStateConflict;
    }

    /// Caller holds the disk lock. The returned token borrows only the caller's buffer.
    pub fn nextIssuedPrize(self: *GameDb, owner: [33]u8, after: ?protocol.Location, out: *[protocol.max_prize_token_bytes]u8) !?struct { tile: protocol.Location, token: []const u8 } {
        try self.reopenIfPoisoned();
        const stmt = try self.prepare(
            \\SELECT x, y, token FROM pending_prizes
            \\WHERE owner = ?1 AND state = 'issued' AND (x, y) > (?2, ?3)
            \\  AND length(token) BETWEEN 1 AND ?4
            \\ORDER BY x, y LIMIT 1
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &owner);
        try stmt.bindInt(2, if (after) |tile| tile.x else @as(i64, std.math.minInt(i32)) - 1);
        try stmt.bindInt(3, if (after) |tile| tile.y else 0);
        try stmt.bindUInt(4, out.len);
        if (!try stmt.next()) return null;
        const tile: protocol.Location = .{
            .x = std.math.cast(i32, try stmt.int(0)) orelse return error.InvalidGameDatabase,
            .y = std.math.cast(i32, try stmt.int(1)) orelse return error.InvalidGameDatabase,
        };
        const bytes = try stmt.blobSlice(2);
        @memcpy(out[0..bytes.len], bytes);
        return .{ .tile = tile, .token = out[0..bytes.len] };
    }

    /// Caller holds the disk lock. A repeated ACK or one from another owner is a no-op.
    pub fn acknowledgePrize(self: *GameDb, prize: Prize) !void {
        try self.reopenIfPoisoned();
        const stmt = try self.prepare("DELETE FROM pending_prizes WHERE x = ?1 AND y = ?2 AND owner = ?3 AND state = 'issued'");
        defer stmt.finalize();
        try bindPrize(stmt, prize);
        try stmt.finish();
    }

    fn bindPrize(stmt: *sqlite.Stmt, prize: Prize) !void {
        try stmt.bindInt(1, prize.x);
        try stmt.bindInt(2, prize.y);
        try stmt.bindBlob(3, &prize.owner);
    }

    fn initSchema(self: *GameDb, create: bool) !void {
        // Check compatibility before writing. Keep inspection and any schema
        // changes in one transaction; a normal reopen only reads.
        try self.exec("BEGIN");
        errdefer self.rollback();
        if (try self.hasSchema()) {
            try self.validateSchema();
            try self.validatePrizeSchema();
            const stmt = try self.prepare("SELECT id, seed, generator_version FROM game_meta");
            defer stmt.finalize();
            if (!try stmt.next() or try stmt.int(0) != 1) return error.InvalidGameDatabase;
            const seed = try stmt.blob(32, 1);
            const version = try stmt.int(2);
            try stmt.finish();
            if (!std.mem.eql(u8, &seed, &world.public_seed) or version != world.generator_version) return error.WorldMismatch;
            try self.validateRows();
        } else {
            if (!create) return error.InvalidGameDatabase;
            try self.exec(comptime std.fmt.comptimePrint(
                \\CREATE TABLE game_meta (
                \\    id INTEGER PRIMARY KEY CHECK (id = 1),
                \\    seed BLOB NOT NULL CHECK (typeof(seed) = 'blob' AND length(seed) = 32),
                \\    generator_version INTEGER NOT NULL CHECK (typeof(generator_version) = 'integer')
                \\);
                \\CREATE TABLE game_chunks (
                \\    cx INTEGER NOT NULL CHECK (typeof(cx) = 'integer' AND cx BETWEEN {[min_chunk]d} AND {[max_chunk]d}),
                \\    cy INTEGER NOT NULL CHECK (typeof(cy) = 'integer' AND cy BETWEEN {[min_chunk]d} AND {[max_chunk]d}),
                \\    bits BLOB NOT NULL CHECK (typeof(bits) = 'blob' AND length(bits) = 32),
                \\    PRIMARY KEY (cx, cy)
                \\) WITHOUT ROWID;
                \\CREATE TABLE game_users (
                \\    pubkey BLOB NOT NULL PRIMARY KEY CHECK (typeof(pubkey) = 'blob' AND length(pubkey) = 33),
                \\    x INTEGER NOT NULL CHECK (typeof(x) = 'integer' AND x BETWEEN {[min_tile]d} AND {[max_tile]d}),
                \\    y INTEGER NOT NULL CHECK (typeof(y) = 'integer' AND y BETWEEN {[min_tile]d} AND {[max_tile]d}),
                \\    hoe_channel_id BLOB CHECK (hoe_channel_id IS NULL OR (typeof(hoe_channel_id) = 'blob' AND length(hoe_channel_id) = 32)),
                \\    axe_channel_id BLOB CHECK (axe_channel_id IS NULL OR (typeof(axe_channel_id) = 'blob' AND length(axe_channel_id) = 32)),
                \\    pickaxe_channel_id BLOB CHECK (pickaxe_channel_id IS NULL OR (typeof(pickaxe_channel_id) = 'blob' AND length(pickaxe_channel_id) = 32))
                \\) WITHOUT ROWID;
            , .{
                .min_chunk = protocol.min_chunk,
                .max_chunk = protocol.max_chunk,
                .min_tile = std.math.minInt(i32),
                .max_tile = std.math.maxInt(i32),
            }));
            try self.createPrizeSchema();
            const stmt = try self.prepare("INSERT INTO game_meta (id, seed, generator_version) VALUES (1, ?1, ?2)");
            defer stmt.finalize();
            try stmt.bindBlob(1, &world.public_seed);
            try stmt.bindInt(2, world.generator_version);
            try stmt.finish();
        }
        try self.commit();
    }

    const prize_index_sql = "CREATE INDEX pending_prizes_issued_owner ON pending_prizes (owner, x, y) WHERE state = 'issued'";

    fn createPrizeSchema(self: *GameDb) !void {
        try self.exec(
            \\CREATE TABLE pending_prizes (
            \\    x INTEGER NOT NULL CHECK (typeof(x) = 'integer' AND x BETWEEN -2147483648 AND 2147483647),
            \\    y INTEGER NOT NULL CHECK (typeof(y) = 'integer' AND y BETWEEN -2147483648 AND 2147483647),
            \\    owner BLOB NOT NULL CHECK (typeof(owner) = 'blob' AND length(owner) = 33),
            \\    unit TEXT NOT NULL DEFAULT 'msat' CHECK (unit = 'msat'),
            \\    amount_msat INTEGER NOT NULL CHECK (typeof(amount_msat) = 'integer' AND amount_msat > 0),
            \\    state TEXT NOT NULL CHECK (state IN ('owed', 'sending', 'unfunded', 'issued')),
            \\    operation_id BLOB CHECK (operation_id IS NULL OR (typeof(operation_id) = 'blob' AND length(operation_id) = 16)),
            \\    token BLOB CHECK ((state = 'issued') = (token IS NOT NULL) AND
            \\        (token IS NULL OR (typeof(token) = 'blob' AND length(token) > 0))),
            \\    PRIMARY KEY (x, y)
            \\) WITHOUT ROWID;
        ++ "\n" ++ prize_index_sql);
    }

    fn validatePrizeSchema(self: *GameDb) !void {
        const stmt = try self.prepare(
            \\SELECT count(*) = 8 AND sum(CASE
            \\    WHEN name = 'x' AND type = 'INTEGER' AND "notnull" = 1 AND pk = 1 THEN 1
            \\    WHEN name = 'y' AND type = 'INTEGER' AND "notnull" = 1 AND pk = 2 THEN 1
            \\    WHEN name = 'owner' AND type = 'BLOB' AND "notnull" = 1 AND pk = 0 THEN 1
            \\    WHEN name = 'amount_msat' AND type = 'INTEGER' AND "notnull" = 1 AND pk = 0 THEN 1
            \\    WHEN name = 'state' AND type = 'TEXT' AND "notnull" = 1 AND pk = 0 THEN 1
            \\    WHEN name IN ('operation_id', 'token') AND type = 'BLOB' AND "notnull" = 0 AND pk = 0 THEN 1
            \\    WHEN name = 'unit' AND type = 'TEXT' AND "notnull" = 1 AND pk = 0 AND dflt_value = '''msat''' THEN 1
            \\    ELSE 0 END) = 8
            \\FROM pragma_table_xinfo('pending_prizes', 'main') WHERE hidden = 0
        );
        defer stmt.finalize();
        if (!try stmt.next() or try stmt.int(0) != 1) return error.InvalidGameDatabase;
        try stmt.finish();

        // Require the definition we ship: SQLite's index pragmas don't expose
        // the predicate, and the key collations can be inherited from the table.
        const index = try self.prepare(
            \\SELECT sql, NOT EXISTS (
            \\    SELECT 1 FROM pragma_index_xinfo('pending_prizes_issued_owner', 'main')
            \\    WHERE "key" = 1 AND coll != 'BINARY'
            \\)
            \\FROM main.sqlite_master WHERE type = 'index'
            \\    AND tbl_name = 'pending_prizes' AND name = 'pending_prizes_issued_owner'
        );
        defer index.finalize();
        if (!try index.next() or !index.textEquals(0, prize_index_sql) or try index.int(1) != 1)
            return error.InvalidGameDatabase;
        try index.finish();
    }

    fn validateSchema(self: *GameDb) !void {
        // A gameplay SELECT alone can compile against a view or a table without
        // the required primary key.
        const schema = try self.prepare(
            \\WITH expected AS (VALUES
            \\    ('game_meta', 'id', 'INTEGER', 0, 1, 0),
            \\    ('game_meta', 'seed', 'BLOB', 1, 0, 0),
            \\    ('game_meta', 'generator_version', 'INTEGER', 1, 0, 0),
            \\    ('game_chunks', 'cx', 'INTEGER', 1, 1, 0),
            \\    ('game_chunks', 'cy', 'INTEGER', 1, 2, 0),
            \\    ('game_chunks', 'bits', 'BLOB', 1, 0, 0),
            \\    ('game_users', 'pubkey', 'BLOB', 1, 1, 0),
            \\    ('game_users', 'x', 'INTEGER', 1, 0, 0),
            \\    ('game_users', 'y', 'INTEGER', 1, 0, 0),
            \\    ('game_users', 'hoe_channel_id', 'BLOB', 0, 0, 0),
            \\    ('game_users', 'axe_channel_id', 'BLOB', 0, 0, 0),
            \\    ('game_users', 'pickaxe_channel_id', 'BLOB', 0, 0, 0)
            \\), actual AS (
            \\    SELECT s.name, p.name, upper(p.type), p."notnull", p.pk, p.hidden
            \\    FROM main.sqlite_master AS s CROSS JOIN pragma_table_xinfo(s.name, 'main') AS p
            \\    WHERE s.type = 'table' AND s.name IN ('game_meta', 'game_chunks', 'game_users')
            \\)
            \\SELECT NOT EXISTS (SELECT * FROM expected EXCEPT SELECT * FROM actual)
            \\   AND NOT EXISTS (SELECT * FROM actual EXCEPT SELECT * FROM expected)
        );
        defer schema.finalize();
        if (!try schema.next() or try schema.int(0) != 1) return error.InvalidGameDatabase;
        try schema.finish();
    }

    fn validateRows(self: *GameDb) !void {
        const integrity = try self.prepare("PRAGMA integrity_check(1)");
        defer integrity.finalize();
        if (!try integrity.next() or !integrity.textEquals(0, "ok")) return error.InvalidGameDatabase;
        try integrity.finish();

        // Validate persisted values even if the tables lack the original CHECKs.
        // Walk the rows without retaining them or populating the world cache.
        const chunks = try self.prepare("SELECT cx, cy, bits FROM game_chunks");
        defer chunks.finalize();
        while (try chunks.next()) {
            if (!chunkCoordsValid(try chunks.int(0), try chunks.int(1))) return error.InvalidGameDatabase;
            _ = try chunks.blob(32, 2);
        }
        const users = try self.prepare("SELECT " ++ user_columns ++ ", pubkey FROM game_users");
        defer users.finalize();
        while (try users.next()) {
            _ = try readUser(users);
            _ = try users.blob(33, 5);
        }

        // Oversized issued tokens stay in the journal for manual handling.
        const prizes = try self.prepare(
            \\SELECT 1 FROM pending_prizes
            \\WHERE typeof(x) != 'integer' OR x NOT BETWEEN -2147483648 AND 2147483647
            \\   OR typeof(y) != 'integer' OR y NOT BETWEEN -2147483648 AND 2147483647
            \\   OR typeof(owner) != 'blob' OR length(owner) != 33
            \\   OR typeof(unit) != 'text' OR unit COLLATE BINARY != 'msat'
            \\   OR typeof(amount_msat) != 'integer' OR amount_msat <= 0
            \\   OR typeof(state) != 'text' OR state COLLATE BINARY NOT IN ('owed', 'sending', 'unfunded', 'issued')
            \\   OR (state COLLATE BINARY = 'issued') != (token IS NOT NULL)
            \\   OR (token IS NOT NULL AND (typeof(token) != 'blob' OR length(token) = 0))
            \\   OR (operation_id IS NOT NULL AND (typeof(operation_id) != 'blob' OR length(operation_id) != 16))
            \\   OR (state COLLATE BINARY = 'owed' AND operation_id IS NOT NULL)
            \\   OR (state COLLATE BINARY IN ('unfunded', 'issued') AND operation_id IS NULL)
            \\LIMIT 1
        );
        defer prizes.finalize();
        if (try prizes.next()) return error.InvalidGameDatabase;
    }

    fn hasSchema(self: *GameDb) !bool {
        const schema = try self.prepare(
            \\SELECT EXISTS (SELECT 1 FROM sqlite_master),
            \\       EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'game_meta')
        );
        defer schema.finalize();
        if (!try schema.next()) return error.InvalidGameDatabase;
        const has_objects = try schema.int(0) != 0;
        const has_meta = try schema.int(1) != 0;
        try schema.finish();
        if (has_objects and !has_meta) return error.InvalidGameDatabase;
        return has_meta;
    }

    fn exec(self: *GameDb, sql: [*:0]const u8) !void {
        const db = self.db orelse return error.GameDatabasePoisoned;
        try db.exec(sql);
    }

    fn prepare(self: *GameDb, sql: [*:0]const u8) !*sqlite.Stmt {
        const db = self.db orelse return error.GameDatabasePoisoned;
        return db.prepare(sql);
    }
};

fn chunkCoordsValid(cx: i64, cy: i64) bool {
    return cx >= protocol.min_chunk and cx <= protocol.max_chunk and
        cy >= protocol.min_chunk and cy <= protocol.max_chunk;
}

fn readUser(stmt: *sqlite.Stmt) !User {
    return .{
        .location = .{
            .x = std.math.cast(i32, try stmt.int(0)) orelse return error.InvalidGameDatabase,
            .y = std.math.cast(i32, try stmt.int(1)) orelse return error.InvalidGameDatabase,
        },
        .hoe_channel_id = if (stmt.isNull(2)) null else try stmt.blob(32, 2),
        .axe_channel_id = if (stmt.isNull(3)) null else try stmt.blob(32, 3),
        .pickaxe_channel_id = if (stmt.isNull(4)) null else try stmt.blob(32, 4),
    };
}

fn gameDbError(err: anyerror) anyerror {
    return if (err == error.InvalidSqliteData) error.InvalidGameDatabase else err;
}

const testing = std.testing;

fn tempPath(tmp: *testing.TmpDir) ![:0]const u8 {
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    return std.fmt.allocPrintSentinel(testing.allocator, "{s}/game.sqlite3", .{dir}, 0);
}

test "winning cut and unique owner survive reopen or roll back together" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp);
    defer testing.allocator.free(path);
    const prize: Prize = .{ .x = -1, .y = -1, .owner = @splat(0x32) };
    const address = ChunkAddress.fromTile(prize.x, prize.y);
    var bits: [32]u8 = @splat(0);
    bits[31] = 0x80;
    {
        var db = try GameDb.open(path);
        defer db.close();
        try db.saveChunk(address, @splat(0));
        try db.exec("CREATE TRIGGER reject_prize BEFORE INSERT ON pending_prizes BEGIN SELECT raise(ABORT, 'test'); END");
        try testing.expectError(error.SqliteConstraint, db.commitPrizeCut(prize, bits, 1000));
        try testing.expectEqual(@as(?[32]u8, @splat(0)), try db.loadChunk(address));
        try db.exec("DROP TRIGGER reject_prize");
        try db.commitPrizeCut(prize, bits, 1000);
        var stranger = prize;
        stranger.owner = @splat(0x44);
        try testing.expectError(error.SqliteConstraint, db.commitPrizeCut(stranger, @splat(0xff), 1000));
        try testing.expectError(error.PrizeStateConflict, db.recordPrizeSend(stranger, .intent));
    }
    var db = try GameDb.open(path);
    defer db.close();
    try testing.expectEqual(@as(?[32]u8, bits), try db.loadChunk(address));
    const row = try db.prepare("SELECT x, y, owner, amount_msat, state FROM pending_prizes");
    defer row.finalize();
    try testing.expect(try row.next());
    try testing.expectEqual(@as(i64, -1), try row.int(0));
    try testing.expectEqual(@as(i64, -1), try row.int(1));
    try testing.expectEqual(prize.owner, try row.blob(33, 2));
    try testing.expectEqual(@as(i64, 1000), try row.int(3));
    try testing.expect(row.textEquals(4, "owed"));
    try row.finish();
}

test "game database refuses missing prize schema without writing it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp);
    defer testing.allocator.free(path);
    {
        var db = try GameDb.open(path);
        defer db.close();
        try db.exec("DROP TABLE pending_prizes");
    }
    const before = try tmp.dir.readFileAlloc(testing.io, "game.sqlite3", testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(before);
    try testing.expectError(error.InvalidGameDatabase, GameDb.open(path));
    const after = try tmp.dir.readFileAlloc(testing.io, "game.sqlite3", testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

test "game database rejects incompatible prize indexes without rewriting" {
    inline for (.{
        "(x, y, owner) WHERE state = 'issued'",
        "(owner, x DESC, y) WHERE state = 'issued'",
        "(owner COLLATE NOCASE, x, y) WHERE state = 'issued'",
        "(owner, x, y)",
        "(owner, x, y) WHERE state = 'sending'",
    }) |definition| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tempPath(&tmp);
        defer testing.allocator.free(path);
        {
            var db = try GameDb.open(path);
            defer db.close();
            try db.exec("DROP INDEX pending_prizes_issued_owner; CREATE INDEX pending_prizes_issued_owner ON pending_prizes " ++ definition);
        }
        try expectRejectedUnchanged(&tmp, path);
    }
}

test "game database rejects malformed prize rows without CHECKs or rewriting" {
    const unchecked_prizes =
        \\DROP TABLE pending_prizes;
        \\CREATE TABLE pending_prizes (
        \\    x INTEGER NOT NULL, y INTEGER NOT NULL, owner BLOB NOT NULL,
        \\    unit TEXT NOT NULL DEFAULT 'msat', amount_msat INTEGER NOT NULL, state TEXT NOT NULL,
        \\    operation_id BLOB, token BLOB, PRIMARY KEY (x, y)
        \\) WITHOUT ROWID;
    ++ "\n" ++ GameDb.prize_index_sql ++ ";";
    inline for (.{
        "x = 'not an integer'",
        "y = 2147483648",
        "owner = zeroblob(32)",
        "unit = 'sat'",
        "amount_msat = 0",
        "amount_msat = 1.5",
        "state = 'paid'",
        "state = 'issued', operation_id = zeroblob(16)",
        "state = 'issued', operation_id = zeroblob(16), token = X''",
        "state = 'issued', operation_id = zeroblob(16), token = 'not a blob'",
        "state = 'sending', token = X'aa'",
        "state = 'sending', operation_id = zeroblob(15)",
        "state = 'sending', operation_id = '1234567890123456'",
        "operation_id = zeroblob(16)",
        "state = 'unfunded'",
        "state = 'issued', token = X'aa'",
    }) |assignment| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tempPath(&tmp);
        defer testing.allocator.free(path);
        {
            var db = try GameDb.open(path);
            defer db.close();
            try db.exec(unchecked_prizes ++
                "INSERT INTO pending_prizes (x, y, owner, amount_msat, state) VALUES (0, 0, zeroblob(33), 500, 'owed');" ++
                "UPDATE pending_prizes SET " ++ assignment);
        }
        try expectRejectedUnchanged(&tmp, path);
    }
}

test "game database keeps oversized issued prize tokens across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp);
    defer testing.allocator.free(path);
    const prize: Prize = .{ .x = 1, .y = 2, .owner = @splat(3) };
    const token: [protocol.max_prize_token_bytes + 1]u8 = @splat(0x5a);
    {
        var db = try GameDb.open(path);
        defer db.close();
        try db.commitPrizeCut(prize, @splat(0xff), 500);
        try db.recordPrizeSend(prize, .intent);
        try db.recordPrizeSend(prize, .{ .issued = .{ .operation_id = @splat(1), .token = &token } });
    }
    try expectOpenUnchanged(&tmp, path);
}

test "unfunded prizes record millisats without a token" {
    var db = try GameDb.open(":memory:");
    defer db.close();
    const prize: Prize = .{ .x = 1, .y = 2, .owner = @splat(3) };
    try db.commitPrizeCut(prize, @splat(0xff), 1000);
    try db.recordPrizeSend(prize, .intent);
    try db.recordPrizeSend(prize, .{ .no_token = @splat(0) });
    try testing.expectError(error.SqliteConstraint, db.exec("UPDATE pending_prizes SET unit = 'sat'"));
    try testing.expectError(error.SqliteConstraint, db.exec("UPDATE pending_prizes SET token = X'aa'"));
    const row = try db.prepare("SELECT unit, amount_msat, state, token FROM pending_prizes");
    defer row.finalize();
    try testing.expect(try row.next());
    try testing.expect(row.textEquals(0, "msat"));
    try testing.expectEqual(@as(u64, 1000), try row.uint(1));
    try testing.expect(row.textEquals(2, "unfunded"));
    try testing.expect(row.isNull(3));
    try row.finish();
}

test "game database persists committed chunks and users across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp);
    defer testing.allocator.free(path);
    const key: [33]u8 = @splat(0xa5);
    var other_key = key;
    other_key[32] = 0;
    var user: User = .{ .location = .{ .x = -2, .y = std.math.maxInt(i32) } };
    user.setChannelId(.hoe, @splat(0xbc));
    user.setChannelId(.axe, @splat(0x34));
    user.setChannelId(.pickaxe, @splat(0x56));
    const other: User = .{ .location = .{ .x = 1, .y = std.math.minInt(i32) } };
    const bits: [32]u8 = @splat(0x41);

    {
        var db = try GameDb.open(path);
        defer db.close();
        try testing.expectEqual(null, try db.loadChunk(.{ .cx = -4, .cy = 7 }));
        try testing.expectEqual(null, try db.loadUser(key));
        try db.begin();
        try db.saveChunk(.{ .cx = -4, .cy = 7 }, bits);
        try db.saveChunk(.{ .cx = 7, .cy = -4 }, @splat(0));
        try db.saveUser(key, user);
        try db.saveUser(other_key, other);
        try db.commit();

        try db.begin();
        try db.saveChunk(.{ .cx = -4, .cy = 7 }, @splat(0xff));
        try db.saveUser(key, other);
        db.rollback();
    }
    var db = try GameDb.open(path);
    defer db.close();
    try testing.expectEqual(bits, (try db.loadChunk(.{ .cx = -4, .cy = 7 })).?);
    try testing.expectEqual(@as([32]u8, @splat(0)), (try db.loadChunk(.{ .cx = 7, .cy = -4 })).?);
    try testing.expectEqualDeep(user, (try db.loadUser(key)).?);
    try testing.expectEqualDeep(other, (try db.loadUser(other_key)).?);

    try db.begin();
    try db.saveChunk(.{ .cx = -4, .cy = 7 }, @splat(0xff));
    try db.saveUser(key, other);
    try db.commit();
    try testing.expectEqual(@as([32]u8, @splat(0xff)), (try db.loadChunk(.{ .cx = -4, .cy = 7 })).?);
    try testing.expectEqualDeep(other, (try db.loadUser(key)).?);
}

test "game database rejects SQLite read-only fallback on startup and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp);
    defer testing.allocator.free(path);
    var db = try GameDb.open(path);
    db.close();

    {
        const file = try tmp.dir.openFile(testing.io, "game.sqlite3", .{});
        defer file.close(testing.io);
        try file.setPermissions(testing.io, .fromMode(0o444));
    }
    if (tmp.dir.access(testing.io, "game.sqlite3", .{ .write = true })) |_| {
        // Privileged runners can still open the file for writing.
        return error.SkipZigTest;
    } else |err| switch (err) {
        error.AccessDenied => {},
        else => return err,
    }

    try testing.expectError(error.SqliteReadOnly, GameDb.open(path));
    db = .{ .db = null, .path = path };
    defer db.close();
    try testing.expectError(error.SqliteReadOnly, db.reopenIfPoisoned());
    try testing.expect(db.db == null);

    {
        const file = try tmp.dir.openFile(testing.io, "game.sqlite3", .{});
        defer file.close(testing.io);
        try file.setPermissions(testing.io, .fromMode(0o600));
    }
    try db.reopenIfPoisoned();
    try db.saveChunk(.{ .cx = 0, .cy = 0 }, @splat(1));
}

test "game database rejects seed and generator mismatches without changing the file" {
    for ([_]bool{ true, false }) |change_seed| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tempPath(&tmp);
        defer testing.allocator.free(path);
        {
            var db = try GameDb.open(path);
            defer db.close();
            try db.saveChunk(.{ .cx = 1, .cy = 2 }, @splat(0xff));
            if (change_seed) {
                const stmt = try db.prepare("UPDATE game_meta SET seed = ?1");
                defer stmt.finalize();
                var seed = world.public_seed;
                seed[0] ^= 1;
                try stmt.bindBlob(1, &seed);
                try stmt.finish();
            } else {
                try db.exec("UPDATE game_meta SET generator_version = generator_version + 1");
            }
        }
        const before = try tmp.dir.readFileAlloc(testing.io, "game.sqlite3", testing.allocator, .limited(1024 * 1024));
        defer testing.allocator.free(before);
        try testing.expectError(error.WorldMismatch, GameDb.open(path));
        const after = try tmp.dir.readFileAlloc(testing.io, "game.sqlite3", testing.allocator, .limited(1024 * 1024));
        defer testing.allocator.free(after);
        try testing.expectEqualSlices(u8, before, after);
    }
}

test "game database rejects incomplete or invalid gameplay tables without changing the file" {
    for ([_][:0]const u8{
        "DROP TABLE game_chunks",
        "DROP TABLE game_users",
        "ALTER TABLE game_users RENAME COLUMN hoe_channel_id TO wrong_name",
        "ALTER TABLE game_users ADD COLUMN channel_id BLOB",
        "DROP TABLE game_chunks; CREATE TABLE game_chunks (cx INTEGER NOT NULL, cy INTEGER NOT NULL, bits BLOB NOT NULL)",
        "DROP TABLE game_users; CREATE VIEW game_users AS SELECT zeroblob(33) AS pubkey, 0 AS x, 0 AS y, NULL AS hoe_channel_id",
    }) |sql| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tempPath(&tmp);
        defer testing.allocator.free(path);
        {
            var db = try GameDb.open(path);
            defer db.close();
            try db.saveChunk(.{ .cx = 1, .cy = 2 }, @splat(0xff));
            try db.saveUser(@splat(0x42), .{ .location = .{ .x = 9, .y = 3 } });
            try db.exec(sql);
        }
        try expectRejectedUnchanged(&tmp, path);
    }
}

fn expectRejectedUnchanged(tmp: *testing.TmpDir, path: [:0]const u8) !void {
    const before = try tmp.dir.readFileAlloc(testing.io, "game.sqlite3", testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(before);
    try testing.expectError(error.InvalidGameDatabase, GameDb.open(path));
    const after = try tmp.dir.readFileAlloc(testing.io, "game.sqlite3", testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

// Simulate older chunk constraints to exercise explicit row validation.
const legacy_chunks =
    \\DROP TABLE game_chunks;
    \\CREATE TABLE game_chunks (
    \\  cx INTEGER NOT NULL CHECK (typeof(cx) = 'integer' AND cx BETWEEN -2147483648 AND 2147483647),
    \\  cy INTEGER NOT NULL CHECK (typeof(cy) = 'integer' AND cy BETWEEN -2147483648 AND 2147483647),
    \\  bits BLOB NOT NULL CHECK (typeof(bits) = 'blob' AND length(bits) = 32),
    \\  PRIMARY KEY (cx, cy)
    \\) WITHOUT ROWID;
;
const single_tool_users =
    \\DROP TABLE game_users;
    \\CREATE TABLE game_users (
    \\  pubkey BLOB NOT NULL PRIMARY KEY,
    \\  x INTEGER NOT NULL,
    \\  y INTEGER NOT NULL,
    \\  hoe_channel_id BLOB
    \\) WITHOUT ROWID;
;

const full_range_user: User = .{ .location = .{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32) } };

fn expectUserChecks(db: *GameDb) !void {
    inline for (.{ -2147483649, 2147483648 }) |outside| {
        try testing.expectError(error.SqliteConstraint, db.exec(std.fmt.comptimePrint("UPDATE game_users SET x = {d}", .{outside})));
        try testing.expectError(error.SqliteConstraint, db.exec(std.fmt.comptimePrint("UPDATE game_users SET y = {d}", .{outside})));
    }
}

fn expectOpenUnchanged(tmp: *testing.TmpDir, path: [:0]const u8) !void {
    const before = try tmp.dir.readFileAlloc(testing.io, "game.sqlite3", testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(before);
    {
        var db = try GameDb.open(path);
        defer db.close();
    }
    const after = try tmp.dir.readFileAlloc(testing.io, "game.sqlite3", testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

test "game database rejects both single-channel schemas on startup and recovery without rewriting" {
    for ([_]bool{ false, true }) |rename_column| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tempPath(&tmp);
        defer testing.allocator.free(path);
        {
            var db = try GameDb.open(path);
            defer db.close();
            try db.exec(single_tool_users);
            try db.exec("INSERT INTO game_users VALUES (zeroblob(33), 0, 0, zeroblob(32))");
            if (rename_column) try db.exec("ALTER TABLE game_users RENAME COLUMN hoe_channel_id TO channel_id");
        }
        const before = try tmp.dir.readFileAlloc(testing.io, "game.sqlite3", testing.allocator, .limited(1024 * 1024));
        defer testing.allocator.free(before);
        var poisoned: GameDb = .{ .db = null, .path = path };
        defer poisoned.close();
        try testing.expectError(error.InvalidGameDatabase, poisoned.reopenIfPoisoned());
        const after = try tmp.dir.readFileAlloc(testing.io, "game.sqlite3", testing.allocator, .limited(1024 * 1024));
        defer testing.allocator.free(after);
        try testing.expectEqualSlices(u8, before, after);
        try expectRejectedUnchanged(&tmp, path);
    }
}

test "game database enforces coordinate bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp);
    defer testing.allocator.free(path);
    const address: ChunkAddress = .{ .cx = protocol.min_chunk, .cy = protocol.max_chunk };
    const key: [33]u8 = @splat(0);
    const user: User = .{ .location = full_range_user.location, .hoe_channel_id = @splat(0x25) };
    const bits: [32]u8 = @splat(0xff);
    {
        var db = try GameDb.open(path);
        defer db.close();
        try db.saveChunk(address, bits);
        try db.saveUser(key, user);
    }

    var db = try GameDb.open(path);
    defer db.close();
    try testing.expectEqual(bits, (try db.loadChunk(address)).?);
    try testing.expectEqualDeep(user, (try db.loadUser(key)).?);
    inline for (.{ protocol.min_chunk - 1, protocol.max_chunk + 1 }) |outside| {
        try testing.expectError(error.InvalidGameDatabase, db.saveChunk(.{ .cx = outside, .cy = 0 }, bits));
        try testing.expectError(error.InvalidGameDatabase, db.saveChunk(.{ .cx = 0, .cy = outside }, bits));
        try testing.expectError(error.SqliteConstraint, db.exec(std.fmt.comptimePrint("INSERT INTO game_chunks VALUES ({d}, 0, zeroblob(32))", .{outside})));
        try testing.expectError(error.SqliteConstraint, db.exec(std.fmt.comptimePrint("INSERT INTO game_chunks VALUES (0, {d}, zeroblob(32))", .{outside})));
    }
    try expectUserChecks(&db);
    try expectOpenUnchanged(&tmp, path);
}

const unchecked_users = "DROP TABLE game_users; CREATE TABLE game_users (pubkey BLOB NOT NULL PRIMARY KEY, x INTEGER NOT NULL, y INTEGER NOT NULL, hoe_channel_id BLOB, axe_channel_id BLOB, pickaxe_channel_id BLOB) WITHOUT ROWID;";

test "game database startup rejects malformed gameplay rows without rewriting" {
    for ([_][:0]const u8{
        "INSERT INTO game_chunks VALUES (0, 0, zeroblob(31))",
        "INSERT INTO game_chunks VALUES (2147483648, 0, zeroblob(32))",
        "INSERT INTO game_users VALUES (zeroblob(32), 0, 0, NULL, NULL, NULL)",
        "INSERT INTO game_users VALUES (zeroblob(33), 'not an integer', 0, NULL, NULL, NULL)",
        "INSERT INTO game_users VALUES (zeroblob(33), 0, -2147483649, NULL, NULL, NULL)",
        "INSERT INTO game_users VALUES (zeroblob(33), 0, 0, zeroblob(31), NULL, NULL)",
        // Legacy CHECKs and structural integrity alone accept these rows.
        legacy_chunks ++ std.fmt.comptimePrint("INSERT INTO game_chunks VALUES ({d}, 0, zeroblob(32))", .{protocol.max_chunk + 1}),
        legacy_chunks ++ std.fmt.comptimePrint("INSERT INTO game_chunks VALUES (0, {d}, zeroblob(32))", .{protocol.min_chunk - 1}),
        // A structural integrity check alone also accepts these malformed rows.
        "DROP TABLE game_chunks; CREATE TABLE game_chunks (cx INTEGER NOT NULL, cy INTEGER NOT NULL, bits BLOB NOT NULL, PRIMARY KEY (cx, cy)) WITHOUT ROWID; INSERT INTO game_chunks VALUES (0, 0, zeroblob(31))",
        unchecked_users ++ "INSERT INTO game_users VALUES (zeroblob(33), 0, 0, zeroblob(31), NULL, NULL)",
        unchecked_users ++ "INSERT INTO game_users VALUES (zeroblob(33), 0, 0, NULL, zeroblob(31), NULL)",
        unchecked_users ++ "INSERT INTO game_users VALUES (zeroblob(33), 0, 0, NULL, NULL, 'not a blob')",
        unchecked_users ++ "INSERT INTO game_users VALUES (zeroblob(33), 2147483648, 0, NULL, NULL, NULL)",
        unchecked_users ++ "INSERT INTO game_users VALUES (zeroblob(33), 0, -2147483649, NULL, NULL, NULL)",
    }) |sql| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tempPath(&tmp);
        defer testing.allocator.free(path);
        {
            var db = try GameDb.open(path);
            defer db.close();
            try db.exec("PRAGMA ignore_check_constraints = ON");
            try db.exec(sql);
        }
        try expectRejectedUnchanged(&tmp, path);
    }
}

test "game database startup rejects SQLite page corruption without rewriting" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp);
    defer testing.allocator.free(path);
    const index_page = index_page: {
        var db = try GameDb.open(path);
        defer db.close();
        try db.exec("CREATE INDEX test_index ON game_chunks (cy)");
        const stmt = try db.prepare("SELECT rootpage, page_size FROM sqlite_master, pragma_page_size WHERE name = 'test_index'");
        defer stmt.finalize();
        try testing.expect(try stmt.next());
        const offset = (try stmt.int(0) - 1) * try stmt.int(1);
        try stmt.finish();
        break :index_page @as(usize, @intCast(offset));
    };
    const bytes = try tmp.dir.readFileAlloc(testing.io, "game.sqlite3", testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    bytes[index_page] = 0; // Invalid b-tree page type in an index unused by gameplay scans.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "game.sqlite3", .data = bytes });
    try expectRejectedUnchanged(&tmp, path);
}

test "game database rejects malformed blobs and reports write contention" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp);
    defer testing.allocator.free(path);
    var db = try GameDb.open(path);
    defer db.close();
    var other = try GameDb.open(path);
    defer other.close();

    try testing.expectError(error.SqliteConstraint, db.exec("INSERT INTO game_chunks VALUES (0, 0, zeroblob(31))"));
    try testing.expectError(error.SqliteConstraint, db.exec("INSERT INTO game_users VALUES (zeroblob(32), 0, 0, NULL, NULL, NULL)"));
    inline for (.{ "hoe_channel_id", "axe_channel_id", "pickaxe_channel_id" }) |column| {
        try testing.expectError(error.SqliteConstraint, db.exec("INSERT INTO game_users (pubkey, x, y, " ++ column ++ ") VALUES (zeroblob(33), 0, 0, zeroblob(33))"));
    }
    try db.begin();
    try testing.expectError(error.SqliteBusy, other.begin());
    db.rollback();
    try other.begin();
    try other.commit();
}
