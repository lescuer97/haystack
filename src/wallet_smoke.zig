//! Disposable startup smoke test for the native wallet C ABI.
//!
//! Linux desktop `main` runs this on a worker thread before creating the
//! window. It proves that the generated bindings and the linked Rust archive
//! can generate a phrase, derive the 64-byte seed, open a brand-new database,
//! list an empty wallet, and close it — without touching the network.
//!
//! The phrase, seed, and database are throwaway test material:
//!
//! * the phrase and Rust-owned seed payload are freed with the ABI's scrubbing
//!   free helpers and never reach the log;
//! * the 64-byte copy needed to open the wallet is scrubbed immediately after
//!   `cdk_wallet_open` returns (with a defer for failure paths);
//! * the database lives in a fresh owner-only directory under `TMPDIR` (or
//!   `/tmp`), so there is never a persistent fixed seed or database;
//! * the whole directory, including SQLite sidecars, is removed afterwards.
//!
//! This is deliberately not a wallet UI, backup mechanism, or production store.

const std = @import("std");
const cdk = @import("cdk");

const c = cdk.c;

const temp_prefix = "haystack-wallet-smoke-";
const temp_attempts = 3;
const db_name = "wallet.sqlite";

fn freeError(err: ?[*:0]u8) void {
    if (err) |e| c.cdk_string_free(e);
}

/// Choose the temporary directory root. `TMPDIR` is honored only when it is a
/// sensible absolute path; otherwise fall back to `/tmp`.
fn tempRoot() []const u8 {
    const value = std.c.getenv("TMPDIR") orelse return "/tmp";
    const root = std.mem.span(value);
    if (root.len == 0 or !std.Io.Dir.path.isAbsolute(root)) return "/tmp";
    return root;
}

/// Run the complete smoke test on a private random directory under the
/// platform temporary root.
pub fn run(io: std.Io) !void {
    return runInFreshDir(io, tempRoot());
}

/// Run the complete smoke test in the calling thread. `runOnWorker` is the
/// production entry point because every ABI call blocks on the Rust runtime;
/// tests and other callers may use this directly.
pub fn runOnWorker(io: std.Io) !void {
    var outcome: ?anyerror = null;
    const thread = try std.Thread.spawn(.{}, smokeThread, .{ io, &outcome });
    thread.join();
    if (outcome) |err| return err;
}

fn smokeThread(io: std.Io, outcome: *?anyerror) void {
    run(io) catch |err| {
        outcome.* = err;
    };
}

/// Create one unique private directory under `root`, run the wallet smoke in
/// it, then remove the directory even if the smoke fails. `root` may be
/// absolute (`TMPDIR`) or relative (tests).
pub fn runInFreshDir(io: std.Io, root: []const u8) !void {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try createPrivateDir(io, root, &path_buf);

    var needs_cleanup = true;
    defer if (needs_cleanup) {
        std.Io.Dir.cwd().deleteTree(io, dir_path) catch |err| {
            std.log.err("wallet smoke: disposable directory cleanup failed: {s}", .{@errorName(err)});
        };
    };

    try runInDir(io, dir_path);

    // Make cleanup part of the success result: a leftover directory must not
    // be reported as a passing startup check. Log only after it succeeds.
    needs_cleanup = false;
    try std.Io.Dir.cwd().deleteTree(io, dir_path);
    std.log.info("wallet smoke: mnemonic + 64-byte seed + empty disposable wallet OK", .{});
}

fn createPrivateDir(
    io: std.Io,
    root: []const u8,
    path_buf: []u8,
) ![:0]const u8 {
    var attempt: usize = 0;
    while (attempt < temp_attempts) : (attempt += 1) {
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const path = std.mem.printSentinel(
            path_buf,
            "{s}/{s}{s}",
            .{ root, temp_prefix, suffix },
            0,
        ) catch return error.WalletSmokeTempDir;

        std.Io.Dir.cwd().createDir(
            io,
            path,
            std.Io.File.Permissions.fromMode(0o700),
        ) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return path;
    }
    return error.WalletSmokeTempDir;
}

