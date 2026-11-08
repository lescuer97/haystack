//! Policy tests that never touch a live mint.
//!
//! These exercise the wrapper-owned database contract, argument validation, the
//! mint-URL policy, the C ABI surface, secret redaction and the panic guard.
//! Everything runs on the process-wide Tokio runtime via [`runtime`], exactly as
//! the C ABI does.

use std::future::Future;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::str::FromStr;

use safer_ffi::prelude::*;

use crate::status::CdkStatus;
use crate::wallet::{parse_mint_url, runtime, CdkWallet, MAX_TOKEN_BYTES};

/// Drive a future on the process-wide runtime.
fn block_on<F: Future>(fut: F) -> F::Output {
    runtime().block_on(fut)
}

fn temp_db() -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("wallet.sqlite");
    (dir, path)
}

fn open_handle(seed: [u8; 64], path: &Path) -> CdkWallet {
    let (handle, _reports) = block_on(CdkWallet::open(&seed, path.to_str().unwrap())).unwrap();
    handle
}

/// A `char_p::Ref` over a NUL-terminated byte buffer (which need not be UTF-8).
///
/// SAFETY: `bytes_with_nul` must be NUL-terminated and must outlive the result.
fn cstr_ref(bytes_with_nul: &[u8]) -> char_p::Ref<'_> {
    assert_eq!(
        bytes_with_nul.last(),
        Some(&0),
        "cstr_ref requires a NUL-terminated buffer"
    );
    unsafe {
        char_p::Ref::from_ptr_unchecked(
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

fn slice_ref(bytes: &[u8]) -> c_slice::Ref<'_, u8> {
    c_slice::Ref::from(bytes)
}

/// Snapshot the SQLite schema (table/index names) of a database file.
fn sqlite_master(path: &Path) -> Vec<(String, String)> {
    let conn = rusqlite::Connection::open(path).unwrap();
    let mut stmt = conn
        .prepare("SELECT type, name FROM sqlite_master ORDER BY type, name")
        .unwrap();
    let rows = stmt
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .unwrap();
    rows.map(|row| row.unwrap()).collect()
}

// ---------------------------------------------------------------------------
// Database contract (open / marker / seed)
// ---------------------------------------------------------------------------

#[test]
fn open_rejects_wrong_seed_length() {
    let (_dir, path) = temp_db();
    let err = block_on(CdkWallet::open(&[0u8; 63], path.to_str().unwrap())).unwrap_err();
    assert_eq!(err.status, CdkStatus::InvalidSeed);
}

#[test]
fn open_rejects_empty_path() {
    let err = block_on(CdkWallet::open(&[7u8; 64], "")).unwrap_err();
    assert_eq!(err.status, CdkStatus::InvalidPath);
}

#[test]
fn open_rejects_directory_path() {
    let dir = tempfile::tempdir().unwrap();
    let err = block_on(CdkWallet::open(&[7u8; 64], dir.path().to_str().unwrap())).unwrap_err();
    assert_eq!(err.status, CdkStatus::InvalidPath);
}

#[test]
fn open_creates_then_rejects_wrong_seed() {
    let (_dir, path) = temp_db();
    let path = path.to_str().unwrap().to_string();

    // First open creates and marks the database.
    let (handle, _reports) = block_on(CdkWallet::open(&[1u8; 64], &path)).unwrap();
    drop(handle);

    // Reopening with a different seed must be refused.
    let err = block_on(CdkWallet::open(&[2u8; 64], &path)).unwrap_err();
    assert_eq!(err.status, CdkStatus::SeedMismatch);

    // Reopening with the original seed still works.
    let (handle, _reports) = block_on(CdkWallet::open(&[1u8; 64], &path)).unwrap();
    drop(handle);
}

#[test]
fn open_rejects_unmarked_preexisting_database_without_modifying_it() {
    let (_dir, path) = temp_db();

    // Create a *valid* CDK wallet database that the wrapper did not create.
    let db = block_on(cdk_sqlite::WalletSqliteDatabase::new(path.clone())).unwrap();
    drop(db);

    let before = sqlite_master(&path);
    assert!(!before.is_empty(), "the foreign database has a schema");

    let err = block_on(CdkWallet::open(&[9u8; 64], path.to_str().unwrap())).unwrap_err();
    assert_eq!(err.status, CdkStatus::UnsupportedDatabase);

    // The rejection must not have mutated the foreign database.
    assert_eq!(sqlite_master(&path), before);
}

#[test]
fn open_rejects_empty_preexisting_file() {
    let (_dir, path) = temp_db();
    std::fs::File::create(&path).unwrap();
    assert_eq!(std::fs::metadata(&path).unwrap().len(), 0);

    let err = block_on(CdkWallet::open(&[9u8; 64], path.to_str().unwrap())).unwrap_err();
    assert_eq!(err.status, CdkStatus::UnsupportedDatabase);

    // The empty file is left untouched.
    assert_eq!(std::fs::metadata(&path).unwrap().len(), 0);
}

#[test]
fn open_rejects_truncated_marker() {
    let (_dir, path) = temp_db();
    let path_str = path.to_str().unwrap().to_string();
    let (handle, _reports) = block_on(CdkWallet::open(&[4u8; 64], &path_str)).unwrap();
    drop(handle);

    // Overwrite the marker with a truncated value.
    let conn = rusqlite::Connection::open(&path).unwrap();
    conn.execute(
        "UPDATE kv_store SET value = ?1 WHERE primary_namespace = 'cdk_wallet_ffi' AND key = 'marker'",
        rusqlite::params![vec![1u8, 2, 3]],
    )
    .unwrap();
    drop(conn);

    let err = block_on(CdkWallet::open(&[4u8; 64], &path_str)).unwrap_err();
    assert_eq!(err.status, CdkStatus::UnsupportedDatabase);
}

#[test]
fn open_rejects_incompatible_format_version() {
    let (_dir, path) = temp_db();
    let path_str = path.to_str().unwrap().to_string();
    let (handle, _reports) = block_on(CdkWallet::open(&[5u8; 64], &path_str)).unwrap();
    drop(handle);

    // Bump the version field to an unsupported value, keeping the 36-byte size.
    let conn = rusqlite::Connection::open(&path).unwrap();
    let mut value: Vec<u8> = conn
        .query_row(
            "SELECT value FROM kv_store WHERE primary_namespace = 'cdk_wallet_ffi' AND key = 'marker'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(value.len(), 36);
    value[..4].copy_from_slice(&999u32.to_le_bytes());
    conn.execute(
        "UPDATE kv_store SET value = ?1 WHERE primary_namespace = 'cdk_wallet_ffi' AND key = 'marker'",
        rusqlite::params![value],
    )
    .unwrap();
    drop(conn);

    let err = block_on(CdkWallet::open(&[5u8; 64], &path_str)).unwrap_err();
    assert_eq!(err.status, CdkStatus::UnsupportedFormatVersion);
}

#[test]
fn open_rejects_insecure_permissions() {
    let (_dir, path) = temp_db();
    let path_str = path.to_str().unwrap().to_string();
    let (handle, _reports) = block_on(CdkWallet::open(&[6u8; 64], &path_str)).unwrap();
    drop(handle);

    // A brand-new database is owner-only.
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "new databases must be 0600");

    // A restored 0644 database must be refused, not silently chmod-ed.
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    let err = block_on(CdkWallet::open(&[6u8; 64], &path_str)).unwrap_err();
    assert_eq!(err.status, CdkStatus::InsecureDatabasePermissions);
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o644,
        "the wrapper must not silently chmod user files"
    );

    // Restoring owner-only permissions makes it usable again.
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let (handle, _reports) = block_on(CdkWallet::open(&[6u8; 64], &path_str)).unwrap();
    drop(handle);
}

