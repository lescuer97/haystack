//! Read-only rendering of the world, camera marker, HUD, and minimap.
//!
//! Every function here borrows `GameState` and a calculated `View` as `const`.
//! Nothing in this file polls input, moves the camera, streams chunks, or
//! mutates persistent state. It only decides what pixels represent the state
//! that the update stage already produced.

const std = @import("std");
const rl = @import("raylib");

const camera = @import("camera.zig");
const game_mod = @import("game.zig");
const world = @import("world.zig");

/// Frame-rate target. The HUD's FPS colour thresholds are derived from it.
pub const target_fps: i32 = 120;

// ── colours ──────────────────────────────────────────────────────────────────

const grid_color = rl.Color.init(255, 255, 255, 55);
const border_color = rl.Color.init(220, 60, 55, 255);
const hud_bg = rl.Color.init(0, 0, 0, 170);
const tile_letter_color = rl.Color.init(235, 235, 240, 255);

/// Default-font size for the terrain letter drawn inside each tile.
const tile_letter_size: i32 = 20;

// ── drawing ──────────────────────────────────────────────────────────────────

/// Single uppercase letter identifying each terrain type. The switch is
/// exhaustive so a new `world.Tile` variant forces a rendering decision.
fn tileLetter(tile: world.Tile) u8 {
    return switch (tile) {
        .grass => 'G',
        .dirt => 'D',
        .rock => 'R',
    };
}

/// Top-left corner that centres a `text_w`×`text_h` label inside the tile whose
/// top-left corner is (`tx`, `ty`). Pure maths so the centring is testable
/// without a window or a loaded font.
fn centeredTextPos(tx: i32, ty: i32, text_w: i32, text_h: i32) struct { x: i32, y: i32 } {
    return .{
        .x = tx + @divTrunc(world.TILE_PX - text_w, 2),
        .y = ty + @divTrunc(world.TILE_PX - text_h, 2),
    };
}

fn drawChunk(chunk: *const world.Chunk, settings: game_mod.DebugSettings) void {
    const ox = chunk.cx * world.CHUNK_PX;
    const oy = chunk.cy * world.CHUNK_PX;

    if (settings.tile_grid) {
        var i: usize = 0;
        while (i <= world.CT) : (i += 1) {
            const off: i32 = @as(i32, @intCast(i)) * world.TILE_PX;
            rl.drawLine(ox + off, oy, ox + off, oy + world.CHUNK_PX, grid_color);
            rl.drawLine(ox, oy + off, ox + world.CHUNK_PX, oy + off, grid_color);
        }
    }

    if (settings.chunk_borders) {
        rl.drawRectangleLinesEx(
            .{
                .x = @floatFromInt(ox),
                .y = @floatFromInt(oy),
                .width = @floatFromInt(world.CHUNK_PX),
                .height = @floatFromInt(world.CHUNK_PX),
            },
            2.0,
            border_color,
        );
    }

    // Terrain letters always render, independent of the optional debug
    // overlays above. `measureText` and `drawText` use the same default font
    // and size, and the default font's glyph height matches `fontSize`.
    var ty: usize = 0;
    while (ty < world.CT) : (ty += 1) {
        var tx: usize = 0;
        while (tx < world.CT) : (tx += 1) {
            var text: [2:0]u8 = .{ tileLetter(chunk.tiles[ty * world.CT + tx]), 0 };
            const text_w = rl.measureText(&text, tile_letter_size);
            const pos = centeredTextPos(
                ox + @as(i32, @intCast(tx)) * world.TILE_PX,
                oy + @as(i32, @intCast(ty)) * world.TILE_PX,
                text_w,
                tile_letter_size,
            );
            rl.drawText(&text, pos.x, pos.y, tile_letter_size, tile_letter_color);
        }
    }
}

