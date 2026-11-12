#[path = "../src/browser_db.rs"]
mod browser_db;
use browser_db::{
    seed_from_mnemonic, test_mnemonic, test_remove_mnemonic, test_set_mnemonic, test_set_state,
    test_state, BrowserDatabase, DbError,
};
use cdk_common::database::WalletDatabase;
use cdk_common::wallet_db_test;
use futures::executor::block_on;

const FINGERPRINT: &str = "test-fingerprint";
const MNEMONIC: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const OTHER_MNEMONIC: &str =
    "legal winner thank year wave sausage worth useful legal winner thank yellow";

fn seed() -> [u8; 64] {
    seed_from_mnemonic(MNEMONIC).expect("test mnemonic is valid")
}

fn other_seed() -> [u8; 64] {
    seed_from_mnemonic(OTHER_MNEMONIC).expect("test mnemonic is valid")
}

fn provision(key: &str) {
    block_on(BrowserDatabase::provision(
        key,
        MNEMONIC,
        FINGERPRINT.to_owned(),
        &seed(),
    ))
    .expect("provision the test wallet");
}

fn open(key: &str) -> Result<BrowserDatabase, DbError> {
    block_on(BrowserDatabase::open(
        key.to_owned(),
        FINGERPRINT.to_owned(),
        seed(),
    ))
}

fn open_with(key: &str, fingerprint: &str, seed: [u8; 64]) -> Result<BrowserDatabase, DbError> {
    block_on(BrowserDatabase::open(
        key.to_owned(),
        fingerprint.to_owned(),
        seed,
    ))
}

async fn provide_db(name: String) -> BrowserDatabase {
    BrowserDatabase::provision(&name, MNEMONIC, FINGERPRINT.to_owned(), &seed())
        .await
        .expect("provision the conformance wallet");
    BrowserDatabase::open(name, FINGERPRINT.to_owned(), seed())
        .await
        .expect("open the conformance wallet")
}

fn valid_record(key: &str) -> String {
    provision(key);
    test_state(key).expect("provisioning must write state").1
}

fn assert_rejected_without_overwrite(key: &str, raw: &str, what: &str) {
    test_set_state(key, raw);
    assert!(open(key).is_err(), "{what} must be rejected");
    assert_eq!(
        test_state(key).map(|(_, data)| data).as_deref(),
        Some(raw),
        "{what} must not modify the stored bytes"
    );
}

#[test]
fn open_requires_both_provisioned_records() {
    let key = "not-provisioned";
    assert_eq!(open(key).unwrap_err(), DbError::NotInitialized);
    assert!(test_state(key).is_none(), "opening must not create state");
    assert!(
        test_mnemonic(key).is_none(),
        "opening must not create a mnemonic"
    );

    let mnemonic_only = "mnemonic-only";
    test_set_mnemonic(mnemonic_only, MNEMONIC);
    assert_eq!(open(mnemonic_only).unwrap_err(), DbError::Incomplete);

    let state_only = "state-only";
    provision(state_only);
    test_remove_mnemonic(state_only);
    assert_eq!(open(state_only).unwrap_err(), DbError::Incomplete);
}

#[test]
fn open_rejects_the_wrong_seed_or_fingerprint() {
    let key = "wrong-seed";
    provision(key);
    let raw = test_state(key).expect("state").1;
    assert_eq!(
        open_with(key, FINGERPRINT, other_seed()).unwrap_err(),
        DbError::SeedMismatch
    );
    assert_eq!(
        open_with(key, "other-fingerprint", seed()).unwrap_err(),
        DbError::SeedMismatch
    );
    assert_eq!(
        test_state(key).map(|(_, data)| data).as_deref(),
        Some(raw.as_str()),
        "a rejected open must not rewrite the record"
    );
}

#[test]
fn open_rejects_an_invalid_stored_mnemonic() {
    let key = "invalid-mnemonic";
    provision(key);
    test_set_mnemonic(key, "this is not a bip39 mnemonic");
    assert_eq!(open(key).unwrap_err(), DbError::InvalidMnemonic);
}

#[test]
fn provisioning_never_replaces_an_existing_wallet() {
    let key = "no-replacement";
    provision(key);
    let before_state = test_state(key).expect("state").1;
    let before_mnemonic = test_mnemonic(key).expect("mnemonic");
    assert_eq!(
        block_on(BrowserDatabase::provision(
            key,
            OTHER_MNEMONIC,
            "other-fingerprint".to_owned(),
            &other_seed(),
        ))
        .unwrap_err(),
        DbError::AlreadyExists
    );
    assert_eq!(test_state(key).expect("state").1, before_state);
    assert_eq!(test_mnemonic(key).expect("mnemonic"), before_mnemonic);
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

    test_set_state(key, &valid);
    open(key).expect("a complete valid v1 record stays loadable");
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

    test_set_state(key, &valid);
    open(key).expect("a complete valid v1 record stays loadable after rejected records");
}

#[test]
fn strict_v1_rejects_unknown_fields_without_overwrite() {
    let key = "strict-unknown-field";
    let valid = valid_record(key);
    let mut value: serde_json::Value = serde_json::from_str(&valid).unwrap();
    value["future_field"] = serde_json::json!({"kept": true});
    let raw = serde_json::to_string(&value).unwrap();

    // Forward-compatible fields cannot be preserved by this writer, so an
    // unknown field is an incompatible record and is rejected before any
    // mutation. This is the only outcome that cannot lose the field.
    assert_rejected_without_overwrite(key, &raw, "unknown field");

    test_set_state(key, &valid);
    open(key).expect("a complete valid v1 record stays loadable after a rejected record");
}

#[test]
fn mutation_after_unknown_field_injection_fails_without_overwrite() {
    let key = "strict-unknown-mutation";
    let valid = valid_record(key);
    let db = open(key).expect("open a valid wallet");

    let mut value: serde_json::Value = serde_json::from_str(&valid).unwrap();
    value["future_field"] = serde_json::json!({"kept": true});
    let injected = serde_json::to_string(&value).unwrap();
    test_set_state(key, &injected);

    // A long-lived handle reloads before every mutation; it must not rewrite
    // the record without the unknown field.
    assert!(block_on(db.kv_write("ns", "", "key", b"value")).is_err());
    assert_eq!(
        test_state(key).map(|(_, data)| data).as_deref(),
        Some(injected.as_str()),
        "failed mutation must not drop the unknown field"
    );
}

#[test]
fn mutation_after_external_corruption_fails_without_overwrite() {
    let key = "strict-mutation";
    let valid = valid_record(key);
    let db = open(key).expect("open a valid wallet");

    let mut value: serde_json::Value = serde_json::from_str(&valid).unwrap();
    value.as_object_mut().unwrap().remove("proofs").unwrap();
    let corrupt = serde_json::to_string(&value).unwrap();
    test_set_state(key, &corrupt);

    // Every mutation reloads first, so a long-lived handle cannot turn a
    // partial record into a valid-but-empty one.
    assert!(block_on(db.kv_write("ns", "", "key", b"value")).is_err());
    assert_eq!(
        test_state(key).map(|(_, data)| data).as_deref(),
        Some(corrupt.as_str()),
        "failed mutation must not rewrite the partial record"
    );
}

#[test]
fn mnemonic_is_stored_as_normalized_plaintext_words() {
    let key = "mnemonic-words";
    provision(key);
    let words = test_mnemonic(key).expect("mnemonic record");
    assert_eq!(words, MNEMONIC);
    assert_eq!(words.split(' ').count(), 12);
}

wallet_db_test!(provide_db);
