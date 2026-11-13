//! Local-only fake mint and static test server. No Lightning or real funds.
//! cargo +stable run --locked --example browser-test-mint --manifest-path
//! vendor/cdk-wallet-ffi/Cargo.toml -- zig-out/browser
use axum::{
    extract::State,
    http::{header, StatusCode, Uri},
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
    sync::Arc,
};

#[derive(Clone)]
struct App {
    wallet: Arc<tokio::sync::Mutex<Wallet>>,
    directory: PathBuf,
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
    let server = tokio::spawn(async move {
        // Funding happens after the listener begins accepting requests.
        let (sender, receiver) = tokio::sync::oneshot::channel::<App>();
        let shared = Arc::new(tokio::sync::OnceCell::<App>::new());
        let for_token = shared.clone();
        let for_asset = shared.clone();
        let extra = Router::new()
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
    server
        .0
        .send(App {
            wallet: Arc::new(tokio::sync::Mutex::new(wallet)),
            directory,
        })
        .map_err(|_| "server stopped")?;
    println!("Local fake mint ready: {url}/?smoke (TEST FUNDS ONLY)");
    server.1.await?;
    drop(temp);
    Ok(())
}
