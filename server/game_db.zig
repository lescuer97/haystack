//! Gameplay-only SQLite storage. The caller serializes access and is responsible
//! for passing authenticated public keys; this layer only stores their raw bytes.
const std = @import("std");
const shared = @import("shared");
const protocol = shared.protocol;
const world = shared.world;
const ChunkAddress = @import("chunk_address.zig").ChunkAddress;

pub const User = struct { location: protocol.Location, channel_id: ?[32]u8 = null };

const users_ddl =
    \\CREATE TABLE {[table]s} (
    \\    pubkey BLOB NOT NULL PRIMARY KEY CHECK (typeof(pubkey) = 'blob' AND length(pubkey) = 33),
    \\    x INTEGER NOT NULL CHECK (typeof(x) = 'integer' AND x BETWEEN {[min_tile]d} AND {[max_tile]d}),
    \\    y INTEGER NOT NULL CHECK (typeof(y) = 'integer' AND y BETWEEN {[min_tile]d} AND {[max_tile]d}),
    \\    channel_id BLOB CHECK (channel_id IS NULL OR (typeof(channel_id) = 'blob' AND length(channel_id) = 32))
    \\) WITHOUT ROWID
;

fn fullUsersDdl(comptime table: []const u8) [:0]const u8 {
    return std.fmt.comptimePrint(users_ddl, .{
        .table = table,
        .min_tile = std.math.minInt(i32),
        .max_tile = std.math.maxInt(i32),
    });
}

// Exact sqlite_schema.sql for the unversioned, renderer-limited table.
const narrow_users_ddl = std.fmt.comptimePrint(users_ddl, .{
    .table = "game_users",
    .min_tile = -67108572,
    .max_tile = 67108555,
});

pub const GameDb = struct {
    db: ?*sqlite.Db,
    path: [:0]const u8,

    const load_chunk_sql = "SELECT bits FROM game_chunks WHERE cx = ?1 AND cy = ?2";
    const load_user_sql = "SELECT x, y, channel_id FROM game_users WHERE pubkey = ?1";

    /// Borrows path until close so a poisoned connection can be reopened.
    pub fn open(path: [:0]const u8) !GameDb {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidGameDatabasePath;
        return openPath(path, true);
    }

    fn openPath(path: [:0]const u8, create: bool) !GameDb {
        var handle: ?*sqlite.Db = null;
        errdefer if (handle) |db| {
            _ = sqlite.sqlite3_close_v2(db);
        };
        const flags = sqlite.open_flags | if (create) sqlite.open_create else @as(c_int, 0);
        try sqlite.check(sqlite.sqlite3_open_v2(path.ptr, &handle, flags, null), sqlite.ok);
        const db = handle orelse return error.SqliteFailure;
        // READWRITE can succeed by falling back to read-only on Unix.
        switch (sqlite.sqlite3_db_readonly(db, "main")) {
            0 => {},
            1 => return error.SqliteReadOnly,
            else => return error.SqliteFailure,
        }
        var self: GameDb = .{ .db = db, .path = path };
        handle = null;
        errdefer self.close();
        try self.initSchema(create);
        return self;
    }

    pub fn close(self: *GameDb) void {
        if (self.db) |db| _ = sqlite.sqlite3_close_v2(db);
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
        const user = try stmt.user();
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
        if (sqlite.sqlite3_get_autocommit(db) != 0) return;
        self.exec("ROLLBACK") catch {
            // Discard the connection so nothing can later commit this failed batch.
            _ = sqlite.sqlite3_close_v2(db);
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
            \\INSERT INTO game_users (pubkey, x, y, channel_id) VALUES (?1, ?2, ?3, ?4)
            \\ON CONFLICT (pubkey) DO UPDATE SET x = excluded.x, y = excluded.y, channel_id = excluded.channel_id
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &key);
        try stmt.bindInt(2, user.location.x);
        try stmt.bindInt(3, user.location.y);
        if (user.channel_id) |*id| {
            try stmt.bindBlob(4, id);
        } else {
            try sqlite.check(sqlite.sqlite3_bind_null(stmt, 4), sqlite.ok);
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
            try self.migrateNarrowUsers();
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
            , .{
                .min_chunk = protocol.min_chunk,
                .max_chunk = protocol.max_chunk,
            }) ++ fullUsersDdl("game_users"));
            const stmt = try self.prepare("INSERT INTO game_meta (id, seed, generator_version) VALUES (1, ?1, ?2)");
            defer stmt.finalize();
            try stmt.bindBlob(1, &world.public_seed);
            try stmt.bindInt(2, world.generator_version);
            try stmt.finish();
        }
        try self.commit();
    }

    fn migrateNarrowUsers(self: *GameDb) !void {
        {
            const stmt = try self.prepare("SELECT sql FROM main.sqlite_schema WHERE type = 'table' AND name = 'game_users'");
            defer stmt.finalize();
            if (!try stmt.next()) return error.InvalidGameDatabase;
            if (!stmt.textEquals(0, narrow_users_ddl)) return;
            try stmt.finish();
        }
        {
            // DROP must not discard custom objects or cascade into other tables.
            const deps = try self.prepare(
                \\SELECT 1 FROM main.sqlite_schema
                \\    WHERE tbl_name = 'game_users' AND type IN ('index', 'trigger') AND sql IS NOT NULL
                \\UNION ALL
                \\SELECT 1 FROM main.sqlite_schema AS s CROSS JOIN pragma_foreign_key_list(s.name, 'main') AS f
                \\    WHERE s.type = 'table' AND f."table" = 'game_users' COLLATE NOCASE
            );
            defer deps.finalize();
            if (try deps.next()) return error.InvalidGameDatabase;
        }
        try self.exec(comptime fullUsersDdl("game_users_migrating") ++ ";" ++
            \\INSERT INTO game_users_migrating (pubkey, x, y, channel_id)
            \\    SELECT pubkey, x, y, channel_id FROM game_users;
            \\DROP TABLE game_users;
            \\ALTER TABLE game_users_migrating RENAME TO game_users;
        );
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
            \\    ('game_users', 'channel_id', 'BLOB', 0, 0, 0)
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
        const users = try self.prepare("SELECT x, y, channel_id, pubkey FROM game_users");
        defer users.finalize();
        while (try users.next()) {
            _ = try users.user();
            _ = try users.blob(33, 3);
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
        try sqlite.check(sqlite.sqlite3_exec(db, sql, null, null, null), sqlite.ok);
    }

    fn prepare(self: *GameDb, sql: [*:0]const u8) !*sqlite.Stmt {
        const db = self.db orelse return error.GameDatabasePoisoned;
        var stmt: ?*sqlite.Stmt = null;
        try sqlite.check(sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null), sqlite.ok);
        return stmt orelse error.SqliteFailure;
    }
};

