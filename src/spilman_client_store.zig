//! Desktop adapter to upstream Spilman client storage. The wallet instance
//! lock must be held, and all calls for the same wallet must be serialized.
const std = @import("std");
const protocol = @import("shared").protocol;
const sf = @import("storage_fs.zig");
const cdk = @import("cdk");
const c = cdk.c;
const slice = cdk.byteSlice;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const eql = std.mem.eql;

pub const filename = "spilman.sqlite";
pub const legacy_journal_dir = "spilman-journal";
pub const legacy_channels_dir = "hoe-channels";
pub const legacy_pending_file = "hoe-wallet-pending";
pub const journal_namespace = "journal";
pub const wallet_namespace = "wallet";
pub const pending_key = "pending";
const lifecycle_namespace = "hoe-lifecycle";

pub const Db = struct {
    handle: *c.CdkSpilmanClientStorage_t,

    pub fn open(io: Io, root: []const u8) !Db {
        if (!std.fs.path.isAbsolute(root)) return error.InvalidPath;
        const dir = try sf.openOwnedDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        try checkLegacy(io, dir);

        for ([_][]const u8{ filename ++ "-journal", filename ++ "-wal", filename ++ "-shm" }) |sidecar| {
            _ = try verifyFile(io, dir, sidecar);
        }
        if (!try verifyFile(io, dir, filename)) {
            const file = try dir.createFile(io, filename, .{ .exclusive = true, .permissions = sf.mode_file });
            defer file.close(io);
            try sf.verifyFile(try file.stat(io));
            try sf.verifyNoExtendedAcl(file);
        }

        const a = std.heap.page_allocator;
        const real_root = try dir.realPathFileAlloc(io, ".", a);
        defer a.free(real_root);
        const path = try std.fmt.allocPrintSentinel(a, "{s}/" ++ filename, .{real_root}, 0);
        defer a.free(path);
        const result = c.cdk_spilman_client_storage_open(path);
        defer c.cdk_string_free(result.@"error");
        try check(result.status);
        const db: Db = .{ .handle = result.handle orelse return error.SpilmanDbFailure };
        errdefer db.close();
        try sf.syncDirectory(dir);
        return db;
    }

    pub fn close(self: Db) void {
        c.cdk_spilman_client_storage_close(self.handle);
    }

    pub fn read(self: Db, comptime T: type, a: Allocator, namespace: []const u8, id: []const u8, max_bytes: usize) !std.json.Parsed(T) {
        return parseRecord(T, a, c.cdk_spilman_client_storage_read_metadata(self.handle, slice(namespace), slice(id)), max_bytes);
    }

    pub fn put(self: Db, namespace: []const u8, id: []const u8, data: []const u8, replace: bool) !void {
        try status(c.cdk_spilman_client_storage_write_metadata(self.handle, slice(namespace), slice(id), slice(data), replace));
    }

    pub fn remove(self: Db, namespace: []const u8, id: []const u8) !void {
        try status(c.cdk_spilman_client_storage_remove_metadata(self.handle, slice(namespace), slice(id)));
    }

    pub fn list(self: Db, comptime Key: type, a: Allocator, namespace: []const u8) ![]Key {
        const result = c.cdk_spilman_client_storage_list_ids(self.handle, slice(namespace));
        defer freeBytes(result);
        try check(result.status);
        const data = byteResult(result);
        if (data.len % @sizeOf(Key) != 0) return error.InvalidSpilmanDatabase;
        const ids = try a.alloc(Key, data.len / @sizeOf(Key));
        @memcpy(std.mem.sliceAsBytes(ids), data);
        return ids;
    }
};

fn check(code: c.CdkStatus_t) !void {
    return switch (code) {
        c.CDK_STATUS_OK => {},
        c.CDK_STATUS_OPERATION_NOT_FOUND => error.FileNotFound,
        c.CDK_STATUS_ALREADY_OPEN => error.RecordAlreadyExists,
        c.CDK_STATUS_UNSUPPORTED_DATABASE => error.InvalidSpilmanDatabase,
        else => error.SpilmanDbFailure,
    };
}

