//! C-ABI consumer test: exercises the vendored `cdk-wallet-ffi` library through
//! the generated C header, from Zig, exactly as an external caller would.
//!
//! These tests do not touch the network. They cover the ABI lifecycle (open /
//! list / close), the error statuses for invalid input, the live-handle lock,
//! the Rust-owned free helpers, the OS-secure seed entropy path, and the
//! BIP-39 mnemonic generation / entropy / seed helpers.
const std = @import("std");
const cdk = @import("cdk");
const wallet = @import("wallet.zig");

const c = cdk.c;

/// Free an optional Rust-owned error string returned by the ABI.
fn freeError(err: ?[*:0]u8) void {
    if (err) |e| c.cdk_string_free(e);
}

/// Free the Rust-owned per-mint recovery-report vector returned by
/// `cdk_wallet_open`. It is empty for a fresh database, but must still be
/// released so the ABI's ownership contract holds for every open result.
fn freeReports(reports: c.Vec_CdkMintRecovery_t) void {
    c.cdk_recovery_reports_free(reports);
}

/// Build `.zig-cache/tmp/<sub_path>/wallet.sqlite` as a NUL-terminated path in
/// `buf`.
///
/// `std.testing.tmpDir` creates its directory relative to the process working
/// directory, and the Rust library resolves relative paths against that same
/// working directory, so a relative path points at the same file for both.
fn walletPath(tmp: *std.testing.TmpDir, buf: []u8) [:0]const u8 {
    const prefix = ".zig-cache/tmp/";
    const suffix = "/wallet.sqlite";
    var i: usize = 0;
    @memcpy(buf[i..][0..prefix.len], prefix);
    i += prefix.len;
    @memcpy(buf[i..][0..tmp.sub_path.len], &tmp.sub_path);
    i += tmp.sub_path.len;
    @memcpy(buf[i..][0..suffix.len], suffix);
    i += suffix.len;
    buf[i] = 0;
    return buf[0..i :0];
}

test "wallet helper opens and closes an FFI wallet" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = walletPath(&tmp, &path_buf);
    const seed: [cdk.seed_len]u8 = @splat(7);
    var opened = try wallet.createWallet(&seed, path);
    defer opened.close() catch {};
    try std.testing.expect(!opened.closed);
    try opened.close();
    try std.testing.expect(opened.closed);
    try opened.close();
}

test "C ABI lifecycle: open, list, lock, close, reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = walletPath(&tmp, &path_buf);

    // A seed that is not exactly 64 bytes is rejected up front.
    const short_seed: [63]u8 = @splat(0);
    var bad = c.cdk_wallet_open(cdk.byteSlice(&short_seed), path.ptr);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_INVALID_SEED), bad.status);
    try std.testing.expect(bad.handle == null);
    try std.testing.expectError(error.CdkFailure, wallet.check(&bad));
    try std.testing.expect(bad.@"error" == null);
    freeReports(bad.reports);

    // A valid open returns an initialized handle.
    const seed: [64]u8 = @splat(7);
    var opened = c.cdk_wallet_open(cdk.byteSlice(&seed), path.ptr);
    try wallet.check(&opened);
    try std.testing.expect(opened.@"error" == null);
    // A fresh database has no approved mints, so startup recovery reports
    // nothing. The vector is owned and must be freed with the matching helper.
    try std.testing.expectEqual(@as(usize, 0), opened.reports.len);
    freeReports(opened.reports);
    const handle: ?*c.CdkWallet_t = opened.handle;
    try std.testing.expect(handle != null);

    // A freshly created database has no approved mints and no balances.
    const mints = c.cdk_wallet_list_mints(handle);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), mints.status);
    try std.testing.expectEqual(@as(usize, 0), mints.mints.len);
    c.cdk_mint_list_free(mints.mints);
    freeError(mints.@"error");

    const balances = c.cdk_wallet_list_balances(handle);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), balances.status);
    try std.testing.expectEqual(@as(usize, 0), balances.balances.len);
    c.cdk_balance_list_free(balances.balances);
    freeError(balances.@"error");

    // A second live handle over the same file is refused.
    const again = c.cdk_wallet_open(cdk.byteSlice(&seed), path.ptr);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_ALREADY_OPEN), again.status);
    try std.testing.expect(again.handle == null);
    freeError(again.@"error");
    freeReports(again.reports);

    // Closing is idempotent-ish: a real handle and a NULL handle both succeed.
    const closed = c.cdk_wallet_close(handle);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), closed.status);
    freeError(closed.@"error");

    const null_close = c.cdk_wallet_close(null);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), null_close.status);
    freeError(null_close.@"error");

    // Once closed the advisory lock is released, so reopening works.
    const reopened = c.cdk_wallet_open(cdk.byteSlice(&seed), path.ptr);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), reopened.status);
    freeError(reopened.@"error");
    freeReports(reopened.reports);
    const reopened_handle: ?*c.CdkWallet_t = reopened.handle;
    try std.testing.expect(reopened_handle != null);
    _ = c.cdk_wallet_close(reopened_handle);
}

