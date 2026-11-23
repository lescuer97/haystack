//! Durable browser sender balance and settlement checkpoints. Zig owns the
//! authenticated game exchange; the wallet owns signing and mint credit.
use super::{browser_db::kv_key, hoe_funding as funding, Args, CdkStatus, CdkWallet, FfiErr};
use cdk::nuts::Proof;
use cdk_common::database::{Error as DbError, WalletDatabase};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use uuid::Uuid;
use zeroize::Zeroizing;

const NS: &str = "browser_hoe";
const KEY: &str = "payment_v1";

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Tool {
    Axe,
    #[default]
    Hoe,
    Pickaxe,
}

impl Tool {
    pub(super) const ALL: [Self; 3] = [Self::Axe, Self::Hoe, Self::Pickaxe];
    pub(super) const MAX_CUTS: u64 = 10;

    pub(super) fn parse(name: &str) -> Result<Self> {
        match name {
            "axe" => Ok(Self::Axe),
            "hoe" => Ok(Self::Hoe),
            "pickaxe" => Ok(Self::Pickaxe),
            _ => Err(invalid()),
        }
    }

    pub(super) fn is_hoe(&self) -> bool {
        *self == Self::Hoe
    }

    pub(super) fn slot(self) -> &'static str {
        match self {
            Self::Axe => "axe",
            Self::Hoe => "", // Preserve the deployed hoe keys.
            Self::Pickaxe => "pickaxe",
        }
    }

    pub(super) fn price(self) -> u64 {
        match self {
            Self::Axe => 2,
            Self::Hoe => 5,
            Self::Pickaxe => 10,
        }
    }

    pub(super) fn valid_capacity(self, capacity: u64) -> bool {
        let price = self.price();
        (price..=price * Self::MAX_CUTS).contains(&capacity) && capacity % price == 0
    }

    pub(super) fn max_debit(self) -> u64 {
        self.price() * Self::MAX_CUTS
            + if cfg!(feature = "local-mint-fixture") {
                0
            } else {
                5
            }
    }
}

type Result<T> = std::result::Result<T, FfiErr>;

#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Payment {
    operation: Uuid,
    balance: u64,
    pending: Option<Pending>,
    receipt: Option<Receipt>,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Pending {
    id: String,
    amount: u64,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    hash: [u8; 32],
    net: Option<u64>,
}

fn recovery() -> FfiErr {
    FfiErr::new(
        CdkStatus::RecoveryPending,
        "hoe operation needs reconciliation",
    )
}

fn invalid() -> FfiErr {
    FfiErr::new(
        CdkStatus::InvalidArgument,
        "invalid hoe operation arguments",
    )
}

fn database(_: impl std::fmt::Display) -> FfiErr {
    FfiErr::new(
        CdkStatus::DatabaseError,
        "could not read or commit hoe sender state",
    )
}

fn text(args: &Args, i: usize) -> Result<&str> {
    args.text(i).map_err(|_| invalid())
}

fn number(args: &Args, i: usize) -> Result<u64> {
    args.number(i).map_err(|_| invalid())
}

