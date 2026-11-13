//! Spilman payment-channel primitives exposed over the C ABI.
//!
//! This module layers two things on top of the core wallet ABI:
//!
//! * five wallet-backed helpers that expose the pieces a Spilman flow needs
//!   from the local wallet (keyset info, raw NUT-03 swaps, and receiving
//!   proofs/tokens that may be P2PK-locked);
//! * twenty-three pure conversion helpers that wrap the vendored
//!   [`cdk_spilman`] crate, so the Zig side can drive channel setup, balance
//!   updates, cooperative close, and post-expiry sender refunds without
//!   reimplementing any of the cryptography.
//!
//! Every function is panic-safe, returns a fixed-width status, and never echoes
//! secret material in an error message. Secret-key and channel-secret hex inputs
//! are wrapped in [`Zeroizing`] for their whole lifetime in this module.

use safer_ffi::prelude::*;
use zeroize::Zeroizing;

use cdk::nuts::{BlindSignature, P2PKWitness, Proof, Proofs, SecretKey, Token, Witness};
use cdk::secp256k1::schnorr::Signature;
use cdk::util::hex;
use cdk_common::bitcoin::hashes::{sha256::Hash as Sha256Hash, Hash as _};
use cdk_spilman::{
    attach_signature_to_balance_update, attach_signature_to_first_input, build_cashu_a_token,
    build_cashu_b_token, channel_parameters_get_channel_id, complete_funding_swap,
    compute_channel_from_token, compute_channel_secret_from_hex, compute_funding_token_amount,
    construct_proofs, create_funding_outputs, create_funding_swap, create_signed_balance_update,
    create_unsigned_balance_update, parse_keyset_info_from_json, sig_all_message_hash_hex,
    sign_with_tweaked_key_util, unblind_and_verify_stage1_response, verify_valid_channel,
    BalanceUpdateMessage, ChannelParameters, CommitmentOutputs, DeterministicSecretWithBlinding,
    EstablishedChannel, KeysetInfo, PreparedSenderRefund, Stage2Role,
};

use crate::api::{
    guard, guard_poison, null_handle, opt_cstr_to_string_bounded, poisoned_handle, receive_error,
};
use crate::status::{
    string_to_box, CdkReceiveResult, CdkSpilmanCloseResult, CdkSpilmanKeypairResult, CdkStatus,
    CdkStatusResult, CdkStringResult,
};
#[cfg(not(target_arch = "wasm32"))]
use crate::wallet::runtime;
use crate::wallet::{CdkWallet, FfiErr, FfiResult, MAX_TOKEN_BYTES};

/// Maximum accepted length, in bytes, for a single hex-encoded value.
///
/// The longest accepted value is a 128-hex-character Schnorr signature; 256
/// leaves room for a short comma-separated signing-key list while rejecting
/// oversized input before any decode or allocation.
const MAX_HEX_BYTES: usize = 256;

/// Maximum accepted length, in bytes, for a comma-separated list of P2PK
/// signing keys.
///
/// Each individual key is still validated against [`MAX_HEX_BYTES`]; the larger
/// bound only exists so multi-key P2PK receives (more than three keys) can be
/// supplied in one argument.
const MAX_SIGNING_KEYS_BYTES: usize = 4096;

// ---------------------------------------------------------------------------
// Argument decoding
// ---------------------------------------------------------------------------

/// Decode a required JSON / token / mint-URL argument.
fn json_arg(s: Option<char_p::Ref<'_>>, what: &str) -> FfiResult<String> {
    opt_cstr_to_string_bounded(s, MAX_TOKEN_BYTES, what)
}

/// Decode a required short hex / identifier argument.
fn hex_arg(s: Option<char_p::Ref<'_>>, what: &str) -> FfiResult<String> {
    opt_cstr_to_string_bounded(s, MAX_HEX_BYTES, what)
}

/// Decode a required secret-bearing hex argument, zeroized on drop.
fn secret_hex_arg(s: Option<char_p::Ref<'_>>, what: &str) -> FfiResult<Zeroizing<String>> {
    opt_cstr_to_string_bounded(s, MAX_HEX_BYTES, what).map(Zeroizing::new)
}

/// Decode an optional secret-bearing hex argument, zeroized on drop.
///
/// `NULL` or an empty string yields `None`; a present value is bounded and
/// wrapped in [`Zeroizing`].
fn opt_secret_hex_arg(
    s: Option<char_p::Ref<'_>>,
    what: &str,
) -> FfiResult<Option<Zeroizing<String>>> {
    let s = match s {
        Some(s) => s,
        None => return Ok(None),
    };
    let value = Zeroizing::new(opt_cstr_to_string_bounded(Some(s), MAX_HEX_BYTES, what)?);
    if value.trim().is_empty() {
        Ok(None)
    } else {
        Ok(Some(value))
    }
}

/// Decode a required mint-URL argument.
fn mint_url_arg(s: Option<char_p::Ref<'_>>) -> FfiResult<String> {
    opt_cstr_to_string_bounded(s, MAX_TOKEN_BYTES, "mint URL")
}

// ---------------------------------------------------------------------------
// Result helpers
// ---------------------------------------------------------------------------

/// A success [`CdkStringResult`] carrying `value`.
fn string_ok(value: String) -> CdkStringResult {
    CdkStringResult {
        status: CdkStatus::Ok,
        error: None,
        value: string_to_box(value),
    }
}

/// Map an upstream `Result<String, String>` onto a [`CdkStringResult`].
///
/// The vendored helpers report structural / validation failures as plain
/// strings, so every failure maps to [`CdkStatus::InvalidArgument`].
fn spilman_string(result: Result<String, String>) -> CdkStringResult {
    match result {
        Ok(value) => string_ok(value),
        Err(message) => CdkStringResult::err(CdkStatus::InvalidArgument, message),
    }
}

/// A success [`CdkReceiveResult`] carrying `net_sats`.
fn receive_sats(net_sats: u64) -> CdkReceiveResult {
    CdkReceiveResult {
        status: CdkStatus::Ok,
        error: None,
        net_sats,
    }
}

/// A success [`CdkStatusResult`].
fn status_ok() -> CdkStatusResult {
    CdkStatusResult::ok()
}

// ---------------------------------------------------------------------------
// Shared parsing helpers
// ---------------------------------------------------------------------------

/// Decode a hex string that must be exactly 32 bytes.
fn parse_32_bytes(hex_str: &str, what: &str) -> Result<[u8; 32], String> {
    let bytes = hex::decode(hex_str).map_err(|e| format!("Invalid {what} hex: {e}"))?;
    bytes
        .try_into()
        .map_err(|_| format!("{what} must be 32 bytes"))
}

/// Reconstruct [`ChannelParameters`] from JSON, a channel secret, and keyset info.
fn parse_params(
    params_json: &str,
    channel_secret_hex: &str,
    keyset_info_json: &str,
) -> Result<ChannelParameters, String> {
    let channel_secret = parse_32_bytes(channel_secret_hex, "channel secret")?;
    let keyset_info = parse_keyset_info_from_json(keyset_info_json)?;
    ChannelParameters::from_json_with_channel_secret(params_json, keyset_info, channel_secret)
        .map_err(|e| format!("Failed to parse channel parameters: {e}"))
}