#[test]
fn open_rejects_symlink_database_path() {
    let (dir, path) = temp_db();
    let path_str = path.to_str().unwrap().to_string();
    let (handle, _reports) = block_on(CdkWallet::open(&[8u8; 64], &path_str)).unwrap();
    drop(handle);

    let link = dir.path().join("link.sqlite");
    std::os::unix::fs::symlink(&path, &link).unwrap();

    let err = block_on(CdkWallet::open(&[8u8; 64], link.to_str().unwrap())).unwrap_err();
    assert_eq!(err.status, CdkStatus::InvalidPath);
}

#[test]
fn open_rejects_a_second_live_handle() {
    let (_dir, path) = temp_db();
    let path = path.to_str().unwrap().to_string();

    let (first, _reports) = block_on(CdkWallet::open(&[3u8; 64], &path)).unwrap();
    let err = block_on(CdkWallet::open(&[3u8; 64], &path)).unwrap_err();
    assert_eq!(err.status, CdkStatus::AlreadyOpen);
    drop(first);

    // Once the first handle is gone the lock is released.
    let (second, _reports) = block_on(CdkWallet::open(&[3u8; 64], &path)).unwrap();
    drop(second);
}

#[test]
fn recover_unknown_mint_is_not_a_silent_success() {
    let (_dir, path) = temp_db();
    let mut handle = open_handle([13u8; 64], &path);
    let unknown = parse_mint_url("https://mint.example.com").unwrap();
    let err = block_on(handle.recover(Some(&unknown))).unwrap_err();
    assert_eq!(err.status, CdkStatus::MintNotRegistered);
}

