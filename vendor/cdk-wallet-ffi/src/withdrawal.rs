//! Transient CDK prepared-melt arguments and local CDK record projections.
use super::*;
use cdk::lightning_invoice::Bolt11Invoice;
use cdk::nuts::MeltQuoteState;
use cdk::wallet::MeltConfirmOptions;
use cdk_common::wallet::{
    MeltQuote, MeltSagaState, TransactionDirection, TransactionStatus, WalletSaga,
};
use serde_json::{json, Value};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum WithdrawalStatus {
    Pending,
    Prepared,
    Completed,
    Failed,
    Unsubmitted,
    Unknown,
}

impl WithdrawalStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Prepared => "prepared",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Unsubmitted => "unsubmitted",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Default)]
struct WithdrawalGroup<'a> {
    sagas: Vec<&'a WalletSaga>,
    transactions: Vec<&'a cdk_common::wallet::Transaction>,
}

/// Borrowed lookup for one CDK read snapshot, never retained across a mutation.
/// Expected O(S + T) construction and O(1) group lookup; record filtering across
/// unique quote identities visits only their groups, not the entire history.
pub(super) struct WithdrawalLookup<'a> {
    groups: HashMap<(&'a MintUrl, &'a CurrencyUnit, &'a str), WithdrawalGroup<'a>>,
    #[cfg(test)]
    visits: std::cell::Cell<usize>,
}

pub(super) struct WithdrawalEvidence {
    status: WithdrawalStatus,
    matching_saga: bool,
    pending_or_completed_tx: bool,
}

impl WithdrawalEvidence {
    fn poll_candidate(&self, q: &MeltQuote) -> bool {
        self.status == WithdrawalStatus::Pending
            || (q.state == MeltQuoteState::Paid && self.status != WithdrawalStatus::Completed)
    }
}

impl<'a> WithdrawalLookup<'a> {
    pub(super) fn new(
        sagas: &'a [WalletSaga],
        transactions: &'a [cdk_common::wallet::Transaction],
    ) -> Self {
        let mut lookup = Self {
            groups: HashMap::new(),
            #[cfg(test)]
            visits: std::cell::Cell::new(0),
        };
        for s in sagas {
            #[cfg(test)]
            lookup.visits.set(lookup.visits.get() + 1);
            if let Some(id) = s.quote_id.as_deref() {
                lookup
                    .groups
                    .entry((&s.mint_url, &s.unit, id))
                    .or_default()
                    .sagas
                    .push(s);
            }
        }
        for t in transactions {
            #[cfg(test)]
            lookup.visits.set(lookup.visits.get() + 1);
            if let Some(id) = t.quote_id.as_deref() {
                lookup
                    .groups
                    .entry((&t.mint_url, &t.unit, id))
                    .or_default()
                    .transactions
                    .push(t);
            }
        }
        lookup
    }

    pub(super) fn classify(&self, q: &MeltQuote) -> WithdrawalEvidence {
        let group = q
            .mint_url
            .as_ref()
            .and_then(|mint| self.groups.get(&(mint, &q.unit, q.id.as_str())));
        let mut matching_saga = false;
        let mut pending_saga = false;
        let mut prepared_saga = false;
        let mut completed_tx = false;
        let mut pending_tx = false;
        let mut failed_tx = false;
        if let Some(group) = group {
            for s in &group.sagas {
                #[cfg(test)]
                self.visits.set(self.visits.get() + 1);
                if !matches!(&s.data, OperationData::Melt(d) if d.quote_id == q.id)
                    || !q
                        .used_by_operation
                        .as_ref()
                        .is_none_or(|id| id == &s.id.to_string())
                {
                    continue;
                }
                matching_saga = true;
                pending_saga |= matches!(
                    s.state,
                    WalletSagaState::Melt(
                        MeltSagaState::MeltRequested | MeltSagaState::PaymentPending
                    )
                );
                prepared_saga |= matches!(
                    s.state,
                    WalletSagaState::Melt(MeltSagaState::ProofsReserved)
                );
            }
            for t in &group.transactions {
                #[cfg(test)]
                self.visits.set(self.visits.get() + 1);
                if t.direction != TransactionDirection::Outgoing
                    || !t
                        .payment_method
                        .as_ref()
                        .is_none_or(|m| m == &q.payment_method)
                    || !q
                        .used_by_operation
                        .as_ref()
                        .is_none_or(|id| t.saga_id.as_ref().is_none_or(|s| id == &s.to_string()))
                {
                    continue;
                }
                completed_tx |= t.status == TransactionStatus::Completed;
                pending_tx |= t.status == TransactionStatus::Pending;
                failed_tx |= t.status == TransactionStatus::Failed;
            }
        }
        let status = if pending_saga {
            WithdrawalStatus::Pending
        } else if prepared_saga {
            WithdrawalStatus::Prepared
        } else if completed_tx {
            WithdrawalStatus::Completed
        } else if pending_tx {
            WithdrawalStatus::Pending
        } else if failed_tx {
            WithdrawalStatus::Failed
        } else {
            match q.state {
                MeltQuoteState::Paid => WithdrawalStatus::Unknown,
                MeltQuoteState::Pending => WithdrawalStatus::Pending,
                MeltQuoteState::Failed => WithdrawalStatus::Failed,
                MeltQuoteState::Unpaid => WithdrawalStatus::Unsubmitted,
                _ => WithdrawalStatus::Unknown,
            }
        };
        WithdrawalEvidence {
            status,
            matching_saga,
            pending_or_completed_tx: completed_tx || pending_tx,
        }
    }
}

// Mirrors upstream cdk-ffi's owned PreparedMelt. Never persisted or serialized.
pub(super) struct PreparedWithdrawal {
    wallet: Wallet,
    operation_id: Uuid,
    quote: MeltQuote,
    proofs: Proofs,
    proofs_to_swap: Proofs,
    swap_fee: Amount,
    input_fee: Amount,
    input_fee_without_swap: Amount,
    metadata: HashMap<String, String>,
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;
    use crate::e2e::{fund_wallet, start_fake_mint_ctl, SwapFault};
    use cdk::amount::SplitTarget;
    use std::sync::atomic::AtomicUsize;

    fn fixture_quote(id: &str) -> MeltQuote {
        MeltQuote {
            id: id.into(),
            mint_url: Some("http://127.0.0.1:1234".parse().unwrap()),
            unit: UNIT,
            amount: Amount::from(21),
            request: test_invoice(Some(21_000), false),
            fee_reserve: Amount::from(1),
            state: MeltQuoteState::Unpaid,
            expiry: 0,
            payment_proof: None,
            estimated_blocks: None,
            fee_index: None,
            payment_method: PaymentMethod::BOLT11,
            used_by_operation: None,
            version: 0,
        }
    }

    fn fixture_tx(q: &MeltQuote, status: TransactionStatus) -> cdk_common::wallet::Transaction {
        cdk_common::wallet::Transaction {
            mint_url: q.mint_url.clone().unwrap(),
            direction: TransactionDirection::Outgoing,
            amount: q.amount,
            fee: Amount::from(0),
            unit: q.unit.clone(),
            ys: vec![],
            timestamp: 0,
            memo: None,
            metadata: HashMap::new(),
            quote_id: Some(q.id.clone()),
            payment_request: None,
            payment_proof: None,
            payment_method: None,
            saga_id: None,
            status,
        }
    }

    fn fixture_saga(q: &MeltQuote, state: MeltSagaState) -> WalletSaga {
        WalletSaga::new(
            Uuid::new_v4(),
            WalletSagaState::Melt(state),
            q.amount,
            q.mint_url.clone().unwrap(),
            q.unit.clone(),
            OperationData::Melt(cdk_common::wallet::MeltOperationData {
                quote_id: q.id.clone(),
                amount: q.amount,
                fee_reserve: q.fee_reserve,
                counter_start: None,
                counter_end: None,
                change_amount: None,
                metadata: HashMap::new(),
                final_proof_ys: None,
                change_blinded_messages: None,
            }),
        )
    }