test "C ABI rejects a NULL handle and invalid arguments without panicking" {
    // NULL handle on every handle-taking entry point.
    const url = "https://mint.example.com";
    const add = c.cdk_wallet_add_mint(null, url.ptr);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_NULL_ARGUMENT), add.status);
    freeError(add.@"error");

    const send = c.cdk_wallet_send(null, url.ptr, 1, 0);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_NULL_ARGUMENT), send.status);
    freeError(send.@"error");

    const recv = c.cdk_wallet_receive(null, "cashuBo2F0".ptr);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_NULL_ARGUMENT), recv.status);
    freeError(recv.@"error");

    // A NULL database path is an invalid argument, not a crash.
    const seed: [64]u8 = @splat(1);
    const bad_path = c.cdk_wallet_open(cdk.byteSlice(&seed), null);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_NULL_ARGUMENT), bad_path.status);
    try std.testing.expect(bad_path.handle == null);
    freeError(bad_path.@"error");
    freeReports(bad_path.reports);

    // A NULL seed slice is rejected before any path handling. The path is a
    // test-owned relative path and is never created.
    const null_seed: c.slice_ref_uint8_t = .{ .ptr = null, .len = 0 };
    const bad_seed = c.cdk_wallet_open(null_seed, ".zig-cache/tmp/never-created.sqlite".ptr);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_NULL_ARGUMENT), bad_seed.status);
    try std.testing.expect(bad_seed.handle == null);
    freeError(bad_seed.@"error");
    freeReports(bad_seed.reports);
}

test "C ABI rejects a non-loopback plain-http mint URL before any network use" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = walletPath(&tmp, &path_buf);

    const seed: [64]u8 = @splat(9);
    const opened = c.cdk_wallet_open(cdk.byteSlice(&seed), path.ptr);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), opened.status);
    freeError(opened.@"error");
    freeReports(opened.reports);
    const handle: ?*c.CdkWallet_t = opened.handle;
    defer _ = c.cdk_wallet_close(handle);

    // Plain http off-loopback violates the URL policy and must be rejected
    // locally, without attempting to contact the mint.
    const add = c.cdk_wallet_add_mint(handle, "http://mint.example.com".ptr);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_INVALID_MINT_URL), add.status);
    try std.testing.expect(add.@"error" != null);
    freeError(add.@"error");

    // A NULL operation-id slice is rejected rather than dereferenced.
    const null_id: c.slice_ref_uint8_t = .{ .ptr = null, .len = 0 };
    const pending = c.cdk_wallet_get_pending_token(handle, null_id);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_NULL_ARGUMENT), pending.status);
    freeError(pending.@"error");
}

