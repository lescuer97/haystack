//! Core (non-FFI) implementation behind the C ABI.
//!
//! Everything in this module is ordinary Rust. The [`crate::api`] layer only
//! validates raw C arguments, then calls into these helpers inside a
//! [`std::panic::catch_unwind`] and a persistent Tokio runtime.
//!
//! # Responsibilities
//!
//! * Own a single SQLite database and a single 64-byte seed.
//! * Enforce the "wrapper-owned database" contract (marker + seed fingerprint).
//! * Hold an exclusive advisory lock on the database file for the lifetime of
//!   the handle, without colliding with SQLite's own byte-range locks.
//! * Run startup / explicit operation recovery and report per-mint outcomes so
//!   that mutations fail closed while reads stay available.
//! * Never log or echo bearer tokens.

use std::collections::{BTreeSet, HashMap};
#[cfg(not(target_arch = "wasm32"))]
use std::fs::{self, DirBuilder, File, OpenOptions};
#[cfg(not(target_arch = "wasm32"))]
use std::io;
#[cfg(not(target_arch = "wasm32"))]
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
#[cfg(not(target_arch = "wasm32"))]
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
#[cfg(not(target_arch = "wasm32"))]
use std::sync::OnceLock;
use std::time::Duration;

#[cfg(target_arch = "wasm32")]
use crate::browser_db::BrowserDatabase as WalletSqliteDatabase;
#[cfg(target_arch = "wasm32")]
use crate::browser_platform::{timeout, BrowserLock as File};
use cdk::amount::SplitTarget;
use cdk::mint_url::MintUrl;
use cdk::nuts::{
    BlindSignature, BlindedMessage, CheckStateRequest, CurrencyUnit, Id, MintQuoteState,
    PaymentMethod, Proofs, PublicKey, RestoreRequest, RestoreResponse, SecretKey, State,
    SwapRequest, SwapResponse, Token,
};
use cdk::wallet::{
    HttpClient, MintConnector, PreparedSend, ReceiveOptions, SendKind, SendOptions, Wallet,
    WalletRepository, WalletRepositoryBuilder,
};
use cdk::{Amount, Error as CdkError};
use cdk_common::bitcoin::hashes::{sha256, Hash as _, HashEngine as _};
use cdk_common::database::{self, WalletDatabase};
use cdk_common::wallet::{OperationData, WalletSagaState};
#[cfg(not(target_arch = "wasm32"))]
use cdk_sqlite::WalletSqliteDatabase;
#[cfg(not(target_arch = "wasm32"))]
use rusqlite::OptionalExtension as _;
use safer_ffi::prelude::*;
#[cfg(not(target_arch = "wasm32"))]
use tokio::time::timeout;
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::status::CdkStatus;

#[path = "withdrawal.rs"]
mod withdrawal;
use withdrawal::PreparedWithdrawal;

fn unix_now() -> u64 {
    #[cfg(target_arch = "wasm32")]
    {
        (js_sys::Date::now() / 1000.0) as u64
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }
}

fn quote_expired(quote: &cdk_common::wallet::MintQuote, now: u64) -> bool {
    quote.expiry != 0 && quote.state == MintQuoteState::Unpaid && quote.is_expired(now)
}

/// Keep legacy sat deposit intents intact and separate from msat deposits.
const DEPOSIT_INTENT_NAMESPACE: &str = "deposit_intent_v2";

/// Key-value namespace used for this wrapper's metadata.
const KV_NAMESPACE: &str = "cdk_wallet_ffi";
/// On-disk format version of the wrapper metadata.
const FORMAT_VERSION: u32 = 1;
/// Single KV key holding the wrapper marker (`version || seed fingerprint`).
const KEY_MARKER: &str = "marker";
/// Domain-separation prefix for the seed fingerprint.
const FINGERPRINT_PREFIX: &[u8] = b"cdk-wallet-ffi:v1:seed:";
/// Length of the marker record: 4-byte little-endian version + 32-byte hash.
const MARKER_LEN: usize = 4 + 32;
/// The only currency unit this wrapper supports.
const UNIT: CurrencyUnit = CurrencyUnit::Msat;
/// Check the live mint, not cached wallet metadata or NUT payment settings.
pub(crate) async fn check_mint_keysets(url: &str) -> FfiResult<()> {
    require_active_keyset(&parse_mint_url(url)?, NETWORK_DEADLINE).await
}

async fn require_active_keyset(mint: &MintUrl, deadline: Duration) -> FfiResult<()> {
    let client = HttpClient::new(mint.clone(), None);
    let response = timeout(deadline, client.get_mint_keysets())
        .await
        .map_err(|_| FfiErr::new(CdkStatus::NetworkError, "mint keyset request timed out"))?
        .map_err(|e| {
            FfiErr::new(
                CdkStatus::NetworkError,
                format!("could not fetch mint keysets: {e}"),
            )
        })?;
    if !response.keysets.iter().any(|k| k.active && k.unit == UNIT) {
        return Err(FfiErr::new(
            CdkStatus::MintUnsupportedUnit,
            "mint has no active msat keyset",
        ));
    }
    Ok(())
}

/// Maximum accepted token string length (1 MiB).
///
/// Tokens are far smaller; this bounds the base64/CBOR work and the allocation
/// a malicious caller can force with an oversized input.
pub(crate) const MAX_TOKEN_BYTES: usize = 1024 * 1024;
/// Deadline for a single network-facing mint request (fetch, receive, send).
///
/// The bitreq transport used by CDK is fully asynchronous (Tokio sockets), so
/// dropping the request future cancels the underlying I/O; this deadline is the
/// bridge that guarantees the ABI call returns even if the mint never answers.
/// A deadline reached during a *mutation* is crash-equivalent: it is reported as
/// an uncertain outcome and the mint is fail-closed until recovery succeeds.
const NETWORK_DEADLINE: Duration = Duration::from_secs(60);
/// Longer deadline for startup / explicit recovery, which may replay several
/// requests against a mint.
const RECOVERY_DEADLINE: Duration = Duration::from_secs(120);
/// Seed restoration can scan many batches across multiple keysets.
const SEED_RESTORE_DEADLINE: Duration = Duration::from_secs(30 * 60);

/// The persistent, multi-threaded Tokio runtime.
///
/// A single runtime is created lazily and never shut down. Every blocking ABI
/// call drives its future on this runtime with [`tokio::runtime::Runtime::block_on`].
#[cfg(not(target_arch = "wasm32"))]
static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

/// Borrow (initializing on first use) the process-wide Tokio runtime.
#[cfg(not(target_arch = "wasm32"))]
pub(crate) fn runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("cdk-wallet-ffi")
            .build()
            .expect("failed to build the cdk-wallet-ffi Tokio runtime")
    })
}

/// An error that maps onto a fixed-width [`CdkStatus`] plus a message.
#[derive(Debug)]
pub(crate) struct FfiErr {
    /// Fixed-width status code.
    pub status: CdkStatus,
    /// Human-readable, non-secret diagnostic.
    pub message: String,
    /// Operation id, when the failure still identifies a send operation.
    pub operation_id: Option<[u8; 16]>,
    /// Sender fee associated with the operation, when known.
    pub sender_fee_msats: u64,
}

impl FfiErr {
    /// Build an error without an operation id.
    pub(crate) fn new(status: CdkStatus, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
            operation_id: None,
            sender_fee_msats: 0,
        }
    }

    /// Build an error that still identifies a send operation.
    pub(crate) fn with_op(
        status: CdkStatus,
        message: impl Into<String>,
        operation_id: [u8; 16],
        sender_fee_msats: u64,
    ) -> Self {
        Self {
            status,
            message: message.into(),
            operation_id: Some(operation_id),
            sender_fee_msats,
        }
    }
}

/// Convenience alias used throughout the crate.
pub(crate) type FfiResult<T> = Result<T, FfiErr>;

/// Per-mint recovery outcome (crate-internal form of `CdkMintRecovery`).
#[derive(Debug, Clone)]
pub(crate) struct MintRecoveryReport {
    /// Mint URL.
    pub mint_url: String,
    /// Sagas recovered for this mint.
    pub recovered: u32,
    /// Sagas compensated (rolled back) for this mint.
    pub compensated: u32,
    /// Sagas skipped (still unresolved) for this mint.
    pub skipped: u32,
    /// Sagas that failed recovery for this mint.
    pub failed: u32,
    /// Status of the recovery call for this mint.
    pub status: CdkStatus,
    /// Non-secret diagnostic, present on skip/failure.
    pub message: Option<String>,
}

/// Sum the per-mint recovery counters into `(recovered, compensated, skipped,
/// failed)` for the aggregate convenience fields of the ABI result structs.
pub(crate) fn aggregate_counts(reports: &[MintRecoveryReport]) -> (u32, u32, u32, u32) {
    reports
        .iter()
        .fold((0u32, 0u32, 0u32, 0u32), |(r, c, s, f), x| {
            (
                r + x.recovered,
                c + x.compensated,
                s + x.skipped,
                f + x.failed,
            )
        })
}

/// The opaque wallet handle exposed to C.
///
/// Created by [`crate::api::cdk_wallet_open`] and destroyed by
/// [`crate::api::cdk_wallet_close`]. It is not thread-safe by itself: the caller
/// must serialize all calls that use the same handle.
///
/// [`Debug`] is redacted: it never prints the seed or the repository internals.
#[derive_ReprC]
#[repr(opaque)]
pub struct CdkWallet {
    /// The multi-mint wallet repository (one [`Wallet`] per approved Msat mint).
    repo: WalletRepository,
    /// The underlying database, retained for mint registration and saga reads.
    db: Arc<WalletSqliteDatabase>,
    #[cfg(not(target_arch = "wasm32"))]
    db_path: PathBuf,
    /// Exclusive advisory lock held for the lifetime of the handle.
    ///
    /// Never read; dropped (releasing the lock) when the handle is freed.
    /// Linux locks the database file with `flock`; macOS uses an
    /// open-file-description byte-range lock outside SQLite's lock bytes.
    _lock: File,
    /// Mints with unresolved recovery state. Mutations against these mints are
    /// rejected with [`CdkStatus::RecoveryPending`] until recovery succeeds.
    unresolved: BTreeSet<MintUrl>,
    prepared_withdrawal: Option<PreparedWithdrawal>,
    /// Set if a Rust panic was caught while servicing a call on this handle.
    ///
    /// A caught panic means the in-memory state may be inconsistent, so the
    /// handle is refused for all further operations except
    /// [`crate::api::cdk_wallet_close`].
    poisoned: Arc<AtomicBool>,
    /// Test-only override for the network deadline (never set in production).
    #[cfg(test)]
    test_network_deadline: Option<Duration>,
    /// Test-only override for the recovery deadline (never set in production).
    #[cfg(test)]
    test_recovery_deadline: Option<Duration>,
}

impl std::fmt::Debug for CdkWallet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CdkWallet")
            .field("unresolved", &self.unresolved.len())
            .field("poisoned", &self.is_poisoned())
            .finish_non_exhaustive()
    }
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct DepositIntent {
    version: u32,
    mint_url: String,
    unit: String,
    payment_method: String,
    amount: u64,
    created_at: u64,
    before_quote_ids: Vec<String>,
    quote_id: Option<String>,
}

struct QuoteHistoryRow {
    time: Option<u64>,
    direction: &'static str,
    mint: String,
    id: String,
    amount: Option<String>,
    unit: String,
    state: String,
    withdrawal: Option<serde_json::Value>,
    expiry: u64,
    expired: bool,
    oversized: bool,
}
impl QuoteHistoryRow {
    fn view(self) -> serde_json::Value {
        if self.oversized {
            return serde_json::json!({"direction":self.direction,"identity":CdkWallet::quote_key(self.direction, &self.mint, &self.id),"error":"Saved quote exceeds display limit; retained in wallet"});
        }
        let mut value = serde_json::json!({"created_at":self.time.map(|n|n.to_string()),"direction":self.direction,
            "mint_url":if self.mint.is_empty(){None}else{Some(self.mint)},"id":self.id,"amount":self.amount,"unit":self.unit,"state":self.state,
            "quote_expiry":self.expiry.to_string(),"expired":self.expired});
        if let Some(w) = self.withdrawal {
            for key in [
                "payment_status",
                "quote_expiry",
                "invoice_expiry",
                "expired",
            ] {
                value[key] = w[key].clone();
            }
        }
        value
    }
}

