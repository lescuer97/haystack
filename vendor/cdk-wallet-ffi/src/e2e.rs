//! End-to-end tests against an in-process fake mint (no real money, no
//! external network).
//!
//! Every test spins up a `cdk` mint backed by the `FakeWallet` payment
//! processor on `127.0.0.1`, funds a wallet over the real HTTP protocol, and
//! then drives the wrapper. Several tests inject faults into the mint's HTTP
//! layer (malformed swap responses, stalled responses, failing proof-state
//! checks) to exercise the wrapper's fail-closed recovery semantics.

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::path::Path;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::Request;
use axum::middleware::{self, Next};
use axum::response::Response;
use cdk::amount::SplitTarget;
use cdk::mint::{MintBuilder, MintMeltLimits, UnitConfig};
use cdk::mint_url::MintUrl;
use cdk::nuts::nut00::token::TokenV3Token;
use cdk::nuts::nut00::KnownMethod;
use cdk::nuts::{CurrencyUnit, MintQuoteState, PaymentMethod, Token, TokenV3};
use cdk::types::{FeeReserve, QuoteTTL};
use cdk::wallet::{SendKind, SendOptions, Wallet, WalletRepositoryBuilder};
use cdk::Amount;
use cdk_axum::create_mint_router;
use cdk_fake_wallet::FakeWallet;
use cdk_sqlite::WalletSqliteDatabase;
use tokio::net::TcpListener;

use crate::status::CdkStatus;
use crate::wallet::{runtime, CdkWallet};

/// Drive a future on the process-wide runtime.
fn block_on<F: Future>(fut: F) -> F::Output {
    runtime().block_on(fut)
}

/// Fault to inject into the fake mint's HTTP layer.
#[derive(Clone)]
pub(crate) enum SwapFault {
    /// No fault injection.
    None,
    /// Return a malformed body for the *first* `/v1/swap` response (the mint
    /// still accepts and caches the swap).
    MalformedSwapOnce,
    /// Stall the *first* `/v1/swap` response for the given duration (the mint
    /// still accepts and caches the swap before stalling).
    StallSwapOnce(Duration),
    /// Return HTTP 500 for every `/v1/checkstate` request, so proof-state checks
    /// (used by recovery) fail deterministically without killing the server.
    FailCheckState,
    MalformedMintOnce,
    MalformedQuoteOnce,
    RejectQuoteOnce,
    StallQuoteOnce(Duration),
    UnpaidQuotes,
    WithdrawalControl { quotes: Arc<AtomicUsize>, posts: Arc<AtomicUsize>, gets: Arc<AtomicUsize>, hold_pending: Arc<AtomicBool>, fail_get: Arc<AtomicBool> },
    DepositControl { fail_get: Arc<AtomicBool>, fail_mint: Arc<AtomicBool>, hold_unpaid: Arc<AtomicBool>, gets: Arc<AtomicUsize>, interrupt_mint: bool },
}

/// Start a fake mint on a random loopback port and return its URL.
///
/// `input_fee_ppk` is applied to the msat keyset (1000 costs one msat per input).
pub(crate) async fn start_fake_mint(input_fee_ppk: u64) -> String {
    start_fake_mint_ctl(input_fee_ppk, SwapFault::None).await.0
}

/// Start a fake mint with fault injection, returning its URL and server handle.
pub(crate) async fn start_fake_mint_ctl(
    input_fee_ppk: u64,
    fault: SwapFault,
) -> (String, tokio::task::JoinHandle<()>) {
    let (url, handle, _) = start_fake_mint_counted(input_fee_ppk, fault).await;
    (url, handle)
}

pub(crate) async fn start_fake_mint_counted(
    input_fee_ppk: u64,
    fault: SwapFault,
) -> (String, tokio::task::JoinHandle<()>, Arc<AtomicUsize>) {
    let db = Arc::new(cdk_sqlite::mint::memory::empty().await.unwrap());
    let mut builder = MintBuilder::new(db.clone());
    builder
        .configure_unit(
            CurrencyUnit::Msat,
            UnitConfig {
                amounts: (0..32).map(|i| 2u64.pow(i)).collect(),
                input_fee_ppk,
            },
        )
        .unwrap();

    let fake = FakeWallet::new(
        FeeReserve {
            min_fee_reserve: 1.into(),
            percent_fee_reserve: 0.0,
        },
        HashMap::default(),
        HashSet::default(),
        0,
        CurrencyUnit::Msat,
    );
    builder
        .add_payment_processor(
            CurrencyUnit::Msat,
            PaymentMethod::Known(KnownMethod::Bolt11),
            MintMeltLimits::new(1, 10_000),
            Arc::new(fake),
        )
        .await
        .unwrap();

    let mint = builder.build_with_seed(db, &[7u8; 64]).await.unwrap();
    mint.set_quote_ttl(QuoteTTL::new(10_000, 10_000))
        .await
        .unwrap();
    mint.start().await.unwrap();

    let router = create_mint_router(Arc::new(mint), vec!["bolt11".to_string()])
        .await
        .unwrap();

    // Mutation-response faults run after processing/NUT-19 caching. The quote
    // rejection fault instead rejects before processing, proving a safe retry.
    let swap_seen = Arc::new(AtomicBool::new(false));
    let quote_posts = Arc::new(AtomicUsize::new(0));
    let counter = quote_posts.clone();
    let router = router.layer(middleware::from_fn(move |req: Request, next: Next| {
        let fault = fault.clone();
        let swap_seen = swap_seen.clone();
        let counter = counter.clone();
        async move {
            let path = req.uri().path().to_owned();
            let withdrawal_get = path.starts_with("/v1/melt/quote/bolt11/") && req.method() == axum::http::Method::GET;
            let withdrawal_post = path == "/v1/melt/bolt11" && req.method() == axum::http::Method::POST;
            if let SwapFault::WithdrawalControl { quotes, posts, gets, fail_get, .. } = &fault {
                if path == "/v1/melt/quote/bolt11" && req.method() == axum::http::Method::POST { quotes.fetch_add(1, Ordering::SeqCst); }
                if withdrawal_post { posts.fetch_add(1, Ordering::SeqCst); }
                if withdrawal_get {
                    gets.fetch_add(1, Ordering::SeqCst);
                    if fail_get.load(Ordering::SeqCst) { return Response::builder().status(500).body(Body::from("injected melt status failure")).unwrap(); }
                }
            }
            let is_swap = path.ends_with("/swap");
            let is_checkstate = path.ends_with("/checkstate");
            let is_mint = path == "/v1/mint/bolt11";
            if is_mint || path.ends_with("/restore") {
                if let SwapFault::DepositControl { fail_mint, .. } = &fault {
                    if fail_mint.load(Ordering::SeqCst) {
                        return Response::builder().status(500).body(Body::from("injected mint recovery failure")).unwrap();
                    }
                }
            }
            let is_quote_get = path.starts_with("/v1/mint/quote/bolt11/") && req.method() == axum::http::Method::GET;
            if path.starts_with("/v1/mint/quote/bolt11/") && req.method() == axum::http::Method::GET {
                if let SwapFault::DepositControl { fail_get, gets, interrupt_mint, .. } = &fault {
                    if !interrupt_mint || path.ends_with("/B") { gets.fetch_add(1, Ordering::SeqCst); }
                    if fail_get.load(Ordering::SeqCst) {
                        return Response::builder().status(500).body(Body::from("injected quote GET failure")).unwrap();
                    }
                }
            }
            let is_quote =
                path == "/v1/mint/quote/bolt11" && req.method() == axum::http::Method::POST;
            if is_quote {
                counter.fetch_add(1, Ordering::SeqCst);
                match fault {
                    SwapFault::RejectQuoteOnce if !swap_seen.swap(true, Ordering::SeqCst) => {
                        return Response::builder()
                            .status(400)
                            .header("content-type", "application/json")
                            .body(Body::from(
                                r#"{"code":20003,"detail":"injected definitive rejection"}"#,
                            ))
                            .unwrap()
                    }
                    SwapFault::StallQuoteOnce(delay) if !swap_seen.swap(true, Ordering::SeqCst) => {
                        tokio::time::sleep(delay).await
                    }
                    _ => {}
                }
            }
            let response = next.run(req).await;
            if let SwapFault::WithdrawalControl { hold_pending, .. } = &fault {
                if hold_pending.load(Ordering::SeqCst) && (withdrawal_get || withdrawal_post) {
                    let (mut parts, body) = response.into_parts();
                    let bytes = axum::body::to_bytes(body, 65536).await.unwrap();
                    let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                    if value.get("state").is_some() {
                        value["state"] = "PENDING".into();
                        value["payment_preimage"] = serde_json::Value::Null;
                        value["change"] = serde_json::Value::Null;
                    }
                    parts.headers.remove(axum::http::header::CONTENT_LENGTH);
                    return Response::from_parts(parts, Body::from(value.to_string()));
                }
            }
            let force_unpaid = matches!(&fault, SwapFault::UnpaidQuotes) || matches!(&fault, SwapFault::DepositControl { hold_unpaid, .. } if hold_unpaid.load(Ordering::SeqCst));
            if force_unpaid && (is_quote_get || is_quote) {
                let (parts, body) = response.into_parts();
                let bytes = axum::body::to_bytes(body, 65536).await.unwrap();
                let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                value["state"] = serde_json::json!("UNPAID");
                value["amount_paid"] = serde_json::json!(0);
                value["amount_issued"] = serde_json::json!(0);
                let mut response = Response::from_parts(parts, Body::from(value.to_string()));
                response.headers_mut().remove(axum::http::header::CONTENT_LENGTH);
                return response;
            }
            match fault {
                SwapFault::DepositControl { interrupt_mint: true, .. } if is_mint && !swap_seen.swap(true, Ordering::SeqCst) => {
                    Response::builder().status(200).body(Body::from("invalid mint response")).unwrap()
                }
                SwapFault::None => response,
                SwapFault::MalformedMintOnce
                    if is_mint && !swap_seen.swap(true, Ordering::SeqCst) =>
                {
                    Response::builder()
                        .status(200)
                        .body(Body::from("invalid mint response"))
                        .unwrap()
                }
                SwapFault::MalformedQuoteOnce
                    if is_quote && !swap_seen.swap(true, Ordering::SeqCst) =>
                {
                    Response::builder()
                        .status(200)
                        .body(Body::from("invalid quote response"))
                        .unwrap()
                }
                SwapFault::MalformedSwapOnce
                    if is_swap && !swap_seen.swap(true, Ordering::SeqCst) =>
                {
                    Response::builder()
                        .status(200)
                        .body(Body::from("not-a-valid-swap-response"))
                        .unwrap()
                }
                SwapFault::StallSwapOnce(delay)
                    if is_swap && !swap_seen.swap(true, Ordering::SeqCst) =>
                {
                    tokio::time::sleep(delay).await;
                    response
                }
                SwapFault::FailCheckState if is_checkstate => Response::builder()
                    .status(500)
                    .body(Body::from("checkstate unavailable"))
                    .unwrap(),
                _ => response,
            }
        }
    }));

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let handle = runtime().spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    (format!("http://{addr}"), handle, quote_posts)
}

