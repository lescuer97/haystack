//! Server-only BIP340 verification via Bitcoin Core libsecp256k1, no wallet API.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Pubkey = @import("sessions.zig").Pubkey;
const c = @import("secp256k1");

/// BIP340 verifies arbitrary message bytes. Callers own domain separation/hashing.
pub fn verify(xonly_key: [32]u8, message: []const u8, signature: [64]u8) bool {
    var key: c.secp256k1_xonly_pubkey = undefined;
    // The immutable static context requires no creation, heap or randomization
    // and may be shared by all verification callbacks.
    if (c.secp256k1_xonly_pubkey_parse(c.secp256k1_context_static, &key, &xonly_key) != 1) return false;
    return c.secp256k1_schnorrsig_verify(c.secp256k1_context_static, &signature, message.ptr, message.len, &key) == 1;
}

pub fn verifyAuth(compressed: [33]u8, nonce: [32]u8, signature: [64]u8) !Pubkey {
    if (compressed[0] != 2 and compressed[0] != 3) return error.InvalidAuthentication;
    var message: [51]u8 = undefined;
    @memcpy(message[0..19], "haystack/ws-auth/v1");
    @memcpy(message[19..], &nonce);
    var digest: [32]u8 = undefined;
    Sha256.hash(&message, &digest, .{});
    if (!verify(compressed[1..].*, &digest, signature)) return error.InvalidAuthentication;
    var normalized = compressed;
    normalized[0] = 2;
    return normalized;
}

test "auth domain nonce single hash and compressed identity normalization" {
    // Fixed signature fixtures use private key 1 and a nonce of 32 bytes of 7.
    var key: Pubkey = undefined;
    _ = try std.fmt.hexToBytes(&key, "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798");
    var signature: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&signature, "49eacfb328fa4897cd34d70e114b33f3f1964f0a0d36ecf0ef5719488358b61eabd2b684bff67111333304d960ff5a1dc83d9aa3a632c4b27e329fc4e47acf20");
    const nonce: [32]u8 = @splat(7);
    try std.testing.expectEqualDeep(key, try verifyAuth(key, nonce, signature));
    var opposite = key;
    opposite[0] = 3;
    try std.testing.expectEqualDeep(key, try verifyAuth(opposite, nonce, signature));
    var wrong_nonce = nonce;
    wrong_nonce[0] ^= 1;
    try std.testing.expectError(error.InvalidAuthentication, verifyAuth(key, wrong_nonce, signature));
    for ([_]u8{ 0, 1, 4, 255 }) |prefix| {
        var bad = key;
        bad[0] = prefix;
        try std.testing.expectError(error.InvalidAuthentication, verifyAuth(bad, nonce, signature));
    }
    var wrong_key = key;
    wrong_key[1] ^= 1;
    try std.testing.expectError(error.InvalidAuthentication, verifyAuth(wrong_key, nonce, signature));
    var wrong_signature = signature;
    wrong_signature[40] ^= 1;
    try std.testing.expectError(error.InvalidAuthentication, verifyAuth(key, nonce, wrong_signature));
    for ([_][]const u8{
        // Bare nonce, SHA256(SHA256(domain||nonce)), and wrong domain.
        "01cc99f65bf1c7f7a89e7449b63b56af352053009ab71af2b75988d08c13b00945fbd16613cbebeabb61e40e5cb83c3063523167d71b112164230abb596d5bfc",
        "202decad78b83544ab802e3397b38b73a700602310e47daf51cd8f0c8747e3abf366976b4471a844506d78d693f88c0e2b474dd48cc9b8895cbd9e3f69a22c2f",
        "e5593970749e3dafe282370d1221375bcb3b2a3dee613453e0e5f79ac5517f13969ffb9ba8d1a5eed2bbc1f5730ab563352f21f5df7b1f1175bf525e1b2b973d",
    }) |hex| {
        _ = try std.fmt.hexToBytes(&wrong_signature, hex);
        try std.testing.expectError(error.InvalidAuthentication, verifyAuth(key, nonce, wrong_signature));
    }
    // Hostile noncanonical field/scalar inputs and canonical zero never panic.
    wrong_key = @splat(255);
    wrong_key[0] = 2;
    try std.testing.expectError(error.InvalidAuthentication, verifyAuth(wrong_key, nonce, signature));
    wrong_signature = @splat(255);
    try std.testing.expectError(error.InvalidAuthentication, verifyAuth(key, nonce, wrong_signature));
    wrong_signature = @splat(0);
    try std.testing.expectError(error.InvalidAuthentication, verifyAuth(key, nonce, wrong_signature));
}
