//! Deterministic wire fixtures shared with the Zig C-ABI test suite.
//!
//! The Zig tests reimplement nothing: they replay real mint responses produced
//! by this module through the same `#[ffi_export]` entry points the Zig
//! application calls. That makes the fixtures a provenance record of the
//! upstream `cdk-spilman` derivation this crate links: if an upstream change
//! alters the deterministic blinding, channel id, or DLEQ construction, the
//! drift test below fails until the file is regenerated.
//!
//! Regenerate with:
//!
//! ```text
//! CDK_SPILMAN_WRITE_FIXTURES=1 \
//!   cargo +stable test --locked spilman_fixture -- --nocapture
//! ```
//!
//! Everything here is deterministic:
//! * the mint keys are derived from fixed small scalars;
//! * the DLEQ nonce inside `BlindSignature::new` is HMAC-derived from the mint
//!   key and the points, not random;
//! * the channel/keyset derivations are HKDF/SHA-256 based.
//!
//! The only random value anywhere in the flow (the sender's BIP-340 balance
//! update signature) never reaches the fixture: responses are built over the
//! blinded *outputs* only.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::ptr::NonNull;

use cdk::nuts::{
    BlindSignature, BlindedMessage, CurrencyUnit, Id, Keys, Proof, PublicKey, SecretKey,
    SwapRequest, SwapResponse, Witness,
};
use cdk::Amount;
use safer_ffi::prelude::*;
use serde_json::{json, Value};

use crate::spilman;

/// Fixed sender key: `0x11..11`.
const ALICE_SECRET: &str = "1111111111111111111111111111111111111111111111111111111111111111";
/// Fixed receiver key: `0x22..22`.
const CHARLIE_SECRET: &str = "2222222222222222222222222222222222222222222222222222222222222222";
const MINT_URL: &str = "https://mint.example.com";
/// Cooperative-close channel expiry (far future).
const EXPIRY: u64 = 1_800_000_000;
/// Fixed channel setup timestamp: `compute_channel_from_token` would otherwise
/// stamp the wall clock, making the fixture non-reproducible.
const SETUP_TIMESTAMP: u64 = 1_700_000_000;
/// Post-expiry refund channel expiry and evaluation time.
const REFUND_EXPIRY: u64 = 1_000;
const REFUND_NOW: u64 = 2_000;
/// Cooperative-close balance: 70 to the receiver, 30 back to the sender.
const CLOSE_BALANCE: u64 = 70;
const DENOMINATIONS: [u64; 7] = [1, 2, 4, 8, 16, 32, 64];
/// Synthetic token value used to derive the channel: `64 + 32 + 4`.
const FUNDING_VALUE: u64 = 100;

const FIXTURE_PATH: &str = "../../src/testdata/spilman_vectors.json";

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(FIXTURE_PATH)
}

fn with_nul(s: &str) -> Vec<u8> {
    let mut bytes = s.as_bytes().to_vec();
    bytes.push(0);
    bytes
}

/// A `char_p::Ref` over a NUL-terminated buffer.
///
/// SAFETY: `bytes` must be NUL-terminated and outlive the returned reference.
fn cstr_ref(bytes: &[u8]) -> char_p::Ref<'_> {
    assert_eq!(bytes.last(), Some(&0), "cstr_ref requires a NUL terminator");
    unsafe { char_p::Ref::from_ptr_unchecked(NonNull::new(bytes.as_ptr() as *mut u8).unwrap()) }
}

/// Fixed mint denomination keys, keyed by amount.
fn mint_keys() -> BTreeMap<u64, SecretKey> {
    DENOMINATIONS
        .iter()
        .map(|amount| {
            let hex = format!("{amount:064x}");
            (*amount, SecretKey::from_hex(&hex).unwrap())
        })
        .collect()
}

fn keys(secrets: &BTreeMap<u64, SecretKey>) -> Keys {
    Keys::new(
        secrets
            .iter()
            .map(|(amount, secret)| (Amount::from(*amount), secret.public_key()))
            .collect(),
    )
}

fn keyset_json(secrets: &BTreeMap<u64, SecretKey>, id: Id) -> String {
    let keys: BTreeMap<String, String> = secrets
        .iter()
        .map(|(amount, secret)| (amount.to_string(), secret.public_key().to_hex()))
        .collect();
    json!({
        "keyset_id": id.to_string(),
        "unit": "sat",
        "keys": keys,
        "amounts": DENOMINATIONS.iter().rev().collect::<Vec<_>>(),
        "input_fee_ppk": 0,
        "final_expiry": Value::Null,
    })
    .to_string()
}

fn alice() -> SecretKey {
    SecretKey::from_hex(ALICE_SECRET).unwrap()
}

fn charlie() -> SecretKey {
    SecretKey::from_hex(CHARLIE_SECRET).unwrap()
}

/// A synthetic, structurally valid proof set worth [`FUNDING_VALUE`].
///
/// `create_funding_swap` only serializes its inputs; the mint that signs the
/// outputs is this fixture module, so no real wallet proofs are needed.
fn synthetic_proofs(secrets: &BTreeMap<u64, SecretKey>, id: Id) -> String {
    let c = secrets[&1].public_key().to_hex();
    let proofs: Vec<Value> = [64u64, 32, 4]
        .iter()
        .map(|amount| {
            json!({
                "amount": amount,
                "id": id.to_string(),
                "secret": format!("fixture-input-{amount}"),
                "C": c,
            })
        })
        .collect();
    serde_json::to_string(&proofs).unwrap()
}

fn take(result: crate::status::CdkStringResult) -> String {
    let error = result.error.as_ref().map(|e| e.to_str().to_owned());
    crate::api::cdk_string_free(result.error);
    assert_eq!(result.status, crate::status::CdkStatus::Ok, "{error:?}");
    let value = result
        .value
        .as_ref()
        .expect("string result")
        .to_str()
        .to_owned();
    crate::api::cdk_string_free(result.value);
    value
}

fn channel_secret_hex() -> String {
    let charlie_pub = charlie().public_key().to_hex();
    let (alice_nul, charlie_nul) = (with_nul(ALICE_SECRET), with_nul(&charlie_pub));
    take(spilman::cdk_spilman_compute_channel_secret(
        Some(cstr_ref(&alice_nul)),
        Some(cstr_ref(&charlie_nul)),
    ))
}