/// Open a [`WalletRepository`](cdk::wallet::WalletRepository) over `db_path`.
async fn open_repo(db_path: &Path, seed: [u8; 64]) -> cdk::wallet::WalletRepository {
    let db = Arc::new(
        WalletSqliteDatabase::new(db_path.to_path_buf())
            .await
            .unwrap(),
    );
    WalletRepositoryBuilder::new()
        .localstore(db)
        .seed(seed)
        .build()
        .await
        .unwrap()
}

/// Fund a wallet at `mint_url` by minting `amount` msats through the fake mint.
///
/// The returned [`Wallet`] shares the database at `db_path` with the wrapper
/// handle, so the minted proofs are visible to the wrapper.
pub(crate) async fn fund_wallet(
    db_path: &Path,
    seed: [u8; 64],
    mint_url: &str,
    amount: u64,
    split: SplitTarget,
) -> Wallet {
    let repo = open_repo(db_path, seed).await;
    let wallet = repo
        .get_or_create_wallet(
            MintUrl::from_str(mint_url).unwrap(),
            CurrencyUnit::Msat,
            None,
        )
        .await
        .unwrap();

    let quote = wallet
        .mint_quote(
            PaymentMethod::Known(KnownMethod::Bolt11),
            Some(Amount::from(amount)),
            None,
            None,
        )
        .await
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let status = wallet.check_mint_quote(&quote.id).await.unwrap();
        if status.state == MintQuoteState::Paid {
            break;
        }
        assert!(Instant::now() < deadline, "mint quote was never paid");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    wallet.mint(&quote.id, split, None).await.unwrap();
    wallet
}

/// Create a token of `amount` msats from an already-funded database, using a
/// `SendKind::OnlineExact` send (same shape as the wrapper's own `send`).
async fn make_token(db_path: &Path, seed: [u8; 64], mint_url: &str, amount: u64) -> String {
    let repo = open_repo(db_path, seed).await;
    let wallet = repo
        .get_or_create_wallet(
            MintUrl::from_str(mint_url).unwrap(),
            CurrencyUnit::Msat,
            None,
        )
        .await
        .unwrap();
    let opts = SendOptions {
        send_kind: SendKind::OnlineExact,
        include_fee: false,
        ..SendOptions::default()
    };
    let prepared = wallet
        .prepare_send(Amount::from(amount), opts)
        .await
        .unwrap();
    prepared.confirm(None).await.unwrap().to_string()
}

/// Open a wrapper handle over `db_path`, asserting success.
fn open_wallet(seed: [u8; 64], db_path: impl AsRef<Path>) -> CdkWallet {
    let (handle, _reports) =
        block_on(CdkWallet::open(&seed, db_path.as_ref().to_str().unwrap())).unwrap();
    handle
}

fn temp_db() -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("wallet.sqlite");
    (dir, path)
}

#[test]
fn e2e_seed_restore_funds_and_spend() {
    let mint_url = block_on(start_fake_mint(0));
    let seed = [55u8; 64];
    let (_original_dir, original_path) = temp_db();
    let (_restored_dir, restored_path) = temp_db();
    let (_other_dir, other_path) = temp_db();

    let funding = block_on(fund_wallet(
        &original_path,
        seed,
        &mint_url,
        1000,
        SplitTarget::default(),
    ));
    drop(funding);

    let mut restored = open_wallet(seed, &restored_path);
    let result = crate::api::cdk_wallet_restore_seed(
        Some(&mut restored),
        Some(cstr_ref(&with_nul(&mint_url))),
    );
    let error = result.error.as_ref().map(|e| e.to_str().to_owned());
    crate::api::cdk_string_free(result.error);
    assert_eq!(result.status, CdkStatus::Ok, "restore failed: {error:?}");
    assert_eq!(result.incomplete, 0);
    assert_eq!(result.unspent_msats, 1000);
    let balances = block_on(restored.list_balances()).unwrap();
    assert_eq!(balances.len(), 1);
    assert_eq!(balances[0], (mint_url.clone(), 1000));

    // A different seed scanning the same mint cannot recover these proofs.
    let mut other = open_wallet([56u8; 64], &other_path);
    let other_result =
        crate::api::cdk_wallet_restore_seed(Some(&mut other), Some(cstr_ref(&with_nul(&mint_url))));
    let error = other_result.error.as_ref().map(|e| e.to_str().to_owned());
    crate::api::cdk_string_free(other_result.error);
    assert_eq!(
        other_result.status,
        CdkStatus::Ok,
        "restore failed: {error:?}"
    );
    assert_eq!(other_result.incomplete, 0);
    assert_eq!(other_result.unspent_msats, 0);

    let outcome = block_on(restored.send(&mint_url, 100, 1000)).unwrap();
    assert!(!outcome.token.is_empty());
    assert_eq!(outcome.sender_fee_msats, 0);
    assert_eq!(block_on(restored.list_balances()).unwrap()[0].1, 900);
    drop(restored);

    let mut reopened = open_wallet(seed, &restored_path);
    assert_eq!(block_on(reopened.list_balances()).unwrap()[0].1, 900);
    let onward = block_on(reopened.send(&mint_url, 100, 1000)).unwrap();
    assert!(!onward.token.is_empty());
}

#[test]
fn e2e_send_receive_roundtrip() {
    let mint_url = block_on(start_fake_mint(0));
    let (_dir_a, path_a) = temp_db();
    let (_dir_b, path_b) = temp_db();

    let mut a = open_wallet([11u8; 64], &path_a);
    block_on(a.add_mint(&mint_url)).unwrap();

    // Fund the wrapper's database with 1000 msats through a second connection.
    block_on(fund_wallet(
        &path_a,
        [11u8; 64],
        &mint_url,
        1000,
        SplitTarget::default(),
    ));

    let balances = block_on(a.list_balances()).unwrap();
    assert_eq!(balances.len(), 1);
    assert_eq!(balances[0].0, mint_url);
    assert_eq!(balances[0].1, 1000);

    // Send 100 msats, allowing a generous fee. With a zero-fee mint the sender
    // fee is zero and the recipient receives the full face value.
    let outcome = block_on(a.send(&mint_url, 100, 1000)).unwrap();
    assert_eq!(outcome.sender_fee_msats, 0);

    // Receive into a second, independent wrapper wallet.
    let mut b = open_wallet([22u8; 64], &path_b);
    block_on(b.add_mint(&mint_url)).unwrap();
    let net = block_on(b.receive(&outcome.token)).unwrap();
    assert_eq!(net, 100);

    // The receiver can now spend it.
    let balances_b = block_on(b.list_balances()).unwrap();
    assert_eq!(balances_b[0].1, 100);
}