fn chunkCoordsValid(cx: i64, cy: i64) bool {
    return cx >= protocol.min_chunk and cx <= protocol.max_chunk and
        cy >= protocol.min_chunk and cy <= protocol.max_chunk;
}

// Small stable subset of the sqlite3.h ABI.
const sqlite = struct {
    const Db = opaque {};
    const Stmt = opaque {
        fn finalize(self: *Stmt) void {
            // finalize can repeat a step error, which the caller already checked.
            _ = sqlite3_finalize(self);
        }

        fn bindInt(self: *Stmt, index: c_int, value: i64) !void {
            try check(sqlite3_bind_int64(self, index, value), ok);
        }

        fn bindBlob(self: *Stmt, index: c_int, value: []const u8) !void {
            // SQLITE_TRANSIENT asks SQLite to copy the bound bytes immediately.
            try check(sqlite3_bind_blob(self, index, value.ptr, @intCast(value.len), @ptrFromInt(std.math.maxInt(usize))), ok);
        }

        fn next(self: *Stmt) !bool {
            const rc = sqlite3_step(self);
            if (rc == row) return true;
            try check(rc, done);
            return false;
        }

        fn finish(self: *Stmt) !void {
            if (try self.next()) return error.InvalidGameDatabase;
        }

        fn int(self: *Stmt, column: c_int) !i64 {
            if (sqlite3_column_type(self, column) != integer_type) return error.InvalidGameDatabase;
            return sqlite3_column_int64(self, column);
        }

        fn textEquals(self: *Stmt, column: c_int, expected: []const u8) bool {
            if (sqlite3_column_type(self, column) != text_type) return false;
            const text = sqlite3_column_text(self, column) orelse return false;
            const len: usize = @intCast(sqlite3_column_bytes(self, column));
            return std.mem.eql(u8, text[0..len], expected);
        }

        fn int32(self: *Stmt, column: c_int) !i32 {
            return std.math.cast(i32, try self.int(column)) orelse error.InvalidGameDatabase;
        }

        fn user(self: *Stmt) !User {
            return .{
                .location = .{ .x = try self.int32(0), .y = try self.int32(1) },
                .channel_id = if (sqlite3_column_type(self, 2) == null_type) null else try self.blob(32, 2),
            };
        }

        fn blob(self: *Stmt, comptime len: usize, column: c_int) ![len]u8 {
            if (sqlite3_column_type(self, column) != blob_type) return error.InvalidGameDatabase;
            const data = sqlite3_column_blob(self, column);
            if (sqlite3_column_bytes(self, column) != len) return error.InvalidGameDatabase;
            return (data orelse return error.InvalidGameDatabase)[0..len].*;
        }
    };

    const ok = 0;
    const row = 100;
    const done = 101;
    const integer_type = 1;
    const text_type = 3;
    const blob_type = 4;
    const null_type = 5;
    const open_flags = 0x02 | 0x8000; // READWRITE | NOMUTEX
    const open_create: c_int = 0x04;
    const Destructor = *const fn (?*anyopaque) callconv(.c) void;
    const ExecCallback = *const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int;

    fn check(rc: c_int, expected: c_int) !void {
        if (rc == expected) return;
        // Mask extended result codes to preserve the same error categories.
        return switch (rc & 0xff) {
            5, 6 => error.SqliteBusy,
            7 => error.OutOfMemory,
            8 => error.SqliteReadOnly,
            10 => error.SqliteIo,
            11, 26 => error.InvalidGameDatabase,
            13 => error.SqliteFull,
            14 => error.SqliteCannotOpen,
            19 => error.SqliteConstraint,
            else => error.SqliteFailure,
        };
    }

    extern "c" fn sqlite3_open_v2([*:0]const u8, *?*Db, c_int, ?[*:0]const u8) c_int;
    extern "c" fn sqlite3_close_v2(*Db) c_int;
    extern "c" fn sqlite3_db_readonly(*Db, [*:0]const u8) c_int;
    extern "c" fn sqlite3_exec(*Db, [*:0]const u8, ?ExecCallback, ?*anyopaque, ?*?[*:0]u8) c_int;
    extern "c" fn sqlite3_get_autocommit(*Db) c_int;
    extern "c" fn sqlite3_prepare_v2(*Db, [*:0]const u8, c_int, *?*Stmt, ?*[*:0]const u8) c_int;
    extern "c" fn sqlite3_finalize(*Stmt) c_int;
    extern "c" fn sqlite3_step(*Stmt) c_int;
    extern "c" fn sqlite3_bind_int64(*Stmt, c_int, i64) c_int;
    extern "c" fn sqlite3_bind_blob(*Stmt, c_int, *const anyopaque, c_int, ?Destructor) c_int;
    extern "c" fn sqlite3_bind_null(*Stmt, c_int) c_int;
    extern "c" fn sqlite3_column_type(*Stmt, c_int) c_int;
    extern "c" fn sqlite3_column_int64(*Stmt, c_int) i64;
    extern "c" fn sqlite3_column_text(*Stmt, c_int) ?[*]const u8;
    extern "c" fn sqlite3_column_blob(*Stmt, c_int) ?[*]const u8;
    extern "c" fn sqlite3_column_bytes(*Stmt, c_int) c_int;
};

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
    const user: User = .{ .location = .{ .x = -2, .y = std.math.maxInt(i32) }, .channel_id = @splat(0xbc) };
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
            try db.exec("DROP TABLE game_users;" ++ narrow_users_ddl);
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
        "ALTER TABLE game_users RENAME COLUMN channel_id TO wrong_name",
        "DROP TABLE game_chunks; CREATE TABLE game_chunks (cx INTEGER NOT NULL, cy INTEGER NOT NULL, bits BLOB NOT NULL)",
        "DROP TABLE game_users; CREATE VIEW game_users AS SELECT zeroblob(33) AS pubkey, 0 AS x, 0 AS y, NULL AS channel_id",
        "DROP TABLE game_users;" ++ narrow_users_ddl ++ "; CREATE INDEX custom_index ON game_users (x)",
        "DROP TABLE game_users;" ++ narrow_users_ddl ++ "; CREATE TABLE custom (key REFERENCES GAME_USERS(pubkey) ON DELETE CASCADE)",
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

