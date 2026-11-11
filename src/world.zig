//! Authoritative world model: tiles, chunks, deterministic generation, storage,
//! streaming, ownership, and statistics.
//!
//! This module deliberately does not import Raylib. Anything that needs a
//! window, a camera transform, or draw calls belongs in `camera.zig` or
//! `rendering.zig`. That keeps the world headless-testable and ready for a
//! future server or simulation that never opens a window.
//!
//! The world is infinite. A chunk that is not resident simply does not exist
//! until the camera gets close enough to ask for it. Residency is therefore a
//! cache of generated chunks, not the world itself: the generator defines every
//! chunk deterministically, and `World` decides which ones are currently in
//! memory.

const std = @import("std");

// ── world constants ──────────────────────────────────────────────────────────

/// One tile is 32×32 world pixels. Debug rendering draws only grid and chunk
/// borders today, but the coordinate system is real.
pub const TILE_PX: i32 = 32;

/// A chunk is 16×16 tiles (512×512 pixels).
pub const CHUNK_TILES: i32 = 16;
pub const CHUNK_PX: i32 = TILE_PX * CHUNK_TILES;

/// Same value as `CHUNK_TILES`, typed for array indexing.
pub const CT: usize = @intCast(CHUNK_TILES);

/// How many chunks beyond the visible range stay loaded.
pub const PREFETCH_MARGIN_CHUNKS: i32 = 2;

/// Small startup reserve; larger viewports preheat their full prefetch ring.
/// This is not a residency limit or a hard memory budget.
pub const MIN_PREHEATED_CHUNKS: usize = 64;

// ── tiles / chunks ───────────────────────────────────────────────────────────

/// Generated terrain. Gameplay state (cut, tilled, ownership, …) is not stored
/// here yet; see `docs/world.md` for the planned delta model.
pub const Tile = enum(u8) { grass, dirt, rock };

pub const Chunk = struct {
    cx: i32 = 0,
    cy: i32 = 0,
    tiles: [CT * CT]Tile = undefined,
};

/// An inclusive rectangular range of chunk indices.
pub const ChunkRange = struct {
    cx0: i32,
    cy0: i32,
    cx1: i32,
    cy1: i32,

    pub fn cols(self: ChunkRange) i32 {
        return self.cx1 - self.cx0 + 1;
    }

    pub fn rows(self: ChunkRange) i32 {
        return self.cy1 - self.cy0 + 1;
    }

    pub fn count(self: ChunkRange) i32 {
        return self.cols() * self.rows();
    }

    pub fn contains(self: ChunkRange, cx: i32, cy: i32) bool {
        return cx >= self.cx0 and cx <= self.cx1 and cy >= self.cy0 and cy <= self.cy1;
    }

    pub fn expanded(self: ChunkRange, margin: i32) ChunkRange {
        return .{
            .cx0 = self.cx0 - margin,
            .cy0 = self.cy0 - margin,
            .cx1 = self.cx1 + margin,
            .cy1 = self.cy1 + margin,
        };
    }
};

// ── coordinate validation ────────────────────────────────────────────────────

/// A chunk is drawable only if its full pixel extent fits in an i32:
/// `cx * CHUNK_PX` and `cx * CHUNK_PX + CHUNK_PX`. For 512 px chunks this
/// gives the inclusive range [-4194304, 4194302].
pub const MIN_DRAWABLE_CHUNK: i32 = @divFloor(std.math.minInt(i32), CHUNK_PX);
pub const MAX_DRAWABLE_CHUNK: i32 = @divFloor(std.math.maxInt(i32) - CHUNK_PX, CHUNK_PX);

/// Raised before an unsafe world-pixel, chunk, or count conversion.
pub const CoordinateError = error{CoordinateOutOfBounds};

