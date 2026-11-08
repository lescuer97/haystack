//! Debug render: streaming chunks with a 2-chunk prefetch ring.
//!
//! Each frame:
//!   1. compute the chunks the camera can see,
//!   2. unload everything outside the prefetch ring,
//!   3. load visible chunks first, then prefetch chunks,
//!   4. draw only the visible ones and report allocation pressure.
//!
//! The world is infinite: a chunk that is not loaded simply does not exist
//! until the camera gets close enough to ask for it.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

// ── world constants ──────────────────────────────────────────────────────────

const TILE_PX: i32 = 32;
const CHUNK_TILES: i32 = 16;
const CHUNK_PX: i32 = TILE_PX * CHUNK_TILES;
const CT: usize = @intCast(CHUNK_TILES);

/// How many chunks beyond the visible range stay loaded.
const PREFETCH_MARGIN_CHUNKS: i32 = 2;

/// Small startup reserve; larger viewports preheat their full prefetch ring.
/// This is not a residency limit or a hard memory budget.
const MIN_PREHEATED_CHUNKS: usize = 64;

/// Frame-rate target. The HUD's FPS colour thresholds are derived from it.
const TARGET_FPS: i32 = 120;

// ── tiles / chunks ───────────────────────────────────────────────────────────

const Tile = enum(u8) { grass, dirt, rock };

const Chunk = struct {
    cx: i32 = 0,
    cy: i32 = 0,
    tiles: [CT * CT]Tile = undefined,
};

const ChunkRange = struct {
    cx0: i32,
    cy0: i32,
    cx1: i32,
    cy1: i32,

    fn cols(self: ChunkRange) i32 {
        return self.cx1 - self.cx0 + 1;
    }

    fn rows(self: ChunkRange) i32 {
        return self.cy1 - self.cy0 + 1;
    }

    fn count(self: ChunkRange) i32 {
        return self.cols() * self.rows();
    }

    fn contains(self: ChunkRange, cx: i32, cy: i32) bool {
        return cx >= self.cx0 and cx <= self.cx1 and cy >= self.cy0 and cy <= self.cy1;
    }

    fn expanded(self: ChunkRange, margin: i32) ChunkRange {
        return .{
            .cx0 = self.cx0 - margin,
            .cy0 = self.cy0 - margin,
            .cx1 = self.cx1 + margin,
            .cy1 = self.cy1 + margin,
        };
    }
};

// ── coordinate validation ────────────────────────────────────────────────────

/// Every world pixel and view corner we convert must fit in an i32. The
/// positive edge is exclusive: the largest f32 below 2^31 is 2147483520, but
/// `@as(f32, @floatFromInt(maxInt(i32)))` rounds to 2147483648, so a naive f32
/// comparison would accept a value that `@intFromFloat` rejects. Compare
/// widened in f64 instead. NaN and infinities are rejected by this range check.
const MIN_WORLD_PX: f64 = -2147483648.0;
const MAX_WORLD_PX_EXCLUSIVE: f64 = 2147483648.0;

/// A chunk is drawable only if its full pixel extent fits in an i32:
/// `cx * CHUNK_PX` and `cx * CHUNK_PX + CHUNK_PX`. For 512 px chunks this
/// gives the inclusive range [-4194304, 4194302].
const MIN_DRAWABLE_CHUNK: i32 = @divFloor(std.math.minInt(i32), CHUNK_PX);
const MAX_DRAWABLE_CHUNK: i32 = @divFloor(std.math.maxInt(i32) - CHUNK_PX, CHUNK_PX);

/// Raised before an unsafe world-pixel, chunk, or count conversion.
const CoordinateError = error{CoordinateOutOfBounds};

fn pixelInI32Bounds(v: f32) bool {
    const wide: f64 = @as(f64, v);
    return wide >= MIN_WORLD_PX and wide < MAX_WORLD_PX_EXCLUSIVE;
}

/// Validate a visible/streamed chunk range together with its prefetch margin.
/// Arithmetic is widened to i64 so validation itself can never overflow.
fn validateChunkRange(range: ChunkRange, margin: i32) CoordinateError!void {
    if (range.cx0 > range.cx1 or range.cy0 > range.cy1) return error.CoordinateOutOfBounds;

    const x0 = @as(i64, range.cx0) - @as(i64, margin);
    const y0 = @as(i64, range.cy0) - @as(i64, margin);
    const x1 = @as(i64, range.cx1) + @as(i64, margin);
    const y1 = @as(i64, range.cy1) + @as(i64, margin);

    if (x0 < MIN_DRAWABLE_CHUNK or x1 > MAX_DRAWABLE_CHUNK) return error.CoordinateOutOfBounds;
    if (y0 < MIN_DRAWABLE_CHUNK or y1 > MAX_DRAWABLE_CHUNK) return error.CoordinateOutOfBounds;

    // `ChunkRange.count()` is i32 and feeds `world.wanted`; reject a ring whose
    // dimensions cannot be represented before it is used.
    const cols = x1 - x0 + 1;
    const rows = y1 - y0 + 1;
    if (cols * rows > std.math.maxInt(i32)) return error.CoordinateOutOfBounds;
}

