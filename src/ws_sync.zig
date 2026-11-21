//! Shared frame-side reconciliation for desktop and browser connections.
const std = @import("std");
const shared = @import("shared");
const game_mod = @import("game.zig");
const frame_loop = @import("frame_loop.zig");

pub const Status = enum { disabled, connecting, authenticating, ready, retrying, wallet_error, credentials_rejected };
pub const Snapshot = struct {
    status: Status = .disabled,
    session: u64 = 0,
    confirmed: shared.protocol.Location = shared.movement.spawn,
    pending: bool = false,
};

pub const Frame = struct {
    status: Status = .disabled,
    session: u64 = 0,

    pub fn apply(self: *Frame, network: Snapshot, driver: *frame_loop.Driver, game: *game_mod.GameState) !?[:0]const u8 {
        if ((self.status == .ready) != (network.status == .ready)) {
            driver.invalidateInput();
            game.camera.resetDrag();
            game.player_walking = false;
        }
        self.status = network.status;
        if (network.status == .ready and (network.session != self.session or
            (!network.pending and !std.meta.eql(game.player_pos, network.confirmed))))
        {
            try game.camera.setTarget(network.confirmed.x, network.confirmed.y);
            game.camera.resetDrag();
            game.player_pos = network.confirmed;
            game.player_walking = false;
            driver.invalidateInput();
            driver.view = null;
        }
        self.session = network.session;
        driver.movement_blocked = network.pending;
        return switch (network.status) {
            .disabled, .ready => null,
            .connecting => "Connecting to the game server...",
            .authenticating => "Authenticating your wallet...",
            .retrying => "Server unavailable. Retrying...",
            .wallet_error => "Could not sign with the wallet. Retrying...",
            .credentials_rejected => "Server rejected the wallet proof. Retrying...",
        };
    }
};