fn sign_output(
    output: &BlindedMessage,
    secrets: &BTreeMap<u64, SecretKey>,
    id: Id,
) -> BlindSignature {
    let amount = u64::from(output.amount);
    let secret = secrets
        .get(&amount)
        .unwrap_or_else(|| panic!("no denomination key for amount {amount}"));
    let c = cdk::dhke::sign_message(secret, &output.blinded_secret).unwrap();
    BlindSignature::new(output.amount, c, id, &output.blinded_secret, secret).unwrap()
}

/// Mint response over the outputs of a serialized `SwapRequest`.
fn sign_outputs(swap_request_json: &str, secrets: &BTreeMap<u64, SecretKey>, id: Id) -> Value {
    let request: SwapRequest = serde_json::from_str(swap_request_json).unwrap();
    let signatures: Vec<BlindSignature> = request
        .outputs()
        .iter()
        .map(|output| sign_output(output, secrets, id))
        .collect();
    serde_json::to_value(SwapResponse { signatures }).unwrap()
}

/// Derive canonical channel parameters from a token built out of synthetic
/// proofs, through the same FFI helper the Zig application uses.
fn channel_params(keyset: &str, secrets: &BTreeMap<u64, SecretKey>, id: Id, expiry: u64) -> String {
    let proofs = synthetic_proofs(secrets, id);
    let (mint_nul, unit_nul, proofs_nul) = (with_nul(MINT_URL), with_nul("sat"), with_nul(&proofs));
    let token = take(spilman::cdk_spilman_build_cashu_b_token(
        Some(cstr_ref(&mint_nul)),
        Some(cstr_ref(&unit_nul)),
        Some(cstr_ref(&proofs_nul)),
    ));

    let channel_secret = channel_secret_hex();
    let (token_nul, keyset_nul, secret_nul) = (
        with_nul(&token),
        with_nul(keyset),
        with_nul(&channel_secret),
    );
    let (alice_nul, charlie_nul) = (
        with_nul(&alice().public_key().to_hex()),
        with_nul(&charlie().public_key().to_hex()),
    );

    let computed = take(spilman::cdk_spilman_compute_channel_from_token(
        Some(cstr_ref(&token_nul)),
        Some(cstr_ref(&charlie_nul)),
        Some(cstr_ref(&alice_nul)),
        Some(cstr_ref(&secret_nul)),
        expiry,
        Some(cstr_ref(&keyset_nul)),
        64,
    ));
    let mut computed: Value = serde_json::from_str(&computed).unwrap();
    // Freeze the wall-clock field so the fixture (and every derived blinding,
    // channel id, and mint response) is byte-reproducible across runs.
    computed["params_json"] = Value::String({
        let mut params: Value =
            serde_json::from_str(computed["params_json"].as_str().unwrap()).unwrap();
        params["setup_timestamp"] = json!(SETUP_TIMESTAMP);
        serde_json::to_string(&params).unwrap()
    });
    computed["params_json"].as_str().unwrap().to_owned()
}

struct FundedChannel {
    params_json: String,
    funding_response: Value,
    funding_proofs_json: String,
}

fn fund(params: &str, keyset: &str, id: Id, secrets: &BTreeMap<u64, SecretKey>) -> FundedChannel {
    let channel_secret = channel_secret_hex();
    let proofs = synthetic_proofs(secrets, id);
    let (params_nul, keyset_nul, secret_nul, proofs_nul) = (
        with_nul(params),
        with_nul(keyset),
        with_nul(&channel_secret),
        with_nul(&proofs),
    );
    let funding = take(spilman::cdk_spilman_create_funding_swap(
        Some(cstr_ref(&params_nul)),
        Some(cstr_ref(&secret_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&proofs_nul)),
    ));
    let funding: Value = serde_json::from_str(&funding).unwrap();
    let swap_request_json = funding["swap_request_json"].as_str().unwrap();
    let funding_secrets_json = funding["funding_secrets_json"].as_str().unwrap();

    let response = sign_outputs(swap_request_json, secrets, id);
    let (response_nul, secrets_nul) = (
        with_nul(&response.to_string()),
        with_nul(funding_secrets_json),
    );
    let completed = take(spilman::cdk_spilman_complete_funding_swap(
        Some(cstr_ref(&response_nul)),
        Some(cstr_ref(&secrets_nul)),
        Some(cstr_ref(&keyset_nul)),
    ));
    let completed: Value = serde_json::from_str(&completed).unwrap();
    FundedChannel {
        params_json: params.to_owned(),
        funding_response: response,
        funding_proofs_json: completed["funding_proofs_json"]
            .as_str()
            .unwrap()
            .to_owned(),
    }
}

/// Build the complete fixture document.
pub(crate) fn build() -> Value {
    let secrets = mint_keys();
    let id = Id::v1_from_keys(&keys(&secrets));
    let keyset = keyset_json(&secrets, id);
    let channel_secret = channel_secret_hex();

    // Cooperative close: a live channel settled at 70/30.
    let params = channel_params(&keyset, &secrets, id, EXPIRY);
    let channel = fund(&params, &keyset, id, &secrets);

    let (params_nul, keyset_nul, alice_nul, proofs_nul) = (
        with_nul(&channel.params_json),
        with_nul(&keyset),
        with_nul(ALICE_SECRET),
        with_nul(&channel.funding_proofs_json),
    );
    let update = take(spilman::cdk_spilman_create_signed_balance_update(
        Some(cstr_ref(&params_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&alice_nul)),
        Some(cstr_ref(&proofs_nul)),
        CLOSE_BALANCE,
    ));
    let update: Value = serde_json::from_str(&update).unwrap();
    let sender_signature = with_nul(update["signature"].as_str().unwrap());

    let (secret_nul, charlie_nul) = (
        with_nul(&channel_secret),
        with_nul(&charlie().to_secret_hex()),
    );
    let prepared = take(spilman::cdk_spilman_prepare_close_swap(
        Some(cstr_ref(&params_nul)),
        Some(cstr_ref(&secret_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&proofs_nul)),
        CLOSE_BALANCE,
        Some(cstr_ref(&sender_signature)),
        Some(cstr_ref(&charlie_nul)),
    ));
    let prepared: Value = serde_json::from_str(&prepared).unwrap();
    let close_response = sign_outputs(
        &serde_json::to_string(&prepared["swap_request"]).unwrap(),
        &secrets,
        id,
    );

    // Post-expiry refund: a separate, already-expired channel.
    let expired_params = channel_params(&keyset, &secrets, id, REFUND_EXPIRY);
    let expired = fund(&expired_params, &keyset, id, &secrets);
    let (expired_nul, expired_proofs_nul) = (
        with_nul(&expired.params_json),
        with_nul(&expired.funding_proofs_json),
    );
    let prepared_refund = take(spilman::cdk_spilman_prepare_sender_refund(
        Some(cstr_ref(&expired_nul)),
        Some(cstr_ref(&secret_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&expired_proofs_nul)),
        Some(cstr_ref(&alice_nul)),
        REFUND_NOW,
        None,
    ));
    let prepared_refund: Value = serde_json::from_str(&prepared_refund).unwrap();
    let refund_response = sign_outputs(
        &serde_json::to_string(&prepared_refund["swap_request"]).unwrap(),
        &secrets,
        id,
    );

    json!({
        "note": "Generated by vendor/cdk-wallet-ffi/src/fixtures.rs. Do not edit by hand.",
        "mint_url": MINT_URL,
        "unit": "sat",
        "keyset_id": id.to_string(),
        "keyset_json": keyset,
        "mint_secret_keys": secrets
            .iter()
            .map(|(amount, secret)| (amount.to_string(), secret.to_secret_hex()))
            .collect::<BTreeMap<_, _>>(),
        "alice_secret": ALICE_SECRET,
        "alice_pubkey": alice().public_key().to_hex(),
        "charlie_secret": CHARLIE_SECRET,
        "charlie_pubkey": charlie().public_key().to_hex(),
        "channel_secret": channel_secret,
        "params_json": channel.params_json,
        "expiry_timestamp": EXPIRY,
        "funding_token_amount": FUNDING_VALUE,
        "close_balance": CLOSE_BALANCE,
        "params_expired_json": expired.params_json,
        "refund_expiry_timestamp": REFUND_EXPIRY,
        "refund_now": REFUND_NOW,
        "funding_proofs_json": channel.funding_proofs_json,
        "responses": {
            "funding": channel.funding_response,
            "close": close_response,
            "funding_expired": expired.funding_response,
            "refund": refund_response,
        },
    })
}

