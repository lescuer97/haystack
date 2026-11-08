//! Fixed-width status codes and result structs shared across the C ABI.
//!
//! Every exported function returns a plain `#[repr(C)]` struct that begins with
//! a [`CdkStatus`] and carries an optional, Rust-owned error message. No global
//! "last error" state is used, so concurrent calls cannot race on diagnostics.

use std::fmt;

use safer_ffi::prelude::*;

/// Fixed-width per-call status. The numeric values are part of the ABI and must
/// not be renumbered.
#[derive_ReprC]
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CdkStatus {
    /// The call succeeded.
    Ok = 0,
    /// A required pointer argument was null.
    NullArgument = 1,
    /// An argument was structurally invalid (bad length, empty string, ...).
    InvalidArgument = 2,
    /// The seed was not exactly 64 bytes.
    InvalidSeed = 3,
    /// The database path was invalid (empty, a directory, not creatable, ...).
    InvalidPath = 4,
    /// The database file is already locked by another live handle/process.
    AlreadyOpen = 5,
    /// An existing database file does not carry this wrapper's marker.
    UnsupportedDatabase = 6,
    /// The stored seed fingerprint does not match the provided seed.
    SeedMismatch = 7,
    /// The database was written by an incompatible wrapper format version.
    UnsupportedFormatVersion = 8,
    /// The mint URL was rejected by URL policy validation.
    InvalidMintUrl = 9,
    /// The mint does not advertise the Sat unit.
    MintUnsupportedUnit = 10,
    /// The mint has not been approved/registered with this wallet.
    MintNotRegistered = 11,
    /// Registering the mint failed.
    MintRegistrationFailed = 12,
    /// A network operation failed.
    NetworkError = 13,
    /// The wallet does not hold enough locally spendable funds.
    InsufficientFunds = 14,
    /// The sender fee would exceed the caller-provided maximum.
    FeeLimitExceeded = 15,
    /// The token string could not be parsed.
    InvalidToken = 16,
    /// The token is structurally unsupported (multi-mint, wrong unit, ...).
    UnsupportedToken = 17,
    /// The token belongs to a mint that has not been approved.
    TokenUnknownMint = 18,
    /// A previous operation for this mint still has unresolved recovery state.
    RecoveryPending = 19,
    /// The send definitively failed; the mint rejected it and no token exists.
    SendFailed = 20,
    /// The send outcome is uncertain; do not retry blindly.
    SendUncertain = 21,
    /// Receiving the token failed.
    ReceiveFailed = 22,
    /// A local database operation failed.
    DatabaseError = 23,
    /// An unexpected internal error occurred.
    InternalError = 24,
    /// A send's reserved proofs could not be released after the fee limit was
    /// exceeded; the mint is now fail-closed until recovery succeeds.
    CancellationFailed = 25,
    /// The requested pending operation does not exist.
    OperationNotFound = 26,
    /// The database file has group/other access permissions that are too broad
    /// (anything other than owner-only). The wrapper refuses to use it.
    InsecureDatabasePermissions = 27,
}

impl CdkStatus {
    /// True when this status represents a successful call.
    pub fn is_ok(self) -> bool {
        matches!(self, CdkStatus::Ok)
    }
}

/// Result of an operation that returns no payload beyond success/failure.
#[derive_ReprC]
#[repr(C)]
#[derive(Debug)]
pub struct CdkStatusResult {
    /// Call status.
    pub status: CdkStatus,
    /// Human-readable error message. `NULL` on success. Free with
    /// [`cdk_string_free`](crate::cdk_string_free).
    pub error: Option<char_p::Box>,
}

impl CdkStatusResult {
    /// Build an error result.
    pub fn err(status: CdkStatus, message: impl Into<String>) -> Self {
        Self {
            status,
            error: string_to_box(message.into()),
        }
    }

    /// Build a success result.
    pub fn ok() -> Self {
        Self {
            status: CdkStatus::Ok,
            error: None,
        }
    }
}

/// Result carrying a single owned string payload.
///
/// The payload may be a bearer token, so [`Debug`] is redacted: never rely on
/// `{:?}` to inspect a token.
#[derive_ReprC]
#[repr(C)]
pub struct CdkStringResult {
    /// Call status.
    pub status: CdkStatus,
    /// Human-readable error message. `NULL` on success. Free with
    /// [`cdk_string_free`](crate::cdk_string_free).
    pub error: Option<char_p::Box>,
    /// Owned string payload, present only on success. Free with
    /// [`cdk_string_free`](crate::cdk_string_free).
    pub value: Option<char_p::Box>,
}

