//! Native onboarding persistence; never repairs or removes existing wallet data.
const std = @import("std");
const builtin = @import("builtin");
const wallet = @import("wallet.zig");
const onboarding = @import("onboarding.zig");
const sf = @import("storage_fs.zig");
const Io = std.Io;

const name = "wallet-onboarding.json";
const pending = "{\"version\":1,\"step\":\"backup_seed\"}";
const completed = "{\"version\":1,\"step\":\"complete\"}";
const ScanOutcome = union(enum) { failed, success: struct { spendable: u64, pending: u64, spent: u64 } };
var test_scan: ?ScanOutcome = null;
const Record = struct {
    version: u32,
    step: enum { backup_seed, complete, preparing, scanning, failed, result, committing, abandoning },
    id: [32]u8 = undefined,
    spendable_sats: u64 = 0,
    pending_sats: u64 = 0,
    spent_sats: u64 = 0,
};

fn number(value: std.json.Value) !u64 {
    if (value != .number_string) return error.InvalidOnboardingRecord;
    for (value.number_string) |c| if (c < '0' or c > '9') return error.InvalidOnboardingRecord;
    return std.fmt.parseInt(u64, value.number_string, 10) catch error.InvalidOnboardingRecord;
}

pub const Native = struct {
    io: Io,
    allocator: std.mem.Allocator,
    config_dir: []const u8,
    paths: wallet.Paths,
    standard_parents: []const []const u8 = &.{},

    fn config(self: *Native) !Io.Dir {
        if (!std.fs.path.isAbsolute(self.config_dir)) return error.InvalidPath;
        try sf.verifyOwnedDir(self.io, self.config_dir);
        const dir = try Io.Dir.openDirAbsolute(self.io, self.config_dir, .{ .follow_symlinks = false });
        errdefer dir.close(self.io);
        try sf.verifyNoExtendedAclDir(dir);
        return dir;
    }

    fn record(self: *Native, dir: Io.Dir) !?Record {
        const st = dir.statFile(self.io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        try sf.verifyFile(st);
        const file = try dir.openFile(self.io, name, .{ .follow_symlinks = false });
        defer file.close(self.io);
        const opened = try file.stat(self.io);
        try sf.verifyFile(opened);
        try sf.verifyNoExtendedAcl(file);
        if (opened.size == 0 or opened.size > 256) return error.InvalidOnboardingRecord;
        var buf: [257]u8 = undefined;
        var reader = file.reader(self.io, &.{});
        const n = try reader.interface.readSliceShort(&buf);
        if (n == 0 or n > 256) return error.InvalidOnboardingRecord;
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, buf[0..n], .{ .parse_numbers = false }) catch return error.InvalidOnboardingRecord;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidOnboardingRecord;
        const version = parsed.value.object.get("version") orelse return error.InvalidOnboardingRecord;
        const step = parsed.value.object.get("step") orelse return error.InvalidOnboardingRecord;
        const v = try number(version);
        if (step != .string) return error.InvalidOnboardingRecord;
        if (v == 1) {
            if (parsed.value.object.count() != 2) return error.InvalidOnboardingRecord;
            if (std.mem.eql(u8, step.string, "backup_seed")) return .{ .version = 1, .step = .backup_seed };
            if (std.mem.eql(u8, step.string, "complete")) return .{ .version = 1, .step = .complete };
            return error.InvalidOnboardingRecord;
        }
        if (v != 2) return error.InvalidOnboardingRecord;
        const id = parsed.value.object.get("id") orelse return error.InvalidOnboardingRecord;
        if (id != .string or id.string.len != 32) return error.InvalidOnboardingRecord;
        for (id.string) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return error.InvalidOnboardingRecord;
        const s = std.meta.stringToEnum(@FieldType(Record, "step"), step.string) orelse return error.InvalidOnboardingRecord;
        if (s == .backup_seed or s == .complete) return error.InvalidOnboardingRecord;
        if (parsed.value.object.count() != (if (s == .result or s == .committing) @as(usize, 6) else 3)) return error.InvalidOnboardingRecord;
        var result = Record{ .version = 2, .step = s, .id = id.string[0..32].* };
        if (s == .result or s == .committing) {
            result.spent_sats = try number(parsed.value.object.get("spent_sats") orelse return error.InvalidOnboardingRecord);
            result.pending_sats = try number(parsed.value.object.get("pending_sats") orelse return error.InvalidOnboardingRecord);
            result.spendable_sats = try number(parsed.value.object.get("spendable_sats") orelse return error.InvalidOnboardingRecord);
        }
        return result;
    }

    fn syncAncestry(self: *Native) !void {
        var parent = try sf.openParent(self.io, self.config_dir);
        defer parent.close(self.io);
        try sf.syncDirectory(parent);
        var i = self.standard_parents.len;
        while (i > 0) {
            i -= 1;
            var dir = try sf.openParent(self.io, self.standard_parents[i]);
            defer dir.close(self.io);
            try sf.syncDirectory(dir);
        }
    }

    fn validate(self: *Native) !void {
        var inspection = try wallet.inspect(self.io, self.allocator, self.paths, true);
        if (inspection.state != .ready) return error.WalletUnavailable;
        try inspection.close();
    }

    fn exists(self: *Native, path: []const u8) !bool {
        _ = Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    fn stageExists(self: *Native) !bool {
        const paths = try wallet.recoveryPaths(self.allocator, self.paths);
        defer {
            paths.deinit(self.allocator);
            self.allocator.free(paths.dir);
        }
        return self.exists(paths.dir);
    }

    fn writeRecord(self: *Native, dir: Io.Dir, r: Record) !void {
        var buf: [256]u8 = undefined;
        const data = if (r.step == .result or r.step == .committing)
            try std.fmt.bufPrint(&buf, "{{\"version\":2,\"step\":\"{s}\",\"id\":\"{s}\",\"spent_sats\":{d},\"pending_sats\":{d},\"spendable_sats\":{d}}}", .{ @tagName(r.step), r.id, r.spent_sats, r.pending_sats, r.spendable_sats })
        else
            try std.fmt.bufPrint(&buf, "{{\"version\":2,\"step\":\"{s}\",\"id\":\"{s}\"}}", .{ @tagName(r.step), r.id });
        try sf.writeAtomicIn(dir, self.io, name, data);
        try self.syncAncestry();
    }

    fn safe(self: *Native, id: [32]u8) bool {
        return wallet.recoveryCanAbandon(self.io, self.allocator, self.paths, id) catch false;
    }

    fn report(self: *Native, r: Record) onboarding.RestoreReport {
        return .{ .spent_sats = r.spent_sats, .pending_sats = r.pending_sats, .spendable_sats = r.spendable_sats, .can_generate_new = r.spent_sats == 0 and r.pending_sats == 0 and r.spendable_sats == 0 and self.safe(r.id) };
    }

    /// Backup payload ownership transfers to the onboarding model.
    pub fn start(self: *Native) !onboarding.Event {
        var dir = try self.config();
        defer dir.close(self.io);
        const state = try self.record(dir);
        if (state) |r| if (r.version == 2) {
            if (r.step == .committing) {
                try self.finishCommitting(dir, r);
                return .ready;
            }
            if (r.step == .abandoning) return self.finishAbandoning(dir, r);
            if (try self.exists(self.paths.dir)) return error.WalletUnavailable;
            const stage_exists = try self.stageExists();
            if (!stage_exists and r.step == .preparing) return .resume_phrase_entry;
            if (!stage_exists) return error.WalletUnavailable;
            var inspection = try wallet.inspectRecovery(self.io, self.allocator, self.paths, r.id, true);
            try inspection.close();
            return switch (r.step) {
                .preparing => .{ .resume_failed = .{ .can_generate_new = false } },
                .scanning, .failed => .{ .resume_failed = .{ .can_generate_new = false } },
                .result => .{ .resume_result = self.report(r) },
                else => error.InvalidOnboardingRecord,
            };
        };
        const final_exists = blk: {
            _ = Io.Dir.cwd().statFile(self.io, self.paths.dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };
        if (final_exists) {
            try self.validate();
            if (state == null) return .ready;
            if (state.?.step == .complete) {
                try sf.syncDirectory(dir);
                try self.syncAncestry();
                return .ready;
            }
            return .{ .backup = try wallet.readMnemonic(self.io, self.allocator, self.paths) };
        }
        const record_value = state orelse {
            if (try self.stageExists()) return error.WalletUnavailable;
            return .{ .choice = .{ .recover_enabled = true } };
        };
        if (record_value.step == .complete) return error.WalletUnavailable;
        if (try self.stageExists()) return error.WalletUnavailable;
        return self.createPending(dir);
    }

    /// Begin creation only after the user chooses a new wallet.
    pub fn createNew(self: *Native) !onboarding.Event {
        var dir = try self.config();
        defer dir.close(self.io);
        if (try self.record(dir) != null or try self.exists(self.paths.dir) or try self.stageExists()) return error.WalletUnavailable;
        try sf.writeAtomicIn(dir, self.io, name, pending);
        return self.createPending(dir);
    }

    pub fn restore(self: *Native, phrase: []const u8, attempt_id: u64) !onboarding.Event {
        var dir = try self.config();
        defer dir.close(self.io);
        if (try self.exists(self.paths.dir) or try self.stageExists()) return error.WalletUnavailable;
        const previous = try self.record(dir);
        if (previous) |r| if (r.version != 2 or r.step != .preparing) return error.WalletUnavailable;
        try wallet.validateRecoveryPhrase(phrase);
        var r = previous orelse blk: {
            var random: [16]u8 = undefined;
            self.io.random(&random);
            break :blk Record{ .version = 2, .step = .preparing, .id = std.fmt.bytesToHex(random, .lower) };
        };
        try self.writeRecord(dir, r);
        try wallet.prepareRecovery(self.io, self.allocator, self.paths, phrase, r.id);
        r.step = .scanning;
        try self.writeRecord(dir, r);
        return self.scan(dir, r, attempt_id);
    }

    pub fn retry(self: *Native, attempt_id: u64) !onboarding.Event {
        if (try self.exists(self.paths.dir)) return error.WalletUnavailable;
        var dir = try self.config();
        defer dir.close(self.io);
        var r = try self.record(dir) orelse return error.WalletUnavailable;
        if (r.version != 2 or (r.step != .preparing and r.step != .scanning and r.step != .failed and r.step != .result)) return error.WalletUnavailable;
        var inspection = try wallet.inspectRecovery(self.io, self.allocator, self.paths, r.id, true);
        try inspection.close();
        r.step = .scanning;
        try self.writeRecord(dir, r);
        return self.scan(dir, r, attempt_id);
    }

    fn scan(self: *Native, dir: Io.Dir, input: Record, attempt_id: u64) !onboarding.Event {
        var inspection = try wallet.inspectRecovery(self.io, self.allocator, self.paths, input.id, true);
        const handle = if (inspection.wallet) |w| w.wallet else return error.WalletUnavailable;
        const outcome: ScanOutcome = if (builtin.is_test) test_scan orelse .failed else blk: {
            const mint = if (builtin.mode == .debug) "http://127.0.0.1:18787" else "https://mint.minibits.cash/Bitcoin";
            const result = wallet.cdk.c.cdk_wallet_restore_seed(handle, mint);
            wallet.cdk.c.cdk_string_free(result.@"error");
            break :blk if (result.status != wallet.cdk.c.CDK_STATUS_OK or result.incomplete != 0) .failed else .{ .success = .{ .spendable = result.unspent_sats, .pending = result.pending_sats, .spent = result.spent_sats } };
        };
        try inspection.close();
        var r = input;
        if (outcome == .failed) {
            r.step = .failed;
            try self.writeRecord(dir, r);
            return .{ .restore_failed = .{ .attempt_id = attempt_id, .stage_created = true, .can_generate_new = false } };
        }
        r.step = .result;
        r.spent_sats = outcome.success.spent;
        r.pending_sats = outcome.success.pending;
        r.spendable_sats = outcome.success.spendable;
        try self.writeRecord(dir, r);
        return .{ .restore_finished = .{ .attempt_id = attempt_id, .report = self.report(r) } };
    }

    fn createPending(self: *Native, dir: Io.Dir) !onboarding.Event {
        // Also sync the marker directory on resume after a failed previous sync.
        try sf.syncDirectory(dir);
        try self.syncAncestry();
        const created = try wallet.create(self.io, self.allocator, self.paths);
        errdefer created.deinit(self.allocator);
        if (created.durability != .durable) return error.WalletDurabilityUnknown;
        try self.validate();
        return .{ .backup = created.mnemonic };
    }

    fn hasHistory(r: Record) bool {
        return r.spent_sats != 0 or r.pending_sats != 0 or r.spendable_sats != 0;
    }

    fn syncWalletParent(self: *Native) !void {
        var parent = try sf.openParent(self.io, self.paths.dir);
        defer parent.close(self.io);
        try sf.syncDirectory(parent);
    }

    fn finishCommitting(self: *Native, dir: Io.Dir, r: Record) !void {
        if (!hasHistory(r)) return error.WalletUnavailable;
        const stage = try self.stageExists();
        const final = try self.exists(self.paths.dir);
        if (stage == final) return error.WalletUnavailable;
        if (stage) {
            if (try wallet.commitRecovery(self.io, self.allocator, self.paths, r.id) != .durable) return error.WalletDurabilityUnknown;
        } else {
            var inspection = try wallet.inspectCommittedRecovery(self.io, self.allocator, self.paths, r.id, true);
            try inspection.close();
            try self.syncWalletParent();
        }
        try sf.writeAtomicIn(dir, self.io, name, completed);
        try sf.syncDirectory(dir);
        try self.syncAncestry();
    }

    pub fn finishRestore(self: *Native) !void {
        var dir = try self.config();
        defer dir.close(self.io);
        var r = try self.record(dir) orelse return error.WalletUnavailable;
        if (r.version != 2 or (r.step != .result and r.step != .committing) or !hasHistory(r)) return error.WalletUnavailable;
        if (r.step == .result) {
            if (try self.exists(self.paths.dir)) return error.WalletUnavailable;
            var inspection = try wallet.inspectRecovery(self.io, self.allocator, self.paths, r.id, true);
            try inspection.close();
            r.step = .committing;
            try self.writeRecord(dir, r);
        }
        try self.finishCommitting(dir, r);
    }

    fn finishAbandoning(self: *Native, dir: Io.Dir, r: Record) !onboarding.Event {
        if (try self.exists(self.paths.dir)) return error.WalletUnavailable;
        const retired = try wallet.retiredRecoveryPaths(self.allocator, self.paths, r.id);
        defer {
            retired.deinit(self.allocator);
            self.allocator.free(retired.dir);
        }
        const stage = try self.stageExists();
        const retained = try self.exists(retired.dir);
        if (stage == retained) return error.WalletUnavailable;
        if (stage) {
            if (try wallet.retireRecovery(self.io, self.allocator, self.paths, r.id) != .durable) return error.WalletDurabilityUnknown;
        } else {
            var inspection = try wallet.inspectRetiredRecovery(self.io, self.allocator, self.paths, r.id, true);
            try inspection.close();
            try self.syncWalletParent();
        }
        try sf.writeAtomicIn(dir, self.io, name, pending);
        try sf.syncDirectory(dir);
        try self.syncAncestry();
        return self.createPending(dir);
    }

    pub fn generateNew(self: *Native) !onboarding.Event {
        var dir = try self.config();
        defer dir.close(self.io);
        var r = try self.record(dir) orelse return error.WalletUnavailable;
        if (r.version != 2) return error.WalletUnavailable;
        if (r.step == .abandoning) return self.finishAbandoning(dir, r);
        if (r.step != .result or hasHistory(r)) return error.WalletUnavailable;
        if (try self.exists(self.paths.dir)) return error.WalletUnavailable;
        if (!self.safe(r.id)) return error.WalletUnavailable;
        r.step = .abandoning;
        try self.writeRecord(dir, r);
        return self.finishAbandoning(dir, r);
    }

    pub fn complete(self: *Native) !void {
        var dir = try self.config();
        defer dir.close(self.io);
        const state = try self.record(dir) orelse return error.InvalidOnboardingRecord;
        if (state.version != 1) return error.InvalidOnboardingRecord;
        try self.validate();
        // A previous rename may have succeeded even if its directory sync failed.
        if (state.step == .complete) return sf.syncDirectory(dir);
        try sf.writeAtomicIn(dir, self.io, name, completed);
    }
};

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    config_dir: []u8,
    wallet_dir: []u8,
    paths: wallet.Paths,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const a = testing.allocator;
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
        errdefer a.free(root);
        const config_dir = try std.fs.path.join(a, &.{ root, "config" });
        errdefer a.free(config_dir);
        const data_dir = try std.fs.path.join(a, &.{ root, "data" });
        defer a.free(data_dir);
        try sf.ensureOwnedDir(testing.io, data_dir);
        const wallet_dir = try std.fs.path.join(a, &.{ data_dir, "wallet" });
        errdefer a.free(wallet_dir);
        try sf.ensureOwnedDir(testing.io, config_dir);
        const paths = try wallet.Paths.init(a, wallet_dir);
        return .{ .tmp = tmp, .root = root, .config_dir = config_dir, .wallet_dir = wallet_dir, .paths = paths };
    }

    fn deinit(self: *Fixture) void {
        const a = testing.allocator;
        self.paths.deinit(a);
        a.free(self.wallet_dir);
        a.free(self.config_dir);
        a.free(self.root);
        self.tmp.cleanup();
    }

    fn native(self: *Fixture) Native {
        return .{ .io = testing.io, .allocator = testing.allocator, .config_dir = self.config_dir, .paths = self.paths };
    }

    fn marker(self: *Fixture, data: []const u8) !void {
        var dir = try Io.Dir.openDirAbsolute(testing.io, self.config_dir, .{});
        defer dir.close(testing.io);
        try sf.writeAtomicIn(dir, testing.io, name, data);
    }
};

