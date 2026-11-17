//! Public terrain v1. Independent of rendering, transport, and persistence.
const std = @import("std");
pub const TILE_PX: i32 = 32;
pub const CHUNK_TILES: i32 = 16;
pub const CHUNK_PX: i32 = TILE_PX * CHUNK_TILES;
pub const CT: usize = CHUNK_TILES;
pub const public_seed: [32]u8 = @splat(0);
pub const generator_version = 1;
pub const Tile = enum(u8) { grass, dirt, rock, tree };
pub const Chunk = struct {
    cx: i32 = 0,
    cy: i32 = 0,
    tiles: [CT * CT]Tile = undefined,
};
pub const ChunkRange = struct {
    cx0: i32,
    cy0: i32,
    cx1: i32,
    cy1: i32,
    // Convenience arithmetic for validated cache-sized ranges. Server area
    // validation widens before arithmetic rather than calling these methods.
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
        return .{ .cx0 = self.cx0 - margin, .cy0 = self.cy0 - margin, .cx1 = self.cx1 + margin, .cy1 = self.cy1 + margin };
    }
};

fn mix32(value: u32) u32 {
    var h = value;
    h ^= h >> 15;
    h *%= 0x2545F491;
    h ^= h >> 13;
    return h;
}
fn hash2(seed: [32]u8, x: i32, y: i32) u32 {
    // Public, non-cryptographic layout hash. Mix coordinates in order so
    // mirrored pairs are not folded together. Consume all eight seed words
    // little-endian, in array order; this encoding is part of terrain v1.
    var h: u32 = @as(u32, @bitCast(x)) *% 0x9E3779B1;
    h = mix32(h);
    h ^= @as(u32, @bitCast(y)) *% 0x85EBCA77;
    h = mix32(h);
    inline for (0..8) |i| {
        h ^= std.mem.readInt(u32, seed[4 * i ..][0..4], .little);
        h = mix32(h);
    }
    return h;
}
const forest_spacing = 32;
const rock_spacing = 16;
const dirt_spacing = 8;
const forest_threshold = 32000;
const rock_threshold = 51000;
const dirt_threshold = 55000;
fn layoutHash(seed: [32]u8, domain: u8, x: i32, y: i32) u32 {
    var derived = seed;
    derived[0] ^= domain;
    return hash2(derived, x, y);
}
fn smoothFraction(remainder: i32, comptime spacing: i32) u64 {
    const t = @as(u64, @intCast(remainder)) * 65536 / @as(u64, spacing);
    return (t * t * (3 * 65536 - 2 * t)) >> 32;
}
fn interpolate(a: u64, b: u64, t: u64) u64 {
    return (a * (65536 - t) + b * t) >> 16;
}
fn valueNoise(seed: [32]u8, domain: u8, x: i32, y: i32, comptime spacing: i32) u32 {
    const gx = @divFloor(x, spacing);
    const gy = @divFloor(y, spacing);
    const tx = smoothFraction(@mod(x, spacing), spacing);
    const ty = smoothFraction(@mod(y, spacing), spacing);
    const top = interpolate(layoutHash(seed, domain, gx, gy) >> 16, layoutHash(seed, domain, gx + 1, gy) >> 16, tx);
    const bottom = interpolate(layoutHash(seed, domain, gx, gy + 1) >> 16, layoutHash(seed, domain, gx + 1, gy + 1) >> 16, tx);
    return @intCast(interpolate(top, bottom, ty));
}
pub fn sampleTile(seed: [32]u8, x: i32, y: i32) Tile {
    if (valueNoise(seed, 2, x, y, rock_spacing) >= rock_threshold) return .rock;
    const forest = valueNoise(seed, 1, x, y, forest_spacing);
    if (forest >= forest_threshold) {
        const density = @min(56000, 22000 + forest - forest_threshold);
        if (layoutHash(seed, 4, x, y) >> 16 < density) return .tree;
    }
    if (valueNoise(seed, 3, x, y, dirt_spacing) >= dirt_threshold) return .dirt;
    return .grass;
}
pub fn generate(chunk: *Chunk) void {
    // Precondition: the whole chunk fits i32 tile coordinates. The client
    // validates its stricter drawable range; the server samples absolute tiles.
    for (0..CT) |ly| {
        for (0..CT) |lx| {
            const x = chunk.cx * CHUNK_TILES + @as(i32, @intCast(lx));
            const y = chunk.cy * CHUNK_TILES + @as(i32, @intCast(ly));
            chunk.tiles[ly * CT + lx] = sampleTile(public_seed, x, y);
        }
    }
}