/// Parse a JSON array of proofs.
fn parse_proofs(proofs_json: &str) -> Result<Vec<Proof>, String> {
    serde_json::from_str(proofs_json).map_err(|e| format!("Failed to parse proofs: {e}"))
}

/// Parse blind signatures from either a `SwapResponse` object (`{"signatures":
/// [...]}`) or a bare `Vec<BlindSignature>` array.
fn parse_blind_signatures(swap_response_json: &str) -> Result<Vec<BlindSignature>, String> {
    let value: serde_json::Value = serde_json::from_str(swap_response_json)
        .map_err(|e| format!("Failed to parse swap response: {e}"))?;
    let signatures = match &value {
        serde_json::Value::Array(_) => value,
        _ => value
            .get("signatures")
            .cloned()
            .ok_or_else(|| "Missing 'signatures' in swap response".to_string())?,
    };
    serde_json::from_value(signatures).map_err(|e| format!("Failed to parse blind signatures: {e}"))
}

/// Parse the `secrets_with_blinding` array produced by
/// [`cdk_spilman_prepare_close_swap`].
fn parse_secrets_with_blinding(
    secrets_with_blinding_json: &str,
) -> Result<Vec<(DeterministicSecretWithBlinding, bool)>, String> {
    let raw: Vec<serde_json::Value> = serde_json::from_str(secrets_with_blinding_json)
        .map_err(|e| format!("Failed to parse secrets_with_blinding: {e}"))?;

    let mut secrets = Vec::with_capacity(raw.len());
    for swb in raw {
        let secret_str = swb["secret"]
            .as_str()
            .ok_or("Missing 'secret' in secrets_with_blinding")?;
        let secret = secret_str
            .parse()
            .map_err(|e| format!("Invalid secret: {e}"))?;
        let blinding_factor_hex = swb["blinding_factor"]
            .as_str()
            .ok_or("Missing 'blinding_factor' in secrets_with_blinding")?;
        let blinding_factor = SecretKey::from_hex(blinding_factor_hex)
            .map_err(|e| format!("Invalid blinding factor: {e}"))?;
        let amount = swb["amount"]
            .as_u64()
            .ok_or("Missing 'amount' in secrets_with_blinding")?;
        let index = swb["index"]
            .as_u64()
            .ok_or("Missing 'index' in secrets_with_blinding")? as usize;
        let is_receiver = swb["is_receiver"]
            .as_bool()
            .ok_or("Missing 'is_receiver' in secrets_with_blinding")?;
        secrets.push((
            DeterministicSecretWithBlinding {
                secret,
                blinding_factor,
                amount,
                index,
            },
            is_receiver,
        ));
    }
    Ok(secrets)
}

/// Parse an optional comma-separated list of P2PK signing keys.
///
/// `NULL` or an empty string yields no keys.
fn parse_signing_keys(raw: Option<char_p::Ref<'_>>) -> FfiResult<Vec<SecretKey>> {
    let raw = match raw {
        Some(raw) => raw,
        None => return Ok(Vec::new()),
    };
    let list = Zeroizing::new(opt_cstr_to_string_bounded(
        Some(raw),
        MAX_SIGNING_KEYS_BYTES,
        "signing key",
    )?);
    if list.trim().is_empty() {
        return Ok(Vec::new());
    }

    let mut keys = Vec::new();
    for part in list.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if part.len() > MAX_HEX_BYTES {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "signing key exceeds the maximum supported size",
            ));
        }
        let key = SecretKey::from_hex(part)
            .map_err(|_| FfiErr::new(CdkStatus::InvalidArgument, "invalid signing key hex"))?;
        keys.push(key);
    }
    Ok(keys)
}

// ---------------------------------------------------------------------------
// Spilman flow helpers
// ---------------------------------------------------------------------------

/// Replicate the receiver-side close preparation without a host.
///
/// Mirrors the upstream `prepare_close_data_impl`: attach the sender's
/// signature to the first input, derive the receiver's blinded-signing tweak,
/// sign the SIG_ALL message, and attach that second signature. The returned
/// JSON carries the signed swap request plus the metadata
/// [`cdk_spilman_unblind_close_swap`] needs.
fn prepare_close_swap_json(
    params: &ChannelParameters,
    output_keyset: &KeysetInfo,
    funding_proofs: Vec<Proof>,
    balance: u64,
    sender_signature_hex: &str,
    receiver_secret_key_hex: &str,
) -> Result<String, String> {
    if balance > params.capacity {
        return Err(format!(
            "balance {balance} exceeds channel capacity {}",
            params.capacity
        ));
    }

    if output_keyset.unit != params.unit {
        return Err("close output keyset unit does not match channel unit".to_string());
    }

    let sender_signature: Signature = sender_signature_hex
        .parse()
        .map_err(|e| format!("Invalid sender signature: {e}"))?;

    let commitment = CommitmentOutputs::for_balance(balance, params)
        .map_err(|e| format!("Failed to build commitment outputs: {e}"))?;
    let mut swap = commitment
        .create_swap_request(funding_proofs.clone(), Some(output_keyset.keyset_id))
        .map_err(|e| format!("Failed to create close swap request: {e}"))?;
    attach_signature_to_first_input(&mut swap, &sender_signature.to_string())
        .map_err(|e| format!("Failed to attach sender signature: {e}"))?;

    let channel = EstablishedChannel::new(params.clone(), funding_proofs)
        .map_err(|e| format!("Failed to build channel: {e}"))?;
    BalanceUpdateMessage {
        channel_id: params.get_channel_id(),
        amount: balance,
        signature: sender_signature,
    }
    .verify_sender_signature(&channel)
    .map_err(|e| format!("Invalid sender signature: {e}"))?;

    let tweak = hex::encode(
        params
            .derive_receiver_blinding_scalar_for_stage1()
            .map_err(|e| format!("Failed to derive receiver blinding scalar: {e}"))?
            .to_be_bytes(),
    );
    let sig_all_message_hash = sig_all_message_hash_hex(&swap);
    let blinded_receiver_pubkey = params
        .get_receiver_blinded_pubkey_for_stage1()
        .map_err(|e| format!("Failed to derive receiver blinded pubkey: {e}"))?
        .to_hex();
    let receiver_secret = SecretKey::from_hex(receiver_secret_key_hex)
        .map_err(|_| "Invalid receiver secret key".to_string())?;
    if receiver_secret.public_key() != params.receiver_pubkey {
        return Err("receiver secret key does not match channel receiver public key".to_string());
    }
    let receiver_signature =
        sign_with_tweaked_key_util(receiver_secret_key_hex, &sig_all_message_hash, &tweak)
            .map_err(|e| format!("Failed to sign close message: {e}"))?;
    attach_signature_to_first_input(&mut swap, &receiver_signature)
        .map_err(|e| format!("Failed to attach receiver signature: {e}"))?;

    let expected_total = params
        .get_value_after_stage1_with_keyset(output_keyset)
        .map_err(|e| format!("Failed to compute expected total: {e}"))?;

    let mut secrets_with_blinding: Vec<(DeterministicSecretWithBlinding, bool)> = commitment
        .receiver_outputs
        .get_secrets_with_blinding()
        .map_err(|e| format!("Failed to derive receiver secrets: {e}"))?
        .into_iter()
        .map(|secret| (secret, true))
        .chain(
            commitment
                .sender_outputs
                .get_secrets_with_blinding()
                .map_err(|e| format!("Failed to derive sender secrets: {e}"))?
                .into_iter()
                .map(|secret| (secret, false)),
        )
        .collect();
    secrets_with_blinding.sort_by_key(|(secret, _)| secret.amount);

    let secrets_with_blinding: Vec<serde_json::Value> = secrets_with_blinding
        .iter()
        .map(|(secret, is_receiver)| {
            serde_json::json!({
                "secret": secret.secret.to_string(),
                "blinding_factor": hex::encode(secret.blinding_factor.secret_bytes()),
                "amount": secret.amount,
                "index": secret.index,
                "is_receiver": is_receiver,
            })
        })
        .collect();

    let result = serde_json::json!({
        "swap_request": serde_json::to_value(&swap)
            .map_err(|e| format!("Failed to serialize swap request: {e}"))?,
        "sig_all_message_hash": sig_all_message_hash,
        "blinded_receiver_pubkey": blinded_receiver_pubkey,
        "expected_total": expected_total,
        "secrets_with_blinding": secrets_with_blinding,
        "output_keyset_info": serde_json::to_value(output_keyset)
            .map_err(|e| format!("Failed to serialize output keyset info: {e}"))?,
    });
    Ok(result.to_string())
}

