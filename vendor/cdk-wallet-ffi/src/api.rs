//! The C ABI surface.
//!
//! Every exported function is a thin, panic-safe adapter: it validates raw C
//! arguments, then drives the corresponding [`crate::wallet`] helper on the
//! persistent Tokio runtime. No Rust panic is ever allowed to unwind across the
//! FFI boundary, and no global "last error" state is used.
//!
//! # Pointer / ownership contract
//!
//! * `cdk_wallet_t *` handles come only from [`cdk_wallet_open`] and are freed
//!   only by [`cdk_wallet_close`].
//! * Owned strings (`char_p::Box`) are freed only by [`cdk_string_free`].
//! * Owned byte payloads (`repr_c::Vec<u8>`) are freed only by
//!   [`cdk_bytes_free`].
//! * Owned lists are freed only by the matching `*_free` function.
//! * The caller must serialize calls that use the same handle, and must not
//!   free a handle while a call using it is still running.

use safer_ffi::prelude::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use zeroize::{Zeroize, Zeroizing};

use crate::status::{
    string_to_box, CdkBalanceEntry, CdkBalanceListResult, CdkBytesResult, CdkMintListResult,
    CdkMintRecovery, CdkOpenResult, CdkPendingListResult, CdkPendingToken, CdkReceiveResult,
    CdkRecoveryResult, CdkRestoreCanAbandonResult, CdkSeedRestoreResult, CdkSendResult, CdkStatus,
    CdkStatusResult, CdkStringResult,
};
use crate::wallet::{FfiErr, FfiResult, MintRecoveryReport, MAX_TOKEN_BYTES};

/// Maximum accepted BIP-39 mnemonic length, in bytes.
///
/// A 24-word English phrase is well under 300 bytes; this bound rejects
/// oversized input before any parse or allocation without rejecting any valid
/// phrase.
pub(crate) const MAX_MNEMONIC_BYTES: usize = 1024;

/// Run `f`, converting any panic into `fallback`.
pub(crate) fn guard<R>(fallback: impl FnOnce() -> R, f: impl FnOnce() -> R) -> R {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(_) => fallback(),
    }
}

/// Like [`guard`], but also marks the handle as poisoned when a panic is caught.
///
/// `poison` is a clone of the handle's flag captured *before* `f` borrows the
/// handle. A poisoned handle refuses all further operations (except
/// [`cdk_wallet_close`]) because its in-memory state may be inconsistent.
pub(crate) fn guard_poison<R>(
    poison: Option<Arc<AtomicBool>>,
    fallback: impl FnOnce() -> R,
    f: impl FnOnce() -> R,
) -> R {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(_) => {
            if let Some(poison) = poison {
                poison.store(true, Ordering::SeqCst);
            }
            fallback()
        }
    }
}

/// The standard "handle was poisoned by an earlier panic" error.
pub(crate) fn poisoned_handle() -> FfiErr {
    FfiErr::new(
        CdkStatus::InternalError,
        "wallet handle is in a failed state after an internal panic; close and reopen it",
    )
}

/// Decode a C string argument as UTF-8.
fn cstr_to_string(s: char_p::Ref<'_>) -> FfiResult<String> {
    std::str::from_utf8(s.to_bytes())
        .map(str::to_owned)
        .map_err(|_| FfiErr::new(CdkStatus::InvalidArgument, "argument is not valid UTF-8"))
}

/// Decode a nullable C string argument as UTF-8.
///
/// `char_p::Ref` is a non-null pointer, so a `NULL` argument must be modelled as
/// `Option`; otherwise constructing the reference is already undefined
/// behaviour.
pub(crate) fn opt_cstr_to_string(s: Option<char_p::Ref<'_>>) -> FfiResult<String> {
    match s {
        Some(s) => cstr_to_string(s),
        None => Err(FfiErr::new(
            CdkStatus::NullArgument,
            "string argument is NULL",
        )),
    }
}

