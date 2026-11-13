//! Header generator for the `cdk-wallet-ffi` C ABI.
//!
//! Run with `cargo run --features headers --bin generate-headers` to (re)write
//! `include/cdk_wallet.h`, or pass `--check` to verify it is up to date.

fn main() -> std::io::Result<()> {
    let check = std::env::args().any(|arg| arg == "--check");
    if check {
        cdk_wallet_ffi::check_headers()?;
        println!(
            "header is up to date: {}",
            cdk_wallet_ffi::default_header_path().display()
        );
    } else {
        cdk_wallet_ffi::generate_headers()?;
        println!("wrote {}", cdk_wallet_ffi::default_header_path().display());
    }
    Ok(())
}