impl CdkWallet {
    /// Decimal strings are the money boundary on both ABIs; no floats or signs.
    pub(crate) fn deposit_amount(text: &str) -> FfiResult<u64> {
        if text.is_empty() || text.len() > 20 || !text.bytes().all(|c| c.is_ascii_digit()) {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "expected positive decimal msats",
            ));
        }
        let amount = text
            .parse::<u64>()
            .map_err(|_| FfiErr::new(CdkStatus::InvalidArgument, "amount overflow"))?;
        if amount == 0 {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "amount must be positive",
            ));
        }
        ensure_fits_i64(amount, "deposit amount")?;
        Ok(amount)
    }

    fn quote_key(direction: &str, mint: &str, id: &str) -> String {
        // Hash an unambiguous tuple: the CDK KV key alphabet excludes URL and
        // JSON punctuation. The metadata is not a parallel payment ledger.
        let tuple = serde_json::to_vec(&(1, direction, mint, id)).expect("string tuple");
        sha256::Hash::hash(&tuple).to_string()
    }

    async fn deposit_wallet(&self, mint: &MintUrl) -> FfiResult<Wallet> {
        self.guard_prepared_withdrawal(Some(mint))?;
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        if self.unresolved.contains(mint) {
            return Err(FfiErr::new(
                CdkStatus::RecoveryPending,
                "mint recovery is unresolved",
            ));
        }
        self.approved_wallet(mint).await
    }

    fn invoice_view(quote: &cdk_common::wallet::MintQuote) -> serde_json::Value {
        serde_json::json!({"id":quote.id,"mint_url":quote.mint_url.to_string(),"invoice":quote.request,
            "amount":quote.amount.map(|a|a.to_u64().to_string()),"unit":quote.unit.to_string(),"state":quote.state.to_string(),"confirmed":false,"expired":quote_expired(quote, unix_now())})
    }

    fn issuance_confirmed(
        quote: &cdk_common::wallet::MintQuote,
        transactions: &[cdk_common::wallet::Transaction],
    ) -> bool {
        use cdk_common::wallet::{TransactionDirection, TransactionStatus};
        quote.state == MintQuoteState::Issued
            && transactions.iter().any(|t| {
                t.mint_url == quote.mint_url
                    && t.unit == quote.unit
                    && t.quote_id.as_deref() == Some(quote.id.as_str())
                    && t.direction == TransactionDirection::Incoming
                    && t.status == TransactionStatus::Completed
            })
    }

    async fn checked_invoice_view(
        &self,
        quote: &cdk_common::wallet::MintQuote,
    ) -> FfiResult<String> {
        Ok(self.checked_invoice_value(quote).await?.to_string())
    }

    async fn checked_invoice_value(
        &self,
        quote: &cdk_common::wallet::MintQuote,
    ) -> FfiResult<serde_json::Value> {
        let mut value = Self::invoice_view(quote);
        if quote.state == MintQuoteState::Issued {
            // A mint's remote ISSUED response alone is not evidence that local
            // proofs were received. Reuse CDK's completed saga transaction.
            let transactions = self
                .db
                .list_transactions(None, None, None)
                .await
                .map_err(db_error)?;
            value["confirmed"] = Self::issuance_confirmed(quote, &transactions).into();
        }
        Ok(value)
    }

    /// CDK persists the quote before returning. An intent survives ambiguous
    /// creation errors so a caller cannot blindly retry with a second invoice.
    pub(crate) async fn create_deposit(&mut self, mint: &str, text: &str) -> FfiResult<String> {
        let amount = Self::deposit_amount(text)?;
        let mint = parse_mint_url(mint)?;
        let wallet = self.deposit_wallet(&mint).await?;
        let intent = Self::quote_key("In", &mint.to_string(), "creation_intent");
        let (status, recovered) = self.reconcile_deposit(&mint).await?;
        if let Some(quote) = recovered {
            return self.checked_invoice_view(&quote).await;
        }
        if status != "none" {
            return Err(FfiErr::new(
                CdkStatus::RecoveryPending,
                "creation outcome unknown; automatic reconciliation pending; saved invoices remain usable",
            ));
        }
        let info = self
            .db
            .get_mint(mint.clone())
            .await
            .map_err(db_error)?
            .ok_or_else(|| {
                FfiErr::new(
                    CdkStatus::MintRegistrationFailed,
                    "mint settings unavailable",
                )
            })?;
        let settings = info
            .nuts
            .nut04
            .get_settings(&UNIT, &PaymentMethod::BOLT11)
            .ok_or_else(|| FfiErr::new(CdkStatus::InvalidArgument, "BOLT11 msats unavailable"))?;
        if info.nuts.nut04.disabled
            || settings
                .min_amount
                .is_some_and(|a| Amount::from(amount) < a)
            || settings
                .max_amount
                .is_some_and(|a| Amount::from(amount) > a)
        {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "amount outside mint limits",
            ));
        }
        let mut before_quote_ids: Vec<_> = self
            .db
            .get_mint_quotes()
            .await
            .map_err(db_error)?
            .into_iter()
            .filter(|q| q.mint_url == mint)
            .map(|q| q.id)
            .collect();
        before_quote_ids.sort();
        let record = DepositIntent {
            version: 2,
            mint_url: mint.to_string(),
            unit: "msat".into(),
            payment_method: "bolt11".into(),
            amount,
            created_at: cdk::util::unix_time(),
            before_quote_ids,
            quote_id: None,
        };
        self.db
            .kv_write(
                KV_NAMESPACE,
                DEPOSIT_INTENT_NAMESPACE,
                &intent,
                &serde_json::to_vec(&record).map_err(db_error)?,
            )
            .await
            .map_err(db_error)?;
        let result = timeout(
            self.network_deadline(),
            wallet.mint_quote(
                PaymentMethod::BOLT11,
                Some(Amount::from(amount)),
                None,
                None,
            ),
        )
        .await;
        if let Ok(Ok(quote)) = result {
            self.finish_deposit_intent(record, &quote).await;
            return self.checked_invoice_view(&quote).await;
        }
        let (_, recovered) = self.reconcile_deposit(&mint).await?;
        if let Some(quote) = recovered {
            return self.checked_invoice_view(&quote).await;
        }
        if matches!(&result, Ok(Err(error)) if error.is_definitive_failure()) {
            let quotes = self.db.get_mint_quotes().await.map_err(db_error)?;
            if !quotes.iter().any(|q| {
                q.mint_url == mint && record.before_quote_ids.binary_search(&q.id).is_err()
            }) {
                self.db
                    .kv_remove(KV_NAMESPACE, DEPOSIT_INTENT_NAMESPACE, &intent)
                    .await
                    .map_err(db_error)?;
                return Err(FfiErr::new(
                    CdkStatus::InvalidArgument,
                    "mint definitively rejected quote; creation may be retried",
                ));
            }
        }
        Err(FfiErr::new(
            CdkStatus::RecoveryPending,
            "creation outcome unknown; automatic reconciliation never creates another invoice",
        ))
    }

    async fn finish_deposit_intent(
        &self,
        mut record: DepositIntent,
        quote: &cdk_common::wallet::MintQuote,
    ) -> bool {
        let key = Self::quote_key("In", &record.mint_url, "creation_intent");
        record.quote_id = Some(quote.id.clone());
        if let Ok(bytes) = serde_json::to_vec(&record) {
            let _ = self
                .db
                .kv_write(KV_NAMESPACE, DEPOSIT_INTENT_NAMESPACE, &key, &bytes)
                .await;
        }
        let time_key = Self::quote_key("In", &record.mint_url, &quote.id);
        if matches!(
            self.db
                .kv_read(KV_NAMESPACE, "quote_created_v1", &time_key)
                .await,
            Ok(None)
        ) {
            // Optional metadata must never hide/lock an already durable invoice.
            let _ = self
                .db
                .kv_write(
                    KV_NAMESPACE,
                    "quote_created_v1",
                    &time_key,
                    &record.created_at.to_le_bytes(),
                )
                .await;
        }
        self.db
            .kv_remove(KV_NAMESPACE, DEPOSIT_INTENT_NAMESPACE, &key)
            .await
            .is_ok()
    }

    async fn reconcile_deposit(
        &self,
        mint: &MintUrl,
    ) -> FfiResult<(&'static str, Option<cdk_common::wallet::MintQuote>)> {
        // Local intent/timestamp cleanup never resumes CDK sagas or touches
        // proofs. Prepared-review guards belong at actual wallet mutations.
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        let key = Self::quote_key("In", &mint.to_string(), "creation_intent");
        let Some(bytes) = self
            .db
            .kv_read(KV_NAMESPACE, DEPOSIT_INTENT_NAMESPACE, &key)
            .await
            .map_err(db_error)?
        else {
            return Ok(("none", None));
        };
        if bytes == b"pending" {
            return Ok(("legacy_unknown", None));
        }
        let Ok(record) = serde_json::from_slice::<DepositIntent>(&bytes) else {
            return Ok(("unknown", None));
        };
        if record.version != 2
            || record.mint_url != mint.to_string()
            || record.unit != "msat"
            || record.payment_method != "bolt11"
            || record.amount == 0
            || record.amount > i64::MAX as u64
            || record.before_quote_ids.windows(2).any(|w| w[0] >= w[1])
            || record
                .quote_id
                .as_ref()
                .is_some_and(|id| record.before_quote_ids.binary_search(id).is_ok())
        {
            return Ok(("unknown", None));
        }
        let quotes = self.db.get_mint_quotes().await.map_err(db_error)?;
        let candidates: Vec<_> = quotes
            .into_iter()
            .filter(|q| {
                q.mint_url == *mint
                    && match &record.quote_id {
                        Some(id) => &q.id == id,
                        None => record.before_quote_ids.binary_search(&q.id).is_err(),
                    }
            })
            .collect();
        if candidates.len() != 1 {
            return Ok(("unknown", None));
        }
        let quote = candidates.into_iter().next().unwrap();
        if quote.unit != UNIT
            || quote.payment_method != PaymentMethod::BOLT11
            || quote.amount != Some(Amount::from(record.amount))
        {
            return Ok(("unknown", None));
        }
        let cleared = self.finish_deposit_intent(record, &quote).await;
        Ok((if cleared { "none" } else { "unknown" }, Some(quote)))
    }

    pub(crate) async fn recover_deposit(&self, mint: &str) -> FfiResult<String> {
        let (status, quote) = self.reconcile_deposit(&parse_mint_url(mint)?).await?;
        if quote.as_ref().is_some_and(|q| {
            q.id.len() > 1024
                || q.id.contains('\0')
                || q.request.len() > 4096
                || q.request.contains('\0')
        }) {
            return Ok(serde_json::json!({"creation_recovery":status,"invoice":null,"error":"Recovered invoice exceeds display limit; retained in wallet"}).to_string());
        }
        let invoice = match quote {
            Some(q) => Some(self.checked_invoice_value(&q).await?),
            None => None,
        };
        Ok(serde_json::json!({"creation_recovery":status,"invoice":invoice}).to_string())
    }

    // ponytail: small operator-funded batches; no separate prize inventory.
    const MAX_PRIZE_STOCK: u64 = 20;
    const MAX_PRIZE_MSAT: u64 = 100_000;
    const MAX_PROOFS_PER_PRIZE: usize = 6;

    async fn prize_stock_split(
        &self,
        wallet: &Wallet,
        amount: u64,
        prize: u64,
    ) -> FfiResult<SplitTarget> {
        // Bound the denomination split even if the mint only offers 1-msat proofs.
        if prize == 0
            || prize > Self::MAX_PRIZE_MSAT
            || amount == 0
            || amount % prize != 0
            || amount / prize > Self::MAX_PRIZE_STOCK
        {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "expected a batch of 1 to 20 whole prizes (up to 100000 msat each)",
            ));
        }
        let proof_mix = timeout(self.network_deadline(), async {
            let keyset = wallet.active_keyset().await?;
            let amounts = wallet.get_keyset_fees_and_amounts_by_id(keyset.id).await?;
            Amount::from(prize).split(&amounts).map_err(CdkError::from)
        })
        .await;
        match proof_mix {
            Ok(Ok(mix)) if mix.len() <= Self::MAX_PROOFS_PER_PRIZE => {
                Ok(SplitTarget::Values(mix.repeat((amount / prize) as usize)))
            }
            Ok(Ok(_)) => Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "mint needs more than six proofs per prize",
            )),
            Ok(Err(err)) => Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                format!("cannot split prize using the active keyset: {err}"),
            )),
            Err(_) => Err(FfiErr::new(
                CdkStatus::NetworkError,
                "prize keyset lookup timed out",
            )),
        }
    }

    pub(crate) async fn create_prize_stock(
        &mut self,
        mint: &str,
        count: &str,
        prize: &str,
    ) -> FfiResult<String> {
        let count = Self::deposit_amount(count)?;
        let prize = Self::deposit_amount(prize)?;
        let amount = count.checked_mul(prize).ok_or_else(|| {
            FfiErr::new(CdkStatus::InvalidArgument, "prize batch amount overflows")
        })?;
        let wallet = self.deposit_wallet(&parse_mint_url(mint)?).await?;
        self.prize_stock_split(&wallet, amount, prize).await?;
        self.create_deposit(mint, &amount.to_string()).await
    }

    pub(crate) async fn claim_prize_stock(
        &mut self,
        mint: &str,
        id: &str,
        prize: &str,
    ) -> FfiResult<String> {
        if id.is_empty() || id.len() > 1024 || id.contains('\0') {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "invalid saved quote id",
            ));
        }
        self.check_deposit_inner(
            mint,
            id,
            true,
            &mut false,
            Some(Self::deposit_amount(prize)?),
        )
        .await
    }

    /// One bounded check, then actual issuance. Never equate Paid with Issued.
    pub(crate) async fn check_deposit(&mut self, mint: &str, id: &str) -> FfiResult<String> {
        self.check_deposit_inner(mint, id, true, &mut false, None)
            .await
    }

    async fn check_deposit_inner(
        &mut self,
        mint: &str,
        id: &str,
        recover: bool,
        changed: &mut bool,
        prize: Option<u64>,
    ) -> FfiResult<String> {
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        let mint = parse_mint_url(mint)?;
        self.guard_prepared_withdrawal(Some(&mint))?;
        let saved = self
            .db
            .get_mint_quote(id)
            .await
            .map_err(db_error)?
            .ok_or_else(|| FfiErr::new(CdkStatus::InvalidArgument, "saved quote not found"))?;
        if saved.mint_url != mint
            || saved.unit != UNIT
            || saved.payment_method != PaymentMethod::BOLT11
        {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "quote identity mismatch",
            ));
        }
        if quote_expired(&saved, unix_now()) {
            return self.checked_invoice_view(&saved).await;
        }
        let _ = self.reconcile_deposit(&mint).await?;
        if recover && self.unresolved.contains(&mint) {
            self.run_recovery(Some(&mint)).await?;
        }
        let wallet = self.deposit_wallet(&mint).await?;
        if saved.state == MintQuoteState::Issued {
            return self.checked_invoice_view(&saved).await;
        }
        if saved.used_by_operation.is_some() {
            // CDK's status check can itself resume this quote's mint saga.
            // Even a later read failure must retain the invalidation hint.
            *changed = true;
        }
        let original_state = saved.state;
        let quote = match timeout(self.network_deadline(), wallet.check_mint_quote_status(id)).await
        {
            Ok(Ok(quote)) => quote,
            _ => {
                *changed = true;
                // CDK may resume an interrupted mint saga while checking. A
                // failed check must not leave new mutations enabled blindly.
                self.unresolved.insert(mint.clone());
                return Err(FfiErr::new(
                    CdkStatus::NetworkError,
                    "quote check failed or timed out; saved work retained",
                ));
            }
        };
        // CDK has already persisted this returned quote. Keep its state-change
        // invalidation even if a subsequent local read fails. This is not local
        // issuance confirmation; the invoice still checks CDK's transaction.
        *changed |= quote.state != original_state;
        if quote.state == MintQuoteState::Paid {
            let split = match prize {
                Some(prize) => {
                    let amount = quote.amount.ok_or_else(|| {
                        FfiErr::new(
                            CdkStatus::InvalidArgument,
                            "prize funding quote has no amount",
                        )
                    })?;
                    self.prize_stock_split(&wallet, amount.to_u64(), prize)
                        .await?
                }
                None => SplitTarget::default(),
            };
            *changed = true;
            match timeout(self.network_deadline(), wallet.mint(id, split, None)).await {
                Ok(Ok(_)) => {}
                _ => {
                    self.unresolved.insert(mint);
                    return Err(FfiErr::new(
                        CdkStatus::RecoveryPending,
                        "minting interrupted; recover this saved quote",
                    ));
                }
            }
        }
        let saved = self
            .db
            .get_mint_quote(id)
            .await
            .map_err(db_error)?
            .ok_or_else(|| FfiErr::new(CdkStatus::DatabaseError, "saved quote missing"))?;
        *changed |= saved.state != original_state;
        self.checked_invoice_view(&saved).await
    }

    /// Local-only quote history. Unknown creation times remain unknown forever;
    /// neither expiry nor updated_at is a creation timestamp.
    pub(crate) async fn quote_history(&self) -> FfiResult<String> {
        Ok(serde_json::Value::Array(
            self.history_rows()
                .await?
                .into_iter()
                .map(QuoteHistoryRow::view)
                .collect(),
        )
        .to_string())
    }

    async fn history_rows(&self) -> FfiResult<Vec<QuoteHistoryRow>> {
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        let (mint_quotes, melt_quotes, metadata, sagas, transactions) =
            self.quote_history_data().await?;
        let withdrawal_lookup = withdrawal::WithdrawalLookup::new(&sagas, &transactions);
        let created = |direction, mint: &str, id: &str| {
            metadata
                .get(&Self::quote_key(direction, mint, id))
                .and_then(|b| <[u8; 8]>::try_from(b.as_slice()).ok())
                .map(u64::from_le_bytes)
        };
        let mut rows = Vec::new();
        for q in mint_quotes {
            let mint = q.mint_url.to_string();
            let expired = quote_expired(&q, unix_now());
            rows.push(QuoteHistoryRow {
                withdrawal: None,
                oversized: q.request.len() > 4096,
                expiry: q.expiry,
                expired,
                time: created("In", &mint, &q.id),
                direction: "In",
                mint,
                id: q.id,
                amount: q.amount.map(|a| a.to_u64().to_string()),
                unit: q.unit.to_string(),
                state: q.state.to_string(),
            });
        }
        for q in melt_quotes {
            let withdrawal = Self::project_withdrawal(&q, &withdrawal_lookup, unix_now());
            let mint = q.mint_url.map(|m| m.to_string()).unwrap_or_default();
            rows.push(QuoteHistoryRow {
                withdrawal: Some(withdrawal),
                oversized: q.request.len() > 4096,
                expiry: q.expiry,
                expired: false,
                time: created("Out", &mint, &q.id),
                direction: "Out",
                mint,
                id: q.id,
                amount: Some(q.amount.to_u64().to_string()),
                unit: q.unit.to_string(),
                state: q.state.to_string(),
            });
        }
        rows.sort_by(|a, b| {
            b.time
                .cmp(&a.time)
                .then_with(|| (&a.direction, &a.mint, &a.id).cmp(&(&b.direction, &b.mint, &b.id)))
        });
        Ok(rows)
    }

    pub(crate) fn history_offset(text: &str) -> FfiResult<u32> {
        if text.is_empty() || text.len() > 10 || !text.bytes().all(|b| b.is_ascii_digit()) {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "invalid history offset",
            ));
        }
        let offset = text
            .parse::<u32>()
            .map_err(|_| FfiErr::new(CdkStatus::InvalidArgument, "history offset overflow"))?;
        if offset % 8 != 0 {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "history offset must be aligned to eight",
            ));
        }
        Ok(offset)
    }

    pub(crate) async fn quote_history_page(&self, offset: &str) -> FfiResult<String> {
        let requested = Self::history_offset(offset)? as usize;
        let rows = self.history_rows().await?;
        let total = rows.len();
        let offset = if total == 0 {
            0
        } else {
            requested.min((total - 1) / 8 * 8)
        };
        let rows: Vec<_> = rows
            .into_iter()
            .skip(offset)
            .take(8)
            .map(|row| {
                let identity = Self::quote_key(row.direction, &row.mint, &row.id);
                let direction = row.direction;
                let invalid_id = row.id.len() > 1024 || row.id.contains('\0');
                let value = row.view();
                if invalid_id || value.to_string().len() > 14 * 1024 {
                    serde_json::json!({"direction":direction,"identity":identity,"error":"Saved quote exceeds display limit; retained in wallet"})
                } else {
                    value
                }
            })
            .collect();
        Ok(serde_json::json!({"offset":offset.to_string(),"total":total.to_string(),"limit":8,"rows":rows}).to_string())
    }

    /// Saved invoices for resume; separate from history so it never leaks invoice
    /// data into history callbacks.
    pub(crate) async fn unfinished_deposits(&self, mint: &str) -> FfiResult<String> {
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        let mint = parse_mint_url(mint)?;
        let mut quotes = self.db.get_mint_quotes().await.map_err(db_error)?;
        let transactions = self
            .db
            .list_transactions(None, None, None)
            .await
            .map_err(db_error)?;
        let completed = Self::completed_quotes(transactions);
        quotes.retain(|q| {
            q.mint_url == mint
                && q.unit == UNIT
                && q.payment_method == PaymentMethod::BOLT11
                && !(q.state == MintQuoteState::Issued
                    && completed.contains(&(
                        q.mint_url.to_string(),
                        q.unit.to_string(),
                        q.id.clone(),
                    )))
        });
        quotes.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(serde_json::Value::Array(quotes.iter().map(Self::invoice_view).collect()).to_string())
    }

    fn completed_quotes(
        transactions: Vec<cdk_common::wallet::Transaction>,
    ) -> BTreeSet<(String, String, String)> {
        use cdk_common::wallet::{TransactionDirection, TransactionStatus};
        transactions
            .into_iter()
            .filter(|t| {
                t.direction == TransactionDirection::Incoming
                    && t.status == TransactionStatus::Completed
            })
            .filter_map(|t| {
                t.quote_id
                    .map(|id| (t.mint_url.to_string(), t.unit.to_string(), id))
            })
            .collect()
    }

    async fn quote_history_data(
        &self,
    ) -> FfiResult<(
        Vec<cdk_common::wallet::MintQuote>,
        Vec<cdk_common::wallet::MeltQuote>,
        HashMap<String, Vec<u8>>,
        Vec<cdk_common::wallet::WalletSaga>,
        Vec<cdk_common::wallet::Transaction>,
    )> {
        #[cfg(target_arch = "wasm32")]
        {
            self.db.quote_history_data().await.map_err(db_error)
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            let mut metadata = HashMap::new();
            for key in self
                .db
                .kv_list(KV_NAMESPACE, "quote_created_v1")
                .await
                .map_err(db_error)?
            {
                if let Some(value) = self
                    .db
                    .kv_read(KV_NAMESPACE, "quote_created_v1", &key)
                    .await
                    .map_err(db_error)?
                {
                    metadata.insert(key, value);
                }
            }
            Ok((
                self.db.get_mint_quotes().await.map_err(db_error)?,
                self.db.get_melt_quotes().await.map_err(db_error)?,
                metadata,
                self.db.get_incomplete_sagas().await.map_err(db_error)?,
                self.db
                    .list_transactions(None, None, None)
                    .await
                    .map_err(db_error)?,
            ))
        }
    }

    async fn eligible_deposits(
        &self,
        mint: &MintUrl,
        mut quotes: Vec<cdk_common::wallet::MintQuote>,
    ) -> FfiResult<Vec<cdk_common::wallet::MintQuote>> {
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        let completed = Self::completed_quotes(
            self.db
                .list_transactions(None, None, None)
                .await
                .map_err(db_error)?,
        );
        quotes.retain(|q| {
            &q.mint_url == mint
                && q.unit == UNIT
                && q.payment_method == PaymentMethod::BOLT11
                && !quote_expired(q, unix_now())
                && !(q.state == MintQuoteState::Issued
                    && completed.contains(&(
                        q.mint_url.to_string(),
                        q.unit.to_string(),
                        q.id.clone(),
                    )))
        });
        Ok(quotes)
    }

    pub(crate) async fn resume_deposit(&self, mint: &str) -> FfiResult<String> {
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        let mint = parse_mint_url(mint)?;
        let (quotes, _, metadata, _, _) = self.quote_history_data().await?;
        let mut quotes = self.eligible_deposits(&mint, quotes).await?;
        let created = |q: &cdk_common::wallet::MintQuote| {
            metadata
                .get(&Self::quote_key("In", &mint.to_string(), &q.id))
                .and_then(|b| <[u8; 8]>::try_from(b.as_slice()).ok())
                .map(u64::from_le_bytes)
                .unwrap_or(0)
        };
        quotes.sort_by(|a, b| created(b).cmp(&created(a)).then_with(|| b.id.cmp(&a.id)));
        let Some(quote) = quotes.first() else {
            return Ok(serde_json::json!({"invoice":null}).to_string());
        };
        if quote.id.len() > 1024
            || quote.id.contains('\0')
            || quote.request.len() > 4096
            || quote.request.contains('\0')
        {
            return Ok(serde_json::json!({"invoice":null,"error":"Saved invoice exceeds display limit; retained in wallet"}).to_string());
        }
        Ok(serde_json::json!({"invoice": Self::invoice_view(quote)}).to_string())
    }

    pub(crate) async fn poll_deposits(&mut self, mint: &str, after_id: &str) -> FfiResult<String> {
        self.poll_deposits_inner(mint, after_id, true, &mut false)
            .await
    }

    async fn poll_deposits_inner(
        &mut self,
        mint: &str,
        after_id: &str,
        recover: bool,
        changed: &mut bool,
    ) -> FfiResult<String> {
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        if after_id.len() > 1024 || after_id.contains('\0') {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "invalid poll cursor",
            ));
        }
        let mint = parse_mint_url(mint)?;
        self.guard_prepared_withdrawal(Some(&mint))?;
        let quotes = self.db.get_mint_quotes().await.map_err(db_error)?;
        let mut quotes = self.eligible_deposits(&mint, quotes).await?;
        quotes.sort_by(|a, b| a.id.cmp(&b.id));
        let cursor = |q: &cdk_common::wallet::MintQuote| {
            if q.id.len() > 1024 || q.id.contains('\0') || q.id.starts_with("cursor-v1:") {
                format!(
                    "cursor-v1:{}",
                    Self::quote_key("In", &mint.to_string(), &q.id)
                )
            } else {
                q.id.clone()
            }
        };
        let index = if after_id.is_empty() {
            0
        } else {
            // Resolve opaque oversized-id cursors, otherwise seek strictly after id.
            if after_id.starts_with("cursor-v1:") {
                quotes
                    .iter()
                    .position(|q| cursor(q) == after_id)
                    .map(|i| i + 1)
                    .unwrap_or(0)
            } else {
                quotes.partition_point(|q| q.id.as_str() <= after_id)
            }
        };
        let Some(quote) = quotes.get(if index >= quotes.len() { 0 } else { index }) else {
            return Ok(serde_json::json!({"invoice":null,"cursor":null}).to_string());
        };
        if quote.id.len() > 1024
            || quote.id.contains('\0')
            || quote.request.len() > 4096
            || quote.request.contains('\0')
        {
            // Check even oversized saved quotes, but never put them on the wire.
            let _ = self
                .check_deposit_inner(&mint.to_string(), &quote.id, recover, changed, None)
                .await;
            return Ok(serde_json::json!({"invoice":null,"cursor":cursor(quote),"error":"Saved invoice exceeds display limit; retained in wallet"}).to_string());
        }
        let mut reply = serde_json::json!({"invoice":null,"cursor":cursor(quote)});
        match self
            .check_deposit_inner(&mint.to_string(), &quote.id, recover, changed, None)
            .await
        {
            Ok(raw) => {
                reply["invoice"] = serde_json::from_str(&raw)
                    .map_err(|_| FfiErr::new(CdkStatus::DatabaseError, "invalid invoice view"))?
            }
            Err(error) => reply["error"] = serde_json::json!(error.message),
        }
        Ok(reply.to_string())
    }

    /// Exact local CDK quote lookup. Never performs recovery or a mint request.
    pub(crate) async fn saved_invoice(&self, mint: &str, id: &str) -> FfiResult<String> {
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        let mint = parse_mint_url(mint)?;
        if id.is_empty() || id.len() > 1024 || id.contains('\0') {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "invalid saved quote id",
            ));
        }
        let quote = self
            .db
            .get_mint_quote(id)
            .await
            .map_err(db_error)?
            .ok_or_else(|| FfiErr::new(CdkStatus::InvalidArgument, "saved quote not found"))?;
        if quote.mint_url != mint
            || quote.unit != UNIT
            || quote.payment_method != PaymentMethod::BOLT11
        {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "quote identity mismatch",
            ));
        }
        if quote.request.len() > 4096 || quote.request.contains('\0') {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "saved invoice exceeds display limit",
            ));
        }
        self.checked_invoice_view(&quote).await
    }

    /// Application envelope: recovery metadata survives later quote/read errors.
    pub(crate) async fn deposit_update(
        &mut self,
        mint: &str,
        kind: &str,
        argument: &str,
    ) -> FfiResult<String> {
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        let selected = parse_mint_url(mint)?;
        self.guard_prepared_withdrawal(Some(&selected))?;
        if !matches!(kind, "check" | "poll" | "recover")
            || argument.len() > 1024
            || argument.contains('\0')
            || (kind == "check" && argument.is_empty())
            || (kind == "recover" && !argument.is_empty())
        {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "invalid deposit update arguments",
            ));
        }
        let mut changed = false;
        let mut operational_error = None;
        if self.unresolved.contains(&selected) {
            match self.run_recovery(Some(&selected)).await {
                Ok(reports) => {
                    changed = reports.iter().any(|r| {
                        r.recovered > 0
                            || r.compensated > 0
                            || r.failed > 0
                            || r.skipped > 0
                            || r.status != CdkStatus::Ok
                    })
                }
                Err(e) => {
                    changed = true;
                    operational_error = Some(e);
                }
            }
        }
        let mut reply = serde_json::json!({"wallet_changed":false,"recovery_pending":false,"creation_recovery":"unknown","invoice":null,"cursor":null,"error":null});
        let mut recovered_quote = None;
        match self.reconcile_deposit(&selected).await {
            Ok((status, quote)) => {
                reply["creation_recovery"] = serde_json::json!(status);
                recovered_quote = quote;
            }
            Err(e) => operational_error = Some(e),
        }
        let result = if self.unresolved.contains(&selected) {
            Err(FfiErr::new(
                CdkStatus::RecoveryPending,
                "selected mint recovery remains pending",
            ))
        } else if operational_error.is_some() {
            Ok(None)
        } else {
            match kind {
                "check" => self
                    .check_deposit_inner(mint, argument, false, &mut changed, None)
                    .await
                    .map(Some),
                "poll" => self
                    .poll_deposits_inner(mint, argument, false, &mut changed)
                    .await
                    .map(Some),
                _ => match recovered_quote {
                    Some(q)
                        if q.id.len() > 1024
                            || q.id.contains('\0')
                            || q.request.len() > 4096
                            || q.request.contains('\0') =>
                    {
                        Err(FfiErr::new(
                            CdkStatus::InvalidArgument,
                            "recovered invoice exceeds display limit",
                        ))
                    }
                    Some(q) => self
                        .checked_invoice_value(&q)
                        .await
                        .map(|invoice| Some(serde_json::json!({"invoice":invoice}).to_string())),
                    None => Ok(None),
                },
            }
        };
        match result {
            Ok(Some(raw)) => match serde_json::from_str::<serde_json::Value>(&raw) {
                Ok(value) => {
                    if kind == "check" {
                        reply["invoice"] = value;
                    } else {
                        reply["invoice"] = value["invoice"].clone();
                        reply["cursor"] = value["cursor"].clone();
                        if !value["error"].is_null() {
                            operational_error = Some(FfiErr::new(
                                CdkStatus::NetworkError,
                                "saved deposit update unavailable; retained in wallet",
                            ));
                        }
                    }
                }
                Err(_) => {
                    operational_error = Some(FfiErr::new(
                        CdkStatus::DatabaseError,
                        "invalid local invoice view",
                    ))
                }
            },
            Ok(None) => {}
            Err(e) => operational_error = Some(e),
        }
        if !reply["invoice"].is_null() {
            let id = reply["invoice"]["id"].as_str();
            let request = reply["invoice"]["invoice"].as_str();
            if id.is_none_or(|s| s.is_empty() || s.len() > 1024 || s.contains('\0'))
                || request.is_none_or(|s| s.is_empty() || s.len() > 4096 || s.contains('\0'))
            {
                reply["invoice"] = serde_json::Value::Null;
                operational_error = Some(FfiErr::new(
                    CdkStatus::InvalidArgument,
                    "saved invoice exceeds display limit",
                ));
            }
        }
        reply["wallet_changed"] = serde_json::json!(changed);
        reply["recovery_pending"] = serde_json::json!(self.unresolved.contains(&selected));
        if let Some(e) = operational_error {
            // Deliberately static: never reflect unbounded mint diagnostics.
            reply["error"] = serde_json::json!({"status":e.status as i32,"message":"Deposit update failed; saved wallet work retained"});
        }
        Ok(reply.to_string())
    }

    /// Small selected balance and local creation-recovery status. No history or
    /// invoice enumeration unless an outstanding intent needs reconciliation.
    pub(crate) async fn wallet_screen(&self, mint: &str) -> FfiResult<String> {
        let mint = parse_mint_url(mint)?;
        let (status, _) = self.reconcile_deposit(&mint).await?;
        let msats = if self.repo.has_wallet(&mint, &UNIT).await {
            self.approved_wallet(&mint)
                .await?
                .total_balance()
                .await
                .map_err(db_error)?
                .to_u64()
        } else {
            0
        };
        Ok(serde_json::json!({"mint_url":mint.to_string(),"msats":msats.to_string(),"creation_recovery":status,"recovery_pending":self.unresolved.contains(&mint)}).to_string())
    }

    /// Share this handle's poison flag with an FFI guard.
    pub(crate) fn poison_flag(&self) -> Arc<AtomicBool> {
        self.poisoned.clone()
    }
    /// True once a panic has been caught while servicing this handle.
    pub(crate) fn is_poisoned(&self) -> bool {
        self.poisoned.load(Ordering::SeqCst)
    }

    /// Flush any pending rate-limiter state before the handle is dropped.
    pub(crate) async fn flush_rate_limits(&self) {
        self.repo.flush_rate_limits().await;
    }

    /// Effective network deadline for this handle.
    fn network_deadline(&self) -> Duration {
        #[cfg(test)]
        if let Some(deadline) = self.test_network_deadline {
            return deadline;
        }
        NETWORK_DEADLINE
    }

    /// Effective recovery deadline for this handle.
    fn recovery_deadline(&self) -> Duration {
        #[cfg(test)]
        if let Some(deadline) = self.test_recovery_deadline {
            return deadline;
        }
        RECOVERY_DEADLINE
    }
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod deposit_tests {
    use super::*;
    use crate::e2e::{start_fake_mint, start_fake_mint_ctl, SwapFault};
    use serde_json::Value;

    #[test]
    fn application_check_and_poll_invalidate_actual_remote_issued_state_without_claiming_local_issuance(
    ) {
        runtime().block_on(async {
            for kind in ["check", "poll"] {
                let (mint, server) = start_fake_mint_ctl(0, SwapFault::None).await;
                let dir = tempfile::tempdir().unwrap();
                let (mut h, _) =
                    CdkWallet::open(&[77; 64], dir.path().join("local.sqlite").to_str().unwrap())
                        .await
                        .unwrap();
                let (mut issuer, _) = CdkWallet::open(
                    &[78; 64],
                    dir.path().join("issuer.sqlite").to_str().unwrap(),
                )
                .await
                .unwrap();
                h.add_mint(&mint).await.unwrap();
                issuer.add_mint(&mint).await.unwrap();
                let created: Value =
                    serde_json::from_str(&h.create_deposit(&mint, "21").await.unwrap()).unwrap();
                let id = created["id"].as_str().unwrap();
                let saved = h.db.get_mint_quote(id).await.unwrap().unwrap();
                assert_eq!(saved.state, MintQuoteState::Unpaid);
                // Issue the real mint's quote through a separate CDK wallet.
                // The selected wallet retains its Unpaid quote and no proofs
                // or completed transaction, so remote Issued is unconfirmed.
                issuer.db.add_mint_quote(saved).await.unwrap();
                let deadline = std::time::Instant::now() + Duration::from_secs(15);
                loop {
                    let issued: Value =
                        serde_json::from_str(&issuer.check_deposit(&mint, id).await.unwrap())
                            .unwrap();
                    if issued["confirmed"] == true {
                        break;
                    }
                    assert!(std::time::Instant::now() < deadline);
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
                assert_eq!(
                    h.db.get_mint_quote(id).await.unwrap().unwrap().state,
                    MintQuoteState::Unpaid
                );
                let update: Value = serde_json::from_str(
                    &h.deposit_update(&mint, kind, if kind == "check" { id } else { "" })
                        .await
                        .unwrap(),
                )
                .unwrap();
                assert_eq!(update["wallet_changed"], true, "{kind}: {update}");
                assert_eq!(update["invoice"]["state"], "ISSUED");
                assert_eq!(update["invoice"]["confirmed"], false);
                assert!(update["error"].is_null());
                let screen: Value =
                    serde_json::from_str(&h.wallet_screen(&mint).await.unwrap()).unwrap();
                assert_eq!(screen["msats"], "0");
                let history: Value =
                    serde_json::from_str(&h.quote_history().await.unwrap()).unwrap();
                assert_eq!(history[0]["state"], "ISSUED");
                assert!(h
                    .db
                    .list_transactions(None, None, None)
                    .await
                    .unwrap()
                    .is_empty());
                let unchanged: Value = serde_json::from_str(
                    &h.deposit_update(&mint, kind, if kind == "check" { id } else { "" })
                        .await
                        .unwrap(),
                )
                .unwrap();
                assert_eq!(unchanged["wallet_changed"], false);
                server.abort();
            }
        });
    }

    #[test]
    fn application_unchanged_unpaid_has_no_refresh_and_saved_lookup_is_local_and_exact() {
        runtime().block_on(async {
            let (mint, server, posts) =
                crate::e2e::start_fake_mint_counted(0, SwapFault::UnpaidQuotes).await;
            let dir = tempfile::tempdir().unwrap();
            let (mut h, _) = CdkWallet::open(
                &[76; 64],
                dir.path().join("wallet.sqlite").to_str().unwrap(),
            )
            .await
            .unwrap();
            h.add_mint(&mint).await.unwrap();
            let a: Value =
                serde_json::from_str(&h.create_deposit(&mint, "21").await.unwrap()).unwrap();
            let id = a["id"].as_str().unwrap();
            for _ in 0..3 {
                let update: Value =
                    serde_json::from_str(&h.deposit_update(&mint, "check", id).await.unwrap())
                        .unwrap();
                assert_eq!(update["wallet_changed"], false, "{update}");
                assert_eq!(update["invoice"]["state"], "UNPAID");
                assert!(update["error"].is_null());
            }
            assert_eq!(posts.load(Ordering::SeqCst), 1);
            server.abort();
            // With the server gone, exact saved reads and unsupported identity
            // rejections still succeed locally, including bounded input checks.
            let saved: Value =
                serde_json::from_str(&h.saved_invoice(&mint, id).await.unwrap()).unwrap();
            assert_eq!(saved["id"], id);
            assert_eq!(saved["confirmed"], false);
            for case in ["unit", "method", "mint", "request"] {
                let mut q = quote(case, &parse_mint_url(&mint).unwrap());
                match case {
                    "unit" => q.unit = CurrencyUnit::Sat,
                    "method" => q.payment_method = PaymentMethod::BOLT12,
                    "mint" => q.mint_url = parse_mint_url("http://127.0.0.1:9").unwrap(),
                    _ => {
                        q.request = "x".repeat(4097);
                        q.expiry = unix_now() - 1;
                    }
                }
                h.db.add_mint_quote(q).await.unwrap();
                assert_eq!(
                    h.saved_invoice(&mint, case).await.unwrap_err().status,
                    CdkStatus::InvalidArgument
                );
            }
            let oversized = h.deposit_update(&mint, "check", "request").await.unwrap();
            assert!(oversized.len() < 1024);
            let oversized: Value = serde_json::from_str(&oversized).unwrap();
            assert!(oversized["invoice"].is_null() && oversized["error"].is_object());
            for bad in ["".to_string(), "x".repeat(1025), "bad\0id".to_string()] {
                assert_eq!(
                    h.saved_invoice(&mint, &bad).await.unwrap_err().status,
                    CdkStatus::InvalidArgument
                );
            }
            let selected = parse_mint_url(&mint).unwrap();
            h.unresolved.insert(selected.clone());
            for (kind, arg) in [("invalid", ""), ("recover", "nonempty"), ("check", "")] {
                assert_eq!(
                    h.deposit_update(&mint, kind, arg).await.unwrap_err().status,
                    CdkStatus::InvalidArgument
                );
                assert!(
                    h.unresolved.contains(&selected),
                    "invalid requests must not recover or mutate"
                );
            }
        });
    }

    #[test]
    fn application_recovery_precedes_empty_and_expired_poll_without_replacement_posts() {
        runtime().block_on(async {
            for kind in ["poll", "recover"] {
                let fail_get = Arc::new(AtomicBool::new(true));
                let gets = Arc::new(std::sync::atomic::AtomicUsize::new(0));
                let fault = SwapFault::DepositControl {
                    fail_get: fail_get.clone(),
                    fail_mint: Arc::new(AtomicBool::new(false)),
                    hold_unpaid: Arc::new(AtomicBool::new(false)),
                    gets: gets.clone(),
                    interrupt_mint: false,
                };
                let (mint, server, posts) = crate::e2e::start_fake_mint_counted(0, fault).await;
                let dir = tempfile::tempdir().unwrap();
                let (mut h, _) = CdkWallet::open(
                    &[74; 64],
                    dir.path().join("wallet.sqlite").to_str().unwrap(),
                )
                .await
                .unwrap();
                h.add_mint(&mint).await.unwrap();
                let invoice: Value =
                    serde_json::from_str(&h.create_deposit(&mint, "21").await.unwrap()).unwrap();
                let id = invoice["id"].as_str().unwrap();
                assert!(h.check_deposit(&mint, id).await.is_err());
                assert!(h.unresolved.contains(&parse_mint_url(&mint).unwrap()));
                assert_eq!(
                    h.create_deposit(&mint, "22").await.unwrap_err().status,
                    CdkStatus::RecoveryPending
                );
                let mut saved = h.db.get_mint_quote(id).await.unwrap().unwrap();
                saved.expiry = unix_now() - 1;
                saved.state = MintQuoteState::Unpaid;
                h.db.add_mint_quote(saved).await.unwrap();
                let before = gets.load(Ordering::SeqCst);
                let update: Value =
                    serde_json::from_str(&h.deposit_update(&mint, kind, "").await.unwrap())
                        .unwrap();
                assert_eq!(update["recovery_pending"], false);
                assert!(update["invoice"].is_null());
                assert!(update["cursor"].is_null());
                assert_eq!(
                    gets.load(Ordering::SeqCst),
                    before,
                    "expired unpaid quote must never be checked"
                );
                assert_eq!(
                    posts.load(Ordering::SeqCst),
                    1,
                    "recovery must not create a replacement"
                );
                h.create_deposit(&mint, "22").await.unwrap();
                assert_eq!(posts.load(Ordering::SeqCst), 2);
                server.abort();
            }
        });
    }

    #[test]
    fn application_hint_survives_recovery_then_other_quote_error_or_empty_poll() {
        runtime().block_on(async {
            for outcome in ["error", "empty", "oversized", "pending", "unchanged"] {
                let fail_get = Arc::new(AtomicBool::new(false));
                let gets = Arc::new(std::sync::atomic::AtomicUsize::new(0));
                let fail_mint = Arc::new(AtomicBool::new(false));
                let hold_unpaid = Arc::new(AtomicBool::new(false));
                let fault = SwapFault::DepositControl {
                    fail_get: fail_get.clone(),
                    fail_mint: fail_mint.clone(),
                    hold_unpaid: hold_unpaid.clone(),
                    gets: gets.clone(),
                    interrupt_mint: true,
                };
                let (mint, server, posts) = crate::e2e::start_fake_mint_counted(0, fault).await;
                let dir = tempfile::tempdir().unwrap();
                let (mut h, _) = CdkWallet::open(
                    &[75; 64],
                    dir.path().join("wallet.sqlite").to_str().unwrap(),
                )
                .await
                .unwrap();
                h.add_mint(&mint).await.unwrap();
                let b_id = if outcome == "unchanged" {
                    let b: Value =
                        serde_json::from_str(&h.create_deposit(&mint, "21").await.unwrap())
                            .unwrap();
                    b["id"].as_str().unwrap().to_string()
                } else {
                    "B".to_string()
                };
                let a: Value =
                    serde_json::from_str(&h.create_deposit(&mint, "21").await.unwrap()).unwrap();
                let id = a["id"].as_str().unwrap();
                let deadline = std::time::Instant::now() + Duration::from_secs(15);
                loop {
                    if h.check_deposit(&mint, id).await.is_err() {
                        break;
                    }
                    assert!(std::time::Instant::now() < deadline);
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
                // A is an actual interrupted CDK saga. B is an independent
                // locally retained quote; no shadow ledger is involved.
                let selected = parse_mint_url(&mint).unwrap();
                if outcome == "empty" || outcome == "oversized" {
                    // An already observed remote Issued quote still has an
                    // interrupted local CDK saga. Once recovery completes its
                    // local transaction, eligibility must exclude it.
                    let mut saved = h.db.get_mint_quote(id).await.unwrap().unwrap();
                    saved.state = MintQuoteState::Issued;
                    h.db.add_mint_quote(saved).await.unwrap();
                }
                let mut b = quote("B", &selected);
                if outcome == "oversized" {
                    b.request = "x".repeat(4097);
                }
                if outcome != "empty" && outcome != "unchanged" {
                    h.db.add_mint_quote(b).await.unwrap();
                }
                fail_get.store(outcome == "error", Ordering::SeqCst);
                fail_mint.store(outcome == "pending", Ordering::SeqCst);
                hold_unpaid.store(outcome == "unchanged", Ordering::SeqCst);
                let before = gets.load(Ordering::SeqCst);
                let update: Value = serde_json::from_str(
                    &h.deposit_update(
                        &mint,
                        if outcome == "empty" || outcome == "oversized" {
                            "poll"
                        } else {
                            "check"
                        },
                        if outcome == "empty" || outcome == "oversized" {
                            ""
                        } else {
                            &b_id
                        },
                    )
                    .await
                    .unwrap(),
                )
                .unwrap();
                assert_eq!(update["wallet_changed"], true, "{outcome}: {update}");
                if outcome == "pending" {
                    assert_eq!(update["recovery_pending"], true);
                    assert!(update["error"].is_object());
                    assert_eq!(
                        gets.load(Ordering::SeqCst),
                        before,
                        "unresolved recovery must skip subsequent B check"
                    );
                    assert_eq!(
                        h.create_deposit(&mint, "22").await.unwrap_err().status,
                        CdkStatus::RecoveryPending
                    );
                    fail_mint.store(false, Ordering::SeqCst);
                    let recovered: Value = serde_json::from_str(
                        &h.deposit_update(&mint, "recover", "").await.unwrap(),
                    )
                    .unwrap();
                    assert_eq!(recovered["recovery_pending"], false);
                    assert_eq!(recovered["wallet_changed"], true);
                    assert_eq!(h.list_balances().await.unwrap()[0].1, 21);
                    assert_eq!(posts.load(Ordering::SeqCst), 1);
                    server.abort();
                    continue;
                }
                assert_eq!(h.list_balances().await.unwrap()[0].1, 21);
                let screen: Value =
                    serde_json::from_str(&h.wallet_screen(&mint).await.unwrap()).unwrap();
                assert_eq!(screen["msats"], "21");
                let history: Value =
                    serde_json::from_str(&h.quote_history().await.unwrap()).unwrap();
                assert!(
                    history.as_array().unwrap().iter().any(|r| r["id"] == id
                        && r["state"]
                            == if outcome == "error" || outcome == "unchanged" {
                                "PAID"
                            } else {
                                "ISSUED"
                            }),
                    "{outcome}: {history}"
                );
                let completed = CdkWallet::completed_quotes(
                    h.db.list_transactions(None, None, None).await.unwrap(),
                );
                assert!(completed.contains(&(mint.clone(), UNIT.to_string(), id.to_string())));
                assert_eq!(
                    posts.load(Ordering::SeqCst),
                    if outcome == "unchanged" { 2 } else { 1 }
                );
                if outcome == "unchanged" {
                    assert_eq!(update["invoice"]["state"], "UNPAID");
                    assert!(update["error"].is_null());
                    let again: Value = serde_json::from_str(
                        &h.deposit_update(&mint, "check", &b_id).await.unwrap(),
                    )
                    .unwrap();
                    assert_eq!(again["wallet_changed"], false);
                }
                if outcome == "error" || outcome == "oversized" {
                    assert!(update["error"].is_object());
                }
                if outcome == "empty" {
                    assert!(update["invoice"].is_null());
                }
                server.abort();
            }
        });
    }

    fn quote(id: &str, mint: &MintUrl) -> cdk_common::wallet::MintQuote {
        cdk_common::wallet::MintQuote {
            id: id.into(),
            mint_url: mint.clone(),
            payment_method: PaymentMethod::BOLT11,
            amount: Some(Amount::from(21)),
            unit: UNIT,
            request: format!("lnbc{}", "a".repeat(1020)),
            state: MintQuoteState::Unpaid,
            expiry: 0,
            secret_key: None,
            amount_issued: Amount::ZERO,
            amount_paid: Amount::ZERO,
            updated_at: 0,
            estimated_blocks: None,
            used_by_operation: None,
            version: 0,
        }
    }

    #[test]
    fn intent_cleanup_reopens_and_returns_old_invoice_without_a_second_post() {
        runtime().block_on(async {
            let (mint,server,posts) = crate::e2e::start_fake_mint_counted(0,SwapFault::None).await;
            let dir=tempfile::tempdir().unwrap(); let path=dir.path().join("wallet.sqlite"); let path=path.to_str().unwrap();
            let (mut h,_) = CdkWallet::open(&[61;64],path).await.unwrap(); h.add_mint(&mint).await.unwrap();
            let conn=rusqlite::Connection::open(path).unwrap();
            conn.execute_batch("CREATE TRIGGER fail_intent_delete BEFORE DELETE ON kv_store WHEN OLD.secondary_namespace = 'deposit_intent_v2' BEGIN SELECT RAISE(FAIL, 'injected cleanup failure'); END;").unwrap();
            let first:Value=serde_json::from_str(&h.create_deposit(&mint,"21").await.unwrap()).unwrap(); drop(h);
            let (mut h,_)=CdkWallet::open(&[61;64],path).await.unwrap();
            let recovered:Value=serde_json::from_str(&h.recover_deposit(&mint).await.unwrap()).unwrap();
            assert_eq!(recovered["invoice"]["id"],first["id"]);
            let same:Value=serde_json::from_str(&h.create_deposit(&mint,"42").await.unwrap()).unwrap();
            assert_eq!(same["id"],first["id"]); assert_eq!(posts.load(Ordering::SeqCst),1);
            conn.execute_batch("DROP TRIGGER fail_intent_delete;").unwrap();
            let same:Value=serde_json::from_str(&h.create_deposit(&mint,"42").await.unwrap()).unwrap();
            assert_eq!(same["id"],first["id"]); assert_eq!(posts.load(Ordering::SeqCst),1);
            h.create_deposit(&mint,"42").await.unwrap(); assert_eq!(posts.load(Ordering::SeqCst),2);
            server.abort();
        });
    }

    #[test]
    fn definitive_rejection_retries_but_timeout_recovery_never_posts() {
        runtime().block_on(async {
            for definitive in [true, false] {
                let fault = if definitive {
                    SwapFault::RejectQuoteOnce
                } else {
                    SwapFault::StallQuoteOnce(Duration::from_secs(1))
                };
                let (mint, server, posts) = crate::e2e::start_fake_mint_counted(0, fault).await;
                let dir = tempfile::tempdir().unwrap();
                let path = dir.path().join("wallet.sqlite");
                let (mut h, _) = CdkWallet::open(&[62; 64], path.to_str().unwrap())
                    .await
                    .unwrap();
                h.add_mint(&mint).await.unwrap();
                h.test_network_deadline = Some(Duration::from_millis(100));
                let error = h.create_deposit(&mint, "21").await.unwrap_err();
                assert_eq!(
                    error.status,
                    if definitive {
                        CdkStatus::InvalidArgument
                    } else {
                        CdkStatus::RecoveryPending
                    }
                );
                let before = posts.load(Ordering::SeqCst);
                let recovery: Value =
                    serde_json::from_str(&h.recover_deposit(&mint).await.unwrap()).unwrap();
                assert_eq!(
                    recovery["creation_recovery"],
                    if definitive { "none" } else { "unknown" }
                );
                assert!(recovery["invoice"].is_null());
                assert_eq!(posts.load(Ordering::SeqCst), before);
                if definitive {
                    h.test_network_deadline = None;
                    h.create_deposit(&mint, "21").await.unwrap();
                    assert_eq!(posts.load(Ordering::SeqCst), before + 1);
                } else {
                    assert!(h.create_deposit(&mint, "21").await.is_err());
                    assert_eq!(posts.load(Ordering::SeqCst), before);
                }
                server.abort();
            }
        });
    }

    #[test]
    fn intent_evidence_never_associates_old_mismatched_multiple_or_legacy_quotes() {
        runtime().block_on(async {
            let mint = parse_mint_url("http://127.0.0.1:9").unwrap();
            for case in [
                "old",
                "old_exact",
                "amount",
                "method",
                "unit",
                "mint",
                "multiple",
                "known",
                "exact",
                "legacy",
            ] {
                let dir = tempfile::tempdir().unwrap();
                let path = dir.path().join("wallet.sqlite");
                let (h, _) = CdkWallet::open(&[63; 64], path.to_str().unwrap())
                    .await
                    .unwrap();
                h.db.add_mint(mint.clone(), None).await.unwrap();
                h.db.add_mint_quote(quote("old", &mint)).await.unwrap();
                let record = DepositIntent {
                    version: 2,
                    mint_url: mint.to_string(),
                    unit: "msat".into(),
                    payment_method: "bolt11".into(),
                    amount: 21,
                    created_at: 7,
                    before_quote_ids: vec!["old".into()],
                    quote_id: if case == "exact" {
                        Some("new".into())
                    } else if case == "old_exact" {
                        Some("old".into())
                    } else {
                        None
                    },
                };
                if case != "old" {
                    let mut q = quote("new", &mint);
                    match case {
                        "amount" => q.amount = Some(Amount::from(42)),
                        "method" => q.payment_method = PaymentMethod::BOLT12,
                        "unit" => q.unit = CurrencyUnit::Sat,
                        "mint" => {
                            q.mint_url = parse_mint_url("http://127.0.0.1:8").unwrap();
                            h.db.add_mint(q.mint_url.clone(), None).await.unwrap();
                        }
                        _ => {}
                    }
                    h.db.add_mint_quote(q).await.unwrap();
                    if case == "multiple" || case == "exact" {
                        h.db.add_mint_quote(quote("other", &mint)).await.unwrap();
                    }
                }
                let key = CdkWallet::quote_key("In", &mint.to_string(), "creation_intent");
                let bytes = if case == "legacy" {
                    b"pending".to_vec()
                } else {
                    serde_json::to_vec(&record).unwrap()
                };
                h.db.kv_write(KV_NAMESPACE, DEPOSIT_INTENT_NAMESPACE, &key, &bytes)
                    .await
                    .unwrap();
                let (state, recovered) = h.reconcile_deposit(&mint).await.unwrap();
                if case == "known" || case == "exact" {
                    assert_eq!(state, "none");
                    assert_eq!(recovered.unwrap().id, "new");
                } else {
                    assert_eq!(
                        state,
                        if case == "legacy" {
                            "legacy_unknown"
                        } else {
                            "unknown"
                        }
                    );
                    assert!(recovered.is_none());
                    assert_eq!(
                        h.db.kv_read(KV_NAMESPACE, DEPOSIT_INTENT_NAMESPACE, &key)
                            .await
                            .unwrap(),
                        Some(bytes)
                    );
                }
            }
        });
    }

    #[test]
    fn history_pages_replace_unusable_ids_without_losing_other_rows() {
        runtime().block_on(async {
            let mint = parse_mint_url("http://127.0.0.1:9").unwrap();
            let dir = tempfile::tempdir().unwrap();
            let (h, _) = CdkWallet::open(
                &[64; 64],
                dir.path().join("wallet.sqlite").to_str().unwrap(),
            )
            .await
            .unwrap();
            for i in 0..7 {
                h.db.add_mint_quote(quote(&format!("normal-{i}"), &mint))
                    .await
                    .unwrap();
            }
            for id in ["x".repeat(1025), "y".repeat(15 * 1024), "nul\0id".into()] {
                h.db.add_mint_quote(quote(&id, &mint)).await.unwrap();
            }
            let mut normal = 0;
            let mut placeholders = 0;
            let mut identities = BTreeSet::new();
            for offset in ["0", "8"] {
                let raw = h.quote_history_page(offset).await.unwrap();
                assert!(raw.len() < 128 * 1024);
                let page: Value = serde_json::from_str(&raw).unwrap();
                assert_eq!(page["total"], "10");
                for row in page["rows"].as_array().unwrap() {
                    assert_eq!(row["direction"], "In");
                    if row.get("error").is_some() {
                        placeholders += 1;
                        assert!(row.get("id").is_none());
                        let identity = row["identity"].as_str().unwrap();
                        assert_eq!(identity.len(), 64);
                        assert!(identities.insert(identity.to_owned()));
                    } else {
                        normal += 1;
                        assert!(row["id"].as_str().unwrap().starts_with("normal-"));
                    }
                }
            }
            assert_eq!((normal, placeholders), (7, 3));
            let whole: Value = serde_json::from_str(&h.quote_history().await.unwrap()).unwrap();
            assert_eq!(whole.as_array().unwrap().len(), 10);
        });
    }

    #[test]
    fn large_history_opens_small_pages_and_polls_every_unfinished_invoice() {
        runtime().block_on(async {
            use cdk_common::wallet::{Transaction, TransactionDirection, TransactionStatus};
            let mint = parse_mint_url("http://127.0.0.1:9").unwrap();
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("wallet.sqlite");
            let (h, _) = CdkWallet::open(&[64; 64], path.to_str().unwrap())
                .await
                .unwrap();
            h.db.add_mint(mint.clone(), None).await.unwrap();
            let mut expected = Vec::new();
            for i in 0..1100 {
                let id = format!("quote-{i:04}");
                let mut q = quote(&id, &mint);
                // Unconfirmed remote issuance is unfinished, but local-only to
                // check: keep the large rotation test independent of transport retries.
                q.state = MintQuoteState::Issued;
                if i < 800 {
                    q.state = MintQuoteState::Issued;
                    h.db.add_transaction(Transaction {
                        mint_url: mint.clone(),
                        direction: TransactionDirection::Incoming,
                        amount: Amount::from(21),
                        fee: Amount::ZERO,
                        unit: UNIT,
                        ys: vec![],
                        timestamp: 0,
                        memo: None,
                        metadata: Default::default(),
                        quote_id: Some(id.clone()),
                        payment_request: None,
                        payment_proof: None,
                        payment_method: Some(PaymentMethod::BOLT11),
                        saga_id: Some(Uuid::new_v4()),
                        status: TransactionStatus::Completed,
                    })
                    .await
                    .unwrap();
                }
                h.db.add_mint_quote(q).await.unwrap();
                let time = if i % 100 == 0 {
                    Some(123 + (i / 100) % 2)
                } else {
                    None
                };
                if let Some(time) = time {
                    h.db.kv_write(
                        KV_NAMESPACE,
                        "quote_created_v1",
                        &CdkWallet::quote_key("In", &mint.to_string(), &id),
                        &(time as u64).to_le_bytes(),
                    )
                    .await
                    .unwrap();
                }
                expected.push((time, "In", mint.to_string(), id));
            }
            for (id, owner) in [("out-known", Some(mint.clone())), ("out-unknown", None)] {
                h.db.add_melt_quote(cdk_common::wallet::MeltQuote {
                    id: id.into(),
                    mint_url: owner.clone(),
                    unit: UNIT,
                    amount: Amount::from(42),
                    request: "private invoice".into(),
                    fee_reserve: Amount::ZERO,
                    state: cdk::nuts::MeltQuoteState::Unpaid,
                    expiry: 0,
                    payment_proof: Some("private proof".into()),
                    estimated_blocks: None,
                    fee_index: None,
                    payment_method: PaymentMethod::BOLT11,
                    used_by_operation: None,
                    version: 0,
                })
                .await
                .unwrap();
                expected.push((
                    None,
                    "Out",
                    owner.map(|m| m.to_string()).unwrap_or_default(),
                    id.into(),
                ));
            }
            drop(h);
            let (mut h, _) =
                CdkWallet::open_selected(&[64; 64], path.to_str().unwrap(), Some(&mint))
                    .await
                    .unwrap();
            assert!(h.quote_history().await.unwrap().len() > 128 * 1024);
            assert!(
                h.unfinished_deposits(&mint.to_string())
                    .await
                    .unwrap()
                    .len()
                    > 128 * 1024
            );
            assert!(h.wallet_screen(&mint.to_string()).await.unwrap().len() < 512);
            expected.sort_by(|a, b| {
                b.0.cmp(&a.0)
                    .then_with(|| (&a.1, &a.2, &a.3).cmp(&(&b.1, &b.2, &b.3)))
            });
            let mut actual = Vec::new();
            for offset in (0..expected.len()).step_by(8) {
                let raw = h.quote_history_page(&offset.to_string()).await.unwrap();
                assert!(raw.len() < 128 * 1024);
                let page: Value = serde_json::from_str(&raw).unwrap();
                assert_eq!(page["total"], expected.len().to_string());
                for row in page["rows"].as_array().unwrap() {
                    actual.push(row["id"].as_str().unwrap().to_owned());
                }
            }
            assert_eq!(
                actual,
                expected.into_iter().map(|e| e.3).collect::<Vec<_>>()
            );
            let clamped: Value =
                serde_json::from_str(&h.quote_history_page("4294967288").await.unwrap()).unwrap();
            assert_eq!(clamped["offset"], "1096");
            for invalid in ["", "-8", "+8", "1", "8.0", "4294967296"] {
                assert!(h.quote_history_page(invalid).await.is_err());
            }
            let mut cursor = String::new();
            let mut ids = BTreeSet::new();
            let mut expired = quote("quote-expired", &mint);
            expired.expiry = 1;
            h.db.add_mint_quote(expired).await.unwrap();
            let resumed: Value =
                serde_json::from_str(&h.resume_deposit(&mint.to_string()).await.unwrap()).unwrap();
            assert_eq!(resumed["invoice"]["id"], "quote-0900");
            assert!(resumed.get("cursor").is_none());
            for _ in 0..300 {
                let raw = h.poll_deposits(&mint.to_string(), &cursor).await.unwrap();
                assert!(raw.len() < 128 * 1024);
                let reply: Value = serde_json::from_str(&raw).unwrap();
                assert!(ids.insert(reply["cursor"].as_str().unwrap().to_owned()));
                cursor = reply["cursor"].as_str().unwrap().into();
            }
            let wrap: Value =
                serde_json::from_str(&h.poll_deposits(&mint.to_string(), &cursor).await.unwrap())
                    .unwrap();
            assert_eq!(wrap["cursor"], "quote-0800");
            let mut huge = quote("aaa-oversized", &mint);
            huge.state = MintQuoteState::Issued;
            huge.request = "a".repeat(140000);
            h.db.add_mint_quote(huge).await.unwrap();
            h.db.kv_write(
                KV_NAMESPACE,
                "quote_created_v1",
                &CdkWallet::quote_key("In", &mint.to_string(), "aaa-oversized"),
                &u64::MAX.to_le_bytes(),
            )
            .await
            .unwrap();
            let newest: Value =
                serde_json::from_str(&h.resume_deposit(&mint.to_string()).await.unwrap()).unwrap();
            assert!(newest["invoice"].is_null() && newest["error"].is_string());
            assert!(newest.get("cursor").is_none());
            let oversized: Value =
                serde_json::from_str(&h.poll_deposits(&mint.to_string(), "").await.unwrap())
                    .unwrap();
            assert!(oversized["error"].is_string());
            let next: Value = serde_json::from_str(
                &h.poll_deposits(&mint.to_string(), oversized["cursor"].as_str().unwrap())
                    .await
                    .unwrap(),
            )
            .unwrap();
            assert_eq!(next["cursor"], "quote-0800");
            assert!(h.wallet_screen(&mint.to_string()).await.unwrap().len() < 512);
            let long_id = format!("000{}", "x".repeat(1400));
            let mut long = quote(&long_id, &mint);
            long.state = MintQuoteState::Issued;
            h.db.add_mint_quote(long).await.unwrap();
            let oversized: Value =
                serde_json::from_str(&h.poll_deposits(&mint.to_string(), "").await.unwrap())
                    .unwrap();
            assert!(oversized["error"].is_string());
            assert!(oversized["cursor"].as_str().unwrap().len() < 1024);
            let next: Value = serde_json::from_str(
                &h.poll_deposits(&mint.to_string(), oversized["cursor"].as_str().unwrap())
                    .await
                    .unwrap(),
            )
            .unwrap();
            assert_ne!(next["cursor"], oversized["cursor"]);
            assert!(h.db.get_mint_quote(&long_id).await.unwrap().is_some());
        });
    }

    #[test]
    fn checked_amounts_and_unambiguous_history_keys() {
        for bad in [
            "",
            "0",
            "+1",
            "-1",
            "1.0",
            "1e3",
            " 1",
            "18446744073709551616",
            "9223372036854775808",
        ] {
            assert!(CdkWallet::deposit_amount(bad).is_err(), "{bad}");
        }
        assert_eq!(CdkWallet::deposit_amount("42").unwrap(), 42);
        assert_ne!(
            CdkWallet::quote_key("In", "a:b", "c"),
            CdkWallet::quote_key("In", "a", "b:c")
        );
        assert_ne!(
            CdkWallet::quote_key("In", "a", "b"),
            CdkWallet::quote_key("Out", "a", "b")
        );
    }

    #[test]
    fn expired_unpaid_is_local_only_and_paid_expiry_remains_eligible() {
        runtime().block_on(async {
            let mint = parse_mint_url("http://127.0.0.1:9").unwrap();
            let dir = tempfile::tempdir().unwrap();
            let (mut h, _) = CdkWallet::open(
                &[94; 64],
                dir.path().join("wallet.sqlite").to_str().unwrap(),
            )
            .await
            .unwrap();
            let mut expired = quote("expired", &mint);
            expired.expiry = 1;
            assert!(!quote_expired(&expired, 1));
            assert!(quote_expired(&expired, 2));
            h.db.add_mint_quote(expired.clone()).await.unwrap();
            let checked: Value =
                serde_json::from_str(&h.check_deposit(&mint.to_string(), "expired").await.unwrap())
                    .unwrap();
            assert_eq!(checked["expired"], true);
            assert!(h.unresolved.is_empty());
            let resumed: Value =
                serde_json::from_str(&h.resume_deposit(&mint.to_string()).await.unwrap()).unwrap();
            assert!(resumed["invoice"].is_null());
            let polled: Value =
                serde_json::from_str(&h.poll_deposits(&mint.to_string(), "").await.unwrap())
                    .unwrap();
            assert!(polled["invoice"].is_null() && polled["cursor"].is_null());
            expired.state = MintQuoteState::Paid;
            assert!(!quote_expired(&expired, unix_now()));
            h.db.add_mint_quote(expired.clone()).await.unwrap();
            assert_eq!(
                h.eligible_deposits(&mint, h.db.get_mint_quotes().await.unwrap())
                    .await
                    .unwrap()
                    .len(),
                1
            );
            expired = h.db.get_mint_quote("expired").await.unwrap().unwrap();
            expired.state = MintQuoteState::Issued;
            h.db.add_mint_quote(expired).await.unwrap();
            assert_eq!(
                h.eligible_deposits(&mint, h.db.get_mint_quotes().await.unwrap())
                    .await
                    .unwrap()
                    .len(),
                1
            );
            assert!(!quote_expired(&quote("legacy", &mint), unix_now()));
        });
    }

    #[test]
    fn persisted_deposit_reload_paid_expired_claim_exactly_once_and_history_is_local() {
        runtime().block_on(async {
            let mint = start_fake_mint(0).await;
            let selected = parse_mint_url(&mint).unwrap();
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("wallet.sqlite");
            let path = path.to_str().unwrap();
            let (mut h, _) = CdkWallet::open_selected(&[18; 64], path, Some(&selected))
                .await
                .unwrap();
            h.add_mint(&mint).await.unwrap();
            assert!(h.create_deposit(&mint, "10001").await.is_err());
            let result: Value =
                serde_json::from_str(&h.create_deposit(&mint, "42").await.unwrap()).unwrap();
            let id = result["id"].as_str().unwrap().to_owned();
            let mut quote = h.db.get_mint_quote(&id).await.unwrap().unwrap();
            quote.state = MintQuoteState::Paid;
            quote.expiry = 1; // Paid-but-expired invoices must not be dropped.
            h.db.add_mint_quote(quote).await.unwrap();
            let history: Value = serde_json::from_str(&h.quote_history().await.unwrap()).unwrap();
            let created = history[0]["created_at"].clone();
            assert!(created.is_string());
            assert!(history[0].get("invoice").is_none());
            assert!(history[0].get("secret_key").is_none());
            // Legacy mint registration is local; scoped opening must not attempt
            // any recovery/refresh against this unreachable old mint.
            h.db.add_mint(parse_mint_url("http://127.0.0.1:9").unwrap(), None)
                .await
                .unwrap();
            h.flush_rate_limits().await;
            drop(h);
            let (mut h, reports) = CdkWallet::open_selected(&[18; 64], path, Some(&selected))
                .await
                .unwrap();
            assert!(reports.iter().all(|r| r.mint_url == mint));
            let deadline = std::time::Instant::now() + Duration::from_secs(15);
            loop {
                let state: Value =
                    serde_json::from_str(&h.check_deposit(&mint, &id).await.unwrap()).unwrap();
                if state["state"] == "ISSUED" {
                    break;
                }
                assert!(std::time::Instant::now() < deadline);
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            assert_eq!(
                h.list_balances()
                    .await
                    .unwrap()
                    .iter()
                    .find(|(m, _)| m == &mint)
                    .unwrap()
                    .1,
                42
            );
            h.check_deposit(&mint, &id).await.unwrap();
            assert_eq!(
                h.list_balances()
                    .await
                    .unwrap()
                    .iter()
                    .find(|(m, _)| m == &mint)
                    .unwrap()
                    .1,
                42
            );
            let history: Value = serde_json::from_str(&h.quote_history().await.unwrap()).unwrap();
            assert_eq!(history[0]["created_at"], created);
            assert_eq!(history[0]["state"], "ISSUED");
            let quote = h.db.get_mint_quote(&id).await.unwrap().unwrap();
            let melt = cdk_common::wallet::MeltQuote {
                id: "legacy-out".into(),
                mint_url: None,
                unit: UNIT,
                amount: Amount::from(21),
                request: "secret invoice".into(),
                fee_reserve: Amount::from(1),
                state: cdk::nuts::MeltQuoteState::Unpaid,
                expiry: quote.expiry,
                payment_proof: Some("secret proof".into()),
                estimated_blocks: None,
                fee_index: None,
                payment_method: PaymentMethod::BOLT11,
                used_by_operation: None,
                version: 0,
            };
            h.db.add_melt_quote(melt).await.unwrap();
            let raw = h.quote_history().await.unwrap();
            assert!(!raw.contains("secret invoice") && !raw.contains("secret proof"));
            let history: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(history[1]["direction"], "Out");
            assert!(history[1]["mint_url"].is_null() && history[1]["created_at"].is_null());
            // Stable ties use quote identity, never updated_at or database order.
            let time = created.as_str().unwrap().parse::<u64>().unwrap();
            for id in ["tie-z", "tie-a"] {
                let mut tied = quote.clone();
                tied.id = id.to_owned();
                tied.updated_at = time + 1000;
                h.db.add_mint_quote(tied).await.unwrap();
                let key = CdkWallet::quote_key("In", &mint, id);
                h.db.kv_write(KV_NAMESPACE, "quote_created_v1", &key, &time.to_le_bytes())
                    .await
                    .unwrap();
            }
            let history: Value = serde_json::from_str(&h.quote_history().await.unwrap()).unwrap();
            let ids: Vec<_> = history
                .as_array()
                .unwrap()
                .iter()
                .filter(|q| !q["created_at"].is_null())
                .map(|q| q["id"].as_str().unwrap())
                .collect();
            let mut ordered = ids.clone();
            ordered.sort();
            assert_eq!(ids, ordered);
            assert!(history.as_array().unwrap().last().unwrap()["created_at"].is_null());
        });
    }

    #[test]
    fn ambiguous_creation_never_blindly_recreates_and_interrupted_mint_recovers() {
        runtime().block_on(async {
            for fault in [SwapFault::MalformedQuoteOnce, SwapFault::MalformedMintOnce] {
                let creation_fault = matches!(fault, SwapFault::MalformedQuoteOnce);
                let (mint, server) = start_fake_mint_ctl(0, fault).await;
                let dir = tempfile::tempdir().unwrap();
                let path = dir.path().join("wallet.sqlite");
                let path = path.to_str().unwrap();
                let (mut h, _) = CdkWallet::open(&[19; 64], path).await.unwrap();
                h.add_mint(&mint).await.unwrap();
                let result = h.create_deposit(&mint, "21").await;
                if creation_fault {
                    assert!(result.is_err());
                    drop(h);
                    let (mut h, _) = CdkWallet::open(&[19; 64], path).await.unwrap();
                    assert_eq!(
                        h.create_deposit(&mint, "21").await.unwrap_err().status,
                        CdkStatus::RecoveryPending
                    );
                } else {
                    let result: Value = serde_json::from_str(&result.unwrap()).unwrap();
                    let id = result["id"].as_str().unwrap();
                    let deadline = std::time::Instant::now() + Duration::from_secs(15);
                    loop {
                        match h.check_deposit(&mint, id).await {
                            Err(e) => {
                                assert_eq!(e.status, CdkStatus::RecoveryPending);
                                break;
                            }
                            Ok(_) => {
                                assert!(std::time::Instant::now() < deadline);
                                tokio::time::sleep(Duration::from_millis(20)).await;
                            }
                        }
                    }
                    drop(h);
                    let (mut h, _) = CdkWallet::open(&[19; 64], path).await.unwrap();
                    let result: Value =
                        serde_json::from_str(&h.check_deposit(&mint, id).await.unwrap()).unwrap();
                    assert_eq!(result["state"], "ISSUED");
                    assert_eq!(h.list_balances().await.unwrap()[0].1, 21);
                }
                server.abort();
            }
        });
    }

    #[test]
    fn metadata_write_failure_retains_invoice_without_inventing_creation_time() {
        runtime().block_on(async {
            let mint = start_fake_mint(0).await;
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("wallet.sqlite");
            let path = path.to_str().unwrap();
            let (mut h, _) = CdkWallet::open(&[20;64],path).await.unwrap();
            h.add_mint(&mint).await.unwrap();
            let conn = rusqlite::Connection::open(path).unwrap();
            conn.execute_batch("CREATE TRIGGER fail_quote_time BEFORE INSERT ON kv_store WHEN NEW.secondary_namespace = 'quote_created_v1' BEGIN SELECT RAISE(FAIL, 'injected metadata failure'); END;").unwrap();
            let returned: Value = serde_json::from_str(&h.create_deposit(&mint,"21").await.unwrap()).unwrap();
            conn.execute_batch("DROP TRIGGER fail_quote_time;").unwrap();
            drop(conn);
            let saved = h.db.get_mint_quotes().await.unwrap();
            assert_eq!(saved.len(),1);
            let mut remote_issued = saved[0].clone();
            remote_issued.state = MintQuoteState::Issued;
            let view: Value = serde_json::from_str(&h.checked_invoice_view(&remote_issued).await.unwrap()).unwrap();
            assert_eq!(view["confirmed"],false, "remote Issued without local issuance is not success");
            let id = saved[0].id.clone();
            assert_eq!(returned["id"],id);
            let raw: Value = serde_json::from_str(&h.quote_history().await.unwrap()).unwrap();
            assert!(raw[0]["created_at"].is_null());
            drop(h);
            let (mut h, _) = CdkWallet::open(&[20;64],path).await.unwrap();
            let next: Value = serde_json::from_str(&h.create_deposit(&mint,"21").await.unwrap()).unwrap();
            assert_ne!(next["id"],id);
            let deadline = std::time::Instant::now()+Duration::from_secs(15);
            loop {
                let raw: Value = serde_json::from_str(&h.check_deposit(&mint,&id).await.unwrap()).unwrap();
                if raw["state"] == "ISSUED" { break; }
                assert!(std::time::Instant::now()<deadline);
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            assert_eq!(h.list_balances().await.unwrap()[0].1,21);
            let raw: Value = serde_json::from_str(&h.quote_history().await.unwrap()).unwrap();
            assert!(raw.as_array().unwrap().iter().find(|q|q["id"]==id).unwrap()["created_at"].is_null());
        });
    }
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod restore_abandon_tests {
    use super::*;
    use cdk::nuts::{Proof, State};
    use cdk::secret::Secret;
    use cdk_common::wallet::ProofInfo;

    #[test]
    fn restore_can_abandon_checks_local_artifacts_and_errors() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wallet.sqlite");
        let (mut wallet, _) = runtime()
            .block_on(CdkWallet::open(&[42; 64], path.to_str().unwrap()))
            .unwrap();
        let check = || crate::cdk_wallet_restore_can_abandon(Some(&wallet));
        assert_eq!(check().safe_to_abandon, 1);
        let mint = MintUrl::from_str("https://test-mint.example.com").unwrap();
        runtime()
            .block_on(wallet.db.add_mint(mint.clone(), None))
            .unwrap();
        assert_eq!(check().safe_to_abandon, 1);
        let proof = Proof {
            amount: Amount::from(1),
            keyset_id: Id::from_str("00916bbf7ef91a36").unwrap(),
            secret: Secret::generate(),
            c: SecretKey::generate().public_key(),
            witness: None,
            dleq: None,
            p2pk_e: None,
        };
        let proof = ProofInfo::new(proof, mint, State::Spent, UNIT).unwrap();
        runtime()
            .block_on(wallet.db.update_proofs(vec![proof], vec![]))
            .unwrap();
        let result = check();
        assert_eq!(result.status, CdkStatus::Ok);
        assert_eq!(result.safe_to_abandon, 0);
        let null = crate::cdk_wallet_restore_can_abandon(None);
        assert_eq!(null.status, CdkStatus::NullArgument);
        assert_eq!(null.safe_to_abandon, 0);
        crate::cdk_string_free(null.error);
        crate::api::cdk_test_panic(Some(&mut wallet));
        let poisoned = crate::cdk_wallet_restore_can_abandon(Some(&wallet));
        assert_eq!(poisoned.status, CdkStatus::InternalError);
        assert_eq!(poisoned.safe_to_abandon, 0);
        crate::cdk_string_free(poisoned.error);
    }

    #[test]
    fn restore_can_abandon_rejects_undecodable_proof() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wallet.sqlite");
        let (wallet, _) = runtime()
            .block_on(CdkWallet::open(&[42; 64], path.to_str().unwrap()))
            .unwrap();
        let mint = MintUrl::from_str("https://test-mint.example.com").unwrap();
        runtime()
            .block_on(wallet.db.add_mint(mint.clone(), None))
            .unwrap();
        let proof = Proof {
            amount: Amount::from(1),
            keyset_id: Id::from_str("00916bbf7ef91a36").unwrap(),
            secret: Secret::generate(),
            c: SecretKey::generate().public_key(),
            witness: None,
            dleq: None,
            p2pk_e: None,
        };
        let proof = ProofInfo::new(proof, mint, State::Spent, UNIT).unwrap();
        runtime()
            .block_on(wallet.db.update_proofs(vec![proof], vec![]))
            .unwrap();
        let conn = rusqlite::Connection::open(&path).unwrap();
        assert_eq!(conn.execute("UPDATE proof SET c = x'00'", []).unwrap(), 1);
        assert!(runtime()
            .block_on(wallet.db.get_proofs(None, None, None, None))
            .unwrap()
            .is_empty());
        assert!(!runtime().block_on(wallet.restore_can_abandon()).unwrap());
    }

    #[test]
    fn restore_can_abandon_rejects_replaced_database_path() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wallet.sqlite");
        let (wallet, _) = runtime()
            .block_on(CdkWallet::open(&[42; 64], path.to_str().unwrap()))
            .unwrap();
        fs::rename(&path, dir.path().join("original.sqlite")).unwrap();
        File::create(&path).unwrap();
        assert_eq!(
            runtime()
                .block_on(wallet.restore_can_abandon())
                .unwrap_err()
                .status,
            CdkStatus::DatabaseError
        );
    }
}

impl CdkWallet {
    /// Open (creating if needed) a wrapper-owned database.
    ///
    /// Returns the handle and the per-mint startup recovery reports.
    ///
    /// A pre-existing database is validated **read-only** (marker, format
    /// version, seed fingerprint) *before* upstream migrations are allowed to
    /// touch it, so a foreign or wrong-seed file is never mutated just to be
    /// rejected.
    pub(crate) async fn open(
        seed_bytes: &[u8],
        path_str: &str,
    ) -> FfiResult<(Self, Vec<MintRecoveryReport>)> {
        Self::open_selected(seed_bytes, path_str, None).await
    }

    /// Application opening recovers only the explicitly selected mint. Repository
    /// initialization loads persisted metadata without refreshing legacy mints.
    pub(crate) async fn open_selected(
        seed_bytes: &[u8],
        path_str: &str,
        selected: Option<&MintUrl>,
    ) -> FfiResult<(Self, Vec<MintRecoveryReport>)> {
        if seed_bytes.len() != 64 {
            return Err(FfiErr::new(
                CdkStatus::InvalidSeed,
                format!("seed must be exactly 64 bytes, got {}", seed_bytes.len()),
            ));
        }
        let mut seed = Zeroizing::new([0u8; 64]);
        seed.copy_from_slice(seed_bytes);

        #[cfg(not(target_arch = "wasm32"))]
        let (db, file) = {
            if path_str.is_empty() {
                return Err(FfiErr::new(
                    CdkStatus::InvalidPath,
                    "database path is empty",
                ));
            }
            let path = PathBuf::from(path_str);
            if path.is_dir() {
                return Err(FfiErr::new(
                    CdkStatus::InvalidPath,
                    "database path points at a directory",
                ));
            }
            ensure_parent_dirs(&path)?;

            // Distinguish a genuinely new database from any pre-existing path
            // (including an empty file). `symlink_metadata` does not follow the
            // final component, so a symlink is detected here.
            let existed = match fs::symlink_metadata(&path) {
                Ok(meta) => {
                    if meta.file_type().is_symlink() {
                        return Err(FfiErr::new(
                            CdkStatus::InvalidPath,
                            "database path is a symbolic link; refusing to follow it",
                        ));
                    }
                    true
                }
                Err(e) if e.kind() == io::ErrorKind::NotFound => false,
                Err(e) => {
                    return Err(FfiErr::new(
                        CdkStatus::InvalidPath,
                        format!("could not inspect the database path: {e}"),
                    ))
                }
            };

            // Hold the wrapper-wide exclusive lock on the database file itself,
            // so every path to the same inode (including hard-link aliases) is
            // excluded. The platform helper chooses a mechanism that cannot
            // collide with SQLite's own locks on this file. `O_NOFOLLOW` refuses
            // a symlinked final component at open time; `O_CLOEXEC` keeps the
            // lock fd out of child processes. `create(true)` plus an explicit
            // mode keeps a brand-new file 0600. The same fd is retained for the
            // handle lifetime as `_lock`, which releases the lock on close.
            let file = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&path)
                .map_err(|e| {
                    FfiErr::new(CdkStatus::InvalidPath, format!("could not open file: {e}"))
                })?;

            // Take the lock before validation or opening SQLite, so a second
            // handle is rejected without touching the database.
            acquire_database_lock(&file)?;

            // Validate the *opened* file (fstat): regular file, owner-only perms.
            check_regular_file(&file)?;

            // Reject an inherited database whose permissions/ACL are too broad
            // before reading SQLite metadata or allowing any migration to touch
            // it. New files are created 0600 above, so this only fires for
            // pre-existing files or inherited ACLs.
            check_permissions(&file)?;

            // Validate an existing marker read-only, before any migration runs.
            if existed {
                validate_existing_marker(&path, &seed)?;
            }

            let db = WalletSqliteDatabase::new(path.clone()).await.map_err(|e| {
                if existed {
                    FfiErr::new(
                        CdkStatus::UnsupportedDatabase,
                        format!("could not open existing database: {e}"),
                    )
                } else {
                    FfiErr::new(
                        CdkStatus::DatabaseError,
                        format!("could not create database: {e}"),
                    )
                }
            })?;
            let db = Arc::new(db);

            // A genuinely new database is marked with a single KV write before the
            // wallet is used. Existing databases were validated above.
            if !existed {
                let mut marker = [0u8; MARKER_LEN];
                marker[..4].copy_from_slice(&FORMAT_VERSION.to_le_bytes());
                marker[4..].copy_from_slice(&seed_fingerprint(&seed[..]));
                db.kv_write(KV_NAMESPACE, "", KEY_MARKER, &marker)
                    .await
                    .map_err(db_error)?;
            }

            (db, file)
        };
        #[cfg(target_arch = "wasm32")]
        let (db, file) = crate::browser_platform::open_database(&seed, path_str).await?;

        let localstore: Arc<dyn WalletDatabase<database::Error> + Send + Sync> = db.clone();
        let repo = WalletRepositoryBuilder::new()
            .localstore(localstore)
            .seed(*seed)
            .build()
            .await
            .map_err(|e| {
                FfiErr::new(
                    CdkStatus::DatabaseError,
                    format!("could not build repository: {e}"),
                )
            })?;

        let mut handle = CdkWallet {
            repo,
            db,
            #[cfg(not(target_arch = "wasm32"))]
            db_path: PathBuf::from(path_str),
            _lock: file,
            unresolved: BTreeSet::new(),
            prepared_withdrawal: None,
            poisoned: Arc::new(AtomicBool::new(false)),
            #[cfg(test)]
            test_network_deadline: None,
            #[cfg(test)]
            test_recovery_deadline: None,
        };
        let reports = if let Some(mint) = selected {
            for wallet in handle.repo.get_wallets().await {
                if &wallet.mint_url != mint {
                    handle.unresolved.insert(wallet.mint_url.clone());
                }
            }
            if handle.repo.has_wallet(mint, &UNIT).await {
                handle.run_recovery(Some(mint)).await?
            } else {
                Vec::new()
            }
        } else {
            handle.run_recovery(None).await?
        };
        Ok((handle, reports))
    }

    /// List approved mint URLs (Msat wallets), sorted and de-duplicated.
    pub(crate) async fn list_mints(&self) -> Vec<String> {
        let mut urls: Vec<String> = self
            .repo
            .get_wallets()
            .await
            .into_iter()
            .filter(|w| w.unit == UNIT)
            .map(|w| w.mint_url.to_string())
            .collect();
        urls.sort();
        urls.dedup();
        urls
    }

    /// List approved mints with their locally spendable Msat balance.
    pub(crate) async fn list_balances(&self) -> FfiResult<Vec<(String, u64)>> {
        let balances = self.repo.get_balances().await.map_err(db_error)?;
        let mut out: Vec<(String, u64)> = balances
            .into_iter()
            .filter(|(key, _)| key.unit == UNIT)
            .map(|(key, amount)| (key.mint_url.to_string(), amount.to_u64()))
            .collect();
        out.sort();
        Ok(out)
    }

    /// Audit local recovery-owned state only; this neither establishes ownership
    /// nor proves that a seed has no funds at a mint.
    #[cfg(not(target_arch = "wasm32"))]
    pub(crate) async fn restore_can_abandon(&self) -> FfiResult<bool> {
        let check_identity = || -> FfiResult<()> {
            let locked = self._lock.metadata().map_err(db_error)?;
            let path = fs::metadata(&self.db_path).map_err(db_error)?;
            if (locked.dev(), locked.ino()) != (path.dev(), path.ino()) {
                return Err(FfiErr::new(
                    CdkStatus::DatabaseError,
                    "database path no longer identifies the locked file",
                ));
            }
            Ok(())
        };
        check_identity()?;
        let conn = rusqlite::Connection::open_with_flags(
            &self.db_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(db_error)?;
        check_identity()?;
        let has_proof_rows: bool = conn
            .query_row("SELECT EXISTS(SELECT 1 FROM proof)", [], |row| row.get(0))
            .map_err(db_error)?;
        check_identity()?;
        let proofs = self
            .db
            .get_proofs(None, None, None, None)
            .await
            .map_err(db_error)?;
        let mint_quotes = self.db.get_mint_quotes().await.map_err(db_error)?;
        let melt_quotes = self.db.get_melt_quotes().await.map_err(db_error)?;
        let transactions = self
            .db
            .list_transactions(None, None, None)
            .await
            .map_err(db_error)?;
        let sagas = self.db.get_incomplete_sagas().await.map_err(db_error)?;
        let p2pk_keys = self.db.list_p2pk_keys().await.map_err(db_error)?;
        Ok(!has_proof_rows
            && proofs.is_empty()
            && mint_quotes.is_empty()
            && melt_quotes.is_empty()
            && transactions.is_empty()
            && sagas.is_empty()
            && p2pk_keys.is_empty())
    }

    /// Register (approve) a mint after validating its URL and live keysets.
    pub(crate) async fn add_mint(&mut self, url_str: &str) -> FfiResult<()> {
        let mint_url = parse_mint_url(url_str)?;
        self.guard_prepared_withdrawal(Some(&mint_url))?;

        // Idempotent: an already-approved mint is a local no-op, no network.
        if self.repo.has_wallet(&mint_url, &UNIT).await {
            return Ok(());
        }

        let deadline = self.network_deadline();
        require_active_keyset(&mint_url, deadline).await?;
        let info = match timeout(deadline, self.repo.fetch_mint_info(&mint_url)).await {
            Ok(result) => result.map_err(|e| {
                let status = match &e {
                    CdkError::HttpError(..) | CdkError::Timeout | CdkError::CouldNotGetMintInfo => {
                        CdkStatus::NetworkError
                    }
                    _ => CdkStatus::MintRegistrationFailed,
                };
                FfiErr::new(status, format!("could not fetch mint info: {e}"))
            })?,
            Err(_) => {
                return Err(FfiErr::new(
                    CdkStatus::NetworkError,
                    "fetching mint info exceeded the network deadline",
                ))
            }
        };

        if !info.supported_units().iter().any(|u| **u == UNIT) {
            return Err(FfiErr::new(
                CdkStatus::MintUnsupportedUnit,
                "mint does not advertise msat payment support",
            ));
        }

        self.db
            .add_mint(mint_url.clone(), Some(info))
            .await
            .map_err(db_error)?;
        self.repo
            .get_or_create_wallet(mint_url, UNIT, None)
            .await
            .map_err(|e| FfiErr::new(CdkStatus::MintRegistrationFailed, format!("{e}")))?;
        Ok(())
    }

    /// Scan deterministic proofs for one Msat mint. Earlier batches may persist
    /// even if a later batch fails or the deadline expires.
    pub(crate) async fn restore_seed(&mut self, url: &str) -> FfiResult<(u64, u64, u64)> {
        let mint = parse_mint_url(url)?;
        self.guard_prepared_withdrawal(Some(&mint))?;
        #[cfg(target_arch = "wasm32")]
        crate::hoe_funding::guard_seed_restore(self, &mint).await?;
        self.add_mint(url).await?;
        let wallet = self.approved_wallet(&mint).await?;
        match timeout(SEED_RESTORE_DEADLINE, wallet.restore()).await {
            Ok(Ok(restored)) => Ok((
                restored.unspent.to_u64(),
                restored.pending.to_u64(),
                restored.spent.to_u64(),
            )),
            Ok(Err(e)) => Err(FfiErr::new(
                map_recovery_error(&e),
                format!("seed restore incomplete; previously restored proofs may remain: {e}"),
            )),
            Err(_) => Err(FfiErr::new(
                CdkStatus::NetworkError,
                "seed restore exceeded its deadline; previously restored proofs may remain",
            )),
        }
    }

    #[cfg(target_arch = "wasm32")]
    pub(crate) async fn browser_restore_can_abandon(&self) -> FfiResult<(u64, bool)> {
        self.db.restore_can_abandon().await.map_err(db_error)
    }

    /// Receive a token, returning the net Msat amount credited.
    ///
    /// The token is fully validated (parse, unit, mint, approval) before any
    /// network access. This is the common case with no P2PK signing keys.
    pub(crate) async fn receive(&mut self, token_str: &str) -> FfiResult<u64> {
        self.receive_with_keys(token_str, &[]).await
    }

    /// Receive a token, supplying P2PK signing keys for locked proofs.
    ///
    /// The token is fully validated (parse, unit, mint, approval) before any
    /// network access. The keys satisfy P2PK witnesses on the token's proofs;
    /// pass an empty slice for ordinary (unlocked) tokens.
    pub(crate) async fn receive_with_keys(
        &mut self,
        token_str: &str,
        signing_keys: &[SecretKey],
    ) -> FfiResult<u64> {
        if token_str.len() > MAX_TOKEN_BYTES {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "token exceeds the maximum supported size",
            ));
        }

        let token = Token::from_str(token_str)
            .map_err(|e| FfiErr::new(CdkStatus::InvalidToken, format!("invalid token: {e}")))?;

        // A Cashu token with no explicit unit defaults to sat, not the wallet unit.
        let unit = token.unit().unwrap_or(CurrencyUnit::Sat);
        if unit != UNIT {
            return Err(FfiErr::new(
                CdkStatus::UnsupportedToken,
                "token is not denominated in Msat",
            ));
        }
        // A multi-mint token errors here; no network access has happened yet.
        let mint_url = token.mint_url().map_err(|e| {
            FfiErr::new(
                CdkStatus::UnsupportedToken,
                format!("unsupported token (multi-mint or unknown mint): {e}"),
            )
        })?;

        if !self.repo.has_wallet(&mint_url, &UNIT).await {
            return Err(FfiErr::new(
                CdkStatus::TokenUnknownMint,
                "token references a mint that has not been approved",
            ));
        }
        self.guard_prepared_withdrawal(Some(&mint_url))?;
        if self.unresolved.contains(&mint_url) {
            return Err(FfiErr::new(
                CdkStatus::RecoveryPending,
                "this mint has unresolved recovery state; run recovery first",
            ));
        }

        // Validate the token's face value against signed storage *before* any
        // network access (SQLite stores amounts as signed 64-bit integers).
        let face_value = token
            .value()
            .map_err(|e| FfiErr::new(CdkStatus::InvalidToken, format!("invalid token: {e}")))?
            .to_u64();
        ensure_fits_i64(face_value, "token value")?;

        let wallet = self
            .repo
            .get_wallet(&mint_url, &UNIT)
            .await
            .map_err(|e| FfiErr::new(CdkStatus::InternalError, format!("{e}")))?;

        let deadline = self.network_deadline();
        let outcome = timeout(
            deadline,
            wallet.receive(token_str, receive_options(signing_keys)),
        )
        .await;
        self.finish_receive(mint_url, outcome)
    }

    #[cfg(target_arch = "wasm32")]
    pub(crate) fn browser_database(&self) -> &WalletSqliteDatabase {
        &self.db
    }

    #[cfg(target_arch = "wasm32")]
    pub(crate) fn browser_game_signer(&self) -> Option<crate::game_auth::GameSigner> {
        crate::game_auth::GameSigner::derive(self.repo.seed())
    }

    #[cfg(target_arch = "wasm32")]
    pub(crate) async fn browser_funding_keyset(&self, mint: &MintUrl) -> FfiResult<String> {
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        self.guard_prepared_withdrawal(Some(mint))?;
        if self.unresolved.contains(mint) {
            return Err(FfiErr::new(
                CdkStatus::RecoveryPending,
                "mint recovery is pending",
            ));
        }
        let wallet = self.approved_wallet(mint).await?;
        let keyset = timeout(
            self.network_deadline(),
            wallet.active_keyset_with_policy(cdk_common::wallet::KeysetLoadPolicy::Refresh),
        )
        .await
        .map_err(|_| FfiErr::new(CdkStatus::NetworkError, "funding keyset request timed out"))?
        .map_err(|e| map_keyset_error(&e))?;
        keyset_to_json(keyset)
    }

    /// Fetch the mint's active Msat keyset and return it as Spilman keyset JSON.
    ///
    /// The JSON uses the camelCase `KeysetInfo` shape accepted by the Spilman
    /// conversion helpers (`keysetId`, `unit`, `keys`, `amounts`,
    /// `inputFeePpk`, `finalExpiry`).
    pub(crate) async fn active_keyset_info_json(&self, mint_url_str: &str) -> FfiResult<String> {
        let mint_url = parse_mint_url(mint_url_str)?;
        let wallet = self.approved_wallet(&mint_url).await?;
        let deadline = self.network_deadline();
        let keyset = match timeout(deadline, wallet.active_keyset()).await {
            Ok(Ok(keyset)) => keyset,
            Ok(Err(e)) => return Err(map_keyset_error(&e)),
            Err(_) => {
                return Err(FfiErr::new(
                    CdkStatus::NetworkError,
                    "fetching the active keyset exceeded the network deadline",
                ))
            }
        };
        keyset_to_json(keyset)
    }

    /// Fetch a single Msat keyset by id and return it as Spilman keyset JSON.
    pub(crate) async fn keyset_info_json(
        &self,
        mint_url_str: &str,
        keyset_id_str: &str,
    ) -> FfiResult<String> {
        let mint_url = parse_mint_url(mint_url_str)?;
        let keyset_id = Id::from_str(keyset_id_str).map_err(|e| {
            FfiErr::new(
                CdkStatus::InvalidArgument,
                format!("invalid keyset id: {e}"),
            )
        })?;
        let wallet = self.approved_wallet(&mint_url).await?;
        let deadline = self.network_deadline();
        let keyset = match timeout(deadline, wallet.keyset(keyset_id)).await {
            Ok(Ok(keyset)) => keyset,
            Ok(Err(e)) => return Err(map_keyset_error(&e)),
            Err(_) => {
                return Err(FfiErr::new(
                    CdkStatus::NetworkError,
                    "fetching the keyset exceeded the network deadline",
                ))
            }
        };
        keyset_to_json(keyset)
    }

    /// Resolve an approved Msat wallet for `mint_url`.
    async fn approved_wallet(&self, mint_url: &MintUrl) -> FfiResult<Wallet> {
        if !self.repo.has_wallet(mint_url, &UNIT).await {
            return Err(FfiErr::new(
                CdkStatus::MintNotRegistered,
                "mint has not been approved",
            ));
        }
        self.repo
            .get_wallet(mint_url, &UNIT)
            .await
            .map_err(|e| FfiErr::new(CdkStatus::InternalError, format!("{e}")))
    }

    /// Post a raw NUT-03 swap request to a mint and return the raw response JSON.
    ///
    /// This is a stateless conversion helper for Spilman funding/close flows: it
    /// does not touch the local database or the per-mint recovery state, so the
    /// caller owns any persistence of the resulting proofs.
    pub(crate) async fn post_swap(
        &self,
        mint_url_str: &str,
        swap_request_json: &str,
    ) -> FfiResult<String> {
        let mint_url = parse_mint_url(mint_url_str)?;

        if !self.repo.has_wallet(&mint_url, &UNIT).await {
            return Err(FfiErr::new(
                CdkStatus::MintNotRegistered,
                "mint has not been approved",
            ));
        }
        self.guard_prepared_withdrawal(Some(&mint_url))?;
        if self.unresolved.contains(&mint_url) {
            return Err(FfiErr::new(
                CdkStatus::RecoveryPending,
                "this mint has unresolved recovery state; run recovery first",
            ));
        }

        let swap_request: SwapRequest = serde_json::from_str(swap_request_json).map_err(|e| {
            FfiErr::new(
                CdkStatus::InvalidArgument,
                format!("invalid swap request JSON: {e}"),
            )
        })?;
        let client = HttpClient::new(mint_url, None);
        let deadline = self.network_deadline();
        match timeout(deadline, client.post_swap(swap_request)).await {
            Ok(Ok(response)) => serde_json::to_string(&response).map_err(|e| {
                FfiErr::new(
                    CdkStatus::InternalError,
                    format!("could not serialize the swap response: {e}"),
                )
            }),
            Ok(Err(e)) => Err(map_swap_error(&e)),
            Err(_) => Err(FfiErr::new(
                CdkStatus::NetworkError,
                "the swap request exceeded the network deadline",
            )),
        }
    }

    /// Inspect a journaled raw swap without submitting it or touching wallet state.
    pub(crate) async fn recover_swap(
        &self,
        mint_url_str: &str,
        swap_request_json: &str,
    ) -> FfiResult<String> {
        let mint_url = parse_mint_url(mint_url_str)?;
        if !self.repo.has_wallet(&mint_url, &UNIT).await {
            return Err(FfiErr::new(
                CdkStatus::MintNotRegistered,
                "mint has not been approved",
            ));
        }
        let (request, ys) = parse_raw_swap(swap_request_json)?;
        let client = HttpClient::new(mint_url, None);
        let evidence = timeout(self.network_deadline(), async {
            let response = client
                .post_check_state(CheckStateRequest { ys: ys.clone() })
                .await
                .map_err(|_| swap_evidence_error("could not query swap input states"))?;
            let mut states = HashMap::with_capacity(ys.len());
            for entry in response.states {
                if !matches!(entry.state, State::Spent | State::Unspent | State::Pending)
                    || states.insert(entry.y, entry.state).is_some()
                {
                    return Err(swap_evidence_error("invalid swap input states"));
                }
            }
            if states.len() != ys.len() {
                return Err(swap_evidence_error("wrong number of swap input states"));
            }
            let input_states = ys
                .iter()
                .map(|y| {
                    states
                        .get(y)
                        .copied()
                        .ok_or_else(|| swap_evidence_error("missing swap input state"))
                })
                .collect::<FfiResult<Vec<_>>>()?;
            let swap_response = if input_states.iter().all(|state| *state == State::Spent) {
                let restored = client
                    .post_restore(RestoreRequest {
                        outputs: request.outputs().clone(),
                    })
                    .await
                    .map_err(|_| swap_evidence_error("could not restore swap outputs"))?;
                match_swap_restore(request.outputs(), restored)?
            } else {
                None
            };
            Ok::<_, FfiErr>(SwapEvidence {
                input_states,
                swap_response,
            })
        })
        .await
        .map_err(|_| swap_evidence_error("swap recovery exceeded the network deadline"))??;
        serde_json::to_string(&evidence).map_err(|_| {
            FfiErr::new(
                CdkStatus::InternalError,
                "could not serialize swap recovery evidence",
            )
        })
    }

    /// Receive raw proofs from a mint, returning the net Msat amount credited.
    ///
    /// Like [`receive`](Self::receive) but takes already-parsed proofs plus an
    /// explicit mint URL. Fails closed on an ambiguous outcome exactly as
    /// `receive` does.
    pub(crate) async fn receive_proofs(
        &mut self,
        mint_url_str: &str,
        proofs: Proofs,
        signing_keys: &[SecretKey],
    ) -> FfiResult<u64> {
        self.prepare_receive_proofs(mint_url_str, proofs, signing_keys)
            .await?
            .execute()
            .await
    }

    /// Run the wrapper's local checks without starting the CDK receive saga.
    /// The prepared receive holds the exclusive wallet borrow until execution.
    pub(crate) async fn prepare_receive_proofs(
        &mut self,
        mint_url_str: &str,
        proofs: Proofs,
        signing_keys: &[SecretKey],
    ) -> FfiResult<PreparedProofReceive<'_>> {
        let mint_url = parse_mint_url(mint_url_str)?;

        if !self.repo.has_wallet(&mint_url, &UNIT).await {
            return Err(FfiErr::new(
                CdkStatus::MintNotRegistered,
                "mint has not been approved",
            ));
        }
        self.guard_prepared_withdrawal(Some(&mint_url))?;
        if self.unresolved.contains(&mint_url) {
            return Err(FfiErr::new(
                CdkStatus::RecoveryPending,
                "this mint has unresolved recovery state; run recovery first",
            ));
        }

        let face_value = proofs.iter().try_fold(0u64, |total, proof| {
            total.checked_add(u64::from(proof.amount))
        });
        let face_value = face_value
            .ok_or_else(|| FfiErr::new(CdkStatus::InvalidArgument, "proofs value overflows"))?;
        ensure_fits_i64(face_value, "proofs value")?;

        let wallet = self.approved_wallet(&mint_url).await?;
        Ok(PreparedProofReceive {
            owner: self,
            wallet,
            mint_url,
            proofs,
            options: receive_options(signing_keys),
        })
    }

    /// Classify a completed `receive` attempt and apply the fail-closed policy.
    ///
    /// Both [`receive_with_keys`](Self::receive_with_keys) and
    /// [`receive_proofs`](Self::receive_proofs) run the same mint swap, so a
    /// success, a clearly definitive error, an ambiguous error, and a timeout
    /// must be reported identically: ambiguous outcomes and timeouts block the
    /// mint until an explicit recovery run. `outcome` is the timed result of
    /// the swap; its timeout error type is the platform adapter's, so it stays
    /// generic and is only ever observed as "the deadline expired".
    fn finish_receive<E>(
        &mut self,
        mint_url: MintUrl,
        outcome: Result<Result<Amount, CdkError>, E>,
    ) -> FfiResult<u64> {
        match outcome {
            Ok(Ok(amount)) => Ok(amount.to_u64()),
            Ok(Err(e)) => {
                let err = map_receive_error(&e);
                if is_clearly_definitive(&e) {
                    return Err(err);
                }
                // The swap may have partially executed at the mint (HTTP error,
                // malformed response, ...). Fail closed and require an explicit
                // recovery before this mint is used again.
                self.unresolved.insert(mint_url);
                Err(FfiErr::new(
                    err.status,
                    format!(
                        "receive outcome is uncertain; the mint is blocked pending recovery: {e}"
                    ),
                ))
            }
            Err(_) => {
                // The swap may have partially executed; fail closed.
                self.unresolved.insert(mint_url);
                Err(FfiErr::new(
                    CdkStatus::NetworkError,
                    "receive exceeded the network deadline; the mint is blocked pending recovery",
                ))
            }
        }
    }

    /// One-shot send from an explicitly selected mint.
    ///
    /// Prepares the send, compares the total fee against `max_sender_fee_msats`
    /// (cancelling if exceeded), then confirms. Ambiguous outcomes are reported
    /// as [`CdkStatus::SendUncertain`] and the mint is marked unresolved; the
    /// call is never retried automatically.
    pub(crate) async fn send(
        &mut self,
        mint_url_str: &str,
        amount_msats: u64,
        max_sender_fee_msats: u64,
    ) -> FfiResult<SendOutcome> {
        self.send_inner(mint_url_str, amount_msats, max_sender_fee_msats, None)
            .await
    }

    pub(crate) async fn send_bounded(
        &mut self,
        mint_url_str: &str,
        amount_msats: u64,
        max_token_bytes: usize,
    ) -> FfiResult<SendOutcome> {
        self.send_inner(mint_url_str, amount_msats, 0, Some(max_token_bytes))
            .await
    }

    async fn send_inner(
        &mut self,
        mint_url_str: &str,
        amount_msats: u64,
        max_sender_fee_msats: u64,
        max_token_bytes: Option<usize>,
    ) -> FfiResult<SendOutcome> {
        let mint_url = parse_mint_url(mint_url_str)?;

        // Validate every caller-provided value locally, before any network use.
        if amount_msats == 0 {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "send amount must be greater than zero",
            ));
        }
        ensure_fits_i64(amount_msats, "send amount")?;
        ensure_fits_i64(max_sender_fee_msats, "maximum sender fee")?;

        if !self.repo.has_wallet(&mint_url, &UNIT).await {
            return Err(FfiErr::new(
                CdkStatus::MintNotRegistered,
                "mint has not been approved",
            ));
        }
        self.guard_prepared_withdrawal(Some(&mint_url))?;
        if self.unresolved.contains(&mint_url) {
            return Err(FfiErr::new(
                CdkStatus::RecoveryPending,
                "this mint has unresolved recovery state; run recovery first",
            ));
        }

        let wallet = self
            .repo
            .get_wallet(&mint_url, &UNIT)
            .await
            .map_err(|e| FfiErr::new(CdkStatus::InternalError, format!("{e}")))?;

        let opts = SendOptions {
            send_kind: if max_token_bytes.is_some() {
                SendKind::OfflineExact
            } else {
                SendKind::OnlineExact
            },
            include_fee: false,
            ..SendOptions::default()
        };

        let deadline = self.network_deadline();
        let prepared = match timeout(
            deadline,
            wallet.prepare_send(Amount::from(amount_msats), opts),
        )
        .await
        {
            Ok(Ok(prepared)) => prepared,
            Ok(Err(e)) => {
                if is_clearly_definitive(&e) {
                    return Err(map_prepare_error(&e));
                }
                // Preparation reserves proofs; a non-definitive failure may
                // leave a partial saga. Fail closed and never retry blindly.
                self.unresolved.insert(mint_url);
                return Err(FfiErr::new(
                    CdkStatus::SendUncertain,
                    format!(
                        "send preparation outcome is uncertain; the mint is blocked pending recovery: {e}"
                    ),
                ));
            }
            Err(_) => {
                self.unresolved.insert(mint_url);
                return Err(FfiErr::new(
                    CdkStatus::SendUncertain,
                    "send preparation exceeded the network deadline; the mint is blocked pending recovery",
                ));
            }
        };

        let operation_id = *prepared.operation_id().as_bytes();
        let total_fee = prepared.fee().to_u64();

        // From here on, every failure must release the prepared reservations
        // through the same explicit cancellation path.
        let overflow = match amount_msats.checked_add(total_fee) {
            Some(total) => total > i64::MAX as u64,
            None => true,
        };
        if overflow {
            return Err(self
                .cancel_prepared(
                    prepared,
                    &mint_url,
                    operation_id,
                    total_fee,
                    CdkStatus::InvalidArgument,
                    "send amount plus fee overflows the supported range".to_string(),
                )
                .await);
        }

        if total_fee > max_sender_fee_msats {
            return Err(self
                .cancel_prepared(
                    prepared,
                    &mint_url,
                    operation_id,
                    total_fee,
                    CdkStatus::FeeLimitExceeded,
                    format!(
                        "send fee {total_fee} msats exceeds the maximum of {max_sender_fee_msats} msats"
                    ),
                )
                .await);
        }

        if let Some(limit) = max_token_bytes {
            let refusal = if !prepared.proofs_to_swap().is_empty() {
                Some("bounded send requires exact proofs without a swap")
            } else {
                // With no swap, no memo, and the default Swap (not SignAndSend)
                // policy, CDK confirms with these same proofs and token fields.
                // Keyset group ordering can vary, but not the encoded length.
                let token = Token::new(
                    wallet.mint_url.clone(),
                    prepared.proofs_to_send().clone(),
                    None,
                    wallet.unit.clone(),
                )
                .to_string();
                (token.len() > limit).then_some("serialized token exceeds the byte limit")
            };
            if let Some(message) = refusal {
                return Err(self
                    .cancel_prepared(
                        prepared,
                        &mint_url,
                        operation_id,
                        total_fee,
                        CdkStatus::SendFailed,
                        message.to_string(),
                    )
                    .await);
            }
        }

        match timeout(deadline, prepared.confirm(None)).await {
            Ok(Ok(token)) => Ok(SendOutcome {
                token: token.to_string(),
                operation_id,
                sender_fee_msats: total_fee,
            }),
            Ok(Err(e)) => {
                if e.is_definitive_failure() {
                    Err(FfiErr::with_op(
                        CdkStatus::SendFailed,
                        format!("send definitively failed: {e}"),
                        operation_id,
                        total_fee,
                    ))
                } else {
                    self.unresolved.insert(mint_url);
                    Err(FfiErr::with_op(
                        CdkStatus::SendUncertain,
                        format!("send outcome is uncertain; do not retry blindly: {e}"),
                        operation_id,
                        total_fee,
                    ))
                }
            }
            Err(_) => {
                self.unresolved.insert(mint_url);
                Err(FfiErr::with_op(
                    CdkStatus::SendUncertain,
                    "send exceeded the network deadline; the outcome is uncertain and the mint is blocked pending recovery",
                    operation_id,
                    total_fee,
                ))
            }
        }
    }

    /// Cancel a prepared send and map the outcome.
    ///
    /// Every failure that happens *after* `prepare_send` succeeded goes through
    /// here, so reserved proofs are always released (or the mint is fail-closed
    /// when cancellation itself fails).
    async fn cancel_prepared(
        &mut self,
        prepared: PreparedSend<'_>,
        mint_url: &MintUrl,
        operation_id: [u8; 16],
        total_fee: u64,
        status: CdkStatus,
        message: String,
    ) -> FfiErr {
        let deadline = self.network_deadline();
        match timeout(deadline, prepared.cancel()).await {
            Ok(Ok(())) => FfiErr::with_op(status, message, operation_id, total_fee),
            Ok(Err(e)) => {
                self.unresolved.insert(mint_url.clone());
                FfiErr::with_op(
                    CdkStatus::CancellationFailed,
                    format!(
                        "failed to cancel the send after a validation failure: {e} ({message})"
                    ),
                    operation_id,
                    total_fee,
                )
            }
            Err(_) => {
                self.unresolved.insert(mint_url.clone());
                FfiErr::with_op(
                    CdkStatus::CancellationFailed,
                    format!(
                        "cancelling the send after a validation failure exceeded the network deadline ({message})"
                    ),
                    operation_id,
                    total_fee,
                )
            }
        }
    }

    /// List pending outgoing tokens (created but not claimed) with their ids.
    pub(crate) async fn list_pending_tokens(&self) -> FfiResult<Vec<PendingToken>> {
        let mut out = Vec::new();
        for wallet in self.repo.get_wallets().await {
            if wallet.unit != UNIT {
                continue;
            }
            let ids = wallet.get_pending_sends().await.map_err(db_error)?;
            for id in ids {
                if let Some(token) = self.pending_token_for(&id).await? {
                    out.push(token);
                }
            }
        }
        Ok(out)
    }

    /// Retrieve a single pending outgoing token by operation id.
    pub(crate) async fn get_pending_token(&self, operation_id: &[u8]) -> FfiResult<PendingToken> {
        let id = Uuid::from_slice(operation_id).map_err(|_| {
            FfiErr::new(CdkStatus::InvalidArgument, "operation id must be 16 bytes")
        })?;
        self.pending_token_for(&id).await?.ok_or_else(|| {
            FfiErr::new(CdkStatus::OperationNotFound, "no pending send with that id")
        })
    }

    /// Internal helper: fetch and validate a single pending send saga.
    async fn pending_token_for(&self, id: &Uuid) -> FfiResult<Option<PendingToken>> {
        let saga = match self.db.get_saga(id).await.map_err(db_error)? {
            Some(saga) => saga,
            None => return Ok(None),
        };
        if !matches!(
            saga.state,
            WalletSagaState::Send(cdk_common::wallet::SendSagaState::TokenCreated)
        ) {
            return Ok(None);
        }
        if saga.unit != UNIT || !self.repo.has_wallet(&saga.mint_url, &UNIT).await {
            return Ok(None);
        }
        match saga.data {
            OperationData::Send(data) => Ok(data.token.map(|token| PendingToken {
                operation_id: *id.as_bytes(),
                token,
            })),
            _ => Ok(None),
        }
    }

    /// Run recovery for every approved Msat wallet, or just one mint.
    ///
    /// Updates the per-mint unresolved set and returns one report per mint.
    /// Diagnostics are returned to the caller; nothing is written to stderr.
    pub(crate) async fn run_recovery(
        &mut self,
        mint: Option<&MintUrl>,
    ) -> FfiResult<Vec<MintRecoveryReport>> {
        self.guard_prepared_withdrawal(mint)?;
        let wallets: Vec<Wallet> = self
            .repo
            .get_wallets()
            .await
            .into_iter()
            .filter(|w| w.unit == UNIT)
            .filter(|w| mint.map(|m| &w.mint_url == m).unwrap_or(true))
            .collect();

        if let Some(m) = mint {
            if wallets.is_empty() {
                return Err(FfiErr::new(
                    CdkStatus::MintNotRegistered,
                    format!("mint {m} is not registered with this wallet"),
                ));
            }
        }

        let deadline = self.recovery_deadline();
        let mut reports = Vec::with_capacity(wallets.len());
        for wallet in wallets {
            let report = match timeout(deadline, wallet.recover_incomplete_sagas()).await {
                Ok(Ok(report)) => {
                    let failed = report.failed as u32;
                    let skipped = report.skipped as u32;
                    if report.failed > 0 || report.skipped > 0 {
                        self.unresolved.insert(wallet.mint_url.clone());
                    } else {
                        self.unresolved.remove(&wallet.mint_url);
                    }
                    MintRecoveryReport {
                        mint_url: wallet.mint_url.to_string(),
                        recovered: report.recovered as u32,
                        compensated: report.compensated as u32,
                        skipped,
                        failed,
                        status: CdkStatus::Ok,
                        message: recovery_diagnostic(failed, skipped),
                    }
                }
                Ok(Err(e)) => {
                    self.unresolved.insert(wallet.mint_url.clone());
                    MintRecoveryReport {
                        mint_url: wallet.mint_url.to_string(),
                        recovered: 0,
                        compensated: 0,
                        skipped: 0,
                        failed: 1,
                        status: map_recovery_error(&e),
                        message: Some(format!("recovery failed: {e}")),
                    }
                }
                Err(_) => {
                    self.unresolved.insert(wallet.mint_url.clone());
                    MintRecoveryReport {
                        mint_url: wallet.mint_url.to_string(),
                        recovered: 0,
                        compensated: 0,
                        skipped: 0,
                        failed: 1,
                        status: CdkStatus::NetworkError,
                        message: Some("recovery exceeded the deadline for this mint".to_string()),
                    }
                }
            };
            reports.push(report);
        }
        Ok(reports)
    }

    /// Explicit recovery entry point; returns one report per mint.
    pub(crate) async fn recover(
        &mut self,
        mint: Option<&MintUrl>,
    ) -> FfiResult<Vec<MintRecoveryReport>> {
        self.run_recovery(mint).await
    }
}