/// Unblind a close swap response and sign the receiver's proofs.
///
/// [`unblind_and_verify_stage1_response`] already attaches the stage-2 P2PK
/// secret to each proof, so this only has to derive the per-proof tweak, sign
/// the secret hash, and install the witness.
fn unblind_close_swap(
    params: &ChannelParameters,
    output_keyset: &KeysetInfo,
    secrets_with_blinding: Vec<(DeterministicSecretWithBlinding, bool)>,
    blind_signatures: Vec<BlindSignature>,
    balance: u64,
    receiver_secret_key_hex: Option<&str>,
) -> Result<CdkSpilmanCloseResult, String> {
    if output_keyset.unit != params.unit {
        return Err("close output keyset unit does not match channel unit".to_string());
    }

    // When a receiver secret is supplied, validate it against the channel's
    // receiver public key before signing; `None` means the caller only wants
    // the stage-2 P2PK secret attached (e.g. Alice unblinding the close
    // response) without pre-signing `receiver_proofs`.
    let receiver_secret_key_hex = match receiver_secret_key_hex {
        Some(hex) => {
            let receiver_secret =
                SecretKey::from_hex(hex).map_err(|_| "Invalid receiver secret key".to_string())?;
            if receiver_secret.public_key() != params.receiver_pubkey {
                return Err(
                    "receiver secret key does not match channel receiver public key".to_string(),
                );
            }
            Some(hex)
        }
        None => None,
    };

    let result = unblind_and_verify_stage1_response(
        blind_signatures,
        secrets_with_blinding,
        params,
        output_keyset,
        balance,
    )
    .map_err(|e| format!("Failed to unblind close response: {e}"))?;

    let mut receiver_proofs = Vec::with_capacity(result.receiver_proofs.len());
    for proof_meta in &result.receiver_proofs {
        let mut proof = proof_meta.proof.clone();
        if let Some(receiver_secret_key_hex) = receiver_secret_key_hex {
            let tweak_info = params
                .stage2_tweak_info_for_role(
                    Stage2Role::Receiver,
                    proof_meta.amount,
                    proof_meta.index,
                )
                .map_err(|e| format!("Failed to derive receiver stage-2 tweak: {e}"))?;
            let tweak_hex = hex::encode(tweak_info.stage2_tweak_scalar.to_be_bytes());
            let message_hash = Sha256Hash::hash(&proof.secret.to_bytes());
            let message_hex = hex::encode(message_hash.to_byte_array());
            let signature =
                sign_with_tweaked_key_util(receiver_secret_key_hex, &message_hex, &tweak_hex)
                    .map_err(|e| format!("Failed to sign receiver proof: {e}"))?;
            proof.witness = Some(Witness::P2PKWitness(P2PKWitness {
                signatures: vec![signature],
            }));
        }
        receiver_proofs.push(proof);
    }

    let sender_proofs: Vec<&Proof> = result
        .sender_proofs
        .iter()
        .map(|proof_meta| &proof_meta.proof)
        .collect();

    let receiver_proofs_json = serde_json::to_string(&receiver_proofs)
        .map_err(|e| format!("Failed to serialize receiver proofs: {e}"))?;
    let sender_proofs_json = serde_json::to_string(&sender_proofs)
        .map_err(|e| format!("Failed to serialize sender proofs: {e}"))?;

    Ok(CdkSpilmanCloseResult {
        status: CdkStatus::Ok,
        error: None,
        receiver_proofs_json: string_to_box(receiver_proofs_json),
        sender_proofs_json: string_to_box(sender_proofs_json),
        receiver_sum: result.receiver_sum,
        sender_sum: result.sender_sum,
    })
}

/// Prepare a signed post-expiry sender refund swap.
fn prepare_sender_refund_json(
    params: ChannelParameters,
    funding_proofs: Vec<Proof>,
    output_keyset: KeysetInfo,
    sender_secret_key_hex: &str,
    now_seconds: u64,
    derivation_context_hex: Option<&str>,
) -> Result<String, String> {
    let sender_secret = SecretKey::from_hex(sender_secret_key_hex)
        .map_err(|_| "Invalid sender secret key".to_string())?;
    let derivation_context = match derivation_context_hex {
        Some(hex) => parse_32_bytes(hex, "derivation context")?,
        None => [0u8; 32],
    };
    let channel = EstablishedChannel::new(params, funding_proofs)
        .map_err(|e| format!("Failed to build channel: {e}"))?;
    let prepared = channel
        .prepare_sender_refund_after_expiry(
            sender_secret,
            now_seconds,
            output_keyset,
            derivation_context,
        )
        .map_err(|e| format!("Failed to prepare sender refund: {e}"))?;
    serde_json::to_string(&prepared)
        .map_err(|e| format!("Failed to serialize prepared refund: {e}"))
}

/// Complete a prepared post-expiry sender refund from a mint swap response.
fn complete_sender_refund_json(
    params: ChannelParameters,
    funding_proofs: Vec<Proof>,
    sender_secret_key_hex: &str,
    prepared_refund_json: &str,
    swap_response_json: &str,
) -> Result<String, String> {
    let sender_secret = SecretKey::from_hex(sender_secret_key_hex)
        .map_err(|_| "Invalid sender secret key".to_string())?;
    let prepared: PreparedSenderRefund = serde_json::from_str(prepared_refund_json)
        .map_err(|e| format!("Failed to parse prepared refund: {e}"))?;
    let blind_signatures = parse_blind_signatures(swap_response_json)?;
    let channel = EstablishedChannel::new(params, funding_proofs)
        .map_err(|e| format!("Failed to build channel: {e}"))?;
    let proofs = channel
        .complete_prepared_sender_refund(&prepared, &sender_secret, blind_signatures)
        .map_err(|e| format!("Failed to complete sender refund: {e}"))?;
    serde_json::to_string(&proofs).map_err(|e| format!("Failed to serialize refund proofs: {e}"))
}

