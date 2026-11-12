use crate::{
    browser_db::{self, BrowserDatabase},
    status::CdkStatus,
    wallet::{seed_fingerprint, FfiErr, FfiResult},
};
use futures::{
    future::{select, Either},
    pin_mut,
};
use std::{future::Future, sync::Arc, time::Duration};
use wasm_bindgen::prelude::*;
use zeroize::Zeroizing;

/// The single persistent user wallet name. Only provisioning this name asks the
/// browser for durable storage; disposable test wallets never do.
pub const USER_WALLET_NAME: &str = "haystack-user";

#[wasm_bindgen(module = "/platform.js")]
extern "C" {
    #[wasm_bindgen(catch, js_name = acquireWalletLock)]
    async fn acquire_lock(name: &str) -> Result<JsValue, JsValue>;
    #[wasm_bindgen(catch, js_name = requestPersistentStorage)]
    async fn request_persistent_storage() -> Result<JsValue, JsValue>;
}

pub struct BrowserLock(JsValue);
impl Drop for BrowserLock {
    fn drop(&mut self) {
        if let Some(release) = self.0.dyn_ref::<js_sys::Function>() {
            let _ = release.call0(&JsValue::UNDEFINED);
        }
    }
}

fn validate_name(name: &str) -> FfiResult<()> {
    if name.is_empty()
        || name.len() > 64
        || !name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
    {
        return Err(FfiErr::new(
            CdkStatus::InvalidPath,
            "browser wallet name must be 1-64 ASCII letters, digits, underscores or hyphens",
        ));
    }
    Ok(())
}

fn lock_name(name: &str) -> String {
    format!("haystack-wallet-lock:{name}")
}

async fn lock(name: &str) -> FfiResult<BrowserLock> {
    Ok(BrowserLock(acquire_lock(&lock_name(name)).await.map_err(
        |_| {
            FfiErr::new(
                CdkStatus::AlreadyOpen,
                "wallet lock unavailable (already open or Web Locks unsupported)",
            )
        },
    )?))
}

pub async fn open_database(
    seed: &[u8; 64],
    name: &str,
) -> FfiResult<(Arc<BrowserDatabase>, BrowserLock)> {
    validate_name(name)?;
    let lock = lock(name).await?;
    let fingerprint = cdk::util::hex::encode(seed_fingerprint(&seed[..]));
    // Opening validates the stored mnemonic and state read-only. A wallet that
    // was never provisioned, or has only one of its two records, is rejected;
    // nothing is created or defaulted.
    let db = BrowserDatabase::open(name.to_owned(), fingerprint, *seed)
        .await
        .map_err(|e| FfiErr::new(CdkStatus::DatabaseError, e.message()))?;
    Ok((Arc::new(db), lock))
}

/// Whether provisioning this wallet name asks the browser for durable storage.
/// Kept as one function so the real provisioning path and the test-only probe
/// cannot diverge.
pub fn requests_persistent_storage(name: &str) -> bool {
    name == USER_WALLET_NAME
}

/// Create the one wallet pair (`mnemonics` + `states`) atomically.
///
/// The caller must not replace an existing wallet; an existing record makes this
/// fail without changing anything. `navigator.storage.persist()` is requested
/// only for [`USER_WALLET_NAME`], and a denial is a warning, not a failure.
pub async fn provision_wallet(mnemonic: &str, name: &str) -> FfiResult<()> {
    validate_name(name)?;
    let seed = Zeroizing::new(
        browser_db::parse_mnemonic(mnemonic)
            .map_err(|_| {
                FfiErr::new(
                    CdkStatus::InvalidArgument,
                    "wallet mnemonic must be a valid English BIP-39 phrase",
                )
            })?
            .1,
    );
    let fingerprint = cdk::util::hex::encode(seed_fingerprint(&seed[..]));

    let lock = lock(name).await?;
    if requests_persistent_storage(name) {
        let granted = request_persistent_storage()
            .await
            .map(|value| value.as_bool().unwrap_or(false))
            .unwrap_or(false);
        if !granted {
            web_sys::console::warn_1(&JsValue::from_str(
                "Persistent storage was not granted; the wallet is stored but may be evicted under storage pressure",
            ));
        }
    }
    BrowserDatabase::provision(name, mnemonic, fingerprint, &seed)
        .await
        .map_err(|e| {
            let status = match e {
                browser_db::DbError::InvalidMnemonic => CdkStatus::InvalidArgument,
                _ => CdkStatus::DatabaseError,
            };
            FfiErr::new(status, e.message())
        })?;
    drop(lock);
    Ok(())
}

/// Test-only persistence probe: runs the production name gate and the real
/// `navigator.storage.persist()` call, but never reads, writes or creates a
/// wallet record. Returns whether durable storage was granted; names outside
/// the user-wallet policy report `true` without calling `persist()`.
///
/// The browser regression fixture uses this so it never has to provision the
/// real user wallet to exercise the policy.
pub async fn probe_persistent_storage(name: &str) -> FfiResult<bool> {
    if !requests_persistent_storage(name) {
        return Ok(true);
    }
    Ok(request_persistent_storage()
        .await
        .map(|value| value.as_bool().unwrap_or(false))
        .unwrap_or(false))
}

/// Dropping the network future cancels local polling. A remote commit may have
/// happened; the shared wallet code still treats mutation timeouts as uncertain.
pub async fn timeout<F: Future>(duration: Duration, future: F) -> Result<F::Output, ()> {
    let timer =
        gloo_timers::future::TimeoutFuture::new(duration.as_millis().min(u32::MAX as u128) as u32);
    pin_mut!(future, timer);
    match select(future, timer).await {
        Either::Left((value, _)) => Ok(value),
        Either::Right(_) => Err(()),
    }
}
