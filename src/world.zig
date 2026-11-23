//! Client resident world cache: shared terrain, streaming, ownership, and stats.
//!
//! This module deliberately does not import Raylib. Anything that needs a
//! window, a camera transform, or draw calls belongs in `camera.zig` or
//! `rendering.zig`. That keeps this cache headless-testable and independent of
//! the server or a window.
//!
//! The world is infinite. A chunk that is not resident simply does not exist
//! until the camera gets close enough to ask for it. Residency is therefore a
//! cache of generated chunks, not the world itself: the generator defines every
//! chunk deterministically, and `World` decides which ones are currently in
//! memory.

const std = @import("std");
const shared = @import("shared");
const terrain = shared.world;
const protocol = shared.protocol;

// ── world constants ──────────────────────────────────────────────────────────

/// One tile is 32×32 world pixels, rendered as terrain art with optional debug
/// grid lines and chunk borders in this space.
pub const TILE_PX = terrain.TILE_PX;

/// A chunk is 16×16 tiles (512×512 pixels).
pub const CHUNK_TILES = terrain.CHUNK_TILES;
pub const CHUNK_PX = terrain.CHUNK_PX;

/// Same value as `CHUNK_TILES`, typed for array indexing.
pub const CT = terrain.CT;

/// How many chunks beyond the visible range stay loaded.
pub const PREFETCH_MARGIN_CHUNKS: i32 = 2;

/// Small startup reserve; larger viewports preheat their full prefetch ring.
/// This is not a residency limit or a hard memory budget.
pub const MIN_PREHEATED_CHUNKS: usize = 64;

// ── tiles / chunks ───────────────────────────────────────────────────────────

pub const Tile = terrain.Tile;

pub const Chunk = struct {
    cx: i32 = 0,
    cy: i32 = 0,
    tiles: [CT * CT]Tile = undefined,
    // Keep the last rendered bitmap while a new session refreshes it.
    cuts: ?[protocol.chunk_bytes]u8 = null,
    cuts_stale: bool = false,

    pub fn cutsSynced(self: *const Chunk) bool {
        return self.cuts != null and !self.cuts_stale;
    }

    pub fn isCut(self: *const Chunk, index: usize) bool {
        const bits = if (self.cuts) |*value| value else return false;
        return bits[index / 8] & (@as(u8, 1) << @as(u3, @intCast(index % 8))) != 0;
    }
};

/// An inclusive rectangular range of chunk indices.
pub const ChunkRange = terrain.ChunkRange;

/// Expand a valid chunk range without prefetching outside the tile world.
pub fn expandChunkRange(range: ChunkRange, margin: i32) ChunkRange {
    std.debug.assert(margin >= 0);
    return .{
        .cx0 = @intCast(@max(protocol.min_chunk, @as(i64, range.cx0) - margin)),
        .cy0 = @intCast(@max(protocol.min_chunk, @as(i64, range.cy0) - margin)),
        .cx1 = @intCast(@min(protocol.max_chunk, @as(i64, range.cx1) + margin)),
        .cy1 = @intCast(@min(protocol.max_chunk, @as(i64, range.cy1) + margin)),
    };
}

pub fn residencyRange(vis: ChunkRange, minimap: ?ChunkRange) ChunkRange {
    const prefetch = expandChunkRange(vis, PREFETCH_MARGIN_CHUNKS);
    const map = minimap orelse return prefetch;
    return .{
        .cx0 = @min(prefetch.cx0, map.cx0),
        .cy0 = @min(prefetch.cy0, map.cy0),
        .cx1 = @max(prefetch.cx1, map.cx1),
        .cy1 = @max(prefetch.cy1, map.cy1),
    };
}

// ── coordinate validation ────────────────────────────────────────────────────

pub const CoordinateError = error{CoordinateOutOfBounds};

/// Validate absolute chunk bounds and the size of their clipped prefetch ring.
pub fn validateChunkRange(range: ChunkRange, margin: i32) CoordinateError!void {
    if (margin < 0 or range.cx0 > range.cx1 or range.cy0 > range.cy1 or
        range.cx0 < protocol.min_chunk or range.cy0 < protocol.min_chunk or
        range.cx1 > protocol.max_chunk or range.cy1 > protocol.max_chunk)
        return error.CoordinateOutOfBounds;

    const expanded = expandChunkRange(range, margin);
    const count = @as(i64, expanded.cols()) * expanded.rows();
    // A u32 hash table must round its bucket count up for spare capacity.
    // Also reject ranges whose chunk bytes cannot fit on 32-bit targets.
    const max_resident_chunks = @min(1 << 30, std.math.maxInt(usize) / @sizeOf(Chunk));
    if (count > max_resident_chunks) return error.CoordinateOutOfBounds;
}