    // Frozen pre-index matcher and projection, intentionally test-only. This
    // independently checks both finer identity predicates and display policy.
    fn reference_projection(
        q: &MeltQuote,
        sagas: &[WalletSaga],
        transactions: &[cdk_common::wallet::Transaction],
        now: u64,
    ) -> Value {
        let matching_sagas: Vec<_> = sagas
            .iter()
            .filter(|s| {
                Some(&s.mint_url) == q.mint_url.as_ref()
                    && s.unit == q.unit
                    && s.quote_id.as_deref() == Some(&q.id)
                    && matches!(&s.data, OperationData::Melt(d) if d.quote_id == q.id)
                    && q.used_by_operation
                        .as_ref()
                        .is_none_or(|id| id == &s.id.to_string())
            })
            .collect();
        let tx: Vec<_> = transactions
            .iter()
            .filter(|t| {
                Some(&t.mint_url) == q.mint_url.as_ref()
                    && t.unit == q.unit
                    && t.quote_id.as_deref() == Some(&q.id)
                    && t.direction == TransactionDirection::Outgoing
                    && t.payment_method
                        .as_ref()
                        .is_none_or(|m| m == &q.payment_method)
                    && q.used_by_operation
                        .as_ref()
                        .is_none_or(|id| t.saga_id.as_ref().is_none_or(|s| id == &s.to_string()))
            })
            .collect();
        let status = if matching_sagas.iter().any(|s| {
            matches!(
                s.state,
                WalletSagaState::Melt(MeltSagaState::MeltRequested | MeltSagaState::PaymentPending)
            )
        }) {
            "pending"
        } else if matching_sagas.iter().any(|s| {
            matches!(
                s.state,
                WalletSagaState::Melt(MeltSagaState::ProofsReserved)
            )
        }) {
            "prepared"
        } else if tx.iter().any(|t| t.status == TransactionStatus::Completed) {
            "completed"
        } else if tx.iter().any(|t| t.status == TransactionStatus::Pending) {
            "pending"
        } else if tx.iter().any(|t| t.status == TransactionStatus::Failed) {
            "failed"
        } else {
            match q.state {
                MeltQuoteState::Paid => "unknown",
                MeltQuoteState::Pending => "pending",
                MeltQuoteState::Failed => "failed",
                MeltQuoteState::Unpaid => "unsubmitted",
                _ => "unknown",
            }
        };
        let expiry = invoice_expiry(&q.request);
        let expired = !matches!(status, "pending" | "completed" | "unknown")
            && ((q.expiry != 0 && q.expiry <= now) || expiry.is_some_and(|t| t <= now));
        let retry = matches!(status, "unsubmitted" | "failed")
            && matching_sagas.is_empty()
            && !tx.iter().any(|t| {
                matches!(
                    t.status,
                    TransactionStatus::Completed | TransactionStatus::Pending
                )
            })
            && expiry.is_some_and(|t| t > now);
        json!({"quote_id":q.id,"mint_url":q.mint_url.as_ref().map(ToString::to_string),"invoice":if q.request.len() <= 4096 { Some(&q.request) } else { None },"unit":q.unit.to_string(),"amount":q.amount.to_u64().to_string(),"quote_state":q.state.to_string(),"payment_status":status,"quote_expiry":q.expiry.to_string(),"invoice_expiry":expiry.map(|n| n.to_string()),"expired":expired,"retry_review_allowed":retry})
    }