/// Verify a channel's funding proofs, returning the verification errors on
/// failure.
fn verify_valid_channel_result(
    params: &ChannelParameters,
    funding_proofs: &[Proof],
) -> Result<(), String> {
    let verification = verify_valid_channel(funding_proofs, params);
    if verification.valid {
        return Ok(());
    }
    // Redact proof secrets before serializing: `SecretMismatch` carries the
    // expected/actual secret strings, which must never be echoed back to the
    // caller in an error message.
    let redacted: Vec<cdk_spilman::ChannelVerificationError> = verification
        .errors
        .into_iter()
        .map(|err| match err {
            cdk_spilman::ChannelVerificationError::SecretMismatch { proof_index, .. } => {
                cdk_spilman::ChannelVerificationError::SecretMismatch {
                    proof_index,
                    expected: "<redacted>".to_string(),
                    actual: "<redacted>".to_string(),
                }
            }
            other => other,
        })
        .collect();
    let errors = serde_json::to_string(&redacted)
        .unwrap_or_else(|_| "[\"channel verification failed\"]".to_string());
    Err(format!("channel verification failed: {errors}"))
}

/// Verify a signed balance update against an established channel.
fn verify_balance_update_result(
    params: ChannelParameters,
    funding_proofs: Vec<Proof>,
    channel_id: &str,
    balance: u64,
    signature_hex: &str,
) -> Result<(), String> {
    if params.get_channel_id() != channel_id {
        return Err("channel id does not match the channel parameters".to_string());
    }
    let signature: Signature = signature_hex
        .parse()
        .map_err(|e| format!("Invalid signature: {e}"))?;
    let channel = EstablishedChannel::new(params, funding_proofs)
        .map_err(|e| format!("Failed to build channel: {e}"))?;
    BalanceUpdateMessage {
        channel_id: channel_id.to_string(),
        amount: balance,
        signature,
    }
    .verify_sender_signature(&channel)
    .map_err(|e| format!("Invalid balance update: {e}"))
}

// ---------------------------------------------------------------------------
// Wallet-backed exports
// ---------------------------------------------------------------------------

/// Return the mint's active Sat keyset as Spilman `KeysetInfo` JSON.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_get_active_keyset_info_json(
    handle: Option<&CdkWallet>,
    mint_url: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(handle) => handle,
                None => return CdkStringResult::err(null_handle().status, null_handle().message),
            };
            if handle.is_poisoned() {
                return CdkStringResult::err(poisoned_handle().status, poisoned_handle().message);
            }
            let mint_url = match mint_url_arg(mint_url) {
                Ok(mint_url) => mint_url,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            match runtime().block_on(handle.active_keyset_info_json(&mint_url)) {
                Ok(value) => string_ok(value),
                Err(e) => CdkStringResult::err(e.status, e.message),
            }
        },
    )
}

/// Return a single Sat keyset, by id, as Spilman `KeysetInfo` JSON.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_get_keyset_info_json(
    handle: Option<&CdkWallet>,
    mint_url: Option<char_p::Ref<'_>>,
    keyset_id: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(handle) => handle,
                None => return CdkStringResult::err(null_handle().status, null_handle().message),
            };
            if handle.is_poisoned() {
                return CdkStringResult::err(poisoned_handle().status, poisoned_handle().message);
            }
            let mint_url = match mint_url_arg(mint_url) {
                Ok(mint_url) => mint_url,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let keyset_id = match hex_arg(keyset_id, "keyset id") {
                Ok(keyset_id) => keyset_id,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            match runtime().block_on(handle.keyset_info_json(&mint_url, &keyset_id)) {
                Ok(value) => string_ok(value),
                Err(e) => CdkStringResult::err(e.status, e.message),
            }
        },
    )
}

/// Post a raw NUT-03 swap request to a mint, returning the raw response JSON.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_post_swap(
    handle: Option<&CdkWallet>,
    mint_url: Option<char_p::Ref<'_>>,
    swap_request_json: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(handle) => handle,
                None => return CdkStringResult::err(null_handle().status, null_handle().message),
            };
            if handle.is_poisoned() {
                return CdkStringResult::err(poisoned_handle().status, poisoned_handle().message);
            }
            let mint_url = match mint_url_arg(mint_url) {
                Ok(mint_url) => mint_url,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let swap_request_json = match json_arg(swap_request_json, "swap request") {
                Ok(json) => json,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            match runtime().block_on(handle.post_swap(&mint_url, &swap_request_json)) {
                Ok(value) => string_ok(value),
                Err(e) => CdkStringResult::err(e.status, e.message),
            }
        },
    )
}

/// Receive a token, optionally supplying comma-separated P2PK signing keys.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_receive_with_keys(
    handle: Option<&mut CdkWallet>,
    token: Option<char_p::Ref<'_>>,
    signing_key_hex: Option<char_p::Ref<'_>>,
) -> CdkReceiveResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || receive_error(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(handle) => handle,
                None => return receive_error(null_handle().status, null_handle().message),
            };
            if handle.is_poisoned() {
                return receive_error(poisoned_handle().status, poisoned_handle().message);
            }
            let token = match json_arg(token, "token") {
                Ok(token) => token,
                Err(e) => return receive_error(e.status, e.message),
            };
            let signing_keys = match parse_signing_keys(signing_key_hex) {
                Ok(keys) => keys,
                Err(e) => return receive_error(e.status, e.message),
            };
            match runtime().block_on(handle.receive_with_keys(&token, &signing_keys)) {
                Ok(net_sats) => receive_sats(net_sats),
                Err(e) => receive_error(e.status, e.message),
            }
        },
    )
}

/// Receive raw proofs from a mint, optionally supplying P2PK signing keys.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_receive_proofs(
    handle: Option<&mut CdkWallet>,
    mint_url: Option<char_p::Ref<'_>>,
    proofs_json: Option<char_p::Ref<'_>>,
    signing_key_hex: Option<char_p::Ref<'_>>,
) -> CdkReceiveResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || receive_error(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(handle) => handle,
                None => return receive_error(null_handle().status, null_handle().message),
            };
            if handle.is_poisoned() {
                return receive_error(poisoned_handle().status, poisoned_handle().message);
            }
            let mint_url = match mint_url_arg(mint_url) {
                Ok(mint_url) => mint_url,
                Err(e) => return receive_error(e.status, e.message),
            };
            let proofs_json = match json_arg(proofs_json, "proofs") {
                Ok(proofs) => proofs,
                Err(e) => return receive_error(e.status, e.message),
            };
            let proofs: Proofs = match serde_json::from_str(&proofs_json) {
                Ok(proofs) => proofs,
                Err(e) => {
                    return receive_error(
                        CdkStatus::InvalidArgument,
                        format!("invalid proofs JSON: {e}"),
                    )
                }
            };
            let signing_keys = match parse_signing_keys(signing_key_hex) {
                Ok(keys) => keys,
                Err(e) => return receive_error(e.status, e.message),
            };
            match runtime().block_on(handle.receive_proofs(&mint_url, proofs, &signing_keys)) {
                Ok(net_sats) => receive_sats(net_sats),
                Err(e) => receive_error(e.status, e.message),
            }
        },
    )
}