// Deterministic terrain generation lives in shared/world.zig.

// ── private yield ────────────────────────────────────────────────────────────

// Keyed BLAKE3-256 is the standard PRF for private yields: 32-byte secret key,
// versioned domain tag, 8-byte little-endian coordinate payload, u64
// truncation. The public layout hash stays non-cryptographic (`hash2`); the two
// are deliberately separate functions with separate seeds.
const Blake3 = std.crypto.hash.Blake3;

/// Domain/version tag hashed before every private-yield payload. Changing the
/// encoding, coordinate meaning, or key derivation requires a new tag.
const private_yield_domain = "haystack.private-yield.v1";

/// Deterministic raw yield roll for one world tile under a secret server seed.
///
/// This is a keyed BLAKE3 PRF, not `hash2`: the seed is a secret, so the result
/// cannot be predicted by a client that only knows the public world seed.
///
/// - `private_seed` is a *separate* secret from the public layout seed used by
///   `hash2`/`generate`. Generate it independently with full entropy (32
///   bytes); never reuse the public seed as the private seed and never derive
///   the private seed from public information (layout seed, coordinates, or
///   anything a client can see). A future server keeps `private_seed`
///   private; the public seed may be shared with clients. No private seed
///   constant lives in production code.
/// - `x`/`y` are world tile coordinates, not pixels and not chunk-local
///   indices. The same coordinate always produces the same roll for a given
///   key; per-respawn identity (e.g. respawn IDs) is not implemented yet.
/// - The return value is a raw roll, not a final reward quantity. Mapping it to
///   reward weights and economy amounts happens elsewhere, later.
/// - Never use this for rendering, chunk layout, or anything a client must
///   reproduce locally.
///
/// The input is the domain tag followed by 8 payload bytes: `x` and `y` as
/// bit-preserving little-endian 32-bit fields, so negative coordinates hash
/// distinctly. The BLAKE3 key is `private_seed` itself: all 32 bytes in array
/// order, `private_seed[0]` first, with no integer or endian conversion applied
/// to the seed. The first 8 output bytes, read little endian, are returned.
/// Allocation-free and platform-independent.
pub fn privateYield(private_seed: [32]u8, x: i32, y: i32) u64 {
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], @bitCast(x), .little);
    std.mem.writeInt(u32, payload[4..8], @bitCast(y), .little);

    var hasher = Blake3.init(.{ .key = private_seed });
    hasher.update(private_yield_domain);
    hasher.update(&payload);

    var out: [8]u8 = undefined;
    hasher.final(&out);
    return std.mem.readInt(u64, &out, .little);
}

// ── resident storage and streaming ───────────────────────────────────────────

/// Standard-library pool of fixed-size chunks: O(1) create/destroy,
/// and the pool owns its backing memory.
const ChunkPool = std.heap.MemoryPool(Chunk);

/// Read-only summary of residency and memory. Rendering and tests consume this
/// instead of reaching into the map, pool, or scratch list.
pub const Stats = struct {
    resident_chunks: usize,
    wanted_chunks: usize,
    generated: u64,
    unloaded: u64,
    memory_pressure: bool,
    resident_bytes: usize,
    pool_backing_bytes: usize,
    map_slots: usize,
    scratch_keys: usize,
    scratch_bytes: usize,
};

/// Iterator over resident chunks. Values are const so read-only callers cannot
/// mutate a chunk through the iterator. The iterator is invalidated by any world
/// mutation; use it only while rendering read-only state.
pub const ResidentIterator = struct {
    inner: std.AutoHashMapUnmanaged(u64, *Chunk).ValueIterator,

    pub fn next(self: *ResidentIterator) ?*const Chunk {
        const slot_ptr = self.inner.next() orelse return null;
        return slot_ptr.*;
    }
};

