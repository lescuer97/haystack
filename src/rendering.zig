//! Read-only rendering of the world, player, HUD, minimap, and menu.
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
const cut_feedback = @import("cut_feedback.zig");
const menu = @import("menu.zig");
const onboarding = @import("onboarding.zig");
const player = @import("player.zig");
const wallet_ui = @import("wallet_ui.zig");
const world = @import("world.zig");
const shared = @import("shared");
const terrain = shared.world;

/// Frame-rate target. The HUD's FPS colour thresholds are derived from it.
pub const target_fps: i32 = 120;

const grass_asset = "assets/Tiles/Grass_Middle.png";
const grass_sheet_width = 16;
const grass_sheet_height = 16;
const grass_source = rl.Rectangle{ .x = 0, .y = 0, .width = 16, .height = 16 };
const dirt_asset = "assets/Tiles/Path_Tile.png";
const dirt_sheet_width = 48;
const dirt_sheet_height = 96;
const dirt_source = rl.Rectangle{ .x = 16, .y = 16, .width = 16, .height = 16 };
const water_asset = "assets/Tiles/Water_Tile.png";
const water_sheet_width = 48;
const water_sheet_height = 96;
const water_source = rl.Rectangle{ .x = 0, .y = 80, .width = 16, .height = 16 };
const oak_asset = "assets/Outdoor decoration/Oak_Tree.png";
const oak_sheet_width = 64;
const oak_sheet_height = 80;
const oak_source = rl.Rectangle{ .x = 0, .y = 0, .width = 64, .height = 80 };
const decor_asset = "assets/Outdoor decoration/Outdoor_Decor_Free.png";
const decor_sheet_width = 112;
const decor_sheet_height = 192;
const rock_source = rl.Rectangle{ .x = 32, .y = 32, .width = 16, .height = 16 };
const grass_clump_source = rl.Rectangle{ .x = 96, .y = 16, .width = 16, .height = 16 };
const cut_grass_source = rl.Rectangle{ .x = 16, .y = 16, .width = 16, .height = 16 };

fn grassClumpSource(tile: world.Tile, is_cut: bool) ?rl.Rectangle {
    if (tile != .grass) return null;
    return if (is_cut) cut_grass_source else grass_clump_source;
}

fn rockDest(x: f32, y: f32) rl.Rectangle {
    // Source baseline (8,12) meets the ground tile bottom; shadow extends below.
    return .{ .x = x, .y = y + 8, .width = 32, .height = 32 };
}

fn oakDest(x: f32, y: f32) rl.Rectangle {
    // Opaque root at source (32,64); the shadow extends below the ground tile.
    return .{ .x = x - 48, .y = y - 96, .width = 128, .height = 160 };
}

const occluding_oak_tint = rl.Color.init(255, 255, 255, 102);

fn oakTint(dest: rl.Rectangle, feet: rl.Vector2) rl.Color {
    // Use the oak's opaque art (source bounds [11,52) × [9,64)), not
    // the padded atlas cell or shadow. Test against the player's body, not tool reach.
    const root_y = dest.y + 64 * 2;
    const overlaps_body = root_y > feet.y and dest.y + 9 * 2 < feet.y and
        dest.x + 11 * 2 < feet.x + 14 and dest.x + 52 * 2 > feet.x - 14;
    return if (overlaps_body) occluding_oak_tint else .white;
}

// Quadrants TL, TR, BL, BR; columns convex, horizontal boundary, vertical
// boundary, concave, solid. Each measured atlas crop is 8x8, drawn at 2x.
const dirt_quadrants = [4][5][2]f32{
    .{ .{ 8, 8 }, .{ 16, 8 }, .{ 8, 16 }, .{ 20, 68 }, .{ 16, 16 } },
    .{ .{ 32, 8 }, .{ 24, 8 }, .{ 32, 16 }, .{ 4, 68 }, .{ 24, 16 } },
    .{ .{ 8, 32 }, .{ 16, 32 }, .{ 8, 24 }, .{ 20, 52 }, .{ 16, 24 } },
    .{ .{ 32, 32 }, .{ 24, 32 }, .{ 32, 24 }, .{ 4, 52 }, .{ 24, 24 } },
};
// Water banks are thicker: concave crops shift inward to keep blue connected.
const water_quadrants = [4][5][2]f32{
    .{ .{ 8, 8 }, .{ 16, 8 }, .{ 8, 16 }, .{ 22, 70 }, .{ 16, 16 } },
    .{ .{ 32, 8 }, .{ 24, 8 }, .{ 32, 16 }, .{ 2, 70 }, .{ 24, 16 } },
    .{ .{ 8, 32 }, .{ 16, 32 }, .{ 8, 24 }, .{ 22, 50 }, .{ 16, 24 } },
    .{ .{ 32, 32 }, .{ 24, 32 }, .{ 32, 24 }, .{ 2, 50 }, .{ 24, 24 } },
};
// Neighbor order NW, N, NE, W, E, SW, S, SE.
const terrain_neighbor_offsets = [8][2]i32{
    .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 }, .{ -1, 0 },
    .{ 1, 0 },   .{ -1, 1 }, .{ 0, 1 },  .{ 1, 1 },
};
const quadrant_neighbors = [4][3]usize{
    .{ 1, 3, 0 }, .{ 1, 4, 2 }, .{ 6, 3, 5 }, .{ 6, 4, 7 },
};

fn isGrassGround(tile: world.Tile) bool {
    return tile == .grass or tile == .tree or tile == .rock;
}

fn isTerrain(w: *const world.World, tile_x: i64, tile_y: i64, kind: world.Tile) bool {
    const x = std.math.cast(i32, tile_x) orelse return false;
    const y = std.math.cast(i32, tile_y) orelse return false;
    if (w.get(@divFloor(x, world.CHUNK_TILES), @divFloor(y, world.CHUNK_TILES))) |chunk| {
        const lx: usize = @intCast(@mod(x, world.CHUNK_TILES));
        const ly: usize = @intCast(@mod(y, world.CHUNK_TILES));
        return chunk.tiles[ly * world.CT + lx] == kind;
    }
    // Prefetch normally supplies neighbors; missing residents need no allocation.
    return terrain.sampleTile(terrain.public_seed, x, y) == kind;
}

fn terrainNeighbors(w: *const world.World, x: i32, y: i32, kind: world.Tile) [8]bool {
    var neighbors: [8]bool = undefined;
    for (terrain_neighbor_offsets, 0..) |offset, i| {
        neighbors[i] = isTerrain(w, @as(i64, x) + offset[0], @as(i64, y) + offset[1], kind);
    }
    return neighbors;
}

fn shoreQuadrantSource(quadrant: usize, neighbors: [8]bool, material: world.Tile) rl.Rectangle {
    const indices = quadrant_neighbors[quadrant];
    const v = neighbors[indices[0]];
    const h = neighbors[indices[1]];
    const d = neighbors[indices[2]];
    const kind: usize = if (!v and !h) 0 else if (!v) 1 else if (!h) 2 else if (!d) 3 else 4;
    const xy = if (material == .water) water_quadrants[quadrant][kind] else dirt_quadrants[quadrant][kind];
    return .{ .x = xy[0], .y = xy[1], .width = 8, .height = 8 };
}

fn quadrantDest(x: f32, y: f32, quadrant: usize) rl.Rectangle {
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
    allocator: std.mem.Allocator,
    minimap: MinimapCache = .{},
    grass: rl.Texture2D,
    dirt: rl.Texture2D,
    oak: rl.Texture2D,
    decor: rl.Texture2D,
    water: rl.Texture2D,
    player_sheet: rl.Texture2D,
    player_actions: rl.Texture2D,

    pub fn init(allocator: std.mem.Allocator) !Resources {
        const grass = try loadAtlas(allocator, grass_asset, grass_sheet_width, grass_sheet_height);
        errdefer rl.unloadTexture(grass);
        const dirt = try loadAtlas(allocator, dirt_asset, dirt_sheet_width, dirt_sheet_height);
        errdefer rl.unloadTexture(dirt);
        const oak = try loadAtlas(allocator, oak_asset, oak_sheet_width, oak_sheet_height);
        errdefer rl.unloadTexture(oak);
        const decor = try loadAtlas(allocator, decor_asset, decor_sheet_width, decor_sheet_height);
        errdefer rl.unloadTexture(decor);
        const water = try loadAtlas(allocator, water_asset, water_sheet_width, water_sheet_height);
        errdefer rl.unloadTexture(water);
        const player_sheet = try loadAtlas(allocator, "assets/Player/Player.png", 192, 320);
        errdefer rl.unloadTexture(player_sheet);
        return .{
            .allocator = allocator,
            .grass = grass,
            .dirt = dirt,
            .oak = oak,
            .decor = decor,
            .water = water,
            .player_sheet = player_sheet,
            .player_actions = try loadAtlas(allocator, "assets/Player/Player_Actions.png", 96, 576),
        };
    }

    pub fn prepareMinimap(self: *Resources, w: *const world.World, map: ?camera.MinimapView) void {
        if (map) |view| self.minimap.prepare(self.allocator, w, view.chunks);
    }

    pub fn deinit(self: *const Resources) void {
        if (self.minimap.texture) |texture| rl.unloadTexture(texture);
        self.allocator.free(self.minimap.pixels.allocatedSlice());
        rl.unloadTexture(self.grass);
        rl.unloadTexture(self.dirt);
        rl.unloadTexture(self.oak);
        rl.unloadTexture(self.decor);
        rl.unloadTexture(self.water);
        rl.unloadTexture(self.player_sheet);
        rl.unloadTexture(self.player_actions);
    }
};

// ── colours ──────────────────────────────────────────────────────────────────

const grid_color = rl.Color.init(255, 255, 255, 55);
const border_color = rl.Color.init(220, 60, 55, 255);
const hud_bg = rl.Color.init(0, 0, 0, 170);

