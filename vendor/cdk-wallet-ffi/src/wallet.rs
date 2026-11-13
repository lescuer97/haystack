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

use std::collections::BTreeSet;
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
use cdk::mint_url::MintUrl;
use cdk::nuts::{CurrencyUnit, Id, Proofs, SecretKey, SwapRequest, Token};
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
const UNIT: CurrencyUnit = CurrencyUnit::Sat;
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
#[cfg(not(target_arch = "wasm32"))]
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
    pub sender_fee_sats: u64,
}

impl FfiErr {
    /// Build an error without an operation id.
    pub(crate) fn new(status: CdkStatus, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
            operation_id: None,
            sender_fee_sats: 0,
        }
    }

    /// Build an error that still identifies a send operation.
    pub(crate) fn with_op(
        status: CdkStatus,
        message: impl Into<String>,
        operation_id: [u8; 16],
        sender_fee_sats: u64,
    ) -> Self {
        Self {
            status,
            message: message.into(),
            operation_id: Some(operation_id),
            sender_fee_sats,
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
    /// The multi-mint wallet repository (one [`Wallet`] per approved Sat mint).
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

impl CdkWallet {
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
            poisoned: Arc::new(AtomicBool::new(false)),
            #[cfg(test)]
            test_network_deadline: None,
            #[cfg(test)]
            test_recovery_deadline: None,
        };
        let reports = handle.run_recovery(None).await?;
        Ok((handle, reports))
    }

    /// List approved mint URLs (Sat wallets), sorted and de-duplicated.
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

    /// List approved mints with their locally spendable Sat balance.
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

    /// Register (approve) a mint after validating its URL and advertised units.
    pub(crate) async fn add_mint(&mut self, url_str: &str) -> FfiResult<()> {
        let mint_url = parse_mint_url(url_str)?;

        // Idempotent: an already-approved mint is a local no-op, no network.
        if self.repo.has_mint(&mint_url).await {
            return Ok(());
        }

        let deadline = self.network_deadline();
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
                "mint does not advertise the Sat unit",
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

    /// Scan deterministic proofs for one Sat mint. Earlier batches may persist
    /// even if a later batch fails or the deadline expires.
    #[cfg(not(target_arch = "wasm32"))]
    pub(crate) async fn restore_seed(&mut self, url: &str) -> FfiResult<(u64, u64, u64)> {
        let mint = parse_mint_url(url)?;
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

    /// Receive a token, returning the net Sat amount credited.
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

        let unit = token.unit().unwrap_or(UNIT);
        if unit != UNIT {
            return Err(FfiErr::new(
                CdkStatus::UnsupportedToken,
                "token is not denominated in Sat",
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
        let amount = match timeout(
            deadline,
            wallet.receive(token_str, receive_options(signing_keys)),
        )
        .await
        {
            Ok(Ok(amount)) => amount,
            Ok(Err(e)) => {
                let err = map_receive_error(&e);
                if is_clearly_definitive(&e) {
                    return Err(err);
                }
                // The swap may have partially executed at the mint (HTTP error,
                // malformed response, ...). Fail closed and require an explicit
                // recovery before this mint is used again.
                self.unresolved.insert(mint_url);
                return Err(FfiErr::new(
                    err.status,
                    format!(
                        "receive outcome is uncertain; the mint is blocked pending recovery: {e}"
                    ),
                ));
            }
            Err(_) => {
                // The swap may have partially executed; fail closed.
                self.unresolved.insert(mint_url);
                return Err(FfiErr::new(
                    CdkStatus::NetworkError,
                    "receive exceeded the network deadline; the mint is blocked pending recovery",
                ));
            }
        };
        Ok(amount.to_u64())
    }

    /// Fetch the mint's active Sat keyset and return it as Spilman keyset JSON.
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

    /// Fetch a single Sat keyset by id and return it as Spilman keyset JSON.
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

    /// Resolve an approved Sat wallet for `mint_url`.
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

    /// Receive raw proofs from a mint, returning the net Sat amount credited.
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
        let mint_url = parse_mint_url(mint_url_str)?;

        if !self.repo.has_wallet(&mint_url, &UNIT).await {
            return Err(FfiErr::new(
                CdkStatus::MintNotRegistered,
                "mint has not been approved",
            ));
        }
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
        let deadline = self.network_deadline();
        let amount = match timeout(
            deadline,
            wallet.receive_proofs(proofs, receive_options(signing_keys), None, None),
        )
        .await
        {
            Ok(Ok(amount)) => amount,
            Ok(Err(e)) => {
                let err = map_receive_error(&e);
                if is_clearly_definitive(&e) {
                    return Err(err);
                }
                self.unresolved.insert(mint_url);
                return Err(FfiErr::new(
                    err.status,
                    format!(
                        "receive outcome is uncertain; the mint is blocked pending recovery: {e}"
                    ),
                ));
            }
            Err(_) => {
                self.unresolved.insert(mint_url);
                return Err(FfiErr::new(
                    CdkStatus::NetworkError,
                    "receive exceeded the network deadline; the mint is blocked pending recovery",
                ));
            }
        };
        Ok(amount.to_u64())
    }

    /// One-shot send from an explicitly selected mint.
    ///
    /// Prepares the send, compares the total fee against `max_sender_fee_sats`
    /// (cancelling if exceeded), then confirms. Ambiguous outcomes are reported
    /// as [`CdkStatus::SendUncertain`] and the mint is marked unresolved; the
    /// call is never retried automatically.
    pub(crate) async fn send(
        &mut self,
        mint_url_str: &str,
        amount_sats: u64,
        max_sender_fee_sats: u64,
    ) -> FfiResult<SendOutcome> {
        let mint_url = parse_mint_url(mint_url_str)?;

        // Validate every caller-provided value locally, before any network use.
        if amount_sats == 0 {
            return Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "send amount must be greater than zero",
            ));
        }
        ensure_fits_i64(amount_sats, "send amount")?;
        ensure_fits_i64(max_sender_fee_sats, "maximum sender fee")?;

        if !self.repo.has_wallet(&mint_url, &UNIT).await {
            return Err(FfiErr::new(
                CdkStatus::MintNotRegistered,
                "mint has not been approved",
            ));
        }
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
            send_kind: SendKind::OnlineExact,
            include_fee: false,
            ..SendOptions::default()
        };

        let deadline = self.network_deadline();
        let prepared = match timeout(
            deadline,
            wallet.prepare_send(Amount::from(amount_sats), opts),
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
        let overflow = match amount_sats.checked_add(total_fee) {
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

        if total_fee > max_sender_fee_sats {
            return Err(self
                .cancel_prepared(
                    prepared,
                    &mint_url,
                    operation_id,
                    total_fee,
                    CdkStatus::FeeLimitExceeded,
                    format!(
                        "send fee {total_fee} sats exceeds the maximum of {max_sender_fee_sats} sats"
                    ),
                )
                .await);
        }

        match timeout(deadline, prepared.confirm(None)).await {
            Ok(Ok(token)) => Ok(SendOutcome {
                token: token.to_string(),
                operation_id,
                sender_fee_sats: total_fee,
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
        if saga.unit != UNIT || !self.repo.has_mint(&saga.mint_url).await {
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

    /// Run recovery for every approved Sat wallet, or just one mint.
    ///
    /// Updates the per-mint unresolved set and returns one report per mint.
    /// Diagnostics are returned to the caller; nothing is written to stderr.
    pub(crate) async fn run_recovery(
        &mut self,
        mint: Option<&MintUrl>,
    ) -> FfiResult<Vec<MintRecoveryReport>> {
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
        amount_sats: u64,
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
            .prepare_send(Amount::from(amount_sats), opts)
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
    /// Total fee charged for the send, in sats.
    pub sender_fee_sats: u64,
}

impl std::fmt::Debug for SendOutcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SendOutcome")
            .field("token", &"<redacted>")
            .field("operation_id", &self.operation_id)
            .field("sender_fee_sats", &self.sender_fee_sats)
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

/// Build [`ReceiveOptions`] carrying the caller-supplied P2PK signing keys.
fn receive_options(signing_keys: &[SecretKey]) -> ReceiveOptions {
    ReceiveOptions {
        p2pk_signing_keys: signing_keys.to_vec(),
        ..Default::default()
    }
}

/// Convert a CDK [`KeySet`](cdk::nuts::KeySet) into Spilman `KeysetInfo` JSON.
fn keyset_to_json(keyset: cdk::nuts::KeySet) -> FfiResult<String> {
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