fn freeEvent(event: onboarding.Event) void {
    if (event == .backup) {
        std.crypto.secureZero(u8, event.backup);
        testing.allocator.free(event.backup);
    }
}

test "new wallet resumes same phrase and completes" {
    var f = try Fixture.init();
    defer f.deinit();
    var native = f.native();
    try testing.expect((try native.start()) == .choice);
    const first = try native.createNew();
    defer freeEvent(first);
    try testing.expect(first == .backup);
    const resumed = try native.start();
    defer freeEvent(resumed);
    try testing.expect(resumed == .backup);
    try testing.expectEqualStrings(first.backup, resumed.backup);
    try native.complete();
    try testing.expect((try native.start()) == .ready);
}

test "fresh startup offers choice without creating wallet or marker" {
    var f = try Fixture.init();
    defer f.deinit();
    var native = f.native();
    const event = try native.start();
    try testing.expect(event == .choice);
    try testing.expect(event.choice.recover_enabled);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(testing.io, f.wallet_dir, .{}));
    var dir = try Io.Dir.openDirAbsolute(testing.io, f.config_dir, .{});
    defer dir.close(testing.io);
    try testing.expectError(error.FileNotFound, dir.statFile(testing.io, name, .{}));
}

test "legacy pair skips and pending missing pair creates" {
    var f = try Fixture.init();
    defer f.deinit();
    var native = f.native();
    const created = try wallet.create(testing.io, testing.allocator, f.paths);
    defer created.deinit(testing.allocator);
    try testing.expect(created.durability == .durable);
    try testing.expect((try native.start()) == .ready);
    try f.marker(pending);
    const resumed = try native.start();
    defer freeEvent(resumed);
    try testing.expect(resumed == .backup);
    try testing.expectEqualStrings(created.mnemonic, resumed.backup);
}