fn status(result: c.CdkStatusResult_t) !void {
    defer c.cdk_string_free(result.@"error");
    try check(result.status);
}

fn freeBytes(result: c.CdkBytesResult_t) void {
    c.cdk_string_free(result.@"error");
    c.cdk_bytes_free(result.bytes);
}

fn byteResult(result: c.CdkBytesResult_t) []const u8 {
    return if (result.bytes.len == 0) &.{} else result.bytes.ptr[0..result.bytes.len];
}

fn parseRecord(comptime T: type, a: Allocator, result: c.CdkBytesResult_t, max_bytes: usize) !std.json.Parsed(T) {
    defer freeBytes(result);
    try check(result.status);
    const data = byteResult(result);
    if (data.len > max_bytes) return error.RecordTooLarge;
    return std.json.parseFromSlice(T, a, data, .{ .allocate = .alloc_always, .max_value_len = max_bytes });
}

fn verifyFile(io: Io, dir: Io.Dir, name: []const u8) !bool {
    const fd = std.posix.openat(dir.handle, name, .{
        .ACCMODE = .RDONLY,
        .NOFOLLOW = true,
        .CLOEXEC = true,
        .NONBLOCK = true,
    }, 0) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.SymLinkLoop => return error.InsecureEntry,
        else => return err,
    };
    const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    try sf.verifyFile(try file.stat(io));
    try sf.verifyNoExtendedAcl(file);
    return true;
}

// Old releases created these directories even for read-only use. Allow empty
// directories, but never silently pass over any legacy data (even staging files).
fn checkLegacy(io: Io, root: Io.Dir) !void {
    if (root.statFile(io, legacy_pending_file, .{ .follow_symlinks = false })) |_| {
        return error.LegacySpilmanRecords;
    } else |err| if (err != error.FileNotFound) return err;

    for ([_][]const u8{ legacy_journal_dir, legacy_channels_dir }) |name| {
        const dir = openLegacyDir(io, root, name) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            if (std.mem.eql(u8, name, legacy_journal_dir) or entry.kind != .directory) return error.LegacySpilmanRecords;
            const scope = try openLegacyDir(io, dir, entry.name);
            defer scope.close(io);
            var records = scope.iterate();
            if (try records.next(io) != null) return error.LegacySpilmanRecords;
        }
    }
}

fn openLegacyDir(io: Io, parent: Io.Dir, name: []const u8) !Io.Dir {
    const dir = sf.openChildDirSyncable(parent, io, name) catch |err| switch (err) {
        error.SymLinkLoop, error.NotDir => return error.LegacySpilmanRecords,
        else => return err,
    };
    errdefer dir.close(io);
    try sf.verifyDirectory(try dir.stat(io));
    try sf.verifyNoExtendedAclDir(dir);
    return dir;
}