/// Decode a nullable C string argument as UTF-8, rejecting oversized inputs
/// before cloning them into a Rust `String`.
pub(crate) fn opt_cstr_to_string_bounded(
    s: Option<char_p::Ref<'_>>,
    max: usize,
    what: &str,
) -> FfiResult<String> {
    match s {
        Some(s) => {
            let bytes = s.to_bytes();
            if bytes.len() > max {
                return Err(FfiErr::new(
                    CdkStatus::InvalidArgument,
                    format!("{what} exceeds the maximum supported size"),
                ));
            }
            std::str::from_utf8(bytes).map(str::to_owned).map_err(|_| {
                FfiErr::new(
                    CdkStatus::InvalidArgument,
                    format!("{what} is not valid UTF-8"),
                )
            })
        }
        None => Err(FfiErr::new(
            CdkStatus::NullArgument,
            "string argument is NULL",
        )),
    }
}

/// Decode and parse an English BIP-39 mnemonic argument.
///
/// The caller's bytes are copied into a `Zeroizing` buffer that is scrubbed on
/// drop, then parsed with `parse_in(Language::English, ..)`, which normalizes
/// (NFKD) and verifies the word count and checksum. Error messages are static
/// and never echo the phrase.
fn parse_english_mnemonic(mnemonic: Option<char_p::Ref<'_>>) -> FfiResult<bip39::Mnemonic> {
    let phrase = opt_cstr_to_string_bounded(mnemonic, MAX_MNEMONIC_BYTES, "mnemonic")?;
    let phrase = Zeroizing::new(phrase);
    bip39::Mnemonic::parse_in(bip39::Language::English, phrase.as_str()).map_err(|_| {
        FfiErr::new(
            CdkStatus::InvalidArgument,
            "mnemonic is not a valid English BIP-39 phrase (check the word count and checksum)",
        )
    })
}

/// Convert crate-internal recovery reports into the C ABI representation.
fn reports_to_c(reports: Vec<MintRecoveryReport>) -> repr_c::Vec<CdkMintRecovery> {
    let items = reports
        .into_iter()
        .map(|r| CdkMintRecovery {
            mint_url: char_p::new(r.mint_url),
            recovered: r.recovered,
            compensated: r.compensated,
            skipped: r.skipped,
            failed: r.failed,
            status: r.status,
            message: r.message.and_then(string_to_box),
        })
        .collect::<Vec<_>>();
    repr_c::Vec::from(items)
}

/// The standard "handle was null" error.
pub(crate) fn null_handle() -> FfiErr {
    FfiErr::new(CdkStatus::NullArgument, "wallet handle is NULL")
}

fn open_error(status: CdkStatus, message: impl Into<String>) -> CdkOpenResult {
    CdkOpenResult {
        status,
        error: string_to_box(message.into()),
        handle: None,
        recovered: 0,
        compensated: 0,
        skipped: 0,
        failed: 0,
        reports: repr_c::Vec::from(Vec::new()),
    }
}

pub(crate) fn receive_error(status: CdkStatus, message: impl Into<String>) -> CdkReceiveResult {
    CdkReceiveResult {
        status,
        error: string_to_box(message.into()),
        net_sats: 0,
    }
}

fn mint_list_error(status: CdkStatus, message: impl Into<String>) -> CdkMintListResult {
    CdkMintListResult {
        status,
        error: string_to_box(message.into()),
        mints: repr_c::Vec::from(Vec::new()),
    }
}

fn balance_list_error(status: CdkStatus, message: impl Into<String>) -> CdkBalanceListResult {
    CdkBalanceListResult {
        status,
        error: string_to_box(message.into()),
        balances: repr_c::Vec::from(Vec::new()),
    }
}

fn pending_list_error(status: CdkStatus, message: impl Into<String>) -> CdkPendingListResult {
    CdkPendingListResult {
        status,
        error: string_to_box(message.into()),
        pending: repr_c::Vec::from(Vec::new()),
    }
}