test "pending with missing pair creates" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.marker(pending);
    var native = f.native();
    const event = try native.start();
    defer freeEvent(event);
    try testing.expect(event == .backup);
}

test "malformed markers and missing completed wallet block" {
    var f = try Fixture.init();
    defer f.deinit();
    var native = f.native();
    for ([_][]const u8{ "{}", "{\"version\":2,\"step\":\"complete\"}", "{\"version\":2,\"step\":\"backup_seed\"}", "{\"version\":1,\"step\":\"complete\",\"extra\":1}", "not json" }) |bad| {
        try f.marker(bad);
        try testing.expectError(error.InvalidOnboardingRecord, native.start());
    }
    try f.marker(completed);
    try testing.expectError(error.WalletUnavailable, native.start());
}

test "empty and partial wallet directories block without repair" {
    var f = try Fixture.init();
    defer f.deinit();
    var native = f.native();
    try sf.ensureOwnedDir(testing.io, f.wallet_dir);
    try testing.expectError(error.WalletUnavailable, native.start());
    var dir = try Io.Dir.openDirAbsolute(testing.io, f.wallet_dir, .{});
    defer dir.close(testing.io);
    try dir.writeFile(testing.io, .{ .sub_path = wallet.seed_file_name, .data = "not a seed", .flags = .{ .permissions = sf.mode_file } });
    try testing.expectError(error.WalletUnavailable, native.start());
    _ = try dir.statFile(testing.io, wallet.seed_file_name, .{});
}