/// Test-only helpers. They are never exported through the C ABI.
#[cfg(test)]
impl CdkWallet {
    /// Override the network and recovery deadlines for this handle.
    pub(crate) fn set_test_deadlines(&mut self, network: Duration, recovery: Duration) {
        self.test_network_deadline = Some(network);
        self.test_recovery_deadline = Some(recovery);
    }

    /// Reserve proofs for a send, then drop the prepared send without confirming
    /// or cancelling, simulating a crash mid-send.
    pub(crate) async fn test_interrupt_prepare(
        &mut self,
        mint_url_str: &str,
        amount_msats: u64,
    ) -> FfiResult<()> {
        let mint_url = parse_mint_url(mint_url_str)?;
        let wallet = self
            .repo
            .get_wallet(&mint_url, &UNIT)
            .await
            .map_err(|e| FfiErr::new(CdkStatus::InternalError, format!("{e}")))?;
        let opts = SendOptions {
            send_kind: SendKind::OnlineExact,
            include_fee: false,
            ..SendOptions::default()
        };
        let prepared = wallet
            .prepare_send(Amount::from(amount_msats), opts)
            .await
            .map_err(|e| map_prepare_error(&e))?;
        // Drop without confirm/cancel: the persisted saga and its reserved
        // proofs survive, exactly like a crash.
        drop(prepared);
        Ok(())
    }
}