impl fmt::Debug for CdkStringResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CdkStringResult")
            .field("status", &self.status)
            .field("error", &self.error)
            .field("value", &self.value.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

impl CdkStringResult {
    /// Build an error result.
    pub fn err(status: CdkStatus, message: impl Into<String>) -> Self {
        Self {
            status,
            error: string_to_box(message.into()),
            value: None,
        }
    }
}

/// Result carrying an owned byte-vector payload.
///
/// The payload may be raw mnemonic entropy or a derived wallet seed, both of
/// which are secret material, so [`Debug`] is redacted: never rely on `{:?}` to
/// inspect the bytes.
#[derive_ReprC]
#[repr(C)]
pub struct CdkBytesResult {
    /// Call status.
    pub status: CdkStatus,
    /// Human-readable error message. `NULL` on success. Free with
    /// [`cdk_string_free`](crate::cdk_string_free).
    pub error: Option<char_p::Box>,
    /// Owned byte payload, present only on success and empty on failure. Free
    /// with [`cdk_bytes_free`](crate::cdk_bytes_free).
    pub bytes: repr_c::Vec<u8>,
}

impl fmt::Debug for CdkBytesResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CdkBytesResult")
            .field("status", &self.status)
            .field("error", &self.error)
            .field(
                "bytes",
                &format_args!("<redacted; {} bytes>", self.bytes.len()),
            )
            .finish()
    }
}

impl CdkBytesResult {
    /// Build an error result with an empty payload.
    pub fn err(status: CdkStatus, message: impl Into<String>) -> Self {
        Self {
            status,
            error: string_to_box(message.into()),
            bytes: repr_c::Vec::from(Vec::new()),
        }
    }
}

/// Result of opening a wallet database.
///
/// The handle is opaque, so [`Debug`] does not print it.
#[derive_ReprC]
#[repr(C)]
pub struct CdkOpenResult {
    /// Call status.
    pub status: CdkStatus,
    /// Human-readable error message. `NULL` on success.
    pub error: Option<char_p::Box>,
    /// The initialized opaque handle. `NULL` on failure. Free with
    /// [`cdk_wallet_close`](crate::cdk_wallet_close).
    pub handle: Option<repr_c::Box<crate::CdkWallet>>,
    /// Sagas recovered during startup recovery.
    pub recovered: u32,
    /// Sagas compensated (rolled back) during startup recovery.
    pub compensated: u32,
    /// Sagas skipped (unresolved, will retry) during startup recovery.
    pub skipped: u32,
    /// Sagas that failed recovery during startup recovery.
    pub failed: u32,
    /// Per-mint startup recovery reports (one entry per approved Sat mint).
    /// Free with
    /// [`cdk_recovery_reports_free`](crate::cdk_recovery_reports_free).
    pub reports: repr_c::Vec<CdkMintRecovery>,
}

impl fmt::Debug for CdkOpenResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CdkOpenResult")
            .field("status", &self.status)
            .field("error", &self.error)
            .field("handle", &self.handle.as_ref().map(|_| "<handle>"))
            .field("recovered", &self.recovered)
            .field("compensated", &self.compensated)
            .field("skipped", &self.skipped)
            .field("failed", &self.failed)
            .field("reports", &self.reports)
            .finish()
    }
}

/// Result of receiving a token.
#[derive_ReprC]
#[repr(C)]
#[derive(Debug)]
pub struct CdkReceiveResult {
    /// Call status.
    pub status: CdkStatus,
    /// Human-readable error message. `NULL` on success.
    pub error: Option<char_p::Box>,
    /// Net spendable sats credited to the wallet, valid only when `status` is
    /// [`CdkStatus::Ok`].
    pub net_sats: u64,
}

/// Result of sending a token.
///
/// Carries a bearer token on success, so [`Debug`] is redacted.
#[derive_ReprC]
#[repr(C)]
pub struct CdkSendResult {
    /// Call status.
    pub status: CdkStatus,
    /// Human-readable error message. `NULL` on success.
    pub error: Option<char_p::Box>,
    /// The bearer token, present only on success. Treat as a secret; free with
    /// [`cdk_string_free`](crate::cdk_string_free).
    pub token: Option<char_p::Box>,
    /// Operation identifier for the send, always populated (zeroes on
    /// pre-prepare failure). 16 raw UUID bytes.
    pub operation_id: [u8; 16],
    /// Sender fee actually charged, in sats. Only meaningful on success or
    /// [`CdkStatus::SendUncertain`].
    pub sender_fee_sats: u64,
}

impl fmt::Debug for CdkSendResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CdkSendResult")
            .field("status", &self.status)
            .field("error", &self.error)
            .field("token", &self.token.as_ref().map(|_| "<redacted>"))
            .field("operation_id", &self.operation_id)
            .field("sender_fee_sats", &self.sender_fee_sats)
            .finish()
    }
}

impl CdkSendResult {
    /// Build an error result with no operation id.
    pub fn err(status: CdkStatus, message: impl Into<String>) -> Self {
        Self {
            status,
            error: string_to_box(message.into()),
            token: None,
            operation_id: [0u8; 16],
            sender_fee_sats: 0,
        }
    }