/// Deterministic 32-bit hash — stands in for the real procedural layer.
fn hash2(x: i32, y: i32) u32 {
    var h: u32 = @as(u32, @bitCast(x)) *% 0x9E3779B1;
    h ^= @as(u32, @bitCast(y)) *% 0x85EBCA77;
    h ^= h >> 15;
    h *%= 0x2545F491;
    h ^= h >> 13;
    return h;
}

fn generate(chunk: *Chunk) void {
    for (0..CT) |ly| {
        for (0..CT) |lx| {
            const x = chunk.cx * CHUNK_TILES + @as(i32, @intCast(lx));
            const y = chunk.cy * CHUNK_TILES + @as(i32, @intCast(ly));
            const h = hash2(x, y);
            chunk.tiles[ly * CT + lx] = if (h % 31 == 0)
                .rock
            else if (h % 17 == 0)
                .dirt
            else
                .grass;
        }
    }
}

// ── streaming world ──────────────────────────────────────────────────────────

/// Standard-library pool of fixed-size chunks: O(1) create/destroy,
/// and the pool owns its backing memory.
const ChunkPool = std.heap.MemoryPool(Chunk);

const World = struct {
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

    fn init(alloc: std.mem.Allocator, initial_capacity: usize) !World {
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

    fn keyOf(cx: i32, cy: i32) u64 {
        const x: u32 = @bitCast(cx);
        const y: u32 = @bitCast(cy);
        return (@as(u64, x) << 32) | y;
    }

    fn deinit(self: *World) void {
        self.doomed.deinit(self.alloc);
        self.by_key.deinit(self.alloc);
        self.pool.deinit(self.alloc);
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

    fn get(self: *const World, cx: i32, cy: i32) ?*const Chunk {
        return self.by_key.get(keyOf(cx, cy));
    }

    const MemoryStats = struct {
        resident_bytes: usize,
        pool_backing_bytes: usize,
        map_slots: usize,
        scratch_keys: usize,
        scratch_bytes: usize,
    };

    fn memoryStats(self: *const World) MemoryStats {
        return .{
            .resident_bytes = @as(usize, self.by_key.count()) * @sizeOf(Chunk),
            // Includes free slots and arena slack, but excludes arena headers
            // and backing-allocator overhead. This is not process RSS.
            .pool_backing_bytes = self.pool.arena_state.promote(self.alloc).queryCapacity(),
            .map_slots = self.by_key.capacity(),
            .scratch_keys = self.doomed.capacity,
            .scratch_bytes = self.doomed.capacity * @sizeOf(u64),
        };
    }
};

/// Chunks intersecting the camera view. Returns
/// `error.CoordinateOutOfBounds` before any f32→i32 conversion that would
/// trap or before a chunk range whose prefetch ring cannot be represented.
fn visibleRange(cam: rl.Camera2D, vw: f32, vh: f32) CoordinateError!ChunkRange {
    // The camera target is converted to i32 directly by the HUD and minimap,
    // so reject non-finite / out-of-i32 targets even before transforming.
    if (!pixelInI32Bounds(cam.target.x) or !pixelInI32Bounds(cam.target.y))
        return error.CoordinateOutOfBounds;

    const tl = rl.getScreenToWorld2D(.{ .x = 0, .y = 0 }, cam);
    const br = rl.getScreenToWorld2D(.{ .x = vw, .y = vh }, cam);

    const tl_x = @floor(tl.x);
    const tl_y = @floor(tl.y);
    const br_x = @ceil(br.x);
    const br_y = @ceil(br.y);
    if (!pixelInI32Bounds(tl_x) or !pixelInI32Bounds(tl_y) or
        !pixelInI32Bounds(br_x) or !pixelInI32Bounds(br_y))
        return error.CoordinateOutOfBounds;

    const tx0 = @divFloor(@as(i32, @intFromFloat(tl_x)), TILE_PX);
    const ty0 = @divFloor(@as(i32, @intFromFloat(tl_y)), TILE_PX);
    const tx1 = @divFloor(@as(i32, @intFromFloat(br_x)), TILE_PX);
    const ty1 = @divFloor(@as(i32, @intFromFloat(br_y)), TILE_PX);

    const range = ChunkRange{
        .cx0 = @divFloor(tx0, CHUNK_TILES),
        .cy0 = @divFloor(ty0, CHUNK_TILES),
        .cx1 = @divFloor(tx1, CHUNK_TILES),
        .cy1 = @divFloor(ty1, CHUNK_TILES),
    };

    // The prefetch ring is loaded and generated too, so it must stay within
    // the drawable chunk extent; this also makes `expanded()` safe.
    try validateChunkRange(range, PREFETCH_MARGIN_CHUNKS);
    return range;
}

/// Errors that can complete a streaming pass: allocation failure is retried,
/// coordinate failure is a caller/program invariant and must propagate.
const StreamError = std.mem.Allocator.Error || CoordinateError;

/// Unload first, then load visible chunks before attempting any prefetch.
/// Failure leaves a valid, possibly incomplete resident set that can be retried.
fn stream(world: *World, vis: ChunkRange) StreamError!void {
    // Validate before mutating the world: inverted, extreme, or count-overflow
    // ranges must not unload/load anything or look like allocation pressure.
    try validateChunkRange(vis, PREFETCH_MARGIN_CHUNKS);

    world.memory_pressure = false;
    errdefer world.memory_pressure = true;
    const ring = vis.expanded(PREFETCH_MARGIN_CHUNKS);
    world.wanted = @intCast(ring.count());

    // Unload first: afterwards every resident chunk is inside the ring,
    // and freed pool slots can satisfy the load pass without allocations.
    world.doomed.clearRetainingCapacity();
    var it = world.by_key.valueIterator();
    while (it.next()) |slot_ptr| {
        const c = slot_ptr.*;
        if (!ring.contains(c.cx, c.cy)) {
            world.doomed.appendAssumeCapacity(World.keyOf(c.cx, c.cy));
        }
    }
    for (world.doomed.items) |key| world.unload(key);

    var cy = vis.cy0;
    while (cy <= vis.cy1) : (cy += 1) {
        var cx = vis.cx0;
        while (cx <= vis.cx1) : (cx += 1) {
            try world.ensureLoaded(cx, cy);
        }
    }

    // Reserve the rest only after visible chunks are available: a failed
    // prefetch reservation must not prevent rendering the visible terrain.
    try world.by_key.ensureTotalCapacity(world.alloc, @intCast(world.wanted));
    try world.doomed.ensureTotalCapacity(world.alloc, world.wanted);

    cy = ring.cy0;
    while (cy <= ring.cy1) : (cy += 1) {
        var cx = ring.cx0;
        while (cx <= ring.cx1) : (cx += 1) {
            if (!vis.contains(cx, cy)) try world.ensureLoaded(cx, cy);
        }
    }
}

// ── colours ──────────────────────────────────────────────────────────────────

const grid_color = rl.Color.init(255, 255, 255, 55);
const border_color = rl.Color.init(220, 60, 55, 255);
const hud_bg = rl.Color.init(0, 0, 0, 170);

// ── camera ───────────────────────────────────────────────────────────────────

const Cam = struct {
    x: f32 = 0,
    y: f32 = 0,
    speed: f32 = 420,

    fn update(self: *Cam, dt: f32) void {
        if (rl.isMouseButtonDown(.left)) {
            // Drag to pan: the world follows the cursor, so the camera
            // moves by the negative mouse delta.
            const d = rl.getMouseDelta();
            self.x -= d.x;
            self.y -= d.y;
        } else {
            if (rl.isKeyDown(.left) or rl.isKeyDown(.a)) self.x -= self.speed * dt;
            if (rl.isKeyDown(.right) or rl.isKeyDown(.d)) self.x += self.speed * dt;
            if (rl.isKeyDown(.up) or rl.isKeyDown(.w)) self.y -= self.speed * dt;
            if (rl.isKeyDown(.down) or rl.isKeyDown(.s)) self.y += self.speed * dt;
        }

        // Pixel art: whole-pixel camera, otherwise the tile grid shimmers.
        self.x = @round(self.x);
        self.y = @round(self.y);
    }

    fn raylib(self: Cam, vw: f32, vh: f32) rl.Camera2D {
        return .{
            .offset = .{ .x = vw / 2, .y = vh / 2 },
            .target = .{ .x = self.x, .y = self.y },
            .rotation = 0,
            .zoom = 1,
        };
    }
};

// ── drawing ──────────────────────────────────────────────────────────────────

/// Debug view toggles. Tiles are never filled with colour; only the grid
/// lines and chunk borders are drawn. On by default in Debug builds.
const DebugSettings = struct {
    tile_grid: bool = builtin.mode == .debug,
    chunk_borders: bool = builtin.mode == .debug,
};

fn drawChunk(chunk: *const Chunk, settings: DebugSettings) void {
    const ox = chunk.cx * CHUNK_PX;
    const oy = chunk.cy * CHUNK_PX;

    if (settings.tile_grid) {
        var i: usize = 0;
        while (i <= CT) : (i += 1) {
            const off: i32 = @as(i32, @intCast(i)) * TILE_PX;
            rl.drawLine(ox + off, oy, ox + off, oy + CHUNK_PX, grid_color);
            rl.drawLine(ox, oy + off, ox + CHUNK_PX, oy + off, grid_color);
        }
    }

    if (settings.chunk_borders) {
        rl.drawRectangleLinesEx(
            .{
                .x = @floatFromInt(ox),
                .y = @floatFromInt(oy),
                .width = @floatFromInt(CHUNK_PX),
                .height = @floatFromInt(CHUNK_PX),
            },
            2.0,
            border_color,
        );
    }
}

fn drawWorld(world: *const World, vis: ChunkRange, settings: DebugSettings) void {
    var cy = vis.cy0;
    while (cy <= vis.cy1) : (cy += 1) {
        var cx = vis.cx0;
        while (cx <= vis.cx1) : (cx += 1) {
            const chunk = world.get(cx, cy) orelse continue;
            drawChunk(chunk, settings);
        }
    }

    // world origin marker, so negative coordinates are obvious
    rl.drawLine(-40, 0, 40, 0, .red);
    rl.drawLine(0, -40, 0, 40, .green);
    rl.drawRectangleLinesEx(.{ .x = -5, .y = -5, .width = 10, .height = 10 }, 2.0, .yellow);
}

/// Yellow X marking the camera target, drawn in world space.
fn drawCameraMarker(cam: *const Cam) void {
    const s: f32 = 14;
    const yellow = rl.Color.init(255, 220, 0, 255);
    const x = cam.x;
    const y = cam.y;

    // Dark under-stroke so the X stays readable on light grass.
    rl.drawLineEx(.{ .x = x - s, .y = y - s }, .{ .x = x + s, .y = y + s }, 5, .black);
    rl.drawLineEx(.{ .x = x - s, .y = y + s }, .{ .x = x + s, .y = y - s }, 5, .black);
    rl.drawLineEx(.{ .x = x - s, .y = y - s }, .{ .x = x + s, .y = y + s }, 3, yellow);
    rl.drawLineEx(.{ .x = x - s, .y = y + s }, .{ .x = x + s, .y = y - s }, 3, yellow);
}

/// Top-right minimap: loaded chunks (green), visible rect (yellow),
/// camera chunk (red dot). Makes the prefetch ring visible at a glance.
fn drawMinimap(world: *const World, vis: ChunkRange, cam: *const Cam) void {
    const panel_w: i32 = 180;
    const panel_h: i32 = 140;
    const x0 = rl.getScreenWidth() - panel_w - 12;
    const y0 = 12;

    rl.drawRectangle(x0, y0, panel_w, panel_h, hud_bg);
    rl.drawRectangleLines(x0, y0, panel_w, panel_h, .dark_gray);

    const cell: i32 = 4;
    const cam_cx = @divFloor(@as(i32, @intFromFloat(cam.x)), CHUNK_PX);
    const cam_cy = @divFloor(@as(i32, @intFromFloat(cam.y)), CHUNK_PX);
    const center_x = x0 + panel_w / 2;
    const center_y = y0 + panel_h / 2;

    var it = world.by_key.valueIterator();
    while (it.next()) |slot_ptr| {
        const c = slot_ptr.*;
        const mx = center_x + (c.cx - cam_cx) * cell;
        const my = center_y + (c.cy - cam_cy) * cell;
        if (mx < x0 + 1 or mx >= x0 + panel_w - cell) continue;
        if (my < y0 + 1 or my >= y0 + panel_h - cell) continue;
        rl.drawRectangle(mx, my, cell - 1, cell - 1, rl.Color.init(80, 170, 100, 255));
    }

    const vx = center_x + (vis.cx0 - cam_cx) * cell;
    const vy = center_y + (vis.cy0 - cam_cy) * cell;
    rl.drawRectangleLinesEx(
        .{
            .x = @floatFromInt(vx),
            .y = @floatFromInt(vy),
            .width = @floatFromInt((vis.cx1 - vis.cx0 + 1) * cell),
            .height = @floatFromInt((vis.cy1 - vis.cy0 + 1) * cell),
        },
        1.0,
        .yellow,
    );

    rl.drawRectangle(center_x - 1, center_y - 1, 3, 3, .red);
}

fn hudLine(buf: []u8, y: i32, comptime fmt: []const u8, args: anytype) void {
    const text = std.mem.printSentinel(buf, fmt, args, 0) catch unreachable;
    rl.drawText(text, 18, y, 16, .light_gray);
}

fn drawHud(world: *const World, vis: ChunkRange, cam: *const Cam, settings: DebugSettings) void {
    const panel_w: i32 = 620;
    const panel_h: i32 = 182;
    rl.drawRectangle(8, 8, panel_w, panel_h, hud_bg);
    rl.drawRectangleLines(8, 8, panel_w, panel_h, .dark_gray);

    var buf: [192]u8 = undefined;
    const title = std.mem.printSentinel(
        &buf,
        "chunk debug - {d}x{d} tiles of {d}px",
        .{ CHUNK_TILES, CHUNK_TILES, TILE_PX },
        0,
    ) catch unreachable;
    rl.drawText(title, 18, 16, 20, .white);

    // FPS badge, right-aligned on the header row. Thresholds track the target:
    // lime at >= 90%, orange at >= 50%, red below.
    const fps = rl.getFPS();
    const fps_color = if (fps >= TARGET_FPS * 9 / 10)
        rl.Color.lime
    else if (fps >= TARGET_FPS / 2)
        rl.Color.orange
    else
        rl.Color.red;
    var fps_buf: [16]u8 = undefined;
    const fps_text = std.mem.printSentinel(&fps_buf, "{d} FPS", .{fps}, 0) catch unreachable;
    const fps_x = 8 + panel_w - 14 - rl.measureText(fps_text, 20);
    rl.drawText(fps_text, fps_x, 16, 20, fps_color);

    const cx = @divFloor(@as(i32, @intFromFloat(cam.x)), CHUNK_PX);
    const cy = @divFloor(@as(i32, @intFromFloat(cam.y)), CHUNK_PX);
    hudLine(&buf, 40, "camera chunk ({d},{d})   visible {d} ({d}x{d})", .{
        cx,
        cy,
        vis.count(),
        vis.cols(),
        vis.rows(),
    });

    hudLine(&buf, 60, "loaded {d}/{d} wanted   generated {d}   unloaded {d}", .{
        world.by_key.count(),
        world.wanted,
        world.generated,
        world.unloaded,
    });

    hudLine(&buf, 80, "prefetch margin: {d} chunks   |   drag mouse or WASD to pan", .{
        PREFETCH_MARGIN_CHUNKS,
    });

    hudLine(&buf, 100, "G tile borders [{s}]   B chunk borders [{s}]", .{
        onOff(settings.tile_grid),
        onOff(settings.chunk_borders),
    });

    const memory = world.memoryStats();
    hudLine(&buf, 120, "resident: {d}.{d} KiB   pool backing: {d}.{d} KiB", .{
        memory.resident_bytes / 1024,
        (memory.resident_bytes % 1024) * 10 / 1024,
        memory.pool_backing_bytes / 1024,
        (memory.pool_backing_bytes % 1024) * 10 / 1024,
    });
    hudLine(&buf, 140, "map: {d} slots   unload scratch: {d} keys ({d}.{d} KiB)", .{
        memory.map_slots,
        memory.scratch_keys,
        memory.scratch_bytes / 1024,
        (memory.scratch_bytes % 1024) * 10 / 1024,
    });
    hudLine(&buf, 160, "stream: {s}", .{
        if (world.memory_pressure) "OUT OF MEMORY - incomplete, retrying visible first" else "ok",
    });
}

fn onOff(v: bool) []const u8 {
    return if (v) "on" else "off";
}

// ── entry point ──────────────────────────────────────────────────────────────

pub fn run(alloc: std.mem.Allocator) !void {
    const screen_w = 1000;
    const screen_h = 640;

    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(screen_w, screen_h, "haystack — chunk streaming test");
    defer rl.closeWindow();
    rl.setTargetFPS(TARGET_FPS);

    var cam = Cam{};
    const initial_vw: f32 = @floatFromInt(rl.getScreenWidth());
    const initial_vh: f32 = @floatFromInt(rl.getScreenHeight());
    const initial_vis = try visibleRange(cam.raylib(initial_vw, initial_vh), initial_vw, initial_vh);
    const initial_capacity = @max(MIN_PREHEATED_CHUNKS, @as(usize, @intCast(initial_vis.expanded(PREFETCH_MARGIN_CHUNKS).count())));
    var world = try World.init(alloc, initial_capacity);
    defer world.deinit();

    var settings = DebugSettings{};

    // Optional: HAYSTACK_SHOT=/path.png grabs a frame and exits (handy for CI).
    const shot_path: ?[:0]const u8 = if (std.c.getenv("HAYSTACK_SHOT")) |p| std.mem.span(p) else null;
    var shot_frames: i32 = if (shot_path != null) 5 else -1;
    var shot_pending = false;

    while (!rl.windowShouldClose()) {
        const vw: f32 = @floatFromInt(rl.getScreenWidth());
        const vh: f32 = @floatFromInt(rl.getScreenHeight());

        cam.update(rl.getFrameTime());

        if (rl.isKeyPressed(.g)) settings.tile_grid = !settings.tile_grid;
        if (rl.isKeyPressed(.b)) settings.chunk_borders = !settings.chunk_borders;

        const rc = cam.raylib(vw, vh);
        const vis = try visibleRange(rc, vw, vh);

        const was_under_pressure = world.memory_pressure;
        stream(&world, vis) catch |err| switch (err) {
            // Only allocation pressure is transient. A coordinate error means
            // the camera/view cannot be represented and must stop the frame
            // loop instead of spinning with a clamped or wrapped view.
            error.OutOfMemory => {
                // Keep drawing whatever is available and retry next frame. Log
                // once per pressure episode rather than flooding at 120 Hz.
                if (!was_under_pressure) std.log.warn("Chunk streaming incomplete: {s}; prioritizing visible chunks", .{@errorName(err)});
            },
            error.CoordinateOutOfBounds => return err,
        };

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.init(24, 24, 28, 255));

        rl.beginMode2D(rc);
        drawWorld(&world, vis, settings);
        drawCameraMarker(&cam);
        rl.endMode2D();

        drawHud(&world, vis, &cam, settings);
        drawMinimap(&world, vis, &cam);

        if (shot_frames >= 0) {
            if (shot_frames == 0) {
                // Screenshot only after EndDrawing has presented the frame:
                // raylib batches draws, so mid-frame the HUD is still pending.
                shot_pending = true;
                break;
            }
            shot_frames -= 1;
        }
    }

    if (shot_pending) rl.takeScreenshot(shot_path.?);
}

test "stream keeps visible chunks plus a 2-chunk margin" {
    const alloc = std.testing.allocator;

    var world = try World.init(alloc, MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    const vis = ChunkRange{ .cx0 = 0, .cy0 = 0, .cx1 = 3, .cy1 = 2 };
    try stream(&world, vis);

    // x: -2..5 (8 cols), y: -2..4 (7 rows)
    try std.testing.expectEqual(@as(usize, 8 * 7), world.by_key.count());
    try std.testing.expect(world.get(-2, -2) != null);
    try std.testing.expect(world.get(5, 4) != null);
    try std.testing.expect(world.get(6, 0) == null);

    // Pan 4 chunks right: the left column must be unloaded, the right loaded.
    const vis2 = ChunkRange{ .cx0 = 4, .cy0 = 0, .cx1 = 7, .cy1 = 2 };
    try stream(&world, vis2);

    try std.testing.expectEqual(@as(usize, 8 * 7), world.by_key.count());
    try std.testing.expect(world.get(-2, 0) == null);
    try std.testing.expect(world.get(2, 0) != null);
    try std.testing.expect(world.get(9, 0) != null);

    // Everything still loaded is inside the new ring, nothing outside.
    var it = world.by_key.valueIterator();
    while (it.next()) |slot_ptr| {
        const c = slot_ptr.*;
        try std.testing.expect(c.cx >= 2 and c.cx <= 9);
        try std.testing.expect(c.cy >= -2 and c.cy <= 4);
    }
}

test "ring larger than the startup reserve does not thrash" {
    var world = try World.init(std.testing.allocator, MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    // vis 31x21 -> ring 35x25 = 875 chunks, above the startup reserve.
    const vis = ChunkRange{ .cx0 = 0, .cy0 = 0, .cx1 = 30, .cy1 = 20 };
    try stream(&world, vis);

    try std.testing.expectEqual(@as(usize, 875), world.by_key.count());
    try std.testing.expectEqual(@as(usize, 875), world.wanted);
    try std.testing.expectEqual(@as(u64, 875), world.generated);

    try stream(&world, vis);
    try std.testing.expectEqual(@as(u64, 875), world.generated);
    try std.testing.expectEqual(@as(u64, 0), world.unloaded);
}

test "startup reserve is small and covers the unload list and map" {
    var world = try World.init(std.testing.allocator, MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    const memory = world.memoryStats();
    try std.testing.expectEqual(@as(usize, 0), memory.resident_bytes);
    try std.testing.expect(memory.pool_backing_bytes >= MIN_PREHEATED_CHUNKS * @sizeOf(Chunk));
    try std.testing.expect(memory.pool_backing_bytes < 512 * @sizeOf(Chunk));
    try std.testing.expect(memory.map_slots >= MIN_PREHEATED_CHUNKS);
    try std.testing.expectEqual(MIN_PREHEATED_CHUNKS, memory.scratch_keys);
}

test "stationary frames panning and teleports reuse reserved memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var world = try World.init(failing.allocator(), MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    const vis = ChunkRange{ .cx0 = 0, .cy0 = 0, .cx1 = 2, .cy1 = 2 };
    try stream(&world, vis);
    const generated = world.generated;
    const memory = world.memoryStats();
    const allocations = failing.allocations;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try stream(&world, vis);
    try std.testing.expectEqual(generated, world.generated);
    for (0..32) |i| {
        const x: i32 = @intCast(i);
        try stream(&world, .{ .cx0 = x, .cy0 = 0, .cx1 = x + 2, .cy1 = 2 });
    }
    try stream(&world, .{ .cx0 = -1000, .cy0 = -1000, .cx1 = -998, .cy1 = -998 });
    try std.testing.expectEqual(@as(usize, 49), world.by_key.count());
    try std.testing.expectEqual(memory.pool_backing_bytes, world.memoryStats().pool_backing_bytes);
    try std.testing.expectEqual(allocations, failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}

test "memory statistics retain the high water mark after the view shrinks" {
    var world = try World.init(std.testing.allocator, MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    try stream(&world, .{ .cx0 = 0, .cy0 = 0, .cx1 = 30, .cy1 = 20 });
    const large = world.memoryStats();
    try stream(&world, .{ .cx0 = 0, .cy0 = 0, .cx1 = 0, .cy1 = 0 });
    const small = world.memoryStats();

    try std.testing.expectEqual(@as(usize, 25), world.wanted);
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
    try std.testing.expectError(error.OutOfMemory, stream(&world, vis));
    try std.testing.expect(world.memory_pressure);
    try std.testing.expect(world.get(10, 10) != null);
    try std.testing.expect(world.get(8, 8) == null);
    try std.testing.expectEqual(@as(usize, 1), world.by_key.count());

    // Eviction and visible loading still work with allocations disabled.
    const moved = ChunkRange{ .cx0 = -10, .cy0 = -10, .cx1 = -10, .cy1 = -10 };
    try std.testing.expectError(error.OutOfMemory, stream(&world, moved));
    try std.testing.expect(world.get(10, 10) == null);
    try std.testing.expect(world.get(-10, -10) != null);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try stream(&world, moved);
    try std.testing.expect(!world.memory_pressure);
    try std.testing.expectEqual(@as(usize, 25), world.by_key.count());
}

test "initialization and streaming clean up every allocation failure" {
    const Exercise = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var world = try World.init(alloc, MIN_PREHEATED_CHUNKS);
            defer world.deinit();

            try stream(&world, .{ .cx0 = 0, .cy0 = 0, .cx1 = 2, .cy1 = 2 });
            try stream(&world, .{ .cx0 = -40, .cy0 = -30, .cx1 = -10, .cy1 = -10 });
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Exercise.run, .{});
}

// A camera shaped like `Cam.raylib`, so tests exercise the same transform as
// the frame loop without initializing a raylib window.
fn testCamera(x: f32, y: f32, vw: f32, vh: f32) rl.Camera2D {
    return .{
        .offset = .{ .x = vw / 2, .y = vh / 2 },
        .target = .{ .x = x, .y = y },
        .rotation = 0,
        .zoom = 1,
    };
}

test "pixel bounds reject non-finite and f32 rounding at the i32 edges" {
    // NaN fails both comparisons; infinities fail the half-open range.
    try std.testing.expect(!pixelInI32Bounds(std.math.nan(f32)));
    try std.testing.expect(!pixelInI32Bounds(std.math.inf(f32)));
    try std.testing.expect(!pixelInI32Bounds(-std.math.inf(f32)));

    // Largest f32 below 2^31 is representable and converts to i32.
    try std.testing.expect(pixelInI32Bounds(2147483520));
    // 2^31 exactly is not: this is the rounding trap that a naive f32
    // comparison against `@floatFromInt(maxInt(i32))` would accept.
    try std.testing.expect(!pixelInI32Bounds(2147483648));
    // i32 min is valid and exactly representable; the next f32 below is not.
    try std.testing.expect(pixelInI32Bounds(-2147483648));
    try std.testing.expect(!pixelInI32Bounds(-2147483904));
}

test "visibleRange rejects non-finite camera targets on both axes" {
    const invalid = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };
    for (invalid) |value| {
        try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(value, 0, 1000, 640), 1000, 640));
        try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(0, value, 1000, 640), 1000, 640));
    }
}