/// A successful send outcome.
pub(crate) struct SendOutcome {
    /// The bearer token. Secret.
    pub token: String,
    /// 16 raw UUID bytes identifying the operation.
    pub operation_id: [u8; 16],
    /// Total fee charged for the send, in msats.
    pub sender_fee_msats: u64,
}

impl std::fmt::Debug for SendOutcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SendOutcome")
            .field("token", &"<redacted>")
            .field("operation_id", &self.operation_id)
            .field("sender_fee_msats", &self.sender_fee_msats)
            .finish()
    }
}

/// A pending outgoing token.
pub(crate) struct PendingToken {
    /// 16 raw UUID bytes identifying the operation.
    pub operation_id: [u8; 16],
    /// The bearer token. Secret.
    pub token: String,
}

impl std::fmt::Debug for PendingToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PendingToken")
            .field("operation_id", &self.operation_id)
            .field("token", &"<redacted>")
            .finish()
    }
}

/// Compute the domain-separated SHA-256 fingerprint of the seed.
///
/// Uses the hash engine directly so no seed-sized buffer is ever allocated.
pub(crate) fn seed_fingerprint(seed: &[u8]) -> [u8; 32] {
    let mut engine = sha256::Hash::engine();
    engine.input(FINGERPRINT_PREFIX);
    engine.input(seed);
    sha256::Hash::from_engine(engine).to_byte_array()
}