    /// Build an error result that still identifies the operation.
    pub fn err_with_op(
        status: CdkStatus,
        message: impl Into<String>,
        operation_id: [u8; 16],
        sender_fee_sats: u64,
    ) -> Self {
        Self {
            status,
            error: string_to_box(message.into()),
            token: None,
            operation_id,
            sender_fee_sats,
        }
    }
}

/// One approved mint and its locally spendable Sat balance.
#[derive_ReprC]
#[repr(C)]
#[derive(Debug)]
pub struct CdkBalanceEntry {
    /// Approved mint URL. Free with [`cdk_balance_list_free`](crate::cdk_balance_list_free).
    pub mint_url: char_p::Box,
    /// Locally spendable (unspent, non-reserved) sats at this mint.
    pub balance_sats: u64,
}

/// One pending outgoing token.
///
/// Carries a bearer token, so [`Debug`] is redacted.
#[derive_ReprC]
#[repr(C)]
pub struct CdkPendingToken {
    /// Operation identifier (16 raw UUID bytes).
    pub operation_id: [u8; 16],
    /// The bearer token. Treat as a secret. Free with
    /// [`cdk_pending_list_free`](crate::cdk_pending_list_free).
    pub token: char_p::Box,
}

impl fmt::Debug for CdkPendingToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CdkPendingToken")
            .field("operation_id", &self.operation_id)
            .field("token", &"<redacted>")
            .finish()
    }
}

/// Result of listing approved mints.
#[derive_ReprC]
#[repr(C)]
#[derive(Debug)]
pub struct CdkMintListResult {
    /// Call status.
    pub status: CdkStatus,
    /// Human-readable error message. `NULL` on success.
    pub error: Option<char_p::Box>,
    /// Owned list of mint URLs. Free with
    /// [`cdk_mint_list_free`](crate::cdk_mint_list_free).
    pub mints: repr_c::Vec<char_p::Box>,
}

/// Result of listing balances.
#[derive_ReprC]
#[repr(C)]
#[derive(Debug)]
pub struct CdkBalanceListResult {
    /// Call status.
    pub status: CdkStatus,
    /// Human-readable error message. `NULL` on success.
    pub error: Option<char_p::Box>,
    /// Owned list of balances. Free with
    /// [`cdk_balance_list_free`](crate::cdk_balance_list_free).
    pub balances: repr_c::Vec<CdkBalanceEntry>,
}

/// Result of listing pending outgoing tokens.
#[derive_ReprC]
#[repr(C)]
#[derive(Debug)]
pub struct CdkPendingListResult {
    /// Call status.
    pub status: CdkStatus,
    /// Human-readable error message. `NULL` on success.
    pub error: Option<char_p::Box>,
    /// Owned list of pending tokens. Free with
    /// [`cdk_pending_list_free`](crate::cdk_pending_list_free).
    pub pending: repr_c::Vec<CdkPendingToken>,
}

/// Per-mint recovery outcome.
///
/// One entry per approved Sat mint, describing how recovery went for that mint
/// specifically. A mint whose `failed`/`skipped` counters are non-zero (or whose
/// `status` is not [`CdkStatus::Ok`]) is left fail-closed until recovery
/// succeeds.
#[derive_ReprC]
#[repr(C)]
#[derive(Debug)]
pub struct CdkMintRecovery {
    /// Mint URL. Free with
    /// [`cdk_recovery_reports_free`](crate::cdk_recovery_reports_free).
    pub mint_url: char_p::Box,
    /// Sagas recovered for this mint.
    pub recovered: u32,
    /// Sagas compensated (rolled back) for this mint.
    pub compensated: u32,
    /// Sagas skipped (still unresolved) for this mint.
    pub skipped: u32,
    /// Sagas that failed recovery for this mint.
    pub failed: u32,
    /// Status of the recovery call for this mint: [`CdkStatus::Ok`] if the call
    /// itself completed (even if some sagas were skipped), otherwise the error.
    pub status: CdkStatus,
    /// Non-secret diagnostic, present when a mint was skipped, failed, or the
    /// recovery call itself errored. `NULL` when the mint recovered cleanly.
    /// Free with
    /// [`cdk_recovery_reports_free`](crate::cdk_recovery_reports_free).
    pub message: Option<char_p::Box>,
}