test "unknown durability retains pending and resumes" {
    var f = try Fixture.init();
    defer f.deinit();
    var native = f.native();
    wallet.testFailCommitSync = true;
    defer wallet.testFailCommitSync = false;
    try testing.expect((try native.start()) == .choice);
    try testing.expectError(error.WalletDurabilityUnknown, native.createNew());
    wallet.testFailCommitSync = false;
    const event = try native.start();
    defer freeEvent(event);
    try testing.expect(event == .backup);
}

test "recovery failures resume and successful totals persist" {
    var f = try Fixture.init();
    defer f.deinit();
    var native = f.native();
    defer test_scan = null;
    const phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    try testing.expectError(error.InvalidMnemonic, native.restore("invalid", 1));
    try testing.expect((try native.start()) == .choice);
    test_scan = .failed;
    const failed = try native.restore(phrase, 2);
    try testing.expect(failed == .restore_failed and failed.restore_failed.stage_created and !failed.restore_failed.can_generate_new);
    const resumed_failure = try native.start();
    try testing.expect(resumed_failure == .resume_failed and !resumed_failure.resume_failed.can_generate_new);
    try testing.expectError(error.WalletUnavailable, native.generateNew());
    var marker_dir = try native.config();
    var scanning = (try native.record(marker_dir)).?;
    scanning.step = .scanning;
    try native.writeRecord(marker_dir, scanning);
    marker_dir.close(testing.io);
    try testing.expect(!(try native.start()).resume_failed.can_generate_new);
    try testing.expectError(error.WalletUnavailable, native.generateNew());
    try testing.expectError(error.WalletUnavailable, native.createNew());
    test_scan = .{ .success = .{ .spendable = 0, .pending = 0, .spent = 0 } };
    const empty = try native.retry(3);
    try testing.expect(empty == .restore_finished and empty.restore_finished.report.can_generate_new);
    const resumed = try native.start();
    try testing.expect(resumed == .resume_result and resumed.resume_result.can_generate_new);
    test_scan = .{ .success = .{ .spendable = 0, .pending = 1, .spent = 0 } };
    try testing.expect(!(try native.retry(4)).restore_finished.report.can_generate_new);
    test_scan = .{ .success = .{ .spendable = 0, .pending = 0, .spent = 1 } };
    try testing.expect(!(try native.retry(5)).restore_finished.report.can_generate_new);
    try testing.expect(!(try native.start()).resume_result.can_generate_new);
}