const menu_backdrop = rl.Color.init(0, 0, 0, 165);
const menu_panel_bg = rl.Color.init(28, 28, 34, 255);
const menu_panel_border = rl.Color.init(88, 92, 106, 255);
const menu_item_bg = rl.Color.init(44, 46, 56, 255);
const menu_item_hover = rl.Color.init(62, 66, 80, 255);
const menu_item_focus = rl.Color.init(48, 58, 76, 255);
const menu_accent = rl.Color.init(110, 165, 245, 255);
const menu_title_color = rl.Color.init(245, 245, 250, 255);
const menu_text_color = rl.Color.init(225, 228, 235, 255);
const menu_muted = rl.Color.init(150, 155, 170, 255);

// ── drawing ──────────────────────────────────────────────────────────────────

fn chunkBaseTile(chunk: i32) i64 {
    return @as(i64, chunk) * world.CHUNK_TILES;
}

fn localPixel(tile: i64, origin: i32) f32 {
    return @floatFromInt(camera.relativePixel(tile, origin));
}

fn drawChunkDebug(chunk: *const world.Chunk, cam: camera.Camera, settings: game_mod.DebugSettings) void {
    const ox = localPixel(chunkBaseTile(chunk.cx), cam.tile_x);
    const oy = localPixel(chunkBaseTile(chunk.cy), cam.tile_y);

    if (settings.tile_grid) {
        var i: usize = 0;
        while (i <= world.CT) : (i += 1) {
            const off = @as(f32, @floatFromInt(i)) * world.TILE_PX;
            rl.drawLineV(.{ .x = ox + off, .y = oy }, .{ .x = ox + off, .y = oy + world.CHUNK_PX }, grid_color);
            rl.drawLineV(.{ .x = ox, .y = oy + off }, .{ .x = ox + world.CHUNK_PX, .y = oy + off }, grid_color);
        }
    }

    if (settings.chunk_borders) {
        rl.drawRectangleLinesEx(
            .{
                .x = ox,
                .y = oy,
                .width = @floatFromInt(world.CHUNK_PX),
                .height = @floatFromInt(world.CHUNK_PX),
            },
            2.0,
            border_color,
        );
    }
}

const TileSpan = struct { start: usize, end: usize };

fn tileSpan(min: i64, max: i64, chunk: i32) TileSpan {
    const base = chunkBaseTile(chunk);
    const start = std.math.clamp(min - base, 0, world.CHUNK_TILES);
    return .{ .start = @intCast(start), .end = @intCast(std.math.clamp(max - base, start, world.CHUNK_TILES)) };
}

const ChunkTiles = struct {
    chunk: *const world.Chunk,
    columns: TileSpan,
    row_end: usize,
    row: usize,
    col: usize,

    const Item = struct { tile: world.Tile, index: usize, tx: i32, ty: i32 };

    fn init(chunk: *const world.Chunk, bounds: camera.TileRange) ChunkTiles {
        const columns = tileSpan(bounds.x0, bounds.x1, chunk.cx);
        const rows = tileSpan(bounds.y0, bounds.y1, chunk.cy);
        return .{ .chunk = chunk, .columns = columns, .row_end = rows.end, .row = rows.start, .col = columns.start };
    }

    inline fn next(self: *ChunkTiles) ?Item {
        if (self.row >= self.row_end or self.col >= self.columns.end) return null;
        const index = self.row * world.CT + self.col;
        const item = Item{
            .tile = self.chunk.tiles[index],
            .index = index,
            .tx = @intCast(chunkBaseTile(self.chunk.cx) + @as(i64, @intCast(self.col))),
            .ty = @intCast(chunkBaseTile(self.chunk.cy) + @as(i64, @intCast(self.row))),
        };
        self.col += 1;
        if (self.col == self.columns.end) {
            self.row += 1;
            self.col = self.columns.start;
        }
        return item;
    }
};

fn spriteChunks(vis: world.ChunkRange) world.ChunkRange {
    const expanded = vis.expanded(1);
    return .{
        .cx0 = @max(expanded.cx0, shared.protocol.min_chunk),
        .cy0 = @max(expanded.cy0, shared.protocol.min_chunk),
        .cx1 = @min(expanded.cx1, shared.protocol.max_chunk),
        .cy1 = @min(expanded.cy1, shared.protocol.max_chunk),
    };
}

fn containsTile(bounds: camera.TileRange, x: i32, y: i32) bool {
    return x >= bounds.x0 and x < bounds.x1 and y >= bounds.y0 and y < bounds.y1;
}

fn drawCutBursts(feedback: *const cut_feedback.Feedback, tiles: camera.TileRange, cam: camera.Camera) void {
    const bursts = feedback.activeBursts();
    if (bursts.len == 0) return;
    const visible = tiles.expanded(2);
    const clippings = [_]struct { vx: f32, vy: f32, spin: f32 }{
        .{ .vx = -54, .vy = -62, .spin = -105 },
        .{ .vx = -36, .vy = -92, .spin = 145 },
        .{ .vx = -19, .vy = -69, .spin = 240 },
        .{ .vx = 6, .vy = -95, .spin = -145 },
        .{ .vx = 23, .vy = -78, .spin = 155 },
        .{ .vx = 39, .vy = -89, .spin = -190 },
        .{ .vx = 57, .vy = -64, .spin = 95 },
    };
    const greens = [_]rl.Color{ .init(82, 142, 53, 255), .init(144, 192, 76, 255), .init(188, 214, 103, 255) };
    for (bursts) |burst| {
        if (!containsTile(visible, burst.tile.x, burst.tile.y)) continue;
        const center = camera.relativeTileCenter(burst.tile.x, burst.tile.y, cam.tile_x, cam.tile_y);
        const age = burst.age;
        const alpha: u8 = @intFromFloat(255 * (1 - age / cut_feedback.burst_seconds));
        for (clippings, 0..) |clipping, i| {
            var tint = greens[i % greens.len];
            tint.a = alpha;
            rl.drawRectanglePro(.{
                .x = center.x + clipping.vx * (age + 0.07),
                .y = center.y + clipping.vy * age + 175 * age * age,
                .width = 2,
                .height = 4,
            }, .{ .x = 1, .y = 2 }, clipping.spin * (age + 0.16), tint);
        }
    }
}