// Previous gameplay tables constrained coordinates only to i32.
const legacy_chunks =
    \\DROP TABLE game_chunks;
    \\CREATE TABLE game_chunks (
    \\  cx INTEGER NOT NULL CHECK (typeof(cx) = 'integer' AND cx BETWEEN -2147483648 AND 2147483647),
    \\  cy INTEGER NOT NULL CHECK (typeof(cy) = 'integer' AND cy BETWEEN -2147483648 AND 2147483647),
    \\  bits BLOB NOT NULL CHECK (typeof(bits) = 'blob' AND length(bits) = 32),
    \\  PRIMARY KEY (cx, cy)
    \\) WITHOUT ROWID;
;
const legacy_users =
    \\DROP TABLE game_users;
    \\CREATE TABLE game_users (
    \\  pubkey BLOB NOT NULL PRIMARY KEY CHECK (typeof(pubkey) = 'blob' AND length(pubkey) = 33),
    \\  x INTEGER NOT NULL CHECK (typeof(x) = 'integer' AND x BETWEEN -2147483648 AND 2147483647),
    \\  y INTEGER NOT NULL CHECK (typeof(y) = 'integer' AND y BETWEEN -2147483648 AND 2147483647),
    \\  channel_id BLOB CHECK (channel_id IS NULL OR (typeof(channel_id) = 'blob' AND length(channel_id) = 32))
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

test "game database migrates the narrow user table on startup and recovery open" {
    for ([_]bool{ false, true }) |recover| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tempPath(&tmp);
        defer testing.allocator.free(path);
        const key: [33]u8 = @splat(0x42);
        const other_key: [33]u8 = @splat(0x43);
        const user: User = .{ .location = .{ .x = -67108572, .y = 67108555 }, .channel_id = @splat(0x24) };
        const other: User = .{ .location = .{ .x = 23, .y = -42 } };
        const address: ChunkAddress = .{ .cx = protocol.min_chunk, .cy = protocol.max_chunk };
        const bits: [32]u8 = @splat(0x81);
        {
            var old = try GameDb.open(path);
            defer old.close();
            try old.exec("DROP TABLE game_users;" ++ narrow_users_ddl);
            try old.saveChunk(address, bits);
            try old.saveUser(key, user);
            try old.saveUser(other_key, other);
            try testing.expectError(error.SqliteConstraint, old.saveUser(key, full_range_user));
            if (recover) {
                // A reader can block COMMIT after the replacement table was built.
                // The failed open must roll back both the table and its contents.
                try old.exec("BEGIN");
                try testing.expectEqualDeep(user, (try old.loadUser(key)).?);
                var poisoned: GameDb = .{ .db = null, .path = path };
                try testing.expectError(error.SqliteBusy, poisoned.reopenIfPoisoned());
                try testing.expect(poisoned.db == null);
                old.rollback();
                try testing.expectError(error.SqliteConstraint, old.saveUser(key, full_range_user));
                try testing.expectEqualDeep(user, (try old.loadUser(key)).?);
            }
        }
        {
            var db: GameDb = .{ .db = null, .path = path };
            defer db.close();
            if (recover) try db.reopenIfPoisoned() else db = try GameDb.open(path);
            try testing.expectEqualDeep(user, (try db.loadUser(key)).?);
            try testing.expectEqualDeep(other, (try db.loadUser(other_key)).?);
            try testing.expectEqual(bits, (try db.loadChunk(address)).?);
            try db.saveUser(key, .{ .location = full_range_user.location, .channel_id = user.channel_id });
            try expectUserChecks(&db);
        }
        try expectOpenUnchanged(&tmp, path);
        var db = try GameDb.open(path);
        defer db.close();
        try testing.expectEqualDeep(User{ .location = full_range_user.location, .channel_id = user.channel_id }, (try db.loadUser(key)).?);
    }
}