#[test]
fn e2e_fee_limit_cancels_and_preserves_balance() {
    let mint_url = block_on(start_fake_mint(1000));
    let (_dir, path) = temp_db();

    let mut handle = open_wallet([33u8; 64], &path);
    block_on(handle.add_mint(&mint_url)).unwrap();
    // A single 512-msat proof: sending 300 must swap it, which costs one input
    // fee (one msat at ppk = 1000), so a zero ceiling must cancel the send.
    block_on(fund_wallet(
        &path,
        [33u8; 64],
        &mint_url,
        512,
        SplitTarget::Values(vec![Amount::from(512u64)]),
    ));

    let err = block_on(handle.send(&mint_url, 300, 0)).unwrap_err();
    assert_eq!(err.status, CdkStatus::FeeLimitExceeded);
    assert!(err.operation_id.is_some(), "cancelled send keeps its op id");
    assert!(
        err.sender_fee_msats >= 1,
        "the reported fee should be non-zero"
    );

    // The cancelled send released its proofs: the balance is intact.
    let balances = block_on(handle.list_balances()).unwrap();
    assert_eq!(balances[0].1, 512);
}

#[test]
fn e2e_prize_stock_mints_two_compact_offline_payouts() {
    let mint_url = block_on(start_fake_mint(0));
    let (_dir, path) = temp_db();
    let seed = [37u8; 64];
    let mut handle = open_wallet(seed, &path);
    block_on(handle.add_mint(&mint_url)).unwrap();
    let invalid = block_on(handle.create_prize_stock(&mint_url, "21", "500")).unwrap_err();
    assert_eq!(invalid.status, CdkStatus::InvalidArgument);

    let raw = block_on(handle.create_prize_stock(&mint_url, "2", "500")).unwrap();
    let invoice: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let id = invoice["id"].as_str().unwrap();
    // Like the operator commands, creation and claim run on different opens.
    drop(handle);
    let mut handle = open_wallet(seed, &path);
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let raw = block_on(handle.claim_prize_stock(&mint_url, id, "500")).unwrap();
        let status: serde_json::Value = serde_json::from_str(&raw).unwrap();
        if status["confirmed"] == true {
            break;
        }
        assert!(Instant::now() < deadline, "prize funding did not confirm");
        std::thread::sleep(Duration::from_millis(50));
    }

    for _ in 0..2 {
        let payout = block_on(handle.send_bounded(&mint_url, 500, 4096)).unwrap();
        assert_eq!(payout.sender_fee_msats, 0);
        assert!(payout.token.len() <= 4096);
        let token = Token::from_str(&payout.token).unwrap();
        assert_eq!(token.value().unwrap(), Amount::from(500));
        assert_eq!(token.unit(), Some(CurrencyUnit::Msat));
        assert_eq!(token.token_secrets().len(), 6);
    }
    let err = block_on(handle.send_bounded(&mint_url, 500, 4096)).unwrap_err();
    assert_eq!(err.status, CdkStatus::InsufficientFunds);
}

#[test]
fn e2e_bounded_send_requires_exact_proofs_and_checks_size_before_issuance() {
    let mint_url = block_on(start_fake_mint(0));
    let (_dir, path) = temp_db();
    let seed = [34u8; 64];
    let mut handle = open_wallet(seed, &path);
    block_on(handle.add_mint(&mint_url)).unwrap();
    let wallet = block_on(fund_wallet(
        &path,
        seed,
        &mint_url,
        512,
        SplitTarget::Values(vec![Amount::from(512u64)]),
    ));

    // A generic zero-fee send could swap the single 512-msat proof for 300;
    // the bounded send must refuse instead, even with ample token space.
    let err = block_on(handle.send_bounded(&mint_url, 300, 4096)).unwrap_err();
    assert_eq!(err.status, CdkStatus::InsufficientFunds);
    assert!(block_on(handle.list_pending_tokens()).unwrap().is_empty());

    let expected = block_on(async {
        let prepared = wallet
            .prepare_send(
                Amount::from(512u64),
                SendOptions {
                    send_kind: SendKind::OfflineExact,
                    ..SendOptions::default()
                },
            )
            .await
            .unwrap();
        let token = Token::new(
            wallet.mint_url.clone(),
            prepared.proofs_to_send().clone(),
            None,
            wallet.unit.clone(),
        )
        .to_string();
        prepared.cancel().await.unwrap();
        token
    });

    let err = block_on(handle.send_bounded(&mint_url, 512, expected.len() - 1)).unwrap_err();
    assert_eq!(err.status, CdkStatus::SendFailed);
    assert!(err.operation_id.is_some());
    assert!(block_on(handle.list_pending_tokens()).unwrap().is_empty());
    assert_eq!(block_on(handle.list_balances()).unwrap()[0].1, 512);

    let outcome = block_on(handle.send_bounded(&mint_url, 512, expected.len())).unwrap();
    assert_eq!(outcome.sender_fee_msats, 0);
    assert_eq!(outcome.token, expected);
    let pending = block_on(handle.get_pending_token(&outcome.operation_id)).unwrap();
    assert_eq!(pending.token, expected);
}

#[test]
fn e2e_bounded_send_cancellation_failure_requires_recovery() {
    let mint_url = block_on(start_fake_mint(0));
    let (_dir, path) = temp_db();
    let seed = [35u8; 64];
    let mut handle = open_wallet(seed, &path);
    block_on(handle.add_mint(&mint_url)).unwrap();
    block_on(fund_wallet(&path, seed, &mint_url, 512, SplitTarget::None));

    // Reserve normally, but fail when cancellation tries to release the proof.
    rusqlite::Connection::open(&path)
        .unwrap()
        .execute_batch(
            "CREATE TRIGGER fail_release BEFORE UPDATE OF state ON proof
             WHEN OLD.state = 'RESERVED' AND NEW.state = 'UNSPENT'
             BEGIN SELECT RAISE(FAIL, 'injected cancellation failure'); END;",
        )
        .unwrap();
    let err = block_on(handle.send_bounded(&mint_url, 512, 1)).unwrap_err();
    assert_eq!(err.status, CdkStatus::CancellationFailed);
    assert!(err.operation_id.is_some());
    assert!(block_on(handle.list_pending_tokens()).unwrap().is_empty());
    let err = block_on(handle.send_bounded(&mint_url, 512, 4096)).unwrap_err();
    assert_eq!(err.status, CdkStatus::RecoveryPending);
}

#[test]
fn e2e_pending_token_is_retrievable() {
    let mint_url = block_on(start_fake_mint(1000));
    let (_dir, path) = temp_db();

    let mut handle = open_wallet([44u8; 64], &path);
    block_on(handle.add_mint(&mint_url)).unwrap();
    block_on(fund_wallet(
        &path,
        [44u8; 64],
        &mint_url,
        1000,
        SplitTarget::default(),
    ));

    let outcome = block_on(handle.send(&mint_url, 100, 1000)).unwrap();

    let pending = block_on(handle.list_pending_tokens()).unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].operation_id, outcome.operation_id);

    let token = block_on(handle.get_pending_token(&outcome.operation_id)).unwrap();
    assert_eq!(token.token, outcome.token);

    // An unknown operation id is reported, not a panic.
    let err = block_on(handle.get_pending_token(&[0u8; 16])).unwrap_err();
    assert_eq!(err.status, CdkStatus::OperationNotFound);

    // A wrong-length id is rejected.
    let err = block_on(handle.get_pending_token(&[0u8; 4])).unwrap_err();
    assert_eq!(err.status, CdkStatus::InvalidArgument);
}