test "preparing stage resumes without replacing ownership" {
    var f = try Fixture.init();
    defer f.deinit();
    var native = f.native();
    const id = "0123456789abcdef0123456789abcdef".*;
    try f.marker("{\"version\":2,\"step\":\"preparing\",\"id\":\"0123456789abcdef0123456789abcdef\"}");
    try testing.expect((try native.start()) == .resume_phrase_entry);
    defer test_scan = null;
    test_scan = .failed;
    _ = try native.restore("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", 1);
    var inspected = try wallet.inspectRecovery(testing.io, testing.allocator, f.paths, id, true);
    try inspected.close();
    try f.marker("{\"version\":2,\"step\":\"preparing\",\"id\":\"0123456789abcdef0123456789abcdef\"}");
    try testing.expect((try native.start()) == .resume_failed);
    try testing.expect((try native.retry(2)) == .restore_failed);
}

test "v2 markers reject malformed fields and incomplete stages" {
    var f = try Fixture.init();
    defer f.deinit();
    var native = f.native();
    for ([_][]const u8{
        "{\"version\":2,\"step\":\"preparing\",\"id\":\"0123456789abcdef0123456789abcdeF\"}",
        "{\"version\":2,\"step\":\"failed\",\"id\":\"0123456789abcdef0123456789abcdef\",\"extra\":0}",
        "{\"version\":2,\"step\":\"result\",\"id\":\"0123456789abcdef0123456789abcdef\",\"spent_sats\":18446744073709551616,\"pending_sats\":0,\"spendable_sats\":0}",
        "{\"version\":2,\"step\":\"result\",\"id\":\"0123456789abcdef0123456789abcdef\",\"spent_sats\":-1,\"pending_sats\":0,\"spendable_sats\":0}",
        "{\"version\":2,\"version\":2,\"step\":\"failed\",\"id\":\"0123456789abcdef0123456789abcdef\"}",
    }) |bad| {
        try f.marker(bad);
        try testing.expectError(error.InvalidOnboardingRecord, native.start());
    }
    try f.marker("{\"version\":2,\"step\":\"scanning\",\"id\":\"0123456789abcdef0123456789abcdef\"}");
    try testing.expectError(error.WalletUnavailable, native.start());
    try f.marker("{\"version\":2,\"step\":\"preparing\",\"id\":\"0123456789abcdef0123456789abcdef\"}");
    const paths = try wallet.recoveryPaths(testing.allocator, f.paths);
    defer {
        paths.deinit(testing.allocator);
        testing.allocator.free(paths.dir);
    }
    try sf.ensureOwnedDir(testing.io, paths.dir);
    try testing.expectError(error.RecoveryStageUnavailable, native.start());
    try testing.expectError(error.WalletUnavailable, native.restore("invalid", 1));
}

