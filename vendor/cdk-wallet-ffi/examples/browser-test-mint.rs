//! Local-only fake mint and static test server. No Lightning or real funds.
//! cargo +stable run --locked --example browser-test-mint --manifest-path
//! vendor/cdk-wallet-ffi/Cargo.toml -- zig-out/browser
use axum::{
    body::Body,
    extract::Request,
    extract::State,
    http::{header, StatusCode, Uri},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use cdk::{
    amount::SplitTarget,
    mint::{MintBuilder, MintMeltLimits, UnitConfig},
    nuts::{CurrencyUnit, MintQuoteState, PaymentMethod},
    types::{FeeReserve, QuoteTTL},
    wallet::{SendOptions, Wallet, WalletRepositoryBuilder},
    Amount,
};
use cdk_fake_wallet::FakeWallet;
use std::{
    collections::{HashMap, HashSet},
    path::{Component, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
};

#[derive(Clone)]
struct App {
    wallet: Arc<tokio::sync::Mutex<Wallet>>,
    directory: PathBuf,
}

fn withdrawal_invoice(query: &HashMap<String, String>) -> Result<String, StatusCode> {
    let sats = query
        .get("sats")
        .and_then(|s| s.parse::<u64>().ok())
        .filter(|n| (1..=10_000).contains(n))
        .ok_or(StatusCode::BAD_REQUEST)?;
    let amount_msat = sats.checked_mul(1000).ok_or(StatusCode::BAD_REQUEST)?;
    let description_bytes = match query.get("description_bytes") {
        Some(s) => s
            .parse::<usize>()
            .ok()
            .filter(|n| *n <= 600)
            .ok_or(StatusCode::BAD_REQUEST)?,
        None => 600,
    };
    let pending = match query.get("pending").map(String::as_str) {
        None | Some("false") => false,
        Some("true") => true,
        _ => return Err(StatusCode::BAD_REQUEST),
    };
    let description = if pending {
        let mut description = serde_json::to_string(&cdk_fake_wallet::FakeInvoiceDescription {
            pay_invoice_state: cdk::nuts::MeltQuoteState::Pending,
            check_payment_state: cdk::nuts::MeltQuoteState::Paid,
            pay_err: false,
            check_err: false,
        }).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let padding = description_bytes.checked_sub(description.len()).ok_or(StatusCode::BAD_REQUEST)?;
        description.push_str(&" ".repeat(padding));
        description
    } else {
        "x".repeat(description_bytes)
    };
    Ok(cdk_fake_wallet::create_fake_invoice(amount_msat, description).to_string())
}

fn withdrawal_mode(query: &HashMap<String, String>) -> Result<bool, StatusCode> {
    match query.get("mode").map(String::as_str) {
        Some("pending") => Ok(true),
        Some("paid") => Ok(false),
        _ => Err(StatusCode::BAD_REQUEST),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn withdrawal_fixture_validates_before_building_invoice() {
        let mut query = HashMap::from([("sats".into(), "21".into())]);
        let invoice = withdrawal_invoice(&query).unwrap();
        assert!((1025..=4096).contains(&invoice.len()));
        let parsed: cdk::lightning_invoice::Bolt11Invoice = invoice.parse().unwrap();
        assert_eq!(parsed.amount_milli_satoshis(), Some(21_000));
        for bytes in ["601", "1300", "2000", "-1", "invalid", "18446744073709551616"] {
            query.insert("description_bytes".into(), bytes.into());
            assert_eq!(withdrawal_invoice(&query), Err(StatusCode::BAD_REQUEST));
        }
        for bytes in ["0", "600"] {
            query.insert("description_bytes".into(), bytes.into());
            assert!(withdrawal_invoice(&query).is_ok());
        }
        for sats in ["0", "-1", "10001", "18446744073709551615", "18446744073709551616", "invalid"] {
            query.insert("sats".into(), sats.into());
            assert_eq!(withdrawal_invoice(&query), Err(StatusCode::BAD_REQUEST));
        }
        query.remove("sats");
        assert_eq!(withdrawal_invoice(&query), Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn withdrawal_pending_description_is_long_valid_json_and_modes_are_exact() {
        let mut query = HashMap::from([("sats".into(), "21".into()), ("pending".into(), "true".into())]);
        let invoice = withdrawal_invoice(&query).unwrap();
        assert!((1025..=4096).contains(&invoice.len()));
        let parsed: cdk::lightning_invoice::Bolt11Invoice = invoice.parse().unwrap();
        let description = parsed.description().to_string();
        assert_eq!(description.len(), 600);
        let control: cdk_fake_wallet::FakeInvoiceDescription = serde_json::from_str(&description).unwrap();
        assert_eq!(control.pay_invoice_state, cdk::nuts::MeltQuoteState::Pending);
        assert_eq!(control.check_payment_state, cdk::nuts::MeltQuoteState::Paid);
        assert!(!control.pay_err && !control.check_err);
        query.insert("description_bytes".into(), "0".into());
        assert_eq!(withdrawal_invoice(&query), Err(StatusCode::BAD_REQUEST));
        query.insert("pending".into(), "invalid".into());
        assert_eq!(withdrawal_invoice(&query), Err(StatusCode::BAD_REQUEST));
        for (mode, expected) in [("pending", Ok(true)), ("paid", Ok(false)), ("invalid", Err(StatusCode::BAD_REQUEST))] {
            assert_eq!(withdrawal_mode(&HashMap::from([("mode".into(), mode.into())])), expected);
        }
        assert_eq!(withdrawal_mode(&HashMap::new()), Err(StatusCode::BAD_REQUEST));
    }
}

async fn token(State(app): State<App>) -> Result<Json<serde_json::Value>, StatusCode> {
    let wallet = app.wallet.lock().await;
    let prepared = wallet
        .prepare_send(Amount::from(100), SendOptions::default())
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let token = prepared
        .confirm(None)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(Json(
        serde_json::json!({"token":token.to_string(),"sats":"100"}),
    ))
}

async fn asset(State(app): State<App>, uri: Uri) -> Response {
    let relative = if uri.path() == "/" {
        "index.html"
    } else {
        uri.path().trim_start_matches('/')
    };
    let path = PathBuf::from(relative);
    if !path.components().all(|c| matches!(c, Component::Normal(_))) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let content_type = match path.extension().and_then(|s| s.to_str()).unwrap_or("") {
        "wasm" => "application/wasm",
        "js" => "text/javascript",
        "html" => "text/html; charset=utf-8",
        "json" => "application/json",
        _ => "application/octet-stream",
    };
    match std::fs::read(app.directory.join(path)) {
        Ok(bytes) => (
            [
                (header::CONTENT_TYPE, content_type),
                (header::CACHE_CONTROL, "no-store"),
            ],
            bytes,
        )
            .into_response(),
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let directory = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("zig-out/browser"));
    let port = std::env::var("BROWSER_TEST_PORT").unwrap_or_else(|_| "18787".to_owned());
    let listener = tokio::net::TcpListener::bind(format!("127.0.0.1:{port}")).await?;
    let url = format!("http://{}", listener.local_addr()?);
    let db = Arc::new(cdk_sqlite::mint::memory::empty().await?);
    let mut builder = MintBuilder::new(db.clone());
    builder.configure_unit(
        CurrencyUnit::Sat,
        UnitConfig {
            amounts: (0..16).map(|i| 2u64.pow(i)).collect(),
            input_fee_ppk: 0,
        },
    )?;
    let fake = FakeWallet::new(
        FeeReserve {
            min_fee_reserve: 1.into(),
            percent_fee_reserve: 0.0,
        },
        HashMap::new(),
        HashSet::new(),
        0,
        CurrencyUnit::Sat,
    );
    builder
        .add_payment_processor(
            CurrencyUnit::Sat,
            PaymentMethod::BOLT11,
            MintMeltLimits::new(1, 10_000),
            Arc::new(fake),
        )
        .await?;
    let mint = builder.build_with_seed(db, &[7u8; 64]).await?;
    mint.set_quote_ttl(QuoteTTL::new(10_000, 10_000)).await?;
    mint.start().await?;
    let router = cdk_axum::create_mint_router(Arc::new(mint), vec!["bolt11".to_owned()]).await?;
    // Explicit test-only deterministic payment gate. Funding runs ungated; the
    // gate closes immediately before the isolated renderer fixture is served.
    let gated = std::env::var_os("BROWSER_TEST_PAYMENT_GATE").is_some();
    let paid = Arc::new(AtomicBool::new(true));
    let quotes = Arc::new(AtomicU64::new(0));
    let claims = Arc::new(AtomicU64::new(0));
    let withdrawal_quotes = Arc::new(AtomicU64::new(0));
    let melt_posts = Arc::new(AtomicU64::new(0));
    let withdrawal_pending = Arc::new(AtomicBool::new(false));
    let unpaid_quote = Arc::new(tokio::sync::Mutex::new(None::<String>));
    let gate = paid.clone();
    let except = unpaid_quote.clone();
    let quote_count = quotes.clone();
    let claim_count = claims.clone();
    let withdrawal_quote_count = withdrawal_quotes.clone();
    let melt_count = melt_posts.clone();
    let withdrawal_gate = withdrawal_pending.clone();
    let router = router.layer(middleware::from_fn(move |req: Request, next: Next| {
        let paid = gate.clone();
        let quotes = quote_count.clone();
        let claims = claim_count.clone();
        let withdrawal_quotes = withdrawal_quote_count.clone();
        let melt_posts = melt_count.clone();
        let withdrawal_pending = withdrawal_gate.clone();
        let except = except.clone();
        async move {
            let path = req.uri().path().to_owned();
            let withdrawal_get = path.starts_with("/v1/melt/quote/bolt11/") && req.method() == axum::http::Method::GET;
            let withdrawal_post = path == "/v1/melt/bolt11" && req.method() == axum::http::Method::POST;
            if req.method() == axum::http::Method::POST {
                if path == "/v1/melt/quote/bolt11" { withdrawal_quotes.fetch_add(1, Ordering::SeqCst); }
                if path == "/v1/melt/bolt11" { melt_posts.fetch_add(1, Ordering::SeqCst); }
            }
            let create =
                req.method() == axum::http::Method::POST && path == "/v1/mint/quote/bolt11";
            let claim = req.method() == axum::http::Method::POST && path == "/v1/mint/bolt11";
            if create {
                quotes.fetch_add(1, Ordering::SeqCst);
            }
            if claim {
                claims.fetch_add(1, Ordering::SeqCst);
            }
            let response = next.run(req).await;
            if withdrawal_pending.load(Ordering::SeqCst) && (withdrawal_get || withdrawal_post) {
                let (mut parts, body) = response.into_parts();
                let bytes = axum::body::to_bytes(body, 65536).await.unwrap();
                if let Ok(mut value) = serde_json::from_slice::<serde_json::Value>(&bytes) {
                    // Hold only real payment progress/completion. Never turn
                    // a rejection or an unsubmitted quote into a pending one.
                    if matches!(value["state"].as_str(), Some("PENDING" | "PAID")) {
                        value["state"] = "PENDING".into();
                        value["payment_preimage"] = serde_json::Value::Null;
                        value["change"] = serde_json::Value::Null;
                        parts.headers.remove(header::CONTENT_LENGTH);
                        return Response::from_parts(parts, Body::from(value.to_string()));
                    }
                }
                return Response::from_parts(parts, Body::from(bytes));
            }
            let held = except.lock().await.clone();
            if gated && (!paid.load(Ordering::SeqCst) || held.as_deref() == Some(path.as_str())) && path.starts_with("/v1/mint/quote/bolt11") {
                let (mut parts, body) = response.into_parts();
                let bytes = axum::body::to_bytes(body, 65536).await.unwrap();
                if let Ok(mut value) = serde_json::from_slice::<serde_json::Value>(&bytes) {
                    if value.get("state").is_some() {
                        value["state"] = "UNPAID".into();
                        value["amount_paid"] = 0.into();
                        value["amount_issued"] = 0.into();
                    }
                    parts.headers.remove(header::CONTENT_LENGTH);
                    return Response::from_parts(parts, Body::from(value.to_string()));
                }
                return Response::from_parts(parts, Body::from(bytes));
            }
            response
        }
    }));
    let gate_ready = paid.clone();
    let quote_ready = quotes.clone();
    let claim_ready = claims.clone();
    let withdrawal_quote_ready = withdrawal_quotes.clone();
    let melt_ready = melt_posts.clone();
    let server = tokio::spawn(async move {
        // Funding happens after the listener begins accepting requests.
        let (sender, receiver) = tokio::sync::oneshot::channel::<App>();
        let shared = Arc::new(tokio::sync::OnceCell::<App>::new());
        let for_token = shared.clone();
        let for_asset = shared.clone();
        let for_gate = paid.clone();
        let for_except = unpaid_quote.clone();
        let for_unpay = paid.clone();
        let for_quotes = quotes.clone();
        let for_claims = claims.clone();
        let extra = Router::new()
            .route("/test-withdrawal-mode", get(move |axum::extract::Query(query): axum::extract::Query<HashMap<String, String>>| {
                let pending = withdrawal_pending.clone();
                async move {
                    let hold = withdrawal_mode(&query)?;
                    pending.store(hold, Ordering::SeqCst);
                    Ok::<_, StatusCode>(StatusCode::OK)
                }
            }))
            .route("/test-withdrawal-invoice", get(|axum::extract::Query(query): axum::extract::Query<HashMap<String, String>>| async move {
                let invoice = withdrawal_invoice(&query)?;
                Ok::<_, StatusCode>(Json(serde_json::json!({"invoice":invoice})))
            }))
            .route("/test-withdrawal-counts", get(move || {
                let quotes = withdrawal_quotes.clone();
                let posts = melt_posts.clone();
                async move { Json(serde_json::json!({"quotes":quotes.load(Ordering::SeqCst),"melt_posts":posts.load(Ordering::SeqCst)})) }
            }))
            .route("/test-unpay", get(move || {
                let paid = for_unpay.clone();
                async move {
                    if !gated { return StatusCode::NOT_FOUND; }
                    paid.store(false, Ordering::SeqCst);
                    StatusCode::OK
                }
            }))
            .route("/test-pay", get(move |axum::extract::Query(query): axum::extract::Query<HashMap<String, String>>| {
                let paid = for_gate.clone();
                let except = for_except.clone();
                async move {
                    if !gated { return StatusCode::NOT_FOUND; }
                    // Query decoding accepts URL-encoded quote IDs; compare the
                    // exact quote path, never a substring or arbitrary suffix.
                    *except.lock().await = query.get("except").map(|id| {
                        let mut quote_url = url::Url::parse("http://127.0.0.1/v1/mint/quote/bolt11/").unwrap();
                        quote_url.path_segments_mut().unwrap().pop_if_empty().push(id);
                        quote_url.path().to_owned()
                    });
                    paid.store(true, Ordering::SeqCst);
                    StatusCode::OK
                }
            }))
            .route("/test-deposit-counts", get(move || {
                let quotes = for_quotes.clone();
                let claims = for_claims.clone();
                async move { Json(serde_json::json!({"quotes":quotes.load(Ordering::SeqCst),"claims":claims.load(Ordering::SeqCst)})) }
            }))
            .route(
                "/test-token",
                get(move || {
                    let shared = for_token.clone();
                    async move {
                        match shared.get() {
                            Some(app) => token(State(app.clone())).await.into_response(),
                            None => StatusCode::SERVICE_UNAVAILABLE.into_response(),
                        }
                    }
                }),
            )
            .fallback(get(move |uri: Uri| {
                let shared = for_asset.clone();
                async move {
                    match shared.get() {
                        Some(app) => asset(State(app.clone()), uri).await,
                        None => StatusCode::SERVICE_UNAVAILABLE.into_response(),
                    }
                }
            }));
        let service = tokio::spawn(async move {
            axum::serve(listener, router.merge(extra)).await.unwrap();
        });
        tokio::spawn(async move {
            if let Ok(app) = receiver.await {
                let _ = shared.set(app);
            }
        });
        (sender, service)
    })
    .await?;

    let temp = tempfile::tempdir()?;
    let wallet_db =
        Arc::new(cdk_sqlite::WalletSqliteDatabase::new(temp.path().join("test.sqlite")).await?);
    let repo = WalletRepositoryBuilder::new()
        .localstore(wallet_db)
        .seed([42u8; 64])
        .build()
        .await?;
    let wallet = repo
        .get_or_create_wallet(url.parse()?, CurrencyUnit::Sat, None)
        .await?;
    let quote = wallet
        .mint_quote(
            PaymentMethod::BOLT11,
            Some(Amount::from(10_000)),
            None,
            None,
        )
        .await?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while wallet.check_mint_quote(&quote.id).await?.state != MintQuoteState::Paid {
        if std::time::Instant::now() > deadline {
            return Err("fake mint funding timed out".into());
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    wallet.mint(&quote.id, SplitTarget::default(), None).await?;
    quote_ready.store(0, Ordering::SeqCst);
    claim_ready.store(0, Ordering::SeqCst);
    withdrawal_quote_ready.store(0, Ordering::SeqCst);
    melt_ready.store(0, Ordering::SeqCst);
    if gated {
        gate_ready.store(false, Ordering::SeqCst);
    }
    server
        .0
        .send(App {
            wallet: Arc::new(tokio::sync::Mutex::new(wallet)),
            directory,
        })
        .map_err(|_| "server stopped")?;
    println!("Local fake mint ready: {url}/ (TEST FUNDS ONLY)");
    server.1.await?;
    drop(temp);
    Ok(())
}
