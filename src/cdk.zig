//! Zig bindings for the vendored `cdk-wallet-ffi` C ABI.
//!
//! The C header is generated from the Rust crate with
//! `cargo run --features headers --bin generate-headers` and must stay in sync
//! (see the `header-check` build step). The build system translates it to the
//! `cdk_c` module with `b.addTranslateC`, because Zig 0.17 no longer provides
//! `@cImport`. Everything the C ABI exposes is available under `cdk.c`.
//!
//! ## Ownership and threading (important)
//!
//! * `CdkWallet_t` is an opaque, initialized handle. It is *not* thread-safe:
//!   the caller must serialize every call that uses the same handle.
//! * Every Rust-owned string, byte payload, or list returned by this ABI must be
//!   freed with the matching `cdk_*_free` function from the same library. Never
//!   hand these pointers to Zig's allocator.
//! * All calls are blocking (they drive a shared Tokio runtime internally), so
//!   call them from a dedicated worker thread, never from the UI thread.
const std = @import("std");

/// The generated C header, translated to Zig by the build system.
pub const c = @import("cdk_c");

/// The seed length, in bytes, required by `cdk_wallet_open`.
pub const seed_len = 64;

/// Convenience: a C slice header over a Zig byte slice.
///
/// The slice must outlive the call it is passed to (all calls are synchronous,
/// so a stack slice is fine).
pub fn byteSlice(bytes: []const u8) c.slice_ref_uint8_t {
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}