// ---------------------------------------------------------------------------
// Mint URL policy
// ---------------------------------------------------------------------------

#[test]
fn parse_mint_url_accepts_https_and_loopback_http() {
    for ok in [
        "https://mint.example.com",
        "https://mint.example.com/path",
        "http://localhost:3338",
        "http://127.0.0.1:3338",
        "http://[::1]:3338",
    ] {
        assert!(
            parse_mint_url(ok).is_ok(),
            "expected {ok} to be accepted, got {:?}",
            parse_mint_url(ok).err()
        );
    }
}

#[test]
fn parse_mint_url_rejects_policy_violations() {
    for bad in [
        "http://mint.example.com",          // plain http off-loopback
        "ftp://mint.example.com",           // unsupported scheme
        "https://user:pw@mint.example.com", // credentials
        "https://user@mint.example.com",    // credentials
        "https://mint.example.com?x=1",     // query string
        "https://mint.example.com#frag",    // fragment
        "not a url",                        // garbage
        "",
    ] {
        let err = parse_mint_url(bad).unwrap_err();
        assert_eq!(err.status, CdkStatus::InvalidMintUrl, "for input {bad:?}");
    }
}

#[test]
fn parse_mint_url_normalizes_matches_minturl() {
    // The accepted URL must also parse as a CDK `MintUrl` (the type used as the
    // database key), so the wrapper and CDK agree on identity.
    let parsed = parse_mint_url("https://mint.example.com").unwrap();
    assert_eq!(
        parsed,
        cdk::mint_url::MintUrl::from_str("https://mint.example.com").unwrap()
    );
}

// ---------------------------------------------------------------------------
// Secret redaction
// ---------------------------------------------------------------------------

#[test]
fn secret_types_do_not_debug_print_tokens() {
    const SECRET: &str = "cashuB_super_secret_bearer_token";

    let send = crate::status::CdkSendResult {
        status: CdkStatus::Ok,
        error: None,
        token: crate::status::string_to_box(SECRET.to_string()),
        operation_id: [1u8; 16],
        sender_fee_sats: 0,
    };
    let rendered = format!("{send:?}");
    assert!(!rendered.contains(SECRET), "send token leaked: {rendered}");
    assert!(rendered.contains("redacted"));

    let pending = crate::status::CdkPendingToken {
        operation_id: [2u8; 16],
        token: crate::status::string_to_box(SECRET.to_string()).unwrap(),
    };
    let rendered = format!("{pending:?}");
    assert!(
        !rendered.contains(SECRET),
        "pending token leaked: {rendered}"
    );

    let string = crate::status::CdkStringResult {
        status: CdkStatus::Ok,
        error: None,
        value: crate::status::string_to_box(SECRET.to_string()),
    };
    let rendered = format!("{string:?}");
    assert!(
        !rendered.contains(SECRET),
        "string value leaked: {rendered}"
    );
}

#[test]
fn string_to_box_replaces_interior_nul_without_dropping() {
    let converted = crate::status::string_to_box("before\0after".to_string()).unwrap();
    assert_eq!(converted.to_str(), "before\u{FFFD}after");
}

// ---------------------------------------------------------------------------
// Panic guard
// ---------------------------------------------------------------------------