test "C ABI: documented result-handling idioms compile and behave" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = walletPath(&tmp, &path_buf);

    const seed: [64]u8 = @splat(3);
    const opened = c.cdk_wallet_open(cdk.byteSlice(&seed), path.ptr);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), opened.status);
    freeError(opened.@"error");
    freeReports(opened.reports);
    const handle: ?*c.CdkWallet_t = opened.handle;
    defer _ = c.cdk_wallet_close(handle);

    // Sending from an unregistered mint fails locally (no network), and the
    // documented switch/free idiom must compile.
    const sent = c.cdk_wallet_send(handle, "https://mint.example.com".ptr, 1000, 5);
    defer if (sent.@"error") |e| c.cdk_string_free(e);
    switch (sent.status) {
        c.CDK_STATUS_OK => {
            if (sent.token) |token| c.cdk_string_free(token);
        },
        c.CDK_STATUS_MINT_NOT_REGISTERED => {},
        c.CDK_STATUS_FEE_LIMIT_EXCEEDED => {},
        c.CDK_STATUS_SEND_UNCERTAIN => {},
        else => {},
    }
    try std.testing.expectEqual(
        @as(c.CdkStatus_t, c.CDK_STATUS_MINT_NOT_REGISTERED),
        sent.status,
    );
}

test "C ABI: OS-secure seed entropy opens and reopens a wallet" {
    // Exercises the secure-entropy path plus FFI integration (not entropy
    // quality): `std.testing.io` is the real Io.Threaded runtime, so
    // `randomSecure` makes a fresh OS syscall with no fallback. If entropy is
    // unavailable, `try` fails the test; it is never skipped.
    var seed: [cdk.seed_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    try std.testing.io.randomSecure(&seed);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = walletPath(&tmp, &path_buf);

    // Create a new wallet from the OS seed, then close it successfully.
    {
        const opened = c.cdk_wallet_open(cdk.byteSlice(&seed), path.ptr);
        // Register cleanup before asserting so a failure still frees the
        // Rust-owned payloads and closes the handle.
        defer freeError(opened.@"error");
        defer freeReports(opened.reports);
        defer if (opened.handle) |h| {
            const closed = c.cdk_wallet_close(h);
            freeError(closed.@"error");
        };
        try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), opened.status);
        try std.testing.expect(opened.handle != null);
    }

    // Reopening the same path with the same seed succeeds: the advisory lock was
    // released and the stored fingerprint matches.
    {
        const reopened = c.cdk_wallet_open(cdk.byteSlice(&seed), path.ptr);
        defer freeError(reopened.@"error");
        defer freeReports(reopened.reports);
        defer if (reopened.handle) |h| {
            const closed = c.cdk_wallet_close(h);
            freeError(closed.@"error");
        };
        try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), reopened.status);
        try std.testing.expect(reopened.handle != null);
    }

    // A different seed over the same database is rejected while no handle is
    // open.
    var flipped = seed;
    flipped[0] ^= 0x01;
    defer std.crypto.secureZero(u8, &flipped);
    const mismatched = c.cdk_wallet_open(cdk.byteSlice(&flipped), path.ptr);
    defer freeError(mismatched.@"error");
    defer freeReports(mismatched.reports);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_SEED_MISMATCH), mismatched.status);
    try std.testing.expect(mismatched.handle == null);
}

