//! Compile-time onboarding mint policy. The fixture feature is test-only.

#[cfg(not(feature = "local-mint-fixture"))]
pub(crate) fn allowed(mint: &str, _origin: &str) -> bool {
    mint == "https://mint.minibits.cash/Bitcoin"
}

#[cfg(feature = "local-mint-fixture")]
pub(crate) fn allowed(mint: &str, origin: &str) -> bool {
    let Some(port) = origin.strip_prefix("http://127.0.0.1:") else {
        return false;
    };
    let Ok(number) = port.parse::<u16>() else {
        return false;
    };
    number != 0
        && port == number.to_string()
        && (mint == origin || mint.strip_suffix('/') == Some(origin))
}
