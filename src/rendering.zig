//! Read-only rendering of the world, camera marker, HUD, minimap, and menu.
//!
//! Every function here borrows `GameState` and a calculated `View` as `const`.
//! Nothing in this file polls input, moves the camera, streams chunks, or
//! mutates persistent state. It only decides what pixels represent the state
//! that the update stage already produced.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

const camera = @import("camera.zig");
const game_mod = @import("game.zig");
const menu = @import("menu.zig");
const onboarding = @import("onboarding.zig");
const world = @import("world.zig");
const terrain = @import("shared").world;

/// Frame-rate target. The HUD's FPS colour thresholds are derived from it.
pub const target_fps: i32 = 120;

const grass_asset = "assets/Tileset/Tileset Grass Spring.png";
const grass_sheet_width = 192;
const grass_sheet_height = 64;
const grass_source = rl.Rectangle{ .x = 144, .y = 32, .width = 16, .height = 16 };
const maple_asset = "assets/Objects/Maple Tree.png";
const maple_sheet_width = 160;
const maple_sheet_height = 48;
const maple_source = rl.Rectangle{ .x = 96, .y = 0, .width = 32, .height = 48 };

fn mapleDest(x: f32, y: f32) rl.Rectangle {
    return .{ .x = x - 16, .y = y - 64, .width = 64, .height = 96 };
}

// Quadrants TL, TR, BL, BR; columns convex, horizontal boundary, vertical
// boundary, concave, solid. Each measured atlas crop is 8x8, drawn at 2x.
const grass_quadrants = [4][5][2]f32{
    .{ .{ 128, 0 }, .{ 32, 0 }, .{ 128, 16 }, .{ 112, 0 }, .{ 144, 32 } },
    .{ .{ 184, 0 }, .{ 40, 0 }, .{ 120, 16 }, .{ 72, 0 }, .{ 152, 32 } },
    .{ .{ 128, 56 }, .{ 144, 56 }, .{ 128, 24 }, .{ 64, 8 }, .{ 144, 40 } },
    .{ .{ 184, 56 }, .{ 152, 56 }, .{ 120, 24 }, .{ 120, 8 }, .{ 152, 40 } },
};
// Neighbor order NW, N, NE, W, E, SW, S, SE.
const grass_neighbor_offsets = [8][2]i32{
    .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 }, .{ -1, 0 },
    .{ 1, 0 },   .{ -1, 1 }, .{ 0, 1 },  .{ 1, 1 },
};
const grass_quadrant_neighbors = [4][3]usize{
    .{ 1, 3, 0 }, .{ 1, 4, 2 }, .{ 6, 3, 5 }, .{ 6, 4, 7 },
};

fn isGrassGround(tile: world.Tile) bool {
    return tile == .grass or tile == .tree;
}

fn isGrass(w: *const world.World, x: i32, y: i32) bool {
    if (w.get(@divFloor(x, world.CHUNK_TILES), @divFloor(y, world.CHUNK_TILES))) |chunk| {
        const lx: usize = @intCast(@mod(x, world.CHUNK_TILES));
        const ly: usize = @intCast(@mod(y, world.CHUNK_TILES));
        return isGrassGround(chunk.tiles[ly * world.CT + lx]);
    }
    // Prefetch normally supplies neighbors; missing residents need no allocation.
    return isGrassGround(terrain.sampleTile(terrain.public_seed, x, y));
}

fn grassNeighbors(w: *const world.World, x: i32, y: i32) [8]bool {
    var neighbors: [8]bool = undefined;
    for (grass_neighbor_offsets, 0..) |offset, i| {
        neighbors[i] = isGrass(w, x + offset[0], y + offset[1]);
    }
    return neighbors;
}

fn grassQuadrantSource(quadrant: usize, neighbors: [8]bool) rl.Rectangle {
    const indices = grass_quadrant_neighbors[quadrant];
    const v = neighbors[indices[0]];
    const h = neighbors[indices[1]];
    const d = neighbors[indices[2]];
    const kind: usize = if (!v and !h) 0 else if (!v) 1 else if (!h) 2 else if (!d) 3 else 4;
    const xy = grass_quadrants[quadrant][kind];
    return .{ .x = xy[0], .y = xy[1], .width = 8, .height = 8 };
}

fn grassQuadrantDest(x: f32, y: f32, quadrant: usize) rl.Rectangle {
    const half: f32 = @floatFromInt(@divExact(world.TILE_PX, 2));
    return .{
        .x = x + @as(f32, @floatFromInt(quadrant % 2)) * half,
        .y = y + @as(f32, @floatFromInt(quadrant / 2)) * half,
        .width = half,
        .height = half,
    };
}

fn loadAtlas(allocator: std.mem.Allocator, comptime asset: []const u8, width: i32, height: i32) !rl.Texture2D {
    const path: [:0]const u8 = if (builtin.os.tag == .emscripten)
        "/" ++ asset
    else
        try std.fs.path.joinZ(allocator, &.{ rl.getApplicationDirectory(), asset });
    defer if (builtin.os.tag != .emscripten) allocator.free(path);
    const texture = rl.loadTexture(path) catch |err| {
        std.log.err("texture: cannot load path={s} error={s}", .{ path, @errorName(err) });
        return err;
    };
    errdefer rl.unloadTexture(texture);
    if (texture.width != width or texture.height != height) {
        std.log.err("texture: invalid dimensions path={s} expected={d}x{d} actual={d}x{d}", .{ path, width, height, texture.width, texture.height });
        return error.InvalidTextureDimensions;
    }
    rl.setTextureFilter(texture, .point);
    return texture;
}