#[test]
fn e2e_unknown_mint_token_rejected_before_network() {
    let mint_url = block_on(start_fake_mint(1000));
    let (_dir, path) = temp_db();

    let mut handle = open_wallet([55u8; 64], &path);
    block_on(handle.add_mint(&mint_url)).unwrap();
    let funding = block_on(fund_wallet(
        &path,
        [55u8; 64],
        &mint_url,
        1000,
        SplitTarget::default(),
    ));
    let proofs = block_on(funding.get_unspent_proofs()).unwrap();

    // A token naming an unapproved, unreachable mint must be rejected locally,
    // i.e. `TokenUnknownMint` rather than a network error.
    let unknown = TokenV3::new(
        MintUrl::from_str("http://127.0.0.1:1").unwrap(),
        proofs.clone(),
        None,
        Some(CurrencyUnit::Msat),
    )
    .unwrap();
    let err = block_on(handle.receive(&unknown.to_string())).unwrap_err();
    assert_eq!(err.status, CdkStatus::TokenUnknownMint);
}

#[test]
fn e2e_multi_mint_and_wrong_unit_tokens_rejected() {
    let mint_url = block_on(start_fake_mint(1000));
    let (_dir, path) = temp_db();

    let mut handle = open_wallet([66u8; 64], &path);
    block_on(handle.add_mint(&mint_url)).unwrap();
    let funding = block_on(fund_wallet(
        &path,
        [66u8; 64],
        &mint_url,
        1000,
        SplitTarget::default(),
    ));
    let proofs = block_on(funding.get_unspent_proofs()).unwrap();

    let a = MintUrl::from_str(&mint_url).unwrap();
    let b = MintUrl::from_str("http://127.0.0.1:1").unwrap();

    let multi = TokenV3 {
        token: vec![
            TokenV3Token::new(a.clone(), proofs.clone()),
            TokenV3Token::new(b, proofs.clone()),
        ],
        memo: None,
        unit: Some(CurrencyUnit::Msat),
    };
    let err = block_on(handle.receive(&multi.to_string())).unwrap_err();
    assert_eq!(err.status, CdkStatus::UnsupportedToken);

    for unit in [Some(CurrencyUnit::Sat), None] {
        let wrong_unit = TokenV3::new(a.clone(), proofs.clone(), None, unit).unwrap();
        let err = block_on(handle.receive(&wrong_unit.to_string())).unwrap_err();
        assert_eq!(err.status, CdkStatus::UnsupportedToken);
    }
}

#[test]
fn mint_check_requires_a_live_active_msat_keyset() {
    block_on(async {
        use axum::{routing::get, Json, Router};
        use serde_json::json;

        let active_msat = Arc::new(AtomicBool::new(false));
        let mint_state = active_msat.clone();
        let app = Router::new().route("/v1/keysets", get(move || {
            let active = mint_state.load(Ordering::SeqCst);
            async move {
                Json(json!({"keysets": [
                    {"id":"0085070c8d13121a", "unit":"sat", "active":true},
                    {"id":"009a1f293253e41e", "unit":"msat", "active":active}
                ]}))
            }
        }));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mint = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let err = crate::wallet::check_mint_keysets(&mint).await.unwrap_err();
        assert_eq!(err.status, CdkStatus::MintUnsupportedUnit);
        active_msat.store(true, Ordering::SeqCst);
        crate::wallet::check_mint_keysets(&mint).await.unwrap();
        active_msat.store(false, Ordering::SeqCst);
        assert_eq!(crate::wallet::check_mint_keysets(&mint).await.unwrap_err().status, CdkStatus::MintUnsupportedUnit);
        server.abort();
    });
}

#[test]
fn e2e_two_mints_persist_across_reopen() {
    let mint_a = block_on(start_fake_mint(1000));
    let mint_b = block_on(start_fake_mint(0));
    let (_dir, path) = temp_db();

    let mut handle = open_wallet([77u8; 64], &path);
    block_on(handle.add_mint(&mint_a)).unwrap();
    block_on(handle.add_mint(&mint_b)).unwrap();
    // Adding an approved mint again is a local no-op.
    block_on(handle.add_mint(&mint_a)).unwrap();
    drop(handle);

    let mut reopened = open_wallet([77u8; 64], &path);
    let mut mints = block_on(reopened.list_mints());
    mints.sort();
    let mut expected = vec![mint_a, mint_b];
    expected.sort();
    assert_eq!(mints, expected);

    // Unknown mints are rejected without network access.
    let err = block_on(reopened.send("http://127.0.0.1:1", 1, 0)).unwrap_err();
    assert_eq!(err.status, CdkStatus::MintNotRegistered);
}

#[test]
fn e2e_recovery_runs_clean() {
    let mint_url = block_on(start_fake_mint(1000));
    let (_dir, path) = temp_db();

    let mut handle = open_wallet([88u8; 64], &path);
    block_on(handle.add_mint(&mint_url)).unwrap();

    let reports = block_on(handle.recover(None)).unwrap();
    assert!(reports.iter().all(|r| r.failed == 0 && r.skipped == 0));
    assert_eq!(reports.len(), 1);
    assert_eq!(reports[0].mint_url, mint_url);

    // Recovering a single mint by URL also works.
    let mint = cdk::mint_url::MintUrl::from_str(&mint_url).unwrap();
    let reports = block_on(handle.recover(Some(&mint))).unwrap();
    assert!(reports.iter().all(|r| r.failed == 0));
}

// ---------------------------------------------------------------------------
// Test 1: pending outgoing token survives a crash/reopen and is redeemable.
// ---------------------------------------------------------------------------

#[test]
fn e2e_pending_token_survives_reopen_and_is_redeemable() {
    let mint_url = block_on(start_fake_mint(0));
    let (_dir_a, path_a) = temp_db();
    let (_dir_b, path_b) = temp_db();
    let path_a_str = path_a.to_str().unwrap().to_string();

    let mut a = open_wallet([101u8; 64], &path_a);
    block_on(a.add_mint(&mint_url)).unwrap();
    block_on(fund_wallet(
        &path_a,
        [101u8; 64],
        &mint_url,
        1000,
        SplitTarget::default(),
    ));

    let outcome = block_on(a.send(&mint_url, 100, 1000)).unwrap();

    // Simulate a crash: drop the handle without cleaning up.
    drop(a);

    // Reopen the exact same database + seed; startup recovery runs.
    let (reopened, reports) = block_on(CdkWallet::open(&[101u8; 64], &path_a_str)).unwrap();
    assert!(reports.iter().all(|r| r.failed == 0 && r.skipped == 0));

    // The pending token is still retrievable with the same operation id.
    let token = block_on(reopened.get_pending_token(&outcome.operation_id)).unwrap();
    assert_eq!(token.token, outcome.token);
    assert_eq!(token.operation_id, outcome.operation_id);

    // An independent wallet redeems it; the net credited is the face value.
    let mut b = open_wallet([102u8; 64], &path_b);
    block_on(b.add_mint(&mint_url)).unwrap();
    let net = block_on(b.receive(&outcome.token)).unwrap();
    assert_eq!(net, 100);
    assert_eq!(block_on(b.list_balances()).unwrap()[0].1, 100);
}

// ---------------------------------------------------------------------------
// Test 2: interrupted receive (mint accepted the swap, bad response) gates the
// mint; explicit recovery credits the funds exactly once.
// ---------------------------------------------------------------------------

#[test]
fn e2e_interrupted_receive_gates_mint_and_recovers() {
    let (mint_url, _server) = block_on(start_fake_mint_ctl(0, SwapFault::MalformedSwapOnce));
    let (_dir_w, path_w) = temp_db();
    let (_dir, path) = temp_db();

    // A token from an independent wallet at the same mint.
    block_on(fund_wallet(
        &path_w,
        [91u8; 64],
        &mint_url,
        1000,
        SplitTarget::default(),
    ));
    let token = block_on(make_token(&path_w, [91u8; 64], &mint_url, 100));

    let mut handle = open_wallet([92u8; 64], &path);
    block_on(handle.add_mint(&mint_url)).unwrap();

    // The mint accepts the swap, but the client never sees a valid response.
    let err = block_on(handle.receive(&token)).unwrap_err();
    assert_ne!(err.status, CdkStatus::Ok);

    // The mint is now fail-closed for mutations, and the pending token is still
    // readable.
    let send_err = block_on(handle.send(&mint_url, 1, 1000)).unwrap_err();
    assert_eq!(send_err.status, CdkStatus::RecoveryPending);
    let recv_err = block_on(handle.receive(&token)).unwrap_err();
    assert_eq!(recv_err.status, CdkStatus::RecoveryPending);
    assert_eq!(block_on(handle.list_balances()).unwrap()[0].1, 0);

    // Explicit recovery replays the swap (NUT-19 cache) and credits the funds.
    let reports = block_on(handle.recover(None)).unwrap();
    assert!(
        reports.iter().all(|r| r.failed == 0 && r.skipped == 0),
        "unexpected recovery outcome: {reports:?}"
    );
    assert!(
        reports.iter().any(|r| r.recovered >= 1),
        "the receive saga should have been recovered"
    );

    // Net credited exactly once.
    let balances = block_on(handle.list_balances()).unwrap();
    assert_eq!(balances[0].1, 100, "recovered net credited exactly once");

    // The mint is usable again.
    let outcome = block_on(handle.send(&mint_url, 100, 1000)).unwrap();
    assert!(!outcome.token.is_empty());
}