fn hex(text: &str, size: usize) -> bool {
    text.len() == 2 * size
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

async fn read(
    wallet: &CdkWallet,
    record: &funding::FundingRecord,
) -> Result<(Option<Vec<u8>>, Option<Payment>)> {
    let price = record.tool.price();
    let prior = wallet
        .browser_database()
        .kv_read(NS, record.tool.slot(), KEY)
        .await
        .map_err(database)?;
    let saved: Option<Payment> = prior
        .as_deref()
        .map(serde_json::from_slice)
        .transpose()
        .map_err(database)?;
    let payment = match saved {
        Some(state) if state.operation == record.operation_id => {
            if state.balance > record.capacity_msats
                || state.balance % price != 0
                || state.pending.as_ref().is_some_and(|p| {
                    !hex(&p.id, 16)
                        || p.amount != state.balance + price
                        || p.amount > record.capacity_msats
                })
                || (state.pending.is_some() && state.receipt.is_some())
            {
                return Err(recovery());
            }
            Some(state)
        }
        // Only a completed receipt may be superseded by a later funding slot.
        Some(state) if !state.receipt.as_ref().is_some_and(|r| r.net.is_some()) => {
            return Err(recovery())
        }
        _ => None,
    };
    Ok((prior, payment))
}

async fn save(
    wallet: &CdkWallet,
    tool: Tool,
    prior: Option<&[u8]>,
    payment: &Payment,
) -> Result<Vec<u8>> {
    let next = serde_json::to_vec(payment).map_err(database)?;
    let key = kv_key(NS, tool.slot(), KEY);
    wallet
        .browser_database()
        .write(|store| {
            if store.kv.get(&key).map(Vec::as_slice) != prior {
                return Err(DbError::Internal("hoe sender state changed".into()));
            }
            store.kv.insert(key, next.clone());
            Ok(())
        })
        .await
        .map_err(database)?;
    Ok(next)
}

fn initial(record: &funding::FundingRecord) -> Payment {
    Payment {
        operation: record.operation_id,
        ..Payment::default()
    }
}

fn reconcile(state: &mut Payment, capacity: u64, accepted: u64) -> Result<()> {
    if accepted > capacity
        || (accepted != state.balance
            && !state.pending.as_ref().is_some_and(|p| p.amount == accepted))
    {
        return Err(recovery());
    }
    state.balance = accepted;
    state.pending = None;
    Ok(())
}

fn resolve(state: &mut Payment, id: &str, charged: bool) -> Result<()> {
    if state.receipt.is_some() {
        return Err(recovery());
    }
    let pending = state
        .pending
        .as_ref()
        .filter(|p| p.id == id)
        .ok_or_else(recovery)?;
    if charged {
        state.balance = pending.amount;
    }
    state.pending = None;
    Ok(())
}

fn balance(state: &Payment) -> Value {
    json!({"balance_msats": state.balance.to_string()})
}

pub(super) async fn request(
    wallet: &mut CdkWallet,
    tool: Tool,
    op: &str,
    args: &Args,
) -> Result<Value> {
    if wallet.is_poisoned() {
        return Err(super::api::poisoned_handle());
    }
    match op {
        "quote" => return funding::quote(wallet, tool, args).await,
        "fund" => return funding::fund(wallet, tool, args).await,
        "resume_quote" => return funding::resume_quote(wallet, tool, args).await,
        "resume" => return funding::resume(wallet, tool, args).await,
        _ => {}
    }
    let count = match op {
        "inspect" => 1,
        "open_payload" => 2,
        "prepare_cut" => 3,
        "bind" | "resolve_cut" => 4,
        "finalize" => 5,
        _ => return Err(invalid()),
    };
    if args.0.len() != count {
        return Err(invalid());
    }
    let scope = text(args, 0)?;
    let record = if op == "inspect" {
        funding::recover(wallet, tool, scope).await?
    } else {
        funding::load(wallet, tool).await?
    };
    let Some(record) = record else {
        return if op == "inspect" {
            Ok(json!({"channel_id":null}))
        } else {
            Err(recovery())
        };
    };
    if record.scope != scope
        || record.funding_proofs_json().is_none()
        || (count > 1 && text(args, 1)? != record.channel_id)
    {
        return Err(recovery());
    }
    let (prior, saved) = read(wallet, &record).await?;
    let admitted = saved.is_some();
    let mut state = saved.unwrap_or_else(|| initial(&record));
    match op {
        "inspect" => Ok(json!({
            "channel_id": record.channel_id,
            "capacity_msats": record.capacity_msats.to_string(),
            "refund_time": record.refund_time.to_string(),
            "balance_msats": state.balance.to_string(),
            "admitted": admitted,
        })),
        "open_payload" if !admitted => record.open_payload(),
        "bind" if state.receipt.is_none() && number(args, 2)? == record.capacity_msats => {
            reconcile(&mut state, record.capacity_msats, number(args, 3)?)?;
            save(wallet, tool, prior.as_deref(), &state).await?;
            Ok(balance(&state))
        }
        "prepare_cut" if admitted && state.pending.is_none() && state.receipt.is_none() => {
            let id = text(args, 2)?;
            let next = state.balance + tool.price();
            let now = (js_sys::Date::now() / 1000.0) as u64;
            if !hex(id, 16)
                || next > record.capacity_msats
                || record.refund_time.saturating_sub(now) <= 120
            {
                return Err(invalid());
            }
            let key = player_key(wallet, &record)?;
            let secret = Zeroizing::new(key.to_secret_hex());
            let signed = cdk_spilman::create_signed_balance_update(
                &record.params_json,
                &record.keyset_json,
                &secret,
                record.funding_proofs_json().ok_or_else(recovery)?,
                next,
            )
            .map_err(|_| recovery())?;
            let signed: Value = serde_json::from_str(&signed).map_err(|_| recovery())?;
            let signature = signed["signature"]
                .as_str()
                .filter(|s| hex(s, 64))
                .ok_or_else(recovery)?;
            if signed["channel_id"].as_str() != Some(&record.channel_id)
                || signed["amount"].as_u64() != Some(next)
            {
                return Err(recovery());
            }
            state.pending = Some(Pending {
                id: id.to_owned(),
                amount: next,
            });
            save(wallet, tool, prior.as_deref(), &state).await?;
            Ok(json!({"signature": signature, "balance_msats": next.to_string()}))
        }
        "resolve_cut" if admitted => {
            let charged = match text(args, 3)? {
                "charged" => true,
                "not_charged" => false,
                _ => return Err(invalid()),
            };
            resolve(&mut state, text(args, 2)?, charged)?;
            save(wallet, tool, prior.as_deref(), &state).await?;
            Ok(balance(&state))
        }
        "finalize" if number(args, 2)? == record.capacity_msats => {
            let proofs = args
                .c(4)
                .map_err(|_| invalid())?
                .map(|v| v.to_str())
                .unwrap_or("");
            finalize(
                wallet,
                &record,
                state,
                prior.as_deref(),
                number(args, 3)?,
                proofs,
            )
            .await
        }
        _ => Err(recovery()),
    }
}

fn player_key(wallet: &CdkWallet, record: &funding::FundingRecord) -> Result<cdk::nuts::SecretKey> {
    wallet
        .browser_game_signer()
        .and_then(|s| s.signing_key())
        .filter(|k| k.public_key().to_hex() == record.sender_pubkey)
        .ok_or_else(recovery)
}

fn credit_unknown() -> FfiErr {
    FfiErr::new(CdkStatus::RecoveryPending, "hoe_settlement_credit_unknown")
}

// Keep the existing nonzero error envelope so older clients don't treat a
// blocked preflight as successful settlement.
fn settlement_error(prefix: &str, mut err: FfiErr) -> FfiErr {
    err.message = format!("{prefix}: {}", err.message);
    err
}

fn needs_credit_checkpoint(receipt: Option<&Receipt>, hash: [u8; 32]) -> Result<bool> {
    match receipt {
        None => Ok(true),
        Some(receipt) if receipt.net.is_none() => Err(credit_unknown()),
        Some(receipt) if receipt.hash == hash => Ok(false),
        Some(_) => Err(recovery()),
    }
}

async fn finalize(
    wallet: &mut CdkWallet,
    record: &funding::FundingRecord,
    mut state: Payment,
    prior: Option<&[u8]>,
    accepted: u64,
    proofs: &str,
) -> Result<Value> {
    if proofs.len() > 60 * 1024 {
        return Err(invalid());
    }
    reconcile(&mut state, record.capacity_msats, accepted)?;
    let hash = Sha256::digest(proofs.as_bytes()).into();
    if needs_credit_checkpoint(state.receipt.as_ref(), hash)? {
        let parsed: Vec<Proof> = if proofs.is_empty() {
            vec![]
        } else {
            serde_json::from_str(proofs).map_err(|_| invalid())?
        };
        let gross = parsed
            .iter()
            .try_fold(0u64, |sum, p| sum.checked_add(u64::from(p.amount)))
            .ok_or_else(invalid)?;
        if !parsed.is_empty() && gross == 0 {
            return Err(invalid());
        }
        if gross > record.capacity_msats - accepted {
            return Err(recovery());
        }
        let key = player_key(wallet, record)?;
        if parsed.is_empty() {
            state.receipt = Some(Receipt { hash, net: Some(0) });
            save(wallet, record.tool, prior, &state).await?;
        } else {
            let receive = wallet
                .prepare_receive_proofs(&record.mint_url, parsed, &[key])
                .await
                .map_err(|err| settlement_error("hoe_settlement_preflight", err))?;
            state.receipt = Some(Receipt { hash, net: None });
            let attempted = save(receive.owner(), record.tool, prior, &state).await?;
            // From the durable attempt onward, never infer that it is safe to
            // replay wallet credit from an error status alone.
            let net = receive.execute().await.map_err(|_| credit_unknown())?;
            if net == 0 || net > gross {
                return Err(credit_unknown());
            }
            state.receipt = Some(Receipt {
                hash,
                net: Some(net),
            });
            save(wallet, record.tool, Some(&attempted), &state)
                .await
                .map_err(|_| credit_unknown())?;
        }
    }
    funding::release(wallet, record.tool, &record.scope, &record.channel_id)
        .await
        .map_err(|err| settlement_error("hoe_settlement_release_pending", err))?;
    Ok(json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attempted_credit_never_reenters_preflight_or_release() {
        let hash = [1; 32];
        let attempted = Receipt { hash, net: None };
        assert!(needs_credit_checkpoint(None, hash).unwrap());
        for request_hash in [hash, [2; 32]] {
            let err = needs_credit_checkpoint(Some(&attempted), request_hash).unwrap_err();
            assert_eq!(err.status, CdkStatus::RecoveryPending);
            assert_eq!(err.message, "hoe_settlement_credit_unknown");
        }
    }

    #[test]
    fn only_a_matching_completed_receipt_can_resume_release() {
        let hash = [1; 32];
        for net in [0, 5] {
            let complete = Receipt {
                hash,
                net: Some(net),
            };
            assert!(!needs_credit_checkpoint(Some(&complete), hash).unwrap());
            assert!(needs_credit_checkpoint(Some(&complete), [2; 32]).is_err());
        }
    }

    #[test]
    fn only_the_original_request_or_exact_authoritative_balances_resolve_a_cut() {
        let mut state = Payment {
            balance: 5,
            pending: Some(Pending {
                id: "original".into(),
                amount: 10,
            }),
            ..Payment::default()
        };
        let original = state.clone();
        assert!(resolve(&mut state, "another", true).is_err());
        assert!(reconcile(&mut state, 20, 15).is_err());
        assert!(state == original);
        for accepted in [5, 10] {
            let mut state = original.clone();
            reconcile(&mut state, 20, accepted).unwrap();
            assert_eq!(state.balance, accepted);
            assert!(state.pending.is_none());
        }
        resolve(&mut state, "original", false).unwrap();
        assert_eq!(state.balance, 5);
    }
}
