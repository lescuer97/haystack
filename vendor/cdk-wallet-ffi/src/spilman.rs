//! Spilman payment-channel primitives exposed over the C ABI.
//!
//! This module layers two things on top of the core wallet ABI:
//!
//! * five wallet-backed helpers that expose the pieces a Spilman flow needs
//!   from the local wallet (keyset info, raw NUT-03 swaps, and receiving
//!   proofs/tokens that may be P2PK-locked);
//! * twenty-three pure conversion helpers that wrap the upstream
//!   [`cdk_spilman`] crate (a Git dependency at an exact release commit), so
//!   the Zig side can drive channel setup, balance updates, cooperative close,
//!   and post-expiry sender refunds without reimplementing any of the
//!   cryptography.
//!
//! Every function is panic-safe, returns a fixed-width status, and never echoes
//! secret material in an error message. Secret-key and channel-secret hex inputs
//! are wrapped in [`Zeroizing`] for their whole lifetime in this module.

use safer_ffi::prelude::*;
use zeroize::Zeroizing;

use cdk::nuts::{BlindSignature, CurrencyUnit, Id, Proof, Proofs, PublicKey, SecretKey, Token};
use cdk::secp256k1::schnorr::Signature;
use cdk::util::hex;
use cdk_spilman::{
    attach_signature_to_balance_update, build_cashu_a_token, build_cashu_b_token,
    channel_parameters_get_channel_id, complete_funding_swap, compute_channel_from_token,
    compute_channel_secret_from_hex, compute_funding_token_amount, construct_proofs,
    create_funding_outputs, create_funding_swap, create_signed_balance_update,
    create_unsigned_balance_update, parse_keyset_info_from_json, sign_with_tweaked_key_util,
    unblind_and_verify_stage1_response, verify_valid_channel, BalanceUpdateMessage, BridgeError,
    ChannelFunding, ChannelParameters, ChannelState, ClosingData, DeterministicSecretWithBlinding,
    EstablishedChannel, KeysetInfo, PaymentProof, PreparedSenderRefund, SpilmanBridge, SpilmanHost,
};