// ---------------------------------------------------------------------------
// Pure conversion exports
// ---------------------------------------------------------------------------

/// Build a `cashuB` (v4) token from a mint URL, unit, and proofs JSON.
#[ffi_export]
pub fn cdk_spilman_build_cashu_b_token(
    mint_url: Option<char_p::Ref<'_>>,
    unit: Option<char_p::Ref<'_>>,
    proofs_json: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let mint_url = match mint_url_arg(mint_url) {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let unit = match hex_arg(unit, "unit") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let proofs_json = match json_arg(proofs_json, "proofs") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            spilman_string(build_cashu_b_token(&mint_url, &unit, &proofs_json))
        },
    )
}

/// Build a `cashuA` (v3) token from a mint URL and proofs JSON.
#[ffi_export]
pub fn cdk_spilman_build_cashu_a_token(
    mint_url: Option<char_p::Ref<'_>>,
    proofs_json: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let mint_url = match mint_url_arg(mint_url) {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let proofs_json = match json_arg(proofs_json, "proofs") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            spilman_string(build_cashu_a_token(&mint_url, &proofs_json))
        },
    )
}

/// Decode a token's proofs into JSON, expanding short keyset ids using the
/// supplied keyset info.
#[ffi_export]
pub fn cdk_token_to_proofs_json(
    token: Option<char_p::Ref<'_>>,
    keyset_info_json: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let token_str = match json_arg(token, "token") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let keyset_info_json = match json_arg(keyset_info_json, "keyset info") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };

            let token: Token = match token_str.parse() {
                Ok(token) => token,
                Err(e) => {
                    return CdkStringResult::err(
                        CdkStatus::InvalidArgument,
                        format!("invalid token: {e}"),
                    )
                }
            };
            let keyset = match parse_keyset_info_from_json(&keyset_info_json) {
                Ok(keyset) => keyset,
                Err(e) => return CdkStringResult::err(CdkStatus::InvalidArgument, e),
            };
            let info = cdk::nuts::KeySetInfo {
                id: keyset.keyset_id,
                unit: keyset.unit,
                active: true,
                input_fee_ppk: keyset.input_fee_ppk,
                final_expiry: keyset.final_expiry,
            };
            match token.proofs(&[info]) {
                Ok(proofs) => match serde_json::to_string(&proofs) {
                    Ok(json) => string_ok(json),
                    Err(e) => CdkStringResult::err(
                        CdkStatus::InternalError,
                        format!("could not serialize proofs: {e}"),
                    ),
                },
                Err(e) => CdkStringResult::err(
                    CdkStatus::InvalidArgument,
                    format!("could not derive proofs: {e}"),
                ),
            }
        },
    )
}

/// Generate a fresh Spilman keypair (secret key plus public key).
#[ffi_export]
pub fn cdk_spilman_generate_keypair() -> CdkSpilmanKeypairResult {
    guard(
        || CdkSpilmanKeypairResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let secret_key = SecretKey::generate();
            let secret_key_hex = Zeroizing::new(secret_key.to_secret_hex());
            CdkSpilmanKeypairResult {
                status: CdkStatus::Ok,
                error: None,
                secret_key_hex: string_to_box(secret_key_hex.as_str().to_owned()),
                pubkey_hex: string_to_box(secret_key.public_key().to_hex()),
            }
        },
    )
}

/// Derive the public key for a secret key (both hex-encoded).
#[ffi_export]
pub fn cdk_spilman_secret_key_to_pubkey(
    secret_key_hex: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let secret_key_hex = match secret_hex_arg(secret_key_hex, "secret key") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            match SecretKey::from_hex(&secret_key_hex) {
                Ok(secret_key) => string_ok(secret_key.public_key().to_hex()),
                Err(e) => CdkStringResult::err(
                    CdkStatus::InvalidArgument,
                    format!("Invalid secret key: {e}"),
                ),
            }
        },
    )
}

/// Compute the shared channel secret from my secret key and their public key.
#[ffi_export]
pub fn cdk_spilman_compute_channel_secret(
    my_secret_key_hex: Option<char_p::Ref<'_>>,
    their_pubkey_hex: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let my_secret_key_hex = match secret_hex_arg(my_secret_key_hex, "secret key") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let their_pubkey_hex = match hex_arg(their_pubkey_hex, "public key") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            spilman_string(compute_channel_secret_from_hex(
                &my_secret_key_hex,
                &their_pubkey_hex,
            ))
        },
    )
}

/// Compute the minimum funding-token amount for a channel capacity.
#[ffi_export]
pub fn cdk_spilman_compute_funding_token_amount(
    capacity: u64,
    keyset_info_json: Option<char_p::Ref<'_>>,
    maximum_amount_for_one_output: u64,
) -> CdkReceiveResult {
    guard(
        || receive_error(CdkStatus::InternalError, "internal panic"),
        || {
            let keyset_info_json = match json_arg(keyset_info_json, "keyset info") {
                Ok(value) => value,
                Err(e) => return receive_error(e.status, e.message),
            };
            match compute_funding_token_amount(
                capacity,
                &keyset_info_json,
                maximum_amount_for_one_output,
            ) {
                Ok(amount) => receive_sats(amount),
                Err(e) => receive_error(CdkStatus::InvalidArgument, e),
            }
        },
    )
}

/// Reconstruct channel parameters from a funding token and both public keys.
#[ffi_export]
pub fn cdk_spilman_compute_channel_from_token(
    token_string: Option<char_p::Ref<'_>>,
    receiver_pubkey_hex: Option<char_p::Ref<'_>>,
    sender_pubkey_hex: Option<char_p::Ref<'_>>,
    channel_secret_hex: Option<char_p::Ref<'_>>,
    expiry_timestamp: u64,
    keyset_info_json: Option<char_p::Ref<'_>>,
    maximum_amount_for_one_output: u64,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let token_string = match json_arg(token_string, "token") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let receiver_pubkey_hex = match hex_arg(receiver_pubkey_hex, "receiver public key") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let sender_pubkey_hex = match hex_arg(sender_pubkey_hex, "sender public key") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let channel_secret_hex = match secret_hex_arg(channel_secret_hex, "channel secret") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let keyset_info_json = match json_arg(keyset_info_json, "keyset info") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            spilman_string(compute_channel_from_token(
                &token_string,
                &receiver_pubkey_hex,
                &sender_pubkey_hex,
                &channel_secret_hex,
                expiry_timestamp,
                &keyset_info_json,
                maximum_amount_for_one_output,
                None,
            ))
        },
    )
}

/// Compute a channel id from channel parameters and a channel secret.
#[ffi_export]
pub fn cdk_spilman_channel_parameters_get_channel_id(
    params_json: Option<char_p::Ref<'_>>,
    channel_secret_hex: Option<char_p::Ref<'_>>,
    keyset_info_json: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let params_json = match json_arg(params_json, "channel parameters") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let channel_secret_hex = match secret_hex_arg(channel_secret_hex, "channel secret") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let keyset_info_json = match json_arg(keyset_info_json, "keyset info") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            spilman_string(channel_parameters_get_channel_id(
                &params_json,
                &channel_secret_hex,
                &keyset_info_json,
            ))
        },
    )
}