fn drawWorld(w: *const world.World, view: camera.View, cam: camera.Camera, settings: game_mod.DebugSettings, player_pos: shared.protocol.Location, frame: player.Frame, resources: *const Resources, feedback: *const cut_feedback.Feedback) void {
    const vis = view.chunks;
    const ground = view.tiles;
    // One visible grass pass keeps texture draws together, below all overlays.
    var grass_cy = vis.cy0;
    while (grass_cy <= vis.cy1) : (grass_cy += 1) {
        var grass_cx = vis.cx0;
        while (grass_cx <= vis.cx1) : (grass_cx += 1) {
            const chunk = w.get(grass_cx, grass_cy) orelse continue;
            var tiles = ChunkTiles.init(chunk, ground);
            while (tiles.next()) |entry| {
                if (!isGrassGround(entry.tile)) continue;
                const x = localPixel(entry.tx, cam.tile_x);
                const y = localPixel(entry.ty, cam.tile_y);
                rl.drawTexturePro(resources.grass, grass_source, .{
                    .x = x,
                    .y = y,
                    .width = world.TILE_PX,
                    .height = world.TILE_PX,
                }, .{ .x = 0, .y = 0 }, 0, .white);
            }
        }
    }

    // Both shore atlases include opaque grass corners; batch dirt, then water.
    for ([_]world.Tile{ .dirt, .water }) |kind| {
        const texture = if (kind == .dirt) resources.dirt else resources.water;
        const source = if (kind == .dirt) dirt_source else water_source;
        var cy = vis.cy0;
        while (cy <= vis.cy1) : (cy += 1) {
            var cx = vis.cx0;
            while (cx <= vis.cx1) : (cx += 1) {
                const chunk = w.get(cx, cy) orelse continue;
                var tiles = ChunkTiles.init(chunk, ground);
                while (tiles.next()) |entry| {
                    if (entry.tile != kind) continue;
                    const x = localPixel(entry.tx, cam.tile_x);
                    const y = localPixel(entry.ty, cam.tile_y);
                    const neighbors = terrainNeighbors(w, entry.tx, entry.ty, kind);
                    if (std.mem.allEqual(bool, &neighbors, true)) {
                        rl.drawTexturePro(texture, source, .{
                            .x = x,
                            .y = y,
                            .width = world.TILE_PX,
                            .height = world.TILE_PX,
                        }, .{ .x = 0, .y = 0 }, 0, .white);
                    } else {
                        for (0..4) |quadrant| {
                            rl.drawTexturePro(texture, shoreQuadrantSource(quadrant, neighbors, kind), quadrantDest(x, y, quadrant), .{ .x = 0, .y = 0 }, 0, .white);
                        }
                    }
                }
            }
        }
    }

    // Tall and cut grass clumps share the decor atlas; finish before rock shadows.
    var clump_cy = vis.cy0;
    while (clump_cy <= vis.cy1) : (clump_cy += 1) {
        var clump_cx = vis.cx0;
        while (clump_cx <= vis.cx1) : (clump_cx += 1) {
            const chunk = w.get(clump_cx, clump_cy) orelse continue;
            var tiles = ChunkTiles.init(chunk, ground);
            while (tiles.next()) |entry| {
                const source = grassClumpSource(entry.tile, chunk.isCut(entry.index)) orelse continue;
                const x = localPixel(entry.tx, cam.tile_x);
                const y = localPixel(entry.ty, cam.tile_y);
                rl.drawTexturePro(resources.decor, source, .{
                    .x = x,
                    .y = y,
                    .width = world.TILE_PX,
                    .height = world.TILE_PX,
                }, .{ .x = 0, .y = 0 }, 0, .white);
            }
        }
    }

    drawCutBursts(feedback, ground, cam);

    // Rock shadows extend 8 px past their tile; oak sprites reach up to 96 px
    // from their anchor. Both can reach the screen from an adjacent chunk.
    const rock_tiles = ground.expanded(1);
    const oak_tiles = ground.expanded(3);
    const sprite_range = spriteChunks(vis);
    var rock_cy = sprite_range.cy0;
    while (rock_cy <= sprite_range.cy1) : (rock_cy += 1) {
        var rock_cx = sprite_range.cx0;
        while (rock_cx <= sprite_range.cx1) : (rock_cx += 1) {
            const chunk = w.get(rock_cx, rock_cy) orelse continue;
            var tiles = ChunkTiles.init(chunk, rock_tiles);
            while (tiles.next()) |entry| {
                if (entry.tile != .rock) continue;
                const x = localPixel(entry.tx, cam.tile_x);
                const y = localPixel(entry.ty, cam.tile_y);
                rl.drawTexturePro(resources.decor, rock_source, rockDest(x, y), .{ .x = 0, .y = 0 }, 0, .white);
            }
        }
    }

    // Merge the player into the oak pass by ground depth, across chunk seams.
    // The largest player frame is 96 px tall; keep offscreen anchors that
    // can still overlap a visible oak, but skip a distant, panned-away player.
    const feet = if (containsTile(ground.expanded(5), player_pos.x, player_pos.y))
        camera.relativeTileCenter(player_pos.x, player_pos.y, cam.tile_x, cam.tile_y)
    else
        null;
    var player_pending = feet;
    var tree_cy = sprite_range.cy0;
    while (tree_cy <= sprite_range.cy1) : (tree_cy += 1) {
        const rows = tileSpan(oak_tiles.y0, oak_tiles.y1, tree_cy);
        for (rows.start..rows.end) |row| {
            const y = localPixel(chunkBaseTile(tree_cy) + @as(i64, @intCast(row)), cam.tile_y);
            if (player_pending) |target| {
                if (y + world.TILE_PX > target.y) {
                    drawPlayer(target, frame, resources);
                    player_pending = null;
                }
            }
            var tree_cx = sprite_range.cx0;
            while (tree_cx <= sprite_range.cx1) : (tree_cx += 1) {
                const cols = tileSpan(oak_tiles.x0, oak_tiles.x1, tree_cx);
                if (cols.start == cols.end) continue;
                const chunk = w.get(tree_cx, tree_cy) orelse continue;
                for (cols.start..cols.end) |col| {
                    const index = row * world.CT + col;
                    if (chunk.tiles[index] != .tree or chunk.isCut(index)) continue;
                    const x = localPixel(chunkBaseTile(tree_cx) + @as(i64, @intCast(col)), cam.tile_x);
                    const dest = oakDest(x, y);
                    const tint: rl.Color = if (feet) |target| oakTint(dest, target) else .white;
                    rl.drawTexturePro(resources.oak, oak_source, dest, .{ .x = 0, .y = 0 }, 0, tint);
                }
            }
        }
    }

    if (player_pending) |target| drawPlayer(target, frame, resources);

    if (!settings.tile_grid and !settings.chunk_borders) return;

    // Debug overlays may cover canopies.
    var cy = vis.cy0;
    while (cy <= vis.cy1) : (cy += 1) {
        var cx = vis.cx0;
        while (cx <= vis.cx1) : (cx += 1) {
            const chunk = w.get(cx, cy) orelse continue;
            drawChunkDebug(chunk, cam, settings);
        }
    }

    if (settings.chunk_borders and containsTile(ground.expanded(2), 0, 0)) {
        // Mark the absolute world origin, not the camera tile's origin.
        const x = localPixel(0, cam.tile_x);
        const y = localPixel(0, cam.tile_y);
        rl.drawLineV(.{ .x = x - 40, .y = y }, .{ .x = x + 40, .y = y }, .red);
        rl.drawLineV(.{ .x = x, .y = y - 40 }, .{ .x = x, .y = y + 40 }, .green);
        rl.drawRectangleLinesEx(.{ .x = x - 5, .y = y - 5, .width = 10, .height = 10 }, 2.0, .yellow);
    }
}

fn drawPlayer(target: rl.Vector2, frame: player.Frame, resources: *const Resources) void {
    const texture = switch (frame.sheet) {
        .character => resources.player_sheet,
        .tools => resources.player_actions,
    };
    const size: f32 = @floatFromInt(frame.size);
    const scale = 2;
    const source = rl.Rectangle{
        .x = @floatFromInt(frame.x),
        .y = @floatFromInt(frame.y),
        .width = if (frame.flip_x) -size else size,
        .height = size,
    };
    const dest = rl.Rectangle{ .x = target.x, .y = target.y, .width = size * scale, .height = size * scale };
    // The larger tool cells add 8 px of padding on each side; both sheets
    // put the foot/shadow line 8 px below their cell center.
    rl.drawTexturePro(texture, source, dest, .{ .x = size, .y = size + 8 * scale }, 0, .white);
}

const MinimapLayout = struct {
    chunks: world.ChunkRange,
    bounds: rl.Rectangle,
    tile_size: f32,
    camera_x: i32,
    camera_y: i32,

    fn tileOrigin(self: MinimapLayout, x: i64, y: i64) rl.Vector2 {
        return .{
            .x = self.bounds.x + self.bounds.width / 2 + (@as(f32, @floatFromInt(x - self.camera_x)) - 0.5) * self.tile_size,
            .y = self.bounds.y + self.bounds.height / 2 + (@as(f32, @floatFromInt(y - self.camera_y)) - 0.5) * self.tile_size,
        };
    }

    fn playerCenter(self: MinimapLayout, x: i32, y: i32) ?rl.Vector2 {
        if (!self.chunks.contains(@divFloor(x, world.CHUNK_TILES), @divFloor(y, world.CHUNK_TILES))) return null;
        const origin = self.tileOrigin(x, y);
        const center = rl.Vector2{ .x = origin.x + self.tile_size / 2, .y = origin.y + self.tile_size / 2 };
        if (!rl.checkCollisionPointRec(center, self.bounds)) return null;
        return center;
    }
};

fn minimapLayout(map: camera.MinimapView, cam: camera.Camera, viewport_w: f32) MinimapLayout {
    const size = map.size_px;
    return .{
        .chunks = map.chunks,
        .tile_size = size / @as(f32, @floatFromInt(2 * @as(i64, map.radius_tiles) + 1)),
        .camera_x = cam.tile_x,
        .camera_y = cam.tile_y,
        .bounds = .{ .x = @floor(viewport_w) - 12 - size, .y = 12, .width = size, .height = size },
    };
}

fn minimapColor(tile: world.Tile) rl.Color {
    // Representative opaque colors sampled from the terrain and sprite crops.
    return switch (tile) {
        .grass => rl.Color.init(62, 137, 72, 255),
        .dirt => rl.Color.init(228, 166, 114, 255),
        .water => rl.Color.init(0, 149, 233, 255),
        .tree => rl.Color.init(90, 197, 79, 255),
        .rock => rl.Color.init(142, 154, 180, 255),
    };
}

const MinimapStamp = struct {
    chunks: world.ChunkRange,
    generated: u64,
    unloaded: u64,
    cut_revision: u64,

    fn get(w: *const world.World, chunks: world.ChunkRange) MinimapStamp {
        return .{ .chunks = chunks, .generated = w.generated, .unloaded = w.unloaded, .cut_revision = w.cut_revision };
    }
};

const MinimapCache = struct {
    stamp: ?MinimapStamp = null,
    pixels: std.ArrayList(rl.Color) = .empty,
    texture: ?rl.Texture2D = null,

    fn prepare(self: *MinimapCache, allocator: std.mem.Allocator, w: *const world.World, chunks: world.ChunkRange) void {
        const stamp = MinimapStamp.get(w, chunks);
        if (self.stamp) |old| {
            if (std.meta.eql(old, stamp)) return;
        }
        self.stamp = null;
        const width = chunks.cols() * world.CHUNK_TILES;
        const height = chunks.rows() * world.CHUNK_TILES;
        const len = std.math.mul(usize, @intCast(width), @intCast(height)) catch return;
        self.pixels.resize(allocator, len) catch return;
        paintMinimap(self.pixels.items, @intCast(width), w, chunks);

        if (self.texture) |texture| {
            if (texture.width == width and texture.height == height) {
                rl.updateTexture(texture, self.pixels.items.ptr);
                self.stamp = stamp;
                return;
            }
            rl.unloadTexture(texture);
            self.texture = null;
        }
        const texture = rl.loadTextureFromImage(.{
            .data = self.pixels.items.ptr,
            .width = width,
            .height = height,
            .mipmaps = 1,
            .format = .uncompressed_r8g8b8a8,
        }) catch return;
        rl.setTextureFilter(texture, .point);
        self.texture = texture;
        self.stamp = stamp;
    }
};

fn paintMinimap(pixels: []rl.Color, width: usize, w: *const world.World, chunks: world.ChunkRange) void {
    @memset(pixels, menu_panel_bg);
    var cy = chunks.cy0;
    while (cy <= chunks.cy1) : (cy += 1) {
        var cx = chunks.cx0;
        while (cx <= chunks.cx1) : (cx += 1) {
            const chunk = w.get(cx, cy) orelse continue;
            const x: usize = @as(usize, @intCast(cx - chunks.cx0)) * world.CT;
            const y: usize = @as(usize, @intCast(cy - chunks.cy0)) * world.CT;
            for (0..world.CT) |row| {
                const offset = (y + row) * width + x;
                for (pixels[offset..][0..world.CT], 0..) |*pixel, col| {
                    const index = row * world.CT + col;
                    const tile = chunk.tiles[index];
                    pixel.* = if ((tile == .grass or tile == .tree) and chunk.isCut(index))
                        rl.Color.init(74, 119, 66, 255) // Bare grass, without the clump or canopy.
                    else
                        minimapColor(tile);
                }
            }
        }
    }
}