fn recovery_error(status: CdkStatus, message: impl Into<String>) -> CdkRecoveryResult {
    CdkRecoveryResult {
        status,
        error: string_to_box(message.into()),
        recovered: 0,
        compensated: 0,
        skipped: 0,
        failed: 0,
        reports: repr_c::Vec::from(Vec::new()),
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn seed_restore_error(status: CdkStatus, message: impl Into<String>) -> CdkSeedRestoreResult {
    CdkSeedRestoreResult {
        status,
        error: string_to_box(message.into()),
        incomplete: 1,
        unspent_sats: 0,
        pending_sats: 0,
        spent_sats: 0,
    }
}

fn send_error(e: FfiErr) -> CdkSendResult {
    match e.operation_id {
        Some(op) => CdkSendResult::err_with_op(e.status, e.message, op, e.sender_fee_sats),
        None => CdkSendResult::err(e.status, e.message),
    }
}

/// Open (creating if needed) a wrapper-owned database.
///
/// `seed` must be exactly 64 bytes. `db_path` must be a valid UTF-8 filesystem
/// path. On success the returned `handle` is owned by the caller and must be
/// freed with [`cdk_wallet_close`].
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_open(
    seed: Option<c_slice::Ref<'_, u8>>,
    db_path: Option<char_p::Ref<'_>>,
) -> CdkOpenResult {
    // Borrow the caller's seed for the duration of the synchronous call rather
    // than copying it into an owned `Vec`.
    let seed = match seed {
        Some(seed) => seed,
        None => return open_error(CdkStatus::NullArgument, "seed slice is NULL"),
    };
    let path = match opt_cstr_to_string(db_path) {
        Ok(path) => path,
        Err(e) => return open_error(e.status, e.message),
    };

    guard(
        || open_error(CdkStatus::InternalError, "internal panic during open"),
        || match crate::wallet::runtime()
            .block_on(crate::wallet::CdkWallet::open(seed.as_slice(), &path))
        {
            Ok((handle, reports)) => {
                let handle: repr_c::Box<crate::wallet::CdkWallet> = Box::new(handle).into();
                let (recovered, compensated, skipped, failed) =
                    crate::wallet::aggregate_counts(&reports);
                CdkOpenResult {
                    status: CdkStatus::Ok,
                    error: None,
                    handle: Some(handle),
                    recovered,
                    compensated,
                    skipped,
                    failed,
                    reports: reports_to_c(reports),
                }
            }
            Err(e) => open_error(e.status, e.message),
        },
    )
}

/// Free a wallet handle.
///
/// Flushes any pending rate-limiter state, then releases the handle. The handle
/// is consumed even if the call reports an error, so it must never be reused;
/// passing `NULL` is a safe no-op. No call using the handle may still be in
/// flight.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_close(handle: Option<repr_c::Box<crate::wallet::CdkWallet>>) -> CdkStatusResult {
    guard(
        || CdkStatusResult::err(CdkStatus::InternalError, "internal panic during close"),
        || {
            let handle = match handle {
                Some(h) => h,
                None => return CdkStatusResult::ok(),
            };
            // Best-effort flush; `flush_rate_limits` cannot fail. The handle is
            // dropped (and its file lock released) regardless.
            crate::wallet::runtime().block_on(handle.flush_rate_limits());
            drop(handle);
            CdkStatusResult::ok()
        },
    )
}

/// Approve (register) a mint.
///
/// Idempotent for an already-approved mint. Requires network access to fetch
/// the mint's advertised units.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_add_mint(
    handle: Option<&mut crate::wallet::CdkWallet>,
    mint_url: Option<char_p::Ref<'_>>,
) -> CdkStatusResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || CdkStatusResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(h) => h,
                None => return CdkStatusResult::err(null_handle().status, null_handle().message),
            };
            if handle.is_poisoned() {
                return CdkStatusResult::err(poisoned_handle().status, poisoned_handle().message);
            }
            let url = match opt_cstr_to_string(mint_url) {
                Ok(u) => u,
                Err(e) => return CdkStatusResult::err(e.status, e.message),
            };
            match crate::wallet::runtime().block_on(handle.add_mint(&url)) {
                Ok(()) => CdkStatusResult::ok(),
                Err(e) => CdkStatusResult::err(e.status, e.message),
            }
        },
    )
}