/// Acquire the wrapper's exclusive per-database lock for the handle lifetime.
///
/// Linux uses `flock(2)` (`File::try_lock`). Flock locks are tied to the open
/// file description, so a second handle - in this process, another process, or
/// via a hard-link alias - is rejected, and dropping the file releases the lock.
/// Linux keeps `flock` and SQLite's `fcntl` byte-range locks independent, so
/// both can coexist on the same database file.
#[cfg(all(not(target_arch = "wasm32"), target_os = "linux"))]
fn acquire_database_lock(file: &File) -> FfiResult<()> {
    file.try_lock().map_err(|e| {
        FfiErr::new(
            CdkStatus::AlreadyOpen,
            format!("database is already open by another handle: {e}"),
        )
    })
}

/// macOS keeps `flock` and `fcntl` locks in the same per-vnode list, so
/// flocking the database would make SQLite's own `fcntl` locks fail with
/// "database is locked". macOS therefore takes an open-file-description lock
/// (`F_OFD_SETLK`) instead. OFD locks are attached to the open file description,
/// so a second handle - even in the same process or via a hard link - still
/// conflicts, and closing the fd releases the lock. A plain POSIX `F_SETLK`
/// would not work here: POSIX locks are per-process, so a second handle in the
/// same process would silently succeed. SQLite's own whole-file `F_UNLCK` is
/// POSIX-owned and does not clear this OFD lock.
#[cfg(all(not(target_arch = "wasm32"), target_os = "macos"))]
fn acquire_database_lock(file: &File) -> FfiResult<()> {
    ofd_try_lock(file).map_err(|e| match e.raw_os_error() {
        Some(libc::EACCES) | Some(libc::EAGAIN) => FfiErr::new(
            CdkStatus::AlreadyOpen,
            format!("database is already open by another handle: {e}"),
        ),
        // Fail closed: an unsupported kernel/filesystem must not silently drop
        // the one-live-handle guarantee.
        _ => FfiErr::new(
            CdkStatus::DatabaseError,
            format!("could not take the required macOS database lock (F_OFD_SETLK): {e}"),
        ),
    })
}

