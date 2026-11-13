//! Browser adapter over the SAME wallet policy and Spilman implementations as
//! the native bridge. The async JS ABI intentionally replaces blocking C calls.
#![cfg(target_arch = "wasm32")]
#![allow(dead_code, unused_imports)]
#[path = "../../../vendor/cdk-wallet-ffi/src/api.rs"]
mod api;
mod browser_db;
mod browser_onboarding;
mod browser_platform;
mod mint_policy;
#[path = "../../../vendor/cdk-wallet-ffi/src/spilman.rs"]
mod spilman;
#[path = "../../../vendor/cdk-wallet-ffi/src/status.rs"]
mod status;
#[path = "../../../vendor/cdk-wallet-ffi/src/wallet.rs"]
mod wallet;
pub use api::*;
pub use wallet::CdkWallet;

use safer_ffi::prelude::*;
use serde_json::{json, Value};
use status::*;
use wallet::{FfiErr, MintRecoveryReport};
use wasm_bindgen::prelude::*;

#[wasm_bindgen(start)]
pub fn initialize() {
    // Diagnostics identify the code location, never a panic payload that might
    // contain mnemonic/proof/token material.
    std::panic::set_hook(Box::new(|info| {
        let location = info
            .location()
            .map(|p| p.to_string())
            .unwrap_or_else(|| "unknown location".to_owned());
        web_sys::console::error_1(&JsValue::from_str(&format!(
            "Wallet Rust panic at {location}; reload required"
        )));
    }));
}

fn js_error(message: &str) -> JsValue {
    js_sys::Error::new(message).into()
}

/// Select the mint at compile time; start_onboarding independently validates it.
#[wasm_bindgen]
pub fn onboarding_mint() -> Result<String, JsValue> {
    #[cfg(feature = "local-mint-fixture")]
    {
        web_sys::window()
            .ok_or_else(|| js_error("unavailable"))?
            .location()
            .origin()
            .map_err(|_| js_error("unavailable"))
    }
    #[cfg(not(feature = "local-mint-fixture"))]
    {
        Ok("https://mint.minibits.cash/Bitcoin".to_owned())
    }
}
fn failure(e: FfiErr) -> Value {
    json!({"status":e.status as u8,"error":e.message,"operation_id":e.operation_id.map(|v| uuid::Uuid::from_bytes(v).to_string()),"sender_fee_sats":e.sender_fee_sats.to_string()})
}
fn reports(reports: Vec<MintRecoveryReport>) -> Value {
    Value::Array(reports.into_iter().map(|r| json!({"mint_url":r.mint_url,"recovered":r.recovered,"compensated":r.compensated,"skipped":r.skipped,"failed":r.failed,"status":r.status as u8,"error":r.message})).collect())
}

struct Args(Vec<Option<char_p::Box>>);
impl Args {
    fn new(raw: &str) -> Result<Self, JsValue> {
        if raw.len() > 8 * 1024 * 1024 {
            return Err(js_error("arguments exceed maximum size"));
        }
        let values: Vec<Option<String>> = serde_json::from_str(raw).map_err(|_| {
            js_error(
                "arguments must be a JSON array of strings or null; use decimal strings for u64",
            )
        })?;
        let mut out = Self(Vec::new());
        for v in values {
            out.0.push(match v {
                None => None,
                Some(s) => {
                    if s.len() > wallet::MAX_TOKEN_BYTES {
                        return Err(js_error("argument exceeds maximum size"));
                    }
                    Some(
                        char_p::Box::try_from(s)
                            .map_err(|_| js_error("NUL is not allowed in arguments"))?,
                    )
                }
            });
        }
        Ok(out)
    }
    fn c(&self, i: usize) -> Result<Option<char_p::Ref<'_>>, JsValue> {
        self.0
            .get(i)
            .map(|v| v.as_ref().map(|s| s.as_ref()))
            .ok_or_else(|| js_error("missing argument"))
    }
    fn text(&self, i: usize) -> Result<&str, JsValue> {
        self.0
            .get(i)
            .and_then(|v| v.as_ref())
            .map(|v| v.to_str())
            .ok_or_else(|| js_error("missing string argument"))
    }
    fn number(&self, i: usize) -> Result<u64, JsValue> {
        self.text(i)?
            .parse()
            .map_err(|_| js_error("expected an unsigned decimal integer string"))
    }
    fn keys(&self, i: usize) -> Result<Vec<cdk::nuts::SecretKey>, JsValue> {
        if self.c(i)?.is_none() || self.text(i)?.is_empty() {
            return Ok(vec![]);
        }
        if self.text(i)?.len() > 4096 {
            return Err(js_error("too many signing keys"));
        }
        self.text(i)?
            .split(',')
            .map(|k| {
                cdk::nuts::SecretKey::from_hex(k.trim())
                    .map_err(|_| js_error("invalid signing key"))
            })
            .collect()
    }
}
impl Drop for Args {
    fn drop(&mut self) {
        for v in &mut self.0 {
            api::cdk_string_free(v.take());
        }
    }
}

