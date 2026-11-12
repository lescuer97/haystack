//! Player settings and their defaults.
//!
//! This module is deliberately free of Raylib and filesystem dependencies so
//! configuration serialization can be tested without a window or the wallet.
//! `game.zig` re-exports these types for the rest of the application.

const std = @import("std");
const builtin = @import("builtin");

/// Debug view toggles. Tiles are never filled with colour; only the grid lines
/// and chunk borders are drawn. On by default in Debug builds.
pub const DebugSettings = struct {
    tile_grid: bool = builtin.mode == .debug,
    chunk_borders: bool = builtin.mode == .debug,
};

/// Player-configurable settings. Debug view toggles live under `.debug`.
pub const Settings = struct { debug: DebugSettings = .{} };