/// Window-owned GPU resources, separate from persistent game/world state.
pub const Resources = struct {
    grass: rl.Texture2D,
    maple: rl.Texture2D,

    pub fn init(allocator: std.mem.Allocator) !Resources {
        const grass = try loadAtlas(allocator, grass_asset, grass_sheet_width, grass_sheet_height);
        errdefer rl.unloadTexture(grass);
        return .{
            .grass = grass,
            .maple = try loadAtlas(allocator, maple_asset, maple_sheet_width, maple_sheet_height),
        };
    }

    pub fn deinit(self: *const Resources) void {
        rl.unloadTexture(self.grass);
        rl.unloadTexture(self.maple);
    }
};

// ── colours ──────────────────────────────────────────────────────────────────

const grid_color = rl.Color.init(255, 255, 255, 55);
const border_color = rl.Color.init(220, 60, 55, 255);
const hud_bg = rl.Color.init(0, 0, 0, 170);
const tile_letter_color = rl.Color.init(235, 235, 240, 255);

const menu_backdrop = rl.Color.init(0, 0, 0, 165);
const menu_panel_bg = rl.Color.init(28, 28, 34, 250);
const menu_panel_border = rl.Color.init(88, 92, 106, 255);
const menu_item_bg = rl.Color.init(44, 46, 56, 255);
const menu_item_hover = rl.Color.init(62, 66, 80, 255);
const menu_item_focus = rl.Color.init(48, 58, 76, 255);
const menu_accent = rl.Color.init(110, 165, 245, 255);
const menu_title_color = rl.Color.init(245, 245, 250, 255);
const menu_text_color = rl.Color.init(225, 228, 235, 255);
const menu_muted = rl.Color.init(150, 155, 170, 255);

/// Default-font size for dirt and rock terrain labels.
const tile_letter_size: i32 = 20;

// ── drawing ──────────────────────────────────────────────────────────────────