#[cfg(all(
    not(target_arch = "wasm32"),
    not(target_os = "linux"),
    not(target_os = "macos")
))]
fn acquire_database_lock(_file: &File) -> FfiResult<()> {
    Err(FfiErr::new(
        CdkStatus::DatabaseError,
        "database locking is only implemented for Linux and macOS",
    ))
}

/// Byte 0 is outside SQLite's reserved lock range. SQLite locks
/// `PENDING_BYTE = 0x40000000` through `0x400001ff` (pending/reserved bytes plus
/// the 510-byte shared range), so a one-byte wrapper lock at offset 0 can never
/// overlap SQLite's own locks.
#[cfg(all(not(target_arch = "wasm32"), target_os = "macos"))]
const WRAPPER_LOCK_BYTE: libc::off_t = 0;
#[cfg(all(not(target_arch = "wasm32"), target_os = "macos"))]
const WRAPPER_LOCK_LEN: libc::off_t = 1;

/// Take a non-blocking exclusive open-file-description lock on the database.
#[cfg(all(not(target_arch = "wasm32"), target_os = "macos"))]
fn ofd_try_lock(file: &File) -> io::Result<()> {
    use std::os::unix::io::AsRawFd;

    let lock = libc::flock {
        l_start: WRAPPER_LOCK_BYTE,
        l_len: WRAPPER_LOCK_LEN,
        l_pid: 0,
        l_type: libc::F_WRLCK as libc::c_short,
        l_whence: libc::SEEK_SET as libc::c_short,
    };
    // SAFETY: `file` owns a valid descriptor for the duration of the call, and
    // `lock` is a fully initialized `struct flock` for `F_OFD_SETLK`. The lock
    // is advisory and never dereferences user memory.
    let result = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_OFD_SETLK, &lock) };
    if result == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// Create any missing parent directories of `path` with owner-only (0700)