test "C ABI: mnemonic generate -> entropy/seed -> open and reopen a wallet" {
    // A freshly generated 12-word English phrase round-trips through the BIP-39
    // helpers, and its derived 64-byte seed opens a real wallet through the C
    // ABI. The phrase is never printed or written to disk.
    const generated = c.cdk_generate_mnemonic();
    // Register cleanup before asserting: both are safe no-ops when NULL.
    defer freeError(generated.@"error");
    defer c.cdk_string_free(generated.value);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), generated.status);
    try std.testing.expect(generated.value != null);

    // Count the words without printing the phrase (a 12-word phrase is expected).
    var word_count: usize = 0;
    {
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(generated.value)));
        var words = std.mem.tokenizeScalar(u8, text, ' ');
        while (words.next()) |_| word_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 12), word_count);

    // 12 words -> 16 bytes of raw entropy.
    const entropy = c.cdk_mnemonic_to_entropy(generated.value);
    defer freeError(entropy.@"error");
    defer c.cdk_bytes_free(entropy.bytes);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), entropy.status);
    try std.testing.expectEqual(@as(usize, 16), entropy.bytes.len);

    // -> always a 64-byte wallet seed.
    const derived = c.cdk_mnemonic_to_seed(generated.value);
    defer freeError(derived.@"error");
    defer c.cdk_bytes_free(derived.bytes);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), derived.status);
    try std.testing.expectEqual(@as(usize, cdk.seed_len), derived.bytes.len);

    // Copy the derived seed out so the wallet calls do not depend on the ABI
    // payload's lifetime; the copy is scrubbed on exit.
    var seed: [cdk.seed_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    @memcpy(&seed, derived.bytes.ptr[0..cdk.seed_len]);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = walletPath(&tmp, &path_buf);

    // Open a new wallet from the mnemonic-derived seed, then close it.
    {
        const opened = c.cdk_wallet_open(cdk.byteSlice(&seed), path.ptr);
        defer freeError(opened.@"error");
        defer freeReports(opened.reports);
        defer if (opened.handle) |h| {
            const closed = c.cdk_wallet_close(h);
            freeError(closed.@"error");
        };
        try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), opened.status);
        try std.testing.expect(opened.handle != null);
    }

    // Re-derive the seed from the same phrase and reopen the same path: the
    // lock was released and the stored fingerprint matches.
    {
        const again = c.cdk_mnemonic_to_seed(generated.value);
        defer freeError(again.@"error");
        defer c.cdk_bytes_free(again.bytes);
        try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), again.status);
        try std.testing.expectEqual(@as(usize, cdk.seed_len), again.bytes.len);

        // The same phrase must derive the same seed (determinism, not an
        // entropy-quality claim). Copy it out and scrub the copy on exit.
        var seed2: [cdk.seed_len]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed2);
        @memcpy(&seed2, again.bytes.ptr[0..cdk.seed_len]);
        try std.testing.expectEqualSlices(u8, &seed, &seed2);

        const reopened = c.cdk_wallet_open(cdk.byteSlice(&seed2), path.ptr);
        defer freeError(reopened.@"error");
        defer freeReports(reopened.reports);
        defer if (reopened.handle) |h| {
            const closed = c.cdk_wallet_close(h);
            freeError(closed.@"error");
        };
        try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), reopened.status);
        try std.testing.expect(reopened.handle != null);
    }

    // NULL and non-BIP-39 input are rejected with an empty payload.
    const null_entropy = c.cdk_mnemonic_to_entropy(null);
    defer freeError(null_entropy.@"error");
    defer c.cdk_bytes_free(null_entropy.bytes);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_NULL_ARGUMENT), null_entropy.status);

    const bad_seed = c.cdk_mnemonic_to_seed("not a bip39 phrase");
    defer freeError(bad_seed.@"error");
    defer c.cdk_bytes_free(bad_seed.bytes);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_INVALID_ARGUMENT), bad_seed.status);
    try std.testing.expectEqual(@as(usize, 0), bad_seed.bytes.len);
}

