//! Paid tool opening: one journaled NUT-03 swap for a verified channel and free change.
//! Recovery is read-only at the mint unless the user reauthorizes the exact saved request.
use super::{
    browser_db::kv_key, hoe::Tool, onboarding_mint, wallet, Args, CdkStatus, CdkWallet, FfiErr,
};
use cdk::{
    mint_url::MintUrl,
    nuts::{
        nut10::SpendingConditions, CurrencyUnit, Proof, PublicKey, SecretKey, State, SwapRequest,
        SwapResponse,
    },
};
use cdk_common::{
    database::{Error as DbError, WalletDatabase},
    wallet::ProofInfo,
};
use cdk_spilman::{
    complete_funding_swap_with_plain_change, compute_funding_token_amount,
    create_funding_swap_with_plain_change, parse_keyset_info_from_json, verify_valid_channel,
    ChannelParameters, KeysetInfo,
};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use uuid::Uuid;

pub(super) type BridgeError = FfiErr;
type Result<T> = std::result::Result<T, BridgeError>;
const NS: &str = "browser_hoe_funding";
const RECORD: &str = "record";
const OFFER: &str = "offer";
const LAST_SETUP: &str = "last_setup";
const VERSION: u32 = 2;
const MIN_OPEN_SECONDS: u64 = 300;
// Leave room for the wallet's 60-second mint request and server admission.
const FUNDING_MARGIN_SECONDS: u64 = 90;
const CONSENT_SECONDS: u64 = 60;
const MAX_OUTPUT: u64 = 1_000_000;
const MAX_PARAMS_BYTES: usize = 4096;
const MAX_PROOF_BYTES: usize = 3072;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Terms {
    scope: String,
    receiver_pubkey: String,
    amount_msats: u64,
    refund_time: u64,
    player_pubkey: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Offer {
    version: u32,
    id: Uuid,
    terms: Terms,
    mint_url: String,
    sender_pubkey: String,
    expires_at: u64,
    capacity_msats: u64,
    nominal_msats: u64,
    debit_msats: u64,
    keyset: Value,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct FundingRecord {
    version: u32,
    #[serde(default, skip_serializing_if = "Tool::is_hoe")]
    pub(super) tool: Tool,
    pub(super) operation_id: Uuid,
    pub(super) scope: String,
    pub(super) mint_url: String,
    pub(super) sender_pubkey: String,
    pub(super) receiver_pubkey: String,
    pub(super) capacity_msats: u64,
    pub(super) refund_time: u64,
    pub(super) channel_id: String,
    pub(super) params_json: String,
    pub(super) keyset_json: String,
    pub(super) channel_secret_hex: String,
    state: FundingState,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "snake_case", deny_unknown_fields)]
enum FundingState {
    Submitted {
        swap_request_json: String,
        funding_secrets_json: String,
        change_secrets_json: String,
    },
    Funded {
        funding_proofs_json: String,
    },
}

impl FundingRecord {
    pub(super) fn funding_proofs_json(&self) -> Option<&str> {
        match &self.state {
            FundingState::Funded {
                funding_proofs_json,
            } => Some(funding_proofs_json),
            FundingState::Submitted { .. } => None,
        }
    }

    pub(super) fn open_payload(&self) -> Result<Value> {
        let proofs = self.funding_proofs_json().ok_or_else(pending)?;
        if self.refund_time.saturating_sub(now()) < MIN_OPEN_SECONDS {
            return Err(invalid("funded hoe channel has expired"));
        }
        Ok(json!({
            "channel_id": self.channel_id,
            "params_json": self.params_json,
            "funding_proofs_json": proofs,
            "capacity_msats": self.capacity_msats.to_string(),
            "refund_time": self.refund_time.to_string(),
        }))
    }
}

#[derive(Deserialize)]
struct PreparedSwap {
    swap_request_json: String,
    funding_secrets_json: String,
    change_secrets_json: String,
}

#[derive(Deserialize)]
struct OutputSecret {
    amount: u64,
    secret: String,
    blinding_factor: String,
}

#[derive(Deserialize)]
struct SwapEvidence {
    input_states: Vec<State>,
    swap_response: Option<SwapResponse>,
}

impl SwapEvidence {
    fn all_unspent(&self, expected: usize) -> bool {
        expected != 0
            && self.input_states.len() == expected
            && self
                .input_states
                .iter()
                .all(|state| *state == State::Unspent)
    }
}

fn now() -> u64 {
    (js_sys::Date::now() / 1000.0) as u64
}

fn invalid(message: &str) -> BridgeError {
    FfiErr::new(CdkStatus::InvalidArgument, message)
}

fn database(_: impl std::fmt::Display) -> BridgeError {
    FfiErr::new(
        CdkStatus::DatabaseError,
        "could not read or commit hoe funding state",
    )
}

fn pending() -> BridgeError {
    FfiErr::new(
        CdkStatus::RecoveryPending,
        "hoe funding is pending; resume the saved swap",
    )
}

fn pending_for(id: Uuid) -> BridgeError {
    FfiErr::with_op(
        CdkStatus::RecoveryPending,
        "hoe funding is pending; resume the saved swap",
        *id.as_bytes(),
        0,
    )
}

fn failed() -> BridgeError {
    FfiErr::new(
        CdkStatus::InternalError,
        "invalid hoe funding layout or channel material",
    )
}

fn corrupt() -> DbError {
    DbError::Internal("invalid or changed hoe funding state".into())
}

fn encode(value: &impl Serialize) -> Result<Vec<u8>> {
    serde_json::to_vec(value).map_err(database)
}

fn decode<T: DeserializeOwned>(bytes: &[u8]) -> Result<T> {
    serde_json::from_slice(bytes).map_err(database)
}

fn parse_key(text: &str) -> Result<PublicKey> {
    if text.len() != 66 {
        return Err(invalid("expected a compressed public key"));
    }
    text.parse()
        .map_err(|_| invalid("invalid compressed public key"))
}

fn check_terms(tool: Tool, terms: &Terms, time: u64) -> Result<()> {
    if terms.amount_msats != tool.price()
        || terms.refund_time.saturating_sub(time) <= MIN_OPEN_SECONDS + FUNDING_MARGIN_SECONDS
    {
        return Err(invalid("invalid or expired hoe requirements"));
    }
    Ok(())
}

fn read_terms(tool: Tool, args: &Args, offset: usize) -> Result<Terms> {
    if args.0.len() != offset + 5 {
        return Err(invalid(
            "expected scope, receiver key, amount, refund time and player key",
        ));
    }
    let text = |i| {
        args.text(offset + i)
            .map_err(|_| invalid("missing hoe funding argument"))
    };
    let number = |i| {
        args.number(offset + i)
            .map_err(|_| invalid("invalid hoe amount or refund time"))
    };
    let scope = text(0)?;
    if scope.is_empty() || scope.len() > 512 || scope.chars().any(char::is_control) {
        return Err(invalid("invalid hoe server scope"));
    }
    let terms = Terms {
        scope: scope.to_owned(),
        receiver_pubkey: parse_key(text(1)?)?.to_hex(),
        amount_msats: number(2)?,
        refund_time: number(3)?,
        player_pubkey: parse_key(text(4)?)?.to_hex(),
    };
    check_terms(tool, &terms, now())?;
    Ok(terms)
}

fn identity(wallet: &CdkWallet, terms: &Terms) -> Result<(String, zeroize::Zeroizing<String>)> {
    let (sender, secret) = wallet
        .browser_game_signer()
        .and_then(|signer| signer.channel_keys(&terms.receiver_pubkey))
        .ok_or_else(|| invalid("could not derive the game channel identity"))?;
    let same_x = |a: &str, b: &str| a.get(2..) == b.get(2..);
    if !same_x(&sender, &terms.player_pubkey) || same_x(&sender, &terms.receiver_pubkey) {
        return Err(invalid(
            "hoe requirements do not match the wallet game identity",
        ));
    }
    Ok((sender, secret))
}

async fn active_keyset(
    wallet: &CdkWallet,
    mint: &MintUrl,
    terms: &Terms,
) -> Result<(String, KeysetInfo)> {
    let raw = wallet
        .browser_funding_keyset(mint)
        .await
        .map_err(|e| FfiErr::new(e.status, "hoe mint or active keyset is unavailable"))?;
    let keyset = parse_keyset_info_from_json(&raw).map_err(|_| failed())?;
    let expected_ppk = if cfg!(feature = "local-mint-fixture") {
        0
    } else {
        100
    };
    let mut ladder = 0u64;
    for &amount in &keyset.amounts_largest_first {
        if !amount.is_power_of_two() || ladder & amount != 0 {
            return Err(invalid("unsupported hoe keyset denominations"));
        }
        ladder |= amount;
    }
    if keyset.unit != CurrencyUnit::Msat
        || keyset.input_fee_ppk != expected_ppk
        || keyset
            .final_expiry
            .is_some_and(|expiry| expiry <= terms.refund_time)
        || ladder == 0
        || ladder & ladder.wrapping_add(1) != 0
        || keyset.active_keys.iter().count() != keyset.amounts_largest_first.len()
        || keyset
            .amounts_largest_first
            .iter()
            .any(|&a| keyset.active_keys.amount_key(a.into()).is_none())
    {
        return Err(invalid(
            "unsupported hoe mint fee, unit, expiry or denominations",
        ));
    }
    // Verify the advertised keyset against its keys before any inputs are reserved.
    use cdk::nuts::nut02::KeySetVersion;
    let derived = match keyset.keyset_id.get_version() {
        KeySetVersion::Version00 => cdk::nuts::Id::v1_from_keys(&keyset.active_keys),
        KeySetVersion::Version01 => cdk::nuts::Id::v2_from_data(
            &keyset.active_keys,
            &keyset.unit,
            keyset.input_fee_ppk,
            keyset.final_expiry,
        ),
    };
    if derived != keyset.keyset_id {
        return Err(invalid("hoe keyset ID does not match its keys"));
    }
    Ok((raw, keyset))
}

fn parse_mint() -> Result<MintUrl> {
    let mint = onboarding_mint().map_err(|_| invalid("hoe mint is unavailable"))?;
    wallet::parse_mint_url(&mint)
}

fn input_fee(ppk: u64, count: usize) -> u64 {
    (ppk * count as u64).div_ceil(1000)
}

struct FundingInputs(Vec<ProofInfo>);

struct Selection<'a> {
    proofs: &'a [ProofInfo],
    debit: u64,
    change: u64,
}

