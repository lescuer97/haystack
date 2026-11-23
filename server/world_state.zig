//! Shared world bitmaps and a bounded FIFO cut replay history.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const world = shared.world;
const actions = @import("actions.zig");
const addresses = @import("chunk_address.zig");
const ChunkAddress = addresses.ChunkAddress;

pub const State = WorldState;

pub const WorldState = struct {
    pub const capacity = 512;
    pub const cache_base_capacity = 5184;
    pub const cache_overflow_capacity = 512;
    pub const cache_capacity = cache_base_capacity + cache_overflow_capacity;
    pub const Chunk = struct { address: ChunkAddress, cuts: [32]u8 };
    pub const Replay = struct { id: p.Id, tile: p.Location, result: p.Outcome(.cut) };
    pub const DirtySnapshot = struct {
        address: ChunkAddress,
        bits: [32]u8,
        revision: u64,
        save_token: u64,
    };

    chunks: [capacity]Chunk = undefined,
    replays: [capacity]Replay = undefined,
    chunk_count: usize = 0,
    replay_count: usize = 0,
    replay_next: usize = 0,
    cache: ?Cache = null,

    /// Allocates all persistent cache storage without installing any rows.
    /// The caller serializes state operations; this state does not perform I/O.
    pub fn initPersistent(allocator: std.mem.Allocator) !WorldState {
        return .{ .cache = try Cache.init(allocator) };
    }

    /// The caller must finish I/O and flush pending dirty rows before teardown.
    pub fn deinit(self: *WorldState, allocator: std.mem.Allocator) void {
        if (self.cache) |*cache| {
            cache.index.deinit(allocator);
            allocator.free(cache.rows);
        }
        self.* = .{};
    }

    /// Pins an existing row. A miss acquires no pin.
    pub fn pin(self: *WorldState, address: ChunkAddress) bool {
        const cache = if (self.cache) |*cache| cache else return false;
        const i = cache.index.get(address) orelse return false;
        cache.rows[i].pins += 1;
        cache.eligible.unset(i);
        return true;
    }

    /// Releases one pin obtained by a successful pin or installPinned call.
    pub fn unpin(self: *WorldState, address: ChunkAddress) void {
        const cache = if (self.cache) |*cache| cache else return;
        const i = cache.index.get(address).?;
        cache.rows[i].pins -= 1;
        if (cache.rows[i].canEvict()) cache.eligible.set(i);
    }

    pub fn hasTrimmableOverflow(self: *const WorldState) bool {
        if (self.chunk_count <= cache_base_capacity) return false;
        const cache = if (self.cache) |*cache| cache else return false;
        return cache.eligible.findFirstSet() != null;
    }

    /// Call off tick after releasing a batch of pins or acknowledging writes.
    pub fn trimOverflow(self: *WorldState, players: []const p.Location) void {
        const cache = if (self.cache) |*cache| cache else return;
        if (self.chunk_count <= cache_base_capacity) return;
        var scratch: [cache_overflow_capacity]Cache.Candidate = undefined;
        const victims = cache.pickVictims(scratch[0 .. self.chunk_count - cache_base_capacity], players);
        for (victims) |victim| cache.remove(victim.slot);
        self.chunk_count -= victims.len;
    }

    /// Installs a loaded bitmap (including zeros) with one pin, or pins a row
    /// that another load already installed without replacing its contents.
    /// At base capacity or above, evicts an eligible row before using overflow.
    /// False means no pin was acquired. Only available in persistent mode.
    /// Coalesce same-address misses if loading outside the guard: a delayed
    /// read cannot be reconciled once the row it raced with has been evicted.
    pub fn installPinned(self: *WorldState, address: ChunkAddress, bits: [32]u8, players: []const p.Location) bool {
        const cache = if (self.cache) |*cache| cache else return false;
        if (self.pin(address)) return true;
        const i = slot: {
            if (self.chunk_count >= cache_base_capacity) {
                var scratch: [1]Cache.Candidate = undefined;
                if (cache.pickVictims(&scratch, players).len != 0) {
                    const victim = scratch[0].slot;
                    cache.remove(victim);
                    break :slot victim;
                }
            }
            const vacant = cache.vacant.findFirstSet() orelse return false;
            self.chunk_count += 1;
            break :slot vacant;
        };
        cache.vacant.unset(i);
        cache.end = @max(cache.end, i + 1);
        cache.rows[i] = .{ .chunk = .{ .address = address, .cuts = bits }, .pins = 1 };
        cache.index.putAssumeCapacityNoClobber(address, i);
        return true;
    }

    /// Starts a save and returns a detached copy of the dirty row. Start cursor
    /// at zero each pass. Edits behind the cursor are picked up on the next pass.
    /// Every returned snapshot must be finished with markSaved or markSaveFailed.
    pub fn nextDirty(self: *WorldState, cursor: *usize) ?DirtySnapshot {
        const cache = if (self.cache) |*cache| cache else return null;
        while (cursor.* < cache.end) {
            const i = cursor.*;
            cursor.* += 1;
            if (cache.vacant.isSet(i)) continue;
            const row = &cache.rows[i];
            if (!row.dirty or row.save_token != 0) continue;
            row.save_token = cache.nextGeneration();
            return .{
                .address = row.chunk.address,
                .bits = row.chunk.cuts,
                .revision = row.revision,
                .save_token = row.save_token,
            };
        }
        return null;
    }

    /// Finishes a successful write. Returns true only if this write made the
    /// current row clean; a newer edit remains dirty and can be saved again.
    pub fn markSaved(self: *WorldState, snapshot: DirtySnapshot) bool {
        const cache = if (self.cache) |*cache| cache else return false;
        const i = cache.finishSave(snapshot) orelse return false;
        const row = &cache.rows[i];
        if (row.revision != snapshot.revision or !std.mem.eql(u8, &row.chunk.cuts, &snapshot.bits)) return false;
        row.dirty = false;
        if (row.canEvict()) cache.eligible.set(i);
        return true;
    }

    /// Releases a failed save claim without marking the row clean.
    pub fn markSaveFailed(self: *WorldState, snapshot: DirtySnapshot) void {
        if (self.cache) |*cache| _ = cache.finishSave(snapshot);
    }

    fn findChunk(self: *const WorldState, address: ChunkAddress) ?usize {
        for (self.chunks[0..self.chunk_count], 0..) |chunk, i| {
            if (chunk.address == address) return i;
        }
        return null;
    }

    /// Check replay/conflict before loading or pinning the target chunk.
    pub fn replayCut(self: *const WorldState, req: p.RequestFor(.cut)) ?p.Outcome(.cut) {
        const tile = req.payload;
        if (tile.payment != null) return null;
        for (self.replays[0..self.replay_count]) |entry| {
            if (!std.mem.eql(u8, &entry.id, &req.request_id)) continue;
            if (entry.tile.x != tile.x or entry.tile.y != tile.y)
                return .{ .failed = .request_id_conflict };
            return entry.result;
        }
        return null;
    }

    pub fn cut(self: *WorldState, req: p.RequestFor(.cut)) error{CapacityExceeded}!p.Outcome(.cut) {
        if (req.payload.payment != null) return .{ .failed = .invalid_request };
        if (self.replayCut(req)) |result| return result;
        const tile = req.payload;
        const address = ChunkAddress.fromTile(tile.x, tile.y);
        const cache = if (self.cache) |*cache| cache else null;
        const row = if (cache) |c| c.get(address) orelse return error.CapacityExceeded else null;
        if (row) |r| if (r.pins == 0) return error.CapacityExceeded;
        const index = if (cache == null) self.findChunk(address) else null;
        const chunk = if (row) |r| &r.chunk else if (index) |i| &self.chunks[i] else null;
        const bit = CutBit.init(tile);
        const already = if (chunk) |c| bit.isSet(c) else false;
        const result = actions.cutRule(.{ .x = tile.x, .y = tile.y, .terrain = world.sampleTile(world.public_seed, tile.x, tile.y), .cut = already });
        if (result == .ok) {
            const target = chunk orelse new: {
                if (self.chunk_count == capacity) return error.CapacityExceeded;
                const fresh = &self.chunks[self.chunk_count];
                fresh.* = .{ .address = address, .cuts = @splat(0) };
                self.chunk_count += 1;
                break :new fresh;
            };
            if (row) |r| cache.?.markCut(r, bit) else bit.set(target);
        }
        self.replays[self.replay_next] = .{ .id = req.request_id, .tile = .{ .x = tile.x, .y = tile.y }, .result = result };
        self.replay_next = (self.replay_next + 1) % capacity;
        if (self.replay_count < capacity) self.replay_count += 1;
        return result;
    }

    const CutBit = struct {
        byte: usize,
        mask: u8,

        fn init(tile: p.Cut) CutBit {
            const bit: usize = @intCast(@mod(tile.y, 16) * 16 + @mod(tile.x, 16));
            return .{ .byte = bit / 8, .mask = @as(u8, 1) << @as(u3, @intCast(bit % 8)) };
        }

        fn isSet(self: CutBit, chunk: *const Chunk) bool {
            return chunk.cuts[self.byte] & self.mask != 0;
        }

        fn set(self: CutBit, chunk: *Chunk) void {
            chunk.cuts[self.byte] |= self.mask;
        }
    };

    const PreparedHoeCut = struct {
        cache: *Cache,
        row: *Cache.Row,
        bit: CutBit,
        result: p.State,

        /// Apply under the same world lock and pin used to prepare.
        pub fn apply(self: PreparedHoeCut) p.State {
            self.cache.markCut(self.row, self.bit);
            return self.result;
        }
    };

    /// No global request-ID lookup: the authoritative bitmap determines whether
    /// the pinned grass tile can be cut, and the ledger authorizes the payment.
    pub fn prepareHoeCut(self: *WorldState, tile: p.Cut) union(enum) { ready: PreparedHoeCut, failed: p.CutFailure } {
        const cache = if (self.cache) |*cache| cache else return .{ .failed = .server_busy };
        const row = cache.get(ChunkAddress.fromTile(tile.x, tile.y)) orelse return .{ .failed = .server_busy };
        if (row.pins == 0) return .{ .failed = .server_busy };
        const terrain = world.sampleTile(world.public_seed, tile.x, tile.y);
        if (terrain != .grass) return .{ .failed = .not_cuttable };
        const bit = CutBit.init(tile);
        const result = actions.cutRule(.{ .x = tile.x, .y = tile.y, .terrain = terrain, .cut = bit.isSet(&row.chunk) });
        return switch (result) {
            .ok => |next| .{ .ready = .{ .cache = cache, .row = row, .bit = bit, .result = next } },
            .failed => |failure| .{ .failed = failure },
        };
    }

    pub fn readArea(self: *const WorldState, area: world.ChunkRange, out: *p.Snapshot) error{InvalidArea}!void {
        const geometry = p.areaGeometry(area) catch return error.InvalidArea;
        out.* = .{ .area = area, .count = geometry.count };
        var iter = addresses.AreaIterator.init(area, geometry);
        for (out.chunks[0..geometry.count]) |*bits| {
            const address = iter.next().?;
            if (self.cache) |*cache| {
                if (cache.index.get(address)) |i| bits.* = cache.rows[i].chunk.cuts;
            } else if (self.findChunk(address)) |i| bits.* = self.chunks[i].cuts;
        }
    }

    const Cache = struct {
        const Index = std.AutoHashMapUnmanaged(ChunkAddress, usize);
        const Row = struct {
            chunk: Chunk,
            pins: usize = 0,
            dirty: bool = false,
            revision: u64 = 0,
            save_token: u64 = 0,

            fn canEvict(self: *const Row) bool {
                return self.pins == 0 and !self.dirty and self.save_token == 0;
            }
        };
        const Candidate = struct {
            slot: usize,
            distance: u64,

            fn order(_: void, a: Candidate, b: Candidate) std.math.Order {
                // Keep the least desirable victim at the head; ties favor earlier slots.
                return if (a.distance == b.distance) std.math.order(b.slot, a.slot) else std.math.order(a.distance, b.distance);
            }
        };

        index: Index = .empty,
        rows: []Row,
        // Holes let us drain overflow without moving live rows or disturbing save cursors.
        vacant: std.StaticBitSet(cache_capacity) = .full,
        eligible: std.StaticBitSet(cache_capacity) = .empty,
        end: usize = 0,
        generation: u64 = 0,
        evictions_since_rehash: usize = 0,

        fn init(allocator: std.mem.Allocator) !Cache {
            var cache: Cache = .{ .rows = try allocator.alloc(Row, cache_capacity) };
            errdefer allocator.free(cache.rows);
            try cache.index.ensureTotalCapacity(allocator, cache_capacity);
            return cache;
        }

        fn get(self: *Cache, address: ChunkAddress) ?*Row {
            return &self.rows[self.index.get(address) orelse return null];
        }

        fn markCut(self: *Cache, row: *Row, bit: CutBit) void {
            bit.set(&row.chunk);
            row.revision = self.nextGeneration();
            row.dirty = true;
        }

        fn finishSave(self: *Cache, snapshot: DirtySnapshot) ?usize {
            const i = self.index.get(snapshot.address) orelse return null;
            const row = &self.rows[i];
            if (snapshot.save_token == 0 or row.save_token != snapshot.save_token) return null;
            row.save_token = 0;
            return i;
        }

        fn nextGeneration(self: *Cache) u64 {
            self.generation += 1;
            return self.generation;
        }

        fn distanceSquared(chunk: ChunkAddress, player: ChunkAddress) u64 {
            const dx = @abs(@as(i64, chunk.cx) - player.cx);
            const dy = @abs(@as(i64, chunk.cy) - player.cy);
            return dx * dx + dy * dy;
        }

        fn pickVictims(self: *const Cache, scratch: []Candidate, players: []const p.Location) []const Candidate {
            // The registry supplies at most 64 active locations. Still consider
            // all players if another caller supplies a larger slice.
            var converted: [64]ChunkAddress = undefined;
            const player_chunks = converted[0..@min(converted.len, players.len)];
            for (player_chunks, players[0..player_chunks.len]) |*chunk, player| chunk.* = ChunkAddress.fromTile(player.x, player.y);

            // One eligible-set pass; keep just the farthest candidates in bounded scratch.
            var best: std.PriorityQueue(Candidate, void, Candidate.order) = .{ .items = scratch[0..0], .cap = scratch.len, .context = {} };
            var iter = self.eligible.iterator(.{});
            candidates: while (iter.next()) |i| {
                const cutoff = if (best.count() == scratch.len) best.peek() else null;
                if (cutoff != null and players.len == 0) break;
                const address = self.rows[i].chunk.address;
                var nearest: u64 = std.math.maxInt(u64);
                for (player_chunks) |player| {
                    nearest = @min(nearest, distanceSquared(address, player));
                    if (cutoff) |c| if (nearest <= c.distance) continue :candidates;
                }
                for (players[player_chunks.len..]) |player| {
                    nearest = @min(nearest, distanceSquared(address, ChunkAddress.fromTile(player.x, player.y)));
                    if (cutoff) |c| if (nearest <= c.distance) continue :candidates;
                }
                if (cutoff != null) _ = best.pop();
                best.push(.failing, .{ .slot = i, .distance = nearest }) catch unreachable;
            }
            return best.items;
        }

        fn remove(self: *Cache, i: usize) void {
            std.debug.assert(self.rows[i].canEvict());
            self.eligible.unset(i);
            self.vacant.set(i);
            const removed = self.index.remove(self.rows[i].chunk.address);
            std.debug.assert(removed);
            self.evictions_since_rehash += 1;
            // Bound tombstone buildup without allocating or moving any rows.
            if (self.evictions_since_rehash == self.index.capacity() / 8) {
                self.index.rehash(std.hash_map.AutoContext(ChunkAddress){});
                self.evictions_since_rehash = 0;
            }
        }
    };
};

pub fn request(id: u128, x: i32, y: i32) p.RequestFor(.cut) {
    var bytes: p.Id = undefined;
    std.mem.writeInt(u128, &bytes, id, .little);
    return .{ .request_id = bytes, .payload = .{ .x = x, .y = y } };
}