test "spilman keypair, ECDH channel secret, and tweaked schnorr signing over C ABI" {
    // Two fresh keypairs, each with a secret key and its public key.
    const alice = c.cdk_spilman_generate_keypair();
    defer freeError(alice.@"error");
    defer c.cdk_string_free(alice.secret_key_hex);
    defer c.cdk_string_free(alice.pubkey_hex);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), alice.status);
    try std.testing.expect(alice.secret_key_hex != null);
    try std.testing.expect(alice.pubkey_hex != null);

    const charlie = c.cdk_spilman_generate_keypair();
    defer freeError(charlie.@"error");
    defer c.cdk_string_free(charlie.secret_key_hex);
    defer c.cdk_string_free(charlie.pubkey_hex);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), charlie.status);

    // The standalone pubkey helper agrees with the keypair helper.
    const derived = c.cdk_spilman_secret_key_to_pubkey(alice.secret_key_hex);
    defer freeError(derived.@"error");
    defer c.cdk_string_free(derived.value);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), derived.status);
    try std.testing.expect(derived.value != null);
    try std.testing.expectEqualStrings(
        std.mem.span(@as([*:0]const u8, @ptrCast(alice.pubkey_hex))),
        std.mem.span(@as([*:0]const u8, @ptrCast(derived.value))),
    );

    // ECDH is symmetric: both sides derive the same 32-byte channel secret.
    const from_alice =
        c.cdk_spilman_compute_channel_secret(alice.secret_key_hex, charlie.pubkey_hex);
    defer freeError(from_alice.@"error");
    defer c.cdk_string_free(from_alice.value);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), from_alice.status);

    const from_charlie =
        c.cdk_spilman_compute_channel_secret(charlie.secret_key_hex, alice.pubkey_hex);
    defer freeError(from_charlie.@"error");
    defer c.cdk_string_free(from_charlie.value);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), from_charlie.status);

    const alice_secret_hex = std.mem.span(@as([*:0]const u8, @ptrCast(from_alice.value)));
    const charlie_secret_hex = std.mem.span(@as([*:0]const u8, @ptrCast(from_charlie.value)));
    try std.testing.expectEqualStrings(alice_secret_hex, charlie_secret_hex);
    try std.testing.expectEqual(@as(usize, 64), alice_secret_hex.len);

    // A tweaked BIP-340 signature over a 32-byte digest is 64 bytes -> 128 hex.
    const message = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    const tweak = "0101010101010101010101010101010101010101010101010101010101010101";
    const signed =
        c.cdk_spilman_sign_with_tweaked_key_util(alice.secret_key_hex, message.ptr, tweak.ptr);
    defer freeError(signed.@"error");
    defer c.cdk_string_free(signed.value);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), signed.status);
    try std.testing.expectEqual(
        @as(usize, 128),
        std.mem.len(@as([*:0]const u8, @ptrCast(signed.value))),
    );

    // NULL secret-key input is rejected without dereferencing.
    const null_key = c.cdk_spilman_secret_key_to_pubkey(null);
    defer freeError(null_key.@"error");
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_NULL_ARGUMENT), null_key.status);
}

