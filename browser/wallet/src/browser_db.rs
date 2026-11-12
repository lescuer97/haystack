//! Browser implementation of the complete pinned WalletDatabase interface.
//!
//! Storage is the dedicated `haystack-wallet` IndexedDB database: one plaintext
//! English BIP-39 mnemonic record and one serialized `Store` v1 record per
//! wallet name. Every read opens a fresh transaction; every write commits only
//! when its IndexedDB transaction completes. Mutations are serialized per
//! handle by an async mutex, and the lifetime Web Lock excludes other tabs.
//!
//! A write is a compare-and-swap on the record revision. Because the
//! read-modify-write spans asynchronous Rust, a writer that lost a race is
//! rejected with `ConcurrentUpdate` instead of overwriting committed state.
use async_trait::async_trait;
use cdk_common::bitcoin::bip32::DerivationPath;
use cdk_common::database::{Error, WalletDatabase};
use cdk_common::mint_url::MintUrl;
use cdk_common::nuts::{
    CurrencyUnit, Id, KeySet, KeySetInfo, Keys, MintInfo, PaymentMethod, PublicKey,
    SpendingConditions, State,
};
use cdk_common::wallet::{
    MeltQuote, MintQuote, P2PKSigningKey, ProofInfo, Transaction, TransactionDirection,
    TransactionId, WalletSaga,
};
use futures::lock::Mutex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;
use zeroize::Zeroizing;

/// Failure classes of the two-record browser wallet store. These never carry
/// secret material; they only describe what is wrong with the storage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DbError {
    /// The IndexedDB backend cannot be reached or opened.
    Unavailable,
    /// Neither a mnemonic nor a state record exists for this name.
    NotInitialized,
    /// Exactly one of the two records exists; that is never treated as empty.
    Incomplete,
    /// The stored words are not a valid English BIP-39 mnemonic.
    InvalidMnemonic,
    /// The supplied seed does not match the stored mnemonic or state.
    SeedMismatch,
    /// A record exists but cannot be parsed as the strict v1 schema.
    Corrupt,
    /// The state record was written by an incompatible format version.
    UnsupportedVersion,
    /// Provisioning found an existing mnemonic or state record.
    AlreadyExists,
    /// The write transaction failed or was aborted.
    WriteFailed,
    /// Another writer changed the state revision between read and write.
    Conflict,
}

impl DbError {
    pub fn message(self) -> &'static str {
        match self {
            Self::Unavailable => "browser wallet storage is unavailable",
            Self::NotInitialized => "wallet is not initialized; provision it before opening",
            Self::Incomplete => {
                "wallet storage is incomplete: its mnemonic and state records do not both exist"
            }
            Self::InvalidMnemonic => "wallet mnemonic is not a valid English BIP-39 phrase",
            Self::SeedMismatch => "seed does not match browser wallet storage",
            Self::Corrupt => "wallet storage is unreadable; refusing to overwrite it",
            Self::UnsupportedVersion => "unsupported browser wallet storage format",
            Self::AlreadyExists => "a wallet with this name already exists",
            Self::WriteFailed => "browser wallet storage write failed (quota or access denied)",
            Self::Conflict => "wallet state changed concurrently; the operation was rejected",
        }
    }
}

impl std::fmt::Display for DbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message())
    }
}

/// Low-level backend failure. `load`/`provision`/`write` map it onto [`DbError`].
#[derive(Debug)]
pub(crate) enum StorageFailure {
    Conflict,
    Other(String),
}

/// Shape of the JSON returned by `loadWallet` in `platform.js`.
#[derive(Serialize, Deserialize)]
struct StateRecord {
    revision: u64,
    data: String,
}

#[derive(Deserialize)]
struct Records {
    mnemonic: Option<String>,
    state: Option<StateRecord>,
}

#[cfg(target_arch = "wasm32")]
mod backend {
    use super::StorageFailure;
    use wasm_bindgen::prelude::*;

