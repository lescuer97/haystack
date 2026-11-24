//! One exclusively leased context, independent of callback thread affinity.
const std = @import("std");
const shared = @import("shared");
const p = shared.protocol;
const WorldState = @import("world_state.zig").WorldState;
const actions = @import("actions.zig");
const sessions = @import("sessions.zig");
const Persistence = @import("persistence.zig").Persistence;
const wallet_service = @import("native_storage").wallet_service;
const Wallet = wallet_service.Headless;
const hoe_log = std.log.scoped(.hoe_channels);

const hoe_refund_seconds = 7 * 24 * 60 * 60;
pub const default_budget = 64 * 1024;

pub const CommonFailure = enum { invalid_request, server_busy };

/// The caller supplies reply storage of at least p.max_response_bytes.
pub fn encodeCommonFailure(out: []u8, req: p.Request, failure: CommonFailure) []const u8 {
    return switch (req.operation) {
        inline else => |payload, kind| shared.wire.encodeReply(out, kind, .{
            .request_id = req.request_id,
            .payload = payload,
        }, .{ .failed = switch (failure) {
            .invalid_request => .invalid_request,
            .server_busy => .server_busy,
        } }) catch unreachable,
    };
}
pub const Context = struct {
    leased: bool = false,
    state: WorldState = .{},
    response: [p.max_response_bytes]u8 = undefined,
    snapshot: p.Snapshot = undefined,
    pub fn handle(self: *Context, comptime kind: p.Kind, req: p.RequestFor(kind), pubkey: sessions.Pubkey) []const u8 {
        const replays_before = self.state.replay_next;
        const outcome = switch (kind) {
            .cut => actions.handleCut(&self.state, req),
            .read_area => actions.handleReadArea(&self.state, &self.snapshot, req),
            else => @compileError("only cut and read_area use the world context"),
        };
        if (comptime std.log.logEnabled(.debug, .gameplay)) {
            const log = std.log.scoped(.gameplay);
            if (outcome == .ok) switch (kind) {
                // A cached success doesn't cut the tile again.
                .cut => if (self.state.replay_next != replays_before) {
                    log.debug("cut pubkey={s} tile=({d},{d})", .{ std.fmt.bytesToHex(pubkey, .lower), req.payload.x, req.payload.y });
                },
                .read_area => log.debug("read_area pubkey={s} chunks=({d},{d})..({d},{d})", .{
                    std.fmt.bytesToHex(pubkey, .lower),
                    req.payload.cx0,
                    req.payload.cy0,
                    req.payload.cx1,
                    req.payload.cy1,
                }),
                else => unreachable,
            };
        }
        return shared.wire.encodeReply(&self.response, kind, req, outcome) catch unreachable;
    }
};
pub const Layout = struct { context: Context, registry: sessions.Registry };
pub const App = struct {
    /// Borrowed from main. The wallet owner serializes receiver operations.
    wallet: ?*Wallet = null,
    persistence: ?*Persistence = null,
    context: *Context,
    registry: *sessions.Registry,
    pub fn init(io: std.Io, buffers: []align(@alignOf(Layout)) u8) !App {
        if (buffers.len < @sizeOf(Layout)) return error.InsufficientApplicationBudget;
        const layout: *Layout = @ptrCast(buffers.ptr);
        layout.registry = .{ .io = io };
        const context = &layout.context;
        context.* = .{};
        return .{ .context = context, .registry = &layout.registry };
    }
    pub fn deinit(self: *App) void {
        // The server drains callbacks before destroying the application.
        self.registry.clearSlots();
    }
    fn unixSeconds(self: *const App) ?u64 {
        return std.math.cast(u64, std.Io.Clock.real.now(self.registry.io).toSeconds());
    }
    pub fn authOutcome(self: *App, handle: sessions.Handle) p.AuthOutcome {
        const session = self.registry.get(handle) orelse return .{ .failed = .unavailable };
        const plain: p.AuthOutcome = .{ .ok = session.location.? };
        const location = plain.ok;
        for (p.tools) |tool| {
            if (session.channelId(tool) != null) break;
        } else return plain;
        const unavailable: p.AuthOutcome = .{ .failed = .unavailable };
        const wallet = self.wallet orelse return unavailable;
        // Login must not wait behind mint I/O or silently drop an unresolved link.
        const channels = wallet.tryAcquire() orelse return unavailable;
        defer channels.release();
        const now = self.unixSeconds() orelse return unavailable;
        var restored: p.ToolChannels = @splat(null);
        for (p.tools) |tool| {
            const id = session.channelId(tool) orelse continue;
            const loaded = (channels.loadLive(session.pubkey, id, now) catch |err| {
                hoe_log.debug("login ledger lookup failed: {s}", .{@errorName(err)});
                return unavailable;
            }) orelse continue;
            if (loaded.info.price_msat != tool.priceMsat()) {
                if (loaded.live) |live| live.deinit();
                return unavailable;
            }
            self.registry.setToolChannel(handle, tool, loaded.live);
            if (loaded.live == null and loaded.info.phase != .depleted) continue;
            restored[@backingInt(tool)] = .{
                .id = id,
                .capacity_msat = loaded.info.capacity_msat,
                .balance_msat = loaded.info.balance_msat,
            };
        }
        if (restored[@backingInt(p.tool.axe)] != null or restored[@backingInt(p.tool.pickaxe)] != null) {
            return .{ .ok_with_tool_channels = .{ .location = location, .channels = restored } };
        }
        const hoe = restored[@backingInt(p.tool.hoe)] orelse return plain;
        return .{ .ok_with_hoe_channel = .{
            .location = location,
            .hoe_channel_id = hoe.id,
            .hoe_channel_capacity_msat = hoe.capacity_msat,
            .hoe_channel_balance_msat = hoe.balance_msat,
        } };
    }
    pub fn channelRequirements(self: *const App, tool: p.tool) p.Outcome(.channel_requirements) {
        const unavailable: p.Outcome(.channel_requirements) = .{ .failed = .unavailable };
        const wallet = self.wallet orelse return unavailable;
        const receiver_key = wallet.receiverPubkey(hoe_refund_seconds) orelse return unavailable;
        const now = self.unixSeconds() orelse return unavailable;
        return .{ .ok = .{
            .pubkey = receiver_key,
            .amount = tool.priceMsat(),
            .refundTime = now + hoe_refund_seconds,
        } };
    }
    pub fn handleChannelOpen(self: *App, handle: sessions.Handle, open: p.SpillmanChannelOpen) std.Io.Cancelable!p.Outcome(.channel_open) {
        const unavailable: p.Outcome(.channel_open) = .{ .failed = .unavailable };
        const wallet = self.wallet orelse return unavailable;
        if (!wallet.hasReceiver()) return unavailable;
        const storage = self.persistence orelse return unavailable;

        const channels = wallet.tryAcquire() orelse return .{ .failed = .server_busy };
        defer channels.release();

        const profile = self.registry.storedUser(handle) catch return .{ .failed = .invalid_request };
        const previous = profile.user.channelId(open.tool);
        const now = self.unixSeconds() orelse return unavailable;
        if (previous) |id| {
            if (!std.mem.eql(u8, &id, &open.id)) {
                const info = channels.lookup(profile.pubkey, id, now) catch |err| {
                    hoe_log.debug("open profile lookup failed: {s}", .{@errorName(err)});
                    return unavailable;
                };
                if (info) |existing| switch (existing.phase) {
                    .depleted => return .{ .failed = .invalid_request },
                    .active, .closing_window => if (existing.remaining() >= open.tool.priceMsat()) return .{ .failed = .invalid_request },
                    .settlement_pending => if (now < existing.expiry) return .{ .failed = .invalid_request },
                    .settled => if (now < existing.expiry and !existing.wallet_redeemed) return .{ .failed = .invalid_request },
                    .expired, .sender_refund_required => {},
                };
            }
        }

        // The wire carries no independent sender binding; new admissions must
        // use the authenticated account's x-only sender key.
        channels.acceptToolFunded(profile.pubkey, .{
            .id = open.id,
            .params_json = open.params,
            .funding_proofs_json = open.proof,
        }, now, open.tool) catch |err| switch (err) {
            error.InvalidChannelPayload,
            error.InvalidChannelParameters,
            error.InvalidChannelHex,
            error.InvalidChannelKey,
            error.InvalidChannelOwnerBinding,
            error.InvalidFundingProof,
            error.InactiveFundingKeyset,
            error.ChannelIdMismatch,
            error.ChannelIdConflict,
            error.ChannelNotActive,
            error.FundingNotUnspent,
            => return .{ .failed = .invalid_proof },
            error.SqliteBusy => return .{ .failed = .server_busy },
            else => {
                hoe_log.debug("funded open failed: {s}", .{@errorName(err)});
                return unavailable;
            },
        };

        const loaded = (channels.loadLive(profile.pubkey, open.id, now) catch return unavailable) orelse return unavailable;
        var transferred = false;
        defer if (!transferred) if (loaded.live) |live| live.deinit();
        storage.linkToolChannel(handle, open.tool, previous, open.id) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (err == error.ChannelLinkedToDifferentTool) return .{ .failed = .invalid_request };
            // The verified ledger entry stays intact. Retrying the same open
            // resumes the link without contacting the mint again.
            hoe_log.debug("open profile link failed: {s}", .{@errorName(err)});
            return unavailable;
        };
        self.registry.setToolChannel(handle, open.tool, loaded.live);
        transferred = true;
        return .{ .ok = {} };
    }
    /// The handler calls this only after authentication. Authorize against the
    /// ledger, not a profile link that may have been replaced since expiry.
    pub fn handleChannelClose(self: *App, handle: sessions.Handle, close: p.SpillmanChannelClosing) p.Outcome(.channel_close) {
        const unavailable: p.Outcome(.channel_close) = .{ .failed = .unavailable };
        const wallet = self.wallet orelse return unavailable;
        if (!wallet.hasReceiver()) return unavailable;
        const session = self.registry.get(handle) orelse return .{ .failed = .invalid_request };
        const channels = wallet.tryAcquire() orelse return .{ .failed = .server_busy };
        defer channels.release();
        const now = self.unixSeconds() orelse return unavailable;
        const closed = channels.closeChannel(session.pubkey, close, now) catch |err| return switch (err) {
            error.ChannelNotFound, error.ChannelNotDepleted, error.ChannelCloseBalanceMismatch => .{ .failed = .close_rejected },
            error.SqliteBusy => .{ .failed = .server_busy },
            else => blk: {
                hoe_log.debug("close failed: {s}", .{@errorName(err)});
                break :blk unavailable;
            },
        };
        for (p.tools) |tool| {
            const live = self.registry.toolChannel(handle, tool) orelse continue;
            if (std.mem.eql(u8, &live.id, &close.id)) self.registry.setToolChannel(handle, tool, null);
        }
        if (closed == .pending) return .{ .failed = .settlement_pending };
        if (closed == .newly_settled) self.registry.notifySettlement(session.pubkey, close.id);
        return .ok;
    }

    pub fn handleChannelStatus(self: *App, handle: sessions.Handle, request: p.ChannelStatusRequest, reply_allocator: std.mem.Allocator) p.Outcome(.channel_status) {
        const unavailable: p.Outcome(.channel_status) = .{ .failed = .unavailable };
        const wallet = self.wallet orelse return unavailable;
        if (!wallet.hasReceiver()) return unavailable;
        const session = self.registry.get(handle) orelse return .{ .failed = .invalid_request };
        const channels = wallet.tryAcquire() orelse return .{ .failed = .server_busy };
        defer channels.release();
        const now = self.unixSeconds() orelse return unavailable;
        const info = (channels.lookup(session.pubkey, request.id, now) catch |err| {
            hoe_log.debug("status lookup failed: {s}", .{@errorName(err)});
            return if (err == error.SqliteBusy) .{ .failed = .server_busy } else unavailable;
        }) orelse return .{ .failed = .not_found };
        const phase: p.ChannelPhase = switch (info.phase) {
            .active => if (info.remaining() < info.price_msat) .settlement_pending else .active,
            .depleted => .depleted,
            .closing_window, .expired => if (info.balance_msat == 0) .sender_refund_required else .settlement_pending,
            .settlement_pending => .settlement_pending,
            .settled => if (info.wallet_redeemed) .settled else .settlement_pending,
            .sender_refund_required => .sender_refund_required,
        };
        return .{ .ok = .{
            .capacity_msat = info.capacity_msat,
            .balance_msat = info.balance_msat,
            .phase = phase,
            .sender_proofs = if (phase == .settled) channels.senderProofs(session.pubkey, request.id, reply_allocator, p.max_sender_change_proofs_bytes) catch |err| {
                hoe_log.debug("status receipt lookup failed: {s}", .{@errorName(err)});
                return unavailable;
            } else null,
        } };
    }
    pub fn handleLocation(self: *App, handle: sessions.Handle, req: p.RequestFor(.update_location)) p.Outcome(.update_location) {
        self.registry.update(handle, req.payload) catch |err| {
            if (err != error.BlockedMovement) return .{ .failed = .invalid_request };
            const from = (self.registry.get(handle) orelse return .{ .failed = .invalid_request }).location.?;
            if (!shared.movement.canStepWith(from, req.payload, shared.movement.AllCleared{})) return .{ .failed = .invalid_request };
            const context = self.lease() orelse return .{ .failed = .server_busy };
            defer self.release(context);
            self.registry.updateWithWorld(handle, req.payload, &context.state) catch return .{ .failed = .invalid_request };
        };
        return .{ .ok = {} };
    }
    fn hasReceiver(self: *const App) bool {
        return if (self.wallet) |wallet| wallet.hasReceiver() else false;
    }
    pub fn requiresPaidCut(self: *const App, tile: p.Cut) bool {
        const world = shared.world;
        if (tile.payment != null or tile.tool != .hoe) return true;
        return switch (world.sampleTile(world.public_seed, tile.x, tile.y)) {
            .tree, .rock => true,
            .grass => self.hasReceiver(),
            .dirt, .water => false,
        };
    }

    /// Run on the connection task, which owns the confirmed session and has
    /// no other gameplay request in flight for it.
    pub fn handlePaidCut(self: *App, handle: sessions.Handle, req: p.Request) std.Io.Cancelable!p.Outcome(.cut) {
        const invalid: p.Outcome(.cut) = .{ .failed = .invalid_request };
        const busy: p.Outcome(.cut) = .{ .failed = .server_busy };
        const tile = req.operation.cut;
        const payment = tile.payment orelse return invalid;
        const wallet = self.wallet orelse return invalid;
        if (!wallet.hasReceiver()) return invalid;
        const storage = self.persistence orelse return invalid;
        const profile = self.registry.storedUser(handle) catch return invalid;
        const location = profile.user.location;
        if (@abs(@as(i64, tile.x) - location.x) > 1 or @abs(@as(i64, tile.y) - location.y) > 1) return invalid;
        var pins = storage.prepare(req) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return busy;
        };
        defer storage.release(&pins);

        // Don't wait behind mint I/O in open/settlement or behind a world cut.
        const channels = wallet.tryAcquire() orelse return busy;
        defer channels.release();
        const context = self.lease() orelse return busy;
        defer self.release(context);

        const prepared = switch (context.state.prepareToolCut(tile)) {
            .ready => |ready| ready,
            .failed => |failure| return .{ .failed = failure },
        };
        const live = self.registry.toolChannel(handle, tile.tool) orelse return invalid;
        if (!std.mem.eql(u8, &live.id, &payment.id)) return invalid;
        const now = self.unixSeconds() orelse return busy;
        try self.registry.io.checkCancel();
        channels.acceptPayment(live, .{
            .balance_msat = payment.amount,
            .signature = payment.signature,
        }, now) catch |err| switch (err) {
            error.ChannelNotFound,
            error.ChannelNotActive,
            error.InvalidPaymentStep,
            error.InvalidPaymentSignature,
            => return invalid,
            else => {
                hoe_log.debug("cut payment failed: {s}", .{@errorName(err)});
                return busy;
            },
        };
        // The row is still pinned and exclusively leased. No I/O, allocation,
        // replay lookup or cancellation point before marking the bitmap dirty.
        const tile_state = prepared.apply();
        if (live.exhausted()) self.registry.setToolChannel(handle, tile.tool, null);
        return .{ .ok = tile_state };
    }

    pub fn retainedCut(self: *App, req: p.Request) !?p.Outcome(.cut) {
        const storage = self.persistence orelse return null;
        const tile = switch (req.operation) {
            .cut => |tile| tile,
            else => return null,
        };
        if (self.requiresPaidCut(tile)) return null;
        try storage.world_lock.lock(storage.io);
        defer storage.world_lock.unlock(storage.io);
        return self.context.state.replayCut(.{ .request_id = req.request_id, .payload = tile });
    }
    pub fn lease(self: *App) ?*Context {
        const context = self.context;
        if (@cmpxchgStrong(bool, &context.leased, false, true, .acquire, .monotonic) != null) return null;
        if (self.persistence) |storage| {
            // Cache maintenance never makes the tick wait, even without disk I/O.
            if (!storage.world_lock.tryLock()) {
                @atomicStore(bool, &context.leased, false, .release);
                return null;
            }
        }
        return context;
    }
    pub fn release(self: *App, context: *Context) void {
        if (self.persistence) |storage| storage.world_lock.unlock(storage.io);
        @atomicStore(bool, &context.leased, false, .release);
    }
};