impl FundingInputs {
    async fn load(wallet: &CdkWallet, mint: MintUrl, keyset: &KeysetInfo) -> Result<Self> {
        let proofs = wallet
            .browser_database()
            .get_proofs(
                Some(mint),
                Some(CurrencyUnit::Msat),
                Some(vec![State::Unspent]),
                None,
            )
            .await
            .map_err(database)?;
        Ok(Self::from_proofs(proofs, keyset))
    }

    fn from_proofs(mut proofs: Vec<ProofInfo>, keyset: &KeysetInfo) -> Self {
        proofs.retain(|p| {
            p.state == State::Unspent
                && p.unit == CurrencyUnit::Msat
                && p.spending_condition.is_none()
                && p.used_by_operation.is_none()
                && eligible_input(&p.proof, keyset)
                && p.proof.y().is_ok_and(|y| y == p.y)
        });
        proofs.sort_unstable_by(|a, b| b.proof.amount.cmp(&a.proof.amount).then(a.y.cmp(&b.y)));
        Self(proofs)
    }

    fn find(&self, nominal: u64, ppk: u64, cap: u64) -> Option<Selection<'_>> {
        // Any n inputs pay the same fee, so their largest-first prefix is a
        // witness whenever any n eligible inputs can afford this nominal.
        let mut total = 0u64;
        for (i, proof) in self.0.iter().take(cap as usize).enumerate() {
            let count = i + 1;
            let debit = nominal.checked_add(input_fee(ppk, count))?;
            if debit > cap {
                break;
            }
            total = total.checked_add(u64::from(proof.proof.amount))?;
            if let Some(change) = total.checked_sub(debit) {
                return Some(Selection {
                    proofs: &self.0[..count],
                    debit,
                    change,
                });
            }
        }
        None
    }
}

fn nominal_for(capacity: u64, keyset_json: &str, keyset: &KeysetInfo) -> Option<u64> {
    let nominal = compute_funding_token_amount(capacity, keyset_json, MAX_OUTPUT).ok()?;
    if nominal > MAX_OUTPUT {
        return None;
    }
    let stage1 = keyset
        .deterministic_value_after_fees(nominal, MAX_OUTPUT)
        .ok()?;
    let usable = keyset
        .deterministic_value_after_fees(stage1, MAX_OUTPUT)
        .ok()?;
    (usable == capacity).then_some(nominal)
}

fn eligible_input(proof: &Proof, keyset: &KeysetInfo) -> bool {
    proof.keyset_id == keyset.keyset_id
        && !proof.secret.is_empty()
        && SpendingConditions::try_from(&proof.secret).is_err()
        && proof.witness.is_none()
        && proof.p2pk_e.is_none()
        && u64::from(proof.amount).is_power_of_two()
        && keyset.active_keys.amount_key(proof.amount).is_some()
}

fn same_swap_input(left: &Proof, right: &Proof) -> bool {
    // NUT-03 strips DLEQ metadata from its input proofs.
    let mut left = left.clone();
    let mut right = right.clone();
    left.dleq = None;
    right.dleq = None;
    left == right
}

struct Layout {
    funding: Vec<OutputSecret>,
    debit: u64,
    change: u64,
}