    #[wasm_bindgen(module = "/platform.js")]
    extern "C" {
        #[wasm_bindgen(catch, js_name = loadWallet)]
        async fn load_wallet(name: &str) -> Result<String, JsValue>;
        #[wasm_bindgen(catch, js_name = provisionWallet)]
        async fn provision_wallet(name: &str, mnemonic: &str, state: &str) -> Result<(), JsValue>;
        #[wasm_bindgen(catch, js_name = writeWalletState)]
        async fn write_wallet_state(name: &str, revision: &str, data: &str) -> Result<(), JsValue>;
    }

    fn message(error: JsValue) -> String {
        error
            .dyn_ref::<js_sys::Error>()
            .map(|error| String::from(error.message()))
            .or_else(|| error.as_string())
            .unwrap_or_default()
    }

    pub async fn load(name: &str) -> Result<String, StorageFailure> {
        load_wallet(name)
            .await
            .map_err(|error| StorageFailure::Other(message(error)))
    }

    pub async fn provision(name: &str, mnemonic: &str, state: &str) -> Result<(), StorageFailure> {
        provision_wallet(name, mnemonic, state)
            .await
            .map_err(|error| StorageFailure::Other(message(error)))
    }

    pub async fn write(name: &str, revision: u64, data: &str) -> Result<(), StorageFailure> {
        let expected = revision.to_string();
        write_wallet_state(name, &expected, data)
            .await
            .map_err(|error| {
                let text = message(error);
                if text.contains("wallet state conflict") {
                    StorageFailure::Conflict
                } else {
                    StorageFailure::Other(text)
                }
            })
    }
}

// Native conformance tests exercise exactly the same serialization, validation
// and compare-and-swap logic against an in-memory substitute for the IndexedDB
// primitives. Actual IndexedDB behavior is covered in Chromium.
#[cfg(not(target_arch = "wasm32"))]
mod backend {
    use super::StorageFailure;
    use serde_json::json;
    use std::cell::RefCell;
    use std::collections::HashMap;

    #[derive(Default)]
    struct Memory {
        mnemonics: HashMap<String, String>,
        states: HashMap<String, (u64, String)>,
    }

    thread_local! {
        static MEMORY: RefCell<Memory> = RefCell::new(Memory::default());
    }

    pub async fn load(name: &str) -> Result<String, StorageFailure> {
        let (mnemonic, state) = MEMORY.with(|memory| {
            let memory = memory.borrow();
            (
                memory.mnemonics.get(name).cloned(),
                memory
                    .states
                    .get(name)
                    .map(|(revision, data)| (*revision, data.clone())),
            )
        });
        Ok(json!({
            "mnemonic": mnemonic,
            "state": state.map(|(revision, data)| json!({"revision": revision, "data": data})),
        })
        .to_string())
    }

    pub async fn provision(name: &str, mnemonic: &str, state: &str) -> Result<(), StorageFailure> {
        MEMORY.with(|memory| {
            let mut memory = memory.borrow_mut();
            if memory.mnemonics.contains_key(name) || memory.states.contains_key(name) {
                return Err(StorageFailure::Other("wallet already exists".to_owned()));
            }
            memory
                .mnemonics
                .insert(name.to_owned(), mnemonic.to_owned());
            memory.states.insert(name.to_owned(), (0, state.to_owned()));
            Ok(())
        })
    }

    pub async fn write(name: &str, revision: u64, data: &str) -> Result<(), StorageFailure> {
        MEMORY.with(|memory| {
            let mut memory = memory.borrow_mut();
            match memory.states.get_mut(name) {
                None => Err(StorageFailure::Other("wallet state is missing".to_owned())),
                Some((current, _)) if *current != revision => Err(StorageFailure::Conflict),
                Some(entry) => {
                    entry.0 = revision + 1;
                    entry.1 = data.to_owned();
                    Ok(())
                }
            }
        })
    }

    #[cfg(test)]
    pub fn test_state(name: &str) -> Option<(u64, String)> {
        MEMORY.with(|memory| memory.borrow().states.get(name).cloned())
    }

    #[cfg(test)]
    pub fn test_mnemonic(name: &str) -> Option<String> {
        MEMORY.with(|memory| memory.borrow().mnemonics.get(name).cloned())
    }

