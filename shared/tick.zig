//! Pure, phase-preserving 20 Hz scheduling. Callers supply their own clock.
const std = @import("std");

pub const rate_hz = 20;
pub const interval_ns = 50_000_000;
pub const dt_seconds = 0.05;

pub const Schedule = struct {
    last_observed_ns: ?i128 = null,
    next_deadline_ns: ?i128 = null,

    /// Grants at most one update, discarding missed ticks rather than queuing
    /// catch-up work. The first call or a backward clock grants a fresh update.
    pub fn poll(self: *Schedule, now_ns: i128) bool {
        if (self.observe(now_ns)) {
            self.advancePast(now_ns, now_ns);
            return true;
        }
        const deadline = self.next_deadline_ns orelse return false;
        if (now_ns < deadline) return false;
        self.advancePast(deadline, now_ns);
        return true;
    }

    /// After work, discard passed boundaries without granting another update.
    /// An unstarted or backward clock establishes a fresh future deadline.
    pub fn skipPast(self: *Schedule, now_ns: i128) void {
        if (self.observe(now_ns)) {
            self.advancePast(now_ns, now_ns);
            return;
        }
        const deadline = self.next_deadline_ns orelse return;
        if (now_ns >= deadline) self.advancePast(deadline, now_ns);
    }

    /// Null means unstarted or exhausted: no future i128 deadline exists.
    /// Exhaustion suppresses updates until a backward clock resets the baseline.
    pub fn nextDeadline(self: *const Schedule) ?i128 {
        return self.next_deadline_ns;
    }

    fn observe(self: *Schedule, now_ns: i128) bool {
        const fresh = if (self.last_observed_ns) |last| now_ns < last else true;
        self.last_observed_ns = now_ns;
        return fresh;
    }

    fn advancePast(self: *Schedule, baseline_ns: i128, now_ns: i128) void {
        // Widen before subtracting: two valid i128 timestamps can differ by
        // more than maxInt(i128). The result retains the original cadence phase.
        const elapsed = @as(i256, now_ns) - @as(i256, baseline_ns);
        const remaining = interval_ns - @mod(elapsed, interval_ns);
        const next = @as(i256, now_ns) + remaining;
        self.next_deadline_ns = if (next <= std.math.maxInt(i128)) @intCast(next) else null;
    }
};

test "immediate update, before and exact boundary, repeated timestamp" {
    var schedule: Schedule = .{};
    try std.testing.expectEqual(@as(?i128, null), schedule.nextDeadline());
    try std.testing.expect(schedule.poll(100));
    try std.testing.expectEqual(@as(?i128, 100 + interval_ns), schedule.nextDeadline());
    try std.testing.expect(!schedule.poll(100));
    try std.testing.expect(!schedule.poll(100 + interval_ns - 1));
    try std.testing.expect(schedule.poll(100 + interval_ns));
    try std.testing.expect(!schedule.poll(100 + interval_ns));
    try std.testing.expectEqual(@as(?i128, 100 + 2 * interval_ns), schedule.nextDeadline());
}

test "long stall yields once and preserves cadence phase" {
    var schedule: Schedule = .{};
    try std.testing.expect(schedule.poll(123));
    const stalled = 123 + 1000 * interval_ns + 17;
    try std.testing.expect(schedule.poll(stalled));
    try std.testing.expect(!schedule.poll(stalled));
    const next = 123 + 1001 * interval_ns;
    try std.testing.expectEqual(@as(?i128, next), schedule.nextDeadline());
    try std.testing.expect(!schedule.poll(next - 1));
    try std.testing.expect(schedule.poll(next));
}