fn checked_request(raw: &str) -> Result<SwapRequest> {
    let swap: SwapRequest = serde_json::from_str(raw).map_err(|_| failed())?;
    // The raw post uses this same serializer on a fresh (non-retrying) client.
    if serde_json::to_string(&swap).map_err(|_| failed())? != raw {
        return Err(failed());
    }
    Ok(swap)
}

fn check_layout(
    swap: &SwapRequest,
    keyset: &KeysetInfo,
    nominal: u64,
    funding: &str,
    change: &str,
) -> Result<Layout> {
    let funding: Vec<OutputSecret> = serde_json::from_str(funding).map_err(|_| failed())?;
    let change: Vec<OutputSecret> = serde_json::from_str(change).map_err(|_| failed())?;
    if funding.is_empty()
        || funding.len() + change.len() != swap.outputs().len()
        || !(1..=64).contains(&swap.inputs().len())
    // Includes journals made by v1.
    {
        return Err(failed());
    }
    let mut ys = BTreeSet::new();
    for input in swap.inputs() {
        if !eligible_input(input, keyset) || !ys.insert(input.y().map_err(|_| failed())?) {
            return Err(failed());
        }
    }
    let mut blinded = BTreeSet::new();
    let mut denominations = 0;
    for (i, (output, s)) in swap
        .outputs()
        .iter()
        .zip(funding.iter().chain(&change))
        .enumerate()
    {
        let r = SecretKey::from_hex(&s.blinding_factor).map_err(|_| failed())?;
        let (b, _) =
            cdk::dhke::blind_message(s.secret.as_bytes(), Some(r)).map_err(|_| failed())?;
        let y = cdk::dhke::hash_to_curve(s.secret.as_bytes()).map_err(|_| failed())?;
        if output.keyset_id != keyset.keyset_id
            || s.amount != u64::from(output.amount)
            || keyset.active_keys.amount_key(output.amount).is_none()
            || output.witness.is_some()
            || b != output.blinded_secret
            || !blinded.insert(b)
            || !ys.insert(y)
        {
            return Err(failed());
        }
        if i < funding.len() {
            if !s.amount.is_power_of_two() || denominations & s.amount != 0 {
                return Err(failed());
            }
            denominations |= s.amount;
        } else if s.secret.len() != 64 || !s.secret.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(failed());
        }
    }
    let input = u64::from(swap.input_amount().map_err(|_| failed())?);
    let output = u64::from(swap.output_amount().map_err(|_| failed())?);
    if keyset.unit != CurrencyUnit::Msat || keyset.input_fee_ppk > 100 {
        return Err(failed());
    }
    let fee = input_fee(keyset.input_fee_ppk, swap.inputs().len());
    if denominations != nominal || input.checked_sub(output) != Some(fee) {
        return Err(failed());
    }
    let change = output.checked_sub(nominal).ok_or_else(failed)?;
    let debit = input.checked_sub(change).ok_or_else(failed)?;
    Ok(Layout {
        funding,
        debit,
        change,
    })
}

fn prepare(
    tool: Tool,
    offer: &Offer,
    keyset_json: String,
    keyset: KeysetInfo,
    secret: &str,
    selection: &Selection<'_>,
    setup: u64,
) -> Result<Option<FundingRecord>> {
    let secret_bytes = cdk::util::hex::decode(secret).map_err(|_| failed())?;
    let params = ChannelParameters::new(
        parse_key(&offer.sender_pubkey)?,
        parse_key(&offer.terms.receiver_pubkey)?,
        offer.mint_url.clone(),
        CurrencyUnit::Msat,
        offer.capacity_msats,
        offer.nominal_msats,
        offer.terms.refund_time,
        setup,
        keyset.clone(),
        MAX_OUTPUT,
        secret_bytes.try_into().map_err(|_| failed())?,
    )
    .map_err(|_| failed())?;
    let params_json = params.get_channel_id_params_json();
    if params_json.len() > MAX_PARAMS_BYTES {
        return Ok(None);
    }
    let proofs: Vec<_> = selection.proofs.iter().map(|p| &p.proof).collect();
    let proofs_json = serde_json::to_string(&proofs).map_err(|_| failed())?;
    let raw = create_funding_swap_with_plain_change(
        &params_json,
        secret,
        &keyset_json,
        &proofs_json,
        selection.change,
    )
    .map_err(|_| failed())?;
    let prepared: PreparedSwap = serde_json::from_str(&raw).map_err(|_| failed())?;
    let swap = checked_request(&prepared.swap_request_json)?;
    let layout = check_layout(
        &swap,
        &keyset,
        offer.nominal_msats,
        &prepared.funding_secrets_json,
        &prepared.change_secrets_json,
    )?;
    if swap.inputs().len() != proofs.len()
        || swap
            .inputs()
            .iter()
            .zip(proofs)
            .any(|(input, proof)| !same_swap_input(input, proof))
        || layout.debit != offer.debit_msats
        || layout.debit > tool.max_debit()
        || layout.change != selection.change
    {
        return Err(failed());
    }
    let mut proof_bytes = 1;
    let hex64 = "0".repeat(64);
    let pubkey = format!("02{hex64}");
    for s in layout.funding {
        proof_bytes += 1 + json!({"amount": s.amount, "id": keyset.keyset_id, "secret": s.secret,
            "C": pubkey, "dleq": {"e": hex64, "s": hex64, "r": hex64}})
        .to_string()
        .len();
    }
    if proof_bytes > MAX_PROOF_BYTES {
        return Ok(None);
    }
    Ok(Some(FundingRecord {
        version: VERSION,
        tool,
        operation_id: offer.id,
        scope: offer.terms.scope.clone(),
        mint_url: offer.mint_url.clone(),
        sender_pubkey: offer.sender_pubkey.clone(),
        receiver_pubkey: offer.terms.receiver_pubkey.clone(),
        capacity_msats: offer.capacity_msats,
        refund_time: offer.terms.refund_time,
        channel_id: params.get_channel_id(),
        params_json,
        keyset_json,
        channel_secret_hex: secret.to_owned(),
        state: FundingState::Submitted {
            swap_request_json: prepared.swap_request_json,
            funding_secrets_json: prepared.funding_secrets_json,
            change_secrets_json: prepared.change_secrets_json,
        },
    }))
}