    #[cfg(test)]
    pub fn test_set_state(name: &str, data: &str) {
        MEMORY.with(|memory| {
            let mut memory = memory.borrow_mut();
            memory
                .states
                .entry(name.to_owned())
                .and_modify(|entry| entry.1 = data.to_owned())
                .or_insert_with(|| (0, data.to_owned()));
        });
    }

    #[cfg(test)]
    pub fn test_set_mnemonic(name: &str, mnemonic: &str) {
        MEMORY.with(|memory| {
            memory
                .borrow_mut()
                .mnemonics
                .insert(name.to_owned(), mnemonic.to_owned());
        });
    }

    #[cfg(test)]
    pub fn test_remove_mnemonic(name: &str) {
        MEMORY.with(|memory| {
            memory.borrow_mut().mnemonics.remove(name);
        });
    }
}

#[cfg(all(test, not(target_arch = "wasm32")))]
pub(crate) use backend::{test_mnemonic, test_remove_mnemonic, test_set_mnemonic, test_set_state};

#[cfg(all(test, not(target_arch = "wasm32")))]
pub(crate) fn test_state(name: &str) -> Option<(u64, String)> {
    backend::test_state(name)
}

// Exact v1 schema. Do not add `#[serde(default)]`: a missing field in an
// existing record means corruption or an incompatible writer, not a fresh
// wallet, and must be rejected before a mutation can overwrite the record.
// `deny_unknown_fields` makes unknown fields an incompatible record too: serde
// would otherwise drop them on the next mutation, silently discarding data
// written by a future writer. Only a brand-new record is built from
// `Store::default()` during provisioning.
#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Store {
    version: u32,
    fingerprint: String,
    mints: HashMap<MintUrl, Option<MintInfo>>,
    mint_keysets: HashMap<MintUrl, Vec<KeySetInfo>>,
    keys: HashMap<String, KeySet>,
    mint_quotes: HashMap<String, MintQuote>,
    melt_quotes: HashMap<String, MeltQuote>,
    proofs: HashMap<String, ProofInfo>,
    counters: HashMap<String, u32>,
    derivation_counters: HashMap<String, u32>,
    transactions: HashMap<String, Transaction>,
    sagas: HashMap<String, WalletSaga>,
    kv: HashMap<String, Vec<u8>>,
    p2pk_keys: Vec<P2PKSigningKey>,
}

impl Store {
    fn new(fingerprint: String) -> Self {
        Self {
            version: 1,
            fingerprint,
            ..Self::default()
        }
    }
}

#[derive(Debug)]
pub struct BrowserDatabase {
    name: String,
    fingerprint: String,
    // Serializes one handle's read-modify-write mutations. The Web Lock already
    // excludes other tabs; this mutex keeps concurrent CDK calls on one handle
    // from observing and rewriting the same revision.
    writes: Mutex<()>,
}

fn error(message: &str) -> Error {
    Error::Internal(message.to_owned())
}
fn read_error(failure: StorageFailure) -> DbError {
    match failure {
        StorageFailure::Conflict => DbError::Conflict,
        StorageFailure::Other(_) => DbError::Unavailable,
    }
}
fn write_error(failure: StorageFailure) -> DbError {
    match failure {
        StorageFailure::Conflict => DbError::Conflict,
        StorageFailure::Other(_) => DbError::WriteFailed,
    }
}
fn internal(failure: DbError) -> Error {
    error(failure.message())
}

/// Parse and normalize an English BIP-39 phrase, deriving the wallet seed.
pub(crate) fn parse_mnemonic(text: &str) -> Result<(String, [u8; 64]), DbError> {
    let mnemonic = bip39::Mnemonic::parse_in_normalized(bip39::Language::English, text)
        .map_err(|_| DbError::InvalidMnemonic)?;
    Ok((mnemonic.to_string(), mnemonic.to_seed("")))
}

#[cfg(test)]
pub(crate) fn seed_from_mnemonic(text: &str) -> Result<[u8; 64], DbError> {
    parse_mnemonic(text).map(|(_, seed)| seed)
}