test "skipPast prevents an immediate batch after work overruns" {
    var schedule: Schedule = .{};
    try std.testing.expect(schedule.poll(7));
    schedule.skipPast(7 + 3 * interval_ns + 25);
    try std.testing.expectEqual(@as(?i128, 7 + 4 * interval_ns), schedule.nextDeadline());
    try std.testing.expect(!schedule.poll(7 + 3 * interval_ns + 25));
    schedule.skipPast(7 + 4 * interval_ns);
    try std.testing.expect(!schedule.poll(7 + 4 * interval_ns));
    try std.testing.expectEqual(@as(?i128, 7 + 5 * interval_ns), schedule.nextDeadline());
    schedule.skipPast(7 + 4 * interval_ns + 1);
    try std.testing.expectEqual(@as(?i128, 7 + 5 * interval_ns), schedule.nextDeadline());
}

test "unstarted skip and backward observations reset without catch-up" {
    var schedule: Schedule = .{};
    schedule.skipPast(100);
    try std.testing.expect(!schedule.poll(100));
    try std.testing.expectEqual(@as(?i128, 100 + interval_ns), schedule.nextDeadline());
    try std.testing.expect(!schedule.poll(200));
    try std.testing.expect(schedule.poll(150));
    try std.testing.expectEqual(@as(?i128, 150 + interval_ns), schedule.nextDeadline());
    schedule.skipPast(120);
    try std.testing.expect(!schedule.poll(120));
    try std.testing.expectEqual(@as(?i128, 120 + interval_ns), schedule.nextDeadline());
    schedule.skipPast(140);
    try std.testing.expect(schedule.poll(130));
    try std.testing.expectEqual(@as(?i128, 130 + interval_ns), schedule.nextDeadline());
}

test "i128 extremes exhaust until backward reset" {
    const min = std.math.minInt(i128);
    const max = std.math.maxInt(i128);
    var schedule: Schedule = .{};
    try std.testing.expect(schedule.poll(max));
    try std.testing.expectEqual(@as(?i128, null), schedule.nextDeadline());
    try std.testing.expect(!schedule.poll(max));
    schedule.skipPast(max);
    try std.testing.expect(!schedule.poll(max));
    try std.testing.expect(schedule.poll(min));
    try std.testing.expectEqual(@as(?i128, min + interval_ns), schedule.nextDeadline());
    try std.testing.expect(!schedule.poll(min));
    try std.testing.expect(schedule.poll(max));
    try std.testing.expect(!schedule.poll(max));
    schedule.skipPast(min);
    try std.testing.expect(!schedule.poll(min));
    try std.testing.expectEqual(@as(?i128, min + interval_ns), schedule.nextDeadline());
}

test "widely separated timestamps preserve phase without subtraction overflow" {
    const min = std.math.minInt(i128);
    const max = std.math.maxInt(i128);
    var schedule: Schedule = .{};
    try std.testing.expect(schedule.poll(min));
    const now = max - 2 * interval_ns;
    try std.testing.expect(schedule.poll(now));
    const next = schedule.nextDeadline().?;
    try std.testing.expect(next > now);
    try std.testing.expect(next - now <= interval_ns);
    try std.testing.expectEqual(@as(i256, 0), @mod(@as(i256, next) - min, interval_ns));
    try std.testing.expect(!schedule.poll(now));
    schedule.skipPast(max);
    try std.testing.expectEqual(@as(?i128, null), schedule.nextDeadline());
    try std.testing.expect(!schedule.poll(max));
}

test "last representable deadline can grant once before exhaustion" {
    const max = std.math.maxInt(i128);
    var schedule: Schedule = .{};
    try std.testing.expect(schedule.poll(max - interval_ns));
    try std.testing.expectEqual(@as(?i128, max), schedule.nextDeadline());
    try std.testing.expect(schedule.poll(max));
    try std.testing.expect(!schedule.poll(max));
    var skipped: Schedule = .{};
    skipped.skipPast(max);
    try std.testing.expect(!skipped.poll(max));
    skipped.skipPast(max - interval_ns);
    try std.testing.expectEqual(@as(?i128, max), skipped.nextDeadline());
    try std.testing.expect(!skipped.poll(max - interval_ns));
}