/// The fixture must actually replay through the same ABI the Zig suite uses:
/// this is the Rust-side validity check for the checked-in mint responses.
#[test]
fn fixture_replays_through_the_abi() {
    fn text(value: &Value, key: &str) -> String {
        value[key].as_str().unwrap().to_owned()
    }

    fn assert_ok(result: crate::status::CdkStatusResult) {
        let error = result.error.as_ref().map(|e| e.to_str().to_owned());
        crate::api::cdk_string_free(result.error);
        assert_eq!(result.status, crate::status::CdkStatus::Ok, "{error:?}");
    }

    let fixture = build();
    let params = text(&fixture, "params_json");
    let expired_params = text(&fixture, "params_expired_json");
    let keyset = text(&fixture, "keyset_json");
    let channel_secret = text(&fixture, "channel_secret");
    let funding_proofs = text(&fixture, "funding_proofs_json");
    let alice_secret = text(&fixture, "alice_secret");
    let charlie_secret = text(&fixture, "charlie_secret");
    let close_balance = fixture["close_balance"].as_u64().unwrap();
    let refund_now = fixture["refund_now"].as_u64().unwrap();
    let responses = &fixture["responses"];

    let (params_nul, expired_nul, keyset_nul, secret_nul, proofs_nul, alice_nul, charlie_nul) = (
        with_nul(&params),
        with_nul(&expired_params),
        with_nul(&keyset),
        with_nul(&channel_secret),
        with_nul(&funding_proofs),
        with_nul(&alice_secret),
        with_nul(&charlie_secret),
    );

    assert_ok(spilman::cdk_spilman_verify_valid_channel(
        Some(cstr_ref(&params_nul)),
        Some(cstr_ref(&secret_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&proofs_nul)),
    ));

    let update = take(spilman::cdk_spilman_create_signed_balance_update(
        Some(cstr_ref(&params_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&alice_nul)),
        Some(cstr_ref(&proofs_nul)),
        close_balance,
    ));
    let update: Value = serde_json::from_str(&update).unwrap();
    let sender_signature = with_nul(update["signature"].as_str().unwrap());

    let prepared = take(spilman::cdk_spilman_prepare_close_swap(
        Some(cstr_ref(&params_nul)),
        Some(cstr_ref(&secret_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&proofs_nul)),
        close_balance,
        Some(cstr_ref(&sender_signature)),
        Some(cstr_ref(&charlie_nul)),
    ));
    let prepared: Value = serde_json::from_str(&prepared).unwrap();
    let secrets = with_nul(&serde_json::to_string(&prepared["secrets_with_blinding"]).unwrap());
    let close_response = with_nul(&responses["close"].to_string());

    let closed = spilman::cdk_spilman_unblind_close_swap(
        Some(cstr_ref(&params_nul)),
        Some(cstr_ref(&secret_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&secrets)),
        Some(cstr_ref(&close_response)),
        close_balance,
        Some(cstr_ref(&charlie_nul)),
    );
    let error = closed.error.as_ref().map(|e| e.to_str().to_owned());
    crate::api::cdk_string_free(closed.error);
    assert_eq!(closed.status, crate::status::CdkStatus::Ok, "{error:?}");
    assert_eq!(closed.receiver_sum, close_balance);
    assert_eq!(closed.sender_sum, FUNDING_VALUE - close_balance);
    crate::api::cdk_string_free(closed.receiver_proofs_json);
    crate::api::cdk_string_free(closed.sender_proofs_json);

    let refund_prepared = take(spilman::cdk_spilman_prepare_sender_refund(
        Some(cstr_ref(&expired_nul)),
        Some(cstr_ref(&secret_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&proofs_nul)),
        Some(cstr_ref(&alice_nul)),
        refund_now,
        None,
    ));
    let refund_response = with_nul(&responses["refund"].to_string());
    let refund_prepared = with_nul(&refund_prepared);
    let refund = take(spilman::cdk_spilman_complete_sender_refund(
        Some(cstr_ref(&expired_nul)),
        Some(cstr_ref(&secret_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&proofs_nul)),
        Some(cstr_ref(&alice_nul)),
        Some(cstr_ref(&refund_prepared)),
        Some(cstr_ref(&refund_response)),
    ));
    let refund: Vec<Value> = serde_json::from_str(&refund).unwrap();
    assert_eq!(
        refund
            .iter()
            .map(|p| p["amount"].as_u64().unwrap())
            .sum::<u64>(),
        FUNDING_VALUE
    );
}

