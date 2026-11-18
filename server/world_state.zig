//! Fixed-capacity, process-lifetime world and cut replay history. No allocator.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const world = shared.world;
const actions = @import("actions.zig");

pub const WorldState = struct {
    pub const capacity = 512;
    pub const Chunk = struct { cx: i32, cy: i32, cuts: [32]u8 };
    pub const Replay = struct { id: p.Id, version: u16, tile: p.Cut, result: p.CutResult };
    chunks: [capacity]Chunk = undefined,
    replays: [capacity]Replay = undefined,
    chunk_count: usize = 0,
    replay_count: usize = 0,

    fn findChunk(self: *const WorldState, cx: i32, cy: i32) ?usize {
        for (self.chunks[0..self.chunk_count], 0..) |chunk, i| {
            if (chunk.cx == cx and chunk.cy == cy) return i;
        }
        return null;
    }

    pub fn cut(self: *WorldState, req: p.Request) error{CapacityExceeded}!p.CutResult {
        const tile = req.operation.cut;
        for (self.replays[0..self.replay_count]) |entry| {
            if (!std.mem.eql(u8, &entry.id, &req.request_id)) continue;
            if (entry.version != req.version or entry.tile.x != tile.x or entry.tile.y != tile.y)
                return .{ .failure = .{ .code = .request_id_conflict } };
            return entry.result;
        }
        const cx = @divFloor(tile.x, 16);
        const cy = @divFloor(tile.y, 16);
        const index = self.findChunk(cx, cy);
        const bit: usize = @intCast(@mod(tile.y, 16) * 16 + @mod(tile.x, 16));
        const mask = @as(u8, 1) << @as(u3, @intCast(bit % 8));
        const already = if (index) |i| self.chunks[i].cuts[bit / 8] & mask != 0 else false;
        const result = actions.cutRule(.{ .x = tile.x, .y = tile.y, .terrain = world.sampleTile(world.public_seed, tile.x, tile.y), .cut = already });
        if (self.replay_count == capacity) return error.CapacityExceeded;
        if (result == .success and index == null and self.chunk_count == capacity) return error.CapacityExceeded;
        // All admission checks precede publication; nothing below can fail.
        if (result == .success) {
            const i = index orelse self.chunk_count;
            if (index == null) {
                self.chunks[i] = .{ .cx = cx, .cy = cy, .cuts = @splat(0) };
                self.chunk_count += 1;
            }
            self.chunks[i].cuts[bit / 8] |= mask;
        }
        self.replays[self.replay_count] = .{ .id = req.request_id, .version = req.version, .tile = tile, .result = result };
        self.replay_count += 1;
        return result;
    }

    pub fn readArea(self: *const WorldState, area: world.ChunkRange, out: *p.Snapshot) error{InvalidArea}!void {
        if (actions.validateArea(area) != null) return error.InvalidArea;
        const cols: usize = @intCast(@as(i64, area.cx1) - area.cx0 + 1);
        const rows: usize = @intCast(@as(i64, area.cy1) - area.cy0 + 1);
        out.* = .{ .area = area, .count = @intCast(cols * rows) };
        for (0..rows) |y| for (0..cols) |x| {
            const cx = area.cx0 + @as(i32, @intCast(x));
            const cy = area.cy0 + @as(i32, @intCast(y));
            if (self.findChunk(cx, cy)) |i| out.chunks[y * cols + x] = self.chunks[i].cuts;
        };
    }
};

pub fn request(id: u128, x: i32, y: i32) p.Request {
    var bytes: p.Id = undefined;
    std.mem.writeInt(u128, &bytes, id, .little);
    return .{ .request_id = bytes, .operation = .{ .cut = .{ .x = x, .y = y } } };
}
