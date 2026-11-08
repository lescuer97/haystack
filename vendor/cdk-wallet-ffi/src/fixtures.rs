//! Deterministic wire fixtures shared with the Zig C-ABI test suite.
//!
//! The Zig tests reimplement nothing: they replay real mint responses produced
//! by this module through the same `#[ffi_export]` entry points the Zig
//! application calls. That makes the fixtures a provenance record of the
//! vendored `cdk-spilman` derivation: if an upstream change alters the
//! deterministic blinding, channel id, or DLEQ construction, the drift test
//! below fails until the file is regenerated.
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
    BlindSignature, BlindedMessage, Id, Keys, Proof, SecretKey, SwapRequest, SwapResponse,
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
        "the checked-in Spilman fixture drifted. If the vendored derivation \
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
            .net_sats,
            no_fee,
            "capacity {capacity} without fees"
        );
        assert_eq!(
            spilman::cdk_spilman_compute_funding_token_amount(
                capacity,
                Some(cstr_ref(&fee999_nul)),
                64
            )
            .net_sats,
            with_fee,
            "capacity {capacity} with fees"
        );
    }
}
