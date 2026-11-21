//! Desktop-only game identity. The wallet stores the mnemonic; the worker
//! keeps the derived signing key only in memory while onboarding is cleared.
const std = @import("std");
const c = @import("secp256k1");
const wallet = @import("wallet.zig");
const AuthProof = @import("shared").protocol.AuthProof;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const key_domain = "haystack/ws-auth/secp256k1/v1";
const challenge_domain = "haystack/ws-auth/v1";

/// Owns a secret keypair in place. Never copy a loaded signer.
pub const Signer = struct {
    context: ?*c.secp256k1_context = null,
    keypair: c.secp256k1_keypair = std.mem.zeroes(c.secp256k1_keypair),
    pubkey: [33]u8 = @splat(0),

    pub fn load(self: *Signer, io: std.Io, paths: wallet.Paths) !void {
        if (self.context != null) return;
        const allocator = std.heap.page_allocator;
        // Onboarding has already verified the existing wallet. Reuse its
        // protected mnemonic reader and the existing BIP-39 conversion ABI.
        const seed = blk: {
            const phrase = try wallet.readMnemonic(io, allocator, paths);
            defer {
                std.crypto.secureZero(u8, phrase);
                allocator.free(phrase);
            }
            const phrase_z = try allocator.dupeSentinel(u8, phrase, 0);
            defer {
                std.crypto.secureZero(u8, phrase_z);
                allocator.free(phrase_z);
            }
            var result = wallet.cdk.c.cdk_mnemonic_to_seed(phrase_z.ptr);
            errdefer wallet.cdk.c.cdk_bytes_free(result.bytes);
            try wallet.check(&result);
            if (result.bytes.len != wallet.cdk.seed_len) return error.InvalidSeed;
            break :blk result.bytes;
        };
        // The existing CDK release function wipes the seed before freeing it.
        defer wallet.cdk.c.cdk_bytes_free(seed);
        try self.initFromSeed(io, seed.ptr[0..wallet.cdk.seed_len]);
    }

    fn initFromSeed(self: *Signer, io: std.Io, seed: []const u8) !void {
        std.debug.assert(self.context == null);
        errdefer self.deinit();
        const context = c.secp256k1_context_create(c.SECP256K1_CONTEXT_NONE) orelse return error.ContextCreationFailed;
        self.context = context;
        {
            var randomness: [32]u8 = undefined;
            defer std.crypto.secureZero(u8, &randomness);
            try io.randomSecure(&randomness);
            if (c.secp256k1_context_randomize(context, &randomness) != 1) return error.RandomizationFailed;
        }
        try self.deriveKeypair(context, seed);

        var pubkey: c.secp256k1_pubkey = undefined;
        if (c.secp256k1_keypair_pub(context, &pubkey, &self.keypair) != 1) return error.KeyDerivationFailed;
        var len: usize = self.pubkey.len;
        if (c.secp256k1_ec_pubkey_serialize(context, &self.pubkey, &len, &pubkey, c.SECP256K1_EC_COMPRESSED) != 1 or len != self.pubkey.len) {
            return error.KeyDerivationFailed;
        }
    }

    fn deriveKeypair(self: *Signer, context: *c.secp256k1_context, seed: []const u8) !void {
        // RFC 5869 extract and one-block expand, with an addressable HMAC
        // state we can wipe instead of passing the PRK by value.
        var prk: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &prk);
        authHmac(&prk, "haystack/wallet-key/v1", seed);
        var scalar: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &scalar);
        var input: [key_domain.len + 4 + 1]u8 = undefined;
        @memcpy(input[0..key_domain.len], key_domain);
        input[input.len - 1] = 1; // HKDF output block number.
        var counter: u32 = 0;
        while (true) {
            std.mem.writeInt(u32, input[key_domain.len..][0..4], counter, .big);
            authHmac(&scalar, &prk, &input);
            if (c.secp256k1_keypair_create(context, &self.keypair, &scalar) == 1) return;
            counter = std.math.add(u32, counter, 1) catch return error.KeyDerivationFailed;
        }
    }

    pub fn sign(self: *const Signer, io: std.Io, nonce: [32]u8) !AuthProof {
        const context = self.context orelse return error.SignerNotLoaded;
        var message: [challenge_domain.len + 32]u8 = undefined;
        @memcpy(message[0..challenge_domain.len], challenge_domain);
        @memcpy(message[challenge_domain.len..], &nonce);
        var digest: [32]u8 = undefined;
        Sha256.hash(&message, &digest, .{});
        var aux: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &aux);
        try io.randomSecure(&aux);
        var proof: AuthProof = .{ .pubkey = self.pubkey, .signature = undefined };
        if (c.secp256k1_schnorrsig_sign32(context, &proof.signature, &digest, &self.keypair, &aux) != 1) return error.SigningFailed;
        return proof;
    }

    pub fn deinit(self: *Signer) void {
        // Wipe the entire opaque keypair, even after partial initialization.
        std.crypto.secureZero(u8, std.mem.asBytes(&self.keypair));
        @memset(&self.pubkey, 0);
        if (self.context) |context| c.secp256k1_context_destroy(context);
        self.context = null;
    }
};

