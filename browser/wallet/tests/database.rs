#[path = "../src/browser_db.rs"]
mod browser_db;
use browser_db::BrowserDatabase;
use cdk_common::wallet_db_test;

async fn provide_db(name: String) -> BrowserDatabase {
    BrowserDatabase::open(name, "test-fingerprint".to_owned()).unwrap()
}

wallet_db_test!(provide_db);