/// Exercise every ABI step inside `dir_path`. The caller owns the directory
/// and its cleanup.
pub fn runInDir(io: std.Io, dir_path: []const u8) !void {
    _ = io;

    // 1. Generate a fresh phrase and derive its 64-byte wallet seed. The phrase
    //    and Rust-owned payloads are freed when this block exits. The 64-byte
    //    copy is needed by `cdk_wallet_open` and is scrubbed immediately after
    //    that call returns; the defer also covers failure paths.
    var seed: [cdk.seed_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    {
        const generated = c.cdk_generate_mnemonic();
        defer freeError(generated.@"error");
        defer c.cdk_string_free(generated.value);
        if (generated.status != c.CDK_STATUS_OK or generated.value == null) {
            return error.WalletSmokeMnemonic;
        }

        const derived = c.cdk_mnemonic_to_seed(generated.value);
        defer freeError(derived.@"error");
        defer c.cdk_bytes_free(derived.bytes);
        if (derived.status != c.CDK_STATUS_OK) return error.WalletSmokeSeed;
        if (derived.bytes.ptr == null or derived.bytes.len != cdk.seed_len) {
            return error.WalletSmokeSeed;
        }
        @memcpy(&seed, derived.bytes.ptr[0..cdk.seed_len]);
    }

    // 2. Open a brand-new database inside the disposable directory.
    var db_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const db_path = std.mem.printSentinel(
        &db_buf,
        "{s}/{s}",
        .{ dir_path, db_name },
        0,
    ) catch return error.WalletSmokeTempDir;

    const opened = c.cdk_wallet_open(cdk.byteSlice(&seed), db_path.ptr);
    // The ABI has consumed its synchronous borrow of the seed. Drop our copy
    // now; the defer above still scrubs it if this call failed before copying.
    std.crypto.secureZero(u8, &seed);
    defer freeError(opened.@"error");
    defer c.cdk_recovery_reports_free(opened.reports);
    if (opened.status != c.CDK_STATUS_OK or opened.handle == null) {
        return error.WalletSmokeOpen;
    }
    const handle = opened.handle.?;

    // A close error still consumes the handle, so guard every later failure
    // path and mark the handle consumed before inspecting the status.
    var close_handled = false;
    defer if (!close_handled) {
        const closed = c.cdk_wallet_close(handle);
        freeError(closed.@"error");
    };

    // A first open of a fresh database must not report recovered, skipped, or
    // failed sagas; there are no approved mints yet.
    if (opened.recovered != 0 or
        opened.compensated != 0 or
        opened.skipped != 0 or
        opened.failed != 0 or
        opened.reports.len != 0)
    {
        return error.WalletSmokeRecoveryUnexpected;
    }

    // 3. Verify the fresh wallet is empty. Both lists are Rust-owned, even
    //    when empty, and must be freed with their matching helpers.
    const balances = c.cdk_wallet_list_balances(handle);
    defer freeError(balances.@"error");
    defer c.cdk_balance_list_free(balances.balances);
    if (balances.status != c.CDK_STATUS_OK) return error.WalletSmokeBalances;
    if (balances.balances.len != 0) return error.WalletSmokeBalances;

    const mints = c.cdk_wallet_list_mints(handle);
    defer freeError(mints.@"error");
    defer c.cdk_mint_list_free(mints.mints);
    if (mints.status != c.CDK_STATUS_OK) return error.WalletSmokeMints;
    if (mints.mints.len != 0) return error.WalletSmokeMints;

    // 4. Explicit close status check. No call may use the handle afterwards.
    const closed = c.cdk_wallet_close(handle);
    close_handled = true;
    defer freeError(closed.@"error");
    if (closed.status != c.CDK_STATUS_OK) return error.WalletSmokeClose;
}

test "wallet smoke opens and cleans fresh disposable directories" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try std.mem.printSentinel(
        &base_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path[0..]},
        0,
    );

    // Two runs must each create a distinct private directory and remove it.
    try runInFreshDir(io, base);
    var it = tmp.dir.iterate();
    try std.testing.expect((try it.next(io)) == null);

    try runInFreshDir(io, base);
    it = tmp.dir.iterate();
    try std.testing.expect((try it.next(io)) == null);
}

test "wallet smoke propagates an open failure without leaking ABI payloads" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A regular file where the database's parent directory is expected makes
    // the open fail even though the ABI will create ordinary missing parents.
    try tmp.dir.writeFile(io, .{ .sub_path = "not-a-dir", .data = "" });

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const not_a_dir = try std.mem.printSentinel(
        &base_buf,
        ".zig-cache/tmp/{s}/not-a-dir",
        .{tmp.sub_path[0..]},
        0,
    );

    // The owned error and recovery report must still be freed before the
    // failure propagates to the caller/startup path.
    try std.testing.expectError(error.WalletSmokeOpen, runInDir(io, not_a_dir));
}