/// Desktop write-ahead records for Spilman mint swaps. The journal never calls
/// a mint. Hold the desktop instance lock for the journal's
/// storage root and serialize access within the process (including recovery).
///
/// Only a successful `prepare` permits the caller to attempt the first external
/// call. Any record found after interruption is already potentially submitted:
/// for a mint swap, use recovery with the saved URL and request, not a repost.
/// Retire only after the outcome and any dependent local state are durable.
pub const Journal = struct {
    pub const Id = [16]u8;
    const version = 1;
    const max_payload_bytes = 1024 * 1024;
    const max_record_bytes = 6 * max_payload_bytes + 1024; // JSON escaping plus envelope

    pub const MintSwap = struct {
        kind: enum { funding, close, refund },
        mint_url: []const u8,
        request_json: []const u8,
        /// Caller-defined blob containing all completion inputs other than the
        /// mint response (e.g. funding secrets and the exact keyset info).
        completion_material: []const u8,
    };

    pub const Operation = struct {
        mint_swap: MintSwap,

        fn validate(self: Operation) !void {
            const swap = self.mint_swap;
            const parts = [_][]const u8{ swap.mint_url, swap.request_json, swap.completion_material };
            var remaining: usize = max_payload_bytes;
            for (parts) |part| {
                if (part.len == 0) return error.EmptyMaterial;
                if (part.len > remaining) return error.RecordTooLarge;
                remaining -= part.len;
            }
        }
    };

    pub const Record = struct {
        version: u32,
        id: Journal.Id,
        operation: Operation,
    };

    db: Db,

    /// `root` must be an already durable, private Haystack directory.
    pub fn open(io: Io, root: []const u8) !Journal {
        return .{ .db = try Db.open(io, root) };
    }

    pub fn close(self: Journal, _: Io) void {
        self.db.close();
    }

    /// Create an immutable pending record. AlreadyPending is not permission to
    /// attempt the call: even a previous sync error may have left a record.
    pub fn prepare(self: Journal, _: Io, allocator: Allocator, id: Journal.Id, operation: Operation) !void {
        try operation.validate();
        const data = try std.json.Stringify.valueAlloc(allocator, Journal.Record{
            .version = Journal.version,
            .id = id,
            .operation = operation,
        }, .{});
        defer {
            std.crypto.secureZero(u8, data);
            allocator.free(data);
        }
        if (data.len > Journal.max_record_bytes) return error.RecordTooLarge;
        self.db.put(journal_namespace, &id, data, false) catch |err| switch (err) {
            error.RecordAlreadyExists => return error.AlreadyPending,
            else => return err,
        };
    }

    /// Deinit the returned parse arena when done. Missing, malformed, insecure,
    /// and unsupported records are errors, not empty journal entries.
    pub fn read(self: Journal, _: Io, allocator: Allocator, id: Journal.Id) !std.json.Parsed(Journal.Record) {
        const record = try self.db.read(Journal.Record, allocator, journal_namespace, &id, Journal.max_record_bytes);
        errdefer record.deinit();
        if (record.value.version != Journal.version) return error.UnsupportedVersion;
        if (!std.mem.eql(u8, &record.value.id, &id)) return error.RecordIdMismatch;
        try record.value.operation.validate();
        return record;
    }

    /// List committed IDs. Call `read` to validate each record before use.
    pub fn list(self: Journal, _: Io, allocator: Allocator) ![]Journal.Id {
        return self.db.list(Journal.Id, allocator, journal_namespace);
    }

    /// Remove a resolved record; retrying an already retired ID is safe.
    pub fn retire(self: Journal, _: Io, id: Journal.Id) !void {
        return self.db.remove(journal_namespace, &id);
    }
};

pub const Id = [32]u8;
pub const Pubkey = [33]u8;
const version = 1;
const max_material_bytes = 1024 * 1024;
const max_record_bytes = 6 * max_material_bytes + 1024;

pub const Scope = struct {
    /// Stable, caller-canonicalized endpoint for the known server (including
    /// scheme, port and path as applicable), not a label from a reply. The
    /// funding journal does not establish the intended endpoint on recovery.
    server: []const u8,
    receiver: Pubkey,
    /// The recovered local sender key's true compressed public key.
    player: Pubkey,

    fn digest(self: Scope) ![32]u8 {
        if (self.server.len == 0 or std.mem.indexOfScalar(u8, self.server, 0) != null or
            !compressed(self.receiver) or !compressed(self.player) or
            eql(u8, self.receiver[1..], self.player[1..])) return error.InvalidScope;
        var hash = Sha256.init(.{});
        hash.update("haystack/hoe-channel-store/v1");
        hash.update(&self.receiver);
        hash.update(&self.player);
        hash.update(self.server);
        return hash.finalResult();
    }
};

/// The exact C strings returned by the verified funding adapter. For payment
/// signing, pass params, keyset and proofs to CDK with the rederived private
/// key matching `Scope.player`. `channel_secret_hex` is the shared channel
/// secret, not the sender signing key. No player private key is stored here.
pub const Funded = struct {
    operation_id: Journal.Id,
    id: Id,
    mint_url: [:0]const u8,
    capacity_msats: u64,
    refund_time: u64,
    channel_secret_hex: [:0]const u8,
    params_json: [:0]const u8,
    keyset_json: [:0]const u8,
    funding_proofs_json: [:0]const u8,
};

pub const Record = struct {
    version: u32,
    scope: [32]u8,
    channel: Funded,
};