pub const World = struct {
    /// Allocator used for the pool, map, and unload scratch list. Every buffer
    /// is returned by `deinit`.
    alloc: std.mem.Allocator,

    /// Preheated for the initial viewport; freed slots are reused on panning.
    pool: ChunkPool,

    /// Chunk key (cx,cy packed into a u64) -> resident chunk.
    by_key: std.AutoHashMapUnmanaged(u64, *Chunk) = .empty,

    generated: u64 = 0,
    unloaded: u64 = 0,
    cut_revision: u64 = 0,

    /// Desired residency, not the amount of memory retained by the pool.
    wanted: usize = 0,
    memory_pressure: bool = false,
    /// Set only when every chunk in this range is resident.
    completed_range: ?ChunkRange = null,

    /// Scratch list of keys to unload; capacity always covers all residents,
    /// so eviction never needs to allocate, even under memory pressure.
    doomed: std.ArrayListUnmanaged(u64) = .empty,

    pub fn init(alloc: std.mem.Allocator, initial_capacity: usize) !World {
        var world = World{
            .alloc = alloc,
            .pool = .empty,
        };
        errdefer world.deinit();

        world.pool = try ChunkPool.initCapacity(alloc, initial_capacity);
        try world.by_key.ensureTotalCapacity(alloc, @intCast(initial_capacity));
        try world.doomed.ensureTotalCapacityPrecise(alloc, initial_capacity);
        return world;
    }

    pub fn deinit(self: *World) void {
        self.doomed.deinit(self.alloc);
        self.by_key.deinit(self.alloc);
        self.pool.deinit(self.alloc);
    }

    fn keyOf(cx: i32, cy: i32) u64 {
        const x: u32 = @bitCast(cx);
        const y: u32 = @bitCast(cy);
        return (@as(u64, x) << 32) | y;
    }

    /// Reuse resident terrain; generate a chunk only on a cache miss.
    fn ensureLoaded(self: *World, cx: i32, cy: i32) std.mem.Allocator.Error!void {
        const key = keyOf(cx, cy);
        if (self.by_key.contains(key)) return;

        // Preserve allocation-free eviction even if a later allocation fails.
        try self.doomed.ensureTotalCapacity(self.alloc, @as(usize, self.by_key.count()) + 1);
        const chunk = try self.pool.create(self.alloc);
        errdefer self.pool.destroy(chunk);
        var base: terrain.Chunk = .{ .cx = cx, .cy = cy };
        terrain.generate(&base);
        chunk.* = .{ .cx = cx, .cy = cy, .tiles = base.tiles };
        try self.by_key.put(self.alloc, key, chunk);
        self.completed_range = null;
        self.generated += 1;
    }

    fn unload(self: *World, key: u64) void {
        const entry = self.by_key.fetchRemove(key) orelse return;
        // The map stores the item's natural alignment; the pool guarantees
        // the free-list alignment, so re-assert it here.
        self.pool.destroy(@alignCast(entry.value));
        self.completed_range = null;
        self.unloaded += 1;
    }

    /// Look up a resident chunk. Chunks that are not resident return `null`;
    /// they can be regenerated deterministically when needed.
    pub fn get(self: *const World, cx: i32, cy: i32) ?*const Chunk {
        return self.by_key.get(keyOf(cx, cy));
    }

    pub fn invalidateCuts(self: *World) void {
        var it = self.by_key.valueIterator();
        while (it.next()) |slot| slot.*.cuts_stale = true;
    }

    pub fn applyCuts(self: *World, snapshot: *const protocol.Snapshot) void {
        const area = snapshot.area;
        const cols: usize = @intCast(area.cols());
        var changed = false;
        for (snapshot.chunks[0..snapshot.count], 0..) |bits, i| {
            const cx = area.cx0 + @as(i32, @intCast(i % cols));
            const cy = area.cy0 + @as(i32, @intCast(i / cols));
            // Panning can evict a requested chunk while its reply is in flight.
            const chunk = self.by_key.get(keyOf(cx, cy)) orelse continue;
            const previous: [protocol.chunk_bytes]u8 = chunk.cuts orelse @splat(0);
            if (!std.mem.eql(u8, &previous, &bits)) changed = true;
            chunk.cuts = bits;
            chunk.cuts_stale = false;
        }
        if (changed) self.cut_revision +%= 1;
    }

    /// The first missing resident starts a rectangle of only unsynced chunks.
    pub fn nextCutArea(self: *const World, range: ChunkRange, limit: i32) ?ChunkRange {
        std.debug.assert(limit > 0 and limit <= protocol.max_area_chunks);
        var cy = range.cy0;
        while (cy <= range.cy1) : (cy += 1) {
            var cx = range.cx0;
            while (cx <= range.cx1) : (cx += 1) {
                if (!self.needsCuts(cx, cy)) continue;
                var end_x = cx;
                while (end_x < @min(range.cx1, cx + limit - 1) and self.needsCuts(end_x + 1, cy)) end_x += 1;
                const rows = @divTrunc(limit, end_x - cx + 1);
                var end_y = cy;
                extend: while (end_y < @min(range.cy1, cy + rows - 1)) : (end_y += 1) {
                    var x = cx;
                    while (x <= end_x) : (x += 1) if (!self.needsCuts(x, end_y + 1)) break :extend;
                }
                return .{ .cx0 = cx, .cy0 = cy, .cx1 = end_x, .cy1 = end_y };
            }
        }
        return null;
    }

    fn needsCuts(self: *const World, cx: i32, cy: i32) bool {
        const chunk = self.get(cx, cy) orelse return false;
        return !chunk.cutsSynced();
    }

    /// Number of chunks currently in memory.
    pub fn residentCount(self: *const World) usize {
        return self.by_key.count();
    }

    /// True when the last streaming pass could not finish every requested load.
    pub fn underMemoryPressure(self: *const World) bool {
        return self.memory_pressure;
    }

    /// Iterate resident chunks without exposing the hash map itself.
    pub fn residents(self: *const World) ResidentIterator {
        return .{ .inner = self.by_key.valueIterator() };
    }

    pub fn stats(self: *const World) Stats {
        return .{
            .resident_chunks = self.by_key.count(),
            .wanted_chunks = self.wanted,
            .generated = self.generated,
            .unloaded = self.unloaded,
            .memory_pressure = self.memory_pressure,
            .resident_bytes = @as(usize, self.by_key.count()) * @sizeOf(Chunk),
            // Includes free slots and arena slack, but excludes arena headers
            // and backing-allocator overhead. This is not process RSS.
            .pool_backing_bytes = self.pool.arena_state.promote(self.alloc).queryCapacity(),
            .map_slots = self.by_key.capacity(),
            .scratch_keys = self.doomed.capacity,
            .scratch_bytes = self.doomed.capacity * @sizeOf(u64),
        };
    }

    /// Unload first, then load visible chunks before attempting any prefetch.
    /// Failure leaves a valid, possibly incomplete resident set that can be
    /// retried on the next frame.
    pub fn stream(self: *World, vis: ChunkRange) StreamError!void {
        return self.streamWithMinimap(vis, null);
    }

    pub fn streamWithMinimap(self: *World, vis: ChunkRange, minimap: ?ChunkRange) StreamError!void {
        // Validate before mutating the world so an invalid range cannot evict chunks.
        try validateChunkRange(vis, PREFETCH_MARGIN_CHUNKS);
        if (minimap) |map| try validateChunkRange(map, 0);
        const ring = residencyRange(vis, minimap);
        try validateChunkRange(ring, 0);
        if (self.completed_range) |completed| {
            if (std.meta.eql(completed, ring)) return;
        }

        self.completed_range = null;
        self.memory_pressure = false;
        errdefer self.memory_pressure = true;
        self.wanted = @intCast(ring.count());

        // Unload first: afterwards every resident chunk is inside the ring,
        // and freed pool slots can satisfy the load pass without allocations.
        self.doomed.clearRetainingCapacity();
        var it = self.by_key.valueIterator();
        while (it.next()) |slot_ptr| {
            const c = slot_ptr.*;
            if (!ring.contains(c.cx, c.cy)) {
                self.doomed.appendAssumeCapacity(keyOf(c.cx, c.cy));
            }
        }
        for (self.doomed.items) |key| self.unload(key);

        var cy = vis.cy0;
        while (cy <= vis.cy1) : (cy += 1) {
            var cx = vis.cx0;
            while (cx <= vis.cx1) : (cx += 1) {
                try self.ensureLoaded(cx, cy);
            }
        }

        // Reserve the rest only after visible chunks are available: a failed
        // prefetch reservation must not prevent rendering the visible terrain.
        try self.by_key.ensureTotalCapacity(self.alloc, @intCast(self.wanted));
        try self.doomed.ensureTotalCapacity(self.alloc, self.wanted);

        cy = ring.cy0;
        while (cy <= ring.cy1) : (cy += 1) {
            var cx = ring.cx0;
            while (cx <= ring.cx1) : (cx += 1) {
                if (!vis.contains(cx, cy)) try self.ensureLoaded(cx, cy);
            }
        }
        self.completed_range = ring;
    }
};