    #[test]
    fn withdrawal_index_projection_matches_legacy_identity_and_precedence() {
        let base = fixture_quote("quote");
        let saga = fixture_saga(&base, MeltSagaState::ProofsReserved);
        let tx = fixture_tx(&base, TransactionStatus::Completed);
        let mut sagas = vec![saga.clone()];
        let mut transactions = vec![tx.clone()];
        for mutation in 0..7 {
            let mut s = saga.clone();
            let mut t = tx.clone();
            match mutation {
                0 => {
                    s.mint_url = "http://127.0.0.1:5678".parse().unwrap();
                    t.mint_url = s.mint_url.clone();
                }
                1 => {
                    s.unit = CurrencyUnit::Msat;
                    t.unit = s.unit.clone();
                }
                2 => {
                    s.quote_id = None;
                    t.quote_id = None;
                }
                3 => {
                    s.quote_id = Some("other".into());
                    t.quote_id = s.quote_id.clone();
                }
                4 => {
                    if let OperationData::Melt(d) = &mut s.data {
                        d.quote_id = "other".into();
                    }
                    t.direction = TransactionDirection::Incoming;
                }
                5 => {
                    s.id = Uuid::new_v4();
                    t.saga_id = Some(s.id);
                }
                _ => {
                    t.payment_method = Some(PaymentMethod::Custom("other".into()));
                    s.state = WalletSagaState::Melt(MeltSagaState::PaymentPending);
                }
            }
            sagas.push(s);
            transactions.push(t);
        }
        let mut empty_id = base.clone();
        empty_id.id.clear();
        sagas.push(fixture_saga(&empty_id, MeltSagaState::MeltRequested));
        transactions.push(fixture_tx(&empty_id, TransactionStatus::Pending));
        // Every prefix exercises absent evidence and the precedence transitions;
        // individual records expose exclusions otherwise masked by a valid row.
        let saga_sets: Vec<_> = (0..=sagas.len())
            .map(|n| sagas[..n].to_vec())
            .chain(sagas.iter().map(|s| vec![s.clone()]))
            .collect();
        let tx_sets: Vec<_> = [
            TransactionStatus::Failed,
            TransactionStatus::Pending,
            TransactionStatus::Completed,
        ]
        .into_iter()
        .map(|status| vec![fixture_tx(&base, status)])
        .chain((0..=transactions.len()).map(|n| transactions[..n].to_vec()))
        .chain(transactions.iter().map(|t| vec![t.clone()]))
        .collect();
        for mut q in [base.clone(), empty_id] {
            for state in [
                MeltQuoteState::Unpaid,
                MeltQuoteState::Pending,
                MeltQuoteState::Paid,
                MeltQuoteState::Failed,
                MeltQuoteState::Unknown,
            ] {
                q.state = state;
                for owner in [
                    None,
                    Some(saga.id.to_string()),
                    Some(Uuid::new_v4().to_string()),
                ] {
                    q.used_by_operation = owner;
                    for unknown_mint in [false, true] {
                        q.mint_url = if unknown_mint {
                            None
                        } else {
                            base.mint_url.clone()
                        };
                        for ss in &saga_sets {
                            for ts in &tx_sets {
                                let lookup = WithdrawalLookup::new(ss, ts);
                                for now in [0, u64::MAX] {
                                    assert_eq!(
                                        CdkWallet::project_withdrawal(&q, &lookup, now),
                                        reference_projection(&q, ss, ts, now)
                                    );
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    fn large_fixture(
        n: usize,
    ) -> (
        Vec<MeltQuote>,
        Vec<WalletSaga>,
        Vec<cdk_common::wallet::Transaction>,
    ) {
        let mut template = fixture_quote("");
        // Classification must not parse even oversized invalid legacy invoices.
        template.request = "invalid".repeat(1000);
        let mut quotes = Vec::new();
        let mut sagas = Vec::new();
        let mut transactions = Vec::new();
        for i in 0..n {
            let mut q = template.clone();
            q.id = format!("quote-{i:06}");
            q.state = MeltQuoteState::Paid;
            for status in [
                TransactionStatus::Failed,
                TransactionStatus::Pending,
                TransactionStatus::Completed,
            ] {
                transactions.push(fixture_tx(&q, status));
            }
            if i % 1000 == 0 {
                sagas.push(fixture_saga(&q, MeltSagaState::PaymentPending));
            }
            quotes.push(q);
        }
        (quotes, sagas, transactions)
    }

    #[test]
    fn withdrawal_index_ignores_non_melt_data_but_preserves_matching_saga_retry_gate() {
        let q = fixture_quote("quote");
        let mut saga = fixture_saga(&q, MeltSagaState::ProofsReserved);
        saga.state = WalletSagaState::Swap(cdk_common::wallet::SwapSagaState::ProofsReserved);
        let sagas = [saga.clone()];
        let projected = CdkWallet::project_withdrawal(&q, &WithdrawalLookup::new(&sagas, &[]), 0);
        assert_eq!(projected, reference_projection(&q, &sagas, &[], 0));
        assert_eq!(projected["payment_status"], "unsubmitted");
        assert_eq!(projected["retry_review_allowed"], false);
        saga.data = OperationData::Swap(cdk_common::wallet::SwapOperationData {
            input_amount: q.amount,
            output_amount: q.amount,
            counter_start: None,
            counter_end: None,
            blinded_messages: None,
        });
        let sagas = [saga];
        let projected = CdkWallet::project_withdrawal(&q, &WithdrawalLookup::new(&sagas, &[]), 0);
        assert_eq!(projected, reference_projection(&q, &sagas, &[], 0));
        assert_eq!(projected["retry_review_allowed"], true);
        let mut tx = fixture_tx(&q, TransactionStatus::Completed);
        let mut owned = q.clone();
        owned.used_by_operation = Some(Uuid::new_v4().to_string());
        for method in [None, Some(PaymentMethod::BOLT11)] {
            tx.payment_method = method;
            let transactions = [tx.clone()];
            let projected = CdkWallet::project_withdrawal(
                &owned,
                &WithdrawalLookup::new(&[], &transactions),
                u64::MAX,
            );
            assert_eq!(projected["payment_status"], "completed");
            assert_eq!(projected["expired"], false);
            assert_eq!(projected["retry_review_allowed"], false);
        }
    }

    #[test]
    fn withdrawal_index_large_history_linear_visits_and_fair_candidates() {
        let mut work = Vec::new();
        for n in [2000, 4000] {
            let (quotes, sagas, transactions) = large_fixture(n);
            let lookup = WithdrawalLookup::new(&sagas, &transactions);
            INVOICE_PARSES.with(|count| count.set(0));
            let mut candidates: Vec<_> = quotes
                .iter()
                .filter(|q| lookup.classify(q).poll_candidate(q))
                .map(|q| q.id.clone())
                .collect();
            assert_eq!(INVOICE_PARSES.with(|count| count.get()), 0);
            work.push(lookup.visits.get());
            let expected: Vec<_> = quotes
                .iter()
                .filter(|q| {
                    let view = reference_projection(q, &sagas, &transactions, 0);
                    view["payment_status"] == "pending"
                        || (q.state == MeltQuoteState::Paid
                            && view["payment_status"] != "completed")
                })
                .map(|q| q.id.clone())
                .collect();
            assert_eq!(candidates, expected);
            candidates.sort();
            assert_eq!(candidates.len(), n / 1000);
            for (i, cursor) in candidates.iter().enumerate() {
                let next = candidates
                    .iter()
                    .find(|id| *id > cursor)
                    .or(candidates.first());
                assert_eq!(next, Some(&candidates[(i + 1) % candidates.len()]));
            }
        }
        assert_eq!(
            work[1],
            2 * work[0],
            "actual index insertions plus filtered group visits"
        );
    }

    #[derive(Default)]
    struct Counts {
        quotes: Arc<AtomicUsize>,
        posts: Arc<AtomicUsize>,
        gets: Arc<AtomicUsize>,
        hold: Arc<AtomicBool>,
        fail: Arc<AtomicBool>,
    }

    #[test]
    fn withdrawal_index_native_history_pages_and_inactive_poll_are_local() {
        runtime().block_on(async {
            let counts = Counts::default();
            let (mint, server) = start_fake_mint_ctl(0, counts.fault()).await;
            let dir = tempfile::tempdir().unwrap();
            let (mut h, _) = CdkWallet::open(&[89; 64], dir.path().join("wallet.sqlite").to_str().unwrap()).await.unwrap();
            let empty = value(h.quote_history_page("0").await.unwrap());
            assert_eq!(empty["rows"], json!([]));
            assert_eq!(empty["total"], "0");
            let owner: MintUrl = mint.parse().unwrap();
            for i in 0..25 {
                let mut q = fixture_quote(&format!("out-{i:03}"));
                q.mint_url = Some(owner.clone());
                q.state = MeltQuoteState::Paid;
                // Three distinct attempts per quote survive real CDK storage.
                for status in [TransactionStatus::Failed, TransactionStatus::Pending, TransactionStatus::Completed] {
                    let mut t = fixture_tx(&q, status);
                    t.saga_id = Some(Uuid::new_v4());
                    h.db.add_transaction(t).await.unwrap();
                }
                h.db.add_melt_quote(q).await.unwrap();
            }
            let mut expired = fixture_quote("out-expired");
            expired.mint_url = Some(owner.clone());
            expired.expiry = 1;
            h.db.add_melt_quote(expired).await.unwrap();
            h.db.add_mint_quote(cdk_common::wallet::MintQuote {
                id: "incoming".into(), mint_url: owner, payment_method: PaymentMethod::BOLT11,
                amount: Some(Amount::from(21)), unit: UNIT, request: "invoice".into(),
                state: MintQuoteState::Unpaid, expiry: 0, secret_key: None,
                amount_issued: Amount::ZERO, amount_paid: Amount::ZERO, updated_at: 0,
                estimated_blocks: None, used_by_operation: None, version: 0,
            }).await.unwrap();
            let mut ids = Vec::new();
            for offset in ["0", "8", "16", "24"] {
                let page = value(h.quote_history_page(offset).await.unwrap());
                assert_eq!(page["total"], "27");
                assert_eq!(page["rows"].as_array().unwrap().len(), if offset == "24" { 3 } else { 8 });
                for row in page["rows"].as_array().unwrap() {
                    let id = row["id"].as_str().unwrap();
                    if id == "incoming" { assert_eq!(row["direction"], "In"); }
                    else if id == "out-expired" { assert_eq!(row["payment_status"], "unsubmitted"); assert_eq!(row["expired"], true); }
                    else { assert_eq!(row["payment_status"], "completed"); assert!(row.get("retry_review_allowed").is_none()); }
                    ids.push(id.to_owned());
                }
            }
            assert_eq!(ids.iter().collect::<BTreeSet<_>>().len(), 27);
            assert_eq!(ids.first().unwrap(), "incoming");
            assert_eq!(value(h.quote_history_page("4294967288").await.unwrap())["offset"], "24");
            let poll = value(h.poll_withdrawals(&mint, "old-cursor").await.unwrap());
            assert_eq!(poll, json!({"cursor":"","checked_id":null,"withdrawal":null,"wallet_changed":false,"recovery_pending":false,"error":null}));
            assert_eq!(counts.quotes.load(Ordering::SeqCst), 0);
            assert_eq!(counts.gets.load(Ordering::SeqCst), 0);
            assert_eq!(counts.posts(), 0);
            server.abort();
        });
    }
    impl Counts {
        fn fault(&self) -> SwapFault {
            SwapFault::WithdrawalControl {
                quotes: self.quotes.clone(),
                posts: self.posts.clone(),
                gets: self.gets.clone(),
                hold_pending: self.hold.clone(),
                fail_get: self.fail.clone(),
            }
        }
        fn posts(&self) -> usize {
            self.posts.load(Ordering::SeqCst)
        }
    }
    fn value(raw: String) -> Value {
        serde_json::from_str(&raw).unwrap()
    }
    fn test_invoice(amount: Option<u64>, expired: bool) -> String {
        use cdk::lightning_invoice::{Currency, InvoiceBuilder, PaymentSecret};
        use cdk_common::bitcoin::secp256k1::{Secp256k1, SecretKey};
        let builder = InvoiceBuilder::new(Currency::Bitcoin)
            .description("test only".into())
            .payment_hash(sha256::Hash::hash(b"test invoice"))
            .payment_secret(PaymentSecret([42; 32]))
            .duration_since_epoch(Duration::from_secs(if expired { 1 } else { unix_now() }))
            .expiry_time(Duration::from_secs(3600))
            .min_final_cltv_expiry_delta(144);
        let builder = match amount {
            Some(amount) => builder.amount_milli_satoshis(amount),
            None => builder,
        };
        builder
            .build_signed(|hash| {
                Secp256k1::new()
                    .sign_ecdsa_recoverable(hash, &SecretKey::from_slice(&[7; 32]).unwrap())
            })
            .unwrap()
            .to_string()
    }

    #[test]
    fn withdrawal_validation_prefix_and_bounds() {
        let valid = cdk_fake_wallet::create_fake_invoice(21_000, "x".repeat(600)).to_string();
        assert!(valid.len() > 1024 && valid.len() < 4096);
        assert_eq!(invoice(&format!("  LiGhTnInG:{valid}  ")).unwrap(), valid);
        for text in [
            "invalid".into(),
            test_invoice(None, false),
            test_invoice(Some(0), false),
            test_invoice(Some(1000), true),
            format!("{valid}\0"),
            format!("\t{valid}"),
            format!("{} {}", &valid[..20], &valid[20..]),
            "x".repeat(4097),
        ] {
            assert!(invoice(&text).is_err());
        }
    }

    #[test]
    fn withdrawal_operation_classifier() {
        for operation in [
            "prepare_withdrawal",
            "confirm_withdrawal",
            "cancel_withdrawal",
            "saved_withdrawal",
            "poll_withdrawals",
        ] {
            assert!(CdkWallet::is_withdrawal_operation(operation));
        }
        for operation in [
            "",
            "unknown",
            "prepare_withdrawal_extra",
            "PREPARE_WITHDRAWAL",
            "saved_invoice",
        ] {
            assert!(!CdkWallet::is_withdrawal_operation(operation));
        }
    }

    #[test]
    fn withdrawal_native_json_limit_and_exact_arity() {
        let counts = Counts::default();
        let (mint, server) = runtime().block_on(start_fake_mint_ctl(0, counts.fault()));
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wallet.sqlite");
        let (mut h, _) = runtime()
            .block_on(CdkWallet::open(&[84; 64], path.to_str().unwrap()))
            .unwrap();
        runtime().block_on(h.add_mint(&mint)).unwrap();
        let _funding = runtime().block_on(fund_wallet(
            &path,
            [84; 64],
            &mint,
            64,
            SplitTarget::default(),
        ));
        let request = cdk_fake_wallet::create_fake_invoice(63_000, "x".repeat(600)).to_string();
        let call = |h: &mut CdkWallet, operation: &str, raw: String| {
            let op: char_p::Box = operation.to_owned().try_into().unwrap();
            let args: char_p::Box = raw.try_into().unwrap();
            crate::api::cdk_wallet_quotes(Some(h), Some(op.as_ref()), Some(args.as_ref()))
        };
        let unsupported = runtime()
            .block_on(h.withdrawal_request("unknown", &mint, &request))
            .unwrap_err();
        assert_eq!(unsupported.status, CdkStatus::InvalidArgument);
        assert!(h.prepared_withdrawal.is_none());
        for operation in [
            "prepare_withdrawal",
            "confirm_withdrawal",
            "cancel_withdrawal",
            "saved_withdrawal",
            "poll_withdrawals",
            "unknown",
        ] {
            for raw in [
                format!("{}[]", " ".repeat(8193)),
                json!([mint]).to_string(),
                json!([mint, request, "extra"]).to_string(),
                json!([mint, 1]).to_string(),
                json!([mint, "bad\0invoice"]).to_string(),
            ] {
                let result = call(&mut h, operation, raw);
                assert_eq!(result.status, CdkStatus::InvalidArgument);
                crate::api::cdk_string_free(result.error);
                crate::api::cdk_string_free(result.value);
            }
        }
        assert_eq!(counts.quotes.load(Ordering::SeqCst), 0);
        // Legal whitespace padding proves the new raw limit is applied before
        // parsing, without enlarging the 4096-byte individual invoice bound.
        let raw = format!("{}{}", " ".repeat(4096), json!([mint, request]));
        assert!(raw.len() > 4096 && raw.len() < 8192);
        let result = call(&mut h, "prepare_withdrawal", raw);
        assert_eq!(result.status, CdkStatus::Ok);
        let review = value(result.value.as_ref().unwrap().to_str().to_owned());
        crate::api::cdk_string_free(result.error);
        crate::api::cdk_string_free(result.value);
        assert_eq!(counts.posts(), 0);
        let gets = counts.gets.load(Ordering::SeqCst);
        let result = call(
            &mut h,
            "saved_withdrawal",
            json!([mint, review["quote_id"]]).to_string(),
        );
        assert_eq!(result.status, CdkStatus::Ok);
        assert_eq!(
            value(result.value.as_ref().unwrap().to_str().to_owned())["payment_status"],
            "prepared"
        );
        crate::api::cdk_string_free(result.error);
        crate::api::cdk_string_free(result.value);
        let result = call(&mut h, "poll_withdrawals", json!([mint, ""]).to_string());
        assert_eq!(result.status, CdkStatus::RecoveryPending);
        crate::api::cdk_string_free(result.error);
        crate::api::cdk_string_free(result.value);
        assert_eq!(counts.gets.load(Ordering::SeqCst), gets);
        assert_eq!(counts.posts(), 0);
        let result = call(
            &mut h,
            "cancel_withdrawal",
            json!([mint, review["operation_id"]]).to_string(),
        );
        assert_eq!(result.status, CdkStatus::Ok);
        crate::api::cdk_string_free(result.error);
        crate::api::cdk_string_free(result.value);
        let result = call(
            &mut h,
            "prepare_withdrawal",
            json!([mint, request]).to_string(),
        );
        assert_eq!(result.status, CdkStatus::Ok);
        let review = value(result.value.as_ref().unwrap().to_str().to_owned());
        crate::api::cdk_string_free(result.error);
        crate::api::cdk_string_free(result.value);
        for expected in [CdkStatus::Ok, CdkStatus::InvalidArgument] {
            let result = call(
                &mut h,
                "confirm_withdrawal",
                json!([mint, review["operation_id"]]).to_string(),
            );
            assert_eq!(result.status, expected);
            crate::api::cdk_string_free(result.error);
            crate::api::cdk_string_free(result.value);
        }
        assert_eq!(counts.posts(), 1);
        let result = call(&mut h, "saved_invoice", format!("{}[]", " ".repeat(4097)));
        assert_eq!(result.status, CdkStatus::InvalidArgument);
        crate::api::cdk_string_free(result.error);
        crate::api::cdk_string_free(result.value);
        server.abort();
    }

    #[test]
    fn withdrawal_real_review_cancel_and_confirm_once() {
        runtime().block_on(async {
            let counts = Counts::default();
            let (mint, server) = start_fake_mint_ctl(0, counts.fault()).await;
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("wallet.sqlite");
            let (mut h, _) = CdkWallet::open(&[81; 64], path.to_str().unwrap())
                .await
                .unwrap();
            h.add_mint(&mint).await.unwrap();
            // Single primary denomination avoids upstream nested-swap edge cases.
            let funding = fund_wallet(&path, [81; 64], &mint, 64, SplitTarget::default()).await;
            let request = cdk_fake_wallet::create_fake_invoice(63_000, "x".repeat(600)).to_string();
            for bad in [
                "bad".to_owned(),
                test_invoice(None, false),
                test_invoice(Some(0), false),
                test_invoice(Some(1000), true),
            ] {
                assert!(h.prepare_withdrawal(&mint, &bad).await.is_err());
            }
            assert_eq!(counts.quotes.load(Ordering::SeqCst), 0);
            let review = value(
                h.prepare_withdrawal(&mint, &format!("  LIGHTNING:{request}  "))
                    .await
                    .unwrap(),
            );
            let token = review["operation_id"].as_str().unwrap();
            let id = review["quote_id"].as_str().unwrap();
            assert_eq!(review["invoice"], request);
            assert_eq!(review["estimated_total"], "64");
            assert_eq!(counts.posts(), 0);
            assert_eq!(funding.total_balance().await.unwrap().to_u64(), 0);
            let saved = value(h.saved_withdrawal(&mint, id).await.unwrap());
            assert_eq!(saved["payment_status"], "prepared");
            assert_eq!(saved["quote_state"], "UNPAID");
            let operation = Uuid::parse_str(token).unwrap();
            let saga = h.db.get_saga(&operation).await.unwrap().unwrap();
            assert!(matches!(
                saga.state,
                WalletSagaState::Melt(MeltSagaState::ProofsReserved)
            ));
            let reserved = h.db.get_reserved_proofs(&operation).await.unwrap();
            assert!(!reserved.is_empty());
            let gets = counts.gets.load(Ordering::SeqCst);
            let screen = value(h.wallet_screen(&mint).await.unwrap());
            assert_eq!(screen["sats"], "0");
            assert_eq!(screen["creation_recovery"], "none");
            let history = value(h.quote_history_page("0").await.unwrap());
            assert!(history["rows"]
                .as_array()
                .unwrap()
                .iter()
                .any(|row| row["id"] == id
                    && row["direction"] == "Out"
                    && row["payment_status"] == "prepared"));
            assert_eq!(
                h.prepared_withdrawal.as_ref().unwrap().operation_id,
                operation
            );
            assert_eq!(
                h.run_recovery(None).await.unwrap_err().status,
                CdkStatus::RecoveryPending
            );
            assert_eq!(
                h.deposit_update(&mint, "poll", "")
                    .await
                    .unwrap_err()
                    .status,
                CdkStatus::RecoveryPending
            );
            assert_eq!(
                h.check_deposit(&mint, "missing").await.unwrap_err().status,
                CdkStatus::RecoveryPending
            );
            assert_eq!(
                h.poll_deposits(&mint, "").await.unwrap_err().status,
                CdkStatus::RecoveryPending
            );
            assert_eq!(
                h.poll_withdrawals(&mint, "").await.unwrap_err().status,
                CdkStatus::RecoveryPending
            );
            assert!(
                serde_json::to_value(h.db.get_saga(&operation).await.unwrap().unwrap()).unwrap()
                    == serde_json::to_value(saga).unwrap(),
                "local reads or guarded operations changed the CDK saga"
            );
            assert!(
                serde_json::to_value(h.db.get_reserved_proofs(&operation).await.unwrap()).unwrap()
                    == serde_json::to_value(reserved).unwrap(),
                "local reads or guarded operations changed reserved proofs"
            );
            assert_eq!(counts.gets.load(Ordering::SeqCst), gets);
            assert_eq!(counts.posts(), 0);
            assert!(h
                .confirm_withdrawal(&mint, &Uuid::new_v4().to_string())
                .await
                .is_err());
            assert!(h
                .confirm_withdrawal("http://127.0.0.1:1", token)
                .await
                .is_err());
            assert_eq!(counts.posts(), 0);
            h.cancel_withdrawal(&mint, token).await.unwrap();
            assert_eq!(funding.total_balance().await.unwrap().to_u64(), 64);
            assert_eq!(value(h.wallet_screen(&mint).await.unwrap())["sats"], "64");
            assert!(h.confirm_withdrawal(&mint, token).await.is_err());
            let review = value(h.prepare_withdrawal(&mint, &request).await.unwrap());
            let token = review["operation_id"].as_str().unwrap();
            let id = review["quote_id"].as_str().unwrap();
            let result = value(h.confirm_withdrawal(&mint, token).await.unwrap());
            assert!(matches!(
                result["payment_status"].as_str(),
                Some("completed" | "pending")
            ));
            assert_eq!(counts.posts(), 1);
            for _ in 0..30 {
                if value(h.saved_withdrawal(&mint, id).await.unwrap())["payment_status"]
                    == "completed"
                {
                    break;
                }
                h.poll_withdrawals(&mint, "").await.unwrap();
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            assert_eq!(
                value(h.saved_withdrawal(&mint, id).await.unwrap())["payment_status"],
                "completed"
            );
            assert!(h.confirm_withdrawal(&mint, token).await.is_err());
            assert_eq!(counts.posts(), 1);
            assert_eq!(funding.total_balance().await.unwrap().to_u64(), 0);
            let gets = counts.gets.load(Ordering::SeqCst);
            assert_eq!(
                value(h.saved_withdrawal(&mint, id).await.unwrap())["payment_status"],
                "completed"
            );
            let history = value(h.quote_history_page("0").await.unwrap());
            assert!(history["rows"]
                .as_array()
                .unwrap()
                .iter()
                .any(|r| r["payment_status"] == "completed"));
            assert_eq!(counts.gets.load(Ordering::SeqCst), gets);
            assert!(h.saved_withdrawal("http://127.0.0.1:1", id).await.is_err());
            let mut old = h.db.get_melt_quote(id).await.unwrap().unwrap();
            old.request = "x".repeat(2 * 1024 * 1024);
            h.db.add_melt_quote(old).await.unwrap();
            let history = h.quote_history_page("0").await.unwrap();
            assert!(history.len() < 128 * 1024);
            assert!(value(history)["rows"]
                .as_array()
                .unwrap()
                .iter()
                .any(|r| r["error"].is_string()));
            assert!(h.saved_withdrawal(&mint, id).await.is_err());
            server.abort();
        });
    }

    #[test]
    fn withdrawal_fees_expiry_and_existing_recovery_gate() {
        runtime().block_on(async {
            let counts = Counts::default();
            let (mint, server) = start_fake_mint_ctl(1000, counts.fault()).await;
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("wallet.sqlite");
            let (mut h, _) = CdkWallet::open(&[82; 64], path.to_str().unwrap())
                .await
                .unwrap();
            h.add_mint(&mint).await.unwrap();
            let funding = fund_wallet(&path, [82; 64], &mint, 64, SplitTarget::default()).await;
            let expensive = cdk_fake_wallet::create_fake_invoice(63_000, String::new()).to_string();
            assert!(h.prepare_withdrawal(&mint, &expensive).await.is_err());
            assert_eq!(counts.posts(), 0);
            let request = cdk_fake_wallet::create_fake_invoice(31_000, String::new()).to_string();
            let review = value(h.prepare_withdrawal(&mint, &request).await.unwrap());
            assert_eq!(review["input_fee"], "1");
            let token = review["operation_id"].as_str().unwrap();
            let id = review["quote_id"].as_str().unwrap();
            let mut q = h.db.get_melt_quote(id).await.unwrap().unwrap();
            q.expiry = 1;
            q.state = MeltQuoteState::Unpaid;
            h.db.add_melt_quote(q).await.unwrap();
            assert!(h.confirm_withdrawal(&mint, token).await.is_err());
            assert_eq!(counts.posts(), 0);
            assert_eq!(funding.total_balance().await.unwrap().to_u64(), 64);
            let request =
                cdk_fake_wallet::create_fake_invoice(31_000, "another".into()).to_string();
            let review = value(h.prepare_withdrawal(&mint, &request).await.unwrap());
            h.unresolved.insert(mint.parse().unwrap());
            h.cancel_withdrawal(&mint, review["operation_id"].as_str().unwrap())
                .await
                .unwrap();
            assert!(h.unresolved.contains(&mint.parse().unwrap()));
            server.abort();
        });
    }

    #[test]
    fn withdrawal_accepted_confirm_preflight_faults_leave_cdk_recovery_available() {
        runtime().block_on(async {
            for expired_cancel in [false, true] {
                let counts = Counts::default();
                let (mint, server) = start_fake_mint_ctl(0, counts.fault()).await;
                let dir = tempfile::tempdir().unwrap();
                let path = dir.path().join("wallet.sqlite");
                let (mut h, _) = CdkWallet::open(&[87; 64], path.to_str().unwrap())
                    .await
                    .unwrap();
                h.add_mint(&mint).await.unwrap();
                let funding = fund_wallet(&path, [87; 64], &mint, 64, SplitTarget::default()).await;
                let request =
                    cdk_fake_wallet::create_fake_invoice(63_000, String::new()).to_string();
                let review = value(h.prepare_withdrawal(&mint, &request).await.unwrap());
                let token = review["operation_id"].as_str().unwrap();
                let operation = Uuid::parse_str(token).unwrap();
                assert!(!h
                    .db
                    .get_reserved_proofs(&operation)
                    .await
                    .unwrap()
                    .is_empty());
                assert_eq!(funding.total_balance().await.unwrap().to_u64(), 0);
                if expired_cancel {
                    let mut quote =
                        h.db.get_melt_quote(review["quote_id"].as_str().unwrap())
                            .await
                            .unwrap()
                            .unwrap();
                    quote.expiry = 1;
                    h.db.add_melt_quote(quote).await.unwrap();
                }
                let conn = rusqlite::Connection::open(&path).unwrap();
                // Isolated DB schema faults exercise actual CDK reads/cancel,
                // without modifying production proof or saga state ourselves.
                let table = if expired_cancel {
                    "wallet_sagas"
                } else {
                    "melt_quote"
                };
                conn.execute_batch(&format!(
                    "ALTER TABLE {table} RENAME TO hidden_confirm_table;"
                ))
                .unwrap();
                assert!(h.confirm_withdrawal(&mint, token).await.is_err());
                assert!(h.prepared_withdrawal.is_none());
                assert!(h.unresolved.contains(&mint.parse().unwrap()));
                assert_eq!(counts.posts(), 0);
                conn.execute_batch(&format!(
                    "ALTER TABLE hidden_confirm_table RENAME TO {table};"
                ))
                .unwrap();
                assert!(h.confirm_withdrawal(&mint, token).await.is_err());
                assert!(!h
                    .db
                    .get_reserved_proofs(&operation)
                    .await
                    .unwrap()
                    .is_empty());
                let saga = h.db.get_saga(&operation).await.unwrap().unwrap();
                assert!(matches!(
                    saga.state,
                    WalletSagaState::Melt(MeltSagaState::ProofsReserved)
                ));
                let recovered = h.run_recovery(None).await.unwrap();
                assert!(recovered.iter().all(|report| report.failed == 0));
                assert!(!h.unresolved.contains(&mint.parse().unwrap()));
                assert!(h
                    .db
                    .get_reserved_proofs(&operation)
                    .await
                    .unwrap()
                    .is_empty());
                assert!(h.db.get_saga(&operation).await.unwrap().is_none());
                assert_eq!(funding.total_balance().await.unwrap().to_u64(), 64);
                assert_eq!(counts.posts(), 0);
                server.abort();
            }
        });
    }

    #[test]
    fn withdrawal_poll_fresh_unapproved_wallet_is_inactive_local_noop() {
        runtime().block_on(async {
            let counts = Counts::default();
            let (mint, server) = start_fake_mint_ctl(0, counts.fault()).await;
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("wallet.sqlite");
            let (mut h, _) = CdkWallet::open(&[88; 64], path.to_str().unwrap()).await.unwrap();
            assert!(h.list_mints().await.is_empty());
            let conn = rusqlite::Connection::open(&path).unwrap();
            // Polling inactive withdrawals must not read balance proofs or
            // history's creation metadata, nor try to approve/contact a mint.
            conn.execute_batch("ALTER TABLE proof RENAME TO hidden_poll_proofs; ALTER TABLE kv_store RENAME TO hidden_poll_metadata;").unwrap();
            for _ in 0..3 {
                let poll = value(h.poll_withdrawals(&mint, "previous").await.unwrap());
                assert_eq!(poll["cursor"], "");
                assert_eq!(poll["checked_id"], Value::Null);
                assert_eq!(poll["withdrawal"], Value::Null);
                assert_eq!(poll["wallet_changed"], false);
                assert_eq!(poll["recovery_pending"], false);
                assert_eq!(poll["error"], Value::Null);
            }
            conn.execute_batch("ALTER TABLE hidden_poll_proofs RENAME TO proof; ALTER TABLE hidden_poll_metadata RENAME TO kv_store;").unwrap();
            assert!(h.list_mints().await.is_empty());
            assert_eq!(counts.quotes.load(Ordering::SeqCst), 0);
            assert_eq!(counts.gets.load(Ordering::SeqCst), 0);
            assert_eq!(counts.posts(), 0);
            server.abort();
        });
    }

    #[test]
    fn withdrawal_poll_preselection_read_failure_retains_cursor_without_invalidation() {
        runtime().block_on(async {
            let counts = Counts::default();
            let (mint, server) = start_fake_mint_ctl(0, counts.fault()).await;
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("wallet.sqlite");
            let (mut h, _) = CdkWallet::open(&[85; 64], path.to_str().unwrap())
                .await
                .unwrap();
            h.add_mint(&mint).await.unwrap();
            let empty = value(h.poll_withdrawals(&mint, "previous").await.unwrap());
            assert_eq!(empty["wallet_changed"], false);
            assert_eq!(empty["cursor"], "");
            let conn = rusqlite::Connection::open(&path).unwrap();
            conn.execute_batch("ALTER TABLE wallet_sagas RENAME TO hidden_wallet_sagas;")
                .unwrap();
            let failed = value(h.poll_withdrawals(&mint, "previous").await.unwrap());
            assert_eq!(failed["cursor"], "previous");
            assert_eq!(failed["checked_id"], Value::Null);
            assert_eq!(failed["withdrawal"], Value::Null);
            assert_eq!(failed["wallet_changed"], false);
            assert!(failed["error"].is_object());
            assert_eq!(counts.posts(), 0);
            conn.execute_batch("ALTER TABLE hidden_wallet_sagas RENAME TO wallet_sagas;")
                .unwrap();
            server.abort();
        });
    }

    #[test]
    fn withdrawal_default_21_from_1000_paid_then_pending() {
        runtime().block_on(async {
            let counts = Counts::default();
            let (mint, server) = start_fake_mint_ctl(0, counts.fault()).await;
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("wallet.sqlite");
            let (mut h, _) = CdkWallet::open(&[86; 64], path.to_str().unwrap()).await.unwrap();
            h.add_mint(&mint).await.unwrap();
            let funding = fund_wallet(&path, [86; 64], &mint, 1000, SplitTarget::default()).await;
            for (index, pending) in [false, true].into_iter().enumerate() {
                let description = if pending {
                    let mut description = serde_json::to_string(&cdk_fake_wallet::FakeInvoiceDescription {
                        pay_invoice_state: MeltQuoteState::Pending,
                        check_payment_state: MeltQuoteState::Paid,
                        pay_err: false,
                        check_err: false,
                    }).unwrap();
                    description.push_str(&" ".repeat(600 - description.len()));
                    description
                } else { "x".repeat(600) };
                let request = cdk_fake_wallet::create_fake_invoice(21_000, description).to_string();
                let review = value(h.prepare_withdrawal(&mint, &request).await.unwrap());
                let id = review["quote_id"].as_str().unwrap();
                if !pending {
                    // With this real CDK denomination/fee selection, default
                    // options do not require a pre-swap. Do not force one.
                    assert_eq!(review["requires_swap"], false);
                }
                assert_eq!(counts.posts(), index);
                counts.hold.store(pending, Ordering::SeqCst);
                let confirmed = value(h.confirm_withdrawal(&mint, review["operation_id"].as_str().unwrap()).await.unwrap());
                if pending {
                    assert_eq!(confirmed["payment_status"], "pending");
                    let held = value(h.poll_withdrawals(&mint, "").await.unwrap());
                    assert_eq!(held["wallet_changed"], true);
                    assert_eq!(held["withdrawal"]["payment_status"], "pending");
                }
                counts.hold.store(false, Ordering::SeqCst);
                for _ in 0..30 {
                    if value(h.saved_withdrawal(&mint, id).await.unwrap())["payment_status"] == "completed" { break; }
                    h.poll_withdrawals(&mint, "").await.unwrap();
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
                assert_eq!(value(h.saved_withdrawal(&mint, id).await.unwrap())["payment_status"], "completed");
                let transactions = h.db.list_transactions(None, None, None).await.unwrap();
                let outgoing = transactions.iter().find(|tx| tx.quote_id.as_deref() == Some(id) && tx.direction == TransactionDirection::Outgoing).unwrap();
                assert_eq!(outgoing.status, TransactionStatus::Completed);
                assert_eq!(outgoing.amount.to_u64(), 21);
                let balance = funding.total_balance().await.unwrap().to_u64();
                assert_eq!(balance, if pending { 957 } else { 978 });
                assert_eq!(outgoing.fee.to_u64(), if pending { 0 } else { 1 });
                println!("default 21-sat withdrawal {}: balance={balance}, CDK outgoing fee={}, review reserve={}, swap_fee={}, input_fee={}", index + 1, outgoing.fee.to_u64(), review["fee_reserve"], review["swap_fee"], review["input_fee"]);
                assert_eq!(counts.posts(), index + 1);
            }
            server.abort();
        });
    }

    #[test]
    fn withdrawal_pending_reopen_recovers_without_payment_repost() {
        runtime().block_on(async {
            let counts = Counts::default();
            let (mint, server) = start_fake_mint_ctl(0, counts.fault()).await;
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("wallet.sqlite");
            let (mut h, _) = CdkWallet::open(&[83; 64], path.to_str().unwrap())
                .await
                .unwrap();
            h.add_mint(&mint).await.unwrap();
            let _funding = fund_wallet(&path, [83; 64], &mint, 64, SplitTarget::default()).await;
            let description = serde_json::to_string(&cdk_fake_wallet::FakeInvoiceDescription {
                pay_invoice_state: MeltQuoteState::Pending,
                check_payment_state: MeltQuoteState::Paid,
                pay_err: false,
                check_err: false,
            })
            .unwrap();
            let request = cdk_fake_wallet::create_fake_invoice(63_000, description).to_string();
            let review = value(h.prepare_withdrawal(&mint, &request).await.unwrap());
            let id = review["quote_id"].as_str().unwrap();
            counts.hold.store(true, Ordering::SeqCst);
            let result = value(
                h.confirm_withdrawal(&mint, review["operation_id"].as_str().unwrap())
                    .await
                    .unwrap(),
            );
            assert_eq!(result["payment_status"], "pending");
            assert_eq!(counts.posts(), 1);
            let mut q = h.db.get_melt_quote(id).await.unwrap().unwrap();
            q.expiry = 1;
            q.state = MeltQuoteState::Unpaid;
            h.db.add_melt_quote(q).await.unwrap();
            let pending = value(h.saved_withdrawal(&mint, id).await.unwrap());
            assert_eq!(pending["quote_state"], "UNPAID");
            assert_eq!(pending["payment_status"], "pending");
            let pending = value(h.poll_withdrawals(&mint, "").await.unwrap());
            assert_eq!(pending["checked_id"], id);
            assert_eq!(pending["withdrawal"]["payment_status"], "pending");
            assert_eq!(pending["withdrawal"]["expired"], false);
            assert_eq!(pending["wallet_changed"], true);
            let mut oversized = h.db.get_melt_quote(id).await.unwrap().unwrap();
            oversized.request = "x".repeat(4097);
            h.db.add_melt_quote(oversized.clone()).await.unwrap();
            let failed_view = value(h.poll_withdrawals(&mint, "").await.unwrap());
            assert_eq!(failed_view["wallet_changed"], true);
            assert_eq!(failed_view["cursor"], id);
            assert_eq!(failed_view["checked_id"], id);
            assert_eq!(failed_view["withdrawal"], Value::Null);
            assert!(failed_view["error"].is_object());
            assert_eq!(counts.posts(), 1);
            let mut oversized = h.db.get_melt_quote(id).await.unwrap().unwrap();
            oversized.request = request.clone();
            h.db.add_melt_quote(oversized).await.unwrap();
            counts.fail.store(true, Ordering::SeqCst);
            h.unresolved.insert(mint.parse().unwrap());
            let failure = value(h.poll_withdrawals(&mint, "").await.unwrap());
            assert_eq!(failure["cursor"], id);
            assert_eq!(failure["wallet_changed"], true);
            assert_eq!(failure["recovery_pending"], true);
            // CDK may retain a pending saga rather than surface an HTTP error.
            assert_eq!(counts.posts(), 1);
            counts.fail.store(false, Ordering::SeqCst);
            counts.hold.store(false, Ordering::SeqCst);
            drop(h);
            let (mut h, _) = CdkWallet::open(&[83; 64], path.to_str().unwrap())
                .await
                .unwrap();
            for _ in 0..20 {
                if value(h.saved_withdrawal(&mint, id).await.unwrap())["payment_status"]
                    == "completed"
                {
                    break;
                }
                h.poll_withdrawals(&mint, "").await.unwrap();
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            assert_eq!(
                value(h.saved_withdrawal(&mint, id).await.unwrap())["payment_status"],
                "completed"
            );
            assert_eq!(counts.posts(), 1);
            let gets = counts.gets.load(Ordering::SeqCst);
            let empty = value(h.poll_withdrawals(&mint, "").await.unwrap());
            assert_eq!(empty["checked_id"], Value::Null);
            assert_eq!(empty["wallet_changed"], false);
            assert_eq!(empty["cursor"], "");
            assert_eq!(counts.gets.load(Ordering::SeqCst), gets);
            server.abort();
        });
    }
}

fn invalid(message: &str) -> FfiErr {
    FfiErr::new(CdkStatus::InvalidArgument, message)
}

#[cfg(test)]
thread_local! {
    static INVOICE_PARSES: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

fn invoice_expiry(text: &str) -> Option<u64> {
    #[cfg(test)]
    INVOICE_PARSES.with(|count| count.set(count.get() + 1));
    if text.len() > 4096 {
        return None;
    }
    Bolt11Invoice::from_str(text)
        .ok()?
        .expires_at()
        .map(|d| d.as_secs())
}

fn invoice(text: &str) -> FfiResult<String> {
    if text.len() > 4096 || !text.is_ascii() || text.contains('\0') {
        return Err(invalid("invalid invoice length or encoding"));
    }
    let text = text.trim_matches(' ');
    const PREFIX: &str = "lightning:";
    let text = if text
        .get(..PREFIX.len())
        .is_some_and(|s| s.eq_ignore_ascii_case(PREFIX))
    {
        &text[PREFIX.len()..]
    } else {
        text
    };
    if text.is_empty()
        || text
            .bytes()
            .any(|b| b.is_ascii_whitespace() || b.is_ascii_control())
    {
        return Err(invalid("invalid invoice whitespace"));
    }
    let parsed = Bolt11Invoice::from_str(text).map_err(|_| invalid("invalid BOLT11 invoice"))?;
    if parsed.amount_milli_satoshis().unwrap_or(0) == 0 {
        return Err(invalid("invoice must have a fixed positive amount"));
    }
    if parsed
        .expires_at()
        .is_none_or(|d| d.as_secs() <= unix_now())
    {
        return Err(invalid("invoice expired"));
    }
    Ok(parsed.to_string())
}

fn identifier(text: &str, empty: bool) -> FfiResult<()> {
    if (!empty && text.is_empty()) || text.len() > 1024 || text.chars().any(char::is_control) {
        return Err(invalid("invalid quote identifier"));
    }
    Ok(())
}

fn bounded(value: Value) -> FfiResult<String> {
    let value = value.to_string();
    if value.len() > 128 * 1024 {
        return Err(invalid("withdrawal response exceeds maximum size"));
    }
    Ok(value)
}

impl CdkWallet {
    pub(crate) fn is_withdrawal_operation(operation: &str) -> bool {
        matches!(
            operation,
            "prepare_withdrawal"
                | "confirm_withdrawal"
                | "cancel_withdrawal"
                | "saved_withdrawal"
                | "poll_withdrawals"
        )
    }

    pub(crate) async fn withdrawal_request(
        &mut self,
        operation: &str,
        mint: &str,
        argument: &str,
    ) -> FfiResult<String> {
        match operation {
            "prepare_withdrawal" => self.prepare_withdrawal(mint, argument).await,
            "confirm_withdrawal" => self.confirm_withdrawal(mint, argument).await,
            "cancel_withdrawal" => self.cancel_withdrawal(mint, argument).await,
            "saved_withdrawal" => self.saved_withdrawal(mint, argument).await,
            "poll_withdrawals" => self.poll_withdrawals(mint, argument).await,
            _ => Err(FfiErr::new(
                CdkStatus::InvalidArgument,
                "invalid quote operation",
            )),
        }
    }

    pub(super) fn guard_prepared_withdrawal(&self, mint: Option<&MintUrl>) -> FfiResult<()> {
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        if self
            .prepared_withdrawal
            .as_ref()
            .is_some_and(|p| mint.is_none_or(|m| m == &p.wallet.mint_url))
        {
            return Err(FfiErr::new(
                CdkStatus::RecoveryPending,
                "cancel or confirm the active withdrawal review first",
            ));
        }
        Ok(())
    }

    pub(crate) async fn prepare_withdrawal(&mut self, mint: &str, text: &str) -> FfiResult<String> {
        let request = invoice(text)?;
        let mint = parse_mint_url(mint)?;
        // Only one owned review may exist, even across mints.
        self.guard_prepared_withdrawal(None)?;
        self.approved_wallet(&mint).await?;
        self.run_recovery(Some(&mint)).await?;
        let wallet = self.deposit_wallet(&mint).await?;
        // CDK owns duplicate/in-flight detection. Never submit payment here.
        for q in self.db.get_melt_quotes().await.map_err(db_error)? {
            if q.mint_url.as_ref() == Some(&mint) && q.unit == UNIT && q.request == request {
                let view = self.withdrawal_value(&q).await?;
                if matches!(
                    view["payment_status"].as_str(),
                    Some("pending" | "completed" | "unknown" | "prepared")
                ) {
                    return Err(invalid(
                        "invoice already paid or awaiting CDK reconciliation",
                    ));
                }
            }
        }
        let quote = match timeout(
            self.network_deadline(),
            wallet.melt_quote(PaymentMethod::BOLT11, request, None, None),
        )
        .await
        {
            Ok(Ok(q)) => q,
            Ok(Err(e)) => return Err(map_prepare_error(&e)),
            Err(_) => {
                self.unresolved.insert(mint.clone());
                return Err(FfiErr::new(
                    CdkStatus::NetworkError,
                    "withdrawal quote exceeded deadline",
                ));
            }
        };
        if unix_now() != 0 {
            self.db
                .kv_write(
                    KV_NAMESPACE,
                    "quote_created_v1",
                    &Self::quote_key("Out", &mint.to_string(), &quote.id),
                    &unix_now().to_le_bytes(),
                )
                .await
                .map_err(db_error)?;
        }
        let prepared = match timeout(
            self.network_deadline(),
            wallet.prepare_melt(&quote.id, HashMap::new()),
        )
        .await
        {
            Ok(Ok(p)) => p,
            Ok(Err(e)) => {
                self.unresolved.insert(mint.clone());
                return Err(map_prepare_error(&e));
            }
            Err(_) => {
                self.unresolved.insert(mint.clone());
                return Err(FfiErr::new(
                    CdkStatus::NetworkError,
                    "withdrawal preparation exceeded deadline",
                ));
            }
        };
        let held = PreparedWithdrawal {
            wallet: wallet.clone(),
            operation_id: prepared.operation_id(),
            quote: prepared.quote().clone(),
            proofs: prepared.proofs().clone(),
            proofs_to_swap: prepared.proofs_to_swap().clone(),
            swap_fee: prepared.swap_fee(),
            input_fee: prepared.input_fee(),
            input_fee_without_swap: prepared.input_fee_without_swap(),
            metadata: prepared.metadata().clone(),
        };
        drop(prepared);
        self.prepared_withdrawal = Some(held);
        let result = self.prepared_withdrawal_value();
        if result.is_err() {
            let id = self
                .prepared_withdrawal
                .as_ref()
                .unwrap()
                .operation_id
                .to_string();
            if let Err(error) = self.cancel_withdrawal(&mint.to_string(), &id).await {
                // No review token reached the caller. Leave persisted CDK saga
                // recovery authoritative, not an inaccessible live handle.
                self.prepared_withdrawal.take();
                self.unresolved.insert(mint);
                return Err(error);
            }
        }
        result
    }

    fn prepared_withdrawal_value(&self) -> FfiResult<String> {
        let p = self
            .prepared_withdrawal
            .as_ref()
            .ok_or_else(|| invalid("no active review"))?;
        let q = &p.quote;
        identifier(&q.id, false)?;
        let total = q
            .amount
            .to_u64()
            .checked_add(q.fee_reserve.to_u64())
            .and_then(|v| v.checked_add(p.swap_fee.to_u64()))
            .and_then(|v| v.checked_add(p.input_fee.to_u64()))
            .ok_or_else(|| invalid("withdrawal estimate overflow"))?;
        bounded(
            json!({"operation_id":p.operation_id.to_string(),"quote_id":q.id,"mint_url":p.wallet.mint_url.to_string(),"invoice":q.request,"unit":"sat","amount":q.amount.to_u64().to_string(),"fee_reserve":q.fee_reserve.to_u64().to_string(),"swap_fee":p.swap_fee.to_u64().to_string(),"input_fee":p.input_fee.to_u64().to_string(),"estimated_total":total.to_string(),"quote_expiry":q.expiry.to_string(),"invoice_expiry":invoice_expiry(&q.request).map(|n| n.to_string()).ok_or_else(|| invalid("invalid prepared invoice"))?,"requires_swap":!p.proofs_to_swap.is_empty()}),
        )
    }

    fn review_token(&self, mint: &MintUrl, token: &str) -> FfiResult<()> {
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        let id = Uuid::parse_str(token).map_err(|_| invalid("invalid operation UUID"))?;
        if id.to_string() != token {
            return Err(invalid("invalid operation UUID"));
        }
        if !self
            .prepared_withdrawal
            .as_ref()
            .is_some_and(|p| p.operation_id == id && &p.wallet.mint_url == mint)
        {
            return Err(invalid("stale or wrong-mint review token"));
        }
        Ok(())
    }

    pub(crate) async fn cancel_withdrawal(&mut self, mint: &str, token: &str) -> FfiResult<String> {
        let mint = parse_mint_url(mint)?;
        self.review_token(&mint, token)?;
        let p = self.prepared_withdrawal.as_ref().unwrap();
        let result = timeout(
            self.network_deadline(),
            p.wallet.cancel_prepared_melt(
                p.operation_id,
                p.proofs.clone(),
                p.proofs_to_swap.clone(),
            ),
        )
        .await;
        match result {
            // Cancellation releases only this reservation. Other interrupted
            // CDK work (including an earlier cancellation timeout) still needs
            // normal recovery before mutations may proceed.
            Ok(Ok(())) => {
                let p = self.prepared_withdrawal.take().unwrap();
                bounded(json!({"quote_id":p.quote.id,"cancelled":true}))
            }
            other => {
                self.unresolved.insert(mint);
                Err(match other {
                    Ok(Err(e)) => map_prepare_error(&e),
                    _ => FfiErr::new(
                        CdkStatus::NetworkError,
                        "withdrawal cancellation exceeded deadline",
                    ),
                })
            }
        }
    }

    pub(crate) async fn confirm_withdrawal(
        &mut self,
        mint: &str,
        token: &str,
    ) -> FfiResult<String> {
        let selected = parse_mint_url(mint)?;
        self.review_token(&selected, token)?;
        // Acceptance consumes the review before even local preflight can fail.
        // Persisted CDK recovery, not an inaccessible owned handle, must remain
        // available after any error once the caller has submitted this token.
        let p = self.prepared_withdrawal.take().unwrap();
        let result = async {
            let stored = self
                .db
                .get_melt_quote(&p.quote.id)
                .await
                .map_err(db_error)?
                .ok_or_else(|| invalid("quote not found"))?;
            let now = unix_now();
            if (stored.expiry != 0 && stored.expiry <= now)
                || invoice_expiry(&p.quote.request).is_none_or(|t| t <= now)
            {
                match timeout(
                    self.network_deadline(),
                    p.wallet
                        .cancel_prepared_melt(p.operation_id, p.proofs, p.proofs_to_swap),
                )
                .await
                {
                    Ok(Ok(())) => return Err(invalid("withdrawal review expired")),
                    Ok(Err(e)) => return Err(map_prepare_error(&e)),
                    Err(_) => {
                        return Err(FfiErr::new(
                            CdkStatus::NetworkError,
                            "withdrawal cancellation exceeded deadline",
                        ))
                    }
                }
            }
            match timeout(
                self.network_deadline(),
                p.wallet.confirm_prepared_melt_prefer_async_with_options(
                    p.operation_id,
                    p.quote.clone(),
                    p.proofs,
                    p.proofs_to_swap,
                    p.input_fee,
                    p.input_fee_without_swap,
                    p.metadata,
                    MeltConfirmOptions::default(),
                ),
            )
            .await
            {
                Ok(Ok(outcome)) => {
                    drop(outcome);
                    self.saved_withdrawal(mint, &p.quote.id).await
                }
                other => Err(match other {
                    Ok(Err(e)) => map_prepare_error(&e),
                    _ => FfiErr::new(
                        CdkStatus::NetworkError,
                        "withdrawal confirmation exceeded deadline; reconcile before retrying",
                    ),
                }),
            }
        }
        .await;
        if result.is_err() {
            self.unresolved.insert(selected);
        }
        result
    }

    async fn local_withdrawal(&self, mint: &MintUrl, id: &str) -> FfiResult<MeltQuote> {
        if self.is_poisoned() {
            return Err(crate::api::poisoned_handle());
        }
        identifier(id, false)?;
        self.approved_wallet(mint).await?;
        let q = self
            .db
            .get_melt_quote(id)
            .await
            .map_err(db_error)?
            .ok_or_else(|| invalid("quote not found"))?;
        if q.mint_url.as_ref() != Some(mint)
            || q.unit != UNIT
            || q.payment_method != PaymentMethod::BOLT11
        {
            return Err(invalid("unsupported or cross-mint quote"));
        }
        Ok(q)
    }

    pub(crate) async fn saved_withdrawal(&self, mint: &str, id: &str) -> FfiResult<String> {
        let mint = parse_mint_url(mint)?;
        let q = self.local_withdrawal(&mint, id).await?;
        if q.request.len() > 4096 || q.request.contains('\0') {
            return Err(invalid(
                "saved withdrawal exceeds display limit; retained in wallet",
            ));
        }
        bounded(self.withdrawal_value(&q).await?)
    }

    pub(super) async fn withdrawal_value(&self, q: &MeltQuote) -> FfiResult<Value> {
        let sagas = self.db.get_incomplete_sagas().await.map_err(db_error)?;
        let transactions = self
            .db
            .list_transactions(None, None, None)
            .await
            .map_err(db_error)?;
        Ok(Self::project_withdrawal(
            q,
            &WithdrawalLookup::new(&sagas, &transactions),
            unix_now(),
        ))
    }

    pub(super) fn project_withdrawal(
        q: &MeltQuote,
        lookup: &WithdrawalLookup<'_>,
        now: u64,
    ) -> Value {
        let evidence = lookup.classify(q);
        let status = evidence.status.as_str();
        let expiry = invoice_expiry(&q.request);
        let expired = !matches!(status, "pending" | "completed" | "unknown")
            && ((q.expiry != 0 && q.expiry <= now) || expiry.is_some_and(|t| t <= now));
        let retry = matches!(status, "unsubmitted" | "failed")
            && !evidence.matching_saga
            && !evidence.pending_or_completed_tx
            && expiry.is_some_and(|t| t > now);
        // Legacy records may contain arbitrarily large requests. Never copy one
        // into a history/projection response; the history adapter marks it as a
        // retained, undisplayable row instead.
        json!({"quote_id":q.id,"mint_url":q.mint_url.as_ref().map(ToString::to_string),"invoice":if q.request.len() <= 4096 { Some(&q.request) } else { None },"unit":q.unit.to_string(),"amount":q.amount.to_u64().to_string(),"quote_state":q.state.to_string(),"payment_status":status,"quote_expiry":q.expiry.to_string(),"invoice_expiry":expiry.map(|n| n.to_string()),"expired":expired,"retry_review_allowed":retry})
    }

    pub(crate) async fn poll_withdrawals(&mut self, mint: &str, cursor: &str) -> FfiResult<String> {
        identifier(cursor, true)?;
        let selected = parse_mint_url(mint)?;
        self.guard_prepared_withdrawal(Some(&selected))?;
        let candidates: FfiResult<Vec<String>> = async {
            let sagas = self.db.get_incomplete_sagas().await.map_err(db_error)?;
            let transactions = self
                .db
                .list_transactions(None, None, None)
                .await
                .map_err(db_error)?;
            let mut candidates = Vec::new();
            let lookup = WithdrawalLookup::new(&sagas, &transactions);
            for q in self.db.get_melt_quotes().await.map_err(db_error)? {
                if q.mint_url.as_ref() == Some(&selected)
                    && q.unit == UNIT
                    && q.payment_method == PaymentMethod::BOLT11
                {
                    if lookup.classify(&q).poll_candidate(&q) {
                        candidates.push(q.id);
                    }
                }
            }
            Ok(candidates)
        }
        .await;
        let mut candidates = match candidates {
            Ok(candidates) => candidates,
            Err(e) => {
                return bounded(
                    json!({"cursor":cursor,"checked_id":null,"withdrawal":null,"wallet_changed":false,"recovery_pending":self.unresolved.contains(&selected),"error":{"status":e.status as u8,"message":"withdrawal local read failed; retry later"}}),
                )
            }
        };
        candidates.sort();
        let id = candidates
            .iter()
            .find(|id| id.as_str() > cursor)
            .or(candidates.first())
            .cloned();
        let mut error = Value::Null;
        let mut view = Value::Null;
        let mut wallet_changed = false;
        if let Some(id) = &id {
            let wallet = self.approved_wallet(&selected).await?;
            if self.unresolved.contains(&selected) {
                // Invalidation, not a financial record: even a failed CDK
                // attempt may have committed proofs, transactions or sagas.
                wallet_changed = true;
                if let Err(e) = self.run_recovery(Some(&selected)).await {
                    return bounded(
                        json!({"cursor":id,"checked_id":id,"withdrawal":null,"wallet_changed":wallet_changed,"recovery_pending":self.unresolved.contains(&selected),"error":{"status":e.status as u8,"message":"withdrawal recovery failed; retry later"}}),
                    );
                }
            }
            wallet_changed = true;
            let result = timeout(self.network_deadline(), wallet.check_melt_quote_status(id)).await;
            match result {
                Ok(Ok(_)) => {}
                other => {
                    self.unresolved.insert(selected.clone());
                    let status = match other {
                        Ok(Err(ref e)) => map_prepare_error(e).status,
                        _ => CdkStatus::NetworkError,
                    };
                    error = json!({"status":status as u8,"message":"withdrawal status check failed; retry later"});
                }
            }
            // CDK status checks may return an object older than their DB writes.
            match self.local_withdrawal(&selected, id).await {
                Ok(q) if q.request.len() > 4096 || q.request.contains('\0') => {
                    error = json!({"status":CdkStatus::InvalidArgument as u8,"message":"saved withdrawal exceeds display limit; retained in wallet"});
                }
                Ok(q) => match self.withdrawal_value(&q).await {
                    Ok(value) => view = value,
                    Err(e) => {
                        error = json!({"status":e.status as u8,"message":"withdrawal local read failed; retry later"})
                    }
                },
                Err(e) => {
                    error = json!({"status":e.status as u8,"message":"withdrawal local read failed; retry later"})
                }
            }
        }
        bounded(
            json!({"cursor":id.as_deref().unwrap_or(""),"checked_id":id,"withdrawal":view,"wallet_changed":wallet_changed,"recovery_pending":self.unresolved.contains(&selected),"error":error}),
        )
    }

    pub(crate) async fn cancel_withdrawal_on_close(&mut self) {
        if let Some(p) = &self.prepared_withdrawal {
            let mint = p.wallet.mint_url.to_string();
            let token = p.operation_id.to_string();
            let _ = self.cancel_withdrawal(&mint, &token).await;
        }
    }
}