pub const Lifecycle = struct {
    admitted: bool = false,
    /// New funding starts at zero; this records only what the client has confirmed.
    confirmed_balance_msats: u64 = 0,
    pending_cut: ?PendingCut = null,
    settlement: ?Settlement = null,

    /// A reservation, not a replayable request. No signature or tile is stored.
    pub const PendingCut = struct { request_id: protocol.Id, amount: u64 };

    pub const Settlement = struct {
        receipt_hash: Id,
        /// Null means a receive could have run. Never replay it or infer credit
        /// from spent inputs or a wallet-wide balance change.
        net_msats: ?u64,
        released: bool = false,
    };
};

const LifecycleRecord = struct {
    version: u32,
    scope: Id,
    state: Lifecycle,
};

pub const LocalChannel = struct {
    id: Id,
    capacity_msats: u64,
    refund_time: u64,
    state: Lifecycle,
};

/// Owns a SQLite connection. Records do not prove that the server opened
/// the channel or that it is still spendable. Check server state, expiry, and unresolved
/// payments before resuming signing; the local amount is not a server balance.
pub const Store = struct {
    db: Db,
    scope: [32]u8,
    receiver: Pubkey,
    player: Pubkey,

    /// `root` must be an existing, durable private Haystack directory.
    pub fn open(io: Io, root: []const u8, scope: Scope) !Store {
        const digest = try scope.digest();
        return .{ .db = try Db.open(io, root), .scope = digest, .receiver = scope.receiver, .player = scope.player };
    }

    pub fn close(self: Store, _: Io) void {
        self.db.close();
    }

    /// Pass only the verified result of `hoe_funding.fund` or `recover` for
    /// this known scope. This is not an admission API for untrusted input.
    /// A byte-identical retry is safe.
    pub fn saveFunded(self: Store, io: Io, a: Allocator, pending: Journal, verified: anytype) !void {
        const channel: Funded = .{
            .operation_id = verified.operation_id,
            .id = verified.id,
            .mint_url = verified.mint_url,
            .capacity_msats = verified.capacity_msats,
            .refund_time = verified.refund_time,
            .channel_secret_hex = verified.channel_secret_hex,
            .params_json = verified.params_json,
            .keyset_json = verified.keyset_json,
            .funding_proofs_json = verified.funding_proofs_json,
        };
        try self.validate(a, channel);
        // The journal is authoritative until the funded channel commits.
        // If it was already retired, the ABI allows only an identical retry.
        const entry = pending.read(io, a, channel.operation_id) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (entry) |saved| saved.deinit();
        const request = if (entry) |saved| request: {
            const swap = saved.value.operation.mint_swap;
            try matchFunding(a, swap, channel);
            break :request swap.request_json;
        } else "";
        const data = try std.json.Stringify.valueAlloc(a, Record{
            .version = version,
            .scope = self.scope,
            .channel = channel,
        }, .{});
        defer {
            std.crypto.secureZero(u8, data);
            a.free(data);
        }
        status(c.cdk_spilman_client_storage_save_funded(self.db.handle, slice(data), slice(request))) catch |err| switch (err) {
            error.RecordAlreadyExists => return error.ChannelConflict,
            else => return err,
        };
    }

    /// Caller owns the parse arena; call `deinit` when done. Treat errors
    /// other than FileNotFound as recovery failures, not as absent channels.
    pub fn read(self: Store, _: Io, a: Allocator, id: Id) !std.json.Parsed(Record) {
        const record = try parseRecord(Record, a, c.cdk_spilman_client_storage_read_funded(self.db.handle, slice(&self.scope), slice(&id)), max_record_bytes);
        errdefer record.deinit();
        if (record.value.version != version) return error.UnsupportedVersion;
        if (!eql(u8, &record.value.scope, &self.scope)) return error.ScopeMismatch;
        if (!eql(u8, &record.value.channel.id, &id)) return error.ChannelIdMismatch;
        try self.validate(a, record.value.channel);
        return record;
    }

    /// Enumerate channel IDs in this scope. Caller owns the slice.
    pub fn list(self: Store, _: Io, a: Allocator) ![]Id {
        return self.db.list(Id, a, &self.scope);
    }

    pub fn readLifecycle(self: Store, a: Allocator, id: Id) !Lifecycle {
        const record = self.db.read(LifecycleRecord, a, lifecycle_namespace, &id, 1024) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        defer record.deinit();
        if (record.value.version != version) return error.UnsupportedVersion;
        if (!eql(u8, &record.value.scope, &self.scope)) return error.ScopeMismatch;
        try validateLifecycle(record.value.state);
        return record.value.state;
    }

    // The caller has already checked that `id` belongs to this exact funded scope.
    pub fn writeLifecycle(self: Store, a: Allocator, id: Id, state: Lifecycle) !void {
        try validateLifecycle(state);
        const data = try std.json.Stringify.valueAlloc(a, LifecycleRecord{
            .version = version,
            .scope = self.scope,
            .state = state,
        }, .{});
        defer a.free(data);
        try self.db.put(lifecycle_namespace, &id, data, true);
    }

    fn validateLifecycle(state: Lifecycle) !void {
        if (!state.admitted and (state.confirmed_balance_msats != 0 or state.pending_cut != null or state.settlement != null)) return error.InvalidSpilmanDatabase;
        if (state.pending_cut) |pending| {
            if (pending.amount <= state.confirmed_balance_msats) return error.InvalidSpilmanDatabase;
        }
        if (state.settlement) |settled| {
            if (settled.released and (settled.net_msats == null or state.pending_cut != null)) return error.InvalidSpilmanDatabase;
        }
    }

    /// Discover the single unresolved funded record without assuming that the
    /// server admitted it or that a server login means it no longer exists.
    pub fn discover(self: Store, io: Io, a: Allocator) !?LocalChannel {
        const ids = try self.list(io, a);
        defer a.free(ids);
        var found: ?LocalChannel = null;
        for (ids) |id| {
            const state = try self.readLifecycle(a, id);
            if (state.settlement != null and state.settlement.?.released) continue;
            if (found != null) return error.MultipleUnresolvedChannels;
            const saved = try self.read(io, a, id);
            defer saved.deinit();
            found = .{
                .id = id,
                .capacity_msats = saved.value.channel.capacity_msats,
                .refund_time = saved.value.channel.refund_time,
                .state = state,
            };
        }
        return found;
    }

    /// Call only AFTER the separate CDK pending send is durably reconciled.
    /// An absent journal entry is allowed on retry, but a missing, corrupt,
    /// or non-durable channel entry never authorizes retiring the journal.
    pub fn retireFundingAfterWalletRecovery(self: Store, io: Io, a: Allocator, pending: Journal, id: Id) !void {
        const saved = try self.read(io, a, id);
        defer saved.deinit();
        const channel = saved.value.channel;
        const entry = pending.read(io, a, channel.operation_id) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer entry.deinit();
        try matchFunding(a, entry.value.operation.mint_swap, channel);
        try pending.retire(io, channel.operation_id);
    }

    fn validate(self: Store, a: Allocator, channel: Funded) !void {
        const fields = [_][]const u8{ channel.mint_url, channel.channel_secret_hex, channel.params_json, channel.keyset_json, channel.funding_proofs_json };
        var remaining: usize = max_material_bytes;
        for (fields) |field| {
            if (field.len > remaining) return error.RecordTooLarge;
            if (field.len == 0 or std.mem.indexOfScalar(u8, field, 0) != null or !std.unicode.utf8ValidateSlice(field)) return error.InvalidMaterial;
            remaining -= field.len;
        }
        if (channel.capacity_msats == 0 or channel.refund_time == 0 or channel.channel_secret_hex.len != 64) return error.InvalidMaterial;
        for (channel.channel_secret_hex) |byte| if (!std.ascii.isHex(byte)) return error.InvalidMaterial;
        // Parse only the cross-checks; never reserialize the nested JSON.
        const parsed = try std.json.parseFromSlice(struct {
            sender_pubkey: []const u8,
            receiver_pubkey: []const u8,
            mint: []const u8,
            unit: []const u8,
            capacity: u64,
            expiry_timestamp: u64,
        }, a, channel.params_json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const p = parsed.value;
        if (!matchesKey(p.sender_pubkey, self.player) or !matchesKey(p.receiver_pubkey, self.receiver)) return error.ScopeMismatch;
        if (!eql(u8, p.mint, channel.mint_url) or !eql(u8, p.unit, "msat") or
            p.capacity != channel.capacity_msats or p.expiry_timestamp != channel.refund_time) return error.InvalidMaterial;
        try validateJson(a, channel.keyset_json, '{');
        try validateJson(a, channel.funding_proofs_json, '[');
    }
};

fn validateJson(a: Allocator, json: []const u8, opening: u8) !void {
    const trimmed = std.mem.trimStart(u8, json, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != opening or !try std.json.validate(a, json)) return error.InvalidMaterial;
}

fn compressed(key: Pubkey) bool {
    return key[0] == 2 or key[0] == 3;
}

fn matchesKey(hex: []const u8, key: Pubkey) bool {
    var decoded: Pubkey = undefined;
    if (hex.len != 2 * key.len) return false;
    _ = std.fmt.hexToBytes(&decoded, hex) catch return false;
    return eql(u8, &decoded, &key);
}

test "funded channel discovery persists admission and holds settlement until release" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "wallet", sf.mode_dir);
    const root = try tmp.dir.realPathFileAlloc(t.io, "wallet", t.allocator);
    defer t.allocator.free(root);
    const mint = "https://mint.example";
    const sender = "034f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa";
    const receiver = "02466d7fcae563e5cb09a0d1870bb580344804617879a14949cf22285f1bae3f27";
    const keys =
        \\{"keyset_id":"00891271bfa74eb8","unit":"msat","input_fee_ppk":0,"keys":{"32":"03d30199d74fb5a22d47b6e054e2f378cedacffcb89904a61d75d0dbd407143e65"}}
    ;
    const params = "{\"sender_pubkey\":\"" ++ sender ++ "\",\"receiver_pubkey\":\"" ++ receiver ++ "\",\"mint\":\"" ++ mint ++
        "\",\"unit\":\"msat\",\"capacity\":32,\"expiry_timestamp\":4000000000,\"setup_timestamp\":1," ++
        "\"funding_token_amount\":32,\"maximum_amount\":32,\"keyset_id\":\"00891271bfa74eb8\",\"input_fee_ppk\":0}";
    const secret = "abababababababababababababababababababababababababababababababab";
    const result = c.cdk_spilman_channel_parameters_get_channel_id(params, secret, keys);
    defer c.cdk_string_free(result.@"error");
    defer c.cdk_string_free(result.value);
    try check(result.status);
    var id: Id = undefined;
    _ = try std.fmt.hexToBytes(&id, std.mem.span(result.value));
    var scope: Scope = .{ .server = "ws://first/", .player = undefined, .receiver = undefined };
    _ = try std.fmt.hexToBytes(&scope.player, sender);
    _ = try std.fmt.hexToBytes(&scope.receiver, receiver);
    {
        const store = try Store.open(t.io, root, scope);
        defer store.close(t.io);
        const data = try std.json.Stringify.valueAlloc(t.allocator, Record{
            .version = version,
            .scope = store.scope,
            .channel = .{
                .operation_id = @splat(3),
                .id = id,
                .mint_url = mint,
                .capacity_msats = 32,
                .refund_time = 4_000_000_000,
                .channel_secret_hex = secret,
                .params_json = params,
                .keyset_json = keys,
                .funding_proofs_json = "[]",
            },
        }, .{});
        defer t.allocator.free(data);
        try status(c.cdk_spilman_client_storage_save_funded(store.db.handle, slice(data), slice("{\"inputs\":[]}")));
        const local = (try store.discover(t.io, t.allocator)).?;
        try t.expectEqual(id, local.id);
        try t.expectEqual(32, local.capacity_msats);
        try t.expect(!local.state.admitted);
        try t.expectEqual(@as(u64, 0), local.state.confirmed_balance_msats);
        // Pre-cut-balance lifecycle records still load as the local baseline.
        const legacy = try std.json.Stringify.valueAlloc(t.allocator, .{
            .version = version,
            .scope = store.scope,
            .state = .{ .admitted = true },
        }, .{});
        defer t.allocator.free(legacy);
        try store.db.put(lifecycle_namespace, &id, legacy, false);
    }
    const store = try Store.open(t.io, root, scope);
    defer store.close(t.io);
    const loaded = (try store.discover(t.io, t.allocator)).?.state;
    try t.expect(loaded.admitted);
    try t.expectEqual(@as(u64, 0), loaded.confirmed_balance_msats);
    try t.expectEqual(null, loaded.pending_cut);
    for ([_]Scope{
        .{ .server = "ws://second/", .receiver = scope.receiver, .player = scope.player },
        .{ .server = scope.server, .receiver = @splat(2), .player = scope.player },
        .{ .server = scope.server, .receiver = scope.receiver, .player = @splat(3) },
    }) |other_scope| {
        const other = try Store.open(t.io, root, other_scope);
        defer other.close(t.io);
        try t.expectEqual(null, try other.discover(t.io, t.allocator));
        try t.expectError(error.ScopeMismatch, other.readLifecycle(t.allocator, id));
    }
    var state: Lifecycle = .{ .admitted = true, .settlement = .{ .receipt_hash = @splat(5), .net_msats = null } };
    try store.writeLifecycle(t.allocator, id, state);
    try t.expect((try store.discover(t.io, t.allocator)) != null);
    state.settlement.?.net_msats = 30;
    try store.writeLifecycle(t.allocator, id, state);
    try t.expect((try store.discover(t.io, t.allocator)) != null);
    state.settlement.?.released = true;
    try store.writeLifecycle(t.allocator, id, state);
    try t.expectEqual(null, try store.discover(t.io, t.allocator));
}