pub(super) async fn quote(wallet: &CdkWallet, tool: Tool, args: &Args) -> Result<Value> {
    let terms = read_terms(tool, args, 0)?;
    if load(wallet, tool).await?.is_some() {
        return Err(pending());
    }
    let (sender_pubkey, secret) = identity(wallet, &terms)?;
    let mint = parse_mint()?;
    let (raw_keyset, keyset) = active_keyset(wallet, &mint, &terms).await?;
    let inputs = FundingInputs::load(wallet, mint.clone(), &keyset).await?;
    let setup = now();
    check_terms(tool, &terms, setup)?;
    let mut offer = Offer {
        version: VERSION,
        id: Uuid::new_v4(),
        mint_url: mint.to_string(),
        sender_pubkey,
        expires_at: (setup + CONSENT_SECONDS)
            .min(terms.refund_time - MIN_OPEN_SECONDS - FUNDING_MARGIN_SECONDS),
        terms,
        capacity_msats: 0,
        nominal_msats: 0,
        debit_msats: 0,
        keyset: serde_json::from_str(&raw_keyset).map_err(|_| failed())?,
    };
    for cuts in (1..=Tool::MAX_CUTS).rev() {
        let capacity = cuts * tool.price();
        let Some(nominal) = nominal_for(capacity, &raw_keyset, &keyset) else {
            continue;
        };
        let Some(selection) = inputs.find(nominal, keyset.input_fee_ppk, tool.max_debit()) else {
            continue;
        };
        let debit = selection.debit;
        offer.capacity_msats = capacity;
        offer.nominal_msats = nominal;
        offer.debit_msats = debit;
        // Preflight the serialization and channel proof size, not just the balance.
        if prepare(
            tool,
            &offer,
            raw_keyset.clone(),
            keyset.clone(),
            &secret,
            &selection,
            setup,
        )?
        .is_none()
        {
            continue;
        }
        let bytes = encode(&offer)?;
        wallet
            .browser_database()
            .write(|store| {
                if store.kv.contains_key(&kv_key(NS, tool.slot(), RECORD)) {
                    return Err(corrupt());
                }
                store.kv.insert(kv_key(NS, tool.slot(), OFFER), bytes);
                Ok(())
            })
            .await
            .map_err(database)?;
        return Ok(json!({
            "quote_id": offer.id, "scope": offer.terms.scope, "mint_url": offer.mint_url,
            "receiver_pubkey": offer.terms.receiver_pubkey, "sender_pubkey": offer.sender_pubkey,
            "price_msats": tool.price().to_string(), "cuts": cuts.to_string(),
            "capacity_msats": capacity.to_string(), "nominal_msats": nominal.to_string(),
            "swap_fee_msats": (debit - nominal).to_string(), "max_sender_fee_msats": "0",
            "max_debit_msats": debit.to_string(), "total_fee_msats": (debit - capacity).to_string(),
            "refund_time": offer.terms.refund_time.to_string(), "expires_at": offer.expires_at.to_string(),
        }));
    }
    Err(FfiErr::new(
        CdkStatus::InsufficientFunds,
        "no affordable whole hoe cut using eligible active-keyset proofs",
    ))
}

pub(super) async fn fund(wallet: &CdkWallet, tool: Tool, args: &Args) -> Result<Value> {
    let terms = read_terms(tool, args, 1)?;
    let id = args
        .text(0)
        .ok()
        .and_then(|s| Uuid::parse_str(s).ok())
        .ok_or_else(|| invalid("invalid hoe quote ID"))?;
    if load(wallet, tool).await?.is_some() {
        return Err(pending());
    }
    let db = wallet.browser_database();
    let offer_bytes = db
        .kv_read(NS, tool.slot(), OFFER)
        .await
        .map_err(database)?
        .ok_or_else(|| invalid("no live hoe quote"))?;
    let offer: Offer = decode(&offer_bytes)?;
    if offer.version != VERSION
        || offer.id != id
        || offer.terms != terms
        || now() >= offer.expires_at
        || !tool.valid_capacity(offer.capacity_msats)
        || offer.debit_msats > tool.max_debit()
    {
        return Err(invalid("hoe quote changed or expired"));
    }
    let mint = parse_mint()?;
    let (sender, secret) = identity(wallet, &terms)?;
    if sender != offer.sender_pubkey || mint.to_string() != offer.mint_url {
        return Err(invalid("hoe quote identity or mint changed"));
    }
    let (raw_keyset, keyset) = active_keyset(wallet, &mint, &terms).await?;
    let fresh: Value = serde_json::from_str(&raw_keyset).map_err(|_| failed())?;
    if fresh != offer.keyset
        || nominal_for(offer.capacity_msats, &raw_keyset, &keyset) != Some(offer.nominal_msats)
    {
        return Err(invalid("hoe quote keyset changed"));
    }
    let inputs = FundingInputs::load(wallet, mint, &keyset).await?;
    let selection = inputs
        .find(offer.nominal_msats, keyset.input_fee_ppk, offer.debit_msats)
        .filter(|s| s.debit == offer.debit_msats)
        .ok_or_else(|| invalid("hoe funding debit changed; request a new quote"))?;
    let setup = now();
    check_terms(tool, &terms, setup)?;
    if setup >= offer.expires_at {
        return Err(invalid("hoe quote expired"));
    }
    let record = prepare(tool, &offer, raw_keyset, keyset, &secret, &selection, setup)?
        .ok_or_else(|| invalid("hoe funding exceeds the channel payload limit"))?;
    let record_bytes = encode(&record)?;
    db.write_hoe_funding(|store| {
        if store.kv.contains_key(&kv_key(NS, tool.slot(), RECORD))
            || store.kv.get(&kv_key(NS, tool.slot(), OFFER)) != Some(&offer_bytes)
            || now() >= offer.expires_at
        {
            return Err(corrupt());
        }
        // The setup timestamp contributes to the deterministic output IDs.
        // Keep this watermark shared across tools: channels of different tools
        // can have identical capacities and otherwise identical parameters.
        if let Some(last) = store.kv.get(&kv_key(NS, "", LAST_SETUP)) {
            let last: u64 = serde_json::from_slice(last).map_err(|_| corrupt())?;
            if setup <= last {
                return Err(corrupt());
            }
        }
        for selected in selection.proofs {
            let proof = store
                .proofs
                .get_mut(&selected.y.to_string())
                .ok_or_else(corrupt)?;
            if proof != selected {
                return Err(corrupt());
            }
            proof.state = State::Reserved;
            proof.used_by_operation = Some(id);
        }
        store.kv.remove(&kv_key(NS, tool.slot(), OFFER));
        store
            .kv
            .insert(kv_key(NS, "", LAST_SETUP), setup.to_string().into_bytes());
        store
            .kv
            .insert(kv_key(NS, tool.slot(), RECORD), record_bytes.clone());
        Ok(())
    })
    .await
    .map_err(database)?;

    // A suspended browser may only discover expiry after the durable CAS. Do
    // not roll back here: another authorized context could already be posting.
    if now() >= offer.expires_at {
        return Err(pending_for(record.operation_id));
    }
    dispatch(wallet, record, &record_bytes)
        .await?
        .open_payload()
}

async fn read_record(wallet: &CdkWallet, tool: Tool) -> Result<Option<(FundingRecord, Vec<u8>)>> {
    let Some(bytes) = wallet
        .browser_database()
        .kv_read(NS, tool.slot(), RECORD)
        .await
        .map_err(database)?
    else {
        return Ok(None);
    };
    Ok(Some((decode_record(tool, &bytes)?, bytes)))
}