#[test]
fn panic_guard_poisons_handle_and_close_still_works() {
    let (_dir, path) = temp_db();
    let path_str = path.to_str().unwrap().to_string();
    let mut handle = open_handle([21u8; 64], &path);

    // Force a panic inside the guard.
    let res = crate::api::cdk_test_panic(Some(&mut handle));
    assert_eq!(res.status, CdkStatus::InternalError);

    // The handle is now poisoned: further calls fail closed.
    let res = crate::api::cdk_wallet_list_mints(Some(&handle));
    assert_eq!(res.status, CdkStatus::InternalError);

    // Close still consumes the handle and releases the lock.
    let boxed: repr_c::Box<CdkWallet> = Box::new(handle).into();
    let closed = crate::api::cdk_wallet_close(Some(boxed));
    assert_eq!(closed.status, CdkStatus::Ok);

    // The lock is released, so reopening works.
    let (reopened, _reports) = block_on(CdkWallet::open(&[21u8; 64], &path_str)).unwrap();
    drop(reopened);
}

// ---------------------------------------------------------------------------
// C ABI argument validation
// ---------------------------------------------------------------------------

#[test]
fn abi_rejects_invalid_utf8_arguments() {
    let (_dir, path) = temp_db();
    let path_str = path.to_str().unwrap().to_string();
    let seed = [31u8; 64];

    // Invalid UTF-8 path.
    let bad_path = cstr_ref(b"\xff\xfe\0");
    let opened = crate::api::cdk_wallet_open(Some(slice_ref(&seed)), Some(bad_path));
    assert_eq!(opened.status, CdkStatus::InvalidArgument);
    assert!(opened.handle.is_none());

    let mut handle = open_handle(seed, Path::new(&path_str));
    let bad = cstr_ref(b"\xff\0");

    // Invalid UTF-8 mint URL and token.
    let add = crate::api::cdk_wallet_add_mint(Some(&mut handle), Some(bad));
    assert_eq!(add.status, CdkStatus::InvalidArgument);

    let recv = crate::api::cdk_wallet_receive(Some(&mut handle), Some(bad));
    assert_eq!(recv.status, CdkStatus::InvalidArgument);
}

#[test]
fn abi_rejects_null_required_strings_on_valid_handle() {
    let (_dir, path) = temp_db();
    let mut handle = open_handle([32u8; 64], &path);

    let add = crate::api::cdk_wallet_add_mint(Some(&mut handle), None);
    assert_eq!(add.status, CdkStatus::NullArgument);

    let recv = crate::api::cdk_wallet_receive(Some(&mut handle), None);
    assert_eq!(recv.status, CdkStatus::NullArgument);

    let send = crate::api::cdk_wallet_send(Some(&mut handle), None, 1, 0);
    assert_eq!(send.status, CdkStatus::NullArgument);

    let pending = crate::api::cdk_wallet_get_pending_token(Some(&handle), None);
    assert_eq!(pending.status, CdkStatus::NullArgument);
}

#[test]
fn abi_rejects_bad_seed_and_operation_id_lengths() {
    let (_dir, path) = temp_db();
    let path_str = path.to_str().unwrap().to_string();

    let short = [0u8; 63];
    let opened = crate::api::cdk_wallet_open(
        Some(slice_ref(&short)),
        Some(cstr_ref(&with_nul(&path_str))),
    );
    assert_eq!(opened.status, CdkStatus::InvalidSeed);

    let handle = open_handle([33u8; 64], Path::new(&path_str));
    let short_id = [0u8; 4];
    let pending =
        crate::api::cdk_wallet_get_pending_token(Some(&handle), Some(slice_ref(&short_id)));
    assert_eq!(pending.status, CdkStatus::InvalidArgument);
}

#[test]
fn abi_rejects_out_of_range_send_arguments_locally() {
    let (_dir, path) = temp_db();
    let mut handle = open_handle([34u8; 64], &path);
    let mint = cstr_ref(b"https://mint.example.com\0");

    // Zero amount is rejected before any network use.
    let send = crate::api::cdk_wallet_send(Some(&mut handle), Some(mint), 0, 0);
    assert_eq!(send.status, CdkStatus::InvalidArgument);

    // Amount and fee above `i64::MAX` are rejected locally.
    let send = crate::api::cdk_wallet_send(Some(&mut handle), Some(mint), u64::MAX, 0);
    assert_eq!(send.status, CdkStatus::InvalidArgument);

    let send = crate::api::cdk_wallet_send(Some(&mut handle), Some(mint), 1, u64::MAX);
    assert_eq!(send.status, CdkStatus::InvalidArgument);
}

#[test]
fn abi_rejects_oversized_token_before_parsing() {
    let (_dir, path) = temp_db();
    let mut handle = open_handle([35u8; 64], &path);

    let mut big = vec![b'a'; MAX_TOKEN_BYTES + 1];
    big.push(0);
    let oversized = cstr_ref(&big);

    let recv = crate::api::cdk_wallet_receive(Some(&mut handle), Some(oversized));
    assert_eq!(recv.status, CdkStatus::InvalidArgument);
}