fn matchFunding(a: Allocator, swap: Journal.MintSwap, channel: Funded) !void {
    if (swap.kind != .funding or !eql(u8, swap.mint_url, channel.mint_url)) return error.FundingMismatch;
    // Read the part of hoe_funding's journal material shared with the store.
    const parsed = try std.json.parseFromSlice(struct {
        version: u32,
        capacity_msats: u64,
        refund_time: u64,
        channel_secret_hex: []const u8,
        params_json: []const u8,
        keyset_json: []const u8,
        funding_secrets_json: []const u8,
    }, a, swap.completion_material, .{});
    defer parsed.deinit();
    const m = parsed.value;
    if (m.version != 1 or m.funding_secrets_json.len == 0 or
        m.capacity_msats != channel.capacity_msats or m.refund_time != channel.refund_time or
        !eql(u8, m.channel_secret_hex, channel.channel_secret_hex) or
        !eql(u8, m.params_json, channel.params_json) or !eql(u8, m.keyset_json, channel.keyset_json)) return error.FundingMismatch;
}

const t = std.testing;
const mint_id: Journal.Id = @splat(1);
const close_id: Journal.Id = @splat(2);
const funding_swap: Journal.Operation = .{ .mint_swap = .{
    .kind = .funding,
    .mint_url = "https://mint.example:443/Case/",
    .request_json = "{\n  \"outputs\" : [], \"inputs\": [] }\n",
    .completion_material = "{ \"secrets\": [\"opaque\"], \"keyset\": {} }",
} };
const close_swap: Journal.Operation = .{ .mint_swap = .{
    .kind = .close,
    .mint_url = "https://mint.example/",
    .request_json = "{\"outputs\":[]}",
    .completion_material = "\x00\xff\xa5",
} };