/// List approved mint URLs.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_list_mints(handle: Option<&crate::wallet::CdkWallet>) -> CdkMintListResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || mint_list_error(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(h) => h,
                None => return mint_list_error(null_handle().status, null_handle().message),
            };
            if handle.is_poisoned() {
                return mint_list_error(poisoned_handle().status, poisoned_handle().message);
            }
            let mints = crate::wallet::runtime().block_on(handle.list_mints());
            let mints = mints.into_iter().map(char_p::new).collect::<Vec<_>>();
            CdkMintListResult {
                status: CdkStatus::Ok,
                error: None,
                mints: repr_c::Vec::from(mints),
            }
        },
    )
}

/// List approved mints with their locally spendable Sat balance.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_list_balances(handle: Option<&crate::wallet::CdkWallet>) -> CdkBalanceListResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || balance_list_error(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(h) => h,
                None => return balance_list_error(null_handle().status, null_handle().message),
            };
            if handle.is_poisoned() {
                return balance_list_error(poisoned_handle().status, poisoned_handle().message);
            }
            match crate::wallet::runtime().block_on(handle.list_balances()) {
                Ok(entries) => {
                    let balances = entries
                        .into_iter()
                        .map(|(mint_url, balance_sats)| CdkBalanceEntry {
                            mint_url: char_p::new(mint_url),
                            balance_sats,
                        })
                        .collect::<Vec<_>>();
                    CdkBalanceListResult {
                        status: CdkStatus::Ok,
                        error: None,
                        balances: repr_c::Vec::from(balances),
                    }
                }
                Err(e) => balance_list_error(e.status, e.message),
            }
        },
    )
}

/// Receive a token, returning the net Sat amount credited.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_receive(
    handle: Option<&mut crate::wallet::CdkWallet>,
    token: Option<char_p::Ref<'_>>,
) -> CdkReceiveResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || receive_error(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(h) => h,
                None => return receive_error(null_handle().status, null_handle().message),
            };
            if handle.is_poisoned() {
                return receive_error(poisoned_handle().status, poisoned_handle().message);
            }
            let token = match opt_cstr_to_string_bounded(token, MAX_TOKEN_BYTES, "token") {
                Ok(t) => t,
                Err(e) => return receive_error(e.status, e.message),
            };
            match crate::wallet::runtime().block_on(handle.receive(&token)) {
                Ok(net_sats) => CdkReceiveResult {
                    status: CdkStatus::Ok,
                    error: None,
                    net_sats,
                },
                Err(e) => receive_error(e.status, e.message),
            }
        },
    )
}

/// Send `amount_sats` from an explicitly selected mint.
///
/// The total send fee must not exceed `max_sender_fee_sats`, otherwise the send
/// is cancelled. On success the returned `token` is a bearer secret owned by
/// the caller and must be freed with [`cdk_string_free`].
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_send(
    handle: Option<&mut crate::wallet::CdkWallet>,
    mint_url: Option<char_p::Ref<'_>>,
    amount_sats: u64,
    max_sender_fee_sats: u64,
) -> CdkSendResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || CdkSendResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(h) => h,
                None => return send_error(null_handle()),
            };
            if handle.is_poisoned() {
                return send_error(poisoned_handle());
            }
            let url = match opt_cstr_to_string(mint_url) {
                Ok(u) => u,
                Err(e) => return send_error(e),
            };
            match crate::wallet::runtime().block_on(handle.send(
                &url,
                amount_sats,
                max_sender_fee_sats,
            )) {
                Ok(outcome) => CdkSendResult {
                    status: CdkStatus::Ok,
                    error: None,
                    token: string_to_box(outcome.token),
                    operation_id: outcome.operation_id,
                    sender_fee_sats: outcome.sender_fee_sats,
                },
                Err(e) => send_error(e),
            }
        },
    )
}

