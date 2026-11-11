// Native negative-path checks for the Spilman helpers.
//
// Every operation still runs through the Rust bindings; this module only
// supplies malformed inputs and asserts the status/error contract. It never
// reads, persists, or logs seeds and must not echo bearer material back.
const flip = hex => hex.slice(0, -1) + (hex.endsWith("0") ? "1" : "0");

export async function runSpilmanNegatives({app, pure, text, assert, v}) {
  const keyset = v.keyset_json;
  const params = v.params_json;
  const proofs = v.funding_proofs_json;
  const raw = (name, args) => app.pure(name, args);

  async function expectStatus(name, args, code, label) {
    let response;
    try {
      response = await raw(name, args);
    } catch (error) {
      throw new Error(`${label}: adapter threw instead of returning status ${code}: ${error.message || error}`);
    }
    assert(response.status === code, `${label} (expected status ${code}, got ${response.status})`);
    return response;
  }

  async function expectThrown(name, args, label, mention) {
    let message = null;
    try { await raw(name, args); } catch (error) { message = String(error.message || error); }
    assert(message !== null, label);
    if (mention) assert(message.includes(mention), `${label} (diagnostic mentions ${mention})`);
    return message;
  }

  const noLeak = (response, needle, label) =>
    assert(!String(response.error || "").includes(needle), label);

  // --- Balance updates: signatures, channel id, capacity -------------------
  const signed = JSON.parse(await text("spilman_create_signed_balance_update", [params, keyset, v.alice_secret, proofs, "70"]));

  await expectStatus(
    "spilman_verify_balance_update",
    [params, v.channel_secret, keyset, proofs, signed.channel_id, "70", flip(signed.signature)],
    2,
    "Changed balance-update signature is rejected",
  );
  await expectStatus(
    "spilman_verify_balance_update",
    [params, v.channel_secret, keyset, proofs, "0".repeat(64), "70", signed.signature],
    2,
    "Valid-length but wrong channel id is rejected",
  );
  await expectStatus(
    "spilman_verify_balance_update",
    [params, v.channel_secret, keyset, proofs, signed.channel_id, "101", signed.signature],
    2,
    "Balance above channel capacity is rejected",
  );

  // --- Cooperative close: sender signature, receiver key, capacity ---------
  const close = JSON.parse(await text("spilman_prepare_close_swap", [
    params, v.channel_secret, keyset, keyset, proofs, "70", signed.signature, v.charlie_secret,
  ]));
  const secrets = JSON.stringify(close.secrets_with_blinding);
  const closeArgs = response => [
    params, v.channel_secret, keyset, keyset, secrets, response, "70", v.charlie_secret,
  ];

  const other = await pure("spilman_generate_keypair");
  await expectStatus(
    "spilman_prepare_close_swap",
    [params, v.channel_secret, keyset, keyset, proofs, "70", flip(signed.signature), v.charlie_secret],
    2,
    "Close with a wrong sender signature is rejected",
  );
  await expectStatus(
    "spilman_prepare_close_swap",
    [params, v.channel_secret, keyset, keyset, proofs, "70", signed.signature, other.secret_key_hex],
    2,
    "Close with an unrelated receiver key is rejected",
  );
  await expectStatus(
    "spilman_prepare_close_swap",
    [params, v.channel_secret, keyset, keyset, proofs, "101", signed.signature, v.charlie_secret],
    2,
    "Close above channel capacity is rejected",
  );

  // --- Tampered live-format close responses --------------------------------
  const tamper = mode => {
    const response = JSON.parse(JSON.stringify(v.responses.close));
    const first = response.signatures[0];
    if (mode === "flip_c") first.C_ = flip(first.C_);
    else if (mode === "drop_signature") response.signatures.pop();
    else if (mode === "change_amount") first.amount = first.amount === 1 ? 2 : 1;
    else if (mode === "flip_e") first.dleq.e = flip(first.dleq.e);
    return JSON.stringify(response);
  };
  for (const mode of ["flip_c", "drop_signature", "change_amount", "flip_e"]) {
    const response = await expectStatus(
      "spilman_unblind_close_swap",
      closeArgs(tamper(mode)),
      2,
      `Tampered close response is rejected (${mode})`,
    );
    assert(response.receiver_proofs_json == null && response.sender_proofs_json == null,
      `Tampered close response yields no partial proofs (${mode})`);
    noLeak(response, "P2PK", `Tampered close response does not echo proof secrets (${mode})`);
  }
  const malformedClose = await expectStatus(
    "spilman_unblind_close_swap",
    closeArgs("{"),
    2,
    "Malformed close-response JSON is rejected",
  );
  assert(malformedClose.receiver_proofs_json == null, "Malformed close response yields no receiver proofs");

  // --- Malformed keys, hex, JSON and tokens --------------------------------
  await expectStatus("spilman_secret_key_to_pubkey", ["zz".repeat(32)], 2, "Non-hex secret key is rejected");
  await expectStatus("spilman_secret_key_to_pubkey", [v.alice_secret.slice(0, -2)], 2, "Short secret key is rejected");
  await expectStatus("spilman_secret_key_to_pubkey", [v.alice_secret + "00"], 2, "Long secret key is rejected");
  const badPub = await expectStatus(
    "spilman_compute_channel_secret",
    [v.alice_secret, "deadbeef"],
    2,
    "Malformed public key is rejected",
  );
  noLeak(badPub, "deadbeef", "Malformed public-key error does not echo the input");

  await expectStatus("spilman_create_funding_outputs", ["{", v.alice_secret, keyset], 2, "Malformed channel-parameter JSON is rejected");
  await expectStatus("spilman_verify_valid_channel", [params, v.channel_secret, keyset, "{"], 2, "Malformed funding-proof JSON is rejected");

  const junkToken = "junk-SECRETMARKER";
  const badToken = await expectStatus("token_to_proofs_json", [junkToken, keyset], 2, "Junk Cashu token is rejected");
  noLeak(badToken, "SECRETMARKER", "Junk-token error does not echo the token");
  const badChannelToken = await expectStatus(
    "spilman_compute_channel_from_token",
    [junkToken, v.charlie_pubkey, v.alice_pubkey, v.channel_secret, String(v.expiry_timestamp), keyset, "64"],
    2,
    "Junk token cannot derive channel parameters",
  );
  noLeak(badChannelToken, "SECRETMARKER", "Junk channel-token error does not echo the token");

  const message = "00".repeat(32);
  await expectStatus(
    "spilman_sign_with_tweaked_key_util",
    [v.alice_secret, message, "11".repeat(33)],
    2,
    "33-byte tweak scalar is rejected",
  );
  await expectStatus(
    "spilman_sign_with_tweaked_key_util",
    [v.alice_secret, "00".repeat(31), "11".repeat(32)],
    2,
    "31-byte message digest is rejected",
  );

  // --- Channel verification must redact a mismatched proof secret ----------
  const leaky = JSON.parse(proofs);
  leaky[0].secret = "LEAKME-64";
  const leakyResponse = await expectStatus(
    "spilman_verify_valid_channel",
    [params, v.channel_secret, keyset, JSON.stringify(leaky)],
    2,
    "Proof-secret mismatch fails channel verification",
  );
  noLeak(leakyResponse, "LEAKME", "Channel-verification error redacts proof secrets");
  noLeak(leakyResponse, v.channel_secret, "Channel-verification error does not echo the channel secret");

  // --- Refund boundary and sender identity ---------------------------------
  // Build the expired channel's own funding proofs: the live-format funding
  // fixture decrypts deterministically from params_expired_json.
  const synth = JSON.stringify([64, 32, 4].map(amount => ({
    amount, id: v.keyset_id, secret: `negative-input-${amount}`, C: JSON.parse(keyset).keys["1"],
  })));
  const expiredPrepared = JSON.parse(await text("spilman_create_funding_swap", [
    v.params_expired_json, v.channel_secret, keyset, synth,
  ]));
  const expiredCompleted = JSON.parse(await text("spilman_complete_funding_swap", [
    JSON.stringify(v.responses.funding_expired), expiredPrepared.funding_secrets_json, keyset,
  ]));
  const refundFunding = expiredCompleted.funding_proofs_json;
  const refundExpiry = String(v.refund_expiry_timestamp);
  await expectStatus(
    "spilman_prepare_sender_refund",
    [v.params_expired_json, v.channel_secret, keyset, keyset, refundFunding, v.alice_secret, refundExpiry, null],
    2,
    "Refund at exactly the expiry timestamp is rejected",
  );
  await expectStatus(
    "spilman_prepare_sender_refund",
    [v.params_expired_json, v.channel_secret, keyset, keyset, refundFunding, other.secret_key_hex, String(v.refund_now), null],
    2,
    "Refund signed by an unrelated sender key is rejected",
  );

  // --- Required null arguments are a status, not an adapter throw ----------
  const nullKey = await expectStatus(
    "spilman_secret_key_to_pubkey",
    [null],
    1,
    "Required null secret key reports NullArgument",
  );
  assert(nullKey.value == null, "Null-argument failure carries no payload");
  await expectStatus(
    "spilman_create_funding_outputs",
    [null, v.alice_secret, keyset],
    1,
    "Required null channel parameters report NullArgument",
  );

  // --- Adapter argument errors are thrown, distinct from status errors -----
  await expectThrown(
    "spilman_secret_key_to_pubkey",
    [],
    "Missing argument throws at the adapter boundary",
    "missing argument",
  );
  await expectThrown(
    "spilman_secret_key_to_pubkey",
    [5],
    "Non-string argument throws at the adapter boundary",
    "JSON array of strings",
  );
  await expectThrown(
    "spilman_secret_key_to_pubkey",
    [`${v.alice_secret.slice(0, 10)}\u0000${v.alice_secret.slice(10)}`],
    "NUL in an argument throws at the adapter boundary",
    "NUL",
  );
}
