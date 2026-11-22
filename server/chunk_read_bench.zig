//! Single-connection chunk read benchmark. Uses a private, disposable SQLite file.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const GameDb = @import("game_db.zig").GameDb;
const Persistence = @import("persistence.zig").Persistence;
const Registry = @import("sessions.zig").Registry;
const WorldState = @import("world_state.zig").WorldState;
const ChunkRange = shared.world.ChunkRange;
const Timestamp = std.Io.Clock.Timestamp;

const sample_count = 256;
// Even with max-sized requests, each batch is below the eviction threshold.
const samples_per_cache = 64;
const max_side = 8;
const fixture_chunks = sample_count * max_side * max_side;
const bitmap: [p.chunk_bytes]u8 = @splat(0x5a);

const Samples = struct {
    prepare: [sample_count]u64 = undefined,
    total: [sample_count]u64 = undefined,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    var nonce: [12]u8 = undefined;
    try io.randomSecure(&nonce);
    const temp_root = init.environ_map.get("TMPDIR") orelse "/tmp";
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "haystack-chunk-bench-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
    const dir = try std.fs.path.join(allocator, &.{ temp_root, name });
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDir(io, dir, .fromMode(0o700));
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch |err|
        std.log.warn("could not remove benchmark directory {s}: {s}", .{ dir, @errorName(err) });
    const path = try std.fs.path.joinZ(allocator, &.{ dir, "game.sqlite" });
    defer allocator.free(path);
    try seed(path);

    var db = try GameDb.open(path);
    defer db.close();
    var registry: Registry = .{ .io = io };
    var world: WorldState = undefined;
    var persistence = try Persistence.init(io, allocator, &db, &world, &registry);
    defer persistence.deinit(allocator);

    var output_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    const out = &stdout.interface;
    try out.print("# fixtures={d} stored chunks, {d} samples per case; one connection, OS cache not cleared\n", .{ fixture_chunks, sample_count });
    try out.writeAll("cache,chunks,stage,p50_ns,p95_ns,p99_ns,max_ns\n");
    for ([_]i32{ 1, 4, max_side }) |side| {
        var misses: Samples = .{};
        var hits: Samples = .{};
        for (0..sample_count) |i| {
            if (i % samples_per_cache == 0) {
                world.deinit(allocator);
                world = try WorldState.initPersistent(allocator);
            }
            const area = sampleArea(i, side);
            try measure(&persistence, area, &misses, i);
            try measure(&persistence, area, &hits, i);
        }
        const chunks = side * side;
        try report(out, "sqlite_miss", chunks, "prepare", &misses.prepare);
        try report(out, "sqlite_miss", chunks, "total", &misses.total);
        try report(out, "ram_hit", chunks, "prepare", &hits.prepare);
        try report(out, "ram_hit", chunks, "total", &hits.total);
    }
    try out.flush();
}

fn sampleArea(i: usize, side: i32) ChunkRange {
    const x: i32 = @intCast((i % samples_per_cache) * max_side);
    const y: i32 = @intCast((i / samples_per_cache) * max_side);
    return .{ .cx0 = x, .cy0 = y, .cx1 = x + side - 1, .cy1 = y + side - 1 };
}

fn seed(path: [:0]const u8) !void {
    var db = try GameDb.open(path);
    defer db.close();
    try db.begin();
    errdefer db.rollback();
    for (0..sample_count) |i| {
        const area = sampleArea(i, max_side);
        for (0..max_side) |y| for (0..max_side) |x| {
            try db.saveChunk(.{ .cx = area.cx0 + @as(i32, @intCast(x)), .cy = area.cy0 + @as(i32, @intCast(y)) }, bitmap);
        };
    }
    try db.commit();
}

fn measure(persistence: *Persistence, area: ChunkRange, samples: *Samples, i: usize) !void {
    const io = persistence.io;
    const request: p.Request = .{ .request_id = @splat(0), .operation = .{ .read_area = area } };
    var snapshot: p.Snapshot = undefined;
    const start: Timestamp = .now(io, .awake);
    var pins = try persistence.prepare(request);
    errdefer persistence.release(&pins);
    const prepared: Timestamp = .now(io, .awake);
    try persistence.world.readArea(area, &snapshot);
    persistence.release(&pins);
    const end: Timestamp = .now(io, .awake);
    samples.prepare[i] = @intCast(start.durationTo(prepared).raw.nanoseconds);
    samples.total[i] = @intCast(start.durationTo(end).raw.nanoseconds);

    if (snapshot.count != (try p.areaGeometry(area)).count) return error.UnexpectedSnapshot;
    for (snapshot.chunks[0..snapshot.count]) |*bits| {
        if (!std.mem.eql(u8, bits, &bitmap)) return error.UnexpectedBitmap;
    }
}

fn report(out: *std.Io.Writer, cache: []const u8, chunks: i32, stage: []const u8, samples: []u64) !void {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    try out.print("{s},{d},{s},{d},{d},{d},{d}\n", .{
        cache,                    chunks,                  stage,
        percentile(samples, 50),  percentile(samples, 95), percentile(samples, 99),
        samples[samples.len - 1],
    });
}

fn percentile(sorted: []const u64, percent: usize) u64 {
    return sorted[(sorted.len * percent + 99) / 100 - 1];
}
