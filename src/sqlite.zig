//! Database policy shared by the gameplay and channel stores.
const std = @import("std");
const c = @import("sqlite").c;

pub const OpenFlags = enum(c_int) {
    read_write_no_mutex = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_NOMUTEX,
    read_write_no_follow = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_NOFOLLOW,
};

pub const Db = opaque {
    pub fn open(path: [*:0]const u8, flags: OpenFlags, create: bool) !*Db {
        var handle: ?*c.sqlite3 = null;
        errdefer if (handle) |db| {
            _ = c.sqlite3_close_v2(db);
        };
        try check(c.sqlite3_open_v2(path, &handle, @backingInt(flags) | if (create) c.SQLITE_OPEN_CREATE else 0, null), c.SQLITE_OK);
        const db = handle orelse return error.SqliteFailure;
        // READWRITE can succeed by falling back to read-only on Unix.
        switch (c.sqlite3_db_readonly(db, "main")) {
            0 => return @ptrCast(db),
            1 => return error.SqliteReadOnly,
            else => return error.SqliteFailure,
        }
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close_v2(@ptrCast(self));
    }

    pub fn exec(self: *Db, sql: [*:0]const u8) !void {
        try check(c.sqlite3_exec(@ptrCast(self), sql, null, null, null), c.SQLITE_OK);
    }

    pub fn prepare(self: *Db, sql: [*:0]const u8) !*Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(@ptrCast(self), sql, -1, &stmt, null), c.SQLITE_OK);
        return @ptrCast(stmt orelse return error.SqliteFailure);
    }

    pub fn autocommit(self: *Db) bool {
        return c.sqlite3_get_autocommit(@ptrCast(self)) != 0;
    }

    pub fn changes(self: *Db) c_int {
        return c.sqlite3_changes(@ptrCast(self));
    }
};

pub const Stmt = opaque {
    pub fn finalize(self: *Stmt) void {
        // finalize can repeat a step error, which the caller already checked.
        _ = c.sqlite3_finalize(@ptrCast(self));
    }

    pub fn bindInt(self: *Stmt, index: c_int, value: i64) !void {
        try check(c.sqlite3_bind_int64(@ptrCast(self), index, value), c.SQLITE_OK);
    }

    pub fn bindUInt(self: *Stmt, index: c_int, value: u64) !void {
        try self.bindInt(index, std.math.cast(i64, value) orelse return error.SqliteFailure);
    }

    pub fn bindBlob(self: *Stmt, index: c_int, value: []const u8) !void {
        // SQLITE_TRANSIENT asks SQLite to copy the bound bytes immediately.
        const len = std.math.cast(c_int, value.len) orelse return error.SqliteFailure;
        try check(c.sqlite3_bind_blob(@ptrCast(self), index, value.ptr, len, c.sqliteTransientAsDestructor()), c.SQLITE_OK);
    }

    pub fn bindNull(self: *Stmt, index: c_int) !void {
        try check(c.sqlite3_bind_null(@ptrCast(self), index), c.SQLITE_OK);
    }

    pub fn next(self: *Stmt) !bool {
        const rc = c.sqlite3_step(@ptrCast(self));
        if (rc == c.SQLITE_ROW) return true;
        try check(rc, c.SQLITE_DONE);
        return false;
    }

    pub fn finish(self: *Stmt) !void {
        if (try self.next()) return error.InvalidSqliteData;
    }

    pub fn int(self: *Stmt, column: c_int) !i64 {
        if (c.sqlite3_column_type(@ptrCast(self), column) != c.SQLITE_INTEGER) return error.InvalidSqliteData;
        return c.sqlite3_column_int64(@ptrCast(self), column);
    }

    pub fn uint(self: *Stmt, column: c_int) !u64 {
        return std.math.cast(u64, try self.int(column)) orelse error.InvalidSqliteData;
    }

    pub fn isNull(self: *Stmt, column: c_int) bool {
        return c.sqlite3_column_type(@ptrCast(self), column) == c.SQLITE_NULL;
    }

    pub fn textEquals(self: *Stmt, column: c_int, expected: []const u8) bool {
        if (c.sqlite3_column_type(@ptrCast(self), column) != c.SQLITE_TEXT) return false;
        const text = c.sqlite3_column_text(@ptrCast(self), column);
        if (text == null) return false;
        const len: usize = @intCast(c.sqlite3_column_bytes(@ptrCast(self), column));
        return std.mem.eql(u8, text[0..len], expected);
    }

    /// The returned bytes borrow the current row and must not outlive it.
    pub fn blobSlice(self: *Stmt, column: c_int) ![]const u8 {
        if (c.sqlite3_column_type(@ptrCast(self), column) != c.SQLITE_BLOB) return error.InvalidSqliteData;
        const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(@ptrCast(self), column) orelse return error.InvalidSqliteData);
        return ptr[0..@intCast(c.sqlite3_column_bytes(@ptrCast(self), column))];
    }

    pub fn blob(self: *Stmt, comptime len: usize, column: c_int) ![len]u8 {
        const data = try self.blobSlice(column);
        if (data.len != len) return error.InvalidSqliteData;
        return data[0..len].*;
    }
};

fn check(rc: c_int, expected: c_int) !void {
    if (rc == expected) return;
    // Mask extended result codes to preserve the same error categories.
    return switch (rc & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.SqliteBusy,
        c.SQLITE_NOMEM => error.OutOfMemory,
        c.SQLITE_READONLY => error.SqliteReadOnly,
        c.SQLITE_IOERR => error.SqliteIo,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.InvalidSqliteData,
        c.SQLITE_FULL => error.SqliteFull,
        c.SQLITE_CANTOPEN => error.SqliteCannotOpen,
        c.SQLITE_CONSTRAINT => error.SqliteConstraint,
        else => error.SqliteFailure,
    };
}
