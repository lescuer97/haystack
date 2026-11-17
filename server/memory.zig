//! Startup-reserved synchronized buddy allocator; no backing allocator retained.
const std = @import("std");
pub const default_ws_budget = 4 * 1024 * 1024;
pub const Lock = struct {
    value: std.atomic.Mutex = .unlocked,
    pub fn lock(self: *Lock) void {
        while (!self.value.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *Lock) void {
        self.value.unlock();
    }
};
pub const Buddy = struct {
    const min_order = 6;
    const none = std.math.maxInt(usize);
    const Node = struct { next: usize, prev: usize };
    region: []u8,
    tags: []i8,
    heads: [64]usize = @splat(none),
    max_order: usize,
    reserved: usize,
    used: usize = 0,
    high_water: usize = 0,
    exhaustions: usize = 0,
    allocation_calls: usize = 0,
    mutex: Lock = .{},
    pub fn init(region: []u8) !Buddy {
        if (region.len < 4096 or !std.math.isPowerOfTwo(region.len) or @intFromPtr(region.ptr) % region.len != 0) return error.InvalidBudget;
        const count = region.len >> min_order;
        const reserved_order = order(count, 1) orelse return error.InvalidBudget;
        var self = Buddy{ .region = region, .tags = @as([*]i8, @ptrCast(region.ptr))[0..count], .max_order = std.math.log2_int(usize, region.len), .reserved = @as(usize, 1) << @intCast(reserved_order) };
        @memset(self.tags, 0);
        for (reserved_order..self.max_order) |o| self.push(@as(usize, 1) << @intCast(o), o);
        self.tags[0] = @intCast(reserved_order + 1);
        return self;
    }
    fn order(len: usize, alignment: usize) ?usize {
        const n = @max(len, alignment, 1 << min_order);
        const rounded = std.math.ceilPowerOfTwo(usize, n) catch return null;
        return std.math.log2_int(usize, rounded);
    }
    fn node(self: *Buddy, offset: usize) *Node {
        return @ptrCast(@alignCast(self.region.ptr + offset));
    }
    fn push(self: *Buddy, offset: usize, o: usize) void {
        const head = self.heads[o];
        self.node(offset).* = .{ .next = head, .prev = none };
        if (head != none) self.node(head).prev = offset;
        self.heads[o] = offset;
        self.tags[offset >> min_order] = -@as(i8, @intCast(o + 1));
    }
    fn remove(self: *Buddy, offset: usize, o: usize) void {
        const n = self.node(offset).*;
        if (n.prev == none) self.heads[o] = n.next else self.node(n.prev).next = n.next;
        if (n.next != none) self.node(n.next).prev = n.prev;
        self.tags[offset >> min_order] = 0;
    }
    pub fn allocator(self: *Buddy) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *Buddy = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.allocation_calls += 1;
        const wanted = order(len, alignment.toByteUnits()) orelse {
            self.exhaustions += 1;
            return null;
        };
        var o = wanted;
        while (o <= self.max_order and self.heads[o] == none) : (o += 1) {}
        if (o > self.max_order) {
            self.exhaustions += 1;
            return null;
        }
        const offset = self.heads[o];
        self.remove(offset, o);
        while (o > wanted) {
            o -= 1;
            self.push(offset + (@as(usize, 1) << @intCast(o)), o);
        }
        self.tags[offset >> min_order] = @intCast(wanted + 1);
        self.used += @as(usize, 1) << @intCast(wanted);
        self.high_water = @max(self.high_water, self.used);
        return self.region.ptr + offset;
    }
    fn resize(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const self: *Buddy = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        const offset = @intFromPtr(memory.ptr) - @intFromPtr(self.region.ptr);
        const o: u6 = @intCast(self.tags[offset >> min_order] - 1);
        return new_len <= (@as(usize, 1) << o);
    }
    fn free(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *Buddy = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        var offset = @intFromPtr(memory.ptr) - @intFromPtr(self.region.ptr);
        const tag = self.tags[offset >> min_order];
        std.debug.assert(tag > 0 and offset >= self.reserved);
        var o: usize = @intCast(tag - 1);
        self.used -= @as(usize, 1) << @intCast(o);
        self.tags[offset >> min_order] = 0;
        while (o < self.max_order) {
            const buddy = offset ^ (@as(usize, 1) << @intCast(o));
            if (self.tags[buddy >> min_order] != -@as(i8, @intCast(o + 1))) break;
            self.remove(buddy, o);
            offset = @min(offset, buddy);
            o += 1;
        }
        self.push(offset, o);
    }
};
test "buddy alignment resize exhaustion full reclaim and concurrent churn" {
    const size = 65536;
    const region = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(size), size);
    defer std.testing.allocator.free(region);
    var pool = try Buddy.init(region);
    const a = pool.allocator();
    const b = try a.alignedAlloc(u8, .fromByteUnits(4096), 100);
    try std.testing.expect(@intFromPtr(b.ptr) % 4096 == 0);
    try std.testing.expect(a.resize(b, 3000));
    a.free(b.ptr[0..3000]);
    var blocks: [1024]?[]u8 = @splat(null);
    for (&blocks) |*block| block.* = a.alloc(u8, 64) catch break;
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, size));
    for (blocks) |block| if (block) |bytes| a.free(bytes);
    const Worker = struct {
        fn run(allocator: std.mem.Allocator) void {
            for (0..1000) |_| {
                var bytes = allocator.alloc(u8, 81) catch @panic("unexpected OOM");
                @memset(bytes, 42);
                bytes = allocator.realloc(bytes, 257) catch @panic("unexpected OOM");
                std.debug.assert(bytes[0] == 42);
                allocator.free(bytes);
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{a});
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(usize, 0), pool.used);
    try std.testing.expect(pool.exhaustions > 0);
    const half = try a.alloc(u8, size / 2);
    a.free(half);
}