#[test]
fn abi_free_helpers_accept_empty_values() {
    // Freeing empty Rust-owned values is a safe no-op (mirrors the C contract).
    crate::api::cdk_string_free(None);
    // An empty string is the crate's shared empty sentinel: freeing it must not
    // touch a real allocation.
    crate::api::cdk_string_free(crate::status::string_to_box(String::new()));
    crate::api::cdk_bytes_free(repr_c::Vec::from(Vec::new()));
    crate::api::cdk_mint_list_free(repr_c::Vec::from(Vec::new()));
    crate::api::cdk_balance_list_free(repr_c::Vec::from(Vec::new()));
    crate::api::cdk_pending_list_free(repr_c::Vec::from(Vec::new()));
    crate::api::cdk_recovery_reports_free(repr_c::Vec::from(Vec::new()));
}

// ---------------------------------------------------------------------------
// BIP-39 mnemonic helpers
// ---------------------------------------------------------------------------

/// Published BIP-39 test vector: the phrase for 16 zero bytes of entropy.
const VECTOR_12_WORDS: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
/// The BIP-39 seed for `VECTOR_12_WORDS` with an empty passphrase.
const VECTOR_12_SEED_HEX: &str = "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4";

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Free a bytes result through the ABI and return a copy of its payload.
fn take_bytes(result: crate::status::CdkBytesResult) -> Vec<u8> {
    crate::api::cdk_string_free(result.error);
    let copy = result.bytes.to_vec();
    crate::api::cdk_bytes_free(result.bytes);
    copy
}

#[test]
fn generate_mnemonic_yields_a_valid_12_word_english_phrase() {
    let generated = crate::api::cdk_generate_mnemonic();
    assert_eq!(generated.status, CdkStatus::Ok);
    let phrase_box = generated.value.expect("a generated phrase");
    let phrase = phrase_box.to_str().to_owned();
    crate::api::cdk_string_free(Some(phrase_box));

    // 12 words, all non-empty, and the phrase parses (word count + checksum).
    let words: Vec<&str> = phrase.split_whitespace().collect();
    assert_eq!(words.len(), 12);
    assert!(words.iter().all(|w| !w.is_empty()));

    // 12 words -> 16 bytes of entropy.
    let entropy = crate::api::cdk_mnemonic_to_entropy(Some(cstr_ref(&with_nul(&phrase))));
    assert_eq!(entropy.status, CdkStatus::Ok);
    assert_eq!(take_bytes(entropy).len(), 16);

    // -> always a 64-byte wallet seed.
    let seed = crate::api::cdk_mnemonic_to_seed(Some(cstr_ref(&with_nul(&phrase))));
    assert_eq!(seed.status, CdkStatus::Ok);
    assert_eq!(take_bytes(seed).len(), 64);
}

#[test]
fn mnemonic_helpers_match_the_published_12_word_vector() {
    let phrase = with_nul(VECTOR_12_WORDS);

    let entropy = crate::api::cdk_mnemonic_to_entropy(Some(cstr_ref(&phrase)));
    assert_eq!(entropy.status, CdkStatus::Ok);
    let entropy = take_bytes(entropy);
    assert_eq!(entropy.len(), 16, "12 words encode 16 bytes of entropy");
    assert_eq!(entropy, vec![0u8; 16]);

    let seed = crate::api::cdk_mnemonic_to_seed(Some(cstr_ref(&phrase)));
    assert_eq!(seed.status, CdkStatus::Ok);
    let seed = take_bytes(seed);
    assert_eq!(seed.len(), 64, "the derived wallet seed is always 64 bytes");
    assert_eq!(hex(&seed), VECTOR_12_SEED_HEX);
}

#[test]
fn mnemonic_helpers_match_the_published_24_word_vector() {
    // 32 zero bytes of entropy encode to 24 English words ending in "art".
    let mut words = vec!["abandon"; 23];
    words.push("art");
    let phrase = with_nul(&words.join(" "));

    let entropy = crate::api::cdk_mnemonic_to_entropy(Some(cstr_ref(&phrase)));
    assert_eq!(entropy.status, CdkStatus::Ok);
    let entropy = take_bytes(entropy);
    assert_eq!(entropy.len(), 32, "24 words encode 32 bytes of entropy");
    assert_eq!(entropy, vec![0u8; 32]);

    let seed = crate::api::cdk_mnemonic_to_seed(Some(cstr_ref(&phrase)));
    assert_eq!(seed.status, CdkStatus::Ok);
    assert_eq!(take_bytes(seed).len(), 64);
}