/// Dirt and rock terrain labels; grass and trees use sprites. The switch is
/// exhaustive so a new `world.Tile` variant forces a rendering decision.
fn tileLetter(tile: world.Tile) ?u8 {
    return switch (tile) {
        .grass, .tree => null,
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

    // Dirt and rock terrain letters render independent of the optional debug
    // overlays above. `measureText` and `drawText` use the same default font
    // and size, and the default font's glyph height matches `fontSize`.
    var ty: usize = 0;
    while (ty < world.CT) : (ty += 1) {
        var tx: usize = 0;
        while (tx < world.CT) : (tx += 1) {
            const letter = tileLetter(chunk.tiles[ty * world.CT + tx]) orelse continue;
            var text: [2:0]u8 = .{ letter, 0 };
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

fn drawWorld(w: *const world.World, vis: world.ChunkRange, settings: game_mod.DebugSettings, resources: *const Resources) void {
    // One visible grass pass keeps texture draws together, below all overlays.
    var grass_cy = vis.cy0;
    while (grass_cy <= vis.cy1) : (grass_cy += 1) {
        var grass_cx = vis.cx0;
        while (grass_cx <= vis.cx1) : (grass_cx += 1) {
            const chunk = w.get(grass_cx, grass_cy) orelse continue;
            for (chunk.tiles, 0..) |tile, i| {
                if (!isGrassGround(tile)) continue;
                const tx = chunk.cx * world.CHUNK_TILES + @as(i32, @intCast(i % world.CT));
                const ty = chunk.cy * world.CHUNK_TILES + @as(i32, @intCast(i / world.CT));
                const x: f32 = @floatFromInt(tx * world.TILE_PX);
                const y: f32 = @floatFromInt(ty * world.TILE_PX);
                const neighbors = grassNeighbors(w, tx, ty);
                if (std.mem.allEqual(bool, &neighbors, true)) {
                    rl.drawTexturePro(resources.grass, grass_source, .{
                        .x = x,
                        .y = y,
                        .width = world.TILE_PX,
                        .height = world.TILE_PX,
                    }, .{ .x = 0, .y = 0 }, 0, .white);
                } else {
                    for (0..4) |quadrant| {
                        rl.drawTexturePro(resources.grass, grassQuadrantSource(quadrant, neighbors), grassQuadrantDest(x, y, quadrant), .{ .x = 0, .y = 0 }, 0, .white);
                    }
                }
            }
        }
    }

    // Canopies reach beyond their anchor chunk. Read only resident neighbors.
    const tree_range = vis.expanded(1);
    var tree_cy = tree_range.cy0;
    while (tree_cy <= tree_range.cy1) : (tree_cy += 1) {
        for (0..world.CT) |row| {
            var tree_cx = tree_range.cx0;
            while (tree_cx <= tree_range.cx1) : (tree_cx += 1) {
                const chunk = w.get(tree_cx, tree_cy) orelse continue;
                for (0..world.CT) |col| {
                    if (chunk.tiles[row * world.CT + col] != .tree) continue;
                    const x: f32 = @floatFromInt((tree_cx * world.CHUNK_TILES + @as(i32, @intCast(col))) * world.TILE_PX);
                    const y: f32 = @floatFromInt((tree_cy * world.CHUNK_TILES + @as(i32, @intCast(row))) * world.TILE_PX);
                    rl.drawTexturePro(resources.maple, maple_source, mapleDest(x, y), .{ .x = 0, .y = 0 }, 0, .white);
                }
            }
        }
    }

    // ponytail: debug overlays and D/R labels may cover canopies.
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
fn drawMinimap(w: *const world.World, vis: world.ChunkRange, cam: *const camera.Camera, viewport_w: f32) void {
    const panel_w: i32 = 180;
    const panel_h: i32 = 140;
    const x0 = @as(i32, @intFromFloat(viewport_w)) - panel_w - 12;
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

fn toRaylibRect(rect: menu.Rect) rl.Rectangle {
    return .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
}

fn drawSolidRect(rect: menu.Rect, color: rl.Color) void {
    rl.drawRectangle(
        @intFromFloat(rect.x),
        @intFromFloat(rect.y),
        @max(@as(i32, @intFromFloat(rect.width)), 1),
        @max(@as(i32, @intFromFloat(rect.height)), 1),
        color,
    );
}

fn drawCenteredText(text: [:0]const u8, rect: menu.Rect, font_size: i32, color: rl.Color) void {
    const text_w = rl.measureText(text, font_size);
    const x = rect.x + (rect.width - @as(f32, @floatFromInt(text_w))) / 2;
    const y = rect.y + (rect.height - @as(f32, @floatFromInt(font_size))) / 2;
    rl.drawText(text, @intFromFloat(x), @intFromFloat(y), font_size, color);
}

const input_label_size: i32 = 15;
const input_text_size: i32 = 18;

/// Draw one editable field inside its item row. Text is scrolled to keep the
/// caret visible and scissored to the field box, so a bounded 128-byte value
/// can never paint outside the menu. `selected` highlights the row when it is
/// not being edited; `focused` keeps the stronger accent and caret.
fn drawTextInput(
    rect: menu.Rect,
    label: [:0]const u8,
    value: [:0]const u8,
    focused: bool,
    selected: bool,
) void {
    const pad: f32 = 10;
    // Very short rows (tiny viewports) collapse to a single inline field.
    const compact = rect.height < 44;
    const label_height = @min(@as(f32, 18), @max(rect.height * 0.34, 1));
    const field_top = if (compact) rect.y + 2 else rect.y + label_height + 6;
    const field = menu.Rect{
        .x = rect.x + pad,
        .y = field_top,
        .width = @max(rect.width - pad * 2, 1),
        .height = if (compact)
            @max(rect.height - 4, 1)
        else
            @max(rect.y + rect.height - 6 - field_top, 1),
    };

    if (!compact) {
        rl.drawText(
            label,
            @intFromFloat(rect.x + pad),
            @intFromFloat(rect.y + 6),
            input_label_size,
            menu_muted,
        );
    }

    drawSolidRect(field, if (focused) menu_item_focus else menu_item_bg);
    rl.drawRectangleLinesEx(
        toRaylibRect(field),
        if (focused) 2.0 else 1.0,
        if (focused) menu_accent else if (selected) menu_item_hover else menu_panel_border,
    );

    const text_size: i32 = if (compact) 14 else input_text_size;
    const inner_pad: f32 = 8;
    const inner_w = @max(field.width - inner_pad * 2, 1);
    const text_x = field.x + inner_pad;
    const text_y = field.y + (field.height - @as(f32, @floatFromInt(text_size))) / 2;
    const value_w: f32 = @floatFromInt(rl.measureText(value, text_size));
    // Scroll just enough that the end of the text and the caret stay visible.
    const scroll = @max(value_w + 2 - inner_w, 0);
    const draw_x = text_x - scroll;

    const clip_x: i32 = @intFromFloat(field.x + 1);
    const clip_y: i32 = @intFromFloat(field.y + 1);
    const clip_w: i32 = @max(@as(i32, @intFromFloat(field.width - 2)), 1);
    const clip_h: i32 = @max(@as(i32, @intFromFloat(field.height - 2)), 1);

    rl.beginScissorMode(clip_x, clip_y, clip_w, clip_h);
    if (value.len == 0 and !focused) {
        rl.drawText("click to edit", @intFromFloat(text_x), @intFromFloat(text_y), text_size, menu_muted);
    } else {
        rl.drawText(value, @intFromFloat(draw_x), @intFromFloat(text_y), text_size, menu_text_color);
    }
    if (focused) {
        const caret_x: i32 = @intFromFloat(draw_x + value_w);
        const caret_y: i32 = @intFromFloat(field.y + 4);
        const caret_h: i32 = @max(@as(i32, @intFromFloat(field.height - 8)), 1);
        rl.drawRectangle(caret_x, caret_y, 2, caret_h, menu_accent);
    }
    rl.endScissorMode();
}

fn drawMenuItem(rect: menu.Rect, item: menu.MenuItem, state: *const menu.Menu, selected: bool) void {
    const incoming = (item == .navigate and item.navigate == .Deposit) or (item == .action and item.action == .deposit);
    const outgoing = (item == .navigate and item.navigate == .Withdraw) or (item == .action and item.action == .confirm_withdrawal);
    if (incoming or outgoing) {
        const color = if (outgoing) rl.Color.red else rl.Color.green;
        rl.drawRectangleLinesEx(toRaylibRect(rect), if (selected) 3 else 1, color);
        drawCenteredText(menu.itemLabel(item), rect, 20, if (item == .action and item.action == .confirm_withdrawal and !state.wallet.canConfirmWithdrawal()) menu_muted else color);
        return;
    }
    if (item == .action and item.action == .balance) {
        drawCenteredText(if (state.wallet.balance.len > 0) state.wallet.balance.z() else "Balance unavailable", rect, 20, menu_text_color);
        return;
    }
    const text_field = menu.itemField(item);
    if (text_field == .withdrawal_invoice) {
        rl.drawRectangleLinesEx(toRaylibRect(rect), if (state.isFocused(.withdrawal_invoice)) 2 else 1, menu_accent);
        drawWrapped(state.withdrawal_invoice.slice(), rect, 16, true);
        return;
    }
    const focused = if (text_field) |field| state.isFocused(field) else false;

    const fill = if (focused)
        menu_item_focus
    else if (selected)
        menu_item_hover
    else
        menu_item_bg;
    const border = if (focused) menu_accent else if (selected) menu_item_hover else menu_panel_border;

    drawSolidRect(rect, fill);
    rl.drawRectangleLinesEx(toRaylibRect(rect), if (focused) 2.0 else 1.0, border);

    switch (item) {
        .text_input => |field| drawTextInput(
            rect,
            menu.itemLabel(item),
            state.textFieldConst(field).cString(),
            state.isFocused(field),
            selected,
        ),
        .navigate, .action => drawCenteredText(
            if (item == .navigate and item.navigate == .Wallet and state.currentPage != .Main) "Back" else menu.itemLabel(item),
            rect,
            if (rect.height < 32) 14 else 20,
            if (item == .action and ((item.action == .review_again and !state.wallet.withdrawal.retry_review_allowed) or (item.action == .review_withdrawal and !state.wallet.canPrepareWithdrawal(state.withdrawal_invoice.slice())))) menu_muted else menu_text_color,
        ),
    }
}

/// Modal menu, drawn in screen space after the world, HUD, and minimap. It only
/// reads menu state and the viewport size passed down by `main`. Pointer and
/// direction input were already sampled by `input.Reader` and applied to
/// `Menu.selected_index`, so the row highlight is a single piece of state
/// rather than a separate hover that can drift from the selection.
fn drawMenu(game: *const game_mod.GameState, viewport_w: f32, viewport_h: f32) void {
    const state = &game.menu;
    const layout = state.layoutFor(viewport_w, viewport_h);

    rl.drawRectangle(
        0,
        0,
        @intFromFloat(@max(viewport_w, 0)),
        @intFromFloat(@max(viewport_h, 0)),
        menu_backdrop,
    );

    drawSolidRect(layout.panel, menu_panel_bg);
    rl.drawRectangleLinesEx(toRaylibRect(layout.panel), 2.0, menu_panel_border);
    drawCenteredText(menu.pageTitle(state.currentPage), layout.title, 26, menu_title_color);
    if (state.currentPage != .Main) drawWalletContent(state, layout.content);

    const page_items = state.items();

    var index: usize = 0;
    while (index < layout.item_count) : (index += 1) {
        drawMenuItem(layout.items[index], page_items[index], state, state.isSelected(index));
    }
}

fn drawWalletContent(state: *const menu.Menu, rect: menu.Rect) void {
    if (rect.width < 2 or rect.height < 2) return;
    const model = &state.wallet;
    const x: i32 = @intFromFloat(rect.x);
    const y: i32 = @intFromFloat(rect.y);
    rl.beginScissorMode(x, y, @intFromFloat(rect.width), @intFromFloat(rect.height));
    defer rl.endScissorMode();
    if (state.currentPage == .History) {
        if (model.pending and model.operation == .history) {
            rl.drawText("Loading history...", x, y, 18, menu_muted);
        } else if (model.history_error) {
            rl.drawText(if (model.available) "History read failed; saved quotes preserved. Back and retry." else "Wallet unavailable; data preserved. Restart app to retry.", x, y, 16, menu_muted);
        } else if (!model.available) {
            rl.drawText(if (model.pending) "Loading history..." else "History unavailable; data preserved", x, y, 18, menu_muted);
        } else if (model.row_count == 0) {
            rl.drawText("No saved quotes", x, y, 18, menu_muted);
        } else {
            const row_height = rect.height / 8;
            for (model.rows[0..model.row_count], 0..) |*row, index| {
                const top = rect.y + @as(f32, @floatFromInt(index)) * row_height;
                if (state.isRowSelected(index)) rl.drawRectangleLinesEx(toRaylibRect(.{ .x = rect.x, .y = top, .width = rect.width, .height = row_height }), 2, menu_accent);
                const label_rect = menu.Rect{ .x = rect.x + 2, .y = top + 2, .width = 82, .height = @max(1, @min(28, row_height - 4)) };
                const color = if (row.outgoing) rl.Color.red else rl.Color.green;
                rl.drawRectangleLinesEx(toRaylibRect(label_rect), 1, color);
                drawCenteredText(if (row.outgoing) "Withdraw" else "Deposit", label_rect, 16, color);
                const text_size: i32 = @intFromFloat(@max(1, @min(20, (row_height - 4) / 2)));
                rl.drawText(row.text.z(), x + 90, @intFromFloat(top + 2), text_size, menu_text_color);
            }
        }
        return;
    }
    if (state.currentPage == .Withdraw or state.currentPage == .Withdrawal) {
        const message = if (model.withdrawal_error_status != 0) model.withdrawalFailureMessage() else model.message.slice();
        drawWrapped(message, .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = if (state.currentPage == .Withdraw) 30 else 52 }, 13, false);
        if (state.currentPage == .Withdraw) {
            if (model.prepareWithdrawalReason(state.withdrawal_invoice.slice())) |reason| drawWrapped(reason, .{ .x = rect.x, .y = rect.y + 32, .width = rect.width, .height = 28 }, 13, false);
            return;
        }
        if (model.withdrawal_loading) {
            rl.drawText("Loading selected saved withdrawal...", x, y + 55, 16, menu_muted);
            return;
        }
        const view = &model.withdrawal;
        if (view.quote_id.len == 0) return;
        var buf: [1024:0]u8 = @splat(0);
        const text = if (model.reviewLive())
            std.fmt.bufPrint(&buf, "Amount: {s} sat\nRouting fee reserve: {s} sat\nCashu swap fee: {s} sat | input fee: {s} sat\nEstimated total: {s} sat (not a guaranteed cap)\nQuote expiry (Unix): {s} | invoice expiry: {s}\nCDK status: {s} | quote: {s}{s}", .{ view.amount.slice(), view.fee_reserve.slice(), view.swap_fee.slice(), view.input_fee.slice(), view.estimated_total.slice(), view.quote_expiry.slice(), view.invoice_expiry.slice(), @tagName(view.status), view.quote_state.slice(), if (view.expired) " | expired" else "" }) catch "Details exceed display limit"
        else
            std.fmt.bufPrint(&buf, "Amount: {s} sat\nQuote expiry (Unix): {s}\nInvoice expiry (Unix): {s}\nCDK status: {s} | quote: {s}{s}", .{ view.amount.slice(), view.quote_expiry.slice(), view.invoice_expiry.slice(), @tagName(view.status), view.quote_state.slice(), if (view.expired) " | expired" else "" }) catch "Details exceed display limit";
        drawWrapped(text, .{ .x = rect.x, .y = rect.y + 56, .width = rect.width, .height = @max(1, rect.height - 56) }, 16, false);
        return;
    }
    if (state.currentPage == .Invoice and model.invoice.len != 0 and !model.expired) {
        const pixels: u32 = @intFromFloat(@max(0, @min(rect.height - 46, rect.width * 0.48)));
        if (model.qr.size() == 0 or model.qr.scale(pixels) == 0) {
            rl.drawText(if (model.qr.size() == 0) "QR unavailable / invoice too long" else "Viewport too small for QR", x, y, 14, menu_muted);
            return;
        }
    }
    rl.drawText(model.message.z(), x, y, 13, menu_muted);
    if (state.currentPage != .Invoice) {
        rl.drawText(model.mint.z(), x, y + 23, 13, menu_muted);
        return;
    }
    if (model.selection_loading) {
        rl.drawText("Loading selected saved invoice...", x, y + 20, 16, menu_muted);
        return;
    }
    if (!model.canCopyInvoice()) return;
    rl.drawText(if (model.expired) "EXPIRED" else model.quote_state.z(), x, y + 20, 16, menu_text_color);
    if (model.expired) {
        rl.drawText("Invoice expired. Create a new deposit.", x, y + 44, 14, menu_muted);
        return;
    }
    if (model.issued) rl.drawText(model.balance.z(), x + 120, y + 20, 16, menu_text_color);
    const max_pixels: u32 = @intFromFloat(@max(0, @min(rect.height - 46, rect.width * 0.48)));
    const scale = model.qr.scale(max_pixels);
    if (model.invoice.len != 0 and scale > 0) {
        const size: i32 = model.qr.size();
        const pixel: i32 = @intCast(scale);
        const top = y + 44;
        rl.drawRectangle(x, top, (size + 8) * pixel, (size + 8) * pixel, rl.Color.white);
        var row: i32 = 0;
        while (row < size) : (row += 1) {
            var col: i32 = 0;
            while (col < size) : (col += 1) if (model.qr.dark(col, row)) {
                rl.drawRectangle(x + (col + 4) * pixel, top + (row + 4) * pixel, pixel, pixel, rl.Color.black);
            };
        }
    } else {
        rl.drawText(if (model.qr.size() == 0) "QR unavailable / invoice too long" else "Viewport too small for QR", x, y + 44, 14, menu_muted);
    }
    const text_x = x + @as(i32, @intFromFloat(rect.width * 0.5));
    rl.drawText("Invoice (bounded preview):", text_x, y + 44, 14, menu_text_color);
    const width: usize = @intFromFloat(@max(1, rect.width * 0.5 / 8));
    const lines: usize = @intFromFloat(@max(0, (rect.height - 70) / 16));
    var start: usize = 0;
    var line: usize = 0;
    while (start < model.invoice.len and line < lines) : (line += 1) {
        var buf: [129:0]u8 = @splat(0);
        const count = @min(@min(width, 128), model.invoice.len - start);
        @memcpy(buf[0..count], model.invoice.slice()[start..][0..count]);
        rl.drawText(buf[0..count :0], text_x, y + 65 + @as(i32, @intCast(line)) * 16, 14, menu_text_color);
        start += count;
    }
}

// UTF-8-safe wrapping shared by the large editable invoice and read-only details.
// The editable field scrolls to its tail rather than silently hiding new input.
fn drawWrapped(text: []const u8, rect: menu.Rect, size: i32, tail: bool) void {
    if (rect.width < 2 or rect.height < 2) return;
    const columns: usize = @intFromFloat(@max(1, @min(120, (rect.width - 16) / @as(f32, @floatFromInt(size)))));
    const line_height = @as(f32, @floatFromInt(size + 4));
    const visible: usize = @intFromFloat(@max(1, (rect.height - 12) / line_height));
    var starts: [4098]usize = undefined;
    var count: usize = 1;
    starts[0] = 0;
    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len and count < starts.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const newline = text[index] == '\n';
        index += @min(n, text.len - index);
        width += 1;
        if (newline or width >= columns) {
            starts[count] = index;
            count += 1;
            width = 0;
        }
    }
    const first = if (tail and count > visible) count - visible else 0;
    rl.beginScissorMode(@intFromFloat(rect.x + 1), @intFromFloat(rect.y + 1), @intFromFloat(@max(1, rect.width - 2)), @intFromFloat(@max(1, rect.height - 2)));
    defer rl.endScissorMode();
    var row: usize = first;
    while (row < count and row - first < visible) : (row += 1) {
        const end = if (row + 1 < count) starts[row + 1] else text.len;
        var line: [512:0]u8 = @splat(0);
        const len = @min(end - starts[row], 511);
        @memcpy(line[0..len], text[starts[row]..][0..len]);
        rl.drawText(line[0..len :0], @intFromFloat(rect.x + 8), @intFromFloat(rect.y + 6 + @as(f32, @floatFromInt(row - first)) * line_height), size, menu_text_color);
    }
}

/// Draw one complete frame using only read-only state and the calculated view.
/// The caller owns `beginDrawing`/`endDrawing` so presentation and the optional
/// screenshot stay visible in `main`. The menu is last so its dim backdrop sits
/// over the HUD and minimap.
pub fn draw(game: *const game_mod.GameState, view: camera.View, viewport_w: f32, viewport_h: f32, model: ?*const onboarding.Onboarding, resources: *const Resources) void {
    rl.clearBackground(rl.Color.init(24, 24, 28, 255));

    rl.beginMode2D(view.transform);
    drawWorld(&game.world, view.chunks, game.settings.debug, resources);
    drawCameraMarker(view.transform.target);
    rl.endMode2D();

    drawHud(&game.world, view.chunks, &game.camera, game.settings.debug);
    drawMinimap(&game.world, view.chunks, &game.camera, viewport_w);

    if (game.menu.opened) {
        drawMenu(game, viewport_w, viewport_h);
    }
    if (model) |m| if (m.isBlocking()) {
        drawOnboarding(m, viewport_w, viewport_h);
    };
}

fn onboardingRect(r: onboarding.Rect) menu.Rect {
    return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
}

// Render word by word, wrapping within the seed box. The scratch copy is
// bounded, never retained, and scrubbed even when the viewport clips text.
fn drawSeed(secret: []const u8, rect: onboarding.Rect, size: i32) void {
    if (rect.width < 2 or rect.height < 2) return;
    rl.beginScissorMode(@intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(rect.width), @intFromFloat(rect.height));
    defer rl.endScissorMode();
    var word: [1025:0]u8 = @splat(0);
    defer std.crypto.secureZero(u8, &word);
    var it = std.mem.tokenizeScalar(u8, secret, ' ');
    var x = rect.x + 4;
    var y = rect.y + 4;
    const gap: f32 = @floatFromInt(@max(@divTrunc(size, 3), 1));
    while (it.next()) |part| {
        if (part.len > 1024) break;
        @memcpy(word[0..part.len], part);
        word[part.len] = 0;
        const text: [:0]const u8 = word[0..part.len :0];
        const width: f32 = @floatFromInt(rl.measureText(text, size));
        if (x > rect.x + 4 and x + width > rect.x + rect.width - 4) {
            x = rect.x + 4;
            y += @as(f32, @floatFromInt(size)) + gap;
        }
        rl.drawText(text, @intFromFloat(x), @intFromFloat(y), size, menu_text_color);
        x += width + gap;
    }
}

fn drawOnboardingButton(rect: onboarding.Rect, text: [:0]const u8, selected: bool, enabled: bool, size: i32) void {
    const r = onboardingRect(rect);
    drawSolidRect(r, if (selected and enabled) menu_item_hover else menu_item_bg);
    rl.drawRectangleLinesEx(toRaylibRect(r), 1, if (selected and enabled) menu_accent else menu_panel_border);
    drawCenteredText(text, r, size, if (enabled) menu_text_color else menu_muted);
}

fn drawOnboarding(model: *const onboarding.Onboarding, vw: f32, vh: f32) void {
    const layout = onboarding.calculateLayout(vw, vh);
    const scale = @min(layout.panel.width / 560, layout.panel.height / 500);
    const size: i32 = @max(1, @as(i32, @intFromFloat(18 * scale)));
    rl.drawRectangle(0, 0, @intFromFloat(@max(vw, 0)), @intFromFloat(@max(vh, 0)), menu_backdrop);
    drawSolidRect(onboardingRect(layout.panel), menu_panel_bg);
    rl.drawRectangleLinesEx(toRaylibRect(onboardingRect(layout.panel)), 2, menu_panel_border);
    switch (model.phase) {
        .loading => drawCenteredText("Loading wallet...", onboardingRect(layout.title), size, menu_title_color),
        .completing => drawCenteredText("Completing setup...", onboardingRect(layout.title), size, menu_title_color),
        .restoring => drawCenteredText("Restoring wallet...", onboardingRect(layout.title), size, menu_title_color),
        .choice => {
            drawCenteredText("Set up your wallet", onboardingRect(layout.title), size, menu_title_color);
            if (!model.recover_enabled) drawCenteredText("Recovery unavailable", onboardingRect(layout.seed), @max(1, @divTrunc(size * 2, 3)), menu_muted);
        },
        .phrase_entry => {
            drawCenteredText("Enter recovery words", onboardingRect(layout.title), size, menu_title_color);
            drawSolidRect(onboardingRect(layout.seed), menu_item_bg);
            drawSeed(model.recoveryPhrase(), layout.seed, size);
            drawCenteredText(if (model.retry_message) "Invalid phrase. Check your words." else "BIP39 passphrases are not supported.", onboardingRect(layout.message), @max(1, @divTrunc(size * 3, 4)), menu_muted);
        },
        .restore_failed, .restore_result => {
            const r = model.report;
            const has_history = if (r) |v| v.spendable_sats != 0 or v.pending_sats != 0 or v.spent_sats != 0 else false;
            drawCenteredText(if (model.phase == .restore_failed) "Restore failed" else "Recovery result", onboardingRect(layout.title), size, menu_title_color);
            if (model.phase == .restore_failed) {
                drawCenteredText("Restore failed. Retry to check again.", onboardingRect(layout.seed), size, menu_text_color);
            } else if (r) |v| {
                var buf: [192]u8 = undefined;
                const text = std.fmt.bufPrint(buf[0 .. buf.len - 1], "Spendable: {d} sats  Pending: {d}  Spent: {d}", .{ v.spendable_sats, v.pending_sats, v.spent_sats }) catch unreachable;
                buf[text.len] = 0;
                drawCenteredText(buf[0..text.len :0], onboardingRect(layout.seed), @max(1, @divTrunc(size * 3, 4)), menu_text_color);
                if (v.spendable_sats == 0 and has_history) drawCenteredText("No spendable sats; pending or spent history exists.", onboardingRect(layout.message), @max(1, @divTrunc(size * 3, 4)), menu_muted);
            }
        },
        .blocked => {
            drawCenteredText("Wallet setup blocked", onboardingRect(layout.title), size, menu_title_color);
            drawCenteredText("Close the game and check wallet storage.", onboardingRect(layout.seed), size, menu_text_color);
        },
        .backup => {
            drawCenteredText("Wallet created - save your recovery words", onboardingRect(layout.title), size, menu_title_color);
            drawSolidRect(onboardingRect(layout.seed), menu_item_bg);
            var explanation = onboardingRect(layout.seed);
            explanation.height = layout.seed_words.y - layout.seed.y;
            drawCenteredText("Anyone with these recovery words controls your wallet.", explanation, @max(1, @divTrunc(size * 3, 4)), menu_muted);
            var message = onboardingRect(layout.message);
            message.height /= 2;
            drawCenteredText("Copy exposes words to apps and clipboard history.", message, @max(1, @divTrunc(size * 3, 4)), menu_muted);
            message.y += message.height;
            drawCenteredText(if (model.retry_message) "Setup failed. Please try again." else "Clipboard is not cleared automatically.", message, @max(1, @divTrunc(size * 3, 4)), menu_muted);
        },
        .inactive => {},
    }
    const controls = model.controls(layout);
    for (controls.items[0..controls.len]) |control| {
        if (control.kind == .word) {
            const index = control.action.copy_word;
            const rect = control.rect;
            const r = onboardingRect(rect);
            drawSolidRect(r, if (model.copied_word != null and model.copied_word.? == index) rl.Color.init(44, 78, 130, 255) else menu_item_hover);
            rl.drawRectangleLinesEx(toRaylibRect(r), 1, if (std.meta.eql(model.selected, @as(?onboarding.Action, control.action))) menu_accent else menu_panel_border);
            if (rect.width < 2 or rect.height < 2) continue;
            const word = model.mnemonicWord(index) orelse continue;
            var buf: [1040:0]u8 = @splat(0);
            defer std.crypto.secureZero(u8, &buf);
            const text = if (std.meta.eql(model.feedback_target, @as(?onboarding.Action, control.action)))
                std.fmt.bufPrint(buf[0 .. buf.len - 1], "{s}", .{onboarding.Onboarding.copy_feedback}) catch continue
            else
                std.fmt.bufPrint(buf[0 .. buf.len - 1], "{d}- {s}", .{ @as(usize, index) + 1, word }) catch continue;
            buf[text.len] = 0;
            rl.beginScissorMode(@intFromFloat(rect.x), @intFromFloat(rect.y), @intFromFloat(rect.width), @intFromFloat(rect.height));
            drawCenteredText(buf[0..text.len :0], r, size, menu_text_color);
            rl.endScissorMode();
        } else drawOnboardingButton(control.rect, control.label, std.meta.eql(model.selected, @as(?onboarding.Action, control.action)), control.enabled, size);
    }
}

test "all grass neighbor patterns select bounded atlas quadrants at 2x" {
    try std.testing.expectEqual(192, grass_sheet_width);
    try std.testing.expectEqual(64, grass_sheet_height);
    try std.testing.expectEqual(@as(f32, 144), grass_source.x);
    try std.testing.expectEqual(@as(f32, 32), grass_source.y);
    try std.testing.expectEqual(@as(f32, 16), grass_source.width);
    try std.testing.expectEqual(@as(f32, 16), grass_source.height);
    try std.testing.expect(grass_source.x + grass_source.width <= grass_sheet_width);
    try std.testing.expect(grass_source.y + grass_source.height <= grass_sheet_height);
    try std.testing.expectEqual(@as(f32, world.TILE_PX), grass_source.width * 2);
    try std.testing.expectEqual(@as(f32, world.TILE_PX), grass_source.height * 2);

    const expected_kinds = [_]usize{ 0, 2, 1, 3, 0, 2, 1, 4 };
    for (0..256) |mask| {
        var neighbors: [8]bool = undefined;
        for (&neighbors, 0..) |*present, i| present.* = (mask & (@as(usize, 1) << @intCast(i))) != 0;
        for (grass_quadrant_neighbors, 0..) |indices, q| {
            const bits = @as(usize, @intFromBool(neighbors[indices[0]])) |
                (@as(usize, @intFromBool(neighbors[indices[1]])) << 1) |
                (@as(usize, @intFromBool(neighbors[indices[2]])) << 2);
            const expected = grass_quadrants[q][expected_kinds[bits]];
            const src = grassQuadrantSource(q, neighbors);
            try std.testing.expectEqual(expected[0], src.x);
            try std.testing.expectEqual(expected[1], src.y);
            try std.testing.expect(src.x >= 0 and src.x + src.width <= grass_sheet_width);
            try std.testing.expect(src.y >= 0 and src.y + src.height <= grass_sheet_height);
            const dest = grassQuadrantDest(-32, -32, q);
            try std.testing.expectEqual(@as(f32, 8), src.width);
            try std.testing.expectEqual(@as(f32, 8), src.height);
            try std.testing.expectEqual(src.width * 2, dest.width);
            try std.testing.expectEqual(src.height * 2, dest.height);
            try std.testing.expectEqual(@as(f32, -32) + @as(f32, @floatFromInt(q % 2)) * 16, dest.x);
            try std.testing.expectEqual(@as(f32, -32) + @as(f32, @floatFromInt(q / 2)) * 16, dest.y);
        }
    }
}

test "grass neighbors cross negative chunk boundaries and match fallback terrain" {
    try std.testing.expect(isGrassGround(.grass));
    try std.testing.expect(isGrassGround(.tree));
    try std.testing.expect(!isGrassGround(.dirt));
    try std.testing.expect(!isGrassGround(.rock));
    var resident = try world.World.init(std.testing.allocator, 36);
    defer resident.deinit();
    try resident.stream(.{ .cx0 = -1, .cy0 = -1, .cx1 = 0, .cy1 = 0 });
    var absent = try world.World.init(std.testing.allocator, 0);
    defer absent.deinit();
    var found_tree = false;
    var y: i32 = -18;
    while (y <= 18) : (y += 1) {
        var x: i32 = -18;
        while (x <= 18) : (x += 1) {
            const sampled = terrain.sampleTile(terrain.public_seed, x, y);
            found_tree = found_tree or sampled == .tree;
            try std.testing.expectEqual(sampled == .grass or sampled == .tree, isGrass(&resident, x, y));
            try std.testing.expectEqual(isGrass(&resident, x, y), isGrass(&absent, x, y));
            try std.testing.expectEqualDeep(grassNeighbors(&resident, x, y), grassNeighbors(&absent, x, y));
        }
    }
    try std.testing.expect(found_tree);

    // Owned fixture chunks: (-1,-1)'s east/south/diagonal cross chunk zero.
    var it = resident.by_key.valueIterator();
    while (it.next()) |chunk| @memset(&chunk.*.tiles, .grass);
    it = resident.by_key.valueIterator();
    while (it.next()) |chunk| {
        if (chunk.*.cx == 0 and chunk.*.cy == -1) chunk.*.tiles[15 * world.CT] = .tree;
    }
    var neighbors = grassNeighbors(&resident, -1, -1);
    try std.testing.expect(std.mem.allEqual(bool, &neighbors, true));
    for (0..4) |q| {
        const src = grassQuadrantSource(q, neighbors);
        try std.testing.expectEqual(grass_quadrants[q][4][0], src.x);
        try std.testing.expectEqual(grass_quadrants[q][4][1], src.y);
    }
    it = resident.by_key.valueIterator();
    while (it.next()) |chunk| {
        if (chunk.*.cx == 0 and chunk.*.cy == 0) chunk.*.tiles[0] = .dirt;
    }
    neighbors = grassNeighbors(&resident, -1, -1);
    for (0..4) |q| {
        const src = grassQuadrantSource(q, neighbors);
        const expected = grass_quadrants[q][if (q == 3) 3 else 4];
        try std.testing.expectEqual(expected[0], src.x);
        try std.testing.expectEqual(expected[1], src.y);
    }
    it = resident.by_key.valueIterator();
    while (it.next()) |chunk| {
        if (chunk.*.cx == 0 and chunk.*.cy == -1) chunk.*.tiles[15 * world.CT] = .rock;
    }
    neighbors = grassNeighbors(&resident, -1, -1);
    try std.testing.expectEqualDeep(rl.Rectangle{ .x = 120, .y = 16, .width = 8, .height = 8 }, grassQuadrantSource(1, neighbors));
    try std.testing.expectEqualDeep(rl.Rectangle{ .x = 120, .y = 24, .width = 8, .height = 8 }, grassQuadrantSource(3, neighbors));
}

test "only dirt and rock terrain types have uppercase labels" {
    try std.testing.expectEqual(null, tileLetter(.grass));
    try std.testing.expectEqual(null, tileLetter(.tree));
    const cases = [_]struct { tile: world.Tile, letter: u8 }{
        .{ .tile = .dirt, .letter = 'D' },
        .{ .tile = .rock, .letter = 'R' },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.letter, tileLetter(c.tile).?);
        try std.testing.expect(c.letter >= 'A' and c.letter <= 'Z');
    }
}

test "mature maple crop doubles around the ground tile bottom center" {
    try std.testing.expectEqual(160, maple_sheet_width);
    try std.testing.expectEqual(48, maple_sheet_height);
    try std.testing.expectEqualDeep(rl.Rectangle{ .x = 96, .y = 0, .width = 32, .height = 48 }, maple_source);
    try std.testing.expect(maple_source.x + maple_source.width <= maple_sheet_width);
    try std.testing.expect(maple_source.y + maple_source.height <= maple_sheet_height);
    for ([_]f32{ 0, -32 }) |pixel| {
        const dest = mapleDest(pixel, pixel);
        try std.testing.expectEqual(pixel - 16, dest.x);
        try std.testing.expectEqual(pixel - 64, dest.y);
        try std.testing.expectEqual(maple_source.width * 2, dest.width);
        try std.testing.expectEqual(maple_source.height * 2, dest.height);
        try std.testing.expectEqual(pixel + world.TILE_PX / 2, dest.x + dest.width / 2);
        try std.testing.expectEqual(pixel + world.TILE_PX, dest.y + dest.height);
    }
}

test "maple anchor ring includes adjacent offscreen canopies at negative coordinates" {
    for ([_]i32{ 0, -2 }) |chunk_coord| {
        const vis = world.ChunkRange{ .cx0 = chunk_coord, .cy0 = chunk_coord, .cx1 = chunk_coord, .cy1 = chunk_coord };
        const anchors = vis.expanded(1);
        try std.testing.expectEqual(chunk_coord - 1, anchors.cx0);
        try std.testing.expectEqual(chunk_coord - 1, anchors.cy0);
        try std.testing.expectEqual(chunk_coord + 1, anchors.cx1);
        try std.testing.expectEqual(chunk_coord + 1, anchors.cy1);
        const left: f32 = @floatFromInt(chunk_coord * world.CHUNK_PX);
        const right = left + world.CHUNK_PX;
        // The first anchor below the viewport still paints its canopy inside it.
        const below = mapleDest(left, right);
        try std.testing.expect(below.y < right and below.y + below.height > right);
        const east = mapleDest(right, left);
        try std.testing.expect(east.x < right);
        const west = mapleDest(left - world.TILE_PX, left);
        try std.testing.expect(west.x + west.width > left);
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