/// List pending outgoing tokens (created but not claimed).
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_list_pending_tokens(
    handle: Option<&crate::wallet::CdkWallet>,
) -> CdkPendingListResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || pending_list_error(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(h) => h,
                None => return pending_list_error(null_handle().status, null_handle().message),
            };
            if handle.is_poisoned() {
                return pending_list_error(poisoned_handle().status, poisoned_handle().message);
            }
            match crate::wallet::runtime().block_on(handle.list_pending_tokens()) {
                Ok(tokens) => {
                    let pending = tokens
                        .into_iter()
                        .map(|t| CdkPendingToken {
                            operation_id: t.operation_id,
                            token: char_p::new(t.token),
                        })
                        .collect::<Vec<_>>();
                    CdkPendingListResult {
                        status: CdkStatus::Ok,
                        error: None,
                        pending: repr_c::Vec::from(pending),
                    }
                }
                Err(e) => pending_list_error(e.status, e.message),
            }
        },
    )
}

/// Retrieve a single pending outgoing token by its 16-byte operation id.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_get_pending_token(
    handle: Option<&crate::wallet::CdkWallet>,
    operation_id: Option<c_slice::Ref<'_, u8>>,
) -> CdkStringResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || CdkStringResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(h) => h,
                None => return CdkStringResult::err(null_handle().status, null_handle().message),
            };
            if handle.is_poisoned() {
                return CdkStringResult::err(poisoned_handle().status, poisoned_handle().message);
            }
            let operation_id = match operation_id {
                Some(id) => id,
                None => {
                    return CdkStringResult::err(
                        CdkStatus::NullArgument,
                        "operation id slice is NULL",
                    )
                }
            };
            match crate::wallet::runtime()
                .block_on(handle.get_pending_token(operation_id.as_slice()))
            {
                Ok(token) => CdkStringResult {
                    status: CdkStatus::Ok,
                    error: None,
                    value: string_to_box(token.token),
                },
                Err(e) => CdkStringResult::err(e.status, e.message),
            }
        },
    )
}

/// Audit local artifacts in a staged wallet. Advisory only: the caller must
/// independently prove recovery ownership. This does not delete anything or
/// prove that the seed has no funds at a mint. Free error with `cdk_string_free`.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_restore_can_abandon(
    handle: Option<&crate::wallet::CdkWallet>,
) -> CdkRestoreCanAbandonResult {
    fn error(e: FfiErr) -> CdkRestoreCanAbandonResult {
        CdkRestoreCanAbandonResult {
            status: e.status,
            error: string_to_box(e.message),
            safe_to_abandon: 0,
        }
    }
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || error(FfiErr::new(CdkStatus::InternalError, "internal panic")),
        || {
            let handle = match handle {
                Some(h) => h,
                None => return error(null_handle()),
            };
            if handle.is_poisoned() {
                return error(poisoned_handle());
            }
            match crate::wallet::runtime().block_on(handle.restore_can_abandon()) {
                Ok(safe) => CdkRestoreCanAbandonResult {
                    status: CdkStatus::Ok,
                    error: None,
                    safe_to_abandon: u8::from(safe),
                },
                Err(e) => error(e),
            }
        },
    )
}

/// Scan a Sat mint for deterministic seed-derived proofs using NUT-13.
/// This is not saga recovery. Failure may leave previously restored proofs in
/// the database; totals are valid only when the scan completed. Free `error`
/// with `cdk_string_free`.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_restore_seed(
    handle: Option<&mut crate::wallet::CdkWallet>,
    mint_url: Option<char_p::Ref<'_>>,
) -> CdkSeedRestoreResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || seed_restore_error(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(h) => h,
                None => return seed_restore_error(null_handle().status, null_handle().message),
            };
            if handle.is_poisoned() {
                return seed_restore_error(poisoned_handle().status, poisoned_handle().message);
            }
            let url = match opt_cstr_to_string(mint_url) {
                Ok(url) => url,
                Err(e) => return seed_restore_error(e.status, e.message),
            };
            match crate::wallet::runtime().block_on(handle.restore_seed(&url)) {
                Ok((unspent_sats, pending_sats, spent_sats)) => CdkSeedRestoreResult {
                    status: CdkStatus::Ok,
                    error: None,
                    incomplete: 0,
                    unspent_sats,
                    pending_sats,
                    spent_sats,
                },
                Err(e) => seed_restore_error(e.status, e.message),
            }
        },
    )
}

