//! SQLite's global lifecycle. Caller closes every DB before stop; tests serialize fixtures.
const std = @import("std");
pub const c = @import("sqlite").c;
pub const default_budget = 4 * 1024 * 1024;
pub const Runtime = struct {
    heap: []align(8) u8,
    pub fn start(heap: []align(8) u8) !Runtime {
        if (heap.len < 65536 or heap.len > std.math.maxInt(c_int)) return error.InvalidSqliteBudget;
        if (c.sqlite3_config(c.SQLITE_CONFIG_HEAP, heap.ptr, @as(c_int, @intCast(heap.len)), @as(c_int, 64)) != c.SQLITE_OK) return error.SqliteHeapConfigurationFailed;
        if (c.sqlite3_config(c.SQLITE_CONFIG_MULTITHREAD) != c.SQLITE_OK) return error.SqliteThreadConfigurationFailed;
        if (c.sqlite3_initialize() != c.SQLITE_OK) {
            _ = c.sqlite3_shutdown();
            return error.SqliteInitializationFailed;
        }
        _ = c.sqlite3_memory_highwater(1);
        return .{ .heap = heap };
    }
    pub fn stop(_: *Runtime) void {
        std.debug.assert(c.sqlite3_shutdown() == c.SQLITE_OK);
    }
    pub fn highWater(_: *const Runtime) usize {
        return @intCast(c.sqlite3_memory_highwater(0));
    }
};
