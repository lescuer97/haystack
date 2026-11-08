/*
 * cdk-wallet-ffi: auto-generated C header.
 * Do not edit by hand; regenerate with `cargo run --features headers --bin generate-headers`.
 */

#ifndef CDK_WALLET_H
#define CDK_WALLET_H
#ifdef __cplusplus
extern "C" {
#endif


#include <stddef.h>
#include <stdint.h>

/** \brief
 *  One approved mint and its locally spendable Sat balance.
 */
typedef struct CdkBalanceEntry {
    /** \brief
     *  Approved mint URL. Free with [`cdk_balance_list_free`](crate::cdk_balance_list_free).
     */
    char * mint_url;

    /** \brief
     *  Locally spendable (unspent, non-reserved) sats at this mint.
     */
    uint64_t balance_sats;
} CdkBalanceEntry_t;

/** \brief
 *  Same as [`Vec<T>`][`rust::Vec`], but with guaranteed `#[repr(C)]` layout
 */
typedef struct Vec_CdkBalanceEntry {
    /** <No documentation available> */
    CdkBalanceEntry_t * ptr;

    /** <No documentation available> */
    size_t len;

    /** <No documentation available> */
    size_t cap;
} Vec_CdkBalanceEntry_t;

/** \brief
 *  Free an owned balance list returned by [`cdk_wallet_list_balances`].
 */
void
cdk_balance_list_free (
    Vec_CdkBalanceEntry_t balances);

/** \brief
 *  Same as [`Vec<T>`][`rust::Vec`], but with guaranteed `#[repr(C)]` layout
 */
typedef struct Vec_uint8 {
    /** <No documentation available> */
    uint8_t * ptr;

    /** <No documentation available> */
    size_t len;

    /** <No documentation available> */
    size_t cap;
} Vec_uint8_t;

/** \brief
 *  Free an owned byte payload returned by this library.
 *
 *  The bytes are scrubbed with `zeroize` before the allocation is freed, so a
 *  freed seed or entropy vector is not left in the heap. Passing an empty
 *  vector is a safe no-op. Only pass vectors produced by this library.
 */
void
cdk_bytes_free (
    Vec_uint8_t bytes);

/** \brief
 *  Fixed-width per-call status. The numeric values are part of the ABI and must
 *  not be renumbered.
 */
/** \remark Has the same ABI as `uint8_t` **/
#ifdef DOXYGEN
typedef
#endif
enum CdkStatus {
    /** \brief
     *  The call succeeded.
     */
    CDK_STATUS_OK = 0,
    /** \brief
     *  A required pointer argument was null.
     */
    CDK_STATUS_NULL_ARGUMENT = 1,
    /** \brief
     *  An argument was structurally invalid (bad length, empty string, ...).
     */
    CDK_STATUS_INVALID_ARGUMENT = 2,
    /** \brief
     *  The seed was not exactly 64 bytes.
     */
    CDK_STATUS_INVALID_SEED = 3,
    /** \brief
     *  The database path was invalid (empty, a directory, not creatable, ...).
     */
    CDK_STATUS_INVALID_PATH = 4,
    /** \brief
     *  The database file is already locked by another live handle/process.
     */
    CDK_STATUS_ALREADY_OPEN = 5,
    /** \brief
     *  An existing database file does not carry this wrapper's marker.
     */
    CDK_STATUS_UNSUPPORTED_DATABASE = 6,
    /** \brief
     *  The stored seed fingerprint does not match the provided seed.
     */
    CDK_STATUS_SEED_MISMATCH = 7,
    /** \brief
     *  The database was written by an incompatible wrapper format version.
     */
    CDK_STATUS_UNSUPPORTED_FORMAT_VERSION = 8,
    /** \brief
     *  The mint URL was rejected by URL policy validation.
     */
    CDK_STATUS_INVALID_MINT_URL = 9,
    /** \brief
     *  The mint does not advertise the Sat unit.
     */
    CDK_STATUS_MINT_UNSUPPORTED_UNIT = 10,
    /** \brief
     *  The mint has not been approved/registered with this wallet.
     */
    CDK_STATUS_MINT_NOT_REGISTERED = 11,
    /** \brief
     *  Registering the mint failed.
     */
    CDK_STATUS_MINT_REGISTRATION_FAILED = 12,
    /** \brief
     *  A network operation failed.
     */
    CDK_STATUS_NETWORK_ERROR = 13,
    /** \brief
     *  The wallet does not hold enough locally spendable funds.
     */
    CDK_STATUS_INSUFFICIENT_FUNDS = 14,
    /** \brief
     *  The sender fee would exceed the caller-provided maximum.
     */
    CDK_STATUS_FEE_LIMIT_EXCEEDED = 15,
    /** \brief
     *  The token string could not be parsed.
     */
    CDK_STATUS_INVALID_TOKEN = 16,
    /** \brief
     *  The token is structurally unsupported (multi-mint, wrong unit, ...).
     */
    CDK_STATUS_UNSUPPORTED_TOKEN = 17,
    /** \brief
     *  The token belongs to a mint that has not been approved.
     */
    CDK_STATUS_TOKEN_UNKNOWN_MINT = 18,
    /** \brief
     *  A previous operation for this mint still has unresolved recovery state.
     */
    CDK_STATUS_RECOVERY_PENDING = 19,
    /** \brief
     *  The send definitively failed; the mint rejected it and no token exists.
     */
    CDK_STATUS_SEND_FAILED = 20,
    /** \brief
     *  The send outcome is uncertain; do not retry blindly.
     */
    CDK_STATUS_SEND_UNCERTAIN = 21,
    /** \brief
     *  Receiving the token failed.
     */
    CDK_STATUS_RECEIVE_FAILED = 22,
    /** \brief
     *  A local database operation failed.
     */
    CDK_STATUS_DATABASE_ERROR = 23,
    /** \brief
     *  An unexpected internal error occurred.
     */
    CDK_STATUS_INTERNAL_ERROR = 24,
    /** \brief
     *  A send's reserved proofs could not be released after the fee limit was
     *  exceeded; the mint is now fail-closed until recovery succeeds.
     */
    CDK_STATUS_CANCELLATION_FAILED = 25,
    /** \brief
     *  The requested pending operation does not exist.
     */
    CDK_STATUS_OPERATION_NOT_FOUND = 26,
    /** \brief
     *  The database file has group/other access permissions that are too broad
     *  (anything other than owner-only). The wrapper refuses to use it.
     */
    CDK_STATUS_INSECURE_DATABASE_PERMISSIONS = 27,
}
#ifndef DOXYGEN
; typedef uint8_t
#endif
CdkStatus_t;

/** \brief
 *  Result carrying a single owned string payload.
 *
 *  The payload may be a bearer token, so [`Debug`] is redacted: never rely on
 *  `{:?}` to inspect a token.
 */
typedef struct CdkStringResult {
    /** \brief
     *  Call status.
     */
    CdkStatus_t status;

    /** \brief
     *  Human-readable error message. `NULL` on success. Free with
     *  [`cdk_string_free`](crate::cdk_string_free).
     */
    char * error;

    /** \brief
     *  Owned string payload, present only on success. Free with
     *  [`cdk_string_free`](crate::cdk_string_free).
     */
    char * value;
} CdkStringResult_t;

/** \brief
 *  Generate a new 12-word English BIP-39 mnemonic phrase.
 *
 *  The phrase encodes 128 bits of entropy and is the wallet's master secret:
 *  treat it like a private key, back it up offline, and never log it. Free the
 *  returned string with [`cdk_string_free`], which scrubs it before freeing.
 *
 *  There is **no** deterministic fallback: if the RNG fails, the call panics
 *  inside the panic guard and returns [`CdkStatus::InternalError`] with no
 *  phrase.
 */
CdkStringResult_t
cdk_generate_mnemonic (void);

/** \brief
 *  Same as [`Vec<T>`][`rust::Vec`], but with guaranteed `#[repr(C)]` layout
 */
typedef struct Vec_char_ptr {
    /** <No documentation available> */
    char * * ptr;

    /** <No documentation available> */
    size_t len;

    /** <No documentation available> */
    size_t cap;
} Vec_char_ptr_t;

/** \brief
 *  Free an owned mint list returned by [`cdk_wallet_list_mints`].
 */
void
cdk_mint_list_free (
    Vec_char_ptr_t mints);

/** \brief
 *  Result carrying an owned byte-vector payload.
 *
 *  The payload may be raw mnemonic entropy or a derived wallet seed, both of
 *  which are secret material, so [`Debug`] is redacted: never rely on `{:?}` to
 *  inspect the bytes.
 */
typedef struct CdkBytesResult {
    /** \brief
     *  Call status.
     */
    CdkStatus_t status;

    /** \brief
     *  Human-readable error message. `NULL` on success. Free with
     *  [`cdk_string_free`](crate::cdk_string_free).
     */
    char * error;

    /** \brief
     *  Owned byte payload, present only on success and empty on failure. Free
     *  with [`cdk_bytes_free`](crate::cdk_bytes_free).
     */
    Vec_uint8_t bytes;
} CdkBytesResult_t;

/** \brief
 *  Convert an English BIP-39 mnemonic back to its raw entropy.
 *
 *  Returns 16 bytes for a 12-word phrase (32 for 24 words; 20/24/28 for
 *  15/18/21). This is the **entropy**, not the wallet seed: do not pass it to
 *  [`cdk_wallet_open`]. Free the payload with [`cdk_bytes_free`].
 */
CdkBytesResult_t
cdk_mnemonic_to_entropy (
    char const * mnemonic);

/** \brief
 *  Derive the 64-byte wallet seed from an English BIP-39 mnemonic.
 *
 *  Uses the BIP-39 PBKDF2 derivation with an **empty** passphrase, matching
 *  upstream CDK's default, so the result can be passed directly to
 *  [`cdk_wallet_open`]. The result is always 64 bytes. Free the payload with
 *  [`cdk_bytes_free`].
 */
CdkBytesResult_t
cdk_mnemonic_to_seed (
    char const * mnemonic);

typedef struct {
    uint8_t idx[16];
} uint8_16_array_t;

/** \brief
 *  One pending outgoing token.
 *
 *  Carries a bearer token, so [`Debug`] is redacted.
 */
typedef struct CdkPendingToken {
    /** \brief
     *  Operation identifier (16 raw UUID bytes).
     */
    uint8_16_array_t operation_id;

    /** \brief
     *  The bearer token. Treat as a secret. Free with
     *  [`cdk_pending_list_free`](crate::cdk_pending_list_free).
     */
    char * token;
} CdkPendingToken_t;

/** \brief
 *  Same as [`Vec<T>`][`rust::Vec`], but with guaranteed `#[repr(C)]` layout
 */
typedef struct Vec_CdkPendingToken {
    /** <No documentation available> */
    CdkPendingToken_t * ptr;

    /** <No documentation available> */
    size_t len;

    /** <No documentation available> */
    size_t cap;
} Vec_CdkPendingToken_t;

/** \brief
 *  Free an owned pending-token list returned by [`cdk_wallet_list_pending_tokens`].
 */
void
cdk_pending_list_free (
    Vec_CdkPendingToken_t pending);

/** \brief
 *  Per-mint recovery outcome.
 *
 *  One entry per approved Sat mint, describing how recovery went for that mint
 *  specifically. A mint whose `failed`/`skipped` counters are non-zero (or whose
 *  `status` is not [`CdkStatus::Ok`]) is left fail-closed until recovery
 *  succeeds.
 */
typedef struct CdkMintRecovery {
    /** \brief
     *  Mint URL. Free with
     *  [`cdk_recovery_reports_free`](crate::cdk_recovery_reports_free).
     */
    char * mint_url;

    /** \brief
     *  Sagas recovered for this mint.
     */
    uint32_t recovered;

    /** \brief
     *  Sagas compensated (rolled back) for this mint.
     */
    uint32_t compensated;

    /** \brief
     *  Sagas skipped (still unresolved) for this mint.
     */
    uint32_t skipped;

    /** \brief
     *  Sagas that failed recovery for this mint.
     */
    uint32_t failed;

    /** \brief
     *  Status of the recovery call for this mint: [`CdkStatus::Ok`] if the call
     *  itself completed (even if some sagas were skipped), otherwise the error.
     */
    CdkStatus_t status;

    /** \brief
     *  Non-secret diagnostic, present when a mint was skipped, failed, or the
     *  recovery call itself errored. `NULL` when the mint recovered cleanly.
     *  Free with
     *  [`cdk_recovery_reports_free`](crate::cdk_recovery_reports_free).
     */
    char * message;
} CdkMintRecovery_t;

/** \brief
 *  Same as [`Vec<T>`][`rust::Vec`], but with guaranteed `#[repr(C)]` layout
 */
typedef struct Vec_CdkMintRecovery {
    /** <No documentation available> */
    CdkMintRecovery_t * ptr;

    /** <No documentation available> */
    size_t len;

    /** <No documentation available> */
    size_t cap;
} Vec_CdkMintRecovery_t;

/** \brief
 *  Free an owned per-mint recovery report vector.
 *
 *  Passing an empty vector is a safe no-op. Only pass vectors produced by this
 *  library (from [`cdk_wallet_open`] or [`cdk_wallet_recover`]); this frees the
 *  nested mint URLs and diagnostics too.
 */
void
cdk_recovery_reports_free (
    Vec_CdkMintRecovery_t reports);

/** \brief
 *  Attach a signature to an unsigned balance-update swap request.
 */
CdkStringResult_t
cdk_spilman_attach_signature_to_balance_update (
    char const * unsigned_swap_request_json,
    char const * signature_hex,
    char const * channel_id,
    uint64_t amount);

/** \brief
 *  Build a `cashuA` (v3) token from a mint URL and proofs JSON.
 */
CdkStringResult_t
cdk_spilman_build_cashu_a_token (
    char const * mint_url,
    char const * proofs_json);

/** \brief
 *  Build a `cashuB` (v4) token from a mint URL, unit, and proofs JSON.
 */
CdkStringResult_t
cdk_spilman_build_cashu_b_token (
    char const * mint_url,
    char const * unit,
    char const * proofs_json);

/** \brief
 *  Compute a channel id from channel parameters and a channel secret.
 */
CdkStringResult_t
cdk_spilman_channel_parameters_get_channel_id (
    char const * params_json,
    char const * channel_secret_hex,
    char const * keyset_info_json);

/** \brief
 *  Complete a funding swap from the mint's response and the funding secrets.
 */
CdkStringResult_t
cdk_spilman_complete_funding_swap (
    char const * swap_response_json,
    char const * funding_secrets_json,
    char const * keyset_info_json);

/** \brief
 *  Complete a prepared post-expiry sender refund from a mint swap response.
 */
CdkStringResult_t
cdk_spilman_complete_sender_refund (
    char const * params_json,
    char const * channel_secret_hex,
    char const * funding_keyset_info_json,
    char const * funding_proofs_json,
    char const * sender_secret_key_hex,
    char const * prepared_refund_json,
    char const * swap_response_json);

/** \brief
 *  Reconstruct channel parameters from a funding token and both public keys.
 */
CdkStringResult_t
cdk_spilman_compute_channel_from_token (
    char const * token_string,
    char const * receiver_pubkey_hex,
    char const * sender_pubkey_hex,
    char const * channel_secret_hex,
    uint64_t expiry_timestamp,
    char const * keyset_info_json,
    uint64_t maximum_amount_for_one_output);

/** \brief
 *  Compute the shared channel secret from my secret key and their public key.
 */
CdkStringResult_t
cdk_spilman_compute_channel_secret (
    char const * my_secret_key_hex,
    char const * their_pubkey_hex);

/** \brief
 *  Result of receiving a token.
 */
typedef struct CdkReceiveResult {
    /** \brief
     *  Call status.
     */
    CdkStatus_t status;

    /** \brief
     *  Human-readable error message. `NULL` on success.
     */
    char * error;

    /** \brief
     *  Net spendable sats credited to the wallet, valid only when `status` is
     *  [`CdkStatus::Ok`].
     */
    uint64_t net_sats;
} CdkReceiveResult_t;

/** \brief
 *  Compute the minimum funding-token amount for a channel capacity.
 */
CdkReceiveResult_t
cdk_spilman_compute_funding_token_amount (
    uint64_t capacity,
    char const * keyset_info_json,
    uint64_t maximum_amount_for_one_output);

/** \brief
 *  Construct proofs from blind signatures and their secrets/blinding factors.
 */
CdkStringResult_t
cdk_spilman_construct_proofs (
    char const * blind_signatures_json,
    char const * secrets_with_blinding_json,
    char const * keyset_info_json);

/** \brief
 *  Build the funding outputs for a channel.
 *
 *  The receiver key used for derivation is taken from `params_json`, matching
 *  the upstream three-argument helper.
 */
CdkStringResult_t
cdk_spilman_create_funding_outputs (
    char const * params_json,
    char const * sender_privkey_hex,
    char const * keyset_info_json);

/** \brief
 *  Build a funding swap request from channel parameters and input proofs.
 */
CdkStringResult_t
cdk_spilman_create_funding_swap (
    char const * params_json,
    char const * channel_secret_hex,
    char const * keyset_info_json,
    char const * input_proofs_json);

/** \brief
 *  Create a signed balance update for a channel.
 */
CdkStringResult_t
cdk_spilman_create_signed_balance_update (
    char const * params_json,
    char const * keyset_info_json,
    char const * secret_key_hex,
    char const * proofs_json,
    uint64_t balance);

/** \brief
 *  Create an unsigned balance update for a channel.
 */
CdkStringResult_t
cdk_spilman_create_unsigned_balance_update (
    char const * params_json,
    char const * keyset_info_json,
    char const * channel_secret_hex,
    char const * proofs_json,
    uint64_t balance);

/** \brief
 *  Result of generating a Spilman channel keypair.
 *
 *  Carries a secret key, so [`Debug`] is redacted: never rely on `{:?}` to
 *  inspect the key material.
 */
typedef struct CdkSpilmanKeypairResult {
    /** \brief
     *  Call status.
     */
    CdkStatus_t status;

    /** \brief
     *  Human-readable error message. `NULL` on success. Free with
     *  [`cdk_string_free`](crate::cdk_string_free).
     */
    char * error;

    /** \brief
     *  Secret key (32 bytes, hex-encoded), present only on success. Treat as a
     *  secret; free with [`cdk_string_free`](crate::cdk_string_free).
     */
    char * secret_key_hex;

    /** \brief
     *  Public key (33 bytes, hex-encoded), present only on success. Free with
     *  [`cdk_string_free`](crate::cdk_string_free).
     */
    char * pubkey_hex;
} CdkSpilmanKeypairResult_t;

/** \brief
 *  Generate a fresh Spilman keypair (secret key plus public key).
 */
CdkSpilmanKeypairResult_t
cdk_spilman_generate_keypair (void);

/** \brief
 *  Prepare a cooperative close swap request signed by both parties.
 */
CdkStringResult_t
cdk_spilman_prepare_close_swap (
    char const * params_json,
    char const * channel_secret_hex,
    char const * funding_keyset_info_json,
    char const * output_keyset_info_json,
    char const * funding_proofs_json,
    uint64_t balance,
    char const * sender_signature_hex,
    char const * receiver_secret_key_hex);

/** \brief
 *  Prepare a signed post-expiry sender refund swap.
 */
CdkStringResult_t
cdk_spilman_prepare_sender_refund (
    char const * params_json,
    char const * channel_secret_hex,
    char const * funding_keyset_info_json,
    char const * output_keyset_info_json,
    char const * funding_proofs_json,
    char const * sender_secret_key_hex,
    uint64_t now_seconds,
    char const * derivation_context_hex);

/** \brief
 *  Derive the public key for a secret key (both hex-encoded).
 */
CdkStringResult_t
cdk_spilman_secret_key_to_pubkey (
    char const * secret_key_hex);

/** \brief
 *  Sign a message with a secret key tweaked by a scalar (all hex-encoded).
 */
CdkStringResult_t
cdk_spilman_sign_with_tweaked_key_util (
    char const * secret_key_hex,
    char const * message_hex,
    char const * tweak_scalar_hex);

/** \brief
 *  Result of completing a Spilman channel close.
 *
 *  Carries proofs (which embed bearer secrets), so [`Debug`] is redacted: never
 *  rely on `{:?}` to inspect the proof payloads.
 */
typedef struct CdkSpilmanCloseResult {
    /** \brief
     *  Call status.
     */
    CdkStatus_t status;

    /** \brief
     *  Human-readable error message. `NULL` on success. Free with
     *  [`cdk_string_free`](crate::cdk_string_free).
     */
    char * error;

    /** \brief
     *  Receiver proofs (JSON array), present only on success. Treat as a
     *  secret; free with [`cdk_string_free`](crate::cdk_string_free).
     */
    char * receiver_proofs_json;

    /** \brief
     *  Sender (change) proofs (JSON array), present only on success. Treat as a
     *  secret; free with [`cdk_string_free`](crate::cdk_string_free).
     */
    char * sender_proofs_json;

    /** \brief
     *  Sum of the receiver proofs, valid only when `status` is
     *  [`CdkStatus::Ok`].
     */
    uint64_t receiver_sum;

    /** \brief
     *  Sum of the sender proofs, valid only when `status` is [`CdkStatus::Ok`].
     */
    uint64_t sender_sum;
} CdkSpilmanCloseResult_t;

/** \brief
 *  Unblind a close swap response and sign the receiver's proofs.
 */
CdkSpilmanCloseResult_t
cdk_spilman_unblind_close_swap (
    char const * params_json,
    char const * channel_secret_hex,
    char const * funding_keyset_info_json,
    char const * output_keyset_info_json,
    char const * secrets_with_blinding_json,
    char const * swap_response_json,
    uint64_t balance,
    char const * receiver_secret_key_hex);

/** \brief
 *  Result of an operation that returns no payload beyond success/failure.
 */
typedef struct CdkStatusResult {
    /** \brief
     *  Call status.
     */
    CdkStatus_t status;

    /** \brief
     *  Human-readable error message. `NULL` on success. Free with
     *  [`cdk_string_free`](crate::cdk_string_free).
     */
    char * error;
} CdkStatusResult_t;

/** \brief
 *  Verify a signed balance update against a channel's funding proofs.
 */
CdkStatusResult_t
cdk_spilman_verify_balance_update (
    char const * params_json,
    char const * channel_secret_hex,
    char const * keyset_info_json,
    char const * funding_proofs_json,
    char const * channel_id,
    uint64_t balance,
    char const * signature_hex);

/** \brief
 *  Verify that a channel's funding proofs are valid.
 */
CdkStatusResult_t
cdk_spilman_verify_valid_channel (
    char const * params_json,
    char const * channel_secret_hex,
    char const * keyset_info_json,
    char const * funding_proofs_json);

/** \brief
 *  Free an owned string returned by this library.
 *
 *  The string contents are scrubbed with `zeroize` before the allocation is
 *  freed, so a freed phrase or bearer token is not left in the heap. Passing
 *  `NULL` is a safe no-op. Only pass strings produced by this library.
 */
void
cdk_string_free (
    char * string);

/** \brief
 *  Decode a token's proofs into JSON, expanding short keyset ids using the
 *  supplied keyset info.
 */
CdkStringResult_t
cdk_token_to_proofs_json (
    char const * token,
    char const * keyset_info_json);

/** \brief
 *  The opaque wallet handle exposed to C.
 *
 *  Created by [`crate::api::cdk_wallet_open`] and destroyed by
 *  [`crate::api::cdk_wallet_close`]. It is not thread-safe by itself: the caller
 *  must serialize all calls that use the same handle.
 *
 *  [`Debug`] is redacted: it never prints the seed or the repository internals.
 */
typedef struct CdkWallet CdkWallet_t;

/** \brief
 *  Approve (register) a mint.
 *
 *  Idempotent for an already-approved mint. Requires network access to fetch
 *  the mint's advertised units.
 */
CdkStatusResult_t
cdk_wallet_add_mint (
    CdkWallet_t * handle,
    char const * mint_url);

/** \brief
 *  Free a wallet handle.
 *
 *  Flushes any pending rate-limiter state, then releases the handle. The handle
 *  is consumed even if the call reports an error, so it must never be reused;
 *  passing `NULL` is a safe no-op. No call using the handle may still be in
 *  flight.
 */
CdkStatusResult_t
cdk_wallet_close (
    CdkWallet_t * handle);

/** \brief
 *  Return the mint's active Sat keyset as Spilman `KeysetInfo` JSON.
 */
CdkStringResult_t
cdk_wallet_get_active_keyset_info_json (
    CdkWallet_t const * handle,
    char const * mint_url);

/** \brief
 *  Return a single Sat keyset, by id, as Spilman `KeysetInfo` JSON.
 */
CdkStringResult_t
cdk_wallet_get_keyset_info_json (
    CdkWallet_t const * handle,
    char const * mint_url,
    char const * keyset_id);

/** \brief
 *  `&'lt [T]` but with a guaranteed `#[repr(C)]` layout.
 *
 *  # C layout (for some given type T)
 *
 *  ```c
 *  typedef struct {
 *  // Cannot be NULL
 *  T * ptr;
 *  size_t len;
 *  } slice_T;
 *  ```
 *
 *  # Nullable pointer?
 *
 *  If you want to support the above typedef, but where the `ptr` field is
 *  allowed to be `NULL` (with the contents of `len` then being undefined)
 *  use the `Option< slice_ptr<_> >` type.
 */
typedef struct slice_ref_uint8 {
    /** \brief
     *  Pointer to the first element (if any).
     */
    uint8_t const * ptr;

    /** \brief
     *  Element count
     */
    size_t len;
} slice_ref_uint8_t;

/** \brief
 *  Retrieve a single pending outgoing token by its 16-byte operation id.
 */
CdkStringResult_t
cdk_wallet_get_pending_token (
    CdkWallet_t const * handle,
    slice_ref_uint8_t operation_id);

/** \brief
 *  Result of listing balances.
 */
typedef struct CdkBalanceListResult {
    /** \brief
     *  Call status.
     */
    CdkStatus_t status;

    /** \brief
     *  Human-readable error message. `NULL` on success.
     */
    char * error;

    /** \brief
     *  Owned list of balances. Free with
     *  [`cdk_balance_list_free`](crate::cdk_balance_list_free).
     */
    Vec_CdkBalanceEntry_t balances;
} CdkBalanceListResult_t;

/** \brief
 *  List approved mints with their locally spendable Sat balance.
 */
CdkBalanceListResult_t
cdk_wallet_list_balances (
    CdkWallet_t const * handle);

/** \brief
 *  Result of listing approved mints.
 */
typedef struct CdkMintListResult {
    /** \brief
     *  Call status.
     */
    CdkStatus_t status;

    /** \brief
     *  Human-readable error message. `NULL` on success.
     */
    char * error;

    /** \brief
     *  Owned list of mint URLs. Free with
     *  [`cdk_mint_list_free`](crate::cdk_mint_list_free).
     */
    Vec_char_ptr_t mints;
} CdkMintListResult_t;

/** \brief
 *  List approved mint URLs.
 */
CdkMintListResult_t
cdk_wallet_list_mints (
    CdkWallet_t const * handle);

/** \brief
 *  Result of listing pending outgoing tokens.
 */
typedef struct CdkPendingListResult {
    /** \brief
     *  Call status.
     */
    CdkStatus_t status;

    /** \brief
     *  Human-readable error message. `NULL` on success.
     */
    char * error;

    /** \brief
     *  Owned list of pending tokens. Free with
     *  [`cdk_pending_list_free`](crate::cdk_pending_list_free).
     */
    Vec_CdkPendingToken_t pending;
} CdkPendingListResult_t;

/** \brief
 *  List pending outgoing tokens (created but not claimed).
 */
CdkPendingListResult_t
cdk_wallet_list_pending_tokens (
    CdkWallet_t const * handle);

/** \brief
 *  Result of opening a wallet database.
 *
 *  The handle is opaque, so [`Debug`] does not print it.
 */
typedef struct CdkOpenResult {
    /** \brief
     *  Call status.
     */
    CdkStatus_t status;

    /** \brief
     *  Human-readable error message. `NULL` on success.
     */
    char * error;

    /** \brief
     *  The initialized opaque handle. `NULL` on failure. Free with
     *  [`cdk_wallet_close`](crate::cdk_wallet_close).
     */
    CdkWallet_t * handle;

    /** \brief
     *  Sagas recovered during startup recovery.
     */
    uint32_t recovered;

    /** \brief
     *  Sagas compensated (rolled back) during startup recovery.
     */
    uint32_t compensated;

    /** \brief
     *  Sagas skipped (unresolved, will retry) during startup recovery.
     */
    uint32_t skipped;

    /** \brief
     *  Sagas that failed recovery during startup recovery.
     */
    uint32_t failed;

    /** \brief
     *  Per-mint startup recovery reports (one entry per approved Sat mint).
     *  Free with
     *  [`cdk_recovery_reports_free`](crate::cdk_recovery_reports_free).
     */
    Vec_CdkMintRecovery_t reports;
} CdkOpenResult_t;

/** \brief
 *  Open (creating if needed) a wrapper-owned database.
 *
 *  `seed` must be exactly 64 bytes. `db_path` must be a valid UTF-8 filesystem
 *  path. On success the returned `handle` is owned by the caller and must be
 *  freed with [`cdk_wallet_close`].
 */
CdkOpenResult_t
cdk_wallet_open (
    slice_ref_uint8_t seed,
    char const * db_path);

/** \brief
 *  Post a raw NUT-03 swap request to a mint, returning the raw response JSON.
 */
CdkStringResult_t
cdk_wallet_post_swap (
    CdkWallet_t const * handle,
    char const * mint_url,
    char const * swap_request_json);

/** \brief
 *  Receive a token, returning the net Sat amount credited.
 */
CdkReceiveResult_t
cdk_wallet_receive (
    CdkWallet_t * handle,
    char const * token);

/** \brief
 *  Receive raw proofs from a mint, optionally supplying P2PK signing keys.
 */
CdkReceiveResult_t
cdk_wallet_receive_proofs (
    CdkWallet_t * handle,
    char const * mint_url,
    char const * proofs_json,
    char const * signing_key_hex);

/** \brief
 *  Receive a token, optionally supplying comma-separated P2PK signing keys.
 */
CdkReceiveResult_t
cdk_wallet_receive_with_keys (
    CdkWallet_t * handle,
    char const * token,
    char const * signing_key_hex);

/** \brief
 *  Result of an explicit recovery retry.
 */
typedef struct CdkRecoveryResult {
    /** \brief
     *  Call status.
     */
    CdkStatus_t status;

    /** \brief
     *  Human-readable error message. `NULL` on success.
     */
    char * error;

    /** \brief
     *  Sagas recovered (aggregate convenience; see `reports` for per-mint).
     */
    uint32_t recovered;

    /** \brief
     *  Sagas compensated (aggregate convenience; see `reports` for per-mint).
     */
    uint32_t compensated;

    /** \brief
     *  Sagas skipped (aggregate convenience; see `reports` for per-mint).
     */
    uint32_t skipped;

    /** \brief
     *  Sagas that failed recovery (aggregate convenience; see `reports`).
     */
    uint32_t failed;

    /** \brief
     *  Per-mint recovery reports. Free with
     *  [`cdk_recovery_reports_free`](crate::cdk_recovery_reports_free).
     */
    Vec_CdkMintRecovery_t reports;
} CdkRecoveryResult_t;

/** \brief
 *  Run explicit operation recovery for all mints, or a single mint.
 *
 *  Pass `NULL` for `mint_url` to recover every approved mint.
 */
CdkRecoveryResult_t
cdk_wallet_recover (
    CdkWallet_t * handle,
    char const * mint_url);

/** \brief
 *  Result of sending a token.
 *
 *  Carries a bearer token on success, so [`Debug`] is redacted.
 */
typedef struct CdkSendResult {
    /** \brief
     *  Call status.
     */
    CdkStatus_t status;

    /** \brief
     *  Human-readable error message. `NULL` on success.
     */
    char * error;

    /** \brief
     *  The bearer token, present only on success. Treat as a secret; free with
     *  [`cdk_string_free`](crate::cdk_string_free).
     */
    char * token;

    /** \brief
     *  Operation identifier for the send, always populated (zeroes on
     *  pre-prepare failure). 16 raw UUID bytes.
     */
    uint8_16_array_t operation_id;

    /** \brief
     *  Sender fee actually charged, in sats. Only meaningful on success or
     *  [`CdkStatus::SendUncertain`].
     */
    uint64_t sender_fee_sats;
} CdkSendResult_t;

/** \brief
 *  Send `amount_sats` from an explicitly selected mint.
 *
 *  The total send fee must not exceed `max_sender_fee_sats`, otherwise the send
 *  is cancelled. On success the returned `token` is a bearer secret owned by
 *  the caller and must be freed with [`cdk_string_free`].
 */
CdkSendResult_t
cdk_wallet_send (
    CdkWallet_t * handle,
    char const * mint_url,
    uint64_t amount_sats,
    uint64_t max_sender_fee_sats);


#ifdef __cplusplus
} /* extern \"C\" */
#endif

#endif /* CDK_WALLET_H */