fn drawWorld(w: *const world.World, vis: world.ChunkRange, settings: game_mod.DebugSettings) void {
    var cy = vis.cy0;
    while (cy <= vis.cy1) : (cy += 1) {
        var cx = vis.cx0;
        while (cx <= vis.cx1) : (cx += 1) {
            const chunk = w.get(cx, cy) orelse continue;
            drawChunk(chunk, settings);
        }
    }

    // world origin marker, so negative coordinates are obvious
    rl.drawLine(-40, 0, 40, 0, .red);
    rl.drawLine(0, -40, 0, 40, .green);
    rl.drawRectangleLinesEx(.{ .x = -5, .y = -5, .width = 10, .height = 10 }, 2.0, .yellow);
}

/// Yellow X marking the camera target, drawn in world space from the view's
/// calculated pixel target.
fn drawCameraMarker(target: rl.Vector2) void {
    const s: f32 = 14;
    const yellow = rl.Color.init(255, 220, 0, 255);
    const x = target.x;
    const y = target.y;

    // Dark under-stroke so the X stays readable on light grass.
    rl.drawLineEx(.{ .x = x - s, .y = y - s }, .{ .x = x + s, .y = y + s }, 5, .black);
    rl.drawLineEx(.{ .x = x - s, .y = y + s }, .{ .x = x + s, .y = y - s }, 5, .black);
    rl.drawLineEx(.{ .x = x - s, .y = y - s }, .{ .x = x + s, .y = y + s }, 3, yellow);
    rl.drawLineEx(.{ .x = x - s, .y = y + s }, .{ .x = x + s, .y = y - s }, 3, yellow);
}

