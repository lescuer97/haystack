#[path = "../src/browser_db.rs"]
mod browser_db;
use browser_db::{test_storage_get, test_storage_set, BrowserDatabase};
use cdk_common::database::WalletDatabase;
use cdk_common::wallet_db_test;
use futures::executor::block_on;

async fn provide_db(name: String) -> BrowserDatabase {
    BrowserDatabase::open(name, FINGERPRINT.to_owned()).unwrap()
}

const FINGERPRINT: &str = "test-fingerprint";

fn valid_record(key: &str) -> String {
    BrowserDatabase::open(key.to_owned(), FINGERPRINT.to_owned())
        .expect("create a valid v1 record");
    test_storage_get(key).expect("new storage must be written")
}

fn assert_rejected_without_overwrite(key: &str, raw: &str, what: &str) {
    test_storage_set(key, raw);
    assert!(
        BrowserDatabase::open(key.to_owned(), FINGERPRINT.to_owned()).is_err(),
        "{what} must be rejected"
    );
    assert_eq!(
        test_storage_get(key).as_deref(),
        Some(raw),
        "{what} must not modify the stored bytes"
    );
}

#[test]
fn strict_v1_rejects_missing_required_fields_without_overwrite() {
    let key = "strict-missing-fields";
    let valid = valid_record(key);

    // Every v1 field is required. A partial record is corruption, not an empty
    // wallet, and must not be serialized back with default/empty collections.
    for field in ["proofs", "counters", "sagas", "transactions", "kv"] {
        let mut value: serde_json::Value = serde_json::from_str(&valid).unwrap();
        value
            .as_object_mut()
            .unwrap()
            .remove(field)
            .unwrap_or_else(|| panic!("valid record has {field}"));
        let raw = serde_json::to_string(&value).unwrap();
        assert_rejected_without_overwrite(key, &raw, &format!("missing {field}"));
    }

    test_storage_set(key, &valid);
    BrowserDatabase::open(key.to_owned(), FINGERPRINT.to_owned())
        .expect("a complete valid v1 record stays loadable");
}

#[test]
fn strict_v1_rejects_truncated_and_incompatible_records() {
    let key = "strict-truncated-incompatible";
    let valid = valid_record(key);

    let truncated = &valid[..valid.len() / 2];
    assert_rejected_without_overwrite(key, truncated, "truncated JSON");

    let mut value: serde_json::Value = serde_json::from_str(&valid).unwrap();
    value["version"] = 2.into();
    let incompatible = serde_json::to_string(&value).unwrap();
    assert_rejected_without_overwrite(key, &incompatible, "incompatible version");

    test_storage_set(key, &valid);
    BrowserDatabase::open(key.to_owned(), FINGERPRINT.to_owned())
        .expect("a complete valid v1 record stays loadable after rejected records");
}

#[test]
fn strict_v1_tolerates_unknown_fields() {
    let key = "strict-unknown-field";
    let valid = valid_record(key);
    let mut value: serde_json::Value = serde_json::from_str(&valid).unwrap();
    value["future_field"] = serde_json::json!({"kept": true});
    let raw = serde_json::to_string(&value).unwrap();
    test_storage_set(key, &raw);
    BrowserDatabase::open(key.to_owned(), FINGERPRINT.to_owned())
        .expect("unknown fields remain readable");
    assert_eq!(
        test_storage_get(key).as_deref(),
        Some(raw.as_str()),
        "opening existing storage must not rewrite it"
    );
}

#[test]
fn mutation_after_external_corruption_fails_without_overwrite() {
    let key = "strict-mutation";
    let valid = valid_record(key);
    let db = BrowserDatabase::open(key.to_owned(), FINGERPRINT.to_owned()).unwrap();

    let mut value: serde_json::Value = serde_json::from_str(&valid).unwrap();
    value.as_object_mut().unwrap().remove("proofs").unwrap();
    let corrupt = serde_json::to_string(&value).unwrap();
    test_storage_set(key, &corrupt);

    // Every mutation reloads first, so a long-lived handle cannot turn a
    // partial record into a valid-but-empty one.
    assert!(block_on(db.kv_write("ns", "", "key", b"value")).is_err());
    assert_eq!(
        test_storage_get(key).as_deref(),
        Some(corrupt.as_str()),
        "failed mutation must not rewrite the partial record"
    );
}

wallet_db_test!(provide_db);
