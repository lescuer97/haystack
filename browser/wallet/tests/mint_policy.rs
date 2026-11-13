#[path = "../src/mint_policy.rs"]
mod mint_policy;

#[cfg(not(feature = "local-mint-fixture"))]
#[test]
fn production_only_accepts_exact_canonical_mint() {
    assert!(mint_policy::allowed(
        "https://mint.minibits.cash/Bitcoin",
        ""
    ));
    for mint in [
        "https://mint.minibits.cash/Bitcoin/",
        "https://mint.minibits.cash/bitcoin",
        "https://mint.minibits.cash/Bitcoin?x=1",
        "https://example.com",
        "http://127.0.0.1:1234/",
    ] {
        assert!(
            !mint_policy::allowed(mint, "http://127.0.0.1:1234"),
            "{mint}"
        );
    }
}

#[cfg(feature = "local-mint-fixture")]
#[test]
fn fixture_only_accepts_root_on_current_loopback_origin() {
    let origin = "http://127.0.0.1:1234";
    assert!(mint_policy::allowed(origin, origin));
    assert!(mint_policy::allowed("http://127.0.0.1:1234/", origin));
    for mint in [
        "https://mint.minibits.cash/Bitcoin",
        "http://127.0.0.1:1235/",
        "http://127.0.0.1:1234/path",
        "http://127.0.0.1:1234/?x=1",
        "http://127.0.0.1:1234/#x",
        "http://user@127.0.0.1:1234/",
        "http://localhost:1234/",
    ] {
        assert!(!mint_policy::allowed(mint, origin), "{mint}");
    }
    for invalid in [
        "http://127.0.0.1:0",
        "http://127.0.0.1:65536",
        "http://127.0.0.1:",
        "http://127.0.0.1:01234",
        "https://127.0.0.1:1234",
        "http://example.com:1234",
        "http://127.0.0.1:1234/path",
        "http://127.0.0.1:1234?x=1",
    ] {
        assert!(!mint_policy::allowed(invalid, invalid), "{invalid}");
    }
}
