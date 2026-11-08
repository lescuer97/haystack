use crate::{
    browser_db::BrowserDatabase,
    status::CdkStatus,
    wallet::{seed_fingerprint, FfiErr, FfiResult},
};
use futures::{
    future::{select, Either},
    pin_mut,
};
use std::{future::Future, sync::Arc, time::Duration};
use wasm_bindgen::prelude::*;

#[wasm_bindgen(module = "/platform.js")]
extern "C" {
    #[wasm_bindgen(catch, js_name = acquireWalletLock)]
    async fn acquire_lock(name: &str) -> Result<JsValue, JsValue>;
}

pub struct BrowserLock(JsValue);
impl Drop for BrowserLock {
    fn drop(&mut self) {
        if let Some(release) = self.0.dyn_ref::<js_sys::Function>() {
            let _ = release.call0(&JsValue::UNDEFINED);
        }
    }
}

pub async fn open_database(
    seed: &[u8; 64],
    name: &str,
) -> FfiResult<(Arc<BrowserDatabase>, BrowserLock)> {
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
    let key = format!("cdk_wallet_browser_v1_{name}");
    let lock = BrowserLock(acquire_lock(&key).await.map_err(|_| {
        FfiErr::new(
            CdkStatus::AlreadyOpen,
            "wallet lock unavailable (already open or Web Locks unsupported)",
        )
    })?);
    let fingerprint = cdk::util::hex::encode(seed_fingerprint(seed));
    let db = BrowserDatabase::open(key, fingerprint).map_err(|_| {
        FfiErr::new(
            CdkStatus::DatabaseError,
            "browser storage unavailable, corrupt, incompatible, or opened with a different seed",
        )
    })?;
    Ok((Arc::new(db), lock))
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