#[test]
fn spilman_fixture_matches_checked_in_vectors() {
    let rendered = serde_json::to_string_pretty(&build()).unwrap() + "\n";
    let path = fixture_path();

    if std::env::var_os("CDK_SPILMAN_WRITE_FIXTURES").is_some() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &rendered).unwrap();
        eprintln!("wrote {}", path.display());
        return;
    }

    let existing = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "missing fixture {}: {e}. Regenerate with \
             CDK_SPILMAN_WRITE_FIXTURES=1 cargo +stable test --locked \
             spilman_fixture -- --nocapture",
            path.display()
        )
    });
    assert_eq!(
        existing, rendered,
        "the checked-in Spilman fixture drifted. If the upstream derivation \
         change is intentional, regenerate with \
         CDK_SPILMAN_WRITE_FIXTURES=1 cargo +stable test --locked \
         spilman_fixture -- --nocapture"
    );
}

/// The fixture proof JSON must deserialize into the CDK `Proof` type the ABI
/// accepts (`secret`/`C`/`id` spelling is part of the contract with Zig).
#[test]
fn fixture_proofs_deserialize_as_cdk_proofs() {
    let secrets = mint_keys();
    let id = Id::v1_from_keys(&keys(&secrets));
    let proofs: Vec<Proof> = serde_json::from_str(&synthetic_proofs(&secrets, id)).unwrap();
    assert_eq!(
        proofs.iter().map(|p| u64::from(p.amount)).sum::<u64>(),
        FUNDING_VALUE
    );
}

#[test]
fn funding_amount_vectors() {
    let secrets = mint_keys();
    let id = Id::v1_from_keys(&keys(&secrets));
    let fee0 = keyset_json(&secrets, id);
    let fee999 = fee0.replace("\"input_fee_ppk\":0", "\"input_fee_ppk\":999");
    let fee0_nul = with_nul(&fee0);
    let fee999_nul = with_nul(&fee999);

    // (capacity, nominal at 0 ppk, nominal at 999 ppk). Mirror of the same
    // table in the Zig suite: both sides must agree on the fee inverse.
    let vectors = [
        (0, 0, 0),
        (1, 1, 4),
        (2, 2, 6),
        (3, 3, 6),
        (4, 4, 8),
        (5, 5, 10),
        (6, 6, 10),
        (7, 7, 10),
        (100, 100, 108),
    ];
    for (capacity, no_fee, with_fee) in vectors {
        assert_eq!(
            spilman::cdk_spilman_compute_funding_token_amount(
                capacity,
                Some(cstr_ref(&fee0_nul)),
                64
            )
            .amount,
            no_fee,
            "capacity {capacity} without fees"
        );
        assert_eq!(
            spilman::cdk_spilman_compute_funding_token_amount(
                capacity,
                Some(cstr_ref(&fee999_nul)),
                64
            )
            .amount,
            with_fee,
            "capacity {capacity} with fees"
        );
    }
}

// ---------------------------------------------------------------------------
// Cooperative-close preparation: adapter equivalence and failure categories.
// ---------------------------------------------------------------------------

/// Everything the three close-preparation entry points need, taken from the
/// checked-in deterministic vectors plus one fresh sender signature over the
/// exact balance and channel id.
struct CloseVector {
    params_json: String,
    keyset_json: String,
    funding_proofs_json: String,
    channel_secret: String,
    charlie_secret: String,
    capacity: u64,
    balance: u64,
    channel_id: String,
    sender_signature: String,
}

fn close_vector() -> CloseVector {
    let fixture = build();
    let text = |key: &str| fixture[key].as_str().unwrap().to_owned();
    let params_json = text("params_json");
    let keyset_json = text("keyset_json");
    let funding_proofs_json = text("funding_proofs_json");
    let channel_secret = text("channel_secret");
    let charlie_secret = text("charlie_secret");
    let balance = fixture["close_balance"].as_u64().unwrap();
    let capacity = serde_json::from_str::<Value>(&params_json).unwrap()["capacity"]
        .as_u64()
        .unwrap();

    let (params_nul, keyset_nul, alice_nul, proofs_nul) = (
        with_nul(&params_json),
        with_nul(&keyset_json),
        with_nul(ALICE_SECRET),
        with_nul(&funding_proofs_json),
    );
    let update = take(spilman::cdk_spilman_create_signed_balance_update(
        Some(cstr_ref(&params_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&alice_nul)),
        Some(cstr_ref(&proofs_nul)),
        balance,
    ));
    let update: Value = serde_json::from_str(&update).unwrap();

    CloseVector {
        params_json,
        keyset_json,
        funding_proofs_json,
        channel_secret,
        charlie_secret,
        capacity,
        balance,
        channel_id: update["channel_id"].as_str().unwrap().to_owned(),
        sender_signature: update["signature"].as_str().unwrap().to_owned(),
    }
}

/// The same JSON shape the FFI close-preparation helper returns.
fn close_data_json(data: &cdk_spilman::CloseData) -> Value {
    json!({
        "swap_request": serde_json::to_value(&data.swap_request).unwrap(),
        "sig_all_message_hash": data.sig_all_message_hash,
        "blinded_receiver_pubkey": data.blinded_receiver_pubkey,
        "expected_total": data.expected_total,
        "secrets_with_blinding": data
            .secrets_with_blinding
            .iter()
            .map(|(secret, is_receiver)| {
                json!({
                    "secret": secret.secret.to_string(),
                    "blinding_factor": cdk::util::hex::encode(secret.blinding_factor.secret_bytes()),
                    "amount": secret.amount,
                    "index": secret.index,
                    "is_receiver": is_receiver,
                })
            })
            .collect::<Vec<_>>(),
        "output_keyset_info": serde_json::to_value(&data.output_keyset_info).unwrap(),
    })
}

/// Receiver signatures use a fresh BIP-340 nonce per call, so two independent
/// preparations of the same vector differ only in that second witness value.
/// Mask it before comparing everything else byte-for-byte.
fn mask_receiver_signature(mut value: Value) -> Value {
    let Some(first) = value["swap_request"]["inputs"]
        .as_array_mut()
        .and_then(|inputs| inputs.first_mut())
    else {
        return value;
    };
    let Some(witness) = first
        .get("witness")
        .and_then(Value::as_str)
        .map(str::to_owned)
    else {
        return value;
    };
    let mut witness: Value = serde_json::from_str(&witness).unwrap();
    if let Some(signatures) = witness["signatures"].as_array_mut() {
        assert_eq!(signatures.len(), 2, "sender and receiver must both sign");
        signatures[1] = json!("<receiver signature>");
    }
    first["witness"] = Value::String(witness.to_string());
    value
}