#[test]
fn mnemonic_helpers_reject_invalid_input_without_echoing_the_phrase() {
    // NULL.
    let null = crate::api::cdk_mnemonic_to_entropy(None);
    assert_eq!(null.status, CdkStatus::NullArgument);
    assert_eq!(take_bytes(null).len(), 0);

    let null = crate::api::cdk_mnemonic_to_seed(None);
    assert_eq!(null.status, CdkStatus::NullArgument);
    assert_eq!(take_bytes(null).len(), 0);

    // Invalid UTF-8.
    let utf8 = crate::api::cdk_mnemonic_to_seed(Some(cstr_ref(b"\xff\xfe\0")));
    assert_eq!(utf8.status, CdkStatus::InvalidArgument);
    assert_eq!(take_bytes(utf8).len(), 0);

    // Oversized (over the documented bound) is rejected before parsing.
    let mut oversized = vec![b'a'; crate::api::MAX_MNEMONIC_BYTES + 1];
    oversized.push(0);
    let big = crate::api::cdk_mnemonic_to_entropy(Some(cstr_ref(&oversized)));
    assert_eq!(big.status, CdkStatus::InvalidArgument);
    assert_eq!(take_bytes(big).len(), 0);

    // Unknown word, wrong checksum, wrong word count, and empty all map to
    // `InvalidArgument`, carry an error, and never echo the phrase.
    for bad in [
        // 12x "abandon": valid words but a bad checksum.
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon",
        // 11 words: invalid count.
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon",
        // Unknown word ("zzzz" is not in the English word list).
        "zzzz abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        "",
    ] {
        let result = crate::api::cdk_mnemonic_to_seed(Some(cstr_ref(&with_nul(bad))));
        assert_eq!(result.status, CdkStatus::InvalidArgument, "input {bad:?}");
        assert!(result.error.is_some(), "input {bad:?} must explain itself");
        let message = result.error.as_ref().unwrap().to_str().to_owned();
        assert!(
            !message.contains("abandon") && !message.contains("zzzz"),
            "error echoed the phrase for input {bad:?}: {message}"
        );
        assert_eq!(take_bytes(result).len(), 0, "input {bad:?}");
    }
}

#[test]
fn bytes_result_debug_is_redacted() {
    let result = crate::api::cdk_mnemonic_to_entropy(Some(cstr_ref(&with_nul(VECTOR_12_WORDS))));
    assert_eq!(result.status, CdkStatus::Ok);
    let rendered = format!("{result:?}");
    assert!(
        rendered.contains("<redacted"),
        "payload not redacted: {rendered}"
    );
    // The vector's payload is 16 zero bytes; the debug output must not dump it.
    assert!(!rendered.contains("0, 0"), "payload leaked: {rendered}");
    assert_eq!(take_bytes(result).len(), 16);
}

// ---------------------------------------------------------------------------
// Spilman primitives
// ---------------------------------------------------------------------------

/// Take the two hex strings out of a successful keypair result.
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

/// Take the value out of a successful string result.
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
fn spilman_keypair_and_ecdh_symmetry() {
    let (alice_secret, alice_public) = take_keypair(crate::spilman::cdk_spilman_generate_keypair());
    let (charlie_secret, charlie_public) =
        take_keypair(crate::spilman::cdk_spilman_generate_keypair());

    assert_ne!(alice_secret, charlie_secret, "keys must be fresh");
    assert_eq!(
        alice_public.len(),
        66,
        "a compressed secp256k1 public key is 33 bytes"
    );
    assert_eq!(charlie_public.len(), 66);

    // The standalone pubkey helper must agree with the keypair helper.
    let derived = take_string(crate::spilman::cdk_spilman_secret_key_to_pubkey(Some(
        cstr_ref(&with_nul(&alice_secret)),
    )));
    assert_eq!(derived, alice_public);

    // ECDH is symmetric: both sides derive the same channel secret.
    let from_alice = take_string(crate::spilman::cdk_spilman_compute_channel_secret(
        Some(cstr_ref(&with_nul(&alice_secret))),
        Some(cstr_ref(&with_nul(&charlie_public))),
    ));
    let from_charlie = take_string(crate::spilman::cdk_spilman_compute_channel_secret(
        Some(cstr_ref(&with_nul(&charlie_secret))),
        Some(cstr_ref(&with_nul(&alice_public))),
    ));
    assert_eq!(from_alice, from_charlie);
    assert_eq!(from_alice.len(), 64, "the channel secret is 32 bytes hex");
}