// ---------------------------------------------------------------------------
// Test 2b: a network timeout during receive is also treated as uncertain.
// ---------------------------------------------------------------------------

#[test]
fn e2e_receive_timeout_gates_mint_and_recovers() {
    let (mint_url, _server) = block_on(start_fake_mint_ctl(
        0,
        SwapFault::StallSwapOnce(Duration::from_secs(3)),
    ));
    let (_dir_w, path_w) = temp_db();
    let (_dir, path) = temp_db();

    block_on(fund_wallet(
        &path_w,
        [93u8; 64],
        &mint_url,
        1000,
        SplitTarget::default(),
    ));
    let token = block_on(make_token(&path_w, [93u8; 64], &mint_url, 100));

    let mut handle = open_wallet([94u8; 64], &path);
    block_on(handle.add_mint(&mint_url)).unwrap();
    // Small network deadline so the stalled swap times out quickly.
    handle.set_test_deadlines(Duration::from_millis(200), Duration::from_secs(30));

    let err = block_on(handle.receive(&token)).unwrap_err();
    assert_eq!(err.status, CdkStatus::NetworkError);

    // Fail-closed after an uncertain timeout.
    let send_err = block_on(handle.send(&mint_url, 1, 1000)).unwrap_err();
    assert_eq!(send_err.status, CdkStatus::RecoveryPending);

    // Recovery replays the cached swap and credits the funds.
    let reports = block_on(handle.recover(None)).unwrap();
    assert!(reports.iter().all(|r| r.failed == 0), "{reports:?}");
    assert_eq!(block_on(handle.list_balances()).unwrap()[0].1, 100);
}

// ---------------------------------------------------------------------------
// Test 3: an interrupted prepare is compensated on reopen.
// ---------------------------------------------------------------------------

#[test]
fn e2e_interrupted_prepare_is_compensated_on_reopen() {
    let mint_url = block_on(start_fake_mint(1000));
    let (_dir, path) = temp_db();
    let path_str = path.to_str().unwrap().to_string();

    let mut handle = open_wallet([95u8; 64], &path);
    block_on(handle.add_mint(&mint_url)).unwrap();
    block_on(fund_wallet(
        &path,
        [95u8; 64],
        &mint_url,
        1000,
        SplitTarget::default(),
    ));
    assert_eq!(block_on(handle.list_balances()).unwrap()[0].1, 1000);

    // Prepare a send and drop it: the saga and its reserved proofs survive,
    // exactly like a crash between prepare and confirm.
    block_on(handle.test_interrupt_prepare(&mint_url, 100)).unwrap();
    assert!(
        block_on(handle.list_balances()).unwrap()[0].1 < 1000,
        "prepared proofs are reserved"
    );

    // Reopening runs startup recovery, which compensates the reserved send and
    // releases the proofs.
    drop(handle);
    let reopened = open_wallet([95u8; 64], &path_str);
    assert_eq!(
        block_on(reopened.list_balances()).unwrap()[0].1,
        1000,
        "compensated send releases its reserved proofs"
    );
    assert!(block_on(reopened.list_pending_tokens()).unwrap().is_empty());
}

// ---------------------------------------------------------------------------
// Test 4: a fee-charging receive nets less than the token face value.
// ---------------------------------------------------------------------------

#[test]
fn e2e_fee_charging_receive_nets_less_than_face() {
    // 1 msat of input fee per proof.
    let mint_url = block_on(start_fake_mint(1000));
    let (_dir_w, path_w) = temp_db();
    let (_dir, path) = temp_db();

    block_on(fund_wallet(
        &path_w,
        [96u8; 64],
        &mint_url,
        1000,
        SplitTarget::default(),
    ));
    let token = block_on(make_token(&path_w, [96u8; 64], &mint_url, 100));

    // Count the proofs in the token; the receiver pays one msat per proof.
    let parsed = Token::from_str(&token).unwrap();
    let proof_count: u64 = match &parsed {
        Token::TokenV3(v3) => v3.token.iter().map(|t| t.proofs.len() as u64).sum(),
        Token::TokenV4(v4) => v4.token.iter().map(|t| t.proofs.len() as u64).sum(),
    };
    assert!(proof_count > 0);

    let mut handle = open_wallet([97u8; 64], &path);
    block_on(handle.add_mint(&mint_url)).unwrap();
    let net = block_on(handle.receive(&token)).unwrap();

    assert!(
        net < 100,
        "a fee-charging receive nets less than face value"
    );
    assert_eq!(net, 100 - proof_count, "net equals face minus input fee");
    assert_eq!(block_on(handle.list_balances()).unwrap()[0].1, net);
}

// ---------------------------------------------------------------------------
// Test 5: per-mint recovery reports isolate a failing mint from a healthy one.
// ---------------------------------------------------------------------------

#[test]
fn e2e_two_mint_recovery_reports_isolate_failure() {
    let mint_a = block_on(start_fake_mint(0));
    let (mint_b, _server_b) = block_on(start_fake_mint_ctl(0, SwapFault::FailCheckState));
    let (_dir, path) = temp_db();
    let path_str = path.to_str().unwrap().to_string();

    let mut handle = open_wallet([111u8; 64], &path);
    block_on(handle.add_mint(&mint_a)).unwrap();
    block_on(handle.add_mint(&mint_b)).unwrap();
    block_on(fund_wallet(
        &path,
        [111u8; 64],
        &mint_a,
        1000,
        SplitTarget::default(),
    ));
    block_on(fund_wallet(
        &path,
        [111u8; 64],
        &mint_b,
        1000,
        SplitTarget::default(),
    ));

    // Leave an unresolved send saga on B (its proofs can only be checked over
    // the network, which we make fail).
    let b_outcome = block_on(handle.send(&mint_b, 100, 1000)).unwrap();
    assert!(!b_outcome.token.is_empty());

    // Recovery: A is clean, B fails its proof-state check.
    let reports = block_on(handle.recover(None)).unwrap();
    assert_eq!(reports.len(), 2, "one report per approved mint");
    let report_a = reports.iter().find(|r| r.mint_url == mint_a).unwrap();
    let report_b = reports.iter().find(|r| r.mint_url == mint_b).unwrap();
    assert_eq!(report_a.failed, 0);
    assert_eq!(report_a.skipped, 0);
    assert_eq!(report_a.status, CdkStatus::Ok);
    assert!(
        report_b.failed > 0 || report_b.skipped > 0,
        "B must report an unresolved saga: {report_b:?}"
    );
    assert!(report_b.message.is_some(), "B must carry a diagnostic");

    // Mutations are blocked only on B; A still works and reads stay available.
    let send_b = block_on(handle.send(&mint_b, 1, 1000)).unwrap_err();
    assert_eq!(send_b.status, CdkStatus::RecoveryPending);
    let send_a = block_on(handle.send(&mint_a, 100, 1000)).unwrap();
    assert!(!send_a.token.is_empty());
    assert_eq!(block_on(handle.list_balances()).unwrap().len(), 2);
    assert!(!block_on(handle.list_pending_tokens()).unwrap().is_empty());

    // Startup recovery exposes the same per-mint detail on reopen.
    drop(handle);
    let (reopened, startup_reports) = block_on(CdkWallet::open(&[111u8; 64], &path_str)).unwrap();
    assert_eq!(startup_reports.len(), 2);
    let startup_b = startup_reports
        .iter()
        .find(|r| r.mint_url == mint_b)
        .unwrap();
    assert!(startup_b.failed > 0 || startup_b.skipped > 0);
    drop(reopened);
}

// ---------------------------------------------------------------------------
// Spilman channel lifecycle (funding -> cooperative close / post-expiry refund)
// ---------------------------------------------------------------------------

fn now_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// A `char_p::Ref` over a NUL-terminated byte buffer.
///
/// SAFETY: `bytes_with_nul` must be NUL-terminated and outlive the result.
fn cstr_ref(bytes_with_nul: &[u8]) -> safer_ffi::prelude::char_p::Ref<'_> {
    assert_eq!(
        bytes_with_nul.last(),
        Some(&0),
        "cstr_ref requires a NUL-terminated buffer"
    );
    unsafe {
        safer_ffi::prelude::char_p::Ref::from_ptr_unchecked(
            std::ptr::NonNull::new(bytes_with_nul.as_ptr() as *mut u8).unwrap(),
        )
    }
}