/// Validate a visible/streamed chunk range together with its prefetch margin.
/// Arithmetic is widened to i64 so validation itself can never overflow.
pub fn validateChunkRange(range: ChunkRange, margin: i32) CoordinateError!void {
    if (range.cx0 > range.cx1 or range.cy0 > range.cy1) return error.CoordinateOutOfBounds;

    const x0 = @as(i64, range.cx0) - @as(i64, margin);
    const y0 = @as(i64, range.cy0) - @as(i64, margin);
    const x1 = @as(i64, range.cx1) + @as(i64, margin);
    const y1 = @as(i64, range.cy1) + @as(i64, margin);

    if (x0 < MIN_DRAWABLE_CHUNK or x1 > MAX_DRAWABLE_CHUNK) return error.CoordinateOutOfBounds;
    if (y0 < MIN_DRAWABLE_CHUNK or y1 > MAX_DRAWABLE_CHUNK) return error.CoordinateOutOfBounds;

    // `ChunkRange.count()` is i32 and feeds the desired residency count;
    // reject a ring whose dimensions cannot be represented before it is used.
    const cols = x1 - x0 + 1;
    const rows = y1 - y0 + 1;
    if (cols * rows > std.math.maxInt(i32)) return error.CoordinateOutOfBounds;
}

// ── deterministic generation ─────────────────────────────────────────────────

/// Deterministic, non-cryptographic 32-bit hash of tile coordinates and the
/// public world seed. Both a client and a future server can compute the same
/// chunk from the same inputs because the result is platform-independent.
///
/// `public_seed` is the shareable layout seed, exactly 32 bytes. `privateYield`
/// uses a separate, independently generated server-only secret; never reuse
/// `public_seed` as `private_seed`.
///
/// The seed is consumed as eight consecutive four-byte words in array order:
/// `public_seed[0..4]` is the first word and `public_seed[28..32]` the last,
/// and each word is read little-endian. Each word is XORed into the state and
/// mixed, so every seed bit participates. The seed array itself is never
/// endian-converted; only those word reads and the byte order above matter.
/// This is a public layout hash, not a secure PRF: do not use it for private
/// data or to derive gameplay yields.
fn hash2(public_seed: [32]u8, x: i32, y: i32) u32 {
    // Mix the coordinate contributions in order rather than folding them
    // together first: folding before mixing makes sign-mirrored coordinate
    // pairs collide.
    var h: u32 = @as(u32, @bitCast(x)) *% 0x9E3779B1;
    h = mix32(h);
    h ^= @as(u32, @bitCast(y)) *% 0x85EBCA77;
    h = mix32(h);

    inline for (0..8) |i| {
        h ^= std.mem.readInt(u32, public_seed[4 * i ..][0..4], .little);
        h = mix32(h);
    }
    return h;
}

/// Avalanching 32-bit finalizer used between inputs: invertible for an
/// individual u32 state, so any change that reaches this state survives to
/// the output. That does not make `hash2` collision-free — its full input is
/// far wider than its u32 output.
fn mix32(value: u32) u32 {
    var h = value;
    h ^= h >> 15;
    h *%= 0x2545F491;
    h ^= h >> 13;
    return h;
}

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