fn drawTerrainMinimap(game: *const game_mod.GameState, vis: world.ChunkRange, layout: MinimapLayout, cache: *const MinimapCache) void {
    rl.drawRectangleRec(layout.bounds, menu_panel_bg);
    rl.beginScissorMode(@intFromFloat(layout.bounds.x), @intFromFloat(layout.bounds.y), @intFromFloat(layout.bounds.width), @intFromFloat(layout.bounds.height));
    defer {
        rl.endScissorMode();
        rl.drawRectangleLinesEx(layout.bounds, 1, menu_panel_border);
    }
    if (cache.stamp != null) if (cache.texture) |texture| {
        const width: f32 = @floatFromInt(texture.width);
        const height: f32 = @floatFromInt(texture.height);
        const first = layout.tileOrigin(chunkBaseTile(layout.chunks.cx0), chunkBaseTile(layout.chunks.cy0));
        rl.drawTexturePro(texture, .{ .x = 0, .y = 0, .width = width, .height = height }, .{
            .x = first.x,
            .y = first.y,
            .width = width * layout.tile_size,
            .height = height * layout.tile_size,
        }, .{ .x = 0, .y = 0 }, 0, .white);

        const seam = rl.Color.init(0, 0, 0, 48);
        var cx = layout.chunks.cx0 + 1;
        while (cx <= layout.chunks.cx1) : (cx += 1) {
            const x = layout.tileOrigin(chunkBaseTile(cx), layout.camera_y).x;
            rl.drawRectangleRec(.{ .x = x, .y = layout.bounds.y, .width = 1, .height = layout.bounds.height }, seam);
        }
        var cy = layout.chunks.cy0 + 1;
        while (cy <= layout.chunks.cy1) : (cy += 1) {
            const y = layout.tileOrigin(layout.camera_x, chunkBaseTile(cy)).y;
            rl.drawRectangleRec(.{ .x = layout.bounds.x, .y = y, .width = layout.bounds.width, .height = 1 }, seam);
        }
        const visible = layout.tileOrigin(chunkBaseTile(vis.cx0), chunkBaseTile(vis.cy0));
        const chunk_size = layout.tile_size * world.CHUNK_TILES;
        rl.drawRectangleLinesEx(.{
            .x = visible.x,
            .y = visible.y,
            .width = @as(f32, @floatFromInt(vis.cols())) * chunk_size,
            .height = @as(f32, @floatFromInt(vis.rows())) * chunk_size,
        }, 1, rl.Color.init(255, 255, 255, 48));
    };
    if (layout.playerCenter(game.player_pos.x, game.player_pos.y)) |center| {
        rl.drawCircleV(center, 4, .black);
        rl.drawCircleV(center, 2.5, .white);
    }
}

fn debugMinimapBounds(terrain_bounds: rl.Rectangle, viewport_h: f32) ?rl.Rectangle {
    const y = @ceil(terrain_bounds.y + terrain_bounds.height + 12);
    const height = @min(140, viewport_h - y - 12);
    if (terrain_bounds.width < 32 or height < 32) return null;
    return .{ .x = terrain_bounds.x, .y = y, .width = terrain_bounds.width, .height = height };
}