fn testRoot(tmp: *t.TmpDir) ![:0]u8 {
    try tmp.dir.createDir(t.io, "root", sf.mode_dir);
    const parent = try tmp.dir.openDir(t.io, ".", .{ .iterate = true });
    defer parent.close(t.io);
    try sf.syncDirectory(parent);
    return tmp.dir.realPathFileAlloc(t.io, "root", t.allocator);
}

test "reopen recovers exact funding and close material; duplicates cannot replace it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer t.allocator.free(root);
    {
        const journal = try Journal.open(t.io, root);
        defer journal.close(t.io);
        try journal.prepare(t.io, t.allocator, mint_id, funding_swap);
        try journal.prepare(t.io, t.allocator, close_id, close_swap);
        try t.expectError(error.AlreadyPending, journal.prepare(t.io, t.allocator, mint_id, close_swap));
        const dir = try sf.openOwnedDir(t.io, root, .{});
        defer dir.close(t.io);
        try sf.verifyFile(try dir.statFile(t.io, filename, .{ .follow_symlinks = false }));
    }
    {
        const journal = try Journal.open(t.io, root);
        defer journal.close(t.io);
        const ids = try journal.list(t.io, t.allocator);
        defer t.allocator.free(ids);
        try t.expectEqual(@as(usize, 2), ids.len);
        if (std.mem.eql(u8, &ids[0], &mint_id)) {
            try t.expectEqual(close_id, ids[1]);
        } else {
            try t.expectEqual(close_id, ids[0]);
            try t.expectEqual(mint_id, ids[1]);
        }
        const saved_mint = try journal.read(t.io, t.allocator, mint_id);
        defer saved_mint.deinit();
        try t.expectEqualDeep(funding_swap, saved_mint.value.operation);
        const saved_close = try journal.read(t.io, t.allocator, close_id);
        defer saved_close.deinit();
        try t.expectEqualDeep(close_swap, saved_close.value.operation);
        try journal.retire(t.io, mint_id);
        try journal.retire(t.io, mint_id);
    }
    const journal = try Journal.open(t.io, root);
    defer journal.close(t.io);
    try t.expectError(error.FileNotFound, journal.read(t.io, t.allocator, mint_id));
    const ids = try journal.list(t.io, t.allocator);
    defer t.allocator.free(ids);
    try t.expectEqual(@as(usize, 1), ids.len);
    try t.expectEqual(close_id, ids[0]);
}