/// The upstream public cooperative-close entry point, driven by the same
/// minimal host the equivalence tests below use. This is the reference adapter
/// the FFI wrapper must match. It is deliberately upstream code rather than a
/// local copy, so drift fails here instead of hiding inside this repository.
fn primitive_close(vector: &CloseVector) -> cdk_spilman::CloseData {
    cdk_spilman::SpilmanBridge::new(close_host(vector))
        .validate_and_prepare_cooperative_close(&close_payment(
            &vector.channel_id,
            vector.balance,
            &vector.sender_signature,
        ))
        .unwrap()
}

/// Minimal receiver host: enough state for the public cooperative-close path,
/// with the signing capability as a field so failure modes are selectable.
struct CloseHost {
    funding: cdk_spilman::ChannelFunding,
    keyset_id: Id,
    keyset_json: String,
    amount_due: u64,
    receiver_secret_hex: Option<String>,
}

impl cdk_spilman::SpilmanHost<String> for CloseHost {
    fn receiver_key_is_acceptable(&self, _: &PublicKey) -> bool {
        true
    }
    fn mint_and_keyset_is_acceptable(&self, _: &str, _: &Id) -> bool {
        true
    }
    fn get_funding(&self, _: &str) -> Option<cdk_spilman::ChannelFunding> {
        Some(self.funding.clone())
    }
    fn save_funding(&self, _: &str, _: cdk_spilman::ChannelFunding, _: cdk_spilman::PaymentProof) {}
    fn get_amount_due(&self, _: &str, _: Option<&String>) -> u64 {
        self.amount_due
    }
    fn record_payment(&self, _: &str, _: cdk_spilman::PaymentProof, _: &String) {}
    fn get_channel_state(&self, _: &str) -> Result<Option<cdk_spilman::ChannelState>, String> {
        Ok(Some(cdk_spilman::ChannelState::Open))
    }
    fn mark_channel_closing(
        &self,
        _: &str,
        _: u64,
        _: cdk_spilman::PaymentProof,
    ) -> Result<(), String> {
        Ok(())
    }
    fn get_closing_data(&self, _: &str) -> Option<cdk_spilman::ClosingData> {
        None
    }
    fn get_channel_policy(&self, _: &str) -> Option<cdk_spilman::ChannelPolicy> {
        None
    }
    fn now_seconds(&self) -> u64 {
        SETUP_TIMESTAMP
    }
    fn get_balance_and_signature_for_unilateral_exit(
        &self,
        _: &str,
    ) -> Option<cdk_spilman::PaymentProof> {
        None
    }
    fn get_active_keyset_ids(&self, _: &str, _: &CurrencyUnit) -> Vec<Id> {
        vec![self.keyset_id]
    }
    fn has_keysets_for_unit(&self, _: &str, _: &CurrencyUnit) -> bool {
        true
    }
    fn get_keyset_info(&self, _: &str, id: &Id) -> Option<String> {
        (id == &self.keyset_id).then(|| self.keyset_json.clone())
    }
    fn mark_channel_closed(
        &self,
        _: &str,
        _: u64,
        _: u64,
        _: &str,
        _: &str,
        _: u64,
        _: u64,
    ) -> Result<(), String> {
        Ok(())
    }
    fn compute_channel_secret(&self, _: &str, _: &str) -> Result<String, String> {
        Err("unused".to_string())
    }
    fn sign_with_tweaked_key(&self, _: &str, message: &str, tweak: &str) -> Result<String, String> {
        match &self.receiver_secret_hex {
            Some(secret) => cdk_spilman::sign_with_tweaked_key_util(secret, message, tweak),
            None => Err("no receiver signing key".to_string()),
        }
    }
}

fn close_host(vector: &CloseVector) -> CloseHost {
    CloseHost {
        funding: cdk_spilman::ChannelFunding {
            params_json: vector.params_json.clone(),
            funding_proofs_json: vector.funding_proofs_json.clone(),
            channel_secret_hex: vector.channel_secret.clone(),
            keyset_info_json: vector.keyset_json.clone(),
        },
        keyset_id: cdk_spilman::parse_keyset_info_from_json(&vector.keyset_json)
            .unwrap()
            .keyset_id,
        keyset_json: vector.keyset_json.clone(),
        amount_due: vector.balance,
        receiver_secret_hex: Some(vector.charlie_secret.clone()),
    }
}

fn close_payment(channel_id: &str, balance: u64, signature: &str) -> String {
    json!({
        "channel_id": channel_id,
        "balance": balance,
        "signature": signature,
    })
    .to_string()
}

/// A syntactically valid sender signature over `balance`, produced through the
/// same ABI helper the fixture uses.
fn signed_balance_update(vector: &CloseVector, balance: u64) -> Value {
    let (params_nul, keyset_nul, alice_nul, proofs_nul) = (
        with_nul(&vector.params_json),
        with_nul(&vector.keyset_json),
        with_nul(ALICE_SECRET),
        with_nul(&vector.funding_proofs_json),
    );
    let update = take(spilman::cdk_spilman_create_signed_balance_update(
        Some(cstr_ref(&params_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&alice_nul)),
        Some(cstr_ref(&proofs_nul)),
        balance,
    ));
    serde_json::from_str(&update).unwrap()
}

/// Call the FFI close-preparation helper and return its status and error text
/// without asserting, so negative cases can inspect the exact diagnostic.
fn prepare_close_swap_result(
    vector: &CloseVector,
    output_keyset_json: &str,
    sender_signature: &str,
    receiver_secret_hex: &str,
) -> (crate::status::CdkStatus, Option<String>) {
    let (params_nul, secret_nul, keyset_nul, output_nul, proofs_nul, signature_nul, receiver_nul) = (
        with_nul(&vector.params_json),
        with_nul(&vector.channel_secret),
        with_nul(&vector.keyset_json),
        with_nul(output_keyset_json),
        with_nul(&vector.funding_proofs_json),
        with_nul(sender_signature),
        with_nul(receiver_secret_hex),
    );
    let result = spilman::cdk_spilman_prepare_close_swap(
        Some(cstr_ref(&params_nul)),
        Some(cstr_ref(&secret_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&output_nul)),
        Some(cstr_ref(&proofs_nul)),
        vector.balance,
        Some(cstr_ref(&signature_nul)),
        Some(cstr_ref(&receiver_nul)),
    );
    let error = result.error.as_ref().map(|e| e.to_str().to_owned());
    crate::api::cdk_string_free(result.error);
    crate::api::cdk_string_free(result.value);
    (result.status, error)
}

