//! Browser implementation of the complete pinned WalletDatabase interface.
//! All reads are fresh; a lifetime Web Lock excludes other wallet handles.
//! Persistence errors are returned, never converted into successful mutations.
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
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen(module = "/platform.js")]
extern "C" {
    #[wasm_bindgen(catch, js_name = readStore)]
    fn read_store(key: &str) -> Result<Option<String>, JsValue>;
    #[wasm_bindgen(catch, js_name = writeStore)]
    fn write_store(key: &str, value: &str) -> Result<(), JsValue>;
}

// Native conformance tests exercise exactly the same serialization and trait
// implementation. Actual Web Locks/quota behavior is covered in Chromium.
#[cfg(not(target_arch = "wasm32"))]
thread_local! { static TEST_STORAGE: std::cell::RefCell<HashMap<String,String>> = std::cell::RefCell::new(HashMap::new()); }
#[cfg(not(target_arch = "wasm32"))]
fn read_store(key: &str) -> Result<Option<String>, String> {
    Ok(TEST_STORAGE.with(|s| s.borrow().get(key).cloned()))
}
#[cfg(not(target_arch = "wasm32"))]
fn write_store(key: &str, value: &str) -> Result<(), String> {
    TEST_STORAGE.with(|s| s.borrow_mut().insert(key.to_owned(), value.to_owned()));
    Ok(())
}

// Exact v1 schema. Do not add `#[serde(default)]`: a missing field in an
// existing record means corruption or an incompatible writer, not a fresh
// wallet, and must be rejected before a mutation can overwrite the record.
// Unknown fields are tolerated by serde for forward-compatible readers. Only a
// brand-new record is built from `Store::default()` (see `Store::new`).
#[derive(Default, Serialize, Deserialize)]
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

#[cfg(test)]
pub(crate) fn test_storage_set(key: &str, value: &str) {
    write_store(key, value).expect("native test storage write");
}

#[cfg(test)]
pub(crate) fn test_storage_get(key: &str) -> Option<String> {
    read_store(key).expect("native test storage read")
}

#[derive(Debug)]
pub struct BrowserDatabase {
    key: String,
    fingerprint: String,
}

fn error(message: &str) -> Error {
    Error::Internal(message.to_owned())
}
fn kv_key(a: &str, b: &str, c: &str) -> String {
    format!("{a}\u{1f}{b}\u{1f}{c}")
}

impl BrowserDatabase {
    pub fn open(key: String, fingerprint: String) -> Result<Self, Error> {
        let db = Self { key, fingerprint };
        let raw = read_store(&db.key).map_err(|_| error("browser storage unavailable"))?;
        match raw {
            Some(_) => {
                db.load()?;
            }
            None => db.save(&Store::new(db.fingerprint.clone()))?,
        }
        Ok(db)
    }
    fn load(&self) -> Result<Store, Error> {
        let raw = read_store(&self.key)
            .map_err(|_| error("browser storage read failed"))?
            .ok_or_else(|| error("wallet storage disappeared; stop and recover from backup"))?;
        let store: Store = serde_json::from_str(&raw)
            .map_err(|_| error("wallet storage is unreadable; refusing to overwrite it"))?;
        if store.version != 1 {
            return Err(error("unsupported browser storage format"));
        }
        if store.fingerprint != self.fingerprint {
            return Err(error("seed does not match browser wallet storage"));
        }
        Ok(store)
    }
    fn save(&self, store: &Store) -> Result<(), Error> {
        let raw = serde_json::to_string(store).map_err(|_| error("wallet serialization failed"))?;
        write_store(&self.key, &raw)
            .map_err(|_| error("browser storage write failed (quota or access denied)"))
    }
    fn read<T>(&self, f: impl FnOnce(&Store) -> T) -> Result<T, Error> {
        Ok(f(&self.load()?))
    }
    fn write<T>(&self, f: impl FnOnce(&mut Store) -> Result<T, Error>) -> Result<T, Error> {
        let mut store = self.load()?;
        let result = f(&mut store)?;
        self.save(&store)?;
        Ok(result)
    }
}