/// Build the funding outputs for a channel.
///
/// The receiver key used for derivation is taken from `params_json`, matching
/// the upstream three-argument helper.
#[ffi_export]
pub fn cdk_spilman_create_funding_outputs(
    params_json: Option<char_p::Ref<'_>>,
    sender_privkey_hex: Option<char_p::Ref<'_>>,
    keyset_info_json: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let params_json = match json_arg(params_json, "channel parameters") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let sender_privkey_hex = match secret_hex_arg(sender_privkey_hex, "sender secret key") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let keyset_info_json = match json_arg(keyset_info_json, "keyset info") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };

            spilman_string(create_funding_outputs(
                &params_json,
                &sender_privkey_hex,
                &keyset_info_json,
            ))
        },
    )
}

/// Build a funding swap request from channel parameters and input proofs.
#[ffi_export]
pub fn cdk_spilman_create_funding_swap(
    params_json: Option<char_p::Ref<'_>>,
    channel_secret_hex: Option<char_p::Ref<'_>>,
    keyset_info_json: Option<char_p::Ref<'_>>,
    input_proofs_json: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let params_json = match json_arg(params_json, "channel parameters") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let channel_secret_hex = match secret_hex_arg(channel_secret_hex, "channel secret") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let keyset_info_json = match json_arg(keyset_info_json, "keyset info") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let input_proofs_json = match json_arg(input_proofs_json, "input proofs") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            spilman_string(create_funding_swap(
                &params_json,
                &channel_secret_hex,
                &keyset_info_json,
                &input_proofs_json,
            ))
        },
    )
}

/// Complete a funding swap from the mint's response and the funding secrets.
#[ffi_export]
pub fn cdk_spilman_complete_funding_swap(
    swap_response_json: Option<char_p::Ref<'_>>,
    funding_secrets_json: Option<char_p::Ref<'_>>,
    keyset_info_json: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let swap_response_json = match json_arg(swap_response_json, "swap response") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let funding_secrets_json = match json_arg(funding_secrets_json, "funding secrets") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let keyset_info_json = match json_arg(keyset_info_json, "keyset info") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            spilman_string(complete_funding_swap(
                &swap_response_json,
                &funding_secrets_json,
                &keyset_info_json,
            ))
        },
    )
}

/// Construct proofs from blind signatures and their secrets/blinding factors.
#[ffi_export]
pub fn cdk_spilman_construct_proofs(
    blind_signatures_json: Option<char_p::Ref<'_>>,
    secrets_with_blinding_json: Option<char_p::Ref<'_>>,
    keyset_info_json: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let blind_signatures_json = match json_arg(blind_signatures_json, "blind signatures") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let secrets_with_blinding_json =
                match json_arg(secrets_with_blinding_json, "secrets with blinding") {
                    Ok(value) => value,
                    Err(e) => return CdkStringResult::err(e.status, e.message),
                };
            let keyset_info_json = match json_arg(keyset_info_json, "keyset info") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            spilman_string(construct_proofs(
                &blind_signatures_json,
                &secrets_with_blinding_json,
                &keyset_info_json,
            ))
        },
    )
}

/// Create a signed balance update for a channel.
#[ffi_export]
pub fn cdk_spilman_create_signed_balance_update(
    params_json: Option<char_p::Ref<'_>>,
    keyset_info_json: Option<char_p::Ref<'_>>,
    secret_key_hex: Option<char_p::Ref<'_>>,
    proofs_json: Option<char_p::Ref<'_>>,
    balance: u64,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let params_json = match json_arg(params_json, "channel parameters") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let keyset_info_json = match json_arg(keyset_info_json, "keyset info") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let secret_key_hex = match secret_hex_arg(secret_key_hex, "secret key") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let proofs_json = match json_arg(proofs_json, "proofs") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            spilman_string(create_signed_balance_update(
                &params_json,
                &keyset_info_json,
                &secret_key_hex,
                &proofs_json,
                balance,
            ))
        },
    )
}

/// Create an unsigned balance update for a channel.
#[ffi_export]
pub fn cdk_spilman_create_unsigned_balance_update(
    params_json: Option<char_p::Ref<'_>>,
    keyset_info_json: Option<char_p::Ref<'_>>,
    channel_secret_hex: Option<char_p::Ref<'_>>,
    proofs_json: Option<char_p::Ref<'_>>,
    balance: u64,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let params_json = match json_arg(params_json, "channel parameters") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let keyset_info_json = match json_arg(keyset_info_json, "keyset info") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let channel_secret_hex = match secret_hex_arg(channel_secret_hex, "channel secret") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let proofs_json = match json_arg(proofs_json, "proofs") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            spilman_string(create_unsigned_balance_update(
                &params_json,
                &keyset_info_json,
                &channel_secret_hex,
                &proofs_json,
                balance,
            ))
        },
    )
}

/// Sign a message with a secret key tweaked by a scalar (all hex-encoded).
#[ffi_export]
pub fn cdk_spilman_sign_with_tweaked_key_util(
    secret_key_hex: Option<char_p::Ref<'_>>,
    message_hex: Option<char_p::Ref<'_>>,
    tweak_scalar_hex: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let secret_key_hex = match secret_hex_arg(secret_key_hex, "secret key") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let message_hex = match hex_arg(message_hex, "message") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let tweak_scalar_hex = match hex_arg(tweak_scalar_hex, "tweak scalar") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            spilman_string(sign_with_tweaked_key_util(
                &secret_key_hex,
                &message_hex,
                &tweak_scalar_hex,
            ))
        },
    )
}

/// Attach a signature to an unsigned balance-update swap request.
#[ffi_export]
pub fn cdk_spilman_attach_signature_to_balance_update(
    unsigned_swap_request_json: Option<char_p::Ref<'_>>,
    signature_hex: Option<char_p::Ref<'_>>,
    channel_id: Option<char_p::Ref<'_>>,
    amount: u64,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let unsigned_swap_request_json =
                match json_arg(unsigned_swap_request_json, "unsigned swap request") {
                    Ok(value) => value,
                    Err(e) => return CdkStringResult::err(e.status, e.message),
                };
            let signature_hex = match hex_arg(signature_hex, "signature") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let channel_id = match hex_arg(channel_id, "channel id") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            spilman_string(attach_signature_to_balance_update(
                &unsigned_swap_request_json,
                &signature_hex,
                &channel_id,
                amount,
            ))
        },
    )
}

