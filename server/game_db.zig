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

    fn initSchema(self: *GameDb, create: bool) !void {
        // Check compatibility before writing. Keep inspection and any schema
        // changes in one transaction; a normal reopen only reads.
        try self.exec("BEGIN");
        errdefer self.rollback();
        if (try self.hasSchema()) {
            try self.validateSchema();
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
            const stmt = try self.prepare("INSERT INTO game_meta (id, seed, generator_version) VALUES (1, ?1, ?2)");
            defer stmt.finalize();
            try stmt.bindBlob(1, &world.public_seed);
            try stmt.bindInt(2, world.generator_version);
            try stmt.finish();
        }
        try self.commit();
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
