//! Shared rules for paid-cut reach and authoritative replies.
const protocol = @import("shared").protocol;

pub fn withinReach(tile: protocol.Location, confirmed: protocol.Location) bool {
    return @abs(@as(i64, tile.x) - confirmed.x) <= 1 and @abs(@as(i64, tile.y) - confirmed.y) <= 1;
}

pub const ReplyVerdict = enum { charged, already_cut };

pub fn classify(tile: protocol.Location, outcome: protocol.Outcome(.cut)) ?ReplyVerdict {
    const state = switch (outcome) {
        .ok => |state| state,
        .failed => |failure| switch (failure) {
            // The paid-cut handler checks this before accepting the payment.
            .already_cut => |state| state,
            else => return null,
        },
    };
    if (state.x != tile.x or state.y != tile.y or state.terrain != .grass or !state.cut) return null;
    return if (outcome == .ok) .charged else .already_cut;
}
