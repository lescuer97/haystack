const std = @import("std");

// Socket-free deterministic thread scheduling; never used by production code.
pub const Gate = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    arrived: bool = false,
    released: bool = false,

    pub fn notify(self: *Gate) void {
        const io = std.testing.io;
        self.mutex.lockUncancelable(io);
        self.arrived = true;
        self.mutex.unlock(io);
        self.condition.broadcast(io);
    }

    pub fn waitArrived(self: *Gate) void {
        const io = std.testing.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.arrived) self.condition.waitUncancelable(io, &self.mutex);
    }

    pub fn arriveAndWait(self: *Gate) void {
        self.notify();
        const io = std.testing.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.released) self.condition.waitUncancelable(io, &self.mutex);
    }

    pub fn release(self: *Gate) void {
        const io = std.testing.io;
        self.mutex.lockUncancelable(io);
        self.released = true;
        self.mutex.unlock(io);
        self.condition.broadcast(io);
    }
};