fn take(value: Option<char_p::Box>) -> Option<String> {
    let text = value.as_ref().map(|s| s.to_str().to_owned());
    api::cdk_string_free(value);
    text
}
fn string_result(r: CdkStringResult) -> Value {
    json!({"status":r.status as u8,"error":take(r.error),"value":take(r.value)})
}
fn amount_result(r: CdkReceiveResult) -> Value {
    json!({"status":r.status as u8,"error":take(r.error),"net_sats":r.net_sats.to_string()})
}
fn status_result(r: CdkStatusResult) -> Value {
    json!({"status":r.status as u8,"error":take(r.error)})
}

/// All non-wallet mnemonic and channel operations, backed by the native sources.
/// `arguments` is a JSON array of strings/null. No u64 ever crosses a JS Number.
#[wasm_bindgen]
pub fn call_pure(operation: &str, arguments: &str) -> Result<String, JsValue> {
    let a = Args::new(arguments)?;
    macro_rules! s { ($f:ident $(,$arg:expr)*) => { string_result(spilman::$f($($arg),*)) }; }
    macro_rules! z { ($f:ident $(,$arg:expr)*) => { status_result(spilman::$f($($arg),*)) }; }
    let value = match operation {
        "generate_mnemonic" => string_result(api::cdk_generate_mnemonic()),
        "mnemonic_to_seed" | "mnemonic_to_entropy" => {
            let r = if operation == "mnemonic_to_seed" {
                api::cdk_mnemonic_to_seed(a.c(0)?)
            } else {
                api::cdk_mnemonic_to_entropy(a.c(0)?)
            };
            let hex = cdk::util::hex::encode(&r.bytes[..]);
            api::cdk_bytes_free(r.bytes);
            json!({"status":r.status as u8,"error":take(r.error),"hex":hex})
        }
        "spilman_generate_keypair" => {
            let r = spilman::cdk_spilman_generate_keypair();
            json!({"status":r.status as u8,"error":take(r.error),"secret_key_hex":take(r.secret_key_hex),"pubkey_hex":take(r.pubkey_hex)})
        }
        "spilman_build_cashu_b_token" => {
            s!(cdk_spilman_build_cashu_b_token, a.c(0)?, a.c(1)?, a.c(2)?)
        }
        "spilman_build_cashu_a_token" => s!(cdk_spilman_build_cashu_a_token, a.c(0)?, a.c(1)?),
        "token_to_proofs_json" => s!(cdk_token_to_proofs_json, a.c(0)?, a.c(1)?),
        "spilman_secret_key_to_pubkey" => s!(cdk_spilman_secret_key_to_pubkey, a.c(0)?),
        "spilman_compute_channel_secret" => {
            s!(cdk_spilman_compute_channel_secret, a.c(0)?, a.c(1)?)
        }
        "spilman_compute_funding_token_amount" => amount_result(
            spilman::cdk_spilman_compute_funding_token_amount(a.number(0)?, a.c(1)?, a.number(2)?),
        ),
        "spilman_compute_channel_from_token" => s!(
            cdk_spilman_compute_channel_from_token,
            a.c(0)?,
            a.c(1)?,
            a.c(2)?,
            a.c(3)?,
            a.number(4)?,
            a.c(5)?,
            a.number(6)?
        ),
        "spilman_channel_parameters_get_channel_id" => s!(
            cdk_spilman_channel_parameters_get_channel_id,
            a.c(0)?,
            a.c(1)?,
            a.c(2)?
        ),
        "spilman_create_funding_outputs" => s!(
            cdk_spilman_create_funding_outputs,
            a.c(0)?,
            a.c(1)?,
            a.c(2)?
        ),
        "spilman_create_funding_swap" => s!(
            cdk_spilman_create_funding_swap,
            a.c(0)?,
            a.c(1)?,
            a.c(2)?,
            a.c(3)?
        ),
        "spilman_complete_funding_swap" => {
            s!(cdk_spilman_complete_funding_swap, a.c(0)?, a.c(1)?, a.c(2)?)
        }
        "spilman_construct_proofs" => s!(cdk_spilman_construct_proofs, a.c(0)?, a.c(1)?, a.c(2)?),
        "spilman_create_signed_balance_update" => s!(
            cdk_spilman_create_signed_balance_update,
            a.c(0)?,
            a.c(1)?,
            a.c(2)?,
            a.c(3)?,
            a.number(4)?
        ),
        "spilman_create_unsigned_balance_update" => s!(
            cdk_spilman_create_unsigned_balance_update,
            a.c(0)?,
            a.c(1)?,
            a.c(2)?,
            a.c(3)?,
            a.number(4)?
        ),
        "spilman_sign_with_tweaked_key_util" => s!(
            cdk_spilman_sign_with_tweaked_key_util,
            a.c(0)?,
            a.c(1)?,
            a.c(2)?
        ),
        "spilman_attach_signature_to_balance_update" => s!(
            cdk_spilman_attach_signature_to_balance_update,
            a.c(0)?,
            a.c(1)?,
            a.c(2)?,
            a.number(3)?
        ),
        "spilman_verify_valid_channel" => z!(
            cdk_spilman_verify_valid_channel,
            a.c(0)?,
            a.c(1)?,
            a.c(2)?,
            a.c(3)?
        ),
        "spilman_verify_balance_update" => z!(
            cdk_spilman_verify_balance_update,
            a.c(0)?,
            a.c(1)?,
            a.c(2)?,
            a.c(3)?,
            a.c(4)?,
            a.number(5)?,
            a.c(6)?
        ),
        "spilman_prepare_close_swap" => s!(
            cdk_spilman_prepare_close_swap,
            a.c(0)?,
            a.c(1)?,
            a.c(2)?,
            a.c(3)?,
            a.c(4)?,
            a.number(5)?,
            a.c(6)?,
            a.c(7)?
        ),
        "spilman_unblind_close_swap" => {
            let r = spilman::cdk_spilman_unblind_close_swap(
                a.c(0)?,
                a.c(1)?,
                a.c(2)?,
                a.c(3)?,
                a.c(4)?,
                a.c(5)?,
                a.number(6)?,
                a.c(7)?,
            );
            json!({"status":r.status as u8,"error":take(r.error),"receiver_proofs_json":take(r.receiver_proofs_json),"sender_proofs_json":take(r.sender_proofs_json),"receiver_sum":r.receiver_sum.to_string(),"sender_sum":r.sender_sum.to_string()})
        }
        "spilman_prepare_sender_refund" => s!(
            cdk_spilman_prepare_sender_refund,
            a.c(0)?,
            a.c(1)?,
            a.c(2)?,
            a.c(3)?,
            a.c(4)?,
            a.c(5)?,
            a.number(6)?,
            a.c(7)?
        ),
        "spilman_complete_sender_refund" => s!(
            cdk_spilman_complete_sender_refund,
            a.c(0)?,
            a.c(1)?,
            a.c(2)?,
            a.c(3)?,
            a.c(4)?,
            a.c(5)?,
            a.c(6)?
        ),
        _ => return Err(js_error("unknown pure operation")),
    };
    Ok(value.to_string())
}

