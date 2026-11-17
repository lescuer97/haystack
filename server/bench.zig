//! Explicit opt-in socket-free real-file benchmark. Numeric IDs are u128 little-endian.
const std = @import("std");
const shared = @import("shared");
const storage = @import("storage.zig");
const actions = @import("actions.zig");
const Fixture = @import("fixture.zig").Fixture;
const App = @import("app.zig").App;
const c = storage.c;
const Timespec = extern struct { sec: i64, ns: i64 };
extern "c" fn clock_gettime(c_int, *Timespec) c_int;
fn now() u64 {
    var t: Timespec = undefined;
    _ = clock_gettime(1, &t);
    return @intCast(t.sec * 1000000000 + t.ns);
}
const WriteProfile = struct {
    durations: [7]u64 = @splat(0),
    active: ?storage.WriteStage = null,
    started: u64 = 0,
    previous: u64 = 0,
    total: u64 = 0,
    outcome: []const u8 = "unfinished",
    code: u16 = 0,
    pub fn start(self: *@This()) void {
        self.started = now();
        self.previous = self.started;
    }
    pub fn stage(self: *@This(), next: storage.WriteStage) void {
        const time = now();
        if (self.active) |active| self.durations[@backingInt(active)] += time - self.previous;
        self.active = next;
        self.previous = time;
    }
    pub fn finish(self: *@This(), err: ?anyerror, result: ?shared.protocol.CutResult) void {
        const time = now();
        if (self.active) |active| self.durations[@backingInt(active)] += time - self.previous;
        self.total = time - self.started;
        self.active = null;
        self.outcome = if (err) |e| @errorName(e) else if (result.? == .success) "success" else "rule_failure";
        self.code = if (result) |r| if (r == .failure) @backingInt(r.failure.code) else 0 else 0;
    }
};
const Worker = struct {
    app: *App,
    mode: []const u8,
    run: usize,
    thread: usize = 0,
    iterations: usize,
    profile: bool = false,
    fn go(self: *@This(), comptime profile_enabled: bool) !void {
        for (0..self.iterations + 8) |i| {
            const req = if (std.mem.eql(u8, self.mode, "sparse") or std.mem.eql(u8, self.mode, "dense"))
                shared.protocol.Request{ .request_id = storage.request(i, 0, 0).request_id, .operation = .{ .read_area = .{ .cx0 = 0, .cy0 = 0, .cx1 = 7, .cy1 = 7 } } }
            else
                storage.request(
                    1000000 + self.run * 10000 + self.thread * 1000 + i,
                    if (std.mem.eql(u8, self.mode, "replay")) 0 else if (std.mem.eql(u8, self.mode, "rule")) -128 else @intCast(100000 + i),
                    if (std.mem.eql(u8, self.mode, "replay")) 0 else if (std.mem.eql(u8, self.mode, "rule")) -128 else @intCast(self.thread + self.run * 4),
                );
            var input: [36]u8 = undefined;
            const data = shared.wire.encodeRequest(&input, req);
            if (std.mem.eql(u8, self.mode, "replay")) {
                const context = self.app.lease().?;
                _ = context.handle(req);
                self.app.release(context);
            }
            const start = now();
            const decoded = shared.wire.decode(data).request;
            const dbstart = now();
            const context = self.app.lease() orelse return error.NoContext;
            var profile: if (profile_enabled) WriteProfile else void = if (profile_enabled) .{} else {};
            const response = if (profile_enabled) blk: {
                const result = context.db.cutObserved(decoded, &profile) catch |err| break :blk shared.wire.failure(decoded.request_id, if (err == error.DatabaseBusy) .database_busy else .internal_error);
                break :blk shared.protocol.Response{ .request_id = decoded.request_id, .result = switch (result) {
                    .success => |state| .{ .cut = state },
                    .failure => |failure| .{ .failure = failure },
                } };
            } else actions.handle(&context.db, &context.snapshot, decoded);
            const dbend = now();
            const bytes = shared.wire.encode(&context.response, response).len;
            self.app.release(context);
            const end = now();
            if (!profile_enabled and response.result == .failure and response.result.failure.code == .internal_error) return error.BenchmarkDatabaseFailure;
            const code: u16 = if (response.result == .failure) @backingInt(response.result.failure.code) else 0;
            if (i >= 8) {
                if (profile_enabled) {
                    std.debug.print("WRITE_PROFILE,{s},{d},{d},{d},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{ self.mode, self.run, self.thread, i - 8, profile.outcome, profile.code, profile.durations[0], profile.durations[1], profile.durations[2], profile.durations[3], profile.durations[4], profile.durations[5], profile.durations[6], profile.total });
                } else std.debug.print("RAW,{s},{d},{d},{d},{d},{d},{d},{d}\n", .{ self.mode, self.run, self.thread, i - 8, end - start, dbend - dbstart, bytes, code });
            }
        }
    }
    fn entry(self: *@This()) void {
        if (self.profile) self.go(true) catch @panic("benchmark failed") else self.go(false) catch @panic("benchmark failed");
    }
};
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--area-query-stress")) return areaQueryStress(init);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--write-profile")) {
        const iterations = if (args.len == 3) try std.fmt.parseInt(usize, args[2], 10) else 128;
        if (args.len > 3 or iterations < 16 or iterations > 512) return error.ExpectedIterations16To512;
        return run(init, iterations, true);
    }
    const iterations = if (args.len == 2) try std.fmt.parseInt(usize, args[1], 10) else 128;
    if (args.len > 2 or iterations < 16 or iterations > 512) return error.ExpectedIterations16To512;
    try run(init, iterations, false);
}
fn areaQueryStress(init: std.process.Init) !void {
    var fixture = try Fixture.initWith(init.gpa, init.io, @import("sqlite_runtime.zig").default_budget);
    defer fixture.deinit();
    const db = &fixture.application.contexts[0].db;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try std.Io.Dir.cwd().realPathFile(init.io, fixture.path, &path_buffer);
    std.debug.print("AREA_STRESS,sqlite={s},fixture={s}\n", .{ c.sqlite3_libversion(), path_buffer[0..path_len] });
    // One bounded transaction, eight matching columns, all million historical
    // rows outside the requested cy range. No legacy query is shipped or timed.
    try db.exec("BEGIN IMMEDIATE; WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<999999) INSERT INTO chunk_state SELECT i%8,100+i/8,zeroblob(32) FROM n; COMMIT;");
    var stmt = c.sqlite3_next_stmt(db.db, null);
    while (stmt) |s| : (stmt = c.sqlite3_next_stmt(db.db, s)) {
        if (std.mem.startsWith(u8, std.mem.span(c.sqlite3_sql(s)), "SELECT cx,cy,cuts FROM chunk_state WHERE cx")) break;
    }
    const area_stmt = stmt orelse return error.MissingAreaStatement;
    var explain_buffer: [1024]u8 = undefined;
    const sql = try std.fmt.bufPrintSentinel(&explain_buffer, "EXPLAIN QUERY PLAN {s}", .{c.sqlite3_sql(area_stmt)}, 0);
    var explain: ?*c.sqlite3_stmt = null;
    try check(c.sqlite3_prepare_v2(db.db, sql, -1, &explain, null));
    {
        defer _ = c.sqlite3_finalize(explain);
        if (c.sqlite3_step(explain) != c.SQLITE_ROW) return error.ExplainFailed;
        const plan = std.mem.span(c.sqlite3_column_text(explain, 3));
        std.debug.print("AREA_STRESS,plan={s}\n", .{plan});
        if (std.mem.indexOf(u8, plan, "USING PRIMARY KEY (cx=? AND cy>? AND cy<?)") == null) return error.UnboundedAreaQuery;
    }
    for (0..2) |inside| {
        if (inside == 1) try db.exec("INSERT INTO chunk_state VALUES(0,0,x'0100000000000000000000000000000000000000000000000000000000000000'),(7,7,x'0100000000000000000000000000000000000000000000000000000000000000')");
        const context = fixture.application.lease() orelse return error.NoContext;
        defer fixture.application.release(context);
        _ = c.sqlite3_stmt_status(area_stmt, c.SQLITE_STMTSTATUS_VM_STEP, 1);
        const start = now();
        const response = actions.handle(&context.db, &context.snapshot, .{ .request_id = @splat(0), .operation = .{ .read_area = .{ .cx0 = 0, .cy0 = 0, .cx1 = 7, .cy1 = 7 } } });
        const elapsed = now() - start;
        const steps = c.sqlite3_stmt_status(area_stmt, c.SQLITE_STMTSTATUS_VM_STEP, 1);
        if (response.result != .snapshot) return error.SnapshotFailed;
        var bits: usize = 0;
        for (context.snapshot.chunks) |chunk| for (chunk) |byte| {
            bits += @popCount(byte);
        };
        if (bits != inside * 2 or context.snapshot.count != 64 or steps >= 2000) return error.IncorrectAreaQuery;
        const bytes = shared.wire.encode(&context.response, response);
        const hash = std.hash.Wyhash.hash(0, bytes);
        std.debug.print("AREA_STRESS,outside=1000000,inside={d},outcome=snapshot,chunks={d},bits={d},reply_bytes={d},hash={x},vm_steps={d},ns={d},sqlite_current={d},sqlite_highwater={d},ceiling={d}\n", .{ inside * 2, context.snapshot.count, bits, bytes.len, hash, steps, elapsed, c.sqlite3_memory_used(), fixture.runtime.highWater(), fixture.heap.len });
    }
}
fn run(init: std.process.Init, iterations: usize, profile: bool) !void {
    if (profile) {
        std.debug.print("WRITE_PROFILE_SEMANTICS,ns;begin=acquisition_execution_plus_wait;rules=terrain_chunk_read_rule;commit=includes_default_autocheckpoint;cleanup=reset_clear_rollback;total=storage_entry_through_cleanup;skipped=0\n", .{});
        std.debug.print("WRITE_PROFILE_HEADER,workload,run,thread,index,outcome,result_code,begin_ns,replay_ns,rules_ns,chunk_upsert_ns,result_insert_ns,commit_ns,cleanup_ns,total_ns\n", .{});
    }
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPath(init.io, &cwd_buffer);
    std.debug.print("BENCH_CWD,{s}\n", .{cwd_buffer[0..cwd_len]});
    std.debug.print("SQLITE,{s}\n", .{c.sqlite3_libversion()});
    std.debug.print("SOURCE,{s}\n", .{c.sqlite3_sourceid()});
    var option: c_int = 0;
    while (true) : (option += 1) {
        const name = c.sqlite3_compileoption_get(option);
        if (name == null) break;
        std.debug.print("OPTION,{s}\n", .{name});
    }
    for ([_][]const u8{ "new", "replay", "rule", "sparse", "dense", "contention" }) |mode| {
        if (profile and (std.mem.eql(u8, mode, "sparse") or std.mem.eql(u8, mode, "dense"))) continue;
        var fixture = try Fixture.initWith(init.gpa, init.io, @import("sqlite_runtime.zig").default_budget);
        defer fixture.deinit();
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path_len = try std.Io.Dir.cwd().realPathFile(init.io, fixture.path, &path_buffer);
        std.debug.print("FIXTURE,{s},{s}\n", .{ mode, path_buffer[0..path_len] });
        const db = &fixture.application.contexts[0].db;
        if (std.mem.eql(u8, mode, "sparse") or std.mem.eql(u8, mode, "dense")) {
            try db.exec("BEGIN IMMEDIATE");
            var stmt: ?*c.sqlite3_stmt = null;
            try check(c.sqlite3_prepare_v2(db.db, "INSERT INTO chunk_state VALUES(?,?,?)", -1, &stmt, null));
            var bitmaps: [64][32]u8 = @splat(@splat(0));
            var logical_cuts: usize = 0;
            for (0..128) |y| for (0..128) |x| {
                const terrain = shared.world.sampleTile(shared.world.public_seed, @intCast(x), @intCast(y));
                if (terrain != .grass and terrain != .tree) continue;
                if (std.mem.eql(u8, mode, "sparse") and (y * 128 + x) % 97 != 0) continue;
                logical_cuts += 1;
                const index = y / 16 * 8 + x / 16;
                const bit = y % 16 * 16 + x % 16;
                bitmaps[index][bit / 8] |= @as(u8, 1) << @as(u3, @intCast(bit % 8));
            };
            if (logical_cuts != @as(usize, if (std.mem.eql(u8, mode, "sparse")) 147 else 14045)) return error.SeedChanged;
            for (&bitmaps, 0..) |*bitmap, index| {
                if (std.mem.allEqual(u8, bitmap, 0)) continue;
                try check(c.sqlite3_bind_int(stmt, 1, @intCast(index % 8)));
                try check(c.sqlite3_bind_int(stmt, 2, @intCast(index / 8)));
                try storage.bindBitmap(stmt.?, 3, bitmap);
                if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SeedFailed;
                try check(c.sqlite3_reset(stmt));
                try check(c.sqlite3_clear_bindings(stmt));
            }
            try check(c.sqlite3_finalize(stmt));
            try db.exec("COMMIT");
        }
        for (0..3) |run_index| {
            if (std.mem.eql(u8, mode, "contention")) {
                var workers: [4]Worker = undefined;
                var threads: [4]std.Thread = undefined;
                for (&workers, 0..) |*w, t| {
                    w.* = .{ .app = &fixture.application, .mode = mode, .run = run_index, .thread = t, .iterations = iterations, .profile = profile };
                    threads[t] = try std.Thread.spawn(.{}, Worker.entry, .{w});
                }
                for (threads) |thread| thread.join();
            } else {
                var worker = Worker{ .app = &fixture.application, .mode = mode, .run = run_index, .iterations = iterations, .profile = profile };
                if (profile) try worker.go(true) else try worker.go(false);
            }
        }
        std.debug.print("BUDGET,{s},sqlite_highwater={d},app_context_bytes={d}\n", .{ mode, fixture.runtime.highWater(), @sizeOf([4]@import("app.zig").Context) });
    }
}
fn check(rc: c_int) !void {
    if (rc != c.SQLITE_OK) return error.DatabaseFailure;
}