/// NUL-terminate a `&str` into an owned byte buffer.
fn with_nul(s: &str) -> Vec<u8> {
    let mut v = s.as_bytes().to_vec();
    v.push(0);
    v
}

fn take_string(result: crate::status::CdkStringResult) -> String {
    let error = result.error.as_ref().map(|e| e.to_str().to_owned());
    crate::api::cdk_string_free(result.error);
    assert_eq!(result.status, CdkStatus::Ok, "unexpected status: {error:?}");
    let value = result.value.expect("string payload");
    let out = value.to_str().to_owned();
    crate::api::cdk_string_free(Some(value));
    out
}

#[test]
fn ffi_resume_and_background_poll_check_a_real_saved_quote() {
    let mint = block_on(start_fake_mint(0));
    let dir = tempfile::tempdir().unwrap();
    let (mut wallet, _) = block_on(CdkWallet::open(&[93;64], dir.path().join("wallet.sqlite").to_str().unwrap())).unwrap();
    block_on(wallet.add_mint(&mint)).unwrap();
    let mut call = |op: &str, args: serde_json::Value| -> serde_json::Value {
        let raw = take_string(crate::api::cdk_wallet_quotes(Some(&mut wallet), Some(cstr_ref(&with_nul(op))), Some(cstr_ref(&with_nul(&args.to_string())))));
        serde_json::from_str(&raw).unwrap()
    };
    let created = call("create_deposit", serde_json::json!([mint,"21"]));
    assert_eq!(created["state"], "UNPAID");
    assert_eq!(created["expired"], false);
    let local = call("saved_invoice", serde_json::json!([mint,created["id"]]));
    assert_eq!(local, created);
    let resumed = call("resume_deposit", serde_json::json!([mint]));
    assert_eq!(resumed["invoice"]["id"], created["id"]);
    assert!(resumed.get("cursor").is_none());
    let mut polled = call("poll_deposits", serde_json::json!([mint,""]));
    assert_eq!(polled["cursor"], created["id"]);
    assert_eq!(polled["invoice"]["id"], created["id"]);
    assert!(polled.get("error").is_none());
    let deadline = Instant::now() + Duration::from_secs(15);
    while polled["invoice"]["state"] != "ISSUED" {
        assert!(Instant::now() < deadline, "poll must check and issue, not just return local unpaid data");
        std::thread::sleep(Duration::from_millis(20));
        polled = call("poll_deposits", serde_json::json!([mint,""]));
        assert!(polled.get("error").is_none());
        assert_eq!(polled["cursor"], created["id"]);
    }
    assert_eq!(polled["invoice"]["confirmed"], true);
    let local = call("saved_invoice", serde_json::json!([mint,created["id"]]));
    assert_eq!(local["confirmed"],true);
    let checked = call("deposit_update",serde_json::json!([mint,"check",created["id"]]));
    assert_eq!(checked["wallet_changed"],false);
    assert_eq!(checked["recovery_pending"],false);
    assert_eq!(checked["invoice"]["confirmed"],true);
    assert!(checked["error"].is_null());
    for kind in ["poll","recover"] {
        let update=call("deposit_update",serde_json::json!([mint,kind,""]));
        assert!(update["invoice"].is_null());
        assert!(update["cursor"].is_null());
        assert_eq!(update["wallet_changed"],false);
    }
    for (op,args) in [("deposit_update",serde_json::json!([mint,"unsupported",""])),("saved_invoice",serde_json::json!([mint,""]))] {
        let result=crate::api::cdk_wallet_quotes(Some(&mut wallet),Some(cstr_ref(&with_nul(op))),Some(cstr_ref(&with_nul(&args.to_string()))));
        assert_eq!(result.status,CdkStatus::InvalidArgument);
        crate::api::cdk_string_free(result.error);
        crate::api::cdk_string_free(result.value);
    }
}

fn take_keypair(result: crate::status::CdkSpilmanKeypairResult) -> (String, String) {
    let error = result.error.as_ref().map(|e| e.to_str().to_owned());
    crate::api::cdk_string_free(result.error);
    assert_eq!(result.status, CdkStatus::Ok, "unexpected status: {error:?}");
    let secret = result.secret_key_hex.expect("secret key");
    let public = result.pubkey_hex.expect("public key");
    let secret_str = secret.to_str().to_owned();
    let public_str = public.to_str().to_owned();
    crate::api::cdk_string_free(Some(secret));
    crate::api::cdk_string_free(Some(public));
    (secret_str, public_str)
}

fn assert_status_ok(result: crate::status::CdkStatusResult) {
    let error = result.error.as_ref().map(|e| e.to_str().to_owned());
    crate::api::cdk_string_free(result.error);
    assert_eq!(result.status, CdkStatus::Ok, "unexpected status: {error:?}");
}

struct CloseProofs {
    receiver: Vec<serde_json::Value>,
    sender: Vec<serde_json::Value>,
    receiver_sum: u64,
    sender_sum: u64,
}

fn take_close(result: crate::status::CdkSpilmanCloseResult) -> CloseProofs {
    let error = result.error.as_ref().map(|e| e.to_str().to_owned());
    crate::api::cdk_string_free(result.error);
    assert_eq!(result.status, CdkStatus::Ok, "unexpected status: {error:?}");
    let receiver_json = result.receiver_proofs_json.expect("receiver proofs");
    let sender_json = result.sender_proofs_json.expect("sender proofs");
    let receiver: Vec<serde_json::Value> = serde_json::from_str(receiver_json.to_str()).unwrap();
    let sender: Vec<serde_json::Value> = serde_json::from_str(sender_json.to_str()).unwrap();
    crate::api::cdk_string_free(Some(receiver_json));
    crate::api::cdk_string_free(Some(sender_json));
    CloseProofs {
        receiver,
        sender,
        receiver_sum: result.receiver_sum,
        sender_sum: result.sender_sum,
    }
}

/// A channel funded end to end through the FFI: the token is minted, the
/// channel params are derived, the funding swap is posted, and the funding
/// proofs are recovered.
struct FundedChannel {
    handle: CdkWallet,
    keyset_info: String,
    alice_secret: String,
    charlie_secret: String,
    channel_secret: String,
    params_json: String,
    funding_proofs_json: String,
    capacity: u64,
}