/// Errors that can complete a streaming pass: allocation failure is retried,
/// coordinate failure is a caller/program invariant and must propagate.
pub const StreamError = std.mem.Allocator.Error || CoordinateError;

// ── tests ────────────────────────────────────────────────────────────────────

test "cut batches are bounded, use chunk addresses, and expire with residency" {
    const t = std.testing;
    var w = try World.init(t.allocator, MIN_PREHEATED_CHUNKS);
    defer w.deinit();
    const visible: ChunkRange = .{ .cx0 = -10, .cy0 = -4, .cx1 = 5, .cy1 = 4 };
    try w.stream(visible);
    const first = w.nextCutArea(visible, protocol.max_area_chunks).?;
    const geometry = try protocol.areaGeometry(first);
    try t.expectEqual(@as(u16, 64), geometry.count);
    var reply: protocol.Snapshot = .{ .area = first, .count = geometry.count };
    const cx = first.cx0 + 3;
    const cy = first.cy0 + 1;
    const base = w.get(cx, cy).?.tiles;
    reply.chunks[geometry.cols + 3][2] = 0b00000100;
    w.applyCuts(&reply);
    try t.expectEqualDeep(base, w.get(cx, cy).?.tiles);
    try t.expect(w.get(cx, cy).?.isCut(18));
    try t.expect(!w.get(cx, cy).?.isCut(17));
    try t.expect(!w.get(cx - 1, cy).?.isCut(18));
    try t.expect(w.get(cx - 1, cy).?.cuts != null);
    const next = w.nextCutArea(visible, protocol.max_area_chunks).?;
    try t.expectEqual(first.cy1 + 1, next.cy0);

    const far: ChunkRange = .{ .cx0 = 30, .cy0 = 40, .cx1 = 30, .cy1 = 40 };
    try w.stream(far);
    w.applyCuts(&reply); // An old reply cannot resurrect evicted terrain.
    try t.expect(w.get(cx, cy) == null);
    try w.stream(visible);
    try t.expect(w.get(cx, cy).?.cuts == null);
    try t.expectEqual(first, w.nextCutArea(visible, protocol.max_area_chunks).?);
}