/// The FFI wrapper, the bridge adapter, and the shared primitive must produce
/// byte-identical close material for the same deterministic vector.
#[test]
fn close_preparation_is_equivalent_across_adapters() {
    let vector = close_vector();
    let primitive = primitive_close(&vector);

    let (params_nul, secret_nul, keyset_nul, proofs_nul, signature_nul, charlie_nul) = (
        with_nul(&vector.params_json),
        with_nul(&vector.channel_secret),
        with_nul(&vector.keyset_json),
        with_nul(&vector.funding_proofs_json),
        with_nul(&vector.sender_signature),
        with_nul(&vector.charlie_secret),
    );
    let wrapper = take(spilman::cdk_spilman_prepare_close_swap(
        Some(cstr_ref(&params_nul)),
        Some(cstr_ref(&secret_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&proofs_nul)),
        vector.balance,
        Some(cstr_ref(&signature_nul)),
        Some(cstr_ref(&charlie_nul)),
    ));
    let wrapper: Value = serde_json::from_str(&wrapper).unwrap();

    let bridge = cdk_spilman::SpilmanBridge::new(close_host(&vector));
    let adapter = bridge
        .validate_and_prepare_cooperative_close(&close_payment(
            &vector.channel_id,
            vector.balance,
            &vector.sender_signature,
        ))
        .unwrap();

    assert_eq!(
        mask_receiver_signature(close_data_json(&primitive)),
        mask_receiver_signature(wrapper.clone())
    );
    assert_eq!(
        mask_receiver_signature(close_data_json(&adapter)),
        mask_receiver_signature(wrapper)
    );

    // Equal-amount ordering is receiver-first and amounts are ascending.
    let amounts: Vec<u64> = primitive
        .secrets_with_blinding
        .iter()
        .map(|(secret, _)| secret.amount)
        .collect();
    assert!(amounts.windows(2).all(|pair| pair[0] <= pair[1]));
    for pair in primitive.secrets_with_blinding.windows(2) {
        if pair[0].0.amount == pair[1].0.amount {
            assert!(pair[0].1 && !pair[1].1);
        }
    }
}

/// Adapter-specific failure categories survive the shared primitive.
#[test]
fn close_preparation_preserves_failure_categories() {
    let vector = close_vector();
    let bridge = cdk_spilman::SpilmanBridge::new(close_host(&vector));

    // A sender signature over a different balance must stay an invalid
    // signature (the due check compares the requested balance only).
    let other_update = signed_balance_update(&vector, vector.balance + 1);
    let wrong_signature_error = bridge
        .validate_and_prepare_cooperative_close(&close_payment(
            &vector.channel_id,
            vector.balance,
            other_update["signature"].as_str().unwrap(),
        ))
        .unwrap_err();
    assert!(matches!(
        wrong_signature_error,
        cdk_spilman::BridgeError::InvalidSignature(_)
    ));

    // Over capacity stays a capacity error, checked before the sender signature.
    let over_capacity = bridge
        .validate_and_prepare_cooperative_close(&close_payment(
            &vector.channel_id,
            vector.capacity + 1,
            &vector.sender_signature,
        ))
        .unwrap_err();
    assert!(matches!(
        over_capacity,
        cdk_spilman::BridgeError::BalanceExceedsCapacity { .. }
    ));

    // A failed receiver signing capability stays a server-misconfiguration error.
    let mut host = close_host(&vector);
    host.receiver_secret_hex = None;
    let no_signer = cdk_spilman::SpilmanBridge::new(host)
        .validate_and_prepare_cooperative_close(&close_payment(
            &vector.channel_id,
            vector.balance,
            &vector.sender_signature,
        ))
        .unwrap_err();
    assert!(matches!(
        no_signer,
        cdk_spilman::BridgeError::ServerMisconfigured(_)
    ));
}

/// The wrapper keeps its local output-unit policy before touching the mint
/// material (the bridge selects a matching keyset instead).
#[test]
fn prepare_close_swap_rejects_a_wrong_unit_output_keyset() {
    let vector = close_vector();
    let mut wrong_unit: Value = serde_json::from_str(&vector.keyset_json).unwrap();
    wrong_unit["unit"] = json!("auth");
    let wrong_unit_json = serde_json::to_string(&wrong_unit).unwrap();

    let (status, error) = prepare_close_swap_result(
        &vector,
        &wrong_unit_json,
        &vector.sender_signature,
        &vector.charlie_secret,
    );
    assert_eq!(status, crate::status::CdkStatus::InvalidArgument);
    assert!(
        error.unwrap().contains("unit does not match"),
        "wrong-unit output keyset must be rejected locally"
    );
}

/// Wrapper validation order is unchanged: the sender signature is checked
/// before the receiver-key check, even now that both live in one primitive.
#[test]
fn prepare_close_swap_keeps_sender_before_receiver_validation() {
    let vector = close_vector();
    let wrong_balance = signed_balance_update(&vector, vector.balance + 1);
    let unrelated_receiver = SecretKey::generate().to_secret_hex();

    // Syntactically valid sender signature over the wrong balance plus an
    // unrelated receiver key: the sender diagnostic wins and the receiver
    // mismatch is never reached.
    let (status, error) = prepare_close_swap_result(
        &vector,
        &vector.keyset_json,
        wrong_balance["signature"].as_str().unwrap(),
        &unrelated_receiver,
    );
    assert_eq!(status, crate::status::CdkStatus::InvalidArgument);
    let error = error.unwrap();
    assert!(
        error.starts_with("Invalid sender signature:"),
        "unexpected diagnostic: {error}"
    );
    assert!(
        !error.contains("does not match"),
        "receiver validation must run after the sender signature: {error}"
    );

    // Valid sender plus an unrelated receiver key reproduces the exact prior,
    // unprefixed mismatch diagnostic.
    let (status, error) = prepare_close_swap_result(
        &vector,
        &vector.keyset_json,
        &vector.sender_signature,
        &unrelated_receiver,
    );
    assert_eq!(status, crate::status::CdkStatus::InvalidArgument);
    assert_eq!(
        error.unwrap(),
        "receiver secret key does not match channel receiver public key"
    );
}

// ---------------------------------------------------------------------------
// Caller-selected close keysets and unblinding contract
// ---------------------------------------------------------------------------

/// The fixture keyset with a caller-chosen id and expiry.
fn variant_keyset(vector: &CloseVector, keyset_id: &str, final_expiry: Value) -> String {
    let mut value: Value = serde_json::from_str(&vector.keyset_json).unwrap();
    value["keyset_id"] = json!(keyset_id);
    value["final_expiry"] = final_expiry;
    value.to_string()
}