#[wasm_bindgen]
pub struct BrowserWallet {
    inner: Option<CdkWallet>,
    startup: String,
    tasks: tokio::task::LocalSet,
}

#[wasm_bindgen]
pub async fn open_wallet(seed: &[u8], name: &str) -> Result<BrowserWallet, JsValue> {
    // CDK's persistent rate limiter spawns local Tokio tasks. LocalSet supplies
    // that task context; JS polls it cooperatively. No Runtime, threads or net.
    let tasks = tokio::task::LocalSet::new();
    let (inner, startup) = tasks
        .run_until(CdkWallet::open(seed, name))
        .await
        .map_err(|e| js_error(&failure(e).to_string()))?;
    Ok(BrowserWallet {
        inner: Some(inner),
        startup: reports(startup).to_string(),
        tasks,
    })
}

/// Provision an existing empty wallet name with a plaintext English BIP-39
/// mnemonic. Both records are written atomically, or nothing is written at all.
/// This is never called automatically: the game does not create a persistent
/// wallet on startup.
#[wasm_bindgen]
pub async fn provision_wallet(mnemonic: &str, name: &str) -> Result<(), JsValue> {
    browser_platform::provision_wallet(mnemonic, name)
        .await
        .map_err(|e| js_error(&failure(e).to_string()))
}

/// Test-only: exercises the real persistent-storage policy and denial path for
/// a wallet name without reading, writing or creating any wallet record. The
/// browser fixture uses it so it never touches the real user wallet.
#[wasm_bindgen]
pub async fn probe_persistent_storage(name: &str) -> Result<bool, JsValue> {
    browser_platform::probe_persistent_storage(name)
        .await
        .map_err(|e| js_error(&failure(e).to_string()))
}