/// Result of an explicit recovery retry.
#[derive_ReprC]
#[repr(C)]
#[derive(Debug)]
pub struct CdkRecoveryResult {
    /// Call status.
    pub status: CdkStatus,
    /// Human-readable error message. `NULL` on success.
    pub error: Option<char_p::Box>,
    /// Sagas recovered (aggregate convenience; see `reports` for per-mint).
    pub recovered: u32,
    /// Sagas compensated (aggregate convenience; see `reports` for per-mint).
    pub compensated: u32,
    /// Sagas skipped (aggregate convenience; see `reports` for per-mint).
    pub skipped: u32,
    /// Sagas that failed recovery (aggregate convenience; see `reports`).
    pub failed: u32,
    /// Per-mint recovery reports. Free with
    /// [`cdk_recovery_reports_free`](crate::cdk_recovery_reports_free).
    pub reports: repr_c::Vec<CdkMintRecovery>,
}

/// Result of generating a Spilman channel keypair.
///
/// Carries a secret key, so [`Debug`] is redacted: never rely on `{:?}` to
/// inspect the key material.
#[derive_ReprC]
#[repr(C)]
pub struct CdkSpilmanKeypairResult {
    /// Call status.
    pub status: CdkStatus,
    /// Human-readable error message. `NULL` on success. Free with
    /// [`cdk_string_free`](crate::cdk_string_free).
    pub error: Option<char_p::Box>,
    /// Secret key (32 bytes, hex-encoded), present only on success. Treat as a
    /// secret; free with [`cdk_string_free`](crate::cdk_string_free).
    pub secret_key_hex: Option<char_p::Box>,
    /// Public key (33 bytes, hex-encoded), present only on success. Free with
    /// [`cdk_string_free`](crate::cdk_string_free).
    pub pubkey_hex: Option<char_p::Box>,
}

impl fmt::Debug for CdkSpilmanKeypairResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CdkSpilmanKeypairResult")
            .field("status", &self.status)
            .field("error", &self.error)
            .field(
                "secret_key_hex",
                &self.secret_key_hex.as_ref().map(|_| "<redacted>"),
            )
            .field("pubkey_hex", &self.pubkey_hex)
            .finish()
    }
}

impl CdkSpilmanKeypairResult {
    /// Build an error result.
    pub fn err(status: CdkStatus, message: impl Into<String>) -> Self {
        Self {
            status,
            error: string_to_box(message.into()),
            secret_key_hex: None,
            pubkey_hex: None,
        }
    }
}

/// Result of completing a Spilman channel close.
///
/// Carries proofs (which embed bearer secrets), so [`Debug`] is redacted: never
/// rely on `{:?}` to inspect the proof payloads.
#[derive_ReprC]
#[repr(C)]
pub struct CdkSpilmanCloseResult {
    /// Call status.
    pub status: CdkStatus,
    /// Human-readable error message. `NULL` on success. Free with
    /// [`cdk_string_free`](crate::cdk_string_free).
    pub error: Option<char_p::Box>,
    /// Receiver proofs (JSON array), present only on success. Treat as a
    /// secret; free with [`cdk_string_free`](crate::cdk_string_free).
    pub receiver_proofs_json: Option<char_p::Box>,
    /// Sender (change) proofs (JSON array), present only on success. Treat as a
    /// secret; free with [`cdk_string_free`](crate::cdk_string_free).
    pub sender_proofs_json: Option<char_p::Box>,
    /// Sum of the receiver proofs, valid only when `status` is
    /// [`CdkStatus::Ok`].
    pub receiver_sum: u64,
    /// Sum of the sender proofs, valid only when `status` is [`CdkStatus::Ok`].
    pub sender_sum: u64,
}

impl fmt::Debug for CdkSpilmanCloseResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CdkSpilmanCloseResult")
            .field("status", &self.status)
            .field("error", &self.error)
            .field(
                "receiver_proofs_json",
                &self.receiver_proofs_json.as_ref().map(|_| "<redacted>"),
            )
            .field(
                "sender_proofs_json",
                &self.sender_proofs_json.as_ref().map(|_| "<redacted>"),
            )
            .field("receiver_sum", &self.receiver_sum)
            .field("sender_sum", &self.sender_sum)
            .finish()
    }
}

impl CdkSpilmanCloseResult {
    /// Build an error result.
    pub fn err(status: CdkStatus, message: impl Into<String>) -> Self {
        Self {
            status,
            error: string_to_box(message.into()),
            receiver_proofs_json: None,
            sender_proofs_json: None,
            receiver_sum: 0,
            sender_sum: 0,
        }
    }
}

/// Convert a Rust `String` into an owned, NUL-terminated C string.
///
/// Interior NUL bytes are replaced with `U+FFFD` so the conversion can never
/// fail for content reasons (and never silently truncates a message).
pub(crate) fn string_to_box(s: String) -> Option<char_p::Box> {
    let sanitized = if s.as_bytes().contains(&0) {
        s.replace('\0', "\u{FFFD}")
    } else {
        s
    };
    // Every interior NUL is gone, so `try_from` cannot fail for content reasons
    // (the only other failure mode is allocation, which aborts).
    Some(char_p::Box::try_from(sanitized).expect("interior NUL bytes were removed"))
}