test "malformed records are not treated as absent" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer t.allocator.free(root);
    const journal = try Journal.open(t.io, root);
    defer journal.close(t.io);
    try journal.db.put(journal_namespace, &mint_id, "{", false);
    try t.expectError(error.UnexpectedEndOfInput, journal.read(t.io, t.allocator, mint_id));
    try t.expectError(error.AlreadyPending, journal.prepare(t.io, t.allocator, mint_id, funding_swap));

    const wrong_version = try std.json.Stringify.valueAlloc(t.allocator, Journal.Record{
        .version = Journal.version + 1,
        .id = mint_id,
        .operation = funding_swap,
    }, .{});
    defer t.allocator.free(wrong_version);
    try journal.db.put(journal_namespace, &mint_id, wrong_version, true);
    try t.expectError(error.UnsupportedVersion, journal.read(t.io, t.allocator, mint_id));

    var incomplete = close_swap;
    incomplete.mint_swap.completion_material = "";
    try t.expectError(error.EmptyMaterial, journal.prepare(t.io, t.allocator, close_id, incomplete));
    try t.expectError(error.FileNotFound, journal.read(t.io, t.allocator, close_id));
}

test "legacy recovery records block SQLite open without modification" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer t.allocator.free(root);
    const dir = try sf.openOwnedDir(t.io, root, .{ .iterate = true });
    defer dir.close(t.io);
    try dir.createDir(t.io, legacy_journal_dir, sf.mode_dir);
    try dir.createDir(t.io, legacy_channels_dir, sf.mode_dir);
    try dir.createDir(t.io, legacy_channels_dir ++ "/scope", sf.mode_dir);
    for ([_][]const u8{ legacy_pending_file, legacy_journal_dir ++ "/.tmp-interrupted", legacy_channels_dir ++ "/scope/channel" }) |path| {
        try dir.writeFile(t.io, .{ .sub_path = path, .data = "recovery data" });
        try t.expectError(error.LegacySpilmanRecords, Journal.open(t.io, root));
        const saved = try dir.readFileAlloc(t.io, path, t.allocator, .limited(32));
        defer t.allocator.free(saved);
        try t.expectEqualStrings("recovery data", saved);
        try dir.deleteFile(t.io, path);
    }
    try t.expectError(error.FileNotFound, dir.statFile(t.io, filename, .{}));
    const journal = try Journal.open(t.io, root);
    defer journal.close(t.io);
}