/// permissions. Existing directories are never re-permissioned.
#[cfg(not(target_arch = "wasm32"))]
fn ensure_parent_dirs(path: &Path) -> FfiResult<()> {
    let Some(parent) = path.parent() else {
        return Ok(());
    };
    if parent.as_os_str().is_empty() || parent.is_dir() {
        return Ok(());
    }

    let mut missing: Vec<PathBuf> = Vec::new();
    let mut cur = parent;
    while !cur.exists() {
        missing.push(cur.to_path_buf());
        match cur.parent() {
            Some(p) if !p.as_os_str().is_empty() => cur = p,
            _ => break,
        }
    }

    for dir in missing.iter().rev() {
        match DirBuilder::new().mode(0o700).create(dir) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(e) => {
                return Err(FfiErr::new(
                    CdkStatus::InvalidPath,
                    format!("could not create parent directory {}: {e}", dir.display()),
                ))
            }
        }
    }
    Ok(())
}

/// Validate the opened database file (via `fstat`): it must be a regular file.
#[cfg(not(target_arch = "wasm32"))]
fn check_regular_file(file: &File) -> FfiResult<()> {
    let meta = file.metadata().map_err(|e| {
        FfiErr::new(
            CdkStatus::InvalidPath,
            format!("could not stat the database file: {e}"),
        )
    })?;
    if !meta.file_type().is_file() {
        return Err(FfiErr::new(
            CdkStatus::InvalidPath,
            "database path is not a regular file",
        ));
    }
    Ok(())
}

