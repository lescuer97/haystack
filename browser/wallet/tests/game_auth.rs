// The browser crate itself only builds on wasm32. Exercise its pure signer
// and the native/browser identity vector on the host as well.
#[path = "../src/game_auth.rs"]
mod game_auth;