/// Top-right minimap: loaded chunks (green), visible rect (yellow),
/// camera chunk (red dot). Makes the prefetch ring visible at a glance.
fn drawMinimap(w: *const world.World, vis: world.ChunkRange, cam: *const camera.Camera) void {
    const panel_w: i32 = 180;
    const panel_h: i32 = 140;
    const x0 = rl.getScreenWidth() - panel_w - 12;
    const y0 = 12;

    rl.drawRectangle(x0, y0, panel_w, panel_h, hud_bg);
    rl.drawRectangleLines(x0, y0, panel_w, panel_h, .dark_gray);

    const cell: i32 = 4;
    const cam_cx = cam.chunkX();
    const cam_cy = cam.chunkY();
    const center_x = x0 + panel_w / 2;
    const center_y = y0 + panel_h / 2;

    var it = w.residents();
    while (it.next()) |c| {
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

fn drawHud(
    w: *const world.World,
    vis: world.ChunkRange,
    cam: *const camera.Camera,
    settings: game_mod.DebugSettings,
) void {
    const panel_w: i32 = 620;
    const panel_h: i32 = 182;
    rl.drawRectangle(8, 8, panel_w, panel_h, hud_bg);
    rl.drawRectangleLines(8, 8, panel_w, panel_h, .dark_gray);

    var buf: [192]u8 = undefined;
    const title = std.mem.printSentinel(
        &buf,
        "chunk debug - {d}x{d} tiles of {d}px",
        .{ world.CHUNK_TILES, world.CHUNK_TILES, world.TILE_PX },
        0,
    ) catch unreachable;
    rl.drawText(title, 18, 16, 20, .white);

    // FPS badge, right-aligned on the header row. Thresholds track the target:
    // lime at >= 90%, orange at >= 50%, red below.
    const fps = rl.getFPS();
    const fps_color = if (fps >= target_fps * 9 / 10)
        rl.Color.lime
    else if (fps >= target_fps / 2)
        rl.Color.orange
    else
        rl.Color.red;
    var fps_buf: [16]u8 = undefined;
    const fps_text = std.mem.printSentinel(&fps_buf, "{d} FPS", .{fps}, 0) catch unreachable;
    const fps_x = 8 + panel_w - 14 - rl.measureText(fps_text, 20);
    rl.drawText(fps_text, fps_x, 16, 20, fps_color);

    const stats = w.stats();
    hudLine(&buf, 40, "tile {d},{d} chunk {d},{d} vis {d} ({d}x{d})", .{
        cam.tile_x,
        cam.tile_y,
        cam.chunkX(),
        cam.chunkY(),
        vis.count(),
        vis.cols(),
        vis.rows(),
    });

    hudLine(&buf, 60, "loaded {d}/{d} wanted   generated {d}   unloaded {d}", .{
        stats.resident_chunks,
        stats.wanted_chunks,
        stats.generated,
        stats.unloaded,
    });

    hudLine(&buf, 80, "WASD/arrows/pad+stick: hold steps 1 tile   drag pans   prefetch {d} chunks", .{
        world.PREFETCH_MARGIN_CHUNKS,
    });

    hudLine(&buf, 100, "G tile borders [{s}]   B chunk borders [{s}]", .{
        onOff(settings.tile_grid),
        onOff(settings.chunk_borders),
    });

    hudLine(&buf, 120, "resident: {d}.{d} KiB   pool backing: {d}.{d} KiB", .{
        stats.resident_bytes / 1024,
        (stats.resident_bytes % 1024) * 10 / 1024,
        stats.pool_backing_bytes / 1024,
        (stats.pool_backing_bytes % 1024) * 10 / 1024,
    });
    hudLine(&buf, 140, "map: {d} slots   unload scratch: {d} keys ({d}.{d} KiB)", .{
        stats.map_slots,
        stats.scratch_keys,
        stats.scratch_bytes / 1024,
        (stats.scratch_bytes % 1024) * 10 / 1024,
    });
    hudLine(&buf, 160, "stream: {s}", .{
        if (stats.memory_pressure) "OUT OF MEMORY - incomplete, retrying visible first" else "ok",
    });
}

fn onOff(v: bool) []const u8 {
    return if (v) "on" else "off";
}

/// Draw one complete frame using only read-only state and the calculated view.
/// The caller owns `beginDrawing`/`endDrawing` so presentation and the optional
/// screenshot stay visible in `main`.
pub fn draw(game: *const game_mod.GameState, view: camera.View) void {
    rl.clearBackground(rl.Color.init(24, 24, 28, 255));

    rl.beginMode2D(view.transform);
    drawWorld(&game.world, view.chunks, game.debug);
    drawCameraMarker(view.transform.target);
    rl.endMode2D();

    drawHud(&game.world, view.chunks, &game.camera, game.debug);
    drawMinimap(&game.world, view.chunks, &game.camera);
}

test "every terrain type has its own uppercase letter" {
    const cases = [_]struct { tile: world.Tile, letter: u8 }{
        .{ .tile = .grass, .letter = 'G' },
        .{ .tile = .dirt, .letter = 'D' },
        .{ .tile = .rock, .letter = 'R' },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.letter, tileLetter(c.tile));
        try std.testing.expect(c.letter >= 'A' and c.letter <= 'Z');
    }
}

test "tile labels are centred on the tile in both axes" {
    const cases = [_]struct { tx: i32, ty: i32, w: i32, h: i32 }{
        .{ .tx = 0, .ty = 0, .w = 11, .h = 20 },
        .{ .tx = 32, .ty = 64, .w = 20, .h = 20 },
        .{ .tx = -96, .ty = -32, .w = 7, .h = 16 },
    };
    for (cases) |c| {
        const pos = centeredTextPos(c.tx, c.ty, c.w, c.h);
        const tile_cx = c.tx + @divTrunc(world.TILE_PX, 2);
        const tile_cy = c.ty + @divTrunc(world.TILE_PX, 2);
        const text_cx = pos.x + @divTrunc(c.w, 2);
        const text_cy = pos.y + @divTrunc(c.h, 2);
        // Integer division can leave the label one pixel off centre.
        try std.testing.expect(@abs(tile_cx - text_cx) <= 1);
        try std.testing.expect(@abs(tile_cy - text_cy) <= 1);
    }
}