fn parse_store(raw: &str, fingerprint: &str) -> Result<Store, DbError> {
    let store: Store = serde_json::from_str(raw).map_err(|_| DbError::Corrupt)?;
    if store.version != 1 {
        return Err(DbError::UnsupportedVersion);
    }
    if store.fingerprint != fingerprint {
        return Err(DbError::SeedMismatch);
    }
    Ok(store)
}

impl BrowserDatabase {
    /// Open an existing provisioned wallet. Never creates or rewrites records.
    pub async fn open(name: String, fingerprint: String, seed: [u8; 64]) -> Result<Self, DbError> {
        let records: Records =
            serde_json::from_str(&backend::load(&name).await.map_err(read_error)?)
                .map_err(|_| DbError::Corrupt)?;
        let (mnemonic, state) = match (records.mnemonic, records.state) {
            (None, None) => return Err(DbError::NotInitialized),
            (Some(mnemonic), Some(state)) => (mnemonic, state),
            _ => return Err(DbError::Incomplete),
        };
        let (_, derived) = parse_mnemonic(&mnemonic)?;
        let derived = Zeroizing::new(derived);
        if *derived != seed {
            return Err(DbError::SeedMismatch);
        }
        parse_store(&state.data, &fingerprint)?;
        Ok(Self {
            name,
            fingerprint,
            writes: Mutex::new(()),
        })
    }

    /// Create the two records atomically in one IndexedDB transaction. Callers
    /// must hold the wallet's Web Lock and must confirm both records are absent.
    /// An existing pair is never replaced.
    pub async fn provision(
        name: &str,
        mnemonic: &str,
        fingerprint: String,
        seed: &[u8; 64],
    ) -> Result<(), DbError> {
        let (normalized, derived) = parse_mnemonic(mnemonic)?;
        let derived = Zeroizing::new(derived);
        if *derived != *seed {
            return Err(DbError::InvalidMnemonic);
        }
        let records: Records =
            serde_json::from_str(&backend::load(name).await.map_err(read_error)?)
                .map_err(|_| DbError::Corrupt)?;
        if records.mnemonic.is_some() || records.state.is_some() {
            return Err(DbError::AlreadyExists);
        }
        let raw =
            serde_json::to_string(&Store::new(fingerprint)).map_err(|_| DbError::WriteFailed)?;
        backend::provision(name, &normalized, &raw)
            .await
            .map_err(|failure| match failure {
                StorageFailure::Other(text) if text.contains("wallet already exists") => {
                    DbError::AlreadyExists
                }
                _ => DbError::WriteFailed,
            })
    }

    async fn load(&self) -> Result<(u64, Store), DbError> {
        let records: Records =
            serde_json::from_str(&backend::load(&self.name).await.map_err(read_error)?)
                .map_err(|_| DbError::Corrupt)?;
        let state = match (records.mnemonic, records.state) {
            (None, None) => return Err(DbError::NotInitialized),
            (Some(_), Some(state)) => state,
            _ => return Err(DbError::Incomplete),
        };
        Ok((state.revision, parse_store(&state.data, &self.fingerprint)?))
    }

    async fn save(&self, revision: u64, store: &Store) -> Result<(), DbError> {
        let raw = serde_json::to_string(store).map_err(|_| DbError::WriteFailed)?;
        backend::write(&self.name, revision, &raw)
            .await
            .map_err(write_error)
    }

    async fn read<T>(&self, f: impl FnOnce(&Store) -> T) -> Result<T, Error> {
        let (_, store) = self.load().await.map_err(internal)?;
        Ok(f(&store))
    }

    async fn write<T>(&self, f: impl FnOnce(&mut Store) -> Result<T, Error>) -> Result<T, Error> {
        let _guard = self.writes.lock().await;
        let (revision, mut store) = self.load().await.map_err(internal)?;
        let result = f(&mut store)?;
        self.save(revision, &store)
            .await
            .map_err(|failure| match failure {
                DbError::Conflict => Error::ConcurrentUpdate,
                other => internal(other),
            })?;
        Ok(result)
    }
}

fn kv_key(a: &str, b: &str, c: &str) -> String {
    format!("{a}\u{1f}{b}\u{1f}{c}")
}