/// Fund a channel end to end through the wallet ABI.
///
/// `handle` must already be open over the wallet database, have `mint_url`
/// approved, and hold at least `capacity` msats of spendable funds. The required
/// funding-token amount is computed from the mint's active keyset and then
/// created with `handle.send`, so the resulting channel is funded from the
/// wrapper's own CDK wallet rather than a raw test helper.
fn fund_channel(
    mut handle: CdkWallet,
    mint_url: &str,
    capacity: u64,
    expiry_timestamp: u64,
) -> FundedChannel {
    let keyset_info = take_string(crate::spilman::cdk_wallet_get_active_keyset_info_json(
        Some(&handle),
        Some(cstr_ref(&with_nul(mint_url))),
    ));

    // The by-id lookup must return the very same keyset as the active lookup,
    // so callers can round-trip the id carried in the JSON.
    let keyset_id = serde_json::from_str::<serde_json::Value>(&keyset_info).unwrap()["keysetId"]
        .as_str()
        .expect("keyset info carries a keysetId")
        .to_string();
    let keyset_info_by_id = take_string(crate::spilman::cdk_wallet_get_keyset_info_json(
        Some(&handle),
        Some(cstr_ref(&with_nul(mint_url))),
        Some(cstr_ref(&with_nul(&keyset_id))),
    ));
    assert_eq!(
        keyset_info, keyset_info_by_id,
        "by-id keyset lookup must match the active keyset JSON"
    );

    // The minimum funding-token amount the channel needs for `capacity`. On the
    // zero-fee test mint this equals `capacity`.
    let funding = crate::spilman::cdk_spilman_compute_funding_token_amount(
        capacity,
        Some(cstr_ref(&with_nul(&keyset_info))),
        64,
    );
    let funding_error = funding.error.as_ref().map(|e| e.to_str().to_owned());
    crate::api::cdk_string_free(funding.error);
    assert_eq!(
        funding.status,
        CdkStatus::Ok,
        "unexpected status: {funding_error:?}"
    );
    assert_eq!(funding.amount, capacity);
    let required_msats = funding.amount;

    // Alice's own CDK wallet creates the funding token; the sent proofs are
    // reserved locally, exactly as the channel funding swap will consume them.
    let token = block_on(handle.send(mint_url, required_msats, 10))
        .expect("wallet send for channel funding must succeed")
        .token;

    let (alice_secret, alice_public) = take_keypair(crate::spilman::cdk_spilman_generate_keypair());
    let (charlie_secret, charlie_public) =
        take_keypair(crate::spilman::cdk_spilman_generate_keypair());

    let channel_secret = take_string(crate::spilman::cdk_spilman_compute_channel_secret(
        Some(cstr_ref(&with_nul(&alice_secret))),
        Some(cstr_ref(&with_nul(&charlie_public))),
    ));

    let computed = take_string(crate::spilman::cdk_spilman_compute_channel_from_token(
        Some(cstr_ref(&with_nul(&token))),
        Some(cstr_ref(&with_nul(&charlie_public))),
        Some(cstr_ref(&with_nul(&alice_public))),
        Some(cstr_ref(&with_nul(&channel_secret))),
        expiry_timestamp,
        Some(cstr_ref(&with_nul(&keyset_info))),
        64,
    ));
    let computed: serde_json::Value = serde_json::from_str(&computed).unwrap();
    let params_json = computed["params_json"].as_str().unwrap().to_string();
    let proofs_json = computed["proofs_json"].as_str().unwrap().to_string();
    let capacity = computed["capacity"].as_u64().unwrap();

    // The token the wallet produced must expand to exactly the proofs the
    // channel derivation consumed, so the CDK and Spilman halves agree.
    let token_proofs_json = take_string(crate::spilman::cdk_token_to_proofs_json(
        Some(cstr_ref(&with_nul(&token))),
        Some(cstr_ref(&with_nul(&keyset_info))),
    ));
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&token_proofs_json).unwrap(),
        serde_json::from_str::<serde_json::Value>(&proofs_json).unwrap(),
        "cdk_token_to_proofs_json must match the channel's derived proofs"
    );

    let funding = take_string(crate::spilman::cdk_spilman_create_funding_swap(
        Some(cstr_ref(&with_nul(&params_json))),
        Some(cstr_ref(&with_nul(&channel_secret))),
        Some(cstr_ref(&with_nul(&keyset_info))),
        Some(cstr_ref(&with_nul(&proofs_json))),
    ));
    let funding: serde_json::Value = serde_json::from_str(&funding).unwrap();
    let swap_request_json = funding["swap_request_json"].as_str().unwrap().to_string();
    let funding_secrets_json = funding["funding_secrets_json"]
        .as_str()
        .unwrap()
        .to_string();

    let swap_response = take_string(crate::spilman::cdk_wallet_post_swap(
        Some(&handle),
        Some(cstr_ref(&with_nul(mint_url))),
        Some(cstr_ref(&with_nul(&swap_request_json))),
    ));

    let complete = take_string(crate::spilman::cdk_spilman_complete_funding_swap(
        Some(cstr_ref(&with_nul(&swap_response))),
        Some(cstr_ref(&with_nul(&funding_secrets_json))),
        Some(cstr_ref(&with_nul(&keyset_info))),
    ));
    let complete: serde_json::Value = serde_json::from_str(&complete).unwrap();
    let funding_proofs_json = complete["funding_proofs_json"]
        .as_str()
        .unwrap()
        .to_string();

    FundedChannel {
        handle,
        keyset_info,
        alice_secret,
        charlie_secret,
        channel_secret,
        params_json,
        funding_proofs_json,
        capacity,
    }
}

#[test]
fn spilman_channel_full_lifecycle_cooperative_close_and_receive() {
    let mint_url = block_on(start_fake_mint(0));
    let (_dir, path) = temp_db();
    let seed = [131u8; 64];

    // The wrapper handle must create the marked database before the raw cdk
    // helper funds it over the same file.
    let mut handle = open_wallet(seed, &path);
    block_on(handle.add_mint(&mint_url)).unwrap();
    // Fund Alice's wallet with 200 msats: 100 to fund the channel and 100 kept
    // behind so the wallet half of the handoff is observable.
    block_on(fund_wallet(
        &path,
        seed,
        &mint_url,
        200,
        SplitTarget::default(),
    ));

    let mut channel = fund_channel(handle, &mint_url, 100, now_seconds() + 3600);
    assert_eq!(
        channel.capacity, 100,
        "channel must be funded with 100 msats"
    );

    // The funding proofs form a valid, verifiable channel.
    assert_status_ok(crate::spilman::cdk_spilman_verify_valid_channel(
        Some(cstr_ref(&with_nul(&channel.params_json))),
        Some(cstr_ref(&with_nul(&channel.channel_secret))),
        Some(cstr_ref(&with_nul(&channel.keyset_info))),
        Some(cstr_ref(&with_nul(&channel.funding_proofs_json))),
    ));

    // Exercise the three-step unsigned balance-update flow for an intermediate
    // balance before signing the final close update.
    let intermediate_balance = 30;
    let unsigned = take_string(crate::spilman::cdk_spilman_create_unsigned_balance_update(
        Some(cstr_ref(&with_nul(&channel.params_json))),
        Some(cstr_ref(&with_nul(&channel.keyset_info))),
        Some(cstr_ref(&with_nul(&channel.channel_secret))),
        Some(cstr_ref(&with_nul(&channel.funding_proofs_json))),
        intermediate_balance,
    ));
    let unsigned: serde_json::Value = serde_json::from_str(&unsigned).unwrap();
    let unsigned_swap_request = unsigned["unsigned_swap_request_json"]
        .as_str()
        .unwrap()
        .to_string();
    let message_hex = unsigned["message_hex"].as_str().unwrap().to_string();
    let tweak_scalar_hex = unsigned["tweak_scalar_hex"].as_str().unwrap().to_string();
    let channel_id = unsigned["channel_id"].as_str().unwrap().to_string();

    let intermediate_signature =
        take_string(crate::spilman::cdk_spilman_sign_with_tweaked_key_util(
            Some(cstr_ref(&with_nul(&channel.alice_secret))),
            Some(cstr_ref(&with_nul(&message_hex))),
            Some(cstr_ref(&with_nul(&tweak_scalar_hex))),
        ));
    let signed = take_string(
        crate::spilman::cdk_spilman_attach_signature_to_balance_update(
            Some(cstr_ref(&with_nul(&unsigned_swap_request))),
            Some(cstr_ref(&with_nul(&intermediate_signature))),
            Some(cstr_ref(&with_nul(&channel_id))),
            intermediate_balance,
        ),
    );
    let signed: serde_json::Value = serde_json::from_str(&signed).unwrap();
    let intermediate_signature = signed["signature"].as_str().unwrap().to_string();

    // The receiver can verify the externally-signed intermediate update.
    assert_status_ok(crate::spilman::cdk_spilman_verify_balance_update(
        Some(cstr_ref(&with_nul(&channel.params_json))),
        Some(cstr_ref(&with_nul(&channel.channel_secret))),
        Some(cstr_ref(&with_nul(&channel.keyset_info))),
        Some(cstr_ref(&with_nul(&channel.funding_proofs_json))),
        Some(cstr_ref(&with_nul(&channel_id))),
        intermediate_balance,
        Some(cstr_ref(&with_nul(&intermediate_signature))),
    ));

    // Close at a split balance so both parties receive value.
    let balance = 70;
    let update = take_string(crate::spilman::cdk_spilman_create_signed_balance_update(
        Some(cstr_ref(&with_nul(&channel.params_json))),
        Some(cstr_ref(&with_nul(&channel.keyset_info))),
        Some(cstr_ref(&with_nul(&channel.alice_secret))),
        Some(cstr_ref(&with_nul(&channel.funding_proofs_json))),
        balance,
    ));
    let update: serde_json::Value = serde_json::from_str(&update).unwrap();
    let sender_signature = update["signature"].as_str().unwrap().to_string();
    let channel_id = update["channel_id"].as_str().unwrap().to_string();

    // The receiver can verify the sender's signed balance update.
    assert_status_ok(crate::spilman::cdk_spilman_verify_balance_update(
        Some(cstr_ref(&with_nul(&channel.params_json))),
        Some(cstr_ref(&with_nul(&channel.channel_secret))),
        Some(cstr_ref(&with_nul(&channel.keyset_info))),
        Some(cstr_ref(&with_nul(&channel.funding_proofs_json))),
        Some(cstr_ref(&with_nul(&channel_id))),
        balance,
        Some(cstr_ref(&with_nul(&sender_signature))),
    ));

    // Build the jointly-signed close swap and submit it.
    let close = take_string(crate::spilman::cdk_spilman_prepare_close_swap(
        Some(cstr_ref(&with_nul(&channel.params_json))),
        Some(cstr_ref(&with_nul(&channel.channel_secret))),
        Some(cstr_ref(&with_nul(&channel.keyset_info))),
        Some(cstr_ref(&with_nul(&channel.keyset_info))),
        Some(cstr_ref(&with_nul(&channel.funding_proofs_json))),
        balance,
        Some(cstr_ref(&with_nul(&sender_signature))),
        Some(cstr_ref(&with_nul(&channel.charlie_secret))),
    ));
    let close: serde_json::Value = serde_json::from_str(&close).unwrap();
    let close_swap_request = serde_json::to_string(&close["swap_request"]).unwrap();
    let secrets_with_blinding = serde_json::to_string(&close["secrets_with_blinding"]).unwrap();

    let close_response = take_string(crate::spilman::cdk_wallet_post_swap(
        Some(&channel.handle),
        Some(cstr_ref(&with_nul(&mint_url))),
        Some(cstr_ref(&with_nul(&close_swap_request))),
    ));

    let closed = take_close(crate::spilman::cdk_spilman_unblind_close_swap(
        Some(cstr_ref(&with_nul(&channel.params_json))),
        Some(cstr_ref(&with_nul(&channel.channel_secret))),
        Some(cstr_ref(&with_nul(&channel.keyset_info))),
        Some(cstr_ref(&with_nul(&channel.keyset_info))),
        Some(cstr_ref(&with_nul(&secrets_with_blinding))),
        Some(cstr_ref(&with_nul(&close_response))),
        balance,
        Some(cstr_ref(&with_nul(&channel.charlie_secret))),
    ));
    assert_eq!(closed.receiver_sum, balance);
    assert_eq!(closed.sender_sum, channel.capacity - balance);
    assert!(!closed.receiver.is_empty());
    assert!(!closed.sender.is_empty());

    // The receiver can spend the close proofs into a fresh wallet.
    let (_dir_c, path_c) = temp_db();
    let mut charlie_wallet = open_wallet([132u8; 64], &path_c);
    block_on(charlie_wallet.add_mint(&mint_url)).unwrap();
    let receiver_proofs_json = serde_json::to_string(&closed.receiver).unwrap();
    let received = crate::spilman::cdk_wallet_receive_proofs(
        Some(&mut charlie_wallet),
        Some(cstr_ref(&with_nul(&mint_url))),
        Some(cstr_ref(&with_nul(&receiver_proofs_json))),
        None,
    );
    let receive_error = received.error.as_ref().map(|e| e.to_str().to_owned());
    crate::api::cdk_string_free(received.error);
    assert_eq!(
        received.status,
        CdkStatus::Ok,
        "receive of close proofs failed: {receive_error:?}"
    );
    assert_eq!(received.net_msats, balance);

    // The sender reclaims the remainder, signing with Alice's P2PK key.
    let sender_proofs_json = serde_json::to_string(&closed.sender).unwrap();
    let received_sender = crate::spilman::cdk_wallet_receive_proofs(
        Some(&mut channel.handle),
        Some(cstr_ref(&with_nul(&mint_url))),
        Some(cstr_ref(&with_nul(&sender_proofs_json))),
        Some(cstr_ref(&with_nul(&channel.alice_secret))),
    );
    let receive_sender_error = received_sender
        .error
        .as_ref()
        .map(|e| e.to_str().to_owned());
    crate::api::cdk_string_free(received_sender.error);
    assert_eq!(
        received_sender.status,
        CdkStatus::Ok,
        "receive of sender proofs failed: {receive_sender_error:?}"
    );
    assert_eq!(received_sender.net_msats, channel.capacity - balance);

    // The handoff is now observable on both sides: Charlie holds the 70 msats he
    // received, and Alice's wallet holds the 100 she kept plus the 30 the close
    // returned to her.
    let charlie_balance = block_on(charlie_wallet.list_balances()).unwrap();
    assert_eq!(charlie_balance.len(), 1);
    assert_eq!(charlie_balance[0].1, balance);
    let alice_balance = block_on(channel.handle.list_balances()).unwrap();
    assert_eq!(alice_balance.len(), 1);
    assert_eq!(alice_balance[0].1, 100 + (channel.capacity - balance));

    // Charlie can spend the close proofs onward through his own CDK wallet.
    let onward = block_on(charlie_wallet.send(&mint_url, balance, 10)).unwrap();
    assert!(!onward.token.is_empty());
}