fn decode_record(tool: Tool, bytes: &[u8]) -> Result<FundingRecord> {
    let record: FundingRecord = decode(bytes)?;
    if record.version != VERSION {
        return Err(FfiErr::new(
            CdkStatus::UnsupportedFormatVersion,
            "unknown hoe funding record version",
        ));
    }
    if record.tool != tool || !tool.valid_capacity(record.capacity_msats) {
        return Err(failed());
    }
    Ok(record)
}

pub(super) async fn load(wallet: &CdkWallet, tool: Tool) -> Result<Option<FundingRecord>> {
    Ok(read_record(wallet, tool).await?.map(|(record, _)| record))
}

pub(super) async fn recover(
    wallet: &CdkWallet,
    tool: Tool,
    scope: &str,
) -> Result<Option<FundingRecord>> {
    let Some((record, bytes)) = read_record(wallet, tool).await? else {
        return Ok(None);
    };
    if record.scope != scope {
        return Err(invalid("hoe funding belongs to another server"));
    }
    if record.funding_proofs_json().is_some() {
        return Ok(Some(record));
    }
    // NUT-07 + NUT-09 only. Neither unspent nor partial evidence releases inputs.
    let evidence = evidence(wallet, &record).await?;
    let response = evidence
        .swap_response
        .ok_or_else(|| pending_for(record.operation_id))?;
    complete(wallet, record, &bytes, &response).await.map(Some)
}

struct Submitted<'a> {
    raw: &'a str,
    swap: SwapRequest,
    funding: &'a str,
    change: &'a str,
    keyset: KeysetInfo,
    params: ChannelParameters,
    layout: Layout,
}

fn submitted(record: &FundingRecord) -> Result<Submitted<'_>> {
    let FundingState::Submitted {
        funding_secrets_json,
        swap_request_json,
        change_secrets_json,
    } = &record.state
    else {
        return Err(failed());
    };
    let keyset = parse_keyset_info_from_json(&record.keyset_json).map_err(|_| failed())?;
    let secret = cdk::util::hex::decode(&record.channel_secret_hex).map_err(|_| failed())?;
    let params = ChannelParameters::from_json_with_channel_secret(
        &record.params_json,
        keyset.clone(),
        secret.try_into().map_err(|_| failed())?,
    )
    .map_err(|_| failed())?;
    if params.get_channel_id() != record.channel_id
        || params.get_capacity() != record.capacity_msats
        || params.expiry_timestamp != record.refund_time
        || params.sender_pubkey.to_hex() != record.sender_pubkey
        || params.receiver_pubkey.to_hex() != record.receiver_pubkey
        || params.mint.trim_end_matches('/') != record.mint_url.trim_end_matches('/')
        || params.unit != CurrencyUnit::Msat
        || record.params_json.len() > MAX_PARAMS_BYTES
    {
        return Err(failed());
    }
    let swap = checked_request(swap_request_json)?;
    let change = change_secrets_json.as_str();
    let nominal = params
        .get_total_funding_token_amount()
        .map_err(|_| failed())?;
    let layout = check_layout(&swap, &keyset, nominal, funding_secrets_json, change)?;
    if layout.debit > record.tool.max_debit() {
        return Err(failed());
    }
    Ok(Submitted {
        raw: swap_request_json,
        swap,
        funding: funding_secrets_json,
        change,
        keyset,
        params,
        layout,
    })
}

async fn evidence(wallet: &CdkWallet, record: &FundingRecord) -> Result<SwapEvidence> {
    let raw = submitted(record)?.raw;
    let raw_evidence = wallet
        .recover_swap(&record.mint_url, raw)
        .await
        .map_err(|_| pending_for(record.operation_id))?;
    serde_json::from_str(&raw_evidence).map_err(|_| pending_for(record.operation_id))
}

fn check_resume(record: &FundingRecord, debit: u64) -> Result<()> {
    if record.refund_time.saturating_sub(now()) <= MIN_OPEN_SECONDS + FUNDING_MARGIN_SECONDS
        || debit > record.tool.max_debit()
        || parse_mint()?.to_string() != record.mint_url
    {
        return Err(invalid(
            "saved hoe swap is no longer eligible for reauthorization",
        ));
    }
    Ok(())
}

/// Read-only display data for a separate, explicit resume confirmation.
pub(super) async fn resume_quote(wallet: &CdkWallet, tool: Tool, args: &Args) -> Result<Value> {
    if args.0.len() != 1 {
        return Err(invalid("expected hoe server scope"));
    }
    let scope = args
        .text(0)
        .map_err(|_| invalid("missing hoe server scope"))?;
    let record = load(wallet, tool)
        .await?
        .ok_or_else(|| invalid("no saved hoe funding"))?;
    if record.scope != scope || record.funding_proofs_json().is_some() {
        return Err(invalid("no pending hoe funding for this server"));
    }
    let debit = submitted(&record)?.layout.debit;
    check_resume(&record, debit)?;
    Ok(json!({
        "operation_id": record.operation_id, "scope": record.scope, "mint_url": record.mint_url,
        "channel_id": record.channel_id, "receiver_pubkey": record.receiver_pubkey,
        "capacity_msats": record.capacity_msats.to_string(), "cuts": (record.capacity_msats / tool.price()).to_string(),
        "max_debit_msats": debit.to_string(), "refund_time": record.refund_time.to_string(),
    }))
}

/// Only call after a new user confirmation for this exact operation and debit.
pub(super) async fn resume(wallet: &CdkWallet, tool: Tool, args: &Args) -> Result<Value> {
    if args.0.len() != 3 {
        return Err(invalid(
            "expected hoe scope, operation ID and confirmed debit",
        ));
    }
    let scope = args
        .text(0)
        .map_err(|_| invalid("missing hoe server scope"))?;
    let id = args
        .text(1)
        .ok()
        .and_then(|s| Uuid::parse_str(s).ok())
        .ok_or_else(|| invalid("invalid hoe operation ID"))?;
    let consent = args
        .number(2)
        .map_err(|_| invalid("invalid confirmed hoe debit"))?;
    let (record, bytes) = read_record(wallet, tool)
        .await?
        .ok_or_else(|| invalid("no saved hoe funding"))?;
    if record.scope != scope || record.operation_id != id {
        return Err(invalid("saved hoe funding changed"));
    }
    if record.funding_proofs_json().is_some() {
        return record.open_payload();
    }
    let saved = submitted(&record)?;
    let debit = saved.layout.debit;
    let count = saved.swap.inputs().len();
    if consent != debit {
        return Err(invalid("confirmed hoe debit does not match saved funding"));
    }
    let evidence = evidence(wallet, &record).await?;
    if let Some(response) = evidence.swap_response {
        return complete(wallet, record, &bytes, &response)
            .await?
            .open_payload();
    }
    if !evidence.all_unspent(count) {
        return Err(pending_for(id));
    }
    let current = read_record(wallet, tool).await?;
    if current.as_ref().is_none_or(|(_, prior)| *prior != bytes) {
        return Err(pending_for(id));
    }
    check_resume(&record, debit)?;
    // This evidence is not proof of non-dispatch. A delayed original may win.
    // Mint atomic single-spend means at most one request of these same bytes
    // can sign; either winner signs the same saved B_ values (including change).
    dispatch(wallet, record, &bytes).await?.open_payload()
}