/// Loaded chunks (green), visible rect (yellow), and camera chunk (red dot).
fn drawDebugMinimap(w: *const world.World, vis: world.ChunkRange, cam: *const camera.Camera, bounds: rl.Rectangle) void {
    const x0: i32 = @intFromFloat(@ceil(bounds.x));
    const y0: i32 = @intFromFloat(bounds.y);
    const panel_w: i32 = @intFromFloat(@floor(bounds.x + bounds.width) - @ceil(bounds.x));
    const panel_h: i32 = @intFromFloat(bounds.height);

    rl.drawRectangleRec(bounds, hud_bg);
    rl.drawRectangleLinesEx(bounds, 1, .dark_gray);
    rl.beginScissorMode(x0 + 1, y0 + 1, panel_w - 2, panel_h - 2);
    defer rl.endScissorMode();

    const cell: i32 = 4;
    const cam_cx = cam.chunkX();
    const cam_cy = cam.chunkY();
    const center_x = x0 + @divTrunc(panel_w, 2);
    const center_y = y0 + @divTrunc(panel_h, 2);

    var it = w.residents();
    while (it.next()) |c| {
        const mx = center_x + (@as(i64, c.cx) - cam_cx) * cell;
        const my = center_y + (@as(i64, c.cy) - cam_cy) * cell;
        if (mx < x0 + 1 or mx >= x0 + panel_w - cell) continue;
        if (my < y0 + 1 or my >= y0 + panel_h - cell) continue;
        rl.drawRectangle(@intCast(mx), @intCast(my), cell - 1, cell - 1, rl.Color.init(80, 170, 100, 255));
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
    hoe: ?game_mod.HoeView,
) void {
    const panel_w: i32 = 620;
    const panel_h: i32 = if (hoe != null) 210 else 182;
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
    if (hoe) |channel| {
        const y = 180;
        const size = 14;
        const left = 18;
        const right = 8 + panel_w - 10;
        const client_text = hoeBalanceText(&buf, "Client", channel.client, "confirmed", channel.payment_pending);
        const client_end = left + rl.measureText(client_text, size);
        rl.drawText(client_text, left, y, size, .light_gray);
        const server_text = hoeBalanceText(&buf, "Server", channel.server, "accepted", false);
        const server_start = right - rl.measureText(server_text, size);
        rl.drawText(server_text, server_start, y, size, .light_gray);

        const gap = 6;
        const bar_width = @divTrunc(right - left - gap, 2);
        drawHoeCapacity(left, y + 19, bar_width, channel.client);
        drawHoeCapacity(left + bar_width + gap, y + 19, bar_width, channel.server);

        if (channel.server) |server| if (channel.client) |client| {
            const difference = @as(i128, server.accepted) - @as(i128, client.accepted);
            if (difference != 0) {
                const text = std.mem.printSentinel(&buf, "Delta: {d} msat{s}", .{ difference, if (server.stale or client.stale) " (stale)" else "" }, 0) catch unreachable;
                const width = rl.measureText(text, size);
                if (server_start - client_end >= width + 16) {
                    rl.drawText(text, @divTrunc(client_end + server_start - width, 2), y, size, .orange);
                }
            }
        };
    }
}

fn drawHoeCapacity(x: i32, y: i32, width: i32, balance: ?game_mod.HoeBalance) void {
    const height = 8;
    rl.drawRectangle(x, y, width, height, .dark_gray);
    const value = balance orelse return;
    if (value.capacity == 0) return;
    const remaining = value.capacity -| value.accepted;
    const fill: i32 = @intCast(@as(u128, @intCast(width)) * remaining / value.capacity);
    rl.drawRectangle(x, y, width, height, if (value.stale) .dark_gray else .gray);
    rl.drawRectangle(x, y, fill, height, if (value.stale) .dark_green else .lime);
}

fn hoeBalanceText(buf: *[192]u8, side: []const u8, balance: ?game_mod.HoeBalance, label: []const u8, pending: bool) [:0]const u8 {
    const pending_text = if (pending) " (pending)" else "";
    return if (balance) |value|
        std.mem.printSentinel(buf, "{s}: {d} {s} / {d} left (msat){s}{s}", .{
            side, value.accepted, label, value.capacity -| value.accepted, if (value.stale) " (stale)" else "", pending_text,
        }, 0) catch unreachable
    else
        std.mem.printSentinel(buf, "{s}: unknown{s}", .{ side, pending_text }, 0) catch unreachable;
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

fn drawMenuItem(rect: menu.Rect, item: menu.MenuItem, game: *const game_mod.GameState, selected: bool) void {
    const state = &game.menu;
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

    if (item == .action and item.action == .toggle_music) {
        const font_size: i32 = if (rect.height < 32) 14 else 20;
        const size = @min(rect.height * 0.55, @as(f32, @floatFromInt(font_size)));
        const label = if (game.music_enabled and game.music_unavailable) "Music (unavailable)" else menu.itemLabel(item);
        const text_width: f32 = @floatFromInt(rl.measureText(label, font_size));
        const gap = size * 0.45;
        const box = menu.Rect{
            .x = rect.centerX() - (size + gap + text_width) / 2,
            .y = rect.centerY() - size / 2,
            .width = size,
            .height = size,
        };
        rl.drawRectangleLinesEx(toRaylibRect(box), 1, menu_text_color);
        if (game.music_enabled) {
            const left = rl.Vector2{ .x = box.x + size * 0.2, .y = box.y + size * 0.52 };
            const middle = rl.Vector2{ .x = box.x + size * 0.43, .y = box.y + size * 0.75 };
            const right = rl.Vector2{ .x = box.x + size * 0.8, .y = box.y + size * 0.25 };
            rl.drawLineEx(left, middle, 2, menu_text_color);
            rl.drawLineEx(middle, right, 2, menu_text_color);
        }
        rl.drawText(label, @intFromFloat(box.x + size + gap), @intFromFloat(rect.centerY() - @as(f32, @floatFromInt(font_size)) / 2), font_size, menu_text_color);
        return;
    }

    const debug_enabled: ?bool = if (item == .action) switch (item.action) {
        .toggle_grid => game.settings.debug.tile_grid,
        .toggle_borders => game.settings.debug.chunk_borders,
        .toggle_debug_minimap => game.show_debug_minimap,
        .toggle_hud => game.show_debug_hud,
        else => null,
    } else null;
    if (debug_enabled) |enabled| {
        var buf: [64]u8 = undefined;
        const label = std.mem.printSentinel(&buf, "{s}: {s}", .{ menu.itemLabel(item), onOff(enabled) }, 0) catch unreachable;
        drawCenteredText(label, rect, if (rect.height < 32) 14 else 20, menu_text_color);
        return;
    }

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
    if (layout.content.height > 0) drawWalletContent(state, layout.content);

    const page_items = state.items();

    var index: usize = 0;
    while (index < layout.item_count) : (index += 1) {
        drawMenuItem(layout.items[index], page_items[index], game, state.isSelected(index));
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
            std.fmt.bufPrint(&buf, "Amount: {s} msat\nRouting fee reserve: {s} msat\nCashu swap fee: {s} msat | input fee: {s} msat\nEstimated total: {s} msat (not a guaranteed cap)\nQuote expiry (Unix): {s} | invoice expiry: {s}\nCDK status: {s} | quote: {s}{s}", .{ view.amount.slice(), view.fee_reserve.slice(), view.swap_fee.slice(), view.input_fee.slice(), view.estimated_total.slice(), view.quote_expiry.slice(), view.invoice_expiry.slice(), @tagName(view.status), view.quote_state.slice(), if (view.expired) " | expired" else "" }) catch "Details exceed display limit"
        else
            std.fmt.bufPrint(&buf, "Amount: {s} msat\nQuote expiry (Unix): {s}\nInvoice expiry (Unix): {s}\nCDK status: {s} | quote: {s}{s}", .{ view.amount.slice(), view.quote_expiry.slice(), view.invoice_expiry.slice(), @tagName(view.status), view.quote_state.slice(), if (view.expired) " | expired" else "" }) catch "Details exceed display limit";
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

fn drawToolbar(game: *const game_mod.GameState, vw: f32, vh: f32) void {
    const layout = game_mod.toolbarLayout(vw, vh) orelse return;
    const selected = game.selected_tool == .hoe;
    drawSolidRect(layout.bounds, menu_panel_bg);
    rl.drawRectangleLinesEx(toRaylibRect(layout.bounds), 1, menu_panel_border);
    drawSolidRect(layout.hoe, if (selected) menu_item_focus else menu_item_bg);
    rl.drawRectangleLinesEx(toRaylibRect(layout.hoe), 2, if (selected) menu_accent else menu_panel_border);
    drawCenteredText("Hoe", layout.hoe, 18, menu_text_color);
}

fn walletBadgeBalance(wallet: *const wallet_ui.Model) [:0]const u8 {
    if (wallet.available and wallet.balance.len != 0) return wallet.balance.z();
    if (!wallet.started or (wallet.pending and wallet.operation == .open)) return "Loading balance...";
    return "Balance unavailable";
}

fn drawWalletBadge(state: *const menu.Menu, vw: f32, vh: f32) void {
    const bounds = game_mod.walletBadgeBounds(vw, vh) orelse return;
    const wallet = &state.wallet;
    const hovered = bounds.contains(state.pointer_x, state.pointer_y);
    drawSolidRect(bounds, if (hovered) menu_item_hover else menu_panel_bg);
    rl.drawRectangleLinesEx(toRaylibRect(bounds), 1, if (hovered) menu_accent else menu_panel_border);

    const x: i32 = @intFromFloat(bounds.x + 10);
    const y: i32 = @intFromFloat(bounds.y + 8);
    rl.drawRectangle(x + 2, y, 13, 3, menu_accent);
    rl.drawRectangle(x, y + 3, 17, 11, menu_accent);
    rl.drawRectangle(x + 2, y + 5, 13, 7, menu_item_focus);
    rl.drawRectangle(x + 11, y + 7, 7, 3, menu_accent);
    rl.drawText("Wallet", x + 25, y, 16, menu_title_color);
    rl.drawText(walletBadgeBalance(wallet), x, y + 20, 14, if (wallet.available) menu_text_color else menu_muted);
}

fn drawRefillNotice(viewport_w: f32, viewport_h: f32) void {
    const message = "Hoe empty";
    const width: f32 = @floatFromInt(rl.measureText(message, 16) + 24);
    const height = 26;
    const toolbar = game_mod.toolbarLayout(viewport_w, viewport_h) orelse return;
    const above = if (game_mod.walletBadgeBounds(viewport_w, viewport_h)) |badge| @min(toolbar.bounds.y, badge.y) else toolbar.bounds.y;
    const notice: menu.Rect = .{ .x = (viewport_w - width) / 2, .y = above - height - 8, .width = width, .height = height };
    if (notice.x < 8 or notice.y < 8) return;
    drawSolidRect(notice, hud_bg);
    drawCenteredText(message, notice, 16, menu_text_color);
}

/// Draw one complete frame using only read-only state and the calculated view.
/// The caller owns `beginDrawing`/`endDrawing` so presentation and the optional
/// screenshot stay visible in `main`. The menu is last so its dim backdrop sits
/// over the HUD and minimap.
pub fn draw(game: *const game_mod.GameState, view: camera.View, viewport_w: f32, viewport_h: f32, model: ?*const onboarding.Onboarding, resources: *const Resources, connected: bool) void {
    rl.clearBackground(rl.Color.init(24, 24, 28, 255));

    rl.beginMode2D(view.transform);
    drawWorld(&game.world, view, game.camera, game.settings.debug, game.player_pos, game.player_animation.frame(), resources, &game.cut_feedback);
    rl.endMode2D();

    if (game.show_debug_hud) drawHud(&game.world, view.chunks, &game.camera, game.settings.debug, if (game_mod.HoeFundingUi.supported) game.paid_hoe.view else null);
    if (view.minimap) |map| {
        const layout = minimapLayout(map, game.camera, viewport_w);
        drawTerrainMinimap(game, view.chunks, layout, &resources.minimap);
        if (game.show_debug_minimap) {
            if (debugMinimapBounds(layout.bounds, viewport_h)) |bounds| {
                drawDebugMinimap(&game.world, view.chunks, &game.camera, bounds);
            }
        }
    }

    const onboarding_blocked = if (model) |m| m.isBlocking() else false;
    if (game.menu.opened) {
        drawMenu(game, viewport_w, viewport_h);
    } else if (connected and !onboarding_blocked) {
        drawToolbar(game, viewport_w, viewport_h);
        drawWalletBadge(&game.menu, viewport_w, viewport_h);
        const channel_visible = if (game_mod.HoeFundingUi.supported) game.paid_hoe.view.status != .hidden else false;
        if (!channel_visible and game.cut_feedback.showRefillNotice()) drawRefillNotice(viewport_w, viewport_h);
    }
    if (model) |m| if (m.isBlocking()) {
        drawOnboarding(m, viewport_w, viewport_h);
    };
}

pub fn drawWorldSync(vw: f32) void {
    const text = "Synchronizing the visible world...";
    const text_width: f32 = @floatFromInt(rl.measureText(text, 16));
    if (vw < text_width + 32) return;
    const width = text_width + 16;
    const panel = menu.Rect{ .x = (vw - width) / 2, .y = 8, .width = width, .height = 28 };
    drawSolidRect(panel, menu_panel_bg);
    rl.drawRectangleLinesEx(toRaylibRect(panel), 1, menu_panel_border);
    drawCenteredText(text, panel, 16, menu_text_color);
}

pub fn drawDisconnected(detail: [:0]const u8, vw: f32, vh: f32) void {
    rl.drawRectangle(0, 0, @intFromFloat(@max(vw, 0)), @intFromFloat(@max(vh, 0)), menu_backdrop);
    const width = @max(0, @min(vw - 16, 460));
    const height = @max(0, @min(vh - 16, 120));
    const panel = menu.Rect{ .x = (vw - width) / 2, .y = (vh - height) / 2, .width = width, .height = height };
    drawSolidRect(panel, menu_panel_bg);
    rl.drawRectangleLinesEx(toRaylibRect(panel), 2, menu_panel_border);
    const title = menu.Rect{ .x = panel.x, .y = panel.y, .width = width, .height = height / 2 };
    const body = menu.Rect{ .x = panel.x, .y = panel.y + height / 2, .width = width, .height = height / 2 };
    drawCenteredText("Disconnected", title, 22, menu_title_color);
    drawCenteredText(detail, body, 16, menu_text_color);
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
            const has_history = if (r) |v| v.spendable_msats != 0 or v.pending_msats != 0 or v.spent_msats != 0 else false;
            drawCenteredText(if (model.phase == .restore_failed) "Restore failed" else "Recovery result", onboardingRect(layout.title), size, menu_title_color);
            if (model.phase == .restore_failed) {
                drawCenteredText("Restore failed. Retry to check again.", onboardingRect(layout.seed), size, menu_text_color);
            } else if (r) |v| {
                var buf: [192]u8 = undefined;
                const text = std.fmt.bufPrint(buf[0 .. buf.len - 1], "Spendable: {d} msat  Pending: {d} msat  Spent: {d} msat", .{ v.spendable_msats, v.pending_msats, v.spent_msats }) catch unreachable;
                buf[text.len] = 0;
                drawCenteredText(buf[0..text.len :0], onboardingRect(layout.seed), @max(1, @divTrunc(size * 3, 4)), menu_text_color);
                if (v.spendable_msats == 0 and has_history) drawCenteredText("No spendable msat; pending or spent history exists.", onboardingRect(layout.message), @max(1, @divTrunc(size * 3, 4)), menu_muted);
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

test "wallet badge anchors left and clears the hoe toolbar on narrow viewports" {
    const wide = game_mod.walletBadgeBounds(1000, 640).?;
    const wide_tools = game_mod.toolbarLayout(1000, 640).?;
    try std.testing.expectEqual(@as(f32, 8), wide.x);
    try std.testing.expectEqual(wide_tools.bounds.y, wide.y);
    try std.testing.expect(wide.x + wide.width < wide_tools.bounds.x);

    const narrow = game_mod.walletBadgeBounds(320, 480).?;
    const narrow_tools = game_mod.toolbarLayout(320, 480).?;
    try std.testing.expectEqual(wide.x, narrow.x);
    try std.testing.expect(narrow.x + narrow.width <= 320);
    try std.testing.expect(narrow.y + narrow.height < narrow_tools.bounds.y);
    try std.testing.expect(game_mod.walletBadgeBounds(320, 64) == null);
}

test "wallet badge distinguishes unknown balance from zero and shows exact msat" {
    var wallet = wallet_ui.Model{};
    try std.testing.expectEqualStrings("Loading balance...", walletBadgeBalance(&wallet));
    wallet.started = true;
    try std.testing.expectEqualStrings("Balance unavailable", walletBadgeBalance(&wallet));
    wallet.available = true;
    _ = wallet.balance.set("0 msat");
    try std.testing.expectEqualStrings("0 msat", walletBadgeBalance(&wallet));
    _ = wallet.balance.set("18446744073709551615 msat");
    try std.testing.expectEqualStrings("18446744073709551615 msat", walletBadgeBalance(&wallet));
}

test "minimap texture pixels follow chunk coordinates and refresh when missing terrain loads" {
    const allocator = std.testing.allocator;
    var w = try world.World.init(allocator, world.MIN_PREHEATED_CHUNKS);
    defer w.deinit();
    const vis = world.ChunkRange{ .cx0 = 0, .cy0 = 0, .cx1 = 0, .cy1 = 0 };
    const map = world.ChunkRange{ .cx0 = -3, .cy0 = -1, .cx1 = -2, .cy1 = -1 };
    try w.stream(vis);
    const before = MinimapStamp.get(&w, map);
    const width = 2 * world.CT;
    var pixels: [width * world.CT]rl.Color = undefined;
    paintMinimap(&pixels, width, &w, map);
    const resident = w.get(-2, -1).?;
    for (0..world.CT) |row| {
        for (0..world.CT) |col| {
            try std.testing.expectEqual(menu_panel_bg, pixels[row * width + col]);
            try std.testing.expectEqual(minimapColor(resident.tiles[row * world.CT + col]), pixels[row * width + world.CT + col]);
        }
    }
    try w.streamWithMinimap(vis, map);
    const after = MinimapStamp.get(&w, map);
    try std.testing.expect(!std.meta.eql(before, after));
    paintMinimap(&pixels, width, &w, map);
    try std.testing.expectEqual(minimapColor(w.get(-3, -1).?.tiles[0]), pixels[0]);
    try w.streamWithMinimap(vis, map);
    try std.testing.expectEqual(after, MinimapStamp.get(&w, map));
}

test "debug minimap uses the terrain minimap column and fits the remaining height" {
    const bounds = rl.Rectangle{ .x = 210.5, .y = 12, .width = 77.5, .height = 60.5 };
    const debug = debugMinimapBounds(bounds, 160).?;
    try std.testing.expectEqual(bounds.x, debug.x);
    try std.testing.expectEqual(bounds.width, debug.width);
    try std.testing.expectEqual(85, debug.y);
    try std.testing.expectEqual(148, debug.y + debug.height);
    try std.testing.expect(debugMinimapBounds(bounds, 120) == null);
}

test "terrain minimap includes prefetched chunks and maps player tiles across zero" {
    const cam = camera.Camera{};
    const view = try camera.calculate(cam, 1000, 640);
    const map = view.minimap.?;
    const layout = minimapLayout(map, cam, 1000);
    try std.testing.expect(layout.chunks.contains(-3, -2));
    try std.testing.expect(layout.chunks.contains(3, 2));
    try std.testing.expect(!view.chunks.contains(-3, -2));
    const first = layout.tileOrigin(-map.radius_tiles, -map.radius_tiles);
    const end = layout.tileOrigin(map.radius_tiles + 1, map.radius_tiles + 1);
    try std.testing.expectApproxEqAbs(layout.bounds.x, first.x, 0.001);
    try std.testing.expectApproxEqAbs(layout.bounds.y, first.y, 0.001);
    try std.testing.expectApproxEqAbs(layout.bounds.x + layout.bounds.width, end.x, 0.001);
    try std.testing.expectApproxEqAbs(layout.bounds.y + layout.bounds.height, end.y, 0.001);
    const left = layout.playerCenter(-1, 0).?;
    const right = layout.playerCenter(0, 0).?;
    try std.testing.expectApproxEqAbs(layout.tile_size, right.x - left.x, 0.001);
    try std.testing.expectEqual(left.y, right.y);
    try std.testing.expect(layout.playerCenter(0, map.radius_tiles) != null);
    try std.testing.expect(layout.playerCenter(0, map.radius_tiles + 1) == null);
    try std.testing.expect((try camera.calculate(cam, 64, 64)).minimap == null);
}

test "minimap frame and tile scale stay stable as visible chunk count changes" {
    const before = camera.Camera{ .tile_x = 0 };
    const after = camera.Camera{ .tile_x = 1 };
    const view_before = try camera.calculate(before, 960, 640);
    const view_after = try camera.calculate(after, 960, 640);
    try std.testing.expect(view_before.chunks.cols() != view_after.chunks.cols());
    const a = minimapLayout(view_before.minimap.?, before, 960);
    const b = minimapLayout(view_after.minimap.?, after, 960);
    try std.testing.expectEqual(a.bounds, b.bounds);
    try std.testing.expectEqual(a.tile_size, b.tile_size);
    try std.testing.expectEqual(debugMinimapBounds(a.bounds, 640), debugMinimapBounds(b.bounds, 640));
    try std.testing.expectEqual(a.playerCenter(before.tile_x, 0), b.playerCenter(after.tile_x, 0));
    try std.testing.expectApproxEqAbs(a.tile_size, a.tileOrigin(0, 0).x - b.tileOrigin(0, 0).x, 0.001);
}

test "minimap keeps tile scale and stops at protocol edges" {
    const low = std.math.minInt(i32);
    const high = std.math.maxInt(i32);
    for ([_]i32{ low, high }, [_]i32{ high, low }) |x, y| {
        const cam = camera.Camera{ .tile_x = x, .tile_y = y };
        const cx = cam.chunkX();
        const cy = cam.chunkY();
        const layout = minimapLayout(.{
            .size_px = 192,
            .radius_tiles = 64,
            .chunks = .{ .cx0 = cx, .cy0 = cy, .cx1 = cx, .cy1 = cy },
        }, cam, 1000);
        try std.testing.expect(layout.playerCenter(y, x) == null);

        const tile = layout.tileOrigin(x, y);
        const next = layout.tileOrigin(@as(i64, x) + 1, @as(i64, y) + 1);
        try std.testing.expectApproxEqAbs(layout.tile_size, next.x - tile.x, 0.001);
        try std.testing.expectApproxEqAbs(layout.tile_size, next.y - tile.y, 0.001);
        const center = layout.playerCenter(x, y).?;
        try std.testing.expectApproxEqAbs(layout.bounds.x + layout.bounds.width / 2, center.x, 0.001);
        try std.testing.expectApproxEqAbs(layout.bounds.y + layout.bounds.height / 2, center.y, 0.001);
        const first = layout.tileOrigin(chunkBaseTile(cx), chunkBaseTile(cy));
        const end = layout.tileOrigin(chunkBaseTile(cx + 1), chunkBaseTile(cy + 1));
        try std.testing.expectEqual(if (x == low) tile.x else next.x, if (x == low) first.x else end.x);
        try std.testing.expectEqual(if (y == low) tile.y else next.y, if (y == low) first.y else end.y);
    }
}

test "minimap repaints cut grass and trees and clears stale cuts" {
    var w = try world.World.init(std.testing.allocator, 1);
    defer w.deinit();
    const area: world.ChunkRange = .{ .cx0 = -1, .cy0 = 0, .cx1 = -1, .cy1 = 0 };
    try w.stream(area);
    const residents = &w.by_key;
    var it = residents.valueIterator();
    while (it.next()) |slot| {
        const chunk = slot.*;
        if (chunk.cx != -1 or chunk.cy != 0) continue;
        chunk.tiles[0..3].* = .{ .grass, .tree, .tree };
    }
    const before = MinimapStamp.get(&w, area);
    var snapshot: @import("shared").protocol.Snapshot = .{ .area = area, .count = 1 };
    snapshot.chunks[0][0] = 0b00000011;
    w.applyCuts(&snapshot);
    try std.testing.expect(!std.meta.eql(before, MinimapStamp.get(&w, area)));
    var pixels: [world.CT * world.CT]rl.Color = undefined;
    paintMinimap(&pixels, world.CT, &w, area);
    try std.testing.expectEqual(pixels[0], pixels[1]);
    try std.testing.expect(!std.meta.eql(minimapColor(.grass), pixels[0]));
    try std.testing.expectEqual(minimapColor(.tree), pixels[2]);
    const cut = MinimapStamp.get(&w, area);
    w.invalidateCuts();
    try std.testing.expect(!std.meta.eql(cut, MinimapStamp.get(&w, area)));
    paintMinimap(&pixels, world.CT, &w, area);
    try std.testing.expectEqual(minimapColor(.grass), pixels[0]);
    try std.testing.expectEqual(minimapColor(.tree), pixels[1]);
}

test "chunk tile iteration skips offscreen rows and columns across negative seams" {
    var west = world.Chunk{ .cx = -1, .cy = -1, .tiles = @splat(.grass) };
    west.tiles[15 * world.CT + 15] = .water;
    const east = world.Chunk{ .cx = 0, .cy = -1, .tiles = @splat(.grass) };
    const bounds = camera.TileRange{ .x0 = -1, .y0 = -1, .x1 = 2, .y1 = 0 };
    var left = ChunkTiles.init(&west, bounds);
    try std.testing.expectEqual(ChunkTiles.Item{ .tile = .water, .index = 255, .tx = -1, .ty = -1 }, left.next().?);
    try std.testing.expect(left.next() == null);
    var right = ChunkTiles.init(&east, bounds);
    try std.testing.expectEqual(ChunkTiles.Item{ .tile = .grass, .index = 240, .tx = 0, .ty = -1 }, right.next().?);
    try std.testing.expectEqual(ChunkTiles.Item{ .tile = .grass, .index = 241, .tx = 1, .ty = -1 }, right.next().?);
    try std.testing.expect(right.next() == null);
}

test "edge chunks keep exact local pixels and a half-open last tile" {
    const low = std.math.minInt(i32);
    const high = std.math.maxInt(i32);
    for ([_]i32{ low, high }) |edge| {
        const coord = @divFloor(edge, world.CHUNK_TILES);
        const chunk = world.Chunk{ .cx = coord, .cy = coord, .tiles = @splat(.grass) };
        const end = @as(i64, edge) + 1;
        const bounds = camera.TileRange{ .x0 = edge, .y0 = edge, .x1 = end, .y1 = end };
        const vis = world.ChunkRange{ .cx0 = coord, .cy0 = coord, .cx1 = coord, .cy1 = coord };
        const anchors = spriteChunks(vis);
        try std.testing.expectEqual(@max(coord - 1, shared.protocol.min_chunk), anchors.cx0);
        try std.testing.expectEqual(@min(coord + 1, shared.protocol.max_chunk), anchors.cy1);

        var tiles = ChunkTiles.init(&chunk, bounds);
        const tile = tiles.next().?;
        try std.testing.expectEqual(edge, tile.tx);
        try std.testing.expectEqual(edge, tile.ty);
        try std.testing.expect(tiles.next() == null);
        try std.testing.expectEqual(0, localPixel(tile.tx, edge));
        try std.testing.expectEqual(@as(f32, world.TILE_PX), localPixel(end, edge));
        const base_px: f32 = @floatFromInt(-@mod(edge, world.CHUNK_TILES) * world.TILE_PX);
        try std.testing.expectEqual(base_px, localPixel(chunkBaseTile(coord), edge));
        try std.testing.expectEqualDeep(rl.Vector2{ .x = 16, .y = 16 }, camera.relativeTileCenter(tile.tx, tile.ty, edge, edge));
    }
}

test "sprite padding keeps anchors in adjacent chunks that can reach the viewport" {
    const bounds = camera.TileRange{ .x0 = 0, .y0 = 0, .x1 = 16, .y1 = 16 };
    const oak = bounds.expanded(3);
    const rock = bounds.expanded(1);
    try std.testing.expectEqual(TileSpan{ .start = 13, .end = 16 }, tileSpan(oak.x0, oak.x1, -1));
    try std.testing.expectEqual(TileSpan{ .start = 0, .end = 3 }, tileSpan(oak.y0, oak.y1, 1));
    try std.testing.expectEqual(TileSpan{ .start = 15, .end = 16 }, tileSpan(rock.y0, rock.y1, -1));
    try std.testing.expectEqual(TileSpan{ .start = 0, .end = 0 }, tileSpan(bounds.x0, bounds.x1, 1));
}

test "grass is a whole tile at 2x beneath grass trees and rocks" {
    try std.testing.expectEqual(16, grass_sheet_width);
    try std.testing.expectEqual(16, grass_sheet_height);
    try std.testing.expectEqualDeep(rl.Rectangle{ .x = 0, .y = 0, .width = 16, .height = 16 }, grass_source);
    try std.testing.expect(grass_source.x + grass_source.width <= grass_sheet_width);
    try std.testing.expect(grass_source.y + grass_source.height <= grass_sheet_height);
    try std.testing.expectEqual(@as(f32, world.TILE_PX), grass_source.width * 2);
    try std.testing.expectEqual(@as(f32, world.TILE_PX), grass_source.height * 2);
    try std.testing.expect(isGrassGround(.grass));
    try std.testing.expect(isGrassGround(.tree));
    try std.testing.expect(!isGrassGround(.dirt));
    try std.testing.expect(isGrassGround(.rock));
    try std.testing.expect(!isGrassGround(.water));
}

test "tall grass source is bounded by the decor atlas and fills a tile at 2x" {
    try std.testing.expectEqualDeep(rl.Rectangle{ .x = 96, .y = 16, .width = 16, .height = 16 }, grass_clump_source);
    try std.testing.expect(grass_clump_source.x >= 0 and grass_clump_source.x + grass_clump_source.width <= decor_sheet_width);
    try std.testing.expect(grass_clump_source.y >= 0 and grass_clump_source.y + grass_clump_source.height <= decor_sheet_height);
    try std.testing.expectEqual(@as(f32, world.TILE_PX), grass_clump_source.width * 2);
    try std.testing.expectEqual(@as(f32, world.TILE_PX), grass_clump_source.height * 2);
}

test "only cut grass uses the persistent cut clump atlas cell" {
    try std.testing.expectEqual(grass_clump_source, grassClumpSource(.grass, false).?);
    const cut = grassClumpSource(.grass, true).?;
    try std.testing.expectEqual(rl.Rectangle{ .x = 16, .y = 16, .width = 16, .height = 16 }, cut);
    try std.testing.expect(cut.x + cut.width <= decor_sheet_width and cut.y + cut.height <= decor_sheet_height);
    try std.testing.expectEqual(null, grassClumpSource(.tree, true));
    try std.testing.expectEqual(null, grassClumpSource(.dirt, true));
}

test "all 256 dirt and water neighbor patterns share bounded shore quadrants at 2x" {
    try std.testing.expectEqualDeep(rl.Rectangle{ .x = 16, .y = 16, .width = 16, .height = 16 }, dirt_source);
    try std.testing.expect(dirt_source.x + dirt_source.width <= dirt_sheet_width);
    try std.testing.expect(dirt_source.y + dirt_source.height <= dirt_sheet_height);
    try std.testing.expectEqual(@as(f32, world.TILE_PX), dirt_source.width * 2);
    try std.testing.expectEqual(@as(f32, world.TILE_PX), dirt_source.height * 2);
    try std.testing.expectEqualDeep(rl.Rectangle{ .x = 0, .y = 80, .width = 16, .height = 16 }, water_source);
    try std.testing.expect(water_source.x + water_source.width <= water_sheet_width);
    try std.testing.expect(water_source.y + water_source.height <= water_sheet_height);
    try std.testing.expectEqual(@as(f32, world.TILE_PX), water_source.width * 2);
    try std.testing.expectEqual(@as(f32, world.TILE_PX), water_source.height * 2);
    const expected_kinds = [_]usize{ 0, 2, 1, 3, 0, 2, 1, 4 };
    for (0..256) |mask| {
        var neighbors: [8]bool = undefined;
        for (&neighbors, 0..) |*present, i| present.* = (mask & (@as(usize, 1) << @intCast(i))) != 0;
        for ([_]world.Tile{ .dirt, .water }) |material| {
            const quadrants = if (material == .water) water_quadrants else dirt_quadrants;
            for (quadrant_neighbors, 0..) |indices, q| {
                const bits = @as(usize, @intFromBool(neighbors[indices[0]])) |
                    (@as(usize, @intFromBool(neighbors[indices[1]])) << 1) |
                    (@as(usize, @intFromBool(neighbors[indices[2]])) << 2);
                const expected = quadrants[q][expected_kinds[bits]];
                const src = shoreQuadrantSource(q, neighbors, material);
                try std.testing.expectEqual(expected[0], src.x);
                try std.testing.expectEqual(expected[1], src.y);
                try std.testing.expect(src.x >= 0 and src.x + src.width <= dirt_sheet_width);
                try std.testing.expect(src.y >= 0 and src.y + src.height <= dirt_sheet_height);
                try std.testing.expect(src.x >= 0 and src.x + src.width <= water_sheet_width);
                try std.testing.expect(src.y >= 0 and src.y + src.height <= water_sheet_height);
                const dest = quadrantDest(-32, -32, q);
                try std.testing.expectEqual(@as(f32, 8), src.width);
                try std.testing.expectEqual(@as(f32, 8), src.height);
                try std.testing.expectEqual(src.width * 2, dest.width);
                try std.testing.expectEqual(src.height * 2, dest.height);
                try std.testing.expectEqual(@as(f32, -32) + @as(f32, @floatFromInt(q % 2)) * 16, dest.x);
                try std.testing.expectEqual(@as(f32, -32) + @as(f32, @floatFromInt(q / 2)) * 16, dest.y);
            }
        }
    }
}

test "dirt concaves use the measured opaque crops" {
    const cases = [_]struct { diagonal: usize, expected: rl.Rectangle }{
        .{ .diagonal = 0, .expected = .{ .x = 20, .y = 68, .width = 8, .height = 8 } },
        .{ .diagonal = 2, .expected = .{ .x = 4, .y = 68, .width = 8, .height = 8 } },
        .{ .diagonal = 5, .expected = .{ .x = 20, .y = 52, .width = 8, .height = 8 } },
        .{ .diagonal = 7, .expected = .{ .x = 4, .y = 52, .width = 8, .height = 8 } },
    };
    for (cases, 0..) |case, quadrant| {
        var neighbors: [8]bool = @splat(true);
        neighbors[case.diagonal] = false;
        try std.testing.expectEqualDeep(case.expected, shoreQuadrantSource(quadrant, neighbors, .dirt));
    }
}

test "water concaves shift inside thicker banks to preserve connected blue" {
    const expected = [4][2]f32{ .{ 22, 70 }, .{ 2, 70 }, .{ 22, 50 }, .{ 2, 50 } };
    for (quadrant_neighbors, expected, 0..) |indices, xy, q| {
        var neighbors: [8]bool = @splat(true);
        neighbors[indices[2]] = false;
        try std.testing.expectEqualDeep(rl.Rectangle{ .x = xy[0], .y = xy[1], .width = 8, .height = 8 }, shoreQuadrantSource(q, neighbors, .water));
        try std.testing.expectEqualDeep(xy, water_quadrants[q][3]);
    }
}

test "dirt and water neighbors cross negative chunk boundaries and match fallback terrain" {
    var resident = try world.World.init(std.testing.allocator, 36);
    defer resident.deinit();
    try resident.stream(.{ .cx0 = -1, .cy0 = -1, .cx1 = 0, .cy1 = 0 });
    var absent = try world.World.init(std.testing.allocator, 0);
    defer absent.deinit();
    var found_dirt = false;
    var found_water = false;
    var y: i32 = -64;
    while (y <= 64) : (y += 1) {
        var x: i32 = -64;
        while (x <= 64) : (x += 1) {
            const sampled = terrain.sampleTile(terrain.public_seed, x, y);
            found_dirt = found_dirt or sampled == .dirt;
            found_water = found_water or sampled == .water;
            for ([_]world.Tile{ .dirt, .water }) |kind| {
                try std.testing.expectEqual(sampled == kind, isTerrain(&resident, x, y, kind));
                try std.testing.expectEqual(isTerrain(&resident, x, y, kind), isTerrain(&absent, x, y, kind));
                try std.testing.expectEqualDeep(terrainNeighbors(&resident, x, y, kind), terrainNeighbors(&absent, x, y, kind));
            }
        }
    }
    try std.testing.expect(found_dirt);
    try std.testing.expect(found_water);

    // Owned fixture chunks: (-1,-1)'s east/south/diagonal cross chunk zero.
    for ([_]world.Tile{ .dirt, .water }) |kind| {
        const quadrants = if (kind == .water) water_quadrants else dirt_quadrants;
        var it = resident.by_key.valueIterator();
        while (it.next()) |chunk| @memset(&chunk.*.tiles, kind);
        var neighbors = terrainNeighbors(&resident, -1, -1, kind);
        try std.testing.expect(std.mem.allEqual(bool, &neighbors, true));
        const other: world.Tile = if (kind == .dirt) .water else .dirt;
        const other_neighbors = terrainNeighbors(&resident, -1, -1, other);
        try std.testing.expect(std.mem.allEqual(bool, &other_neighbors, false));
        for (0..4) |q| {
            const src = shoreQuadrantSource(q, neighbors, kind);
            try std.testing.expectEqual(quadrants[q][4][0], src.x);
            try std.testing.expectEqual(quadrants[q][4][1], src.y);
        }
        it = resident.by_key.valueIterator();
        while (it.next()) |chunk| {
            if (chunk.*.cx == 0 and chunk.*.cy == 0) chunk.*.tiles[0] = .grass;
        }
        neighbors = terrainNeighbors(&resident, -1, -1, kind);
        for (0..4) |q| {
            const src = shoreQuadrantSource(q, neighbors, kind);
            const expected = quadrants[q][if (q == 3) 3 else 4];
            try std.testing.expectEqual(expected[0], src.x);
            try std.testing.expectEqual(expected[1], src.y);
        }
        it = resident.by_key.valueIterator();
        while (it.next()) |chunk| {
            if (chunk.*.cx == 0 and chunk.*.cy == -1) chunk.*.tiles[15 * world.CT] = .tree;
        }
        neighbors = terrainNeighbors(&resident, -1, -1, kind);
        try std.testing.expect(!neighbors[4]); // Trees never connect to dirt or water.
        try std.testing.expectEqualDeep(rl.Rectangle{ .x = 32, .y = 16, .width = 8, .height = 8 }, shoreQuadrantSource(1, neighbors, kind));
        try std.testing.expectEqualDeep(rl.Rectangle{ .x = 32, .y = 24, .width = 8, .height = 8 }, shoreQuadrantSource(3, neighbors, kind));
        it = resident.by_key.valueIterator();
        while (it.next()) |chunk| @memset(&chunk.*.tiles, .grass);
        neighbors = terrainNeighbors(&resident, -1, -1, kind);
        try std.testing.expect(std.mem.allEqual(bool, &neighbors, false));
        for (0..4) |q| {
            const src = shoreQuadrantSource(q, neighbors, kind);
            try std.testing.expectEqual(quadrants[q][0][0], src.x);
            try std.testing.expectEqual(quadrants[q][0][1], src.y);
        }
    }
}

test "shore neighbors do not wrap at protocol corners" {
    var w = try world.World.init(std.testing.allocator, 1);
    defer w.deinit();
    const low = std.math.minInt(i32);
    const high = std.math.maxInt(i32);
    for ([_]i32{ low, high }) |edge| {
        const coord = @divFloor(edge, world.CHUNK_TILES);
        try w.stream(.{ .cx0 = coord, .cy0 = coord, .cx1 = coord, .cy1 = coord });
        var residents = w.by_key.valueIterator();
        while (residents.next()) |slot| @memset(&slot.*.tiles, .water);
        const expected: [8]bool = if (edge == low)
            .{ false, false, false, false, true, false, true, true }
        else
            .{ true, true, false, true, false, false, false, false };
        try std.testing.expectEqualDeep(expected, terrainNeighbors(&w, edge, edge, .water));
    }
}

test "rock crop doubles with its baseline at the ground tile bottom center" {
    try std.testing.expectEqual(112, decor_sheet_width);
    try std.testing.expectEqual(192, decor_sheet_height);
    try std.testing.expectEqualDeep(rl.Rectangle{ .x = 32, .y = 32, .width = 16, .height = 16 }, rock_source);
    try std.testing.expect(rock_source.x >= 0 and rock_source.x + rock_source.width <= decor_sheet_width);
    try std.testing.expect(rock_source.y >= 0 and rock_source.y + rock_source.height <= decor_sheet_height);
    for ([_]f32{ 0, -32 }) |pixel| {
        const dest = rockDest(pixel, pixel);
        try std.testing.expectEqual(pixel, dest.x);
        try std.testing.expectEqual(pixel + 8, dest.y);
        try std.testing.expectEqual(rock_source.width * 2, dest.width);
        try std.testing.expectEqual(rock_source.height * 2, dest.height);
        try std.testing.expectEqual(@as(f32, world.TILE_PX), dest.width);
        try std.testing.expectEqual(pixel + world.TILE_PX / 2, dest.x + 8 * 2);
        try std.testing.expectEqual(pixel + world.TILE_PX, dest.y + 12 * 2);
    }
}

test "oak root doubles around the ground tile bottom center" {
    try std.testing.expectEqual(64, oak_sheet_width);
    try std.testing.expectEqual(80, oak_sheet_height);
    try std.testing.expectEqualDeep(rl.Rectangle{ .x = 0, .y = 0, .width = 64, .height = 80 }, oak_source);
    try std.testing.expect(oak_source.x + oak_source.width <= oak_sheet_width);
    try std.testing.expect(oak_source.y + oak_source.height <= oak_sheet_height);
    for ([_]f32{ 0, -32 }) |pixel| {
        const dest = oakDest(pixel, pixel);
        try std.testing.expectEqual(pixel - 48, dest.x);
        try std.testing.expectEqual(pixel - 96, dest.y);
        try std.testing.expectEqual(oak_source.width * 2, dest.width);
        try std.testing.expectEqual(oak_source.height * 2, dest.height);
        try std.testing.expectEqual(pixel + world.TILE_PX / 2, dest.x + 32 * 2);
        try std.testing.expectEqual(pixel + world.TILE_PX, dest.y + 64 * 2);
    }
}

test "oak tint fades only foreground art that can cover the player" {
    const feet = camera.relativeTileCenter(-1, -1, 0, 0);
    // A canopy rooted across the chunk seam can still cover the player.
    try std.testing.expectEqual(occluding_oak_tint, oakTint(oakDest(0, 0), feet));
    try std.testing.expectEqual(occluding_oak_tint, oakTint(oakDest(-32, 32), feet));
    try std.testing.expectEqual(occluding_oak_tint, oakTint(oakDest(-64, -32), feet));
    // Behind the feet, beside the body, or only cell padding above the feet.
    try std.testing.expectEqual(rl.Color.white, oakTint(oakDest(-32, -64), feet));
    try std.testing.expectEqual(rl.Color.white, oakTint(oakDest(32, 0), feet));
    try std.testing.expectEqual(rl.Color.white, oakTint(oakDest(-32, 64), feet));
}

test "sprite anchor ring includes adjacent offscreen canopies and shadows at negative coordinates" {
    for ([_]i32{ 0, -2 }) |chunk_coord| {
        const vis = world.ChunkRange{ .cx0 = chunk_coord, .cy0 = chunk_coord, .cx1 = chunk_coord, .cy1 = chunk_coord };
        const anchors = spriteChunks(vis);
        try std.testing.expectEqual(chunk_coord - 1, anchors.cx0);
        try std.testing.expectEqual(chunk_coord - 1, anchors.cy0);
        try std.testing.expectEqual(chunk_coord + 1, anchors.cx1);
        try std.testing.expectEqual(chunk_coord + 1, anchors.cy1);
        const left = localPixel(chunkBaseTile(chunk_coord), 0);
        const right = left + world.CHUNK_PX;
        // The first anchor below the viewport still paints its canopy inside it.
        const below = oakDest(left, right);
        try std.testing.expect(below.y + 9 * 2 < right and below.y + 72 * 2 > right);
        const east = oakDest(right, left);
        try std.testing.expect(east.x + 11 * 2 < right);
        const west = oakDest(left - world.TILE_PX, left);
        try std.testing.expect(west.x + 52 * 2 > left);
        const above = oakDest(left, left - world.TILE_PX);
        try std.testing.expect(above.y + 72 * 2 > left);
        const rock_above = rockDest(left, left - world.TILE_PX);
        try std.testing.expectEqual(left + 4, rock_above.y + 14 * 2);
    }
}