/// Verify that a channel's funding proofs are valid.
#[ffi_export]
pub fn cdk_spilman_verify_valid_channel(
    params_json: Option<char_p::Ref<'_>>,
    channel_secret_hex: Option<char_p::Ref<'_>>,
    keyset_info_json: Option<char_p::Ref<'_>>,
    funding_proofs_json: Option<char_p::Ref<'_>>,
) -> CdkStatusResult {
    guard(
        || CdkStatusResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let params_json = match json_arg(params_json, "channel parameters") {
                Ok(value) => value,
                Err(e) => return CdkStatusResult::err(e.status, e.message),
            };
            let channel_secret_hex = match secret_hex_arg(channel_secret_hex, "channel secret") {
                Ok(value) => value,
                Err(e) => return CdkStatusResult::err(e.status, e.message),
            };
            let keyset_info_json = match json_arg(keyset_info_json, "keyset info") {
                Ok(value) => value,
                Err(e) => return CdkStatusResult::err(e.status, e.message),
            };
            let funding_proofs_json = match json_arg(funding_proofs_json, "funding proofs") {
                Ok(value) => value,
                Err(e) => return CdkStatusResult::err(e.status, e.message),
            };

            let params = match parse_params(&params_json, &channel_secret_hex, &keyset_info_json) {
                Ok(params) => params,
                Err(e) => return CdkStatusResult::err(CdkStatus::InvalidArgument, e),
            };
            let funding_proofs = match parse_proofs(&funding_proofs_json) {
                Ok(proofs) => proofs,
                Err(e) => return CdkStatusResult::err(CdkStatus::InvalidArgument, e),
            };
            match verify_valid_channel_result(&params, &funding_proofs) {
                Ok(()) => status_ok(),
                Err(e) => CdkStatusResult::err(CdkStatus::InvalidArgument, e),
            }
        },
    )
}

/// Verify a signed balance update against a channel's funding proofs.
#[ffi_export]
pub fn cdk_spilman_verify_balance_update(
    params_json: Option<char_p::Ref<'_>>,
    channel_secret_hex: Option<char_p::Ref<'_>>,
    keyset_info_json: Option<char_p::Ref<'_>>,
    funding_proofs_json: Option<char_p::Ref<'_>>,
    channel_id: Option<char_p::Ref<'_>>,
    balance: u64,
    signature_hex: Option<char_p::Ref<'_>>,
) -> CdkStatusResult {
    guard(
        || CdkStatusResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let params_json = match json_arg(params_json, "channel parameters") {
                Ok(value) => value,
                Err(e) => return CdkStatusResult::err(e.status, e.message),
            };
            let channel_secret_hex = match secret_hex_arg(channel_secret_hex, "channel secret") {
                Ok(value) => value,
                Err(e) => return CdkStatusResult::err(e.status, e.message),
            };
            let keyset_info_json = match json_arg(keyset_info_json, "keyset info") {
                Ok(value) => value,
                Err(e) => return CdkStatusResult::err(e.status, e.message),
            };
            let funding_proofs_json = match json_arg(funding_proofs_json, "funding proofs") {
                Ok(value) => value,
                Err(e) => return CdkStatusResult::err(e.status, e.message),
            };
            let channel_id = match hex_arg(channel_id, "channel id") {
                Ok(value) => value,
                Err(e) => return CdkStatusResult::err(e.status, e.message),
            };
            let signature_hex = match hex_arg(signature_hex, "signature") {
                Ok(value) => value,
                Err(e) => return CdkStatusResult::err(e.status, e.message),
            };

            let params = match parse_params(&params_json, &channel_secret_hex, &keyset_info_json) {
                Ok(params) => params,
                Err(e) => return CdkStatusResult::err(CdkStatus::InvalidArgument, e),
            };
            let funding_proofs = match parse_proofs(&funding_proofs_json) {
                Ok(proofs) => proofs,
                Err(e) => return CdkStatusResult::err(CdkStatus::InvalidArgument, e),
            };
            match verify_balance_update_result(
                params,
                funding_proofs,
                &channel_id,
                balance,
                &signature_hex,
            ) {
                Ok(()) => status_ok(),
                Err(e) => CdkStatusResult::err(CdkStatus::InvalidArgument, e),
            }
        },
    )
}

/// Prepare a cooperative close swap request signed by both parties.
#[ffi_export]
pub fn cdk_spilman_prepare_close_swap(
    params_json: Option<char_p::Ref<'_>>,
    channel_secret_hex: Option<char_p::Ref<'_>>,
    funding_keyset_info_json: Option<char_p::Ref<'_>>,
    output_keyset_info_json: Option<char_p::Ref<'_>>,
    funding_proofs_json: Option<char_p::Ref<'_>>,
    balance: u64,
    sender_signature_hex: Option<char_p::Ref<'_>>,
    receiver_secret_key_hex: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let params_json = match json_arg(params_json, "channel parameters") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let channel_secret_hex = match secret_hex_arg(channel_secret_hex, "channel secret") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let funding_keyset_info_json =
                match json_arg(funding_keyset_info_json, "funding keyset info") {
                    Ok(value) => value,
                    Err(e) => return CdkStringResult::err(e.status, e.message),
                };
            let output_keyset_info_json =
                match json_arg(output_keyset_info_json, "output keyset info") {
                    Ok(value) => value,
                    Err(e) => return CdkStringResult::err(e.status, e.message),
                };
            let funding_proofs_json = match json_arg(funding_proofs_json, "funding proofs") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let sender_signature_hex = match hex_arg(sender_signature_hex, "sender signature") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let receiver_secret_key_hex =
                match secret_hex_arg(receiver_secret_key_hex, "receiver secret key") {
                    Ok(value) => value,
                    Err(e) => return CdkStringResult::err(e.status, e.message),
                };

            let params =
                match parse_params(&params_json, &channel_secret_hex, &funding_keyset_info_json) {
                    Ok(params) => params,
                    Err(e) => return CdkStringResult::err(CdkStatus::InvalidArgument, e),
                };
            let output_keyset = match parse_keyset_info_from_json(&output_keyset_info_json) {
                Ok(keyset) => keyset,
                Err(e) => return CdkStringResult::err(CdkStatus::InvalidArgument, e),
            };
            let funding_proofs = match parse_proofs(&funding_proofs_json) {
                Ok(proofs) => proofs,
                Err(e) => return CdkStringResult::err(CdkStatus::InvalidArgument, e),
            };
            spilman_string(prepare_close_swap_json(
                &params,
                &output_keyset,
                funding_proofs,
                balance,
                &sender_signature_hex,
                &receiver_secret_key_hex,
            ))
        },
    )
}