test "visibleRange rejects the reproduced i32 overflow boundaries" {
    // These are the values from the Debug reproduction. 2147483008 fits in
    // i32 and its transformed corner (2147483520) still fits, but the chunk it
    // maps to has a full +CHUNK_PX extent past i32; 2147483648 already rounds
    // past the i32 conversion.
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(2147483008, 0, 1000, 640), 1000, 640));
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(-2147483008, 0, 1000, 640), 1000, 640));
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(2147483648, 0, 1000, 640), 1000, 640));
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(-2147483648, 0, 1000, 640), 1000, 640));

    // Same boundaries on Y, independently.
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(0, 2147483008, 1000, 640), 1000, 640));
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(0, -2147483008, 1000, 640), 1000, 640));
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(0, 2147483648, 1000, 640), 1000, 640));
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(0, -2147483648, 1000, 640), 1000, 640));
}

test "visibleRange validates transformed corners, not just the target" {
    // Target and top-left corner fit i32, but the far corner does not.
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(2000000000, 0, 1000000000, 0), 1000000000, 0));
    // Mirror: target and far corner fit, but the near corner is below i32 min.
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(-2000000000, 0, 1000000000, 0), 1000000000, 0));
}

test "visibleRange accepts ordinary and negative views" {
    const origin = try visibleRange(testCamera(0, 0, 1000, 640), 1000, 640);
    try std.testing.expectEqual(ChunkRange{ .cx0 = -1, .cy0 = -1, .cx1 = 0, .cy1 = 0 }, origin);

    // -10000 +/- 400 px and -20000 +/- 300 px, floor-divided per tile/chunk.
    const negative = try visibleRange(testCamera(-10000, -20000, 800, 600), 800, 600);
    try std.testing.expectEqual(ChunkRange{ .cx0 = -21, .cy0 = -40, .cx1 = -19, .cy1 = -39 }, negative);
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

test "visibleRange accepts the furthest prefetch-safe chunk edges" {
    // Visible chunk 4194300 leaves exactly the 2-chunk margin up to 4194302.
    const max_cam: f32 = @floatFromInt(4194300 * CHUNK_PX);
    const max_view = try visibleRange(testCamera(max_cam, 0, 0, 0), 0, 0);
    try std.testing.expectEqual(@as(i32, 4194300), max_view.cx0);
    try std.testing.expectEqual(@as(i32, 4194300), max_view.cx1);

    const too_far_pos: f32 = @floatFromInt(4194301 * CHUNK_PX);
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(too_far_pos, 0, 0, 0), 0, 0));

    // Mirror on the negative side.
    const min_cam: f32 = @floatFromInt(-4194302 * CHUNK_PX);
    const min_view = try visibleRange(testCamera(0, min_cam, 0, 0), 0, 0);
    try std.testing.expectEqual(@as(i32, -4194302), min_view.cy0);
    try std.testing.expectEqual(@as(i32, -4194302), min_view.cy1);

    const too_far_neg: f32 = @floatFromInt(-4194303 * CHUNK_PX);
    try std.testing.expectError(error.CoordinateOutOfBounds, visibleRange(testCamera(0, too_far_neg, 0, 0), 0, 0));
}

