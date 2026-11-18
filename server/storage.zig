//! Exclusive leased connection with cached SQL and checked cleanup. No request allocator.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const world = shared.world;
pub const c = @import("sqlite").c;
const rules = @import("actions.zig");
pub const busy_timeout_ms = 250;
const schema_version = 4;
pub const DbError = error{ DatabaseBusy, DatabaseFailure, SqliteOutOfMemory, IncompatibleDatabase, PoisonedConnection };
pub const WriteStage = enum { begin, replay, rules, chunk_upsert, result_insert, commit, cleanup };
const Unobserved = struct {
    fn start(_: @This()) void {}
    fn stage(_: @This(), _: WriteStage) void {}
    fn finish(_: @This(), _: ?anyerror, _: ?p.CutResult) void {}
};
const Sql = enum { begin, commit, rollback, replay, chunk_lookup, chunk_upsert, insert_result, area };
const queries = [_][:0]const u8{
    "BEGIN IMMEDIATE",
    "COMMIT",
    "ROLLBACK",
    "SELECT version,operation,x,y,result,terrain FROM action_results WHERE request_id=?",
    "SELECT cuts FROM chunk_state WHERE cx=? AND cy=?",
    "INSERT INTO chunk_state(cx,cy,cuts) VALUES(?,?,?) ON CONFLICT(cx,cy) DO UPDATE SET cuts=excluded.cuts",
    "INSERT INTO action_results(request_id,version,operation,x,y,result,terrain) VALUES(?,?,1,?,?,?,?)",
    "SELECT cx,cy,cuts FROM chunk_state WHERE cx IN (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,?36,?37,?38,?39,?40,?41,?42,?43,?44,?45,?46,?47,?48,?49,?50,?51,?52,?53,?54,?55,?56,?57,?58,?59,?60,?61,?62,?63,?64) AND cy BETWEEN ?65 AND ?66",
};
const Cached = struct { ptr: ?*c.sqlite3_stmt = null, last: c_int = c.SQLITE_OK };
pub const Storage = struct {
    db: ?*c.sqlite3,
    poisoned: bool = false,
    statements: [queries.len]Cached = @splat(.{}),
    pub fn open(path: [:0]const u8) !Storage {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX, null);
        if (rc != c.SQLITE_OK) {
            if (db != null) _ = c.sqlite3_close_v2(db);
            try check(rc);
            return error.DatabaseFailure;
        }
        var self = Storage{ .db = db };
        errdefer self.close();
        try check(c.sqlite3_busy_timeout(db, busy_timeout_ms));
        // Bound each connection's page cache; keep FULL durability, WAL defaults unchanged.
        try self.exec("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA cache_size=-256; PRAGMA temp_store=MEMORY;");
        return self;
    }
    pub fn close(self: *Storage) void {
        for (&self.statements) |*s| {
            if (s.ptr) |statement| _ = c.sqlite3_finalize(statement);
            s.* = .{};
        }
        if (self.db) |db| _ = c.sqlite3_close_v2(db);
        self.db = null;
        self.poisoned = true;
    }
    pub fn initialize(self: *Storage) !void {
        const wal = try self.prepare("PRAGMA journal_mode=WAL");
        {
            defer _ = c.sqlite3_finalize(wal);
            if (c.sqlite3_step(wal) != c.SQLITE_ROW or !std.mem.eql(u8, text(wal, 0), "wal")) return error.DatabaseFailure;
        }
        try self.exec("BEGIN IMMEDIATE");
        errdefer {
            self.exec("ROLLBACK") catch {};
        }
        const existing = try self.prepare("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
        const fresh = blk: {
            defer _ = c.sqlite3_finalize(existing);
            if (c.sqlite3_step(existing) != c.SQLITE_ROW) return error.DatabaseFailure;
            break :blk c.sqlite3_column_int(existing, 0) == 0;
        };
        if (fresh) try self.exec("CREATE TABLE metadata(id INTEGER PRIMARY KEY CHECK(id=1),schema_version INTEGER NOT NULL,generator_version INTEGER NOT NULL,public_seed BLOB NOT NULL CHECK(length(public_seed)=32)) STRICT;" ++
            std.fmt.comptimePrint("INSERT INTO metadata VALUES(1,{d},{d},zeroblob(32));", .{ schema_version, world.generator_version }) ++
            "CREATE TABLE chunk_state(cx INTEGER NOT NULL CHECK(cx BETWEEN -134217728 AND 134217727),cy INTEGER NOT NULL CHECK(cy BETWEEN -134217728 AND 134217727),cuts BLOB NOT NULL CHECK(length(cuts)=32),PRIMARY KEY(cx,cy)) STRICT, WITHOUT ROWID;" ++
            "CREATE TABLE action_results(request_id BLOB PRIMARY KEY CHECK(length(request_id)=16),version INTEGER NOT NULL,operation INTEGER NOT NULL CHECK(operation=1),x INTEGER NOT NULL,y INTEGER NOT NULL,result INTEGER NOT NULL CHECK(result BETWEEN 0 AND 2),terrain INTEGER NOT NULL CHECK(terrain BETWEEN 0 AND 4)) STRICT;");
        const meta = self.prepare("SELECT schema_version,generator_version,public_seed FROM metadata WHERE id=1") catch |err| {
            if (err == error.SqliteOutOfMemory) return err;
            return error.IncompatibleDatabase;
        };
        {
            defer _ = c.sqlite3_finalize(meta);
            if (c.sqlite3_step(meta) != c.SQLITE_ROW or c.sqlite3_column_int(meta, 0) != schema_version or c.sqlite3_column_int(meta, 1) != world.generator_version) return error.IncompatibleDatabase;
            if (c.sqlite3_column_bytes(meta, 2) != 32) return error.IncompatibleDatabase;
            const bytes: [*]const u8 = @ptrCast(c.sqlite3_column_blob(meta, 2) orelse return error.IncompatibleDatabase);
            if (!std.mem.eql(u8, bytes[0..32], &world.public_seed)) return error.IncompatibleDatabase;
        }
        try self.exec("COMMIT");
    }
    pub fn ready(self: *Storage) !void {
        for (queries, &self.statements) |query, *s| s.ptr = try self.prepare(query);
    }
    fn ptr(self: *Storage, sql: Sql) *c.sqlite3_stmt {
        return self.statements[@backingInt(sql)].ptr.?;
    }
    fn step(self: *Storage, sql: Sql) !c_int {
        const s = &self.statements[@backingInt(sql)];
        s.last = c.sqlite3_step(s.ptr);
        if (s.last != c.SQLITE_ROW and s.last != c.SQLITE_DONE) try check(s.last);
        return s.last;
    }
    fn reset(self: *Storage, sql: Sql) !void {
        const s = &self.statements[@backingInt(sql)];
        const rc = c.sqlite3_reset(s.ptr);
        const previous = s.last;
        s.last = c.SQLITE_OK;
        const clear = c.sqlite3_clear_bindings(s.ptr);
        // reset normally repeats a failed step's code; this is not a new poison.
        if (clear != c.SQLITE_OK or (rc != c.SQLITE_OK and rc != previous)) {
            self.poisoned = true;
            return error.PoisonedConnection;
        }
    }
    fn done(self: *Storage, sql: Sql) !void {
        const rc = self.step(sql) catch |err| {
            try self.reset(sql);
            return err;
        };
        try self.reset(sql);
        if (rc != c.SQLITE_DONE) return error.DatabaseFailure;
    }
    fn cleanup(self: *Storage) void {
        // Clear SQLITE_STATIC IDs before request storage can be reused.
        for (0..queries.len) |i| self.reset(@fromBackingInt(@intCast(i))) catch {};
        if (c.sqlite3_get_autocommit(self.db) == 0) {
            self.done(.rollback) catch {
                self.poisoned = true;
            };
            if (c.sqlite3_get_autocommit(self.db) == 0) self.poisoned = true;
        }
    }
    pub fn cut(self: *Storage, req: p.Request) !p.CutResult {
        return self.cutObserved(req, Unobserved{});
    }
    /// Observer callbacks are specialized away for production. finish is called
    /// once, after checked cleanup, with the actual storage error or rule result.
    pub fn cutObserved(self: *Storage, req: p.Request, observer: anytype) !p.CutResult {
        observer.start();
        if (self.poisoned) {
            observer.stage(.cleanup);
            observer.finish(error.PoisonedConnection, null);
            return error.PoisonedConnection;
        }
        const result = self.cutBody(&req, observer) catch |err| {
            observer.stage(.cleanup);
            self.cleanup();
            observer.finish(err, null);
            return err;
        };
        observer.stage(.cleanup);
        self.cleanup();
        if (self.poisoned) {
            observer.finish(error.PoisonedConnection, null);
            return error.PoisonedConnection;
        }
        observer.finish(null, result);
        return result;
    }
    fn cutBody(self: *Storage, req: *const p.Request, observer: anytype) !p.CutResult {
        if (self.poisoned) return error.PoisonedConnection;
        observer.stage(.begin);
        try self.done(.begin);
        observer.stage(.replay);
        if (try self.replay(req)) |result| {
            if (self.poisoned) return error.PoisonedConnection;
            observer.stage(.commit);
            try self.done(.commit);
            return result;
        }
        if (self.poisoned) return error.PoisonedConnection;
        observer.stage(.rules);
        const tile = req.operation.cut;
        const terrain = world.sampleTile(world.public_seed, tile.x, tile.y);
        const cx = @divFloor(tile.x, 16);
        const cy = @divFloor(tile.y, 16);
        const bit: usize = @intCast(@mod(tile.y, 16) * 16 + @mod(tile.x, 16));
        const mask = @as(u8, 1) << @as(u3, @intCast(bit % 8));
        var bitmap: [32]u8 = @splat(0);
        const s = self.ptr(.chunk_lookup);
        try bindInt(s, 1, cx);
        try bindInt(s, 2, cy);
        if (try self.step(.chunk_lookup) == c.SQLITE_ROW) @memcpy(&bitmap, try blob(s, 0));
        try self.reset(.chunk_lookup);
        const cut_already = bitmap[bit / 8] & mask != 0;
        const result = rules.cutRule(.{ .x = tile.x, .y = tile.y, .terrain = terrain, .cut = cut_already });
        if (result == .success) {
            observer.stage(.chunk_upsert);
            bitmap[bit / 8] |= mask;
            const insert = self.ptr(.chunk_upsert);
            try bindInt(insert, 1, cx);
            try bindInt(insert, 2, cy);
            try bindBitmap(insert, 3, &bitmap);
            try self.done(.chunk_upsert);
        }
        observer.stage(.result_insert);
        const insert = self.ptr(.insert_result);
        try bindId(insert, 1, &req.request_id);
        try bindInt(insert, 2, req.version);
        try bindInt(insert, 3, tile.x);
        try bindInt(insert, 4, tile.y);
        try bindInt(insert, 5, switch (result) {
            .success => @as(i32, 0),
            .failure => |f| if (f.code == .already_cut) @as(i32, 2) else @as(i32, 1),
        });
        try bindInt(insert, 6, @backingInt(terrain));
        try self.done(.insert_result);
        // Commit before any encoding or socket write. Never retry an uncertain action.
        observer.stage(.commit);
        try self.done(.commit);
        return result;
    }
    fn replay(self: *Storage, req: *const p.Request) !?p.CutResult {
        const s = self.ptr(.replay);
        try bindId(s, 1, &req.request_id);
        const result = self.replayRow(req) catch |err| {
            try self.reset(.replay);
            return err;
        };
        try self.reset(.replay);
        return result;
    }
    fn replayRow(self: *Storage, req: *const p.Request) !?p.CutResult {
        const s = self.ptr(.replay);
        if (try self.step(.replay) == c.SQLITE_DONE) return null;
        const tile = req.operation.cut;
        if (c.sqlite3_column_int(s, 0) != req.version or c.sqlite3_column_int(s, 1) != 1 or c.sqlite3_column_int64(s, 2) != tile.x or c.sqlite3_column_int64(s, 3) != tile.y) return .{ .failure = .{ .code = .request_id_conflict } };
        const terrain = std.enums.fromInt(world.Tile, c.sqlite3_column_int(s, 5)) orelse return error.DatabaseFailure;
        const state = p.State{ .x = tile.x, .y = tile.y, .terrain = terrain, .cut = true };
        return switch (c.sqlite3_column_int(s, 4)) {
            0 => .{ .success = state },
            1 => .{ .failure = .{ .code = .not_cuttable } },
            2 => .{ .failure = .{ .code = .already_cut, .current = state } },
            else => error.DatabaseFailure,
        };
    }
    pub fn readArea(self: *Storage, area: world.ChunkRange, out: *p.Snapshot) !void {
        if (self.poisoned) return error.PoisonedConnection;
        if (rules.validateArea(area) != null) return error.InvalidArea;
        self.readAreaBody(area, out) catch |err| {
            self.cleanup();
            return err;
        };
        self.cleanup();
        if (self.poisoned) return error.PoisonedConnection;
    }
    fn readAreaBody(self: *Storage, area: world.ChunkRange, out: *p.Snapshot) !void {
        const cols: usize = @intCast(@as(i64, area.cx1) - area.cx0 + 1);
        const rows: usize = @intCast(@as(i64, area.cy1) - area.cy0 + 1);
        out.* = .{ .area = area, .count = @intCast(cols * rows) };
        const s = self.ptr(.area);
        // Equality probes let the clustered primary key bound cy too, rather than scanning all
        // history in these columns. Duplicate padding does not duplicate rows.
        for (0..64) |i| try bindInt(s, @intCast(i + 1), @as(i64, area.cx0) + if (i < cols) @as(i64, @intCast(i)) else 0);
        try bindInt(s, 65, area.cy0);
        try bindInt(s, 66, area.cy1);
        // A single SELECT gives one consistent complete snapshot, no ORDER BY or heap lists.
        while (try self.step(.area) == c.SQLITE_ROW) {
            if (c.sqlite3_column_type(s, 0) != c.SQLITE_INTEGER or c.sqlite3_column_type(s, 1) != c.SQLITE_INTEGER) return error.DatabaseFailure;
            const cx = c.sqlite3_column_int64(s, 0);
            const cy = c.sqlite3_column_int64(s, 1);
            if (cx < -134217728 or cx > 134217727 or cy < -134217728 or cy > 134217727) return error.DatabaseFailure;
            if (cx < area.cx0 or cx > area.cx1 or cy < area.cy0 or cy > area.cy1) return error.DatabaseFailure;
            const bitmap = try blob(s, 2);
            const index: usize = @intCast((cy - area.cy0) * @as(i64, @intCast(cols)) + cx - area.cx0);
            @memcpy(&out.chunks[index], bitmap);
        }
    }
    pub fn exec(self: *Storage, sql: [:0]const u8) !void {
        try check(c.sqlite3_exec(self.db, sql, null, null, null));
    }
    fn prepare(self: *Storage, sql: [:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            if (stmt) |s| _ = c.sqlite3_finalize(s);
            try check(rc);
        }
        return stmt orelse error.DatabaseFailure;
    }
};
fn check(rc: c_int) DbError!void {
    return switch (rc & 255) {
        c.SQLITE_OK => {},
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.DatabaseBusy,
        c.SQLITE_NOMEM => error.SqliteOutOfMemory,
        else => error.DatabaseFailure,
    };
}
fn bindInt(s: *c.sqlite3_stmt, index: c_int, value: i64) !void {
    try check(c.sqlite3_bind_int64(s, index, value));
}
fn bindId(s: *c.sqlite3_stmt, index: c_int, value: *const p.Id) !void {
    try check(c.sqlite3_bind_blob(s, index, value, 16, null));
}
pub fn bindBitmap(s: *c.sqlite3_stmt, index: c_int, value: *const [32]u8) !void {
    // SQLITE_TRANSIENT: SQLite owns a copy inside its fixed memsys5 heap.
    try check(c.sqlite3_bind_blob(s, index, value, 32, @ptrFromInt(std.math.maxInt(usize))));
}
fn blob(s: *c.sqlite3_stmt, index: c_int) ![]const u8 {
    if (c.sqlite3_column_type(s, index) != c.SQLITE_BLOB or c.sqlite3_column_bytes(s, index) != 32) return error.DatabaseFailure;
    const bytes: [*]const u8 = @ptrCast(c.sqlite3_column_blob(s, index) orelse return error.DatabaseFailure);
    return bytes[0..32];
}
fn text(s: *c.sqlite3_stmt, index: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(s, index);
    return ptr[0..@intCast(c.sqlite3_column_bytes(s, index))];
}

pub fn request(id: u128, x: i32, y: i32) p.Request {
    var bytes: p.Id = undefined;
    std.mem.writeInt(u128, &bytes, id, .little);
    return .{ .request_id = bytes, .operation = .{ .cut = .{ .x = x, .y = y } } };
}