test "finish recovery commits history and reconciles interrupted rename" {
    defer test_scan = null;
    for ([_]bool{ false, true }) |interrupted| {
        var f = try Fixture.init();
        defer f.deinit();
        var native = f.native();
        test_scan = .{ .success = .{ .spendable = if (interrupted) 5 else 0, .pending = if (interrupted) 0 else 2, .spent = 0 } };
        _ = try native.restore("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", 1);
        if (interrupted) {
            wallet.testFailCommitSync = true;
            defer wallet.testFailCommitSync = false;
            try testing.expectError(error.WalletDurabilityUnknown, native.finishRestore());
            wallet.testFailCommitSync = false;
        } else try native.finishRestore();
        try testing.expect((try native.start()) == .ready);
    }
}

test "recovery refuses conflicting final and nonzero abandonment" {
    defer test_scan = null;
    var f = try Fixture.init();
    defer f.deinit();
    var native = f.native();
    test_scan = .{ .success = .{ .spendable = 0, .pending = 0, .spent = 1 } };
    _ = try native.restore("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", 1);
    try testing.expectError(error.WalletUnavailable, native.generateNew());
    const existing = try wallet.create(testing.io, testing.allocator, f.paths);
    defer existing.deinit(testing.allocator);
    try testing.expectError(error.WalletUnavailable, native.finishRestore());
    const phrase = try wallet.readMnemonic(testing.io, testing.allocator, f.paths);
    defer testing.allocator.free(phrase);
    try testing.expectEqualStrings(existing.mnemonic, phrase);
}

test "abandon recovery retains ownership and reconciles both rename states" {
    defer test_scan = null;
    for ([_]u8{ 0, 1, 2 }) |scenario| {
        var f = try Fixture.init();
        defer f.deinit();
        var native = f.native();
        test_scan = .{ .success = .{ .spendable = 0, .pending = 0, .spent = 0 } };
        _ = try native.restore("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", 1);
        var dir = try native.config();
        const r = (try native.record(dir)).?;
        if (scenario == 1) {
            var abandoning = r;
            abandoning.step = .abandoning;
            try native.writeRecord(dir, abandoning);
        }
        dir.close(testing.io);
        const event = if (scenario == 1) try native.start() else blk: {
            if (scenario == 2) {
                wallet.testFailCommitSync = true;
                defer wallet.testFailCommitSync = false;
                try testing.expectError(error.WalletDurabilityUnknown, native.generateNew());
                wallet.testFailCommitSync = false;
                break :blk try native.start();
            }
            break :blk try native.generateNew();
        };
        defer freeEvent(event);
        try testing.expect(event == .backup);
        var inspection = try wallet.inspectRetiredRecovery(testing.io, testing.allocator, f.paths, r.id, true);
        try inspection.close();
    }
}