const zero_seed = public_seed;
const one_seed: [32]u8 = blk: {
    var seed: [32]u8 = @splat(0);
    seed[0] = 1;
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
    for (coords) |coord| try std.testing.expectEqual(hash2(hash_seed, coord.x, coord.y), hash2(hash_seed, coord.x, coord.y));
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
    const pairs = [_][2]i32{ .{ 7, -3 }, .{ 5, 9 }, .{ 37, -91 }, .{ -7, -3 }, .{ 1, 0 }, .{ 0, 1 }, .{ 4194302, -4194304 } };
    for ([_][32]u8{ zero_seed, hash_seed }) |seed| {
        for (pairs) |pair| try std.testing.expect(hash2(seed, pair[0], pair[1]) != hash2(seed, -pair[0], -pair[1]));
    }
}
test "every seed bit participates in hash2" {
    for ([_][32]u8{ zero_seed, hash_seed }) |base| {
        const expected = hash2(base, 37, -91);
        for (0..256) |bit| {
            var mutated = base;
            mutated[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
            try std.testing.expect(hash2(mutated, 37, -91) != expected);
        }
    }
}
test "seed limb order is not a plain xor fold" {
    var reversed: [32]u8 = undefined;
    inline for (0..8) |i| @memcpy(reversed[4 * (7 - i) ..][0..4], hash_seed[4 * i ..][0..4]);
    try std.testing.expect(hash2(hash_seed, 5, 9) != hash2(reversed, 5, 9));
}
test "terrain absolute sampling crosses negative seams" {
    inline for (.{ .{ .domain = 1, .spacing = forest_spacing }, .{ .domain = 2, .spacing = rock_spacing }, .{ .domain = 3, .spacing = dirt_spacing } }) |field| {
        for ([_]i32{ -1, 0, 1 }) |gy| {
            for ([_]i32{ -1, 0, 1 }) |gx| {
                const x = gx * field.spacing;
                const y = gy * field.spacing;
                const corner = layoutHash(zero_seed, field.domain, gx, gy) >> 16;
                try std.testing.expectEqual(corner, valueNoise(zero_seed, field.domain, x, y, field.spacing));
                for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |offset| {
                    const nearby = valueNoise(zero_seed, field.domain, x + offset[0], y + offset[1], field.spacing);
                    try std.testing.expect(@abs(@as(i64, nearby) - corner) <= 4096);
                }
            }
        }
    }
}

test "terrain v1 distribution correlation and fixed region checksum" {
    const side = 512;
    const total = side * side;
    var tiles: [total]Tile = undefined;
    var counts: [4]u64 = @splat(0);
    var neighbors: [4]u64 = @splat(0);
    var forest_grass: usize = 0;
    var forest_trees: usize = 0;
    var checksum: u64 = 0xcbf29ce484222325;
    for (&tiles, 0..) |*tile, i| {
        const x = @as(i32, @intCast(i % side)) - side / 2;
        const y = @as(i32, @intCast(i / side)) - side / 2;
        tile.* = sampleTile(public_seed, x, y);
        counts[@backingInt(tile.*)] += 1;
        checksum = (checksum ^ @backingInt(tile.*)) *% 0x100000001b3;
        if (valueNoise(public_seed, 1, x, y, forest_spacing) >= forest_threshold) {
            if (tile.* == .grass) forest_grass += 1;
            if (tile.* == .tree) forest_trees += 1;
        }
    }
    for (tiles, 0..) |tile, i| {
        if (i % side + 1 < side and tile == tiles[i + 1]) neighbors[@backingInt(tile)] += 1;
        if (i / side + 1 < side and tile == tiles[i + side]) neighbors[@backingInt(tile)] += 1;
    }
    const grass = counts[@backingInt(Tile.grass)];
    const trees = counts[@backingInt(Tile.tree)];
    const rocks = counts[@backingInt(Tile.rock)];
    const dirt = counts[@backingInt(Tile.dirt)];
    try std.testing.expect(grass > total / 2 and grass > trees and trees > rocks and rocks > dirt and dirt > 0);
    for ([_]Tile{ .tree, .rock, .dirt }) |tile| {
        const i = @backingInt(tile);
        try std.testing.expect(neighbors[i] * total * 10 > counts[i] * counts[i] * 26);
    }
    try std.testing.expect(forest_trees > 0 and forest_grass > forest_trees / 4);
    try std.testing.expectEqual(@as(u64, 0xec04d88c8e6885e5), checksum);
}

test "negative seams chunk parity and full i32 tile coordinates" {
    for ([_]i32{ -2, -1, 0, 1, -134217728, 134217727 }) |cy| {
        for ([_]i32{ -2, -1, 0, 1, -134217728, 134217727 }) |cx| {
            var chunk = Chunk{ .cx = cx, .cy = cy };
            generate(&chunk);
            for (chunk.tiles, 0..) |tile, i| {
                try std.testing.expectEqual(sampleTile(public_seed, cx * CHUNK_TILES + @as(i32, @intCast(i % CT)), cy * CHUNK_TILES + @as(i32, @intCast(i / CT))), tile);
            }
        }
    }
    _ = sampleTile(public_seed, std.math.minInt(i32), std.math.maxInt(i32));
    _ = sampleTile(public_seed, std.math.maxInt(i32), std.math.minInt(i32));
    try std.testing.expectEqual(@as(u32, 0x4419CA0F), hash2(public_seed, 7, -3));
    try std.testing.expectEqual(@as(u32, 0xDA013E35), hash2(public_seed, std.math.minInt(i32), std.math.maxInt(i32)));
}