#[cfg_attr(target_arch = "wasm32", async_trait(?Send))]
#[cfg_attr(not(target_arch = "wasm32"), async_trait)]
impl WalletDatabase<Error> for BrowserDatabase {
    async fn get_mint(&self, url: MintUrl) -> Result<Option<MintInfo>, Error> {
        self.read(|s| s.mints.get(&url).cloned().flatten())
    }
    async fn get_mints(&self) -> Result<HashMap<MintUrl, Option<MintInfo>>, Error> {
        self.read(|s| s.mints.clone())
    }
    async fn get_mint_keysets(&self, url: MintUrl) -> Result<Option<Vec<KeySetInfo>>, Error> {
        self.read(|s| s.mint_keysets.get(&url).cloned())
    }
    async fn get_keyset_by_id(&self, id: &Id) -> Result<Option<KeySetInfo>, Error> {
        self.read(|s| {
            s.mint_keysets
                .values()
                .flatten()
                .find(|k| &k.id == id)
                .cloned()
        })
    }
    async fn get_mint_quote(&self, id: &str) -> Result<Option<MintQuote>, Error> {
        self.read(|s| s.mint_quotes.get(id).cloned())
    }
    async fn get_mint_quotes(&self) -> Result<Vec<MintQuote>, Error> {
        self.read(|s| s.mint_quotes.values().cloned().collect())
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
    }
    async fn get_melt_quote(&self, id: &str) -> Result<Option<MeltQuote>, Error> {
        self.read(|s| s.melt_quotes.get(id).cloned())
    }
    async fn get_melt_quotes(&self) -> Result<Vec<MeltQuote>, Error> {
        self.read(|s| s.melt_quotes.values().cloned().collect())
    }
    async fn get_keys(&self, id: &Id) -> Result<Option<Keys>, Error> {
        self.read(|s| s.keys.get(&id.to_string()).map(|k| k.keys.clone()))
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
    }
    async fn get_proofs_by_ys(&self, ys: Vec<PublicKey>) -> Result<Vec<ProofInfo>, Error> {
        self.read(|s| {
            ys.iter()
                .filter_map(|y| s.proofs.get(&y.to_string()).cloned())
                .collect()
        })
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
        })?
    }
    async fn get_transaction(&self, id: TransactionId) -> Result<Option<Transaction>, Error> {
        self.read(|s| s.transactions.get(&id.to_string()).cloned())
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
    }
    async fn add_transaction(&self, tx: Transaction) -> Result<(), Error> {
        self.write(|s| {
            s.transactions.insert(tx.id().to_string(), tx);
            Ok(())
        })
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
    }
    async fn increment_keyset_counter(&self, id: &Id, count: u32) -> Result<u32, Error> {
        self.write(|s| {
            let v = s.counters.entry(id.to_string()).or_default();
            *v = v.checked_add(count).ok_or(Error::AmountOverflow)?;
            Ok(*v)
        })
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
    }
    async fn add_mint(&self, url: MintUrl, info: Option<MintInfo>) -> Result<(), Error> {
        self.write(|s| {
            s.mints.insert(url, info);
            Ok(())
        })
    }
    async fn remove_mint(&self, url: MintUrl) -> Result<(), Error> {
        self.write(|s| {
            s.mints.remove(&url);
            s.mint_keysets.remove(&url);
            Ok(())
        })
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
    }
    async fn remove_mint_quote(&self, id: &str) -> Result<(), Error> {
        self.write(|s| {
            s.mint_quotes.remove(id);
            Ok(())
        })
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
    }
    async fn remove_melt_quote(&self, id: &str) -> Result<(), Error> {
        self.write(|s| {
            s.melt_quotes.remove(id);
            Ok(())
        })
    }
    async fn add_keys(&self, keyset: KeySet) -> Result<(), Error> {
        self.write(|s| {
            s.keys.insert(keyset.id.to_string(), keyset);
            Ok(())
        })
    }
    async fn remove_keys(&self, id: &Id) -> Result<(), Error> {
        self.write(|s| {
            s.keys.remove(&id.to_string());
            Ok(())
        })
    }
    async fn remove_transaction(&self, id: TransactionId) -> Result<(), Error> {
        self.write(|s| {
            s.transactions.remove(&id.to_string());
            Ok(())
        })
    }
    async fn add_saga(&self, saga: WalletSaga) -> Result<(), Error> {
        self.write(|s| {
            if s.sagas.contains_key(&saga.id.to_string()) {
                return Err(Error::Duplicate);
            }
            s.sagas.insert(saga.id.to_string(), saga);
            Ok(())
        })
    }
    async fn get_saga(&self, id: &Uuid) -> Result<Option<WalletSaga>, Error> {
        self.read(|s| s.sagas.get(&id.to_string()).cloned())
    }
    async fn update_saga(&self, saga: WalletSaga) -> Result<bool, Error> {
        self.write(|s| match s.sagas.get_mut(&saga.id.to_string()) {
            Some(old) if saga.version.checked_sub(1) == Some(old.version) => {
                *old = saga;
                Ok(true)
            }
            _ => Ok(false),
        })
    }
    async fn delete_saga(&self, id: &Uuid) -> Result<(), Error> {
        self.write(|s| {
            s.sagas.remove(&id.to_string());
            Ok(())
        })
    }
    async fn get_incomplete_sagas(&self) -> Result<Vec<WalletSaga>, Error> {
        self.read(|s| s.sagas.values().cloned().collect())
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
    }
    async fn get_reserved_proofs(&self, operation: &Uuid) -> Result<Vec<ProofInfo>, Error> {
        self.read(|s| {
            s.proofs
                .values()
                .filter(|p| p.used_by_operation == Some(*operation))
                .cloned()
                .collect()
        })
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
    }
    async fn kv_read(&self, a: &str, b: &str, key: &str) -> Result<Option<Vec<u8>>, Error> {
        self.read(|s| s.kv.get(&kv_key(a, b, key)).cloned())
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
    }
    async fn kv_write(&self, a: &str, b: &str, key: &str, value: &[u8]) -> Result<(), Error> {
        self.write(|s| {
            s.kv.insert(kv_key(a, b, key), value.to_vec());
            Ok(())
        })
    }
    async fn kv_remove(&self, a: &str, b: &str, key: &str) -> Result<(), Error> {
        self.write(|s| {
            s.kv.remove(&kv_key(a, b, key));
            Ok(())
        })
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
    }
    async fn get_p2pk_key(&self, pubkey: &PublicKey) -> Result<Option<P2PKSigningKey>, Error> {
        self.read(|s| s.p2pk_keys.iter().find(|k| k.pubkey == *pubkey).cloned())
    }
    async fn list_p2pk_keys(&self) -> Result<Vec<P2PKSigningKey>, Error> {
        self.read(|s| s.p2pk_keys.clone())
    }
    async fn latest_p2pk(&self) -> Result<Option<P2PKSigningKey>, Error> {
        self.read(|s| {
            s.p2pk_keys
                .iter()
                .max_by_key(|k| k.derivation_index)
                .cloned()
        })
    }
}
