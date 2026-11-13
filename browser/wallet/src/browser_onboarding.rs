use crate::{
    browser_db,
    browser_platform::{self, BrowserLock, USER_WALLET_NAME},
    mint_policy, wallet,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use wasm_bindgen::prelude::*;
use zeroize::Zeroizing;

#[wasm_bindgen(module = "/platform.js")]
extern "C" {
    #[wasm_bindgen(catch, js_name = loadOnboardingSnapshot)]
    async fn snapshot() -> Result<String, JsValue>;
    #[wasm_bindgen(catch, js_name = createOnboardingWallet)]
    async fn create(
        name: &str,
        mnemonic: &str,
        state: &str,
        marker: &JsValue,
        retired: &str,
    ) -> Result<(), JsValue>;
    #[wasm_bindgen(catch, js_name = onboardingRandomId)]
    fn random_id() -> Result<String, JsValue>;
    #[wasm_bindgen(catch, js_name = stageOnboardingWallet)]
    async fn stage(
        name: &str,
        id: &str,
        mnemonic: &str,
        state: &str,
        marker: &JsValue,
        retired: &str,
    ) -> Result<(), JsValue>;
    #[wasm_bindgen(catch, js_name = updateOnboardingScan)]
    async fn update_scan(
        name: &str,
        expected_marker: &JsValue,
        new_marker: &JsValue,
        expected_stage_revision: f64,
        expected_mnemonic: &str,
        expected_state_data: &str,
        expected_retired_json: &str,
    ) -> Result<(), JsValue>;
    #[wasm_bindgen(catch, js_name = completeOnboardingWallet)]
    async fn complete(
        name: &str,
        revision: f64,
        fingerprint: &str,
        state_revision: f64,
        mnemonic: &str,
        state: &str,
        retired: &str,
    ) -> Result<(), JsValue>;
    #[wasm_bindgen(catch, js_name = finishOnboardingRestore)]
    async fn finish_restore(
        name: &str,
        marker: &JsValue,
        revision: f64,
        mnemonic: &str,
        state: &str,
        retired: &str,
    ) -> Result<(), JsValue>;
    #[wasm_bindgen(catch, js_name = generateOnboardingWallet)]
    async fn generate_wallet(
        name: &str,
        marker: &JsValue,
        revision: f64,
        mnemonic: &str,
        state: &str,
        new_mnemonic: &str,
        new_state: &str,
        new_marker: &JsValue,
        retired: &str,
    ) -> Result<(), JsValue>;
}

const MAX_SAFE: u64 = 9_007_199_254_740_991;
const PREFIX: &str = "haystack-recovery-";

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Snapshot {
    has_marker: bool,
    #[serde(deserialize_with = "required_option")]
    marker: Option<SnapshotMarker>,
    entries: Vec<Entry>,
    wallets: Vec<Wallet>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Marker {
    version: u32,
    revision: u64,
    step: String,
    fingerprint: String,
}
#[derive(Deserialize)]
#[serde(untagged)]
enum SnapshotMarker {
    Basic(Marker),
    Active(ActiveMarker),
    Result(ResultMarker),
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ActiveMarker {
    version: u32,
    revision: u64,
    step: String,
    id: String,
    fingerprint: String,
    mint: String,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ResultMarker {
    version: u32,
    revision: u64,
    step: String,
    id: String,
    fingerprint: String,
    mint: String,
    spendable_sats: String,
    pending_sats: String,
    spent_sats: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    key: String,
    marker: Retired,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Retired {
    version: u32,
    step: String,
    id: String,
    fingerprint: String,
    mint: String,
    spendable_sats: String,
    pending_sats: String,
    spent_sats: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Wallet {
    name: String,
    has_mnemonic: bool,
    #[serde(deserialize_with = "required_option")]
    mnemonic: Option<String>,
    has_state: bool,
    #[serde(deserialize_with = "required_option")]
    state: Option<State>,
}
fn required_option<'de, D: serde::Deserializer<'de>, T: Deserialize<'de>>(
    d: D,
) -> Result<Option<T>, D::Error> {
    Option::deserialize(d)
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct State {
    revision: u64,
    data: String,
}
#[derive(Serialize)]
struct Expected {
    id: String,
    mnemonic: String,
    state: State,
    marker: Retired,
}
enum View {
    Choice,
    Ready,
    Backup {
        mnemonic: String,
        state: State,
        marker: Marker,
    },
    ResumeFailed,
    ResumeResult {
        spendable_sats: String,
        pending_sats: String,
        spent_sats: String,
        can_generate_new: bool,
    },
}
struct Audited {
    view: View,
    retired: String,
    active: Option<ActiveStage>,
}

struct ActiveStage {
    id: String,
    stage_name: String,
    marker: serde_json::Value,
    mnemonic: String,
    state: State,
    seed: Zeroizing<[u8; 64]>,
}

struct PreparedStage {
    id: String,
    stage: String,
    seed: Zeroizing<[u8; 64]>,
}

fn hex(s: &str, len: usize) -> bool {
    s.len() == len
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn pair(wallet: Wallet, expected: Option<&str>) -> Result<(String, State, String), ()> {
    if !wallet.has_mnemonic || !wallet.has_state {
        return Err(());
    }
    let mnemonic = wallet.mnemonic.ok_or(())?;
    let state = wallet.state.ok_or(())?;
    if state.revision > MAX_SAFE {
        return Err(());
    }
    let (normalized, seed) = browser_db::parse_mnemonic(&mnemonic).map_err(|_| ())?;
    let seed = Zeroizing::new(seed);
    let fingerprint = cdk::util::hex::encode(wallet::seed_fingerprint(&seed[..]));
    if expected.is_some_and(|s| s != fingerprint) {
        return Err(());
    }
    browser_db::validate_onboarding_store(&state.data, &fingerprint).map_err(|_| ())?;
    Ok((normalized, state, mnemonic))
}
fn canonical_amount(s: &str) -> bool {
    s.parse::<u64>().is_ok_and(|n| n.to_string() == s)
}
fn active_valid(
    version: u32,
    revision: u64,
    id: &str,
    fingerprint: &str,
    mint: &str,
    selected: &str,
) -> bool {
    version == 1
        && revision <= MAX_SAFE
        && hex(id, 32)
        && hex(fingerprint, 64)
        && mint == selected
        && wallet::parse_mint_url(mint).is_ok()
}
fn audit(raw: &str, selected_mint: &str) -> Result<Audited, ()> {
    let snapshot: Snapshot = serde_json::from_str(raw).map_err(|_| ())?;
    if snapshot.has_marker != snapshot.marker.is_some() {
        return Err(());
    }
    let mut wallets = HashMap::new();
    for w in snapshot.wallets {
        if w.has_mnemonic != w.mnemonic.is_some() || w.has_state != w.state.is_some() {
            return Err(());
        }
        if wallets.insert(w.name.clone(), w).is_some() {
            return Err(());
        }
    }
    let user = wallets.remove(USER_WALLET_NAME).ok_or(())?;
    let mut ids = HashSet::new();
    let mut retired = Vec::new();
    for entry in snapshot.entries {
        let marker = entry.marker;
        if marker.version != 1
            || marker.step != "retired"
            || !hex(&marker.id, 32)
            || !hex(&marker.fingerprint, 64)
            || entry.key != format!("retired:{}", marker.id)
            || !ids.insert(marker.id.clone())
            || marker.mint.is_empty()
            || marker.spendable_sats != "0"
            || marker.pending_sats != "0"
            || marker.spent_sats != "0"
        {
            return Err(());
        }
        let w = wallets
            .remove(&format!("{PREFIX}{}", marker.id))
            .ok_or(())?;
        let (_, state, mnemonic) = pair(w, Some(&marker.fingerprint))?;
        retired.push(Expected {
            id: marker.id.clone(),
            mnemonic,
            state,
            marker,
        });
    }
    let retired = serde_json::to_string(&retired).map_err(|_| ())?;
    let mut active = None;
    let view = match snapshot.marker {
        None if !user.has_mnemonic && !user.has_state => View::Choice,
        None => {
            pair(user, None)?;
            View::Ready
        }
        Some(SnapshotMarker::Basic(marker)) => {
            if marker.version != 1 || marker.revision > MAX_SAFE || !hex(&marker.fingerprint, 64) {
                return Err(());
            }
            let (normalized, state, raw) = pair(user, Some(&marker.fingerprint))?;
            match marker.step.as_str() {
                "complete" => View::Ready,
                "backup_seed" if normalized.split_whitespace().count() == 12 => View::Backup {
                    mnemonic: raw,
                    state,
                    marker,
                },
                _ => return Err(()),
            }
        }
        Some(SnapshotMarker::Active(marker)) => {
            if !matches!(marker.step.as_str(), "scanning" | "failed")
                || !active_valid(
                    marker.version,
                    marker.revision,
                    &marker.id,
                    &marker.fingerprint,
                    &marker.mint,
                    selected_mint,
                )
                || user.has_mnemonic
                || user.has_state
                || ids.contains(&marker.id)
            {
                return Err(());
            }
            let stage_name = format!("{PREFIX}{}", marker.id);
            let stage = wallets.remove(&stage_name).ok_or(())?;
            let (_, state, mnemonic) = pair(stage, Some(&marker.fingerprint))?;
            let (_, seed) = browser_db::parse_mnemonic(&mnemonic).map_err(|_| ())?;
            active = Some(ActiveStage {
                id: marker.id.clone(),
                stage_name,
                marker: serde_json::to_value(&marker).map_err(|_| ())?,
                mnemonic,
                state,
                seed: Zeroizing::new(seed),
            });
            View::ResumeFailed
        }
        Some(SnapshotMarker::Result(marker)) => {
            if marker.step != "result"
                || !active_valid(
                    marker.version,
                    marker.revision,
                    &marker.id,
                    &marker.fingerprint,
                    &marker.mint,
                    selected_mint,
                )
                || user.has_mnemonic
                || user.has_state
                || ids.contains(&marker.id)
                || !canonical_amount(&marker.spendable_sats)
                || !canonical_amount(&marker.pending_sats)
                || !canonical_amount(&marker.spent_sats)
            {
                return Err(());
            }
            let stage_name = format!("{PREFIX}{}", marker.id);
            let stage = wallets.remove(&stage_name).ok_or(())?;
            let (_, state, mnemonic) = pair(stage, Some(&marker.fingerprint))?;
            let can_generate_new = marker.spendable_sats == "0"
                && marker.pending_sats == "0"
                && marker.spent_sats == "0"
                && browser_db::onboarding_store_can_abandon(&state.data, &marker.fingerprint)
                    .map_err(|_| ())?;
            let view = View::ResumeResult {
                spendable_sats: marker.spendable_sats.clone(),
                pending_sats: marker.pending_sats.clone(),
                spent_sats: marker.spent_sats.clone(),
                can_generate_new,
            };
            let (_, seed) = browser_db::parse_mnemonic(&mnemonic).map_err(|_| ())?;
            active = Some(ActiveStage {
                id: marker.id.clone(),
                stage_name,
                marker: serde_json::to_value(&marker).map_err(|_| ())?,
                mnemonic,
                state,
                seed: Zeroizing::new(seed),
            });
            view
        }
    };
    if !wallets.is_empty() {
        return Err(());
    }
    Ok(Audited {
        view,
        retired,
        active,
    })
}

fn unavailable() -> JsValue {
    js_sys::Error::new("onboarding unavailable").into()
}
fn event(name: &str) -> String {
    json!({"event":name}).to_string()
}
fn retry_marker(marker: &serde_json::Value) -> Option<serde_json::Value> {
    let revision = marker.get("revision")?.as_u64()?;
    if revision >= MAX_SAFE {
        return None;
    }
    let mut scanning = marker.clone();
    let fields = scanning.as_object_mut()?;
    fields.insert("revision".into(), json!(revision + 1));
    fields.insert("step".into(), json!("scanning"));
    fields.remove("spendable_sats");
    fields.remove("pending_sats");
    fields.remove("spent_sats");
    Some(scanning)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RestoreArgs {
    phrase: String,
}
fn backup(mnemonic: &str) -> Result<String, ()> {
    let (normalized, seed) = browser_db::parse_mnemonic(mnemonic).map_err(|_| ())?;
    let _seed = Zeroizing::new(seed);
    Ok(json!({"event":"backup","mnemonic":normalized}).to_string())
}

#[wasm_bindgen]
pub struct BrowserOnboarding {
    lock: Option<BrowserLock>,
    mint: String,
}

impl BrowserOnboarding {
    /// The caller holds the user wallet lock and the scan has fully quiesced.
    async fn finish_scan(&self, expected_id: &str, outcome: Result<(u64, u64, u64), ()>) -> String {
        let failed_event = || {
            json!({"event":"restore_failed","stage_created":true,"can_generate_new":false})
                .to_string()
        };
        let audited = match snapshot()
            .await
            .ok()
            .and_then(|raw| audit(&raw, &self.mint).ok())
        {
            Some(audited) => audited,
            None => return failed_event(),
        };
        let stage = match audited.active {
            Some(stage) if stage.id == expected_id && stage.marker["step"] == "scanning" => stage,
            _ => return failed_event(),
        };
        let revision = match stage.marker["revision"].as_u64() {
            Some(revision) if revision < MAX_SAFE => revision + 1,
            _ => return failed_event(),
        };
        let expected = match js_sys::JSON::parse(&stage.marker.to_string()) {
            Ok(marker) => marker,
            Err(_) => return failed_event(),
        };
        let mut failed = stage.marker.clone();
        failed["revision"] = json!(revision);
        failed["step"] = json!("failed");
        let failed_marker = match js_sys::JSON::parse(&failed.to_string()) {
            Ok(marker) => marker,
            Err(_) => return failed_event(),
        };
        if let Ok((spendable, pending, spent)) = outcome {
            let mut result = stage.marker.clone();
            result["revision"] = json!(revision);
            result["step"] = json!("result");
            result["spendable_sats"] = json!(spendable.to_string());
            result["pending_sats"] = json!(pending.to_string());
            result["spent_sats"] = json!(spent.to_string());
            let fingerprint = stage.marker["fingerprint"].as_str().unwrap_or("");
            let can_generate_new = spendable == 0
                && pending == 0
                && spent == 0
                && browser_db::onboarding_store_can_abandon(&stage.state.data, fingerprint)
                    .unwrap_or(false);
            if let Ok(marker) = js_sys::JSON::parse(&result.to_string()) {
                if update_scan(
                    USER_WALLET_NAME,
                    &expected,
                    &marker,
                    stage.state.revision as f64,
                    &stage.mnemonic,
                    &stage.state.data,
                    &audited.retired,
                )
                .await
                .is_ok()
                {
                    return json!({"event":"restore_finished","report":{"spendable_sats":spendable.to_string(),"pending_sats":pending.to_string(),"spent_sats":spent.to_string(),"can_generate_new":can_generate_new}}).to_string();
                }
            }
        }
        let _ = update_scan(
            USER_WALLET_NAME,
            &expected,
            &failed_marker,
            stage.state.revision as f64,
            &stage.mnemonic,
            &stage.state.data,
            &audited.retired,
        )
        .await;
        failed_event()
    }

    /// The caller must hold the user wallet lock for the duration of the scan.
    async fn scan_stage(&self, stage: &str, seed: &[u8; 64]) -> Result<(u64, u64, u64), ()> {
        let tasks = tokio::task::LocalSet::new();
        let result = tasks
            .run_until(async {
                let (mut handle, reports) =
                    wallet::CdkWallet::open(seed, stage).await.map_err(|_| ())?;
                let result = if reports
                    .iter()
                    .any(|report| !report.status.is_ok() || report.skipped > 0 || report.failed > 0)
                {
                    Err(())
                } else {
                    handle.restore_seed(&self.mint).await.map_err(|_| ())
                };
                handle.flush_rate_limits().await;
                drop(handle);
                result
            })
            .await;
        drop(tasks);
        result
    }

    /// The caller must hold user_lock and pass an audited Choice snapshot.
    async fn prepare_stage(
        &self,
        mnemonic: &str,
        audited: Audited,
    ) -> Result<PreparedStage, JsValue> {
        if !matches!(audited.view, View::Choice) {
            return Err(unavailable());
        }
        let (normalized, seed) = browser_db::parse_mnemonic(mnemonic).map_err(|_| unavailable())?;
        let normalized = Zeroizing::new(normalized);
        let seed = Zeroizing::new(seed);
        if normalized.as_str() != mnemonic {
            return Err(unavailable());
        }
        let id = random_id().map_err(|_| unavailable())?;
        if !hex(&id, 32) {
            return Err(unavailable());
        }
        let fingerprint = cdk::util::hex::encode(wallet::seed_fingerprint(&seed[..]));
        let state =
            browser_db::initial_onboarding_store(fingerprint.clone()).map_err(|_| unavailable())?;
        let marker = json!({"version":1,"revision":0,"step":"scanning","id":id,"fingerprint":fingerprint,"mint":self.mint}).to_string();
        let marker = js_sys::JSON::parse(&marker).map_err(|_| unavailable())?;
        browser_platform::warn_if_storage_not_persistent().await;
        stage(
            USER_WALLET_NAME,
            &id,
            &normalized,
            &state,
            &marker,
            &audited.retired,
        )
        .await
        .map_err(|_| unavailable())?;
        Ok(PreparedStage {
            stage: format!("{PREFIX}{id}"),
            id,
            seed,
        })
    }
}

#[wasm_bindgen]
pub async fn start_onboarding(mint: &str) -> Result<BrowserOnboarding, JsValue> {
    #[cfg(feature = "local-mint-fixture")]
    let origin = web_sys::window()
        .ok_or_else(unavailable)?
        .location()
        .origin()
        .map_err(|_| unavailable())?;
    #[cfg(not(feature = "local-mint-fixture"))]
    let origin = String::new();
    if !mint_policy::allowed(mint, &origin) {
        return Err(unavailable());
    }
    let mint = wallet::parse_mint_url(mint)
        .map_err(|_| unavailable())?
        .to_string();
    let lock = browser_platform::onboarding_lock()
        .await
        .map_err(|_| unavailable())?;
    Ok(BrowserOnboarding {
        lock: Some(lock),
        mint,
    })
}

#[wasm_bindgen]
impl BrowserOnboarding {
    pub async fn request(&mut self, op: &str, args: &str) -> Result<String, JsValue> {
        if self.lock.is_none() {
            return Err(unavailable());
        }
        let phrase = if op == "restore" {
            let args: RestoreArgs = serde_json::from_str(args).map_err(|_| unavailable())?;
            if args.phrase.len() > 1024 || args.phrase.contains('\0') {
                return Err(unavailable());
            }
            Some(Zeroizing::new(args.phrase))
        } else if matches!(
            op,
            "inspect" | "create" | "complete_backup" | "retry" | "finish_restore" | "generate"
        ) && args == "{}"
        {
            None
        } else {
            return Err(unavailable());
        };
        let fail = if matches!(op, "complete_backup" | "finish_restore") {
            "complete_fail"
        } else {
            "blocked"
        };
        let _lock = match browser_platform::user_lock().await {
            Ok(lock) => lock,
            Err(_) => return Ok(event(fail)),
        };
        let audited = match snapshot()
            .await
            .ok()
            .and_then(|s| audit(&s, &self.mint).ok())
        {
            Some(v) => v,
            None => return Ok(event(fail)),
        };
        if op == "restore" {
            if !matches!(audited.view, View::Choice) {
                return Ok(event("blocked"));
            }
            let (normalized, seed) = match browser_db::parse_mnemonic(phrase.as_ref().unwrap()) {
                Ok(value) => value,
                Err(_) => return Ok(event("invalid_phrase")),
            };
            let normalized = Zeroizing::new(normalized);
            let _seed = Zeroizing::new(seed);
            let prepared = match self.prepare_stage(&normalized, audited).await {
                Ok(stage) => stage,
                Err(_) => return Ok(event("blocked")),
            };
            let outcome = self.scan_stage(&prepared.stage, &prepared.seed).await;
            return Ok(self.finish_scan(&prepared.id, outcome).await);
        }
        if op == "retry" {
            let failed = || {
                json!({"event":"restore_failed","stage_created":true,"can_generate_new":false})
                    .to_string()
            };
            if !matches!(audited.view, View::ResumeFailed | View::ResumeResult { .. }) {
                return Ok(event("blocked"));
            }
            let Some(active) = audited.active else {
                return Ok(event("blocked"));
            };
            let Some(scanning) = retry_marker(&active.marker) else {
                return Ok(failed());
            };
            let (Ok(expected), Ok(marker)) = (
                js_sys::JSON::parse(&active.marker.to_string()),
                js_sys::JSON::parse(&scanning.to_string()),
            ) else {
                return Ok(failed());
            };
            if update_scan(
                USER_WALLET_NAME,
                &expected,
                &marker,
                active.state.revision as f64,
                &active.mnemonic,
                &active.state.data,
                &audited.retired,
            )
            .await
            .is_err()
            {
                return Ok(failed());
            }
            let outcome = self.scan_stage(&active.stage_name, &active.seed).await;
            return Ok(self.finish_scan(&active.id, outcome).await);
        }
        if matches!(op, "finish_restore" | "generate") {
            let View::ResumeResult {
                spendable_sats,
                pending_sats,
                spent_sats,
                can_generate_new,
            } = &audited.view
            else {
                return Ok(event(fail));
            };
            let nonzero = spendable_sats != "0" || pending_sats != "0" || spent_sats != "0";
            if (op == "finish_restore" && !nonzero)
                || (op == "generate" && (nonzero || !can_generate_new))
            {
                return Ok(event(fail));
            }
            let Some(active) = audited.active else {
                return Ok(event(fail));
            };
            let Ok(marker) = js_sys::JSON::parse(&active.marker.to_string()) else {
                return Ok(event(fail));
            };
            if op == "finish_restore" {
                return Ok(event(
                    if finish_restore(
                        USER_WALLET_NAME,
                        &marker,
                        active.state.revision as f64,
                        &active.mnemonic,
                        &active.state.data,
                        &audited.retired,
                    )
                    .await
                    .is_ok()
                    {
                        "complete_success"
                    } else {
                        fail
                    },
                ));
            }
            let Ok(phrase) = bip39::Mnemonic::generate(12) else {
                return Ok(event(fail));
            };
            let mnemonic = Zeroizing::new(phrase.to_string());
            let seed = Zeroizing::new(phrase.to_seed(""));
            let fingerprint = cdk::util::hex::encode(wallet::seed_fingerprint(&seed[..]));
            if active.marker["fingerprint"].as_str() == Some(&fingerprint) {
                return Ok(event(fail));
            }
            let Ok(state) = browser_db::initial_onboarding_store(fingerprint.clone()) else {
                return Ok(event(fail));
            };
            let new_marker =
                json!({"version":1,"revision":0,"step":"backup_seed","fingerprint":fingerprint});
            let Ok(new_marker) = js_sys::JSON::parse(&new_marker.to_string()) else {
                return Ok(event(fail));
            };
            browser_platform::warn_if_storage_not_persistent().await;
            if generate_wallet(
                USER_WALLET_NAME,
                &marker,
                active.state.revision as f64,
                &active.mnemonic,
                &active.state.data,
                &mnemonic,
                &state,
                &new_marker,
                &audited.retired,
            )
            .await
            .is_err()
            {
                return Ok(event(fail));
            }
            return Ok(backup(&mnemonic).unwrap_or_else(|_| event(fail)));
        }
        match (op, audited.view) {
            ("inspect", View::Choice) => {
                Ok(json!({"event":"choice","recover_enabled":true}).to_string())
            }
            ("inspect", View::Ready) => Ok(event("ready")),
            ("inspect", View::ResumeFailed) => Ok(json!({"event":"resume_failed","can_generate_new":false}).to_string()),
            ("inspect", View::ResumeResult { spendable_sats, pending_sats, spent_sats, can_generate_new }) => Ok(json!({"event":"resume_result","report":{"spendable_sats":spendable_sats,"pending_sats":pending_sats,"spent_sats":spent_sats,"can_generate_new":can_generate_new}}).to_string()),
            ("inspect", View::Backup { mnemonic, .. }) => {
                Ok(backup(&mnemonic).unwrap_or_else(|_| event(fail)))
            }
            ("create", View::Choice) => {
                let phrase = match bip39::Mnemonic::generate(12) {
                    Ok(v) => v,
                    Err(_) => return Ok(event(fail)),
                };
                let mnemonic = Zeroizing::new(phrase.to_string());
                let seed = Zeroizing::new(phrase.to_seed(""));
                let fingerprint = cdk::util::hex::encode(wallet::seed_fingerprint(&seed[..]));
                let state = match browser_db::initial_onboarding_store(fingerprint.clone()) {
                    Ok(v) => v,
                    Err(_) => return Ok(event(fail)),
                };
                let marker = json!({"version":1,"revision":0,"step":"backup_seed","fingerprint":fingerprint}).to_string();
                let marker = js_sys::JSON::parse(&marker).map_err(|_| unavailable())?;
                browser_platform::warn_if_storage_not_persistent().await;
                if create(
                    USER_WALLET_NAME,
                    &mnemonic,
                    &state,
                    &marker,
                    &audited.retired,
                )
                .await
                .is_err()
                {
                    return Ok(event(fail));
                }
                Ok(backup(&mnemonic).unwrap_or_else(|_| event(fail)))
            }
            (
                "complete_backup",
                View::Backup {
                    mnemonic,
                    state,
                    marker,
                },
            ) => {
                if complete(
                    USER_WALLET_NAME,
                    marker.revision as f64,
                    &marker.fingerprint,
                    state.revision as f64,
                    &mnemonic,
                    &state.data,
                    &audited.retired,
                )
                .await
                .is_err()
                {
                    return Ok(event(fail));
                }
                Ok(event("complete_success"))
            }
            _ => Ok(event(fail)),
        }
    }
    pub fn close(&mut self) {
        self.lock.take();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const WORDS: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn retry_marker_removes_results_and_checks_revision() {
        let mut marker = json!({"version":1,"revision":4,"step":"result","id":"id","fingerprint":"fingerprint","mint":"mint","spendable_sats":"1","pending_sats":"2","spent_sats":"3"});
        assert_eq!(
            retry_marker(&marker).unwrap(),
            json!({"version":1,"revision":5,"step":"scanning","id":"id","fingerprint":"fingerprint","mint":"mint"})
        );
        marker["revision"] = json!(MAX_SAFE);
        assert!(retry_marker(&marker).is_none());
    }

    fn records() -> (serde_json::Value, String) {
        let (_, seed) = browser_db::parse_mnemonic(WORDS).unwrap();
        let fingerprint = cdk::util::hex::encode(wallet::seed_fingerprint(&seed));
        let data = browser_db::initial_onboarding_store(fingerprint.clone()).unwrap();
        (
            json!({"hasMarker":false,"marker":null,"entries":[],"wallets":[{"name":USER_WALLET_NAME,"hasMnemonic":false,"mnemonic":null,"hasState":false,"state":null}]}),
            data,
        )
    }

    #[test]
    fn choice_legacy_backup_complete_and_invalid() {
        let (mut s, data) = records();
        assert!(audit(&s.to_string(), "https://example.com/")
            .unwrap()
            .active
            .is_none());
        assert!(matches!(
            audit(&s.to_string(), "https://example.com/").unwrap().view,
            View::Choice
        ));
        let (_, seed) = browser_db::parse_mnemonic(WORDS).unwrap();
        let fingerprint = cdk::util::hex::encode(wallet::seed_fingerprint(&seed));
        s["wallets"][0] = json!({"name":USER_WALLET_NAME,"hasMnemonic":true,"mnemonic":WORDS,"hasState":true,"state":{"revision":0,"data":data}});
        assert!(audit(&s.to_string(), "https://example.com/")
            .unwrap()
            .active
            .is_none());
        assert!(matches!(
            audit(&s.to_string(), "https://example.com/").unwrap().view,
            View::Ready
        ));
        s["hasMarker"] = json!(true);
        s["marker"] =
            json!({"version":1,"revision":0,"step":"backup_seed","fingerprint":fingerprint});
        assert!(audit(&s.to_string(), "https://example.com/")
            .unwrap()
            .active
            .is_none());
        assert!(matches!(
            audit(&s.to_string(), "https://example.com/").unwrap().view,
            View::Backup { .. }
        ));
        s["marker"]["step"] = json!("complete");
        assert!(audit(&s.to_string(), "https://example.com/")
            .unwrap()
            .active
            .is_none());
        assert!(matches!(
            audit(&s.to_string(), "https://example.com/").unwrap().view,
            View::Ready
        ));
        s["wallets"][0]["state"]["data"] = json!("{}");
        assert!(audit(&s.to_string(), "https://example.com/").is_err());
    }

    #[test]
    fn retired_pair_is_required_and_bound_to_fingerprint() {
        let (mut s, data) = records();
        let (_, seed) = browser_db::parse_mnemonic(WORDS).unwrap();
        let fingerprint = cdk::util::hex::encode(wallet::seed_fingerprint(&seed));
        let id = "0123456789abcdef0123456789abcdef";
        s["entries"] = json!([{"key":format!("retired:{id}"),"marker":{"version":1,"step":"retired","id":id,"fingerprint":fingerprint,"mint":"https://example.com","spendable_sats":"0","pending_sats":"0","spent_sats":"0"}}]);
        assert!(audit(&s.to_string(), "https://example.com/").is_err());
        s["wallets"].as_array_mut().unwrap().push(json!({"name":format!("{PREFIX}{id}"),"hasMnemonic":true,"mnemonic":WORDS,"hasState":true,"state":{"revision":3,"data":data}}));
        assert!(matches!(
            audit(&s.to_string(), "https://example.com/").unwrap().view,
            View::Choice
        ));
        s["entries"][0]["marker"]["fingerprint"] = json!("0".repeat(64));
        assert!(audit(&s.to_string(), "https://example.com/").is_err());
    }

    #[test]
    fn active_recovery_is_strict_and_audits_result() {
        let (mut s, data) = records();
        let (_, seed) = browser_db::parse_mnemonic(WORDS).unwrap();
        let fingerprint = cdk::util::hex::encode(wallet::seed_fingerprint(&seed));
        let id = "0123456789abcdef0123456789abcdef";
        let mint = "https://example.com/";
        s["hasMarker"] = json!(true);
        s["marker"] = json!({"version":1,"revision":0,"step":"scanning","id":id,"fingerprint":fingerprint,"mint":mint});
        s["wallets"].as_array_mut().unwrap().push(json!({"name":format!("{PREFIX}{id}"),"hasMnemonic":true,"mnemonic":WORDS,"hasState":true,"state":{"revision":0,"data":data}}));
        for step in ["scanning", "failed"] {
            s["marker"]["step"] = json!(step);
            let audited = audit(&s.to_string(), mint).unwrap();
            let active = audited.active.unwrap();
            assert_eq!(active.id, id);
            assert_eq!(active.stage_name, format!("{PREFIX}{id}"));
            assert_eq!(active.marker, s["marker"]);
            assert_eq!(active.mnemonic, WORDS);
            assert_eq!(active.state.revision, 0);
            assert_eq!(active.state.data, data);
            assert_eq!(&active.seed[..], &seed[..]);
        }
        assert!(matches!(
            audit(&s.to_string(), mint).unwrap().view,
            View::ResumeFailed
        ));
        s["marker"]["step"] = json!("failed");
        assert!(matches!(
            audit(&s.to_string(), mint).unwrap().view,
            View::ResumeFailed
        ));
        s["marker"]["step"] = json!("result");
        s["marker"]["spendable_sats"] = json!("0");
        s["marker"]["pending_sats"] = json!("0");
        s["marker"]["spent_sats"] = json!("0");
        let active = audit(&s.to_string(), mint).unwrap().active.unwrap();
        assert_eq!(active.marker, s["marker"]);
        assert_eq!(active.mnemonic, WORDS);
        assert_eq!(active.state.data, data);
        assert_eq!(&active.seed[..], &seed[..]);
        assert!(matches!(
            audit(&s.to_string(), mint).unwrap().view,
            View::ResumeResult {
                can_generate_new: true,
                ..
            }
        ));
        s["marker"]["spent_sats"] = json!("1");
        assert!(matches!(
            audit(&s.to_string(), mint).unwrap().view,
            View::ResumeResult {
                can_generate_new: false,
                ..
            }
        ));
        s["marker"]["spent_sats"] = json!("00");
        assert!(audit(&s.to_string(), mint).is_err());
        s["marker"]["spent_sats"] = json!("0");
        s["marker"]["fingerprint"] = json!("0".repeat(64));
        assert!(audit(&s.to_string(), mint).is_err());
        s["marker"]["fingerprint"] = json!(fingerprint);
        s["marker"]["unexpected"] = json!(true);
        assert!(audit(&s.to_string(), mint).is_err());
        s["marker"].as_object_mut().unwrap().remove("unexpected");
        assert!(audit(&s.to_string(), "https://other.example/").is_err());
        s["wallets"].as_array_mut().unwrap().pop();
        assert!(audit(&s.to_string(), mint).is_err());
    }
}