async fn dispatch(
    wallet: &CdkWallet,
    record: FundingRecord,
    prior: &[u8],
) -> Result<FundingRecord> {
    let saved = submitted(&record)?;
    let response = wallet
        .post_swap(&record.mint_url, saved.raw)
        .await
        .map_err(|_| pending_for(record.operation_id))?;
    let response = serde_json::from_str(&response).map_err(|_| pending_for(record.operation_id))?;
    complete(wallet, record, prior, &response).await
}

#[derive(Deserialize)]
struct CompletedSwap {
    funding_proofs_json: String,
    change_proofs_json: String,
}

fn verify_completed(
    record: &FundingRecord,
    saved: &Submitted<'_>,
    response: &SwapResponse,
) -> Result<(String, Vec<ProofInfo>)> {
    let pending = || pending_for(record.operation_id);
    let raw = serde_json::to_string(response).map_err(|_| pending())?;
    // The upstream helper checks every signature's denomination, keyset and
    // DLEQ against its reconstructed B_; submitted() bound every B_ to the journal.
    let completed = complete_funding_swap_with_plain_change(
        &raw,
        saved.funding,
        saved.change,
        &record.keyset_json,
    )
    .map_err(|_| pending())?;
    let completed: CompletedSwap = serde_json::from_str(&completed).map_err(|_| pending())?;
    let proofs = completed.funding_proofs_json;
    if proofs.len() > MAX_PROOF_BYTES {
        return Err(pending());
    }
    let parsed = serde_json::from_str::<Vec<Proof>>(&proofs).map_err(|_| pending())?;
    if !verify_valid_channel(&parsed, &saved.params).valid {
        return Err(pending());
    }
    let mint: MintUrl = record.mint_url.parse().map_err(|_| pending())?;
    let change =
        serde_json::from_str::<Vec<Proof>>(&completed.change_proofs_json).map_err(|_| pending())?;
    let mut total = 0u64;
    let mut verified = Vec::with_capacity(change.len());
    for proof in change {
        let key = saved
            .keyset
            .active_keys
            .amount_key(proof.amount)
            .ok_or_else(pending)?;
        if !eligible_input(&proof, &saved.keyset) || proof.verify_dleq(key).is_err() {
            return Err(pending());
        }
        total = total
            .checked_add(u64::from(proof.amount))
            .ok_or_else(pending)?;
        let mut proof = ProofInfo::new(proof, mint.clone(), State::Unspent, CurrencyUnit::Msat)
            .map_err(|_| pending())?;
        proof.created_by_operation = Some(record.operation_id);
        verified.push(proof);
    }
    if total != saved.layout.change {
        return Err(pending());
    }
    Ok((proofs, verified))
}

async fn complete(
    wallet: &CdkWallet,
    mut record: FundingRecord,
    prior: &[u8],
    response: &SwapResponse,
) -> Result<FundingRecord> {
    let saved = submitted(&record)?;
    let (proofs, change) = verify_completed(&record, &saved, response)?;
    let swap = saved.swap;
    record.state = FundingState::Funded {
        funding_proofs_json: proofs,
    };
    let funded = encode(&record)?;
    wallet
        .browser_database()
        .write_hoe_funding(|store| {
            persist_funded(
                store,
                record.tool,
                prior,
                funded,
                record.operation_id,
                &swap,
                change,
            )
        })
        .await
        .map_err(database)?;
    Ok(record)
}

fn persist_funded(
    store: &mut super::browser_db::Store,
    tool: Tool,
    prior: &[u8],
    funded: Vec<u8>,
    id: Uuid,
    swap: &SwapRequest,
    change: Vec<ProofInfo>,
) -> std::result::Result<(), DbError> {
    let key = kv_key(NS, tool.slot(), RECORD);
    if store.kv.get(&key).map(Vec::as_slice) != Some(prior) {
        return Err(corrupt());
    }
    for input in swap.inputs() {
        let y = input.y().map_err(|_| corrupt())?.to_string();
        let proof = store.proofs.get_mut(&y).ok_or_else(corrupt)?;
        if proof.state != State::Reserved
            || proof.used_by_operation != Some(id)
            || !same_swap_input(&proof.proof, input)
        {
            return Err(corrupt());
        }
        proof.state = State::Spent;
        proof.used_by_operation = None;
    }
    for proof in change {
        if store.proofs.insert(proof.y.to_string(), proof).is_some() {
            return Err(corrupt());
        }
    }
    store.kv.insert(key, funded);
    Ok(())
}

/// Call only after the parent module has durably reconciled the channel close
/// or sender refund. This never releases raw funding inputs or a pending swap.
pub(super) async fn release(
    wallet: &CdkWallet,
    tool: Tool,
    scope: &str,
    channel_id: &str,
) -> Result<()> {
    let Some((record, prior)) = read_record(wallet, tool).await? else {
        return Ok(());
    };
    if record.scope != scope
        || record.channel_id != channel_id
        || record.funding_proofs_json().is_none()
    {
        return Err(invalid("cannot release this hoe funding record"));
    }
    wallet
        .browser_database()
        .write(|store| {
            if store.kv.get(&kv_key(NS, tool.slot(), RECORD)) != Some(&prior) {
                return Err(corrupt());
            }
            store.kv.remove(&kv_key(NS, tool.slot(), RECORD));
            Ok(())
        })
        .await
        .map_err(database)
}

/// The CDK database is also used by receives and sagas. They must never
/// replace, remove, or transition a proof owned by this raw swap.
pub(crate) fn reserved_inputs(
    store: &super::browser_db::Store,
) -> std::result::Result<Vec<(String, ProofInfo)>, DbError> {
    let mut protected = Vec::new();
    for tool in Tool::ALL {
        protected.extend(reserved_inputs_for(store, tool)?);
    }
    Ok(protected)
}