#[cfg_attr(target_arch = "wasm32", async_trait(?Send))]
#[cfg_attr(not(target_arch = "wasm32"), async_trait)]
impl WalletDatabase<Error> for BrowserDatabase {
    async fn get_mint(&self, url: MintUrl) -> Result<Option<MintInfo>, Error> {
        self.read(|s| s.mints.get(&url).cloned().flatten()).await
    }
    async fn get_mints(&self) -> Result<HashMap<MintUrl, Option<MintInfo>>, Error> {
        self.read(|s| s.mints.clone()).await
    }
    async fn get_mint_keysets(&self, url: MintUrl) -> Result<Option<Vec<KeySetInfo>>, Error> {
        self.read(|s| s.mint_keysets.get(&url).cloned()).await
    }
    async fn get_keyset_by_id(&self, id: &Id) -> Result<Option<KeySetInfo>, Error> {
        self.read(|s| {
            s.mint_keysets
                .values()
                .flatten()
                .find(|k| &k.id == id)
                .cloned()
        })
        .await
    }
    async fn get_mint_quote(&self, id: &str) -> Result<Option<MintQuote>, Error> {
        self.read(|s| s.mint_quotes.get(id).cloned()).await
    }
    async fn get_mint_quotes(&self) -> Result<Vec<MintQuote>, Error> {
        self.read(|s| s.mint_quotes.values().cloned().collect())
            .await
    }
    async fn get_unissued_mint_quotes(&self) -> Result<Vec<MintQuote>, Error> {
        self.read(|s| {
            s.mint_quotes
                .values()
                .filter(|q| {
                    q.payment_method != PaymentMethod::BOLT11
                        || q.amount_issued == cdk_common::Amount::ZERO
                })
                .cloned()
                .collect()
        })
        .await
    }
    async fn get_melt_quote(&self, id: &str) -> Result<Option<MeltQuote>, Error> {
        self.read(|s| s.melt_quotes.get(id).cloned()).await
    }
    async fn get_melt_quotes(&self) -> Result<Vec<MeltQuote>, Error> {
        self.read(|s| s.melt_quotes.values().cloned().collect())
            .await
    }
    async fn get_keys(&self, id: &Id) -> Result<Option<Keys>, Error> {
        self.read(|s| s.keys.get(&id.to_string()).map(|k| k.keys.clone()))
            .await
    }
    async fn get_proofs(
        &self,
        mint: Option<MintUrl>,
        unit: Option<CurrencyUnit>,
        state: Option<Vec<State>>,
        conditions: Option<Vec<SpendingConditions>>,
    ) -> Result<Vec<ProofInfo>, Error> {
        self.read(|s| {
            s.proofs
                .values()
                .filter(|p| p.matches_conditions(&mint, &unit, &state, &conditions))
                .cloned()
                .collect()
        })
        .await
    }
    async fn get_proofs_by_ys(&self, ys: Vec<PublicKey>) -> Result<Vec<ProofInfo>, Error> {
        self.read(|s| {
            ys.iter()
                .filter_map(|y| s.proofs.get(&y.to_string()).cloned())
                .collect()
        })
        .await
    }
    async fn get_balance(
        &self,
        mint: Option<MintUrl>,
        unit: Option<CurrencyUnit>,
        state: Option<Vec<State>>,
    ) -> Result<u64, Error> {
        self.read(|s| {
            s.proofs
                .values()
                .filter(|p| p.matches_conditions(&mint, &unit, &state, &None))
                .try_fold(0u64, |v, p| {
                    v.checked_add(u64::from(p.proof.amount))
                        .ok_or(Error::AmountOverflow)
                })
        })
        .await?
    }
    async fn get_transaction(&self, id: TransactionId) -> Result<Option<Transaction>, Error> {
        self.read(|s| s.transactions.get(&id.to_string()).cloned())
            .await
    }
    async fn list_transactions(
        &self,
        mint: Option<MintUrl>,
        direction: Option<TransactionDirection>,
        unit: Option<CurrencyUnit>,
    ) -> Result<Vec<Transaction>, Error> {
        self.read(|s| {
            let mut out: Vec<_> = s
                .transactions
                .values()
                .filter(|t| t.matches_conditions(&mint, &direction, &unit))
                .cloned()
                .collect();
            out.sort_by_key(|t| std::cmp::Reverse(t.timestamp));
            out
        })
        .await
    }
    async fn update_proofs(
        &self,
        added: Vec<ProofInfo>,
        removed: Vec<PublicKey>,
    ) -> Result<(), Error> {
        self.write(|s| {
            for y in removed {
                s.proofs.remove(&y.to_string());
            }
            for mut p in added {
                if p.derivation_index.is_none() {
                    p.derivation_index = s
                        .proofs
                        .get(&p.y.to_string())
                        .and_then(|old| old.derivation_index);
                }
                s.proofs.insert(p.y.to_string(), p);
            }
            Ok(())
        })
        .await
    }
    async fn update_proofs_state(&self, ys: Vec<PublicKey>, state: State) -> Result<(), Error> {
        self.write(|s| {
            for y in ys {
                if let Some(p) = s.proofs.get_mut(&y.to_string()) {
                    p.state = state;
                }
            }
            Ok(())
        })
        .await
    }
    async fn add_transaction(&self, tx: Transaction) -> Result<(), Error> {
        self.write(|s| {
            s.transactions.insert(tx.id().to_string(), tx);
            Ok(())
        })
        .await
    }
    async fn update_mint_url(&self, old: MintUrl, new: MintUrl) -> Result<(), Error> {
        self.write(|s| {
            if let Some(v) = s.mints.remove(&old) {
                s.mints.insert(new.clone(), v);
            }
            if let Some(v) = s.mint_keysets.remove(&old) {
                s.mint_keysets.insert(new.clone(), v);
            }
            for p in s.proofs.values_mut() {
                if p.mint_url == old {
                    p.mint_url = new.clone();
                }
            }
            for q in s.mint_quotes.values_mut() {
                if q.mint_url == old {
                    q.mint_url = new.clone();
                }
            }
            Ok(())
        })
        .await
    }
    async fn increment_keyset_counter(&self, id: &Id, count: u32) -> Result<u32, Error> {
        self.write(|s| {
            let v = s.counters.entry(id.to_string()).or_default();
            *v = v.checked_add(count).ok_or(Error::AmountOverflow)?;
            Ok(*v)
        })
        .await
    }
    async fn increment_derivation_counter(
        &self,
        namespace: &str,
        count: u32,
    ) -> Result<u32, Error> {
        self.write(|s| {
            let v = s
                .derivation_counters
                .entry(namespace.to_owned())
                .or_default();
            *v = v.checked_add(count).ok_or(Error::AmountOverflow)?;
            Ok(*v)
        })
        .await
    }
    async fn add_mint(&self, url: MintUrl, info: Option<MintInfo>) -> Result<(), Error> {
        self.write(|s| {
            s.mints.insert(url, info);
            Ok(())
        })
        .await
    }
    async fn remove_mint(&self, url: MintUrl) -> Result<(), Error> {
        self.write(|s| {
            s.mints.remove(&url);
            s.mint_keysets.remove(&url);
            Ok(())
        })
        .await
    }
    async fn add_mint_keysets(&self, url: MintUrl, keysets: Vec<KeySetInfo>) -> Result<(), Error> {
        self.write(|s| {
            let values = s.mint_keysets.entry(url).or_default();
            for k in keysets {
                if let Some(v) = values.iter_mut().find(|v| v.id == k.id) {
                    *v = k;
                } else {
                    values.push(k);
                }
            }
            Ok(())
        })
        .await
    }
    async fn add_mint_quote(&self, mut quote: MintQuote) -> Result<(), Error> {
        self.write(|s| {
            if let Some(old) = s.mint_quotes.get(&quote.id) {
                if old.version != quote.version {
                    return Err(Error::ConcurrentUpdate);
                }
                quote.version = quote.version.wrapping_add(1);
            }
            s.mint_quotes.insert(quote.id.clone(), quote);
            Ok(())
        })
        .await
    }
    async fn remove_mint_quote(&self, id: &str) -> Result<(), Error> {
        self.write(|s| {
            s.mint_quotes.remove(id);
            Ok(())
        })
        .await
    }
    async fn add_melt_quote(&self, mut quote: MeltQuote) -> Result<(), Error> {
        self.write(|s| {
            if let Some(old) = s.melt_quotes.get(&quote.id) {
                if old.version != quote.version {
                    return Err(Error::ConcurrentUpdate);
                }
                quote.version = quote.version.wrapping_add(1);
            }
            s.melt_quotes.insert(quote.id.clone(), quote);
            Ok(())
        })
        .await
    }
    async fn remove_melt_quote(&self, id: &str) -> Result<(), Error> {
        self.write(|s| {
            s.melt_quotes.remove(id);
            Ok(())
        })
        .await
    }
    async fn add_keys(&self, keyset: KeySet) -> Result<(), Error> {
        self.write(|s| {
            s.keys.insert(keyset.id.to_string(), keyset);
            Ok(())
        })
        .await
    }
    async fn remove_keys(&self, id: &Id) -> Result<(), Error> {
        self.write(|s| {
            s.keys.remove(&id.to_string());
            Ok(())
        })
        .await
    }
    async fn remove_transaction(&self, id: TransactionId) -> Result<(), Error> {
        self.write(|s| {
            s.transactions.remove(&id.to_string());
            Ok(())
        })
        .await
    }
    async fn add_saga(&self, saga: WalletSaga) -> Result<(), Error> {
        self.write(|s| {
            if s.sagas.contains_key(&saga.id.to_string()) {
                return Err(Error::Duplicate);
            }
            s.sagas.insert(saga.id.to_string(), saga);
            Ok(())
        })
        .await
    }
    async fn get_saga(&self, id: &Uuid) -> Result<Option<WalletSaga>, Error> {
        self.read(|s| s.sagas.get(&id.to_string()).cloned()).await
    }
    async fn update_saga(&self, saga: WalletSaga) -> Result<bool, Error> {
        self.write(|s| match s.sagas.get_mut(&saga.id.to_string()) {
            Some(old) if saga.version.checked_sub(1) == Some(old.version) => {
                *old = saga;
                Ok(true)
            }
            _ => Ok(false),
        })
        .await
    }
    async fn delete_saga(&self, id: &Uuid) -> Result<(), Error> {
        self.write(|s| {
            s.sagas.remove(&id.to_string());
            Ok(())
        })
        .await
    }
    async fn get_incomplete_sagas(&self) -> Result<Vec<WalletSaga>, Error> {
        self.read(|s| s.sagas.values().cloned().collect()).await
    }
    async fn reserve_proofs(&self, ys: Vec<PublicKey>, operation: &Uuid) -> Result<(), Error> {
        self.write(|s| {
            for y in &ys {
                match s.proofs.get(&y.to_string()) {
                    Some(p) if p.state == State::Unspent => (),
                    Some(_) => return Err(Error::ProofNotUnspent),
                    None => return Err(Error::ProofNotFound),
                }
            }
            for y in ys {
                let p = s
                    .proofs
                    .get_mut(&y.to_string())
                    .ok_or(Error::ProofNotFound)?;
                p.state = State::Reserved;
                p.used_by_operation = Some(*operation);
            }
            Ok(())
        })
        .await
    }
    async fn release_proofs(&self, operation: &Uuid) -> Result<(), Error> {
        self.write(|s| {
            for p in s
                .proofs
                .values_mut()
                .filter(|p| p.used_by_operation == Some(*operation))
            {
                if matches!(p.state, State::Reserved | State::Pending) {
                    p.state = State::Unspent;
                    p.used_by_operation = None;
                }
            }
            Ok(())
        })
        .await
    }
    async fn get_reserved_proofs(&self, operation: &Uuid) -> Result<Vec<ProofInfo>, Error> {
        self.read(|s| {
            s.proofs
                .values()
                .filter(|p| p.used_by_operation == Some(*operation))
                .cloned()
                .collect()
        })
        .await
    }
    async fn reserve_melt_quote(&self, id: &str, operation: &Uuid) -> Result<(), Error> {
        self.write(|s| {
            let q = s.melt_quotes.get_mut(id).ok_or(Error::UnknownQuote)?;
            if q.used_by_operation
                .as_ref()
                .is_some_and(|v| v != &operation.to_string())
            {
                return Err(Error::QuoteAlreadyInUse);
            }
            q.used_by_operation = Some(operation.to_string());
            Ok(())
        })
        .await
    }
    async fn release_melt_quote(&self, operation: &Uuid) -> Result<(), Error> {
        self.write(|s| {
            for q in s.melt_quotes.values_mut() {
                if q.used_by_operation == Some(operation.to_string()) {
                    q.used_by_operation = None;
                }
            }
            Ok(())
        })
        .await
    }
    async fn reserve_mint_quote(&self, id: &str, operation: &Uuid) -> Result<(), Error> {
        self.write(|s| {
            let q = s.mint_quotes.get_mut(id).ok_or(Error::UnknownQuote)?;
            if q.used_by_operation
                .as_ref()
                .is_some_and(|v| v != &operation.to_string())
            {
                return Err(Error::QuoteAlreadyInUse);
            }
            q.used_by_operation = Some(operation.to_string());
            Ok(())
        })
        .await
    }
    async fn release_mint_quote(&self, operation: &Uuid) -> Result<(), Error> {
        self.write(|s| {
            for q in s.mint_quotes.values_mut() {
                if q.used_by_operation == Some(operation.to_string()) {
                    q.used_by_operation = None;
                }
            }
            Ok(())
        })
        .await
    }
    async fn kv_read(&self, a: &str, b: &str, key: &str) -> Result<Option<Vec<u8>>, Error> {
        self.read(|s| s.kv.get(&kv_key(a, b, key)).cloned()).await
    }
    async fn kv_list(&self, a: &str, b: &str) -> Result<Vec<String>, Error> {
        self.read(|s| {
            let prefix = kv_key(a, b, "");
            let mut keys: Vec<_> =
                s.kv.keys()
                    .filter_map(|k| k.strip_prefix(&prefix).map(str::to_owned))
                    .collect();
            keys.sort();
            keys
        })
        .await
    }
    async fn kv_write(&self, a: &str, b: &str, key: &str, value: &[u8]) -> Result<(), Error> {
        self.write(|s| {
            s.kv.insert(kv_key(a, b, key), value.to_vec());
            Ok(())
        })
        .await
    }
    async fn kv_remove(&self, a: &str, b: &str, key: &str) -> Result<(), Error> {
        self.write(|s| {
            s.kv.remove(&kv_key(a, b, key));
            Ok(())
        })
        .await
    }
    async fn add_p2pk_key(
        &self,
        pubkey: &PublicKey,
        path: DerivationPath,
        index: u32,
    ) -> Result<(), Error> {
        self.write(|s| {
            s.p2pk_keys.retain(|k| k.pubkey != *pubkey);
            s.p2pk_keys.push(P2PKSigningKey {
                pubkey: *pubkey,
                derivation_path: path,
                derivation_index: index,
                created_time: web_time::SystemTime::now()
                    .duration_since(web_time::UNIX_EPOCH)
                    .map_err(|_| error("clock unavailable"))?
                    .as_secs(),
            });
            Ok(())
        })
        .await
    }
    async fn get_p2pk_key(&self, pubkey: &PublicKey) -> Result<Option<P2PKSigningKey>, Error> {
        self.read(|s| s.p2pk_keys.iter().find(|k| k.pubkey == *pubkey).cloned())
            .await
    }
    async fn list_p2pk_keys(&self) -> Result<Vec<P2PKSigningKey>, Error> {
        self.read(|s| s.p2pk_keys.clone()).await
    }
    async fn latest_p2pk(&self) -> Result<Option<P2PKSigningKey>, Error> {
        self.read(|s| {
            s.p2pk_keys
                .iter()
                .max_by_key(|k| k.derivation_index)
                .cloned()
        })
        .await
    }
}