/// Run explicit operation recovery for all mints, or a single mint.
///
/// Pass `NULL` for `mint_url` to recover every approved mint.
#[ffi_export]
#[cfg(not(target_arch = "wasm32"))]
pub fn cdk_wallet_recover(
    handle: Option<&mut crate::wallet::CdkWallet>,
    mint_url: Option<char_p::Ref<'_>>,
) -> CdkRecoveryResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || recovery_error(CdkStatus::InternalError, "internal panic"),
        || {
            let handle = match handle {
                Some(h) => h,
                None => return recovery_error(null_handle().status, null_handle().message),
            };
            if handle.is_poisoned() {
                return recovery_error(poisoned_handle().status, poisoned_handle().message);
            }
            let mint = match mint_url {
                Some(raw) => match cstr_to_string(raw) {
                    Ok(u) => match crate::wallet::parse_mint_url(&u) {
                        Ok(m) => Some(m),
                        Err(e) => return recovery_error(e.status, e.message),
                    },
                    Err(e) => return recovery_error(e.status, e.message),
                },
                None => None,
            };
            match crate::wallet::runtime().block_on(handle.recover(mint.as_ref())) {
                Ok(reports) => {
                    let (recovered, compensated, skipped, failed) =
                        crate::wallet::aggregate_counts(&reports);
                    CdkRecoveryResult {
                        status: CdkStatus::Ok,
                        error: None,
                        recovered,
                        compensated,
                        skipped,
                        failed,
                        reports: reports_to_c(reports),
                    }
                }
                Err(e) => recovery_error(e.status, e.message),
            }
        },
    )
}

/// Free an owned per-mint recovery report vector.
///
/// Passing an empty vector is a safe no-op. Only pass vectors produced by this
/// library (from [`cdk_wallet_open`] or [`cdk_wallet_recover`]); this frees the
/// nested mint URLs and diagnostics too.
#[ffi_export]
pub fn cdk_recovery_reports_free(reports: repr_c::Vec<CdkMintRecovery>) {
    drop(reports);
}

/// Generate a new 12-word English BIP-39 mnemonic phrase.
///
/// The phrase encodes 128 bits of entropy and is the wallet's master secret:
/// treat it like a private key, back it up offline, and never log it. Free the
/// returned string with [`cdk_string_free`], which scrubs it before freeing.
///
/// There is **no** deterministic fallback: if the RNG fails, the call panics
/// inside the panic guard and returns [`CdkStatus::InternalError`] with no
/// phrase.
#[ffi_export]
pub fn cdk_generate_mnemonic() -> CdkStringResult {
    guard(
        || {
            CdkStringResult::err(
                CdkStatus::InternalError,
                "internal panic during mnemonic generation",
            )
        },
        || match bip39::Mnemonic::generate(12) {
            // `Mnemonic` is `ZeroizeOnDrop`; the rendered phrase is moved into
            // the owned box, where `cdk_string_free` scrubs it before freeing.
            Ok(mnemonic) => CdkStringResult {
                status: CdkStatus::Ok,
                error: None,
                value: string_to_box(mnemonic.to_string()),
            },
            Err(_) => CdkStringResult::err(
                CdkStatus::InternalError,
                "could not obtain secure entropy for mnemonic generation",
            ),
        },
    )
}