test "game database retains legacy schema compatibility and enforces coordinate bounds" {
    for ([_]bool{ false, true }) |legacy| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tempPath(&tmp);
        defer testing.allocator.free(path);
        const address: ChunkAddress = .{ .cx = protocol.min_chunk, .cy = protocol.max_chunk };
        const key: [33]u8 = @splat(0);
        const user = full_range_user;
        const bits: [32]u8 = @splat(0xff);
        {
            var db = try GameDb.open(path);
            defer db.close();
            if (legacy) try db.exec(legacy_chunks ++ legacy_users);
            try db.saveChunk(address, bits);
            try db.saveUser(key, user);
        }

        try expectOpenUnchanged(&tmp, path);
        var db = try GameDb.open(path);
        defer db.close();
        try testing.expectEqual(bits, (try db.loadChunk(address)).?);
        try testing.expectEqualDeep(user, (try db.loadUser(key)).?);
        inline for (.{ protocol.min_chunk - 1, protocol.max_chunk + 1 }) |outside| {
            try testing.expectError(error.InvalidGameDatabase, db.saveChunk(.{ .cx = outside, .cy = 0 }, bits));
            try testing.expectError(error.InvalidGameDatabase, db.saveChunk(.{ .cx = 0, .cy = outside }, bits));
            if (!legacy) {
                try testing.expectError(error.SqliteConstraint, db.exec(std.fmt.comptimePrint("INSERT INTO game_chunks VALUES ({d}, 0, zeroblob(32))", .{outside})));
                try testing.expectError(error.SqliteConstraint, db.exec(std.fmt.comptimePrint("INSERT INTO game_chunks VALUES (0, {d}, zeroblob(32))", .{outside})));
            }
        }
        try expectUserChecks(&db);
    }
}