#[test]
fn spilman_channel_post_expiry_sender_refund() {
    let mint_url = block_on(start_fake_mint(0));
    let (_dir, path) = temp_db();
    let seed = [141u8; 64];

    let mut handle = open_wallet(seed, &path);
    block_on(handle.add_mint(&mint_url)).unwrap();
    // Fund Alice's wallet with 200 msats: 100 to fund the channel and 100 kept
    // behind so the refund's effect on her wallet is observable.
    block_on(fund_wallet(
        &path,
        seed,
        &mint_url,
        200,
        SplitTarget::default(),
    ));

    // Fund the channel with an expiry in the past so the refund path is open.
    let expiry = now_seconds().saturating_sub(60);
    let mut channel = fund_channel(handle, &mint_url, 100, expiry);
    assert_eq!(
        channel.capacity, 100,
        "channel must be funded with 100 msats"
    );

    // Pass `NULL` for the derivation context to exercise the default
    // 32-zero-byte context.
    let prepared_str = take_string(crate::spilman::cdk_spilman_prepare_sender_refund(
        Some(cstr_ref(&with_nul(&channel.params_json))),
        Some(cstr_ref(&with_nul(&channel.channel_secret))),
        Some(cstr_ref(&with_nul(&channel.keyset_info))),
        Some(cstr_ref(&with_nul(&channel.keyset_info))),
        Some(cstr_ref(&with_nul(&channel.funding_proofs_json))),
        Some(cstr_ref(&with_nul(&channel.alice_secret))),
        now_seconds(),
        None,
    ));
    let prepared: serde_json::Value = serde_json::from_str(&prepared_str).unwrap();
    let refund_swap_request = serde_json::to_string(&prepared["swap_request"]).unwrap();

    let refund_response = take_string(crate::spilman::cdk_wallet_post_swap(
        Some(&channel.handle),
        Some(cstr_ref(&with_nul(&mint_url))),
        Some(cstr_ref(&with_nul(&refund_swap_request))),
    ));

    let refund = take_string(crate::spilman::cdk_spilman_complete_sender_refund(
        Some(cstr_ref(&with_nul(&channel.params_json))),
        Some(cstr_ref(&with_nul(&channel.channel_secret))),
        Some(cstr_ref(&with_nul(&channel.keyset_info))),
        Some(cstr_ref(&with_nul(&channel.funding_proofs_json))),
        Some(cstr_ref(&with_nul(&channel.alice_secret))),
        Some(cstr_ref(&with_nul(&prepared_str))),
        Some(cstr_ref(&with_nul(&refund_response))),
    ));
    let refund_proofs: Vec<serde_json::Value> = serde_json::from_str(&refund).unwrap();
    let total: u64 = refund_proofs
        .iter()
        .map(|proof| proof["amount"].as_u64().unwrap())
        .sum();
    assert!(total > 0, "the refund must return value");
    assert!(total <= channel.capacity);

    // Round-trip the refund proofs back into Alice's wallet as a cashuB token.
    let refund_token = take_string(crate::spilman::cdk_spilman_build_cashu_b_token(
        Some(cstr_ref(&with_nul(&mint_url))),
        Some(cstr_ref(&with_nul("msat"))),
        Some(cstr_ref(&with_nul(&refund))),
    ));
    let received = crate::spilman::cdk_wallet_receive_with_keys(
        Some(&mut channel.handle),
        Some(cstr_ref(&with_nul(&refund_token))),
        None,
    );
    let receive_error = received.error.as_ref().map(|e| e.to_str().to_owned());
    crate::api::cdk_string_free(received.error);
    assert_eq!(
        received.status,
        CdkStatus::Ok,
        "receive of refund failed: {receive_error:?}"
    );
    assert_eq!(received.net_msats, total);

    // The refund makes Alice whole again: the 100 she kept plus the full refund.
    let restored = block_on(channel.handle.list_balances()).unwrap();
    assert_eq!(restored.len(), 1);
    assert_eq!(restored[0].1, 100 + total);
    assert_eq!(
        restored[0].1, 200,
        "the refund restores Alice's full balance"
    );
}
