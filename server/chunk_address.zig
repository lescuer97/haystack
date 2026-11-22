const shared = @import("shared");

pub const ChunkAddress = packed struct(u64) {
    cx: i32,
    cy: i32,

    pub fn fromTile(x: i32, y: i32) ChunkAddress {
        return .{ .cx = @divFloor(x, shared.world.CHUNK_TILES), .cy = @divFloor(y, shared.world.CHUNK_TILES) };
    }
};

pub const AreaIterator = struct {
    origin: ChunkAddress,
    geometry: shared.protocol.AreaGeometry,
    offset: usize = 0,

    /// Geometry must come from validating this area.
    pub fn init(area: shared.world.ChunkRange, geometry: shared.protocol.AreaGeometry) AreaIterator {
        return .{ .origin = .{ .cx = area.cx0, .cy = area.cy0 }, .geometry = geometry };
    }

    pub fn next(self: *AreaIterator) ?ChunkAddress {
        const i = self.offset;
        if (i == self.geometry.count) return null;
        self.offset += 1;
        return .{
            .cx = self.origin.cx + @as(i32, @intCast(i % self.geometry.cols)),
            .cy = self.origin.cy + @as(i32, @intCast(i / self.geometry.cols)),
        };
    }
};