/// Convert an English BIP-39 mnemonic back to its raw entropy.
///
/// Returns 16 bytes for a 12-word phrase (32 for 24 words; 20/24/28 for
/// 15/18/21). This is the **entropy**, not the wallet seed: do not pass it to
/// [`cdk_wallet_open`]. Free the payload with [`cdk_bytes_free`].
#[ffi_export]
pub fn cdk_mnemonic_to_entropy(mnemonic: Option<char_p::Ref<'_>>) -> CdkBytesResult {
    guard(
        || {
            CdkBytesResult::err(
                CdkStatus::InternalError,
                "internal panic during mnemonic conversion",
            )
        },
        || match parse_english_mnemonic(mnemonic) {
            Ok(mnemonic) => CdkBytesResult {
                status: CdkStatus::Ok,
                error: None,
                bytes: repr_c::Vec::from(mnemonic.to_entropy()),
            },
            Err(e) => CdkBytesResult::err(e.status, e.message),
        },
    )
}

/// Derive the 64-byte wallet seed from an English BIP-39 mnemonic.
///
/// Uses the BIP-39 PBKDF2 derivation with an **empty** passphrase, matching
/// upstream CDK's default, so the result can be passed directly to
/// [`cdk_wallet_open`]. The result is always 64 bytes. Free the payload with
/// [`cdk_bytes_free`].
#[ffi_export]
pub fn cdk_mnemonic_to_seed(mnemonic: Option<char_p::Ref<'_>>) -> CdkBytesResult {
    guard(
        || {
            CdkBytesResult::err(
                CdkStatus::InternalError,
                "internal panic during mnemonic conversion",
            )
        },
        || match parse_english_mnemonic(mnemonic) {
            Ok(mnemonic) => {
                // The derived seed is secret; scrub the temporary before it is
                // copied into the owned payload.
                let seed = Zeroizing::new(mnemonic.to_seed_normalized(""));
                CdkBytesResult {
                    status: CdkStatus::Ok,
                    error: None,
                    bytes: repr_c::Vec::from(seed.to_vec()),
                }
            }
            Err(e) => CdkBytesResult::err(e.status, e.message),
        },
    )
}

/// Free an owned byte payload returned by this library.
///
/// The bytes are scrubbed with `zeroize` before the allocation is freed, so a
/// freed seed or entropy vector is not left in the heap. Passing an empty
/// vector is a safe no-op. Only pass vectors produced by this library.
#[ffi_export]
pub fn cdk_bytes_free(bytes: repr_c::Vec<u8>) {
    let mut bytes = bytes;
    bytes.zeroize();
    drop(bytes);
}

/// Free an owned string returned by this library.
///
/// The string contents are scrubbed with `zeroize` before the allocation is
/// freed, so a freed phrase or bearer token is not left in the heap. Passing
/// `NULL` is a safe no-op. Only pass strings produced by this library.
#[ffi_export]
pub fn cdk_string_free(string: Option<char_p::Box>) {
    if let Some(string) = string {
        // `into_string` is infallible for boxes produced by this library.
        let mut owned = string.into_string();
        owned.zeroize();
    }
}

/// Test-only: force a panic inside the FFI guard so the panic-containment path
/// (poisoning) can be exercised. Never part of the generated header or of a
/// production build.
#[cfg(test)]
#[ffi_export]
pub fn cdk_test_panic(handle: Option<&mut crate::wallet::CdkWallet>) -> CdkStatusResult {
    let poison = handle.as_ref().map(|h| h.poison_flag());
    guard_poison(
        poison,
        || CdkStatusResult::err(CdkStatus::InternalError, "internal panic"),
        || {
            let _ = handle;
            panic!("intentional test panic");
        },
    )
}

/// Free an owned mint list returned by [`cdk_wallet_list_mints`].
#[ffi_export]
pub fn cdk_mint_list_free(mints: repr_c::Vec<char_p::Box>) {
    drop(mints);
}

/// Free an owned balance list returned by [`cdk_wallet_list_balances`].
#[ffi_export]
pub fn cdk_balance_list_free(balances: repr_c::Vec<CdkBalanceEntry>) {
    drop(balances);
}

/// Free an owned pending-token list returned by [`cdk_wallet_list_pending_tokens`].
#[ffi_export]
pub fn cdk_pending_list_free(pending: repr_c::Vec<CdkPendingToken>) {
    drop(pending);
}