const unchecked_users = "DROP TABLE game_users; CREATE TABLE game_users (pubkey BLOB NOT NULL PRIMARY KEY, x INTEGER NOT NULL, y INTEGER NOT NULL, channel_id BLOB) WITHOUT ROWID;";

test "game database startup rejects malformed gameplay rows without rewriting" {
    for ([_][:0]const u8{
        "INSERT INTO game_chunks VALUES (0, 0, zeroblob(31))",
        "INSERT INTO game_chunks VALUES (2147483648, 0, zeroblob(32))",
        "INSERT INTO game_users VALUES (zeroblob(32), 0, 0, NULL)",
        "INSERT INTO game_users VALUES (zeroblob(33), 'not an integer', 0, NULL)",
        "INSERT INTO game_users VALUES (zeroblob(33), 0, -2147483649, NULL)",
        "INSERT INTO game_users VALUES (zeroblob(33), 0, 0, zeroblob(31))",
        // Legacy CHECKs and structural integrity alone accept these rows.
        legacy_chunks ++ std.fmt.comptimePrint("INSERT INTO game_chunks VALUES ({d}, 0, zeroblob(32))", .{protocol.max_chunk + 1}),
        legacy_chunks ++ std.fmt.comptimePrint("INSERT INTO game_chunks VALUES (0, {d}, zeroblob(32))", .{protocol.min_chunk - 1}),
        "DROP TABLE game_users;" ++ narrow_users_ddl ++ "; INSERT INTO game_users VALUES (zeroblob(33), 2147483648, 0, NULL)",
        // A structural integrity check alone also accepts these malformed rows.
        "DROP TABLE game_chunks; CREATE TABLE game_chunks (cx INTEGER NOT NULL, cy INTEGER NOT NULL, bits BLOB NOT NULL, PRIMARY KEY (cx, cy)) WITHOUT ROWID; INSERT INTO game_chunks VALUES (0, 0, zeroblob(31))",
        unchecked_users ++ "INSERT INTO game_users VALUES (zeroblob(33), 0, 0, zeroblob(31))",
        unchecked_users ++ "INSERT INTO game_users VALUES (zeroblob(33), 2147483648, 0, NULL)",
        unchecked_users ++ "INSERT INTO game_users VALUES (zeroblob(33), 0, -2147483649, NULL)",
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
    try testing.expectError(error.SqliteConstraint, db.exec("INSERT INTO game_users VALUES (zeroblob(32), 0, 0, NULL)"));
    try testing.expectError(error.SqliteConstraint, db.exec("INSERT INTO game_users VALUES (zeroblob(33), 0, 0, zeroblob(33))"));
    try db.begin();
    try testing.expectError(error.SqliteBusy, other.begin());
    db.rollback();
    try other.begin();
    try other.commit();
}