fn expectCleared(signer: *const Signer) !void {
    try std.testing.expect(signer.context == null);
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&signer.keypair), 0));
    try std.testing.expect(std.mem.allEqual(u8, &signer.pubkey, 0));
    try std.testing.expectError(error.SignerNotLoaded, signer.sign(std.testing.io, @splat(7)));
}

test "signer wipes partial state when initialization fails" {
    var signer: Signer = .{};
    defer signer.deinit();
    @memset(std.mem.asBytes(&signer.keypair), 0xa5);
    @memset(&signer.pubkey, 0xa5);
    const seed: [64]u8 = @splat(1);
    // The entropy error occurs after allocating the context and must clean it up.
    try std.testing.expectError(error.EntropyUnavailable, signer.initFromSeed(std.Io.failing, &seed));
    try expectCleared(&signer);
}

fn authHmac(out: *[32]u8, key: []const u8, message: []const u8) void {
    var state = Hmac.init(key);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&state));
    state.update(message);
    state.final(out);
}

test "game identity is stable and signs exactly the server challenge" {
    const t = std.testing;
    var signer: Signer = .{};
    defer signer.deinit();
    const seed: [64]u8 = @splat(1);
    try signer.initFromSeed(t.io, &seed);
    const proof = try signer.sign(t.io, @splat(7));
    var key_bytes: [33]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key_bytes, "020d82abed9ad0b47627a01df67bd14cdfb824669562b37b967c9b58181436eb87");
    try t.expectEqual(key_bytes, proof.pubkey);

    const verify_ctx = c.secp256k1_context_static;
    var xonly: c.secp256k1_xonly_pubkey = undefined;
    try t.expectEqual(1, c.secp256k1_xonly_pubkey_parse(verify_ctx, &xonly, proof.pubkey[1..].ptr));
    var challenge: [51]u8 = @splat(7);
    @memcpy(challenge[0..19], "haystack/ws-auth/v1");
    var digest: [32]u8 = undefined;
    Sha256.hash(&challenge, &digest, .{});
    try t.expectEqual(1, c.secp256k1_schnorrsig_verify(verify_ctx, &proof.signature, &digest, digest.len, &xonly));
    challenge[50] = 8;
    Sha256.hash(&challenge, &digest, .{});
    try t.expectEqual(0, c.secp256k1_schnorrsig_verify(verify_ctx, &proof.signature, &digest, digest.len, &xonly));

    try t.expect(!std.mem.allEqual(u8, std.mem.asBytes(&signer.keypair), 0));
    signer.deinit();
    try expectCleared(&signer);
    signer.deinit();
    try expectCleared(&signer);
    try signer.initFromSeed(t.io, &seed);
    try t.expectEqual(proof.pubkey, (try signer.sign(t.io, @splat(8))).pubkey);
}