/// The fixture keyset id, as a string.
fn vector_keyset_id(vector: &CloseVector) -> String {
    cdk_spilman::parse_keyset_info_from_json(&vector.keyset_json)
        .unwrap()
        .keyset_id
        .to_string()
}

/// Run the FFI close preparation and deserialize the successful JSON.
fn prepare_close_swap_value(
    vector: &CloseVector,
    output_keyset_json: &str,
    receiver_secret_hex: &str,
) -> Value {
    let (params_nul, secret_nul, keyset_nul, output_nul, proofs_nul, signature_nul, receiver_nul) = (
        with_nul(&vector.params_json),
        with_nul(&vector.channel_secret),
        with_nul(&vector.keyset_json),
        with_nul(output_keyset_json),
        with_nul(&vector.funding_proofs_json),
        with_nul(&vector.sender_signature),
        with_nul(receiver_secret_hex),
    );
    let value = take(spilman::cdk_spilman_prepare_close_swap(
        Some(cstr_ref(&params_nul)),
        Some(cstr_ref(&secret_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&output_nul)),
        Some(cstr_ref(&proofs_nul)),
        vector.balance,
        Some(cstr_ref(&signature_nul)),
        Some(cstr_ref(&receiver_nul)),
    ));
    serde_json::from_str(&value).unwrap()
}

/// The FFI unblinding helper's outcome, with proofs already deserialized.
struct UnblindOutcome {
    status: crate::status::CdkStatus,
    error: Option<String>,
    receiver_proofs: Vec<Proof>,
    sender_proofs: Vec<Proof>,
    receiver_sum: u64,
    sender_sum: u64,
}

fn unblind_close_swap_value(
    vector: &CloseVector,
    output_keyset_json: &str,
    secrets_with_blinding: &Value,
    swap_response: &Value,
    receiver_secret_hex: Option<&str>,
) -> UnblindOutcome {
    let (params_nul, secret_nul, keyset_nul, output_nul, secrets_nul, response_nul) = (
        with_nul(&vector.params_json),
        with_nul(&vector.channel_secret),
        with_nul(&vector.keyset_json),
        with_nul(output_keyset_json),
        with_nul(&secrets_with_blinding.to_string()),
        with_nul(&swap_response.to_string()),
    );
    let receiver_storage;
    let receiver = match receiver_secret_hex {
        Some(secret) => {
            receiver_storage = with_nul(secret);
            Some(cstr_ref(&receiver_storage))
        }
        None => None,
    };
    let result = spilman::cdk_spilman_unblind_close_swap(
        Some(cstr_ref(&params_nul)),
        Some(cstr_ref(&secret_nul)),
        Some(cstr_ref(&keyset_nul)),
        Some(cstr_ref(&output_nul)),
        Some(cstr_ref(&secrets_nul)),
        Some(cstr_ref(&response_nul)),
        vector.balance,
        receiver,
    );

    let error = result.error.as_ref().map(|e| e.to_str().to_owned());
    let receiver_json = result
        .receiver_proofs_json
        .as_ref()
        .map(|value| value.to_str().to_owned());
    let sender_json = result
        .sender_proofs_json
        .as_ref()
        .map(|value| value.to_str().to_owned());
    let status = result.status;
    let receiver_sum = result.receiver_sum;
    let sender_sum = result.sender_sum;
    crate::api::cdk_string_free(result.error);
    crate::api::cdk_string_free(result.receiver_proofs_json);
    crate::api::cdk_string_free(result.sender_proofs_json);

    UnblindOutcome {
        status,
        error,
        receiver_proofs: serde_json::from_str(receiver_json.as_deref().unwrap_or("[]")).unwrap(),
        sender_proofs: serde_json::from_str(sender_json.as_deref().unwrap_or("[]")).unwrap(),
        receiver_sum,
        sender_sum,
    }
}

/// Mint response for a prepared close request, signed by the fixture mint.
fn sign_close_request(prepared: &Value, keyset_id: &str) -> Value {
    let id: Id = keyset_id.parse().unwrap();
    sign_outputs(&prepared["swap_request"].to_string(), &mint_keys(), id)
}

/// The caller chooses the close output keyset: it must be used unchanged for
/// every commitment output instead of the funding keyset being reused.
#[test]
fn close_preparation_uses_the_caller_selected_output_keyset() {
    let vector = close_vector();
    let rotated_id = "009a1f293253e41e";
    let rotated = variant_keyset(&vector, rotated_id, Value::Null);

    let prepared = prepare_close_swap_value(&vector, &rotated, &vector.charlie_secret);
    assert_eq!(
        prepared["output_keyset_info"]["keysetId"],
        json!(rotated_id),
        "the prepared metadata must echo the caller's keyset"
    );

    let outputs = prepared["swap_request"]["outputs"].as_array().unwrap();
    assert!(!outputs.is_empty(), "a close request always has outputs");
    for output in outputs {
        assert_eq!(
            output["id"],
            json!(rotated_id),
            "every output must be locked to the caller-selected keyset"
        );
    }

    // The funding keyset is a different keyset; choosing it must produce a
    // different id, proving the selection is the caller's, not a default.
    let funding_based =
        prepare_close_swap_value(&vector, &vector.keyset_json, &vector.charlie_secret);
    assert_eq!(
        funding_based["output_keyset_info"]["keysetId"],
        json!(vector_keyset_id(&vector))
    );
    assert_ne!(
        funding_based["output_keyset_info"]["keysetId"],
        json!(rotated_id)
    );

    // Rotation changes the output keyset only: the deterministic secret
    // material is derived from the channel, not from the keyset.
    assert_eq!(
        prepared["secrets_with_blinding"],
        funding_based["secrets_with_blinding"]
    );
    assert_eq!(prepared["expected_total"], funding_based["expected_total"]);
}

/// The adapter never narrows the caller's keyset choice by expiry: an expired
/// test keyset, an explicit `final_expiry: 0`, and no expiry all prepare.
#[test]
fn close_preparation_accepts_expired_and_zero_expiry_output_keysets() {
    let vector = close_vector();
    let keyset_id = vector_keyset_id(&vector);
    let cases = [
        ("expired", json!(SETUP_TIMESTAMP - 1)),
        ("zero", json!(0)),
        ("none", Value::Null),
    ];
    for (label, expiry) in cases {
        let keyset = variant_keyset(&vector, &keyset_id, expiry.clone());
        let (status, error) = prepare_close_swap_result(
            &vector,
            &keyset,
            &vector.sender_signature,
            &vector.charlie_secret,
        );
        assert_eq!(
            status,
            crate::status::CdkStatus::Ok,
            "{label} keyset must prepare without expiry narrowing: {error:?}"
        );
    }
}