test "cdk + spilman integration: token/proof conversion, channel id, and funding outputs over C ABI" {
    // One keyset key per amount, produced by the library itself so the keyset
    // JSON carries real secp256k1 public keys rather than placeholders.
    const key1 = c.cdk_spilman_generate_keypair();
    defer freeError(key1.@"error");
    defer c.cdk_string_free(key1.secret_key_hex);
    defer c.cdk_string_free(key1.pubkey_hex);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), key1.status);

    const key2 = c.cdk_spilman_generate_keypair();
    defer freeError(key2.@"error");
    defer c.cdk_string_free(key2.secret_key_hex);
    defer c.cdk_string_free(key2.pubkey_hex);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), key2.status);

    const key1_pub = std.mem.span(@as([*:0]const u8, @ptrCast(key1.pubkey_hex)));
    const key2_pub = std.mem.span(@as([*:0]const u8, @ptrCast(key2.pubkey_hex)));

    // A two-denomination keyset (1 and 2 sats) with no input fee. The amount is
    // exactly representable, so no fee math distorts the expectations below.
    var keyset_buf: [1024]u8 = undefined;
    const keyset_json = try std.mem.printSentinel(
        &keyset_buf,
        "{{\"keysetId\":\"009a1f293253e41e\",\"unit\":\"sat\"," ++
            "\"keys\":{{\"1\":\"{s}\",\"2\":\"{s}\"}},\"amounts\":[1,2],\"inputFeePpk\":0}}",
        .{ key1_pub, key2_pub },
        0,
    );

    // With amounts [1,2] and input_fee_ppk 0, a capacity of 3 sats needs exactly
    // 3 sats of funding-token nominal.
    const funding = c.cdk_spilman_compute_funding_token_amount(3, keyset_json.ptr, 64);
    defer freeError(funding.@"error");
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), funding.status);
    try std.testing.expectEqual(@as(u64, 3), funding.net_sats);

    // Alice sends, Charlie receives; ECDH gives both sides the same 32-byte
    // channel secret.
    const alice = c.cdk_spilman_generate_keypair();
    defer freeError(alice.@"error");
    defer c.cdk_string_free(alice.secret_key_hex);
    defer c.cdk_string_free(alice.pubkey_hex);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), alice.status);

    const charlie = c.cdk_spilman_generate_keypair();
    defer freeError(charlie.@"error");
    defer c.cdk_string_free(charlie.secret_key_hex);
    defer c.cdk_string_free(charlie.pubkey_hex);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), charlie.status);

    const alice_pub = std.mem.span(@as([*:0]const u8, @ptrCast(alice.pubkey_hex)));
    const charlie_pub = std.mem.span(@as([*:0]const u8, @ptrCast(charlie.pubkey_hex)));

    const channel_secret =
        c.cdk_spilman_compute_channel_secret(alice.secret_key_hex, charlie.pubkey_hex);
    defer freeError(channel_secret.@"error");
    defer c.cdk_string_free(channel_secret.value);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), channel_secret.status);
    const channel_secret_hex =
        std.mem.span(@as([*:0]const u8, @ptrCast(channel_secret.value)));
    try std.testing.expectEqual(@as(usize, 64), channel_secret_hex.len);

    // Channel parameters matching the funding-token amount computed above.
    var params_buf: [1024]u8 = undefined;
    const params_json = try std.mem.printSentinel(
        &params_buf,
        "{{\"sender_pubkey\":\"{s}\",\"receiver_pubkey\":\"{s}\"," ++
            "\"mint\":\"https://mint.example.com\",\"unit\":\"sat\",\"capacity\":3," ++
            "\"funding_token_amount\":3,\"maximum_amount\":64,\"expiry_timestamp\":1800000000," ++
            "\"setup_timestamp\":1700000000,\"keyset_id\":\"009a1f293253e41e\"," ++
            "\"input_fee_ppk\":0}}",
        .{ alice_pub, charlie_pub },
        0,
    );

    // The channel id is the SHA-256 of the canonical parameter encoding: 32
    // bytes -> 64 hex characters.
    const channel_id = c.cdk_spilman_channel_parameters_get_channel_id(
        params_json.ptr,
        channel_secret_hex.ptr,
        keyset_json.ptr,
    );
    defer freeError(channel_id.@"error");
    defer c.cdk_string_free(channel_id.value);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), channel_id.status);
    const channel_id_hex = std.mem.span(@as([*:0]const u8, @ptrCast(channel_id.value)));
    try std.testing.expectEqual(@as(usize, 64), channel_id_hex.len);
    for (channel_id_hex) |ch| try std.testing.expect(std.ascii.isHex(ch));

    // The sender builds the funding outputs: blinded messages for the mint plus
    // the secrets/blinding factors needed to unblind the signatures later.
    const outputs = c.cdk_spilman_create_funding_outputs(
        params_json.ptr,
        alice.secret_key_hex,
        keyset_json.ptr,
    );
    defer freeError(outputs.@"error");
    defer c.cdk_string_free(outputs.value);
    try std.testing.expectEqual(@as(c.CdkStatus_t, c.CDK_STATUS_OK), outputs.status);

    const outputs_json = std.mem.span(@as([*:0]const u8, @ptrCast(outputs.value)));
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, outputs_json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqual(@as(i64, 3), obj.get("funding_token_nominal").?.integer);
    const blinded = obj.get("blinded_messages").?.array.items;
    const secrets = obj.get("secrets_with_blinding").?.array.items;
    try std.testing.expect(blinded.len > 0);
    try std.testing.expect(secrets.len > 0);
    // Each blinded message has the shape the mint expects.
    for (blinded) |msg| {
        _ = msg.object.get("amount") orelse return error.MissingField;
        _ = msg.object.get("id") orelse return error.MissingField;
        _ = msg.object.get("B_") orelse return error.MissingField;
    }
    // Each secret carries the matching blinding factor and amount.
    for (secrets) |sec| {
        _ = sec.object.get("secret") orelse return error.MissingField;
        _ = sec.object.get("blinding_factor") orelse return error.MissingField;
        _ = sec.object.get("amount") orelse return error.MissingField;
    }
}