/// Unblind a close swap response and sign the receiver's proofs.
#[ffi_export]
pub fn cdk_spilman_unblind_close_swap(
    params_json: Option<char_p::Ref<'_>>,
    channel_secret_hex: Option<char_p::Ref<'_>>,
    funding_keyset_info_json: Option<char_p::Ref<'_>>,
    output_keyset_info_json: Option<char_p::Ref<'_>>,
    secrets_with_blinding_json: Option<char_p::Ref<'_>>,
    swap_response_json: Option<char_p::Ref<'_>>,
    balance: u64,
    receiver_secret_key_hex: Option<char_p::Ref<'_>>,
) -> CdkSpilmanCloseResult {
    guard(
        || CdkSpilmanCloseResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let params_json = match json_arg(params_json, "channel parameters") {
                Ok(value) => value,
                Err(e) => return CdkSpilmanCloseResult::err(e.status, e.message),
            };
            let channel_secret_hex = match secret_hex_arg(channel_secret_hex, "channel secret") {
                Ok(value) => value,
                Err(e) => return CdkSpilmanCloseResult::err(e.status, e.message),
            };
            let funding_keyset_info_json =
                match json_arg(funding_keyset_info_json, "funding keyset info") {
                    Ok(value) => value,
                    Err(e) => return CdkSpilmanCloseResult::err(e.status, e.message),
                };
            let output_keyset_info_json =
                match json_arg(output_keyset_info_json, "output keyset info") {
                    Ok(value) => value,
                    Err(e) => return CdkSpilmanCloseResult::err(e.status, e.message),
                };
            let secrets_with_blinding_json =
                match json_arg(secrets_with_blinding_json, "secrets with blinding") {
                    Ok(value) => value,
                    Err(e) => return CdkSpilmanCloseResult::err(e.status, e.message),
                };
            let swap_response_json = match json_arg(swap_response_json, "swap response") {
                Ok(value) => value,
                Err(e) => return CdkSpilmanCloseResult::err(e.status, e.message),
            };
            let receiver_secret_key_hex =
                match opt_secret_hex_arg(receiver_secret_key_hex, "receiver secret key") {
                    Ok(value) => value,
                    Err(e) => return CdkSpilmanCloseResult::err(e.status, e.message),
                };

            let params =
                match parse_params(&params_json, &channel_secret_hex, &funding_keyset_info_json) {
                    Ok(params) => params,
                    Err(e) => return CdkSpilmanCloseResult::err(CdkStatus::InvalidArgument, e),
                };
            let output_keyset = match parse_keyset_info_from_json(&output_keyset_info_json) {
                Ok(keyset) => keyset,
                Err(e) => return CdkSpilmanCloseResult::err(CdkStatus::InvalidArgument, e),
            };
            let secrets_with_blinding =
                match parse_secrets_with_blinding(&secrets_with_blinding_json) {
                    Ok(secrets) => secrets,
                    Err(e) => return CdkSpilmanCloseResult::err(CdkStatus::InvalidArgument, e),
                };
            let blind_signatures = match parse_blind_signatures(&swap_response_json) {
                Ok(signatures) => signatures,
                Err(e) => return CdkSpilmanCloseResult::err(CdkStatus::InvalidArgument, e),
            };

            match unblind_close_swap(
                &params,
                &output_keyset,
                secrets_with_blinding,
                blind_signatures,
                balance,
                receiver_secret_key_hex.as_ref().map(|s| s.as_str()),
            ) {
                Ok(result) => result,
                Err(e) => CdkSpilmanCloseResult::err(CdkStatus::InvalidArgument, e),
            }
        },
    )
}

/// Prepare a signed post-expiry sender refund swap.
#[ffi_export]
pub fn cdk_spilman_prepare_sender_refund(
    params_json: Option<char_p::Ref<'_>>,
    channel_secret_hex: Option<char_p::Ref<'_>>,
    funding_keyset_info_json: Option<char_p::Ref<'_>>,
    output_keyset_info_json: Option<char_p::Ref<'_>>,
    funding_proofs_json: Option<char_p::Ref<'_>>,
    sender_secret_key_hex: Option<char_p::Ref<'_>>,
    now_seconds: u64,
    derivation_context_hex: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let params_json = match json_arg(params_json, "channel parameters") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let channel_secret_hex = match secret_hex_arg(channel_secret_hex, "channel secret") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let funding_keyset_info_json =
                match json_arg(funding_keyset_info_json, "funding keyset info") {
                    Ok(value) => value,
                    Err(e) => return CdkStringResult::err(e.status, e.message),
                };
            let output_keyset_info_json =
                match json_arg(output_keyset_info_json, "output keyset info") {
                    Ok(value) => value,
                    Err(e) => return CdkStringResult::err(e.status, e.message),
                };
            let funding_proofs_json = match json_arg(funding_proofs_json, "funding proofs") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let sender_secret_key_hex =
                match secret_hex_arg(sender_secret_key_hex, "sender secret key") {
                    Ok(value) => value,
                    Err(e) => return CdkStringResult::err(e.status, e.message),
                };
            let derivation_context_hex =
                match opt_secret_hex_arg(derivation_context_hex, "derivation context") {
                    Ok(value) => value,
                    Err(e) => return CdkStringResult::err(e.status, e.message),
                };

            let params =
                match parse_params(&params_json, &channel_secret_hex, &funding_keyset_info_json) {
                    Ok(params) => params,
                    Err(e) => return CdkStringResult::err(CdkStatus::InvalidArgument, e),
                };
            let output_keyset = match parse_keyset_info_from_json(&output_keyset_info_json) {
                Ok(keyset) => keyset,
                Err(e) => return CdkStringResult::err(CdkStatus::InvalidArgument, e),
            };
            let funding_proofs = match parse_proofs(&funding_proofs_json) {
                Ok(proofs) => proofs,
                Err(e) => return CdkStringResult::err(CdkStatus::InvalidArgument, e),
            };
            spilman_string(prepare_sender_refund_json(
                params,
                funding_proofs,
                output_keyset,
                &sender_secret_key_hex,
                now_seconds,
                derivation_context_hex.as_ref().map(|s| s.as_str()),
            ))
        },
    )
}

/// Complete a prepared post-expiry sender refund from a mint swap response.
#[ffi_export]
pub fn cdk_spilman_complete_sender_refund(
    params_json: Option<char_p::Ref<'_>>,
    channel_secret_hex: Option<char_p::Ref<'_>>,
    funding_keyset_info_json: Option<char_p::Ref<'_>>,
    funding_proofs_json: Option<char_p::Ref<'_>>,
    sender_secret_key_hex: Option<char_p::Ref<'_>>,
    prepared_refund_json: Option<char_p::Ref<'_>>,
    swap_response_json: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    guard(
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let params_json = match json_arg(params_json, "channel parameters") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let channel_secret_hex = match secret_hex_arg(channel_secret_hex, "channel secret") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let funding_keyset_info_json =
                match json_arg(funding_keyset_info_json, "funding keyset info") {
                    Ok(value) => value,
                    Err(e) => return CdkStringResult::err(e.status, e.message),
                };
            let funding_proofs_json = match json_arg(funding_proofs_json, "funding proofs") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let sender_secret_key_hex =
                match secret_hex_arg(sender_secret_key_hex, "sender secret key") {
                    Ok(value) => value,
                    Err(e) => return CdkStringResult::err(e.status, e.message),
                };
            let prepared_refund_json = match json_arg(prepared_refund_json, "prepared refund") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };
            let swap_response_json = match json_arg(swap_response_json, "swap response") {
                Ok(value) => value,
                Err(e) => return CdkStringResult::err(e.status, e.message),
            };

            let params =
                match parse_params(&params_json, &channel_secret_hex, &funding_keyset_info_json) {
                    Ok(params) => params,
                    Err(e) => return CdkStringResult::err(CdkStatus::InvalidArgument, e),
                };
            let funding_proofs = match parse_proofs(&funding_proofs_json) {
                Ok(proofs) => proofs,
                Err(e) => return CdkStringResult::err(CdkStatus::InvalidArgument, e),
            };
            spilman_string(complete_sender_refund_json(
                params,
                funding_proofs,
                &sender_secret_key_hex,
                &prepared_refund_json,
                &swap_response_json,
            ))
        },
    )
}