/// Reject an inherited database whose group/other permissions are non-zero.
///
/// The file is never chmod-ed silently; the caller must fix the permissions.
/// On macOS, any extended ACL object returned for the opened descriptor is also
/// rejected, including deny-only ACLs: with mode 0600 an ACL is the only way to
/// grant another principal access, and we cannot safely reason about every
/// inherited variant. A descriptor-based query avoids following a path.
#[cfg(not(target_arch = "wasm32"))]
fn check_permissions(file: &File) -> FfiResult<()> {
    let meta = file.metadata().map_err(|e| {
        FfiErr::new(
            CdkStatus::InvalidPath,
            format!("could not stat the database file: {e}"),
        )
    })?;
    let mode = meta.mode();
    if mode & 0o077 != 0 {
        return Err(FfiErr::new(
            CdkStatus::InsecureDatabasePermissions,
            format!(
                "database file permissions are too broad (mode {:o}); restrict it to owner-only (0600)",
                mode & 0o777
            ),
        ));
    }

    #[cfg(target_os = "macos")]
    if macos_acl::has_extended_acl(file).map_err(|e| {
        FfiErr::new(
            CdkStatus::InsecureDatabasePermissions,
            format!("could not inspect the database extended ACL: {e}"),
        )
    })? {
        return Err(FfiErr::new(
            CdkStatus::InsecureDatabasePermissions,
            "database file has an extended ACL; remove it and keep the file owner-only (0600)",
        ));
    }

    Ok(())
}

/// Classify a NULL `acl_get_fd_np` result.
///
/// macOS Libc reports "no extended ACL" as `ENOENT`; only that status proves
/// absence. A NULL result with errno 0 (or no errno) is an uninspectable
/// outcome and must fail closed, as must any other errno.
#[cfg(all(not(target_arch = "wasm32"), any(target_os = "macos", test)))]
fn classify_null_acl(errno: Option<libc::c_int>) -> io::Result<bool> {
    match errno {
        Some(libc::ENOENT) => Ok(false),
        Some(0) | None => Err(io::Error::new(
            io::ErrorKind::Other,
            "acl_get_fd_np returned NULL without a usable errno",
        )),
        Some(code) => Err(io::Error::from_raw_os_error(code)),
    }
}

/// Minimal, descriptor-based macOS extended-ACL probe.
///
/// `acl_get_fd_np(fd, ACL_TYPE_EXTENDED)` is the documented ACL API and operates
/// on the already-open database descriptor, so no path is followed here. Darwin
/// returns NULL with ENOENT when no extended ACL is present. Any returned ACL
/// object is treated as unsafe, including a deny-only ACL, to fail closed on
/// inherited or principal-specific grants. A NULL result without ENOENT is an
/// inspection error and also fails closed.
#[cfg(target_os = "macos")]
mod macos_acl {
    use super::{classify_null_acl, io, File};
    use std::os::unix::io::AsRawFd;

    const ACL_TYPE_EXTENDED: libc::c_int = 0x0000_0100;

    unsafe extern "C" {
        fn acl_get_fd_np(fd: libc::c_int, acl_type: libc::c_int) -> *mut libc::c_void;
        fn acl_free(obj: *mut libc::c_void) -> libc::c_int;
    }

    /// Owns an ACL allocated by acl_get_fd_np for the duration of the probe.
    struct OwnedAcl(*mut libc::c_void);

    impl Drop for OwnedAcl {
        fn drop(&mut self) {
            // SAFETY: `self.0` is non-null and came from acl_get_fd_np; it is
            // released exactly once, here.
            let _ = unsafe { acl_free(self.0) };
        }
    }

    pub(super) fn has_extended_acl(file: &File) -> io::Result<bool> {
        has_extended_acl_fd(file.as_raw_fd())
    }

    fn has_extended_acl_fd(fd: libc::c_int) -> io::Result<bool> {
        // SAFETY: libc's `__error()` returns the current thread's errno pointer.
        unsafe { *libc::__error() = 0 };

        // SAFETY: `fd` is passed to the kernel; acl_get_fd_np does not follow a
        // path and returns either NULL or an allocated ACL requiring acl_free.
        let acl = unsafe { acl_get_fd_np(fd, ACL_TYPE_EXTENDED) };
        if acl.is_null() {
            return classify_null_acl(io::Error::last_os_error().raw_os_error());
        }

        let _owned = OwnedAcl(acl);
        Ok(true)
    }

    #[cfg(all(test, target_os = "macos"))]
    mod tests {
        use super::has_extended_acl_fd;
        use std::os::unix::io::AsRawFd;

        #[test]
        fn ordinary_file_has_no_extended_acl() {
            let file = tempfile::tempfile().unwrap();
            assert!(!has_extended_acl_fd(file.as_raw_fd()).unwrap());
        }

        #[test]
        fn invalid_descriptor_fails_closed() {
            let error = has_extended_acl_fd(-1).unwrap_err();
            assert_eq!(error.raw_os_error(), Some(libc::EBADF));
        }
    }
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod acl_classifier_tests {
    use super::classify_null_acl;

    #[test]
    fn enoent_is_the_only_no_acl_classification() {
        assert!(!classify_null_acl(Some(libc::ENOENT)).unwrap());
    }

    #[test]
    fn null_with_errno_zero_is_an_inspection_error() {
        let error = classify_null_acl(Some(0)).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::Other);
        assert!(error.to_string().contains("without a usable errno"));
    }

    #[test]
    fn null_without_errno_is_an_inspection_error() {
        assert!(classify_null_acl(None).is_err());
    }

    #[test]
    fn real_errno_is_preserved_and_rejected() {
        let error = classify_null_acl(Some(libc::EACCES)).unwrap_err();
        assert_eq!(error.raw_os_error(), Some(libc::EACCES));
    }
}

/// Validate an existing database's marker **read-only**, before migrations.
///
/// Never mutates the file. A missing/truncated marker is reported as
/// `UnsupportedDatabase` (not `SeedMismatch`), an incompatible version as
/// `UnsupportedFormatVersion`, and only a genuine fingerprint mismatch as
/// `SeedMismatch`.
#[cfg(not(target_arch = "wasm32"))]
fn validate_existing_marker(path: &Path, seed: &[u8; 64]) -> FfiResult<()> {
    let conn =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|e| {
                FfiErr::new(
                    CdkStatus::UnsupportedDatabase,
                    format!("existing database is not a readable SQLite database: {e}"),
                )
            })?;

    let value: Option<Vec<u8>> = conn
        .query_row(
            "SELECT value FROM kv_store \
             WHERE primary_namespace = ?1 AND secondary_namespace = ?2 AND key = ?3",
            rusqlite::params![KV_NAMESPACE, "", KEY_MARKER],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| {
            FfiErr::new(
                CdkStatus::UnsupportedDatabase,
                format!("existing database was not created by cdk-wallet-ffi: {e}"),
            )
        })?;

    let Some(value) = value else {
        return Err(FfiErr::new(
            CdkStatus::UnsupportedDatabase,
            "existing database was not created by cdk-wallet-ffi (missing marker)",
        ));
    };

    if value.len() != MARKER_LEN {
        return Err(FfiErr::new(
            CdkStatus::UnsupportedDatabase,
            format!(
                "existing database has a truncated wrapper marker ({} bytes, expected {MARKER_LEN})",
                value.len()
            ),
        ));
    }

    let version = u32::from_le_bytes(value[..4].try_into().expect("4 bytes"));
    if version != FORMAT_VERSION {
        return Err(FfiErr::new(
            CdkStatus::UnsupportedFormatVersion,
            format!("database was written by an incompatible wrapper format version: {version}"),
        ));
    }

    if value[4..] != seed_fingerprint(seed) {
        return Err(FfiErr::new(
            CdkStatus::SeedMismatch,
            "the provided seed does not match this database",
        ));
    }
    Ok(())
}

/// Map a database error onto [`CdkStatus::DatabaseError`].
fn db_error<E: std::fmt::Display>(e: E) -> FfiErr {
    FfiErr::new(CdkStatus::DatabaseError, format!("database error: {e}"))
}

/// Reject values that cannot be stored as a signed 64-bit integer (SQLite's
/// amount representation) before they ever reach the database or the network.
fn ensure_fits_i64(value: u64, what: &str) -> FfiResult<()> {
    if value > i64::MAX as u64 {
        return Err(FfiErr::new(
            CdkStatus::InvalidArgument,
            format!("{what} exceeds the maximum supported value"),
        ));
    }
    Ok(())
}

/// Whether a mutation error is clearly local/definitive, so the mint does not
/// need to be fail-closed.
///
/// `InsufficientFunds` is treated as local even though upstream's catch-all
/// classifies it as ambiguous: it is a local balance check and must not wedge a
/// mint the caller can still legitimately use.
fn is_clearly_definitive(e: &CdkError) -> bool {
    matches!(e, CdkError::InsufficientFunds) || e.is_definitive_failure()
}

/// Honest diagnostic for a recovery that left sagas skipped or failed.
fn recovery_diagnostic(failed: u32, skipped: u32) -> Option<String> {
    if failed > 0 {
        Some(format!(
            "{failed} saga(s) could not be recovered; the mint stays blocked until a later recovery succeeds"
        ))
    } else if skipped > 0 {
        Some(format!(
            "{skipped} saga(s) are still unresolved; the mint stays blocked until a later recovery succeeds"
        ))
    } else {
        None
    }
}

/// Map a `receive` failure onto a status.
fn map_receive_error(e: &CdkError) -> FfiErr {
    let status = match e {
        CdkError::InsufficientFunds => CdkStatus::InsufficientFunds,
        CdkError::TokenAlreadySpent | CdkError::UnexpectedProofState => CdkStatus::InvalidToken,
        CdkError::IncorrectMint | CdkError::UnknownMint { .. } => CdkStatus::TokenUnknownMint,
        CdkError::UnsupportedUnit | CdkError::UnitMismatch => CdkStatus::UnsupportedToken,
        CdkError::HttpError(..) | CdkError::Timeout => CdkStatus::NetworkError,
        CdkError::Database(_) => CdkStatus::DatabaseError,
        _ => CdkStatus::ReceiveFailed,
    };
    FfiErr::new(status, format!("receive failed: {e}"))
}

/// Map a `prepare_send` failure onto a status.
fn map_prepare_error(e: &CdkError) -> FfiErr {
    let status = match e {
        CdkError::InsufficientFunds => CdkStatus::InsufficientFunds,
        CdkError::UnknownWallet(_) => CdkStatus::MintNotRegistered,
        CdkError::HttpError(..) | CdkError::Timeout => CdkStatus::NetworkError,
        CdkError::Database(_) => CdkStatus::DatabaseError,
        CdkError::AmountOverflow | CdkError::SplitValuesGreater => CdkStatus::InvalidArgument,
        _ => CdkStatus::SendFailed,
    };
    FfiErr::new(status, format!("could not prepare send: {e}"))
}

pub(crate) struct PreparedProofReceive<'a> {
    owner: &'a mut CdkWallet,
    wallet: Wallet,
    mint_url: MintUrl,
    proofs: Proofs,
    options: ReceiveOptions,
}

impl PreparedProofReceive<'_> {
    #[cfg(target_arch = "wasm32")]
    pub(crate) fn owner(&self) -> &CdkWallet {
        self.owner
    }

    pub(crate) async fn execute(self) -> FfiResult<u64> {
        let outcome = timeout(
            self.owner.network_deadline(),
            self.wallet
                .receive_proofs(self.proofs, self.options, None, None),
        )
        .await;
        self.owner.finish_receive(self.mint_url, outcome)
    }
}

/// Build [`ReceiveOptions`] carrying the caller-supplied P2PK signing keys.
fn receive_options(signing_keys: &[SecretKey]) -> ReceiveOptions {
    ReceiveOptions {
        p2pk_signing_keys: signing_keys.to_vec(),
        ..Default::default()
    }
}

/// Convert a CDK [`KeySet`](cdk::nuts::KeySet) into Spilman `KeysetInfo` JSON.
fn keyset_to_json(keyset: cdk::nuts::KeySet) -> FfiResult<String> {
    if keyset.unit != UNIT {
        return Err(FfiErr::new(
            CdkStatus::MintUnsupportedUnit,
            "keyset is not denominated in msat",
        ));
    }
    let info = cdk_spilman::KeysetInfo::new(
        keyset.id,
        keyset.unit,
        keyset.keys,
        keyset.input_fee_ppk,
        keyset.final_expiry,
    );
    serde_json::to_string(&info).map_err(|e| {
        FfiErr::new(
            CdkStatus::InternalError,
            format!("could not serialize keyset info: {e}"),
        )
    })
}

/// Map a keyset-load failure onto a status.
fn map_keyset_error(e: &CdkError) -> FfiErr {
    let status = match e {
        CdkError::HttpError(..) | CdkError::Timeout => CdkStatus::NetworkError,
        CdkError::Database(_) => CdkStatus::DatabaseError,
        CdkError::UnknownKeySet | CdkError::KeysetUnknown(_) | CdkError::NoActiveKeyset => {
            CdkStatus::InvalidArgument
        }
        _ => CdkStatus::InternalError,
    };
    FfiErr::new(status, format!("could not load keyset info: {e}"))
}

/// Map a raw swap-post failure onto a status.
fn map_swap_error(e: &CdkError) -> FfiErr {
    let status = match e {
        CdkError::HttpError(..) | CdkError::Timeout => CdkStatus::NetworkError,
        CdkError::Database(_) => CdkStatus::DatabaseError,
        CdkError::TokenAlreadySpent | CdkError::UnexpectedProofState => CdkStatus::InvalidToken,
        _ => CdkStatus::ReceiveFailed,
    };
    FfiErr::new(status, format!("swap request failed: {e}"))
}

#[derive(serde::Serialize)]
struct SwapEvidence {
    input_states: Vec<State>,
    swap_response: Option<SwapResponse>,
}

fn parse_raw_swap(json: &str) -> FfiResult<(SwapRequest, Vec<PublicKey>)> {
    let invalid = |message| FfiErr::new(CdkStatus::InvalidArgument, message);
    let request: SwapRequest =
        serde_json::from_str(json).map_err(|_| invalid("invalid swap request JSON"))?;
    if request.inputs().is_empty() || request.outputs().is_empty() {
        return Err(invalid("swap requires both inputs and outputs"));
    }
    let ys = request
        .inputs()
        .iter()
        .map(|proof| {
            proof
                .y()
                .map_err(|_| invalid("could not derive swap input Y"))
        })
        .collect::<FfiResult<Vec<_>>>()?;
    if ys.iter().collect::<BTreeSet<_>>().len() != ys.len()
        || request
            .outputs()
            .iter()
            .map(|output| &output.blinded_secret)
            .collect::<BTreeSet<_>>()
            .len()
            != request.outputs().len()
    {
        return Err(invalid("swap contains duplicate inputs or blinded outputs"));
    }
    Ok((request, ys))
}

fn swap_evidence_error(message: &'static str) -> FfiErr {
    FfiErr::new(CdkStatus::NetworkError, message)
}

fn signature_matches_output(signature: &BlindSignature, output: &BlindedMessage) -> bool {
    signature.amount == output.amount && signature.keyset_id == output.keyset_id
}

pub(crate) fn match_swap_restore(
    outputs: &[BlindedMessage],
    response: RestoreResponse,
) -> FfiResult<Option<SwapResponse>> {
    if response.outputs.len() != response.signatures.len() || response.outputs.len() > outputs.len()
    {
        return Err(swap_evidence_error("invalid swap restore counts"));
    }
    let positions: HashMap<_, _> = outputs
        .iter()
        .enumerate()
        .map(|(i, output)| (output.blinded_secret, i))
        .collect();
    let mut ordered = vec![None; outputs.len()];
    for (output, signature) in response.outputs.into_iter().zip(response.signatures) {
        let i = *positions
            .get(&output.blinded_secret)
            .ok_or_else(|| swap_evidence_error("unexpected restored swap output"))?;
        let expected = &outputs[i];
        if output.amount != expected.amount
            || output.keyset_id != expected.keyset_id
            || !signature_matches_output(&signature, expected)
            || ordered[i].replace(signature).is_some()
        {
            return Err(swap_evidence_error(
                "invalid restored swap output or signature",
            ));
        }
    }
    Ok(ordered
        .into_iter()
        .collect::<Option<Vec<_>>>()
        .map(SwapResponse::new))
}

/// Map a recovery-call failure onto a status.
fn map_recovery_error(e: &CdkError) -> CdkStatus {
    match e {
        CdkError::HttpError(..) | CdkError::Timeout => CdkStatus::NetworkError,
        CdkError::Database(_) => CdkStatus::DatabaseError,
        _ => CdkStatus::InternalError,
    }
}

/// Validate an HTTP(S) mint URL against the wrapper's endpoint policy.
///
/// The CDK [`MintUrl`] parser is intentionally lenient, so this adds the
/// policy the project requires: only `https`, or `http` for localhost, no
/// credentials, and no fragment.
pub(crate) fn parse_mint_url(raw: &str) -> FfiResult<MintUrl> {
    let parsed = url::Url::parse(raw)
        .map_err(|e| FfiErr::new(CdkStatus::InvalidMintUrl, format!("invalid mint URL: {e}")))?;

    match parsed.scheme() {
        "https" => {}
        "http" => {
            let host = parsed.host_str().unwrap_or("");
            let is_localhost =
                host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]";
            if !is_localhost {
                return Err(FfiErr::new(
                    CdkStatus::InvalidMintUrl,
                    "plain http is only allowed for localhost",
                ));
            }
        }
        other => {
            return Err(FfiErr::new(
                CdkStatus::InvalidMintUrl,
                format!("unsupported URL scheme: {other}"),
            ));
        }
    }

    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(FfiErr::new(
            CdkStatus::InvalidMintUrl,
            "mint URL must not contain credentials",
        ));
    }
    if parsed.fragment().is_some() {
        return Err(FfiErr::new(
            CdkStatus::InvalidMintUrl,
            "mint URL must not contain a fragment",
        ));
    }
    if parsed.query().is_some() {
        return Err(FfiErr::new(
            CdkStatus::InvalidMintUrl,
            "mint URL must not contain a query string",
        ));
    }
    if parsed.host_str().is_none() {
        return Err(FfiErr::new(
            CdkStatus::InvalidMintUrl,
            "mint URL must have a host",
        ));
    }

    MintUrl::from_str(raw)
        .map_err(|e| FfiErr::new(CdkStatus::InvalidMintUrl, format!("invalid mint URL: {e}")))
}