use crate::api::{
    guard, guard_poison, null_handle, opt_cstr_to_string_bounded, poisoned_handle, receive_error,
};
use crate::status::{
    string_to_box, CdkReceiveResult, CdkSpilmanAmountResult, CdkSpilmanCloseResult, CdkSpilmanKeypairResult, CdkStatus,
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
/// The upstream helpers report structural / validation failures as plain
/// strings, so every failure maps to [`CdkStatus::InvalidArgument`].
fn spilman_string(result: Result<String, String>) -> CdkStringResult {
    match result {
        Ok(value) => string_ok(value),
        Err(message) => CdkStringResult::err(CdkStatus::InvalidArgument, message),
    }
}

/// A success [`CdkReceiveResult`] carrying `net_msats`.
fn receive_msats(net_msats: u64) -> CdkReceiveResult {
    CdkReceiveResult {
        status: CdkStatus::Ok,
        error: None,
        net_msats,
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

/// Fixed diagnostic for a host capability this one-call adapter must never use.
///
/// The cooperative-close path only reads the arguments it was given; anything
/// that would persist, refresh keysets, or reach the network is a programming
/// error, so the adapter refuses instead of pretending the mutation succeeded.
/// No secret material is ever part of this text.
const CLOSE_PREPARATION_UNSUPPORTED_HOST_CALL: &str =
    "close preparation host does not support this operation";

/// Panic guard for the trait's void mutators.
///
/// [`SpilmanHost`] declares two mutators that return no value, so a failure
/// cannot be reported through `Result`. Refusing by panic (instead of silently
/// dropping the write) is caught by the ABI's panic guard and surfaces as an
/// internal error; nothing is persisted and no material is logged.
fn close_preparation_reject_mutation(operation: &'static str) -> ! {
    panic!("{CLOSE_PREPARATION_UNSUPPORTED_HOST_CALL}: {operation}")
}

/// Single-call [`SpilmanHost`] for cooperative-close preparation.
///
/// The upstream bridge is built around a stateful host that owns storage,
/// keysets, and the receiver's signing capability. This ABI is stateless, so
/// the host is constructed per call from arguments the caller already supplied
/// and answers only the questions the close-preparation path asks:
///
/// * the channel identity must be the one derived from the caller's own
///   channel parameters; every other identity is unknown;
/// * the amount due is the caller's recipient balance, so the bridge's
///   due-check cannot silently rewrite the signed commitment;
/// * the only active keyset is the caller-selected output keyset, returned
///   unchanged (never re-selected, refreshed, or replaced);
/// * the clock is a synthetic `0` so the bridge's keyset-expiry filter keeps
///   this adapter's historical behaviour (no expiry narrowing is introduced
///   here, including `final_expiry = 0` and already-expired test keysets);
/// * the receiver signature is produced only after the bridge has verified the
///   sender signature, and only after this adapter checks that the supplied
///   receiver secret key owns the channel's receiver public key.
struct ClosePreparationHost {
    /// Channel id derived from the caller's channel parameters.
    channel_id: String,
    /// Funding material parsed from the caller's arguments.
    funding: ChannelFunding,
    /// Caller-selected close output keyset.
    output_keyset: KeysetInfo,
    /// The same keyset as the caller's JSON, returned byte-for-byte.
    output_keyset_json: String,
    /// Recipient balance the sender signed.
    amount_due: u64,
    /// Receiver secret key, zeroized for the host's lifetime.
    receiver_secret_key_hex: Zeroizing<String>,
    /// Channel receiver public key the secret must own.
    receiver_pubkey: PublicKey,
}

impl SpilmanHost<String> for ClosePreparationHost {
    fn receiver_key_is_acceptable(&self, receiver_pubkey: &PublicKey) -> bool {
        receiver_pubkey == &self.receiver_pubkey
    }

    fn mint_and_keyset_is_acceptable(&self, _mint: &str, keyset_id: &Id) -> bool {
        keyset_id == &self.output_keyset.keyset_id
    }

    fn get_funding(&self, channel_id: &str) -> Option<ChannelFunding> {
        (channel_id == self.channel_id).then(|| self.funding.clone())
    }

    fn save_funding(
        &self,
        _channel_id: &str,
        _funding: ChannelFunding,
        _initial_payment: PaymentProof,
    ) {
        close_preparation_reject_mutation("save_funding")
    }

    fn get_amount_due(&self, channel_id: &str, _context: Option<&String>) -> u64 {
        if channel_id == self.channel_id {
            self.amount_due
        } else {
            0
        }
    }

    fn record_payment(&self, _channel_id: &str, _payment: PaymentProof, _context: &String) {
        close_preparation_reject_mutation("record_payment")
    }

    fn get_channel_state(&self, channel_id: &str) -> Result<Option<ChannelState>, String> {
        // The caller is closing a channel it just described; the adapter has no
        // stored lifecycle and must not report a closed channel it cannot know.
        Ok((channel_id == self.channel_id).then_some(ChannelState::Open))
    }

    fn mark_channel_closing(
        &self,
        _channel_id: &str,
        _expiry_timestamp: u64,
        _payment: PaymentProof,
    ) -> Result<(), String> {
        Err(CLOSE_PREPARATION_UNSUPPORTED_HOST_CALL.to_string())
    }

    fn get_closing_data(&self, _channel_id: &str) -> Option<ClosingData> {
        None
    }

    fn get_channel_policy(&self, _unit: &str) -> Option<cdk_spilman::ChannelPolicy> {
        None
    }

    fn now_seconds(&self) -> u64 {
        // Synthetic clock: keeps the bridge's `is_unexpired_at` filter true for
        // every keyset, including `final_expiry = 0`, so this adapter performs
        // exactly the expiry checking it always did (none).
        0
    }

    fn get_balance_and_signature_for_unilateral_exit(
        &self,
        _channel_id: &str,
    ) -> Option<PaymentProof> {
        None
    }

    fn get_active_keyset_ids(&self, _mint: &str, _unit: &CurrencyUnit) -> Vec<Id> {
        // Only the caller's keyset; the bridge must not choose another one.
        vec![self.output_keyset.keyset_id]
    }

    fn has_keysets_for_unit(&self, _mint: &str, _unit: &CurrencyUnit) -> bool {
        false
    }

    fn get_keyset_info(&self, _mint: &str, keyset_id: &Id) -> Option<String> {
        (keyset_id == &self.output_keyset.keyset_id).then(|| self.output_keyset_json.clone())
    }

    #[allow(clippy::too_many_arguments)]
    fn mark_channel_closed(
        &self,
        _channel_id: &str,
        _expiry_timestamp: u64,
        _balance: u64,
        _receiver_proofs_json: &str,
        _sender_proofs_json: &str,
        _receiver_sum: u64,
        _sender_sum: u64,
    ) -> Result<(), String> {
        Err(CLOSE_PREPARATION_UNSUPPORTED_HOST_CALL.to_string())
    }

    fn compute_channel_secret(
        &self,
        _receiver_pubkey_hex: &str,
        _sender_pubkey_hex: &str,
    ) -> Result<String, String> {
        Err(CLOSE_PREPARATION_UNSUPPORTED_HOST_CALL.to_string())
    }

    fn sign_with_tweaked_key(
        &self,
        signer_pubkey_hex: &str,
        message_hex: &str,
        tweak_scalar_hex: &str,
    ) -> Result<String, String> {
        // Runs inside the bridge, after the sender signature verified: the
        // receiver's ownership check keeps its original phase and wording.
        let receiver_secret = SecretKey::from_hex(&self.receiver_secret_key_hex)
            .map_err(|_| "Invalid receiver secret key".to_string())?;
        let receiver_pubkey = receiver_secret.public_key();
        if receiver_pubkey != self.receiver_pubkey || receiver_pubkey.to_hex() != signer_pubkey_hex
        {
            return Err(
                "receiver secret key does not match channel receiver public key".to_string(),
            );
        }
        sign_with_tweaked_key_util(&self.receiver_secret_key_hex, message_hex, tweak_scalar_hex)
            .map_err(|e| format!("Failed to sign close message: {e}"))
    }
}

/// Render a bridge failure with this ABI's stable diagnostic wording.
///
/// The two adapter-owned categories keep their exact historical text. Anything
/// the bridge reports as an internal build/derivation failure becomes a fixed,
/// sanitized message: upstream hides its step names, and the C ABI must not
/// depend on private wording it cannot inspect.
fn close_preparation_error(error: BridgeError) -> String {
    match error {
        BridgeError::InvalidSignature(e) => format!("Invalid sender signature: {e}"),
        // The signing callback already produced this adapter's final wording.
        BridgeError::ServerMisconfigured(message) => message,
        BridgeError::BalanceExceedsCapacity { balance, capacity } => {
            format!("balance {balance} exceeds channel capacity {capacity}")
        }
        _ => "failed to prepare cooperative close".to_string(),
    }
}

/// Prepare the receiver-side close request through the upstream bridge.
///
/// The bridge is the upstream `validate_and_prepare_cooperative_close` entry
/// point driven by [`ClosePreparationHost`]: the sender's signature is verified
/// against the caller's channel id, the commitment swap is built and
/// co-signed, and the amount-sorted secret metadata is returned. Only this
/// adapter's own validation (capacity, output unit, receiver-key ownership) and
/// the public JSON shape live here, and the JSON keeps its historical keys so
/// [`cdk_spilman_unblind_close_swap`] keeps working unchanged.
#[allow(clippy::too_many_arguments)]
fn prepare_close_swap_json(
    params: &ChannelParameters,
    channel_parameters_json: &str,
    channel_secret_hex: &str,
    funding_keyset_info_json: &str,
    output_keyset: &KeysetInfo,
    output_keyset_info_json: &str,
    funding_proofs_json: &str,
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

    let host = ClosePreparationHost {
        channel_id: params.get_channel_id(),
        funding: ChannelFunding {
            params_json: channel_parameters_json.to_string(),
            funding_proofs_json: funding_proofs_json.to_string(),
            channel_secret_hex: channel_secret_hex.to_string(),
            keyset_info_json: funding_keyset_info_json.to_string(),
        },
        output_keyset: output_keyset.clone(),
        output_keyset_json: output_keyset_info_json.to_string(),
        amount_due: balance,
        receiver_secret_key_hex: Zeroizing::new(receiver_secret_key_hex.to_string()),
        receiver_pubkey: params.receiver_pubkey,
    };

    // The bridge deserializes the payment itself; only the three signed fields
    // are needed, and the caller's arguments stay authoritative.
    let request = serde_json::json!({
        "channel_id": params.get_channel_id(),
        "balance": balance,
        "signature": sender_signature.to_string(),
    });

    let close = SpilmanBridge::new(host)
        .validate_and_prepare_cooperative_close(&request.to_string())
        .map_err(close_preparation_error)?;

    let secrets_with_blinding: Vec<serde_json::Value> = close
        .secrets_with_blinding
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
        "swap_request": serde_json::to_value(&close.swap_request)
            .map_err(|e| format!("Failed to serialize swap request: {e}"))?,
        "sig_all_message_hash": close.sig_all_message_hash,
        "blinded_receiver_pubkey": close.blinded_receiver_pubkey,
        "expected_total": close.expected_total,
        "secrets_with_blinding": secrets_with_blinding,
        "output_keyset_info": serde_json::to_value(&close.output_keyset_info)
            .map_err(|e| format!("Failed to serialize output keyset info: {e}"))?,
    });
    Ok(result.to_string())
}

/// Unblind a close swap response and sign the receiver's proofs.
///
/// [`unblind_and_verify_stage1_response`] already attaches the stage-2 P2PK
/// secret to each proof, so this only has to derive the per-proof stage-2 key
/// from the receiver's channel key and sign the proof secret with it. The
/// derivation and signing are both public upstream operations; this adapter
/// never recomposes the crypto itself.
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
    let receiver_secret = match receiver_secret_key_hex {
        Some(hex) => {
            let receiver_secret =
                SecretKey::from_hex(hex).map_err(|_| "Invalid receiver secret key".to_string())?;
            if receiver_secret.public_key() != params.receiver_pubkey {
                return Err(
                    "receiver secret key does not match channel receiver public key".to_string(),
                );
            }
            Some(receiver_secret)
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
        if let Some(receiver_secret) = &receiver_secret {
            let stage2_secret = params
                .get_receiver_blinded_secret_key_for_stage2_output(
                    receiver_secret,
                    proof_meta.amount,
                    proof_meta.index,
                )
                .map_err(|e| format!("Failed to derive receiver stage-2 key: {e}"))?;
            // `Proof::sign_p2pk` hashes the proof secret internally and would
            // append to an inherited witness; the wrapper has always replaced
            // it with exactly one receiver signature.
            proof.witness = None;
            proof
                .sign_p2pk(stage2_secret)
                .map_err(|e| format!("Failed to sign receiver proof: {e}"))?;
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

/// Return the mint's active Msat keyset as Spilman `KeysetInfo` JSON.
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

/// Return a single Msat keyset, by id, as Spilman `KeysetInfo` JSON.
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
    wallet_swap_call(handle, mint_url, swap_request_json, false)
}

/// Inspect the saved swap using NUT-07 and NUT-09; never submits a swap.
/// Returns JSON with `input_states` in request order and `swap_response`
/// (a NUT-03 response in request order, or null if unresolved). Null is
/// never authorization to retry. Complete and verify using the saved Spilman
/// material before considering the swap recovered. Does not update wallet state.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_recover_swap(
    handle: Option<&CdkWallet>,
    mint_url: Option<char_p::Ref<'_>>,
    swap_request_json: Option<char_p::Ref<'_>>,
) -> CdkStringResult {
    wallet_swap_call(handle, mint_url, swap_request_json, true)
}

#[cfg(not(target_arch = "wasm32"))]
fn wallet_swap_call(
    handle: Option<&CdkWallet>,
    mint_url: Option<char_p::Ref<'_>>,
    swap_request_json: Option<char_p::Ref<'_>>,
    recover: bool,
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
            let result = runtime().block_on(async {
                if recover {
                    handle.recover_swap(&mint_url, &swap_request_json).await
                } else {
                    handle.post_swap(&mint_url, &swap_request_json).await
                }
            });
            match result {
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
                Ok(net_msats) => receive_msats(net_msats),
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
                Ok(net_msats) => receive_msats(net_msats),
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
) -> CdkSpilmanAmountResult {
    let error = |status, message: String| CdkSpilmanAmountResult {
        status,
        error: string_to_box(message),
        amount: 0,
    };
    guard(
        || error(CdkStatus::InternalError, "internal panic".into()),
        || {
            let keyset_info_json = match json_arg(keyset_info_json, "keyset info") {
                Ok(value) => value,
                Err(e) => return error(e.status, e.message),
            };
            match compute_funding_token_amount(
                capacity,
                &keyset_info_json,
                maximum_amount_for_one_output,
            ) {
                Ok(amount) => CdkSpilmanAmountResult { status: CdkStatus::Ok, error: None, amount },
                Err(e) => error(CdkStatus::InvalidArgument, e),
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
            // Validate the caller's funding proofs up front, at this adapter's
            // original phase; the bridge re-parses the same caller JSON so no
            // value is re-serialized on the way in.
            if let Err(e) = parse_proofs(&funding_proofs_json) {
                return CdkStringResult::err(CdkStatus::InvalidArgument, e);
            }
            spilman_string(prepare_close_swap_json(
                &params,
                &params_json,
                &channel_secret_hex,
                &funding_keyset_info_json,
                &output_keyset,
                &output_keyset_info_json,
                &funding_proofs_json,
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