test "terrain survives eviction regeneration and reversed load order" {
    var first = try World.init(std.testing.allocator, 4);
    defer first.deinit();
    var second = try World.init(std.testing.allocator, 4);
    defer second.deinit();
    const coords = [_][2]i32{ .{ -1, -1 }, .{ 0, -1 }, .{ -1, 0 }, .{ 0, 0 } };
    for (coords) |c| try first.ensureLoaded(c[0], c[1]);
    for (0..coords.len) |i| {
        const c = coords[coords.len - 1 - i];
        try second.ensureLoaded(c[0], c[1]);
    }
    for (coords) |c| {
        const expected = first.get(c[0], c[1]).?.tiles;
        var shared_chunk = terrain.Chunk{ .cx = c[0], .cy = c[1] };
        terrain.generate(&shared_chunk);
        try std.testing.expectEqualSlices(Tile, &shared_chunk.tiles, &expected);
        try std.testing.expectEqualSlices(Tile, &expected, &second.get(c[0], c[1]).?.tiles);
        first.unload(World.keyOf(c[0], c[1]));
        try std.testing.expect(first.get(c[0], c[1]) == null);
        try first.ensureLoaded(c[0], c[1]);
        try std.testing.expectEqualSlices(Tile, &expected, &first.get(c[0], c[1]).?.tiles);
    }
    try std.testing.expectEqual(@as(u64, 4), first.stats().unloaded);
}

