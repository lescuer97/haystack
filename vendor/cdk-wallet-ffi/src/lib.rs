//! `cdk-wallet-ffi`: a minimal, boring C ABI over a subset of
//! [`cdk::wallet::WalletRepository`].
//!
//! The crate builds as a `staticlib` (plus an `rlib`) for the Zig application
//! to link. It wraps:
//!
//! * one SQLite database, one 64-byte seed, Sat-only balances;
//! * explicit, durable mint approval;
//! * `open`/`close`, `add_mint`, `list_mints`, `list_balances`, `receive`,
//!   `send`, pending-token listing/retrieval, and explicit recovery;
//! * BIP-39 mnemonic generation plus entropy / 64-byte seed derivation, using
//!   the same dependency and semantics as upstream CDK (the application still
//!   owns backup and secure storage; there is no restore engine).
//!
//! # Blocking API
//!
//! Every exported function blocks the calling thread while it drives a future
//! on a single, process-wide, multi-threaded Tokio runtime. The Zig side is
//! expected to call the ABI from a worker thread.
//!
//! # Ownership
//!
//! * Handles are created by [`cdk_wallet_open`] and freed by
//!   [`cdk_wallet_close`].
//! * Owned strings, byte payloads, and lists are freed only by the matching
//!   `cdk_*_free` functions (which scrub secret material first).
//! * Mnemonics, entropy, seeds, and bearer tokens are secrets: never log them,
//!   and treat anything returned as sensitive.

mod api;
mod spilman;
mod status;
mod wallet;

#[cfg(panic = "abort")]
compile_error!(
    "cdk-wallet-ffi requires `panic = \"unwind\"`: the C ABI relies on `catch_unwind` to \
     contain panics instead of aborting the process."
);

#[cfg(test)]
mod e2e;
#[cfg(test)]
mod fixtures;
#[cfg(test)]
mod tests;

pub use api::*;
pub use spilman::*;
pub use status::*;
pub use wallet::CdkWallet;

/// Default path (relative to the crate manifest) of the committed C header.
#[cfg(feature = "headers")]
pub fn default_header_path() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("include/cdk_wallet.h")
}

/// Render the C header to a string without touching the filesystem.
#[cfg(feature = "headers")]
pub fn header_contents() -> String {
    // Referencing every exported symbol forces the linker to keep the `api`
    // object file (and therefore the `inventory` registrations that the header
    // generator iterates over).
    let force: [*const (); 47] = [
        cdk_wallet_open as *const (),
        cdk_wallet_close as *const (),
        cdk_wallet_add_mint as *const (),
        cdk_wallet_list_mints as *const (),
        cdk_wallet_list_balances as *const (),
        cdk_wallet_receive as *const (),
        cdk_wallet_send as *const (),
        cdk_wallet_list_pending_tokens as *const (),
        cdk_wallet_get_pending_token as *const (),
        cdk_wallet_recover as *const (),
        cdk_generate_mnemonic as *const (),
        cdk_mnemonic_to_entropy as *const (),
        cdk_mnemonic_to_seed as *const (),
        cdk_string_free as *const (),
        cdk_bytes_free as *const (),
        cdk_mint_list_free as *const (),
        cdk_balance_list_free as *const (),
        cdk_pending_list_free as *const (),
        cdk_recovery_reports_free as *const (),
        cdk_wallet_get_active_keyset_info_json as *const (),
        cdk_wallet_get_keyset_info_json as *const (),
        cdk_wallet_post_swap as *const (),
        cdk_wallet_receive_with_keys as *const (),
        cdk_wallet_receive_proofs as *const (),
        cdk_spilman_build_cashu_b_token as *const (),
        cdk_spilman_build_cashu_a_token as *const (),
        cdk_token_to_proofs_json as *const (),
        cdk_spilman_generate_keypair as *const (),
        cdk_spilman_secret_key_to_pubkey as *const (),
        cdk_spilman_compute_channel_secret as *const (),
        cdk_spilman_compute_funding_token_amount as *const (),
        cdk_spilman_compute_channel_from_token as *const (),
        cdk_spilman_channel_parameters_get_channel_id as *const (),
        cdk_spilman_create_funding_outputs as *const (),
        cdk_spilman_create_funding_swap as *const (),
        cdk_spilman_complete_funding_swap as *const (),
        cdk_spilman_construct_proofs as *const (),
        cdk_spilman_create_signed_balance_update as *const (),
        cdk_spilman_create_unsigned_balance_update as *const (),
        cdk_spilman_sign_with_tweaked_key_util as *const (),
        cdk_spilman_attach_signature_to_balance_update as *const (),
        cdk_spilman_verify_valid_channel as *const (),
        cdk_spilman_verify_balance_update as *const (),
        cdk_spilman_prepare_close_swap as *const (),
        cdk_spilman_unblind_close_swap as *const (),
        cdk_spilman_prepare_sender_refund as *const (),
        cdk_spilman_complete_sender_refund as *const (),
    ];
    std::hint::black_box(force);

    let mut out = Vec::new();
    safer_ffi::headers::builder()
        .with_banner(
            "/*\n * cdk-wallet-ffi: auto-generated C header.\n * Do not edit by hand; regenerate with `cargo run --features headers --bin generate-headers`.\n */\n",
        )
        .with_guard("CDK_WALLET_H")
        .to_writer(&mut out)
        .generate()
        .expect("header generation failed");
    String::from_utf8(out).expect("generated header is valid UTF-8")
}

/// Generate the committed C header at [`default_header_path`].
#[cfg(feature = "headers")]
pub fn generate_headers() -> std::io::Result<()> {
    let path = default_header_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, header_contents())
}

/// Check that the committed C header matches the generated output.
#[cfg(feature = "headers")]
pub fn check_headers() -> std::io::Result<()> {
    let path = default_header_path();
    let existing = std::fs::read_to_string(&path)?;
    let generated = header_contents();
    if existing != generated {
        return Err(std::io::Error::other(format!(
            "{} is stale; regenerate it",
            path.display()
        )));
    }
    Ok(())
}