/// The unblinder accepts any self-consistent supplied metadata ordering: the
/// historical contract never required the caller to canonicalize the list, and
/// signatures are matched to the entries they were made for.
#[test]
fn unblind_close_swap_accepts_noncanonical_supplied_metadata() {
    let vector = close_vector();
    let prepared = prepare_close_swap_value(&vector, &vector.keyset_json, &vector.charlie_secret);

    let canonical = unblind_close_swap_value(
        &vector,
        &vector.keyset_json,
        &prepared["secrets_with_blinding"],
        &sign_close_request(&prepared, &vector_keyset_id(&vector)),
        Some(&vector.charlie_secret),
    );
    assert_eq!(
        canonical.status,
        crate::status::CdkStatus::Ok,
        "{:?}",
        canonical.error
    );

    // Reversed, sender-first order: valid, just not the canonical amount-sorted
    // order the bridge emits.
    let mut secrets = prepared["secrets_with_blinding"]
        .as_array()
        .unwrap()
        .clone();
    secrets.reverse();
    let mut response = sign_close_request(&prepared, &vector_keyset_id(&vector));
    let mut signatures = response["signatures"].as_array().unwrap().clone();
    signatures.reverse();
    response["signatures"] = Value::Array(signatures);

    let reordered = unblind_close_swap_value(
        &vector,
        &vector.keyset_json,
        &json!(secrets),
        &response,
        Some(&vector.charlie_secret),
    );
    assert_eq!(
        reordered.status,
        crate::status::CdkStatus::Ok,
        "{:?}",
        reordered.error
    );
    assert_eq!(reordered.receiver_sum, canonical.receiver_sum);
    assert_eq!(reordered.sender_sum, canonical.sender_sum);
    assert_eq!(
        reordered.receiver_proofs.len(),
        canonical.receiver_proofs.len()
    );
    assert_eq!(reordered.sender_proofs.len(), canonical.sender_proofs.len());
}

/// The optional signing key must belong to this channel before any proof is returned.
#[test]
fn unblind_close_swap_rejects_a_receiver_key_not_owned_by_the_channel() {
    let vector = close_vector();
    let prepared = prepare_close_swap_value(&vector, &vector.keyset_json, &vector.charlie_secret);
    let response = sign_close_request(&prepared, &vector_keyset_id(&vector));
    let unrelated_receiver = SecretKey::generate().to_secret_hex();
    let result = unblind_close_swap_value(
        &vector,
        &vector.keyset_json,
        &prepared["secrets_with_blinding"],
        &response,
        Some(&unrelated_receiver),
    );
    assert_eq!(result.status, crate::status::CdkStatus::InvalidArgument);
    assert_eq!(
        result.error.as_deref(),
        Some("receiver secret key does not match channel receiver public key")
    );
    assert!(result.receiver_proofs.is_empty());
    assert!(result.sender_proofs.is_empty());
}

/// Receiver proofs carry exactly one signature over their stage-2 key, and
/// omitting the receiver secret preserves the unsigned proofs unchanged.
#[test]
fn unblind_close_swap_signs_once_and_preserves_unsigned_proofs() {
    let vector = close_vector();
    let prepared = prepare_close_swap_value(&vector, &vector.keyset_json, &vector.charlie_secret);
    let response = sign_close_request(&prepared, &vector_keyset_id(&vector));

    let signed = unblind_close_swap_value(
        &vector,
        &vector.keyset_json,
        &prepared["secrets_with_blinding"],
        &response,
        Some(&vector.charlie_secret),
    );
    assert_eq!(
        signed.status,
        crate::status::CdkStatus::Ok,
        "{:?}",
        signed.error
    );
    assert!(!signed.receiver_proofs.is_empty());

    let keyset = cdk_spilman::parse_keyset_info_from_json(&vector.keyset_json).unwrap();
    let channel_secret: [u8; 32] = cdk::util::hex::decode(&vector.channel_secret)
        .unwrap()
        .try_into()
        .unwrap();
    let params = cdk_spilman::ChannelParameters::from_json_with_channel_secret(
        &vector.params_json,
        keyset,
        channel_secret,
    )
    .unwrap();

    let metadata = prepared["secrets_with_blinding"].as_array().unwrap();
    for proof in &signed.receiver_proofs {
        let secret = proof.secret.to_string();
        let entry = metadata
            .iter()
            .find(|entry| entry["secret"] == json!(secret) && entry["is_receiver"] == json!(true))
            .unwrap_or_else(|| panic!("no receiver metadata for proof secret"));
        let amount = entry["amount"].as_u64().unwrap();
        let index = entry["index"].as_u64().unwrap() as usize;
        let witness = match &proof.witness {
            Some(Witness::P2PKWitness(witness)) => witness,
            other => panic!("receiver proof must carry a P2PK witness, got {other:?}"),
        };
        assert_eq!(
            witness.signatures.len(),
            1,
            "the wrapper replaces any inherited witness with one signature"
        );
        let signature: cdk::secp256k1::schnorr::Signature = witness.signatures[0].parse().unwrap();
        let stage2_pubkey = params
            .get_receiver_blinded_pubkey_for_stage2_output(amount, index)
            .unwrap();
        stage2_pubkey
            .verify(&proof.secret.to_bytes(), &signature)
            .expect("receiver signature must verify against the derived stage-2 key");
    }
    for proof in &signed.sender_proofs {
        assert!(
            proof.witness.is_none(),
            "sender proofs are never signed by this adapter"
        );
    }

    // Without the receiver secret the same proofs come back unsigned.
    let unsigned = unblind_close_swap_value(
        &vector,
        &vector.keyset_json,
        &prepared["secrets_with_blinding"],
        &response,
        None,
    );
    assert_eq!(
        unsigned.status,
        crate::status::CdkStatus::Ok,
        "{:?}",
        unsigned.error
    );
    assert_eq!(unsigned.receiver_sum, signed.receiver_sum);
    assert_eq!(unsigned.sender_sum, signed.sender_sum);
    assert!(unsigned
        .receiver_proofs
        .iter()
        .all(|proof| proof.witness.is_none()));

    let strip = |proofs: &[Proof]| -> Vec<Value> {
        proofs
            .iter()
            .map(|proof| {
                let mut value = serde_json::to_value(proof).unwrap();
                value.as_object_mut().unwrap().remove("witness");
                value
            })
            .collect()
    };
    assert_eq!(
        strip(&signed.receiver_proofs),
        strip(&unsigned.receiver_proofs)
    );
}