test "stream keeps visible chunks plus a 2-chunk margin" {
    const alloc = std.testing.allocator;

    var world = try World.init(alloc, MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    const vis = ChunkRange{ .cx0 = 0, .cy0 = 0, .cx1 = 3, .cy1 = 2 };
    try world.stream(vis);

    // x: -2..5 (8 cols), y: -2..4 (7 rows)
    try std.testing.expectEqual(@as(usize, 8 * 7), world.residentCount());
    try std.testing.expect(world.get(-2, -2) != null);
    try std.testing.expect(world.get(5, 4) != null);
    try std.testing.expect(world.get(6, 0) == null);

    // Pan 4 chunks right: the left column must be unloaded, the right loaded.
    const vis2 = ChunkRange{ .cx0 = 4, .cy0 = 0, .cx1 = 7, .cy1 = 2 };
    try world.stream(vis2);

    try std.testing.expectEqual(@as(usize, 8 * 7), world.residentCount());
    try std.testing.expect(world.get(-2, 0) == null);
    try std.testing.expect(world.get(2, 0) != null);
    try std.testing.expect(world.get(9, 0) != null);

    // Everything still loaded is inside the new ring, nothing outside.
    var it = world.residents();
    while (it.next()) |c| {
        try std.testing.expect(c.cx >= 2 and c.cx <= 9);
        try std.testing.expect(c.cy >= -2 and c.cy <= 4);
    }
}

test "minimap streaming reuses cached terrain and generates only entering chunks" {
    var world = try World.init(std.testing.allocator, MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    const vis = ChunkRange{ .cx0 = 0, .cy0 = 0, .cx1 = 0, .cy1 = 0 };
    const map = ChunkRange{ .cx0 = -3, .cy0 = -3, .cx1 = 3, .cy1 = 3 };
    try world.streamWithMinimap(vis, map);
    const cached = world.get(0, 0).?;
    const initial = world.stats();
    try std.testing.expectEqual(@as(u64, 49), initial.generated);

    // Changing which chunks are visible does not matter if residency is unchanged.
    const next_vis = ChunkRange{ .cx0 = 1, .cy0 = 0, .cx1 = 1, .cy1 = 0 };
    try world.streamWithMinimap(next_vis, map);
    try std.testing.expectEqual(initial, world.stats());
    try std.testing.expectEqual(cached, world.get(0, 0).?);

    try world.streamWithMinimap(next_vis, .{ .cx0 = -2, .cy0 = -3, .cx1 = 4, .cy1 = 3 });
    try std.testing.expectEqual(cached, world.get(0, 0).?);
    try std.testing.expectEqual(initial.generated + 7, world.stats().generated);
    try std.testing.expectEqual(initial.unloaded + 7, world.stats().unloaded);
}

test "ring larger than the startup reserve does not thrash" {
    var world = try World.init(std.testing.allocator, MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    // vis 31x21 -> ring 35x25 = 875 chunks, above the startup reserve.
    const vis = ChunkRange{ .cx0 = 0, .cy0 = 0, .cx1 = 30, .cy1 = 20 };
    try world.stream(vis);

    try std.testing.expectEqual(@as(usize, 875), world.residentCount());
    var stats = world.stats();
    try std.testing.expectEqual(@as(usize, 875), stats.wanted_chunks);
    try std.testing.expectEqual(@as(u64, 875), stats.generated);

    try world.stream(vis);
    stats = world.stats();
    try std.testing.expectEqual(@as(u64, 875), stats.generated);
    try std.testing.expectEqual(@as(u64, 0), stats.unloaded);
}

test "startup reserve is small and covers the unload list and map" {
    var world = try World.init(std.testing.allocator, MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    const stats = world.stats();
    try std.testing.expectEqual(@as(usize, 0), stats.resident_bytes);
    try std.testing.expect(stats.pool_backing_bytes >= MIN_PREHEATED_CHUNKS * @sizeOf(Chunk));
    try std.testing.expect(stats.pool_backing_bytes < 512 * @sizeOf(Chunk));
    try std.testing.expect(stats.map_slots >= MIN_PREHEATED_CHUNKS);
    try std.testing.expectEqual(MIN_PREHEATED_CHUNKS, stats.scratch_keys);
}

test "stationary frames panning and teleports reuse reserved memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var world = try World.init(failing.allocator(), MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    const vis = ChunkRange{ .cx0 = 0, .cy0 = 0, .cx1 = 2, .cy1 = 2 };
    try world.stream(vis);
    const generated = world.stats().generated;
    const memory = world.stats();
    const allocations = failing.allocations;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try world.stream(vis);
    try std.testing.expectEqual(generated, world.stats().generated);
    for (0..32) |i| {
        const x: i32 = @intCast(i);
        try world.stream(.{ .cx0 = x, .cy0 = 0, .cx1 = x + 2, .cy1 = 2 });
    }
    try world.stream(.{ .cx0 = -1000, .cy0 = -1000, .cx1 = -998, .cy1 = -998 });
    try std.testing.expectEqual(@as(usize, 49), world.residentCount());
    try std.testing.expectEqual(memory.pool_backing_bytes, world.stats().pool_backing_bytes);
    try std.testing.expectEqual(allocations, failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}

test "memory statistics retain the high water mark after the view shrinks" {
    var world = try World.init(std.testing.allocator, MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    try world.stream(.{ .cx0 = 0, .cy0 = 0, .cx1 = 30, .cy1 = 20 });
    const large = world.stats();
    try world.stream(.{ .cx0 = 0, .cy0 = 0, .cx1 = 0, .cy1 = 0 });
    const small = world.stats();

    try std.testing.expectEqual(@as(usize, 25), small.wanted_chunks);
    try std.testing.expectEqual(@as(usize, 25 * @sizeOf(Chunk)), small.resident_bytes);
    try std.testing.expect(small.resident_bytes < large.resident_bytes);
    try std.testing.expectEqual(large.pool_backing_bytes, small.pool_backing_bytes);
    try std.testing.expectEqual(large.map_slots, small.map_slots);
    try std.testing.expectEqual(large.scratch_bytes, small.scratch_bytes);
}

test "prefetch failure preserves visible chunks and recovers on retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var world = try World.init(failing.allocator(), 1);
    defer world.deinit();

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    const vis = ChunkRange{ .cx0 = 10, .cy0 = 10, .cx1 = 10, .cy1 = 10 };
    try std.testing.expectError(error.OutOfMemory, world.stream(vis));
    try std.testing.expect(world.stats().memory_pressure);
    try std.testing.expect(world.get(10, 10) != null);
    try std.testing.expect(world.get(8, 8) == null);
    try std.testing.expectEqual(@as(usize, 1), world.residentCount());

    // Eviction and visible loading still work with allocations disabled.
    const moved = ChunkRange{ .cx0 = -10, .cy0 = -10, .cx1 = -10, .cy1 = -10 };
    try std.testing.expectError(error.OutOfMemory, world.stream(moved));
    try std.testing.expect(world.get(10, 10) == null);
    const cached = world.get(-10, -10).?;
    const generated = world.stats().generated;

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try world.stream(moved);
    try std.testing.expect(!world.stats().memory_pressure);
    try std.testing.expectEqual(@as(usize, 25), world.residentCount());
    try std.testing.expectEqual(cached, world.get(-10, -10).?);
    try std.testing.expectEqual(generated + 24, world.stats().generated);
}

test "initialization and streaming clean up every allocation failure" {
    const Exercise = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var world = try World.init(alloc, MIN_PREHEATED_CHUNKS);
            defer world.deinit();

            try world.stream(.{ .cx0 = 0, .cy0 = 0, .cx1 = 2, .cy1 = 2 });
            try world.stream(.{ .cx0 = -40, .cy0 = -30, .cx1 = -10, .cy1 = -10 });
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Exercise.run, .{});
}

test "streaming clips prefetch and loads absolute terrain at opposite world edges" {
    const t = std.testing;
    var w = try World.init(t.allocator, MIN_PREHEATED_CHUNKS);
    defer w.deinit();
    const low = protocol.min_chunk;
    const high = protocol.max_chunk;
    const first: ChunkRange = .{ .cx0 = low, .cy0 = high, .cx1 = low, .cy1 = high };
    const second: ChunkRange = .{ .cx0 = high, .cy0 = low, .cx1 = high, .cy1 = low };
    const map: ChunkRange = .{ .cx0 = high - 3, .cy0 = low, .cx1 = high, .cy1 = low + 3 };

    try t.expectEqual(ChunkRange{ .cx0 = low, .cy0 = high - 2, .cx1 = low + 2, .cy1 = high }, residencyRange(first, null));
    try w.stream(first);
    try t.expectEqual(@as(usize, 9), w.residentCount());
    try t.expect(w.get(low - 1, high) == null and w.get(low, high + 1) == null);
    try t.expectEqual(terrain.sampleTile(terrain.public_seed, std.math.minInt(i32), std.math.maxInt(i32)), w.get(low, high).?.tiles[(CT - 1) * CT]);

    try t.expectEqual(map, residencyRange(second, map));
    try w.streamWithMinimap(second, map);
    try t.expectEqual(@as(usize, 16), w.residentCount());
    try t.expect(w.get(low, high) == null and w.get(high - 3, low + 3) != null);
    try t.expect(w.get(high + 1, low) == null and w.get(high, low - 1) == null);
    try t.expectEqual(terrain.sampleTile(terrain.public_seed, std.math.maxInt(i32), std.math.minInt(i32)), w.get(high, low).?.tiles[CT - 1]);
}

test "stream rejects malformed and oversized ranges before mutating the world" {
    var world = try World.init(std.testing.allocator, MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    // Inverted rows/columns.
    try std.testing.expectError(error.CoordinateOutOfBounds, world.stream(.{ .cx0 = 1, .cy0 = 0, .cx1 = 0, .cy1 = 0 }));
    try std.testing.expectError(error.CoordinateOutOfBounds, world.stream(.{ .cx0 = 0, .cy0 = 1, .cx1 = 0, .cy1 = 0 }));

    // Indices beyond the world fail before generation or eviction.
    const high = protocol.max_chunk;
    const low = protocol.min_chunk;
    try std.testing.expectError(error.CoordinateOutOfBounds, world.stream(.{ .cx0 = high + 1, .cy0 = 0, .cx1 = high + 1, .cy1 = 0 }));
    try std.testing.expectError(error.CoordinateOutOfBounds, world.stream(.{ .cx0 = 0, .cy0 = low - 1, .cx1 = 0, .cy1 = low - 1 }));

    // Valid individual bounds do not guarantee a manageable residency count.
    const all = ChunkRange{ .cx0 = low, .cy0 = low, .cx1 = high, .cy1 = high };
    try std.testing.expectError(error.CoordinateOutOfBounds, world.stream(all));
    const first: ChunkRange = .{ .cx0 = low, .cy0 = low, .cx1 = low, .cy1 = low };
    const map: ChunkRange = .{ .cx0 = high, .cy0 = high, .cx1 = high, .cy1 = high };
    try std.testing.expectError(error.CoordinateOutOfBounds, world.streamWithMinimap(first, map));

    try std.testing.expectEqual(@as(usize, 0), world.residentCount());
    var stats = world.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.generated);
    try std.testing.expect(!stats.memory_pressure);

    // A valid range still streams normally after the rejections.
    try world.stream(.{ .cx0 = 0, .cy0 = 0, .cx1 = 0, .cy1 = 0 });
    stats = world.stats();
    try std.testing.expectEqual(@as(usize, 25), stats.resident_chunks);
    try std.testing.expect(!stats.memory_pressure);
}

// Test seeds are explicit 32-byte arrays; index 0 is the first seed byte and
// index 31 the last. Each replaces a former 256-bit integer constant holding
// the same little-endian bytes, so all expected vectors below are unchanged.
const zero_seed: [32]u8 = @splat(0);

const top_bit_seed: [32]u8 = blk: {
    var seed: [32]u8 = @splat(0);
    seed[31] = 0x80;
    break :blk seed;
};

// Test-only secret seeds; production code must never embed a private seed.
const yield_seed = [32]u8{
    0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
    0x87, 0x96, 0xA5, 0xB4, 0xC3, 0xD2, 0xE1, 0xF0,
    0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01,
    0xBE, 0xBA, 0xFE, 0xCA, 0xEF, 0xBE, 0xAD, 0xDE,
};

test "private yield fixed vectors stay stable" {
    // Negative coordinates, extreme coordinates, a zero seed, and a seed with
    // only the highest bit set (locks the top seed byte).
    try std.testing.expectEqual(@as(u64, 0x5C3880ED335E415A), privateYield(zero_seed, 0, 0));
    try std.testing.expectEqual(@as(u64, 0x2129415C1B31CC5D), privateYield(yield_seed, 7, -3));
    try std.testing.expectEqual(@as(u64, 0x7CEBD6C5494E30E6), privateYield(zero_seed, std.math.minInt(i32), std.math.maxInt(i32)));
    try std.testing.expectEqual(@as(u64, 0xC2385D8455021523), privateYield(top_bit_seed, 0, 0));
    try std.testing.expectEqual(@as(u64, 0x8D8D4FA2F22750AF), privateYield(yield_seed, -1, -1));
    try std.testing.expectEqual(@as(u64, 0xA49CD34EB7022A53), privateYield(yield_seed, 37, -91));
}

test "private yield is repeatable including negative and extreme coordinates" {
    const coords = [_]struct { x: i32, y: i32 }{
        .{ .x = 0, .y = 0 },
        .{ .x = 7, .y = -3 },
        .{ .x = -3, .y = 7 },
        .{ .x = -1, .y = -1 },
        .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32) },
        .{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32) },
        .{ .x = std.math.maxInt(i32), .y = std.math.maxInt(i32) },
    };
    for ([_][32]u8{ zero_seed, yield_seed, top_bit_seed }) |seed| {
        for (coords) |c| {
            try std.testing.expectEqual(privateYield(seed, c.x, c.y), privateYield(seed, c.x, c.y));
        }
    }
}