test "stream rejects malformed and oversized ranges before mutating the world" {
    var world = try World.init(std.testing.allocator, MIN_PREHEATED_CHUNKS);
    defer world.deinit();

    // Inverted rows/columns.
    try std.testing.expectError(error.CoordinateOutOfBounds, stream(&world, .{ .cx0 = 1, .cy0 = 0, .cx1 = 0, .cy1 = 0 }));
    try std.testing.expectError(error.CoordinateOutOfBounds, stream(&world, .{ .cx0 = 0, .cy0 = 1, .cx1 = 0, .cy1 = 0 }));

    // Extreme chunk indices fail before generation or eviction.
    try std.testing.expectError(error.CoordinateOutOfBounds, stream(&world, .{ .cx0 = 4194302, .cy0 = 0, .cx1 = 4194302, .cy1 = 0 }));
    try std.testing.expectError(error.CoordinateOutOfBounds, stream(&world, .{ .cx0 = 0, .cy0 = -4194304, .cx1 = 0, .cy1 = -4194304 }));

    // Individually drawable bounds, but the prefetch ring count exceeds i32.
    const wide = ChunkRange{ .cx0 = -4194302, .cy0 = -2, .cx1 = 4194300, .cy1 = 255 };
    try std.testing.expectError(error.CoordinateOutOfBounds, stream(&world, wide));

    try std.testing.expectEqual(@as(usize, 0), world.by_key.count());
    try std.testing.expectEqual(@as(u64, 0), world.generated);
    try std.testing.expect(!world.memory_pressure);

    // A valid range still streams normally after the rejections.
    try stream(&world, .{ .cx0 = 0, .cy0 = 0, .cx1 = 0, .cy1 = 0 });
    try std.testing.expectEqual(@as(usize, 25), world.by_key.count());
    try std.testing.expect(!world.memory_pressure);
}