fn reserved_inputs_for(
    store: &super::browser_db::Store,
    tool: Tool,
) -> std::result::Result<Vec<(String, ProofInfo)>, DbError> {
    let Some(bytes) = store.kv.get(&kv_key(NS, tool.slot(), RECORD)) else {
        return Ok(vec![]);
    };
    let record = decode_record(tool, bytes).map_err(|_| corrupt())?;
    let FundingState::Submitted {
        swap_request_json, ..
    } = record.state
    else {
        return Ok(vec![]);
    };
    let swap: SwapRequest = serde_json::from_str(&swap_request_json).map_err(|_| corrupt())?;
    swap.inputs()
        .iter()
        .map(|input| {
            let y = input.y().map_err(|_| corrupt())?.to_string();
            let proof = store
                .proofs
                .get(&y)
                .filter(|p| {
                    p.state == State::Reserved
                        && p.used_by_operation == Some(record.operation_id)
                        && same_swap_input(&p.proof, input)
                })
                .ok_or_else(corrupt)?;
            Ok((y, proof.clone()))
        })
        .collect()
}

/// Seed restore must not re-import a reserved input as unspent while a raw swap
/// can still commit. CDK's saga recovery does not own these proofs.
pub(super) async fn guard_seed_restore(wallet: &CdkWallet, mint: &MintUrl) -> Result<()> {
    for tool in Tool::ALL {
        if load(wallet, tool)
            .await?
            .is_some_and(|r| r.mint_url == mint.to_string() && r.funding_proofs_json().is_none())
        {
            return Err(pending());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use cdk::nuts::{BlindSignature, Id, Keys, RestoreResponse};

    fn fixture(ppk: u64, amounts: &[u64]) -> (KeysetInfo, FundingInputs) {
        let public_key = mint_key().public_key();
        let keys = Keys::new((0..7).map(|n| ((1u64 << n).into(), public_key)).collect());
        let id = Id::v1_from_keys(&keys);
        let keyset = KeysetInfo::new(id, CurrencyUnit::Msat, keys, ppk, None);
        let mint: MintUrl = "https://example.com".parse().unwrap();
        let candidates = amounts
            .iter()
            .enumerate()
            .map(|(i, &amount)| {
                ProofInfo::new(
                    Proof::new(
                        amount.into(),
                        id,
                        cdk::secret::Secret::new(format!("{i:064x}")),
                        public_key,
                    ),
                    mint.clone(),
                    State::Unspent,
                    CurrencyUnit::Msat,
                )
                .unwrap()
            })
            .collect();
        let inputs = FundingInputs::from_proofs(candidates, &keyset);
        (keyset, inputs)
    }

    fn mint_key() -> SecretKey {
        SecretKey::from_slice(&[1; 32]).unwrap()
    }

    fn prepare_record(keyset: KeysetInfo, selection: &Selection<'_>) -> FundingRecord {
        prepare_tool_record(Tool::Hoe, Uuid::nil(), 50, keyset, selection)
    }

    fn prepare_tool_record(
        tool: Tool,
        id: Uuid,
        capacity: u64,
        keyset: KeysetInfo,
        selection: &Selection<'_>,
    ) -> FundingRecord {
        let sender = SecretKey::from_slice(&[2; 32]).unwrap();
        let receiver = SecretKey::from_slice(&[3; 32]).unwrap().public_key();
        let sender_pubkey = sender.public_key().to_hex();
        let secret = cdk_spilman::compute_channel_secret_from_hex(
            &sender.to_secret_hex(),
            &receiver.to_hex(),
        )
        .unwrap();
        let keyset_json = serde_json::to_string(&keyset).unwrap();
        let offer = Offer {
            version: VERSION,
            id,
            mint_url: "https://example.com".into(),
            terms: Terms {
                scope: "test".into(),
                player_pubkey: sender_pubkey.clone(),
                receiver_pubkey: receiver.to_hex(),
                amount_msats: tool.price(),
                refund_time: 2000,
            },
            sender_pubkey,
            expires_at: 1060,
            capacity_msats: capacity,
            nominal_msats: nominal_for(capacity, &keyset_json, &keyset).unwrap(),
            debit_msats: selection.debit,
            keyset: serde_json::from_str(&keyset_json).unwrap(),
        };
        prepare(tool, &offer, keyset_json, keyset, &secret, selection, 1000)
            .unwrap()
            .unwrap()
    }

    fn sign(swap: &SwapRequest) -> SwapResponse {
        let key = mint_key();
        SwapResponse::new(
            swap.outputs()
                .iter()
                .map(|p| {
                    let c = cdk::dhke::sign_message(&key, &p.blinded_secret).unwrap();
                    BlindSignature::new(p.amount, c, p.keyset_id, &p.blinded_secret, &key).unwrap()
                })
                .collect(),
        )
    }

    #[test]
    fn chooses_largest_affordable_cuts_including_input_fees() {
        let (keyset, fragmented) = fixture(100, &[1; 64]);
        let raw = serde_json::to_string(&keyset).unwrap();
        assert_eq!(nominal_for(50, &raw, &keyset), Some(52));
        assert!(fragmented.find(52, 100, 55).is_none());
        assert!(fragmented.find(52, 100, 57).is_none());
        assert_eq!(fragmented.find(52, 100, 58).unwrap().debit, 58);
        let largest = (1..=Tool::MAX_CUTS).rev().find_map(|cuts| {
            fragmented
                .find(
                    nominal_for(cuts * Tool::Hoe.price(), &raw, &keyset)?,
                    100,
                    55,
                )
                .map(|s| (cuts, s.debit))
        });
        assert_eq!(largest, Some((9, 53)));
        let (_, large) = fixture(100, &[64]);
        let selection = large.find(52, 100, 55).unwrap();
        assert_eq!((selection.debit, selection.change), (53, 11));
        let (_, large) = fixture(0, &[64]);
        let selection = large.find(50, 0, 50).unwrap();
        assert_eq!((selection.debit, selection.change), (50, 14));
        assert!(large.find(50, 0, 49).is_none());
    }

    #[test]
    fn journals_protect_each_tools_inputs_and_keep_the_legacy_hoe_slot() {
        let (keyset, inputs) = fixture(0, &[32, 64]);
        let mut store = super::super::browser_db::Store::default();
        let mut records = Vec::new();
        for (tool, capacity, id, input) in [(Tool::Axe, 20, 1, 1), (Tool::Hoe, 50, 2, 0)] {
            let unspent = FundingInputs(vec![inputs.0[input].clone()]);
            let selection = unspent.find(capacity, 0, tool.max_debit()).unwrap();
            let record = prepare_tool_record(
                tool,
                Uuid::from_u128(id),
                capacity,
                keyset.clone(),
                &selection,
            );
            let prior = encode(&record).unwrap();
            let key = kv_key(NS, tool.slot(), RECORD);
            if tool == Tool::Hoe {
                assert_eq!(key, kv_key(NS, "", RECORD));
                assert!(serde_json::from_slice::<Value>(&prior)
                    .unwrap()
                    .get("tool")
                    .is_none());
            }
            assert!(decode_record(tool, &prior).is_ok());
            // Capacity 20 is valid for both axe and pickaxe; the record must
            // still be rejected if it appears in the wrong slot.
            assert!(decode_record(Tool::Pickaxe, &prior).is_err());
            store.kv.insert(key, prior.clone());
            for selected in selection.proofs {
                let mut input = selected.clone();
                input.state = State::Reserved;
                input.used_by_operation = Some(record.operation_id);
                assert!(store.proofs.insert(input.y.to_string(), input).is_none());
            }
            records.push((record, prior));
        }
        assert_eq!(reserved_inputs(&store).unwrap().len(), 2);
        let (mut axe, prior) = records.remove(0);
        let saved = submitted(&axe).unwrap();
        let (funding, change) = verify_completed(&axe, &saved, &sign(&saved.swap)).unwrap();
        let swap = saved.swap;
        axe.state = FundingState::Funded {
            funding_proofs_json: funding,
        };
        persist_funded(
            &mut store,
            Tool::Axe,
            &prior,
            encode(&axe).unwrap(),
            axe.operation_id,
            &swap,
            change,
        )
        .unwrap();
        let protected = reserved_inputs(&store).unwrap();
        assert_eq!(protected.len(), 1);
        assert_eq!(
            protected[0].1.used_by_operation,
            Some(records[0].0.operation_id)
        );
        assert_eq!(store.kv[&kv_key(NS, "", RECORD)], records[0].1);
    }

    #[test]
    fn journal_restores_every_signature_and_credits_only_verified_change() {
        let (keyset, inputs) = fixture(0, &[64]);
        let selection = inputs.find(50, 0, 50).unwrap();
        let record = prepare_record(keyset, &selection);
        let prior = encode(&record).unwrap();
        let mut record = decode_record(Tool::Hoe, &prior).unwrap();
        let saved = submitted(&record).unwrap();
        assert_eq!(saved.layout.debit, 50);
        assert_eq!(saved.layout.change, 14);
        assert_eq!(saved.raw, serde_json::to_string(&saved.swap).unwrap());
        let response = sign(&saved.swap);
        let (funding, change) = verify_completed(&record, &saved, &response).unwrap();
        assert_eq!(
            change
                .iter()
                .map(|p| u64::from(p.proof.amount))
                .sum::<u64>(),
            14
        );
        assert!(change.iter().all(|p| p.state == State::Unspent
            && p.spending_condition.is_none()
            && p.used_by_operation.is_none()
            && p.created_by_operation == Some(record.operation_id)));

        let mut restored = RestoreResponse {
            outputs: saved.swap.outputs().iter().rev().cloned().collect(),
            signatures: response.signatures.iter().rev().cloned().collect(),
        };
        let matched = wallet::match_swap_restore(saved.swap.outputs(), restored.clone())
            .unwrap()
            .unwrap();
        assert_eq!(
            verify_completed(&record, &saved, &matched).unwrap(),
            (funding.clone(), change.clone())
        );
        restored.outputs.remove(0);
        restored.signatures.remove(0);
        assert!(wallet::match_swap_restore(saved.swap.outputs(), restored)
            .unwrap()
            .is_none());
        let mut invalid = response;
        invalid.signatures.last_mut().unwrap().dleq = None;
        assert!(verify_completed(&record, &saved, &invalid).is_err());

        let swapped = saved.swap;
        let mut store = super::super::browser_db::Store::default();
        store.kv.insert(kv_key(NS, "", RECORD), prior.clone());
        let mut input = selection.proofs[0].clone();
        let y = input.y.to_string();
        input.state = State::Reserved;
        input.used_by_operation = Some(record.operation_id);
        store.proofs.insert(y.clone(), input);
        assert_eq!(reserved_inputs(&store).unwrap().len(), 1);
        record.state = FundingState::Funded {
            funding_proofs_json: funding,
        };
        let funded = encode(&record).unwrap();
        persist_funded(
            &mut store,
            Tool::Hoe,
            &prior,
            funded.clone(),
            record.operation_id,
            &swapped,
            change.clone(),
        )
        .unwrap();
        assert_eq!(store.kv[&kv_key(NS, "", RECORD)], funded);
        assert_eq!(store.proofs[&y].state, State::Spent);
        assert!(reserved_inputs(&store).unwrap().is_empty());
        for p in &change {
            assert_eq!(&store.proofs[&p.y.to_string()], p);
        }
        assert!(persist_funded(
            &mut store,
            Tool::Hoe,
            &prior,
            funded,
            record.operation_id,
            &swapped,
            change
        )
        .is_err());
    }

    #[cfg(not(feature = "local-mint-fixture"))]
    #[test]
    fn testnut_returns_exact_change_net_of_the_raw_swap_fee() {
        let (keyset, inputs) = fixture(100, &[64]);
        let selection = inputs.find(52, 100, Tool::Hoe.max_debit()).unwrap();
        let record = prepare_record(keyset, &selection);
        let saved = submitted(&record).unwrap();
        assert_eq!(u64::from(saved.swap.output_amount().unwrap()), 63);
        let (_, change) = verify_completed(&record, &saved, &sign(&saved.swap)).unwrap();
        assert_eq!(
            change
                .iter()
                .map(|p| u64::from(p.proof.amount))
                .sum::<u64>(),
            11
        );
        assert_eq!(saved.layout.debit, 53);
    }

    #[test]
    fn journal_requires_the_current_schema_even_without_change() {
        let (keyset, inputs) = fixture(0, &[32, 16, 2]);
        let selection = inputs.find(50, 0, 50).unwrap();
        let record = prepare_record(keyset, &selection);
        let record = decode_record(Tool::Hoe, &encode(&record).unwrap()).unwrap();
        let saved = submitted(&record).unwrap();
        assert!(verify_completed(&record, &saved, &sign(&saved.swap))
            .unwrap()
            .1
            .is_empty());

        let value = serde_json::to_value(record).unwrap();
        for version in [1, VERSION + 1] {
            let mut wrong_version = value.clone();
            wrong_version["version"] = json!(version);
            assert!(decode_record(Tool::Hoe, &encode(&wrong_version).unwrap()).is_err());
        }
        let mut missing_change = value.clone();
        missing_change["state"]
            .as_object_mut()
            .unwrap()
            .remove("change_secrets_json");
        assert!(decode_record(Tool::Hoe, &encode(&missing_change).unwrap()).is_err());
        let mut unknown_field = value;
        unknown_field["state"]["unknown"] = json!(true);
        assert!(decode_record(Tool::Hoe, &encode(&unknown_field).unwrap()).is_err());
    }

    #[test]
    fn only_complete_unspent_evidence_qualifies_for_explicit_retransmission() {
        let mut evidence = SwapEvidence {
            input_states: vec![State::Unspent],
            swap_response: None,
        };
        assert!(evidence.all_unspent(1));
        assert!(!evidence.all_unspent(0));
        assert!(!evidence.all_unspent(2));
        evidence.input_states.push(State::Pending);
        assert!(!evidence.all_unspent(2));
        evidence.input_states[1] = State::Spent;
        assert!(!evidence.all_unspent(2));
    }
}
