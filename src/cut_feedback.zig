//! Presentation only. Submit a ConfirmedCut after receiving confirmation from
//! an authoritative source; this runtime never edits cut bits or wallet state.
const std = @import("std");
const Location = @import("shared").protocol.Location;

pub const ConfirmedCut = struct {
    tile: Location,
    refill_needed: bool = false,
};

pub const Cues = struct {
    snip: bool = false,
    fail: bool = false,
};

pub const burst_seconds: f32 = 0.42;
const fail_delay: f32 = 0.20;
const notice_seconds: f32 = 1.8;
const capacity = 16;

pub const Burst = struct {
    tile: Location,
    age: f32 = 0,
    snip_pending: bool = true,
    refill_needed: bool,
};

pub const Feedback = struct {
    bursts: [capacity]Burst = undefined,
    count: usize = 0,
    refill_remaining: f32 = 0,

    pub fn confirm(self: *Feedback, event: ConfirmedCut) void {
        if (self.count == capacity) {
            std.mem.copyForwards(Burst, self.bursts[0 .. capacity - 1], self.bursts[1..]);
            self.count -= 1;
        }
        self.bursts[self.count] = .{ .tile = event.tile, .refill_needed = event.refill_needed };
        self.count += 1;
    }

    pub fn activeBursts(self: *const Feedback) []const Burst {
        return self.bursts[0..self.count];
    }

    pub fn showRefillNotice(self: *const Feedback) bool {
        return self.refill_remaining > 0;
    }

    /// Tick once per presentation frame. Multiple events in a frame share one
    /// playback of each cue. Start a new burst at age zero even after a stall.
    pub fn update(self: *Feedback, elapsed: f32) Cues {
        const dt = @max(elapsed, 0);
        self.refill_remaining = @max(self.refill_remaining - dt, 0);
        var cues: Cues = .{};
        var kept: usize = 0;
        for (self.activeBursts()) |burst| {
            var next = burst;
            if (burst.snip_pending) {
                cues.snip = true;
                next.snip_pending = false;
            } else {
                next.age += dt;
                if (burst.refill_needed and burst.age < fail_delay and next.age >= fail_delay) {
                    cues.fail = true;
                    self.refill_remaining = notice_seconds;
                }
            }
            if (next.age >= burst_seconds) continue;
            self.bursts[kept] = next;
            kept += 1;
        }
        self.count = kept;
        return cues;
    }
};

test "confirmed cut anchors a short burst and emits only one snip by default" {
    var feedback: Feedback = .{};
    try std.testing.expectEqual(Cues{}, feedback.update(1));
    const tile: Location = .{ .x = -17, .y = 16 };
    feedback.confirm(.{ .tile = tile });
    try std.testing.expectEqual(Cues{ .snip = true }, feedback.update(1));
    try std.testing.expectEqual(tile, feedback.activeBursts()[0].tile);
    try std.testing.expectEqual(@as(f32, 0), feedback.activeBursts()[0].age);
    try std.testing.expectEqual(Cues{}, feedback.update(burst_seconds));
    try std.testing.expectEqual(0, feedback.activeBursts().len);
    try std.testing.expect(!feedback.showRefillNotice());
}

test "optional fail and refill notice follow the snip even across a long frame" {
    var feedback: Feedback = .{};
    feedback.confirm(.{ .tile = .{ .x = 0, .y = -1 }, .refill_needed = true });
    try std.testing.expectEqual(Cues{ .snip = true }, feedback.update(1));
    try std.testing.expect(!feedback.showRefillNotice());
    try std.testing.expectEqual(Cues{}, feedback.update(fail_delay / 2));
    try std.testing.expect(!feedback.showRefillNotice());
    try std.testing.expectEqual(Cues{ .fail = true }, feedback.update(1));
    try std.testing.expect(feedback.showRefillNotice());
    try std.testing.expectEqual(0, feedback.activeBursts().len);
    try std.testing.expectEqual(Cues{}, feedback.update(notice_seconds));
    try std.testing.expect(!feedback.showRefillNotice());
}

test "overlapping bursts are bounded and expire independently" {
    var feedback: Feedback = .{};
    for (0..capacity + 1) |x| feedback.confirm(.{ .tile = .{ .x = @intCast(x), .y = 0 } });
    try std.testing.expectEqual(capacity, feedback.activeBursts().len);
    try std.testing.expectEqual(1, feedback.activeBursts()[0].tile.x);
    try std.testing.expectEqual(Cues{ .snip = true }, feedback.update(0));
    feedback.confirm(.{ .tile = .{ .x = -1, .y = 0 } });
    try std.testing.expectEqual(Cues{ .snip = true }, feedback.update(burst_seconds));
    try std.testing.expectEqual(1, feedback.activeBursts().len);
    try std.testing.expectEqual(-1, feedback.activeBursts()[0].tile.x);
}