#[test]
fn spilman_debug_redacts_secrets() {
    let (secret, _public) = take_keypair(crate::spilman::cdk_spilman_generate_keypair());

    let keypair = crate::status::CdkSpilmanKeypairResult {
        status: CdkStatus::Ok,
        error: None,
        secret_key_hex: crate::status::string_to_box(secret.clone()),
        pubkey_hex: crate::status::string_to_box("02".repeat(33)),
    };
    let rendered = format!("{keypair:?}");
    assert!(rendered.contains("<redacted>"), "not redacted: {rendered}");
    assert!(!rendered.contains(&secret), "secret leaked: {rendered}");
    crate::api::cdk_string_free(keypair.secret_key_hex);
    crate::api::cdk_string_free(keypair.pubkey_hex);

    let close = crate::status::CdkSpilmanCloseResult {
        status: CdkStatus::Ok,
        error: None,
        receiver_proofs_json: crate::status::string_to_box(
            r#"[{"secret":"deadbeef"}]"#.to_string(),
        ),
        sender_proofs_json: crate::status::string_to_box("[]".to_string()),
        receiver_sum: 7,
        sender_sum: 0,
    };
    let rendered = format!("{close:?}");
    assert!(rendered.contains("<redacted>"), "not redacted: {rendered}");
    assert!(!rendered.contains("deadbeef"), "proofs leaked: {rendered}");
    assert!(rendered.contains('7'), "sums must stay visible: {rendered}");
    crate::api::cdk_string_free(close.receiver_proofs_json);
    crate::api::cdk_string_free(close.sender_proofs_json);
}

#[test]
fn spilman_null_and_invalid_inputs_rejected() {
    // NULL secret key.
    let result = crate::spilman::cdk_spilman_secret_key_to_pubkey(None);
    assert_eq!(result.status, CdkStatus::NullArgument);
    assert!(result.error.is_some());
    assert!(result.value.is_none());
    crate::api::cdk_string_free(result.error);

    // Malformed secret key hex must be rejected and never echoed back.
    let result =
        crate::spilman::cdk_spilman_secret_key_to_pubkey(Some(cstr_ref(&with_nul("not-hex"))));
    assert_eq!(result.status, CdkStatus::InvalidArgument);
    let message = result.error.as_ref().unwrap().to_str().to_owned();
    assert!(!message.contains("not-hex"), "echoed input: {message}");
    crate::api::cdk_string_free(result.error);

    // ECDH with a NULL peer key.
    let result = crate::spilman::cdk_spilman_compute_channel_secret(
        Some(cstr_ref(&with_nul(&"11".repeat(32)))),
        None,
    );
    assert_eq!(result.status, CdkStatus::NullArgument);
    crate::api::cdk_string_free(result.error);

    // An oversized hex argument is rejected before decoding.
    let oversized = "ab".repeat(600);
    let result =
        crate::spilman::cdk_spilman_secret_key_to_pubkey(Some(cstr_ref(&with_nul(&oversized))));
    assert_eq!(result.status, CdkStatus::InvalidArgument);
    crate::api::cdk_string_free(result.error);

    // Pure token builder with NULL inputs.
    let result = crate::spilman::cdk_spilman_build_cashu_a_token(None, None);
    assert_eq!(result.status, CdkStatus::NullArgument);
    crate::api::cdk_string_free(result.error);

    // A NULL wallet handle is reported as such, not as a panic.
    let result = crate::spilman::cdk_wallet_get_active_keyset_info_json(
        None,
        Some(cstr_ref(&with_nul("https://example.com"))),
    );
    assert_eq!(result.status, CdkStatus::NullArgument);
    crate::api::cdk_string_free(result.error);

    // `generate_keypair` takes no input and always succeeds.
    let (secret, public) = take_keypair(crate::spilman::cdk_spilman_generate_keypair());
    assert!(!secret.is_empty());
    assert!(!public.is_empty());
}