#[wasm_bindgen]
impl BrowserWallet {
    pub fn startup_reports(&self) -> String {
        self.startup.clone()
    }

    /// Mutable async receiver rejects overlapping calls; JS facade queues them.
    pub async fn call(&mut self, operation: &str, arguments: &str) -> Result<String, JsValue> {
        let a = Args::new(arguments)?;
        let h = self
            .inner
            .as_mut()
            .ok_or_else(|| js_error("wallet is closed"))?;
        self.tasks.run_until(async {
        let value=match operation {
            "list_mints" => json!({"status":0,"mints":h.list_mints().await}),
            "list_balances" => match h.list_balances().await { Ok(b) => json!({"status":0,"balances":b.into_iter().map(|(mint,sats)| json!({"mint_url":mint,"sats":sats.to_string()})).collect::<Vec<_>>()}), Err(e) => failure(e) },
            "add_mint" => match h.add_mint(a.text(0)?).await { Ok(()) => json!({"status":0}), Err(e) => failure(e) },
            "receive" => match h.receive(a.text(0)?).await { Ok(n) => json!({"status":0,"net_sats":n.to_string()}), Err(e) => failure(e) },
            "send" => match h.send(a.text(0)?,a.number(1)?,a.number(2)?).await { Ok(r) => json!({"status":0,"token":r.token,"operation_id":uuid::Uuid::from_bytes(r.operation_id).to_string(),"sender_fee_sats":r.sender_fee_sats.to_string()}), Err(e) => failure(e) },
            "list_pending_tokens" => match h.list_pending_tokens().await { Ok(p) => json!({"status":0,"pending":p.into_iter().map(|p| json!({"operation_id":uuid::Uuid::from_bytes(p.operation_id).to_string(),"token":p.token})).collect::<Vec<_>>()}), Err(e) => failure(e) },
            "get_pending_token" => {
                let id=uuid::Uuid::parse_str(a.text(0)?).map_err(|_| js_error("invalid operation UUID"))?;
                match h.get_pending_token(id.as_bytes()).await { Ok(p) => json!({"status":0,"token":p.token,"operation_id":id.to_string()}), Err(e) => failure(e) }
            }
            "recover" => {
                // FIXME: Known browser send/swap recovery defects are not fixed here:
                // docs/browser-wallet.md#known-recovery-defects-reported-by-browser-tests
                let mint=if a.0.is_empty() || a.c(0)?.is_none() { None } else { Some(wallet::parse_mint_url(a.text(0)?).map_err(|e| js_error(&failure(e).to_string()))?) };
                match h.recover(mint.as_ref()).await { Ok(r) => json!({"status":0,"reports":reports(r)}), Err(e) => failure(e) }
            }
            "restore_seed" => match h.restore_seed(a.text(0)?).await { Ok((spendable,pending,spent)) => json!({"status":0,"spendable_sats":spendable.to_string(),"pending_sats":pending.to_string(),"spent_sats":spent.to_string()}), Err(e) => failure(e) },
            "restore_can_abandon" => match h.browser_restore_can_abandon().await { Ok((_revision,can_abandon)) => json!({"status":0,"can_abandon":can_abandon}), Err(e) => failure(e) },
            "get_active_keyset_info_json" => match h.active_keyset_info_json(a.text(0)?).await { Ok(v) => json!({"status":0,"value":v}), Err(e) => failure(e) },
            "get_keyset_info_json" => match h.keyset_info_json(a.text(0)?,a.text(1)?).await { Ok(v) => json!({"status":0,"value":v}), Err(e) => failure(e) },
            "post_swap" => match h.post_swap(a.text(0)?,a.text(1)?).await { Ok(v) => json!({"status":0,"value":v}), Err(e) => failure(e) },
            "receive_with_keys" => match h.receive_with_keys(a.text(0)?,&a.keys(1)?).await { Ok(n) => json!({"status":0,"net_sats":n.to_string()}), Err(e) => failure(e) },
            "receive_proofs" => {
                let proofs=serde_json::from_str(a.text(1)?).map_err(|_| js_error("invalid proofs JSON"))?;
                match h.receive_proofs(a.text(0)?,proofs,&a.keys(2)?).await { Ok(n) => json!({"status":0,"net_sats":n.to_string()}), Err(e) => failure(e) }
            }
            _ => return Err(js_error("unknown wallet operation")),
        };
        Ok(value.to_string())
        }).await
    }

    pub async fn close(&mut self) {
        if let Some(h) = self.inner.take() {
            self.tasks
                .run_until(async {
                    h.flush_rate_limits().await;
                    drop(h);
                })
                .await;
        }
    }
}
