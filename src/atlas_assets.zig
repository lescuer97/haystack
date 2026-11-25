//! Sprite sheets used by the renderer and embedded by the standalone build.
pub const Atlas = struct { path: []const u8, width: i32, height: i32 };

pub const grass: Atlas = .{ .path = "assets/Tiles/Grass_Middle.png", .width = 16, .height = 16 };
pub const dirt: Atlas = .{ .path = "assets/Tiles/Path_Tile.png", .width = 48, .height = 96 };
pub const water: Atlas = .{ .path = "assets/Tiles/Water_Tile.png", .width = 48, .height = 96 };
pub const oak: Atlas = .{ .path = "assets/Outdoor decoration/Oak_Tree.png", .width = 64, .height = 80 };
pub const decor: Atlas = .{ .path = "assets/Outdoor decoration/Outdoor_Decor_Free.png", .width = 112, .height = 192 };
pub const player: Atlas = .{ .path = "assets/Player/Player.png", .width = 192, .height = 320 };
pub const player_actions: Atlas = .{ .path = "assets/Player/Player_Actions.png", .width = 96, .height = 576 };

pub const all = [_]Atlas{ grass, dirt, water, oak, decor, player, player_actions };