test "private yield changes when the seed or a coordinate changes" {
    const base = privateYield(yield_seed, 7, -3);
    try std.testing.expect(base != privateYield(yield_seed, 8, -3));
    try std.testing.expect(base != privateYield(yield_seed, 7, -2));
    try std.testing.expect(base != privateYield(yield_seed, 7, 3));
    try std.testing.expect(base != privateYield(yield_seed, -7, -3));
    var next_seed = yield_seed;
    next_seed[0] ^= 1;
    try std.testing.expect(base != privateYield(next_seed, 7, -3));
    // Only the highest seed bit differs: the whole 32-byte key is hashed.
    var high_bit_seed = yield_seed;
    high_bit_seed[31] ^= 0x80;
    try std.testing.expect(base != privateYield(high_bit_seed, 7, -3));
}

test "every private yield seed bit participates" {
    const x: i32 = 37;
    const y: i32 = -91;
    for ([_][32]u8{ zero_seed, yield_seed }) |base| {
        const expected = privateYield(base, x, y);
        var bit: usize = 0;
        while (bit < 256) : (bit += 1) {
            var mutated = base;
            mutated[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
            try std.testing.expect(privateYield(mutated, x, y) != expected);
        }
    }
}

test "private yield matches an independently encoded keyed BLAKE3 input" {
    // Hand-written key bytes matching yield_seed, in array order.
    const key = [32]u8{
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
        0x87, 0x96, 0xA5, 0xB4, 0xC3, 0xD2, 0xE1, 0xF0,
        0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01,
        0xBE, 0xBA, 0xFE, 0xCA, 0xEF, 0xBE, 0xAD, 0xDE,
    };

    // Domain tag, then x = 7 and y = -3 as hand-written little-endian fields.
    const tag = "haystack.private-yield.v1";
    var input: [tag.len + 8]u8 = undefined;
    @memcpy(input[0..tag.len], tag);
    input[tag.len..][0..4].* = .{ 0x07, 0x00, 0x00, 0x00 };
    input[tag.len + 4 ..][0..4].* = .{ 0xFD, 0xFF, 0xFF, 0xFF };

    var digest: [8]u8 = undefined;
    Blake3.hash(&input, &digest, .{ .key = key });

    // First 8 digest bytes, little endian: the roll this primitive returns.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x5D, 0xCC, 0x31, 0x1B, 0x5C, 0x41, 0x29, 0x21 }, &digest);
    try std.testing.expectEqual(std.mem.readInt(u64, &digest, .little), privateYield(yield_seed, 7, -3));
}
