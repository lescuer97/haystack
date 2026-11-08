const std = @import("std");

const tile_size_px = 16;
// the chunk sizes are the amount of
const CHUNK_TILES = 16;

const CutStatus = enum { Cut, Uncut };

// type of entity to be rendered
const TileEntitity = union {
    Tree: struct { status: CutStatus },
    Grass: struct { status: CutStatus },
    Character: struct { yourself: bool },
};

const Tile = struct { x: u8, y: u8, entity: TileEntitity };

// The chunk is the container and the identity.
const ChunkKey = struct { cx: i32, cy: i32 };

const Chunk = struct {
    key: ChunkKey,
    tiles: [CHUNK_TILES * CHUNK_TILES]Tile, // row-major: idx = ly*16 + lx
    dirty: bool = true,
};