fn generate(chunk: *Chunk) void {
    // Placeholder public world seed. Seed plumbing belongs to the world
    // configuration; all zeros keeps generation deterministic for now.
    const public_seed: [32]u8 = @splat(0);
    for (0..CT) |ly| {
        for (0..CT) |lx| {
            const x = chunk.cx * CHUNK_TILES + @as(i32, @intCast(lx));
            const y = chunk.cy * CHUNK_TILES + @as(i32, @intCast(ly));
            const h = hash2(public_seed, x, y);
            chunk.tiles[ly * CT + lx] = if (h % 31 == 0)
                .rock
            else if (h % 17 == 0)
                .dirt
            else
                .grass;
        }
    }
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

    /// Desired residency, not the amount of memory retained by the pool.
    wanted: usize = 0,
    memory_pressure: bool = false,

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

    /// Bring a chunk into memory, generating it if this is the first time.
    fn ensureLoaded(self: *World, cx: i32, cy: i32) std.mem.Allocator.Error!void {
        const key = keyOf(cx, cy);
        if (self.by_key.contains(key)) return;

        // Preserve allocation-free eviction even if a later allocation fails.
        try self.doomed.ensureTotalCapacity(self.alloc, @as(usize, self.by_key.count()) + 1);
        const chunk = try self.pool.create(self.alloc);
        errdefer self.pool.destroy(chunk);
        chunk.cx = cx;
        chunk.cy = cy;
        generate(chunk);

        try self.by_key.put(self.alloc, key, chunk);
        self.generated += 1;
    }

    fn unload(self: *World, key: u64) void {
        const entry = self.by_key.fetchRemove(key) orelse return;
        // The map stores the item's natural alignment; the pool guarantees
        // the free-list alignment, so re-assert it here.
        self.pool.destroy(@alignCast(entry.value));
        self.unloaded += 1;
    }

    /// Look up a resident chunk. Chunks that are not resident return `null`;
    /// they can be regenerated deterministically when needed.
    pub fn get(self: *const World, cx: i32, cy: i32) ?*const Chunk {
        return self.by_key.get(keyOf(cx, cy));
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
        // Validate before mutating the world: inverted, extreme, or count-overflow
        // ranges must not unload/load anything or look like allocation pressure.
        try validateChunkRange(vis, PREFETCH_MARGIN_CHUNKS);

        self.memory_pressure = false;
        errdefer self.memory_pressure = true;
        const ring = vis.expanded(PREFETCH_MARGIN_CHUNKS);
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
    }
};

/// Errors that can complete a streaming pass: allocation failure is retried,
/// coordinate failure is a caller/program invariant and must propagate.
pub const StreamError = std.mem.Allocator.Error || CoordinateError;

// ── tests ────────────────────────────────────────────────────────────────────

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
    try std.testing.expect(world.get(-10, -10) != null);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try world.stream(moved);
    try std.testing.expect(!world.stats().memory_pressure);
    try std.testing.expectEqual(@as(usize, 25), world.residentCount());
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

test "chunk extent validation covers the +CHUNK_PX edge" {
    // Positive: chunk 4194302 is the last chunk whose full extent fits i32
    // (it ends at 2147483136; the next chunk would end at 2^31).
    try validateChunkRange(.{ .cx0 = 4194302, .cy0 = 0, .cx1 = 4194302, .cy1 = 0 }, 0);
    try std.testing.expectError(error.CoordinateOutOfBounds, validateChunkRange(.{ .cx0 = 4194303, .cy0 = 0, .cx1 = 4194303, .cy1 = 0 }, 0));

    // Negative: origin == minInt(i32) exactly for chunk -4194304.
    try validateChunkRange(.{ .cx0 = -4194304, .cy0 = 0, .cx1 = -4194304, .cy1 = 0 }, 0);
    try std.testing.expectError(error.CoordinateOutOfBounds, validateChunkRange(.{ .cx0 = -4194305, .cy0 = 0, .cx1 = -4194305, .cy1 = 0 }, 0));

    // The prefetch ring must also fit, so an edge chunk needs two chunks slack.
    try std.testing.expectError(error.CoordinateOutOfBounds, validateChunkRange(.{ .cx0 = 4194302, .cy0 = 0, .cx1 = 4194302, .cy1 = 0 }, PREFETCH_MARGIN_CHUNKS));
    try std.testing.expectError(error.CoordinateOutOfBounds, validateChunkRange(.{ .cx0 = -4194304, .cy0 = 0, .cx1 = -4194304, .cy1 = 0 }, PREFETCH_MARGIN_CHUNKS));
}

test "stream rejects malformed and oversized ranges before mutating the world" {
    var world = try World.init(std.testing.allocator, MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    // Inverted rows/columns.
    try std.testing.expectError(error.CoordinateOutOfBounds, world.stream(.{ .cx0 = 1, .cy0 = 0, .cx1 = 0, .cy1 = 0 }));
    try std.testing.expectError(error.CoordinateOutOfBounds, world.stream(.{ .cx0 = 0, .cy0 = 1, .cx1 = 0, .cy1 = 0 }));

    // Extreme chunk indices fail before generation or eviction.
    try std.testing.expectError(error.CoordinateOutOfBounds, world.stream(.{ .cx0 = 4194302, .cy0 = 0, .cx1 = 4194302, .cy1 = 0 }));
    try std.testing.expectError(error.CoordinateOutOfBounds, world.stream(.{ .cx0 = 0, .cy0 = -4194304, .cx1 = 0, .cy1 = -4194304 }));

    // Individually drawable bounds, but the prefetch ring count exceeds i32.
    const wide = ChunkRange{ .cx0 = -4194302, .cy0 = -2, .cx1 = 4194300, .cy1 = 255 };
    try std.testing.expectError(error.CoordinateOutOfBounds, world.stream(wide));

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

const one_seed: [32]u8 = blk: {
    var seed: [32]u8 = @splat(0);
    seed[0] = 1;
    break :blk seed;
};

const top_bit_seed: [32]u8 = blk: {
    var seed: [32]u8 = @splat(0);
    seed[31] = 0x80;
    break :blk seed;
};

const hash_seed = [32]u8{
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
    0x78, 0x69, 0x5A, 0x4B, 0x3C, 0x2D, 0x1E, 0x0F,
    0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE,
    0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01,
};

test "hash2 is repeatable including negative and extreme coordinates" {
    const coords = [_]struct { x: i32, y: i32 }{
        .{ .x = 0, .y = 0 },
        .{ .x = 7, .y = -3 },
        .{ .x = -3, .y = 7 },
        .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32) },
        .{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32) },
        .{ .x = std.math.minInt(i32), .y = std.math.minInt(i32) },
    };
    for (coords) |c| {
        try std.testing.expectEqual(hash2(hash_seed, c.x, c.y), hash2(hash_seed, c.x, c.y));
    }
}

test "hash2 fixed vectors stay stable" {
    try std.testing.expectEqual(@as(u32, 0x00000000), hash2(zero_seed, 0, 0));
    try std.testing.expectEqual(@as(u32, 0x4419CA0F), hash2(zero_seed, 7, -3));
    try std.testing.expectEqual(@as(u32, 0x799AA099), hash2(one_seed, 7, -3));
    try std.testing.expectEqual(@as(u32, 0xDA013E35), hash2(zero_seed, std.math.minInt(i32), std.math.maxInt(i32)));
    try std.testing.expectEqual(@as(u32, 0xEA89E056), hash2(hash_seed, 37, -91));
}

test "hash2 changes when either coordinate changes" {
    const base = hash2(hash_seed, 7, -3);
    try std.testing.expect(base != hash2(hash_seed, 8, -3));
    try std.testing.expect(base != hash2(hash_seed, 7, -2));
}

test "mirrored coordinates do not collide" {
    const pairs = [_][2]i32{
        .{ 7, -3 },
        .{ 5, 9 },
        .{ 37, -91 },
        .{ -7, -3 },
        .{ 1, 0 },
        .{ 0, 1 },
        .{ 4194302, -4194304 },
    };
    for ([_][32]u8{ zero_seed, hash_seed }) |seed| {
        for (pairs) |p| {
            try std.testing.expect(hash2(seed, p[0], p[1]) != hash2(seed, -p[0], -p[1]));
        }
    }
}

test "every seed bit participates in hash2" {
    const x: i32 = 37;
    const y: i32 = -91;
    const bases = [_][32]u8{ zero_seed, hash_seed };
    for (bases) |base| {
        const expected = hash2(base, x, y);
        var bit: usize = 0;
        while (bit < 256) : (bit += 1) {
            var mutated = base;
            mutated[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
            try std.testing.expect(hash2(mutated, x, y) != expected);
        }
    }
}

test "seed limb order is not a plain xor fold" {
    // Reverse the eight four-byte words, leaving bytes within each word in
    // place: a limb reorder, not a byte reversal.
    var reversed: [32]u8 = undefined;
    inline for (0..8) |i| {
        @memcpy(reversed[4 * (7 - i) ..][0..4], hash_seed[4 * i ..][0..4]);
    }
    try std.testing.expect(hash2(hash_seed, 5, 9) != hash2(reversed, 5, 9));
}

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
