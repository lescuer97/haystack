# CDK wallet bindings for the Zig app

This document covers the **Zig side** of the vendored
[`vendor/cdk-wallet-ffi`](../vendor/cdk-wallet-ffi/README.md) library: how it is
wired into `build.zig`, how to import it, and the rules you must follow when
calling it. Read the crate README first for the ABI, ownership, security, and
recovery semantics.

---

## Importing

The desktop build graph exposes a public module named `cdk`:

```zig
const cdk = @import("cdk");
const c = cdk.c;              // the translated C ABI
```

* `cdk.c` is the generated C header (`vendor/cdk-wallet-ffi/include/cdk_wallet.h`)
  translated to Zig.
* `cdk.seed_len` is `64`.
* `cdk.byteSlice(bytes)` builds a `slice_ref_uint8_t` header over a byte slice.
* `cdk_generate_mnemonic` / `cdk_mnemonic_to_seed` produce a BIP-39 phrase and
  the 64-byte seed `cdk_wallet_open` needs (see the mnemonic example below).

The main application already imports it (see the `exe` in `build.zig`), and the
C-ABI consumer test (`src/wallet_test.zig`) is a complete, runnable example.

---

## Build steps

For the working experimental browser wallet, see
[browser build, runtime tests, and limitations](browser-wallet.md). It shares the
wallet/Spilman implementation but exposes an async JS API, not this native C ABI.
The [initial WebAssembly investigation](webassembly.md) documents the separate
native-crate cross-compilation probe, which is still expected to fail.

| Command | What it does |
| --- | --- |
| `zig build` | Builds the app, the Rust staticlib, and links both. |
| `zig build test` | The pre-existing application tests. |
| `zig build wallet` | Builds only the Rust `staticlib` (release, `--locked`). |
| `zig build test-wallet` | Runs the Rust suite **and** the Zig C-ABI consumer test. |
| `zig build header-check` | Fails if the committed C header is stale. |

The desktop graph provisions pinned Rust 1.99.0, builds the native archive for an
explicit matching host target, and selects Cargo's debug/release profile from
`-Doptimize`. `header-check` runs `generate-headers -- --check`. Desktop artifacts
go under `zig-out/desktop`, independently of the Wasm graph. See [build.md](build.md).

---

## Threading

Every call **blocks** the calling thread while it drives a shared Tokio runtime.
Call the ABI from a dedicated worker thread and **serialize all calls that use
the same handle**; never call it from the UI/render thread, and never free a
handle while a call is in flight.

```zig
// Sketch: a single worker thread owns the handle and a command queue.
const Worker = struct {
    handle: *c.CdkWallet_t,

    fn run(self: *Worker) void {
        while (nextCommand()) |cmd| {
            switch (cmd) {
                .receive => |token| {
                    const res = c.cdk_wallet_receive(self.handle, token.ptr);
                    defer if (res.@"error") |e| c.cdk_string_free(e);
                    // ... report res.status / res.net_sats back to the UI ...
                },
                // ...
            }
        }
    }
};
```

---

## Example: open, approve a mint, send, receive

```zig
const std = @import("std");
const cdk = @import("cdk");
const c = cdk.c;

fn errString(e: [*c]const u8) []const u8 {
    return if (e == null) "" else std.mem.span(@as([*:0]const u8, @ptrCast(e)));
}

pub fn main() !void {
    // The application owns seed generation, backup, and secure storage. This
    // example takes an already-provisioned 64-byte seed; generate it with the
    // application's secure source (for example `std.Io`'s randomness APIs).
    var seed: [cdk.seed_len]u8 = try loadOrCreateSeed();

    const opened = c.cdk_wallet_open(cdk.byteSlice(&seed), "/var/lib/app/wallet.sqlite");
    // Free the owned error/report payloads on every path, including the failure
    // path below (a `defer` only runs for the scope that registered it, so it
    // must be registered immediately after the call).
    defer if (opened.@"error") |e| c.cdk_string_free(e);
    defer c.cdk_recovery_reports_free(opened.reports);
    if (opened.status != c.CDK_STATUS_OK) {
        std.debug.print("open failed: {s}\n", .{errString(opened.@"error")});
        return;
    }
    const handle: ?*c.CdkWallet_t = opened.handle;

    // Close (and consume) the handle on every exit path. `close` returns its own
    // owned error string, so free that as well.
    defer {
        const closed = c.cdk_wallet_close(handle);
        if (closed.@"error") |e| c.cdk_string_free(e);
    }

    // Startup recovery reports live in opened.reports (one entry per approved
    // Sat mint) and are freed by the defer above. skipped > 0 or failed > 0
    // means the corresponding mint is fail-closed until an explicit recovery
    // succeeds.

    // Approve a mint (first add fetches mint info over the network).
    const add = c.cdk_wallet_add_mint(handle, "https://mint.example.com".ptr);
    defer if (add.@"error") |e| c.cdk_string_free(e);
    if (add.status != c.CDK_STATUS_OK) return error.MintNotApproved;

    // Send 1000 sats from that mint, allowing at most 5 sats of sender fee.
    const sent = c.cdk_wallet_send(handle, "https://mint.example.com".ptr, 1000, 5);
    defer if (sent.@"error") |e| c.cdk_string_free(e);
    switch (sent.status) {
        c.CDK_STATUS_OK => {
            if (sent.token) |token| { // bearer secret!
                defer c.cdk_string_free(token);
                // hand `token` to the recipient...
            }
        },
        c.CDK_STATUS_FEE_LIMIT_EXCEEDED => {},
        c.CDK_STATUS_SEND_UNCERTAIN => {
            // Do NOT retry blindly. Run cdk_wallet_recover later.
        },
        else => {},
    }

    // Receive a token; the return value is the net spendable sats.
    const recv = c.cdk_wallet_receive(handle, "cashuB...".ptr);
    defer if (recv.@"error") |e| c.cdk_string_free(e);
    const credited = if (recv.status == c.CDK_STATUS_OK) recv.net_sats else 0;
    _ = credited;
}
```

Key rules shown above:

* Free every `error` and payload with the matching `cdk_*_free` function — never
  with the Zig allocator. Nested payloads (like `opened.reports`) are owned too
  and have their own free helper (`cdk_recovery_reports_free`).
* `cdk_wallet_close` consumes the handle even on error.
* Tokens are secrets: do not log them.
* Result structs are opaque: never `memcmp`, hash, or raw-serialize them. Read
  their named fields only — padding and internal layout are unspecified.

---

## Example: mnemonic → seed → wallet

The ABI can generate a BIP-39 phrase and derive the 64-byte wallet seed that
`cdk_wallet_open` needs. The phrase, its entropy, and the derived seed are all
secrets: never log or persist them here — the application owns backup and secure
storage.

```zig
const std = @import("std");
const cdk = @import("cdk");
const c = cdk.c;

pub fn main() !void {
    // 1. Generate a 12-word English phrase (128-bit entropy). The owned string
    //    is scrubbed by cdk_string_free.
    const generated = c.cdk_generate_mnemonic();
    defer if (generated.@"error") |e| c.cdk_string_free(e);
    defer c.cdk_string_free(generated.value);
    if (generated.status != c.CDK_STATUS_OK) return error.NoMnemonic;
    // `generated.value` is the phrase: show it to the user for offline backup,
    // never write it to a log or a file.

    // 2. Derive the 64-byte wallet seed (empty BIP-39 passphrase, CDK default).
    const derived = c.cdk_mnemonic_to_seed(generated.value);
    defer if (derived.@"error") |e| c.cdk_string_free(e);
    defer c.cdk_bytes_free(derived.bytes);
    if (derived.status != c.CDK_STATUS_OK) return error.BadMnemonic;
    if (derived.bytes.len != cdk.seed_len) return error.UnexpectedSeedLength;

    // 3. Open the wallet with the derived seed. Do NOT pass the 16 bytes from
    //    cdk_mnemonic_to_entropy here — open needs the 64-byte seed.
    const opened = c.cdk_wallet_open(
        cdk.byteSlice(derived.bytes.ptr[0..cdk.seed_len]),
        "/var/lib/app/wallet.sqlite",
    );
    defer if (opened.@"error") |e| c.cdk_string_free(e);
    defer c.cdk_recovery_reports_free(opened.reports);
    if (opened.status != c.CDK_STATUS_OK) return error.OpenFailed;
    defer {
        const closed = c.cdk_wallet_close(opened.handle);
        if (closed.@"error") |e| c.cdk_string_free(e);
    }

    // 4. Restoring an existing wallet is the same flow: take the phrase from the
    //    user (or secure storage) and run cdk_mnemonic_to_seed -> cdk_wallet_open.
}
```

Rules:

* `cdk_generate_mnemonic` returns a 12-word English phrase and has **no**
  deterministic RNG fallback (an RNG failure is `INTERNAL_ERROR`).
* `cdk_mnemonic_to_seed` always returns 64 bytes; `cdk_mnemonic_to_entropy`
  returns 16/20/24/28/32 bytes depending on the phrase length.
* Conversion accepts any valid English phrase (12/15/18/21/24 words) and verifies
  word count + checksum; failures are `INVALID_ARGUMENT` with a static message
  that never echoes the phrase. A `NULL` phrase is `NULL_ARGUMENT`.
* Free the phrase with `cdk_string_free` and byte payloads with
  `cdk_bytes_free`; both scrub the bytes first, and `NULL`/empty are safe no-ops.
* Mnemonic **storage, backup, and restore** remain out of scope — the app decides
  how (and whether) to persist the phrase. Wallets created with a non-empty
  BIP-39 passphrase are not supported.

---

## Spilman payment channels

The library also exposes the Spilman payment-channel primitives and the CDK
conversion helpers the Zig side needs to drive a channel end to end. These are
plain ABI functions (they appear in `cdk.c` like everything else); they never
touch the network unless they take a wallet handle.

### Wallet-backed helpers

These need a live `CdkWallet_t` and a mint that has already been approved with
`cdk_wallet_add_mint`:

| Function | Returns | Notes |
| --- | --- | --- |
| `cdk_wallet_get_active_keyset_info_json(handle, mint_url)` | `CdkStringResult` | Active Sat keyset as Spilman `KeysetInfo` JSON (`keysetId`, `unit`, `keys`, `amounts`, `inputFeePpk`, `finalExpiry`). |
| `cdk_wallet_get_keyset_info_json(handle, mint_url, keyset_id)` | `CdkStringResult` | A single keyset by id. |
| `cdk_wallet_post_swap(handle, mint_url, swap_request_json)` | `CdkStringResult` | Posts a raw NUT-03 `SwapRequest` and returns the raw response. Stateless: it does not persist proofs. |
| `cdk_wallet_receive_with_keys(handle, token, signing_key_hex)` | `CdkReceiveResult` | `cdk_wallet_receive` with P2PK signing keys. |
| `cdk_wallet_receive_proofs(handle, mint_url, proofs_json, signing_key_hex)` | `CdkReceiveResult` | Receives already-parsed proofs (for example the receiver proofs from a close). |

`signing_key_hex` is an optional comma-separated list of 32-byte hex secret
keys; `NULL` or an empty string means "no keys". `cdk_wallet_receive` is
`cdk_wallet_receive_with_keys` with no keys.

### Pure conversion helpers

These take and return strings only — no handle, no network:

| Area | Functions |
| --- | --- |
| Token ⇄ proofs | `cdk_spilman_build_cashu_b_token`, `cdk_spilman_build_cashu_a_token`, `cdk_token_to_proofs_json` |
| Key material | `cdk_spilman_generate_keypair`, `cdk_spilman_secret_key_to_pubkey`, `cdk_spilman_compute_channel_secret`, `cdk_spilman_sign_with_tweaked_key_util` |
| Channel setup | `cdk_spilman_compute_funding_token_amount`, `cdk_spilman_compute_channel_from_token`, `cdk_spilman_channel_parameters_get_channel_id`, `cdk_spilman_create_funding_outputs`, `cdk_spilman_create_funding_swap`, `cdk_spilman_complete_funding_swap`, `cdk_spilman_construct_proofs` |
| Balance updates | `cdk_spilman_create_signed_balance_update`, `cdk_spilman_create_unsigned_balance_update`, `cdk_spilman_attach_signature_to_balance_update`, `cdk_spilman_verify_valid_channel`, `cdk_spilman_verify_balance_update` |
| Cooperative close | `cdk_spilman_prepare_close_swap`, `cdk_spilman_unblind_close_swap` |
| Post-expiry refund | `cdk_spilman_prepare_sender_refund`, `cdk_spilman_complete_sender_refund` |

The typical funding flow is: mint a token → `cdk_spilman_compute_channel_from_token`
→ `cdk_spilman_create_funding_swap` → `cdk_wallet_post_swap` →
`cdk_spilman_complete_funding_swap`. The cooperative close is:
`cdk_spilman_create_signed_balance_update` → `cdk_spilman_prepare_close_swap` →
`cdk_wallet_post_swap` → `cdk_spilman_unblind_close_swap`. The post-expiry refund
is: `cdk_spilman_prepare_sender_refund` → `cdk_wallet_post_swap` →
`cdk_spilman_complete_sender_refund`.

### Result types and rules

Two Spilman-specific result structs join the existing ones:

* `CdkSpilmanKeypairResult { status, error, secret_key_hex, pubkey_hex }` — from
  `cdk_spilman_generate_keypair`.
* `CdkSpilmanCloseResult { status, error, receiver_proofs_json,
  sender_proofs_json, receiver_sum, sender_sum }` — from
  `cdk_spilman_unblind_close_swap`.

Both render secrets as `<redacted>` in `{:?}`; do **not** rely on `Debug` to
inspect them, and treat `secret_key_hex` and the proof JSON as bearer secrets.
Free every `error` and payload string with `cdk_string_free`; the `_sum` fields
are plain integers.

Other rules:

* All string inputs are length-bounded before any parse or allocation: JSON,
  tokens, and mint URLs up to 1 MiB; short hex values (keys, channel ids,
  signatures, tweak scalars) up to 256 bytes. Oversized or non-UTF-8 input is
  `INVALID_ARGUMENT`; a `NULL` required string is `NULL_ARGUMENT`.
* Secret-key and channel-secret hex inputs are zeroized inside Rust, but the
  caller owns its own copies: scrub them after the call.
* The helpers never echo secret material in an error message.
* `cdk_spilman_create_funding_outputs` takes only the parameters, the sender
  secret key, and the keyset: the receiver key is read from `params_json`,
  matching the upstream three-argument helper.

### Tests and deterministic fixtures

Two suites cover this surface:

* `vendor/cdk-wallet-ffi/src/{tests,e2e,fixtures}.rs` — Rust unit, policy, and
  fake-mint end-to-end tests.
* `src/spilman_test.zig` — offline Zig C-ABI integration tests, run by
  `zig build test-spilman` (also part of `zig build test-wallet`). They cover
  keyset/token JSON contracts, fee math, channel-id and funding-output
  determinism, secret redaction, argument validation, ABI struct layout,
  unapproved-mint guards, balance-update replay semantics, close-swap
  structure, and replay of real mint responses.

The replay tests consume `src/testdata/spilman_vectors.json`, which contains
real blind signatures and NUT-12 DLEQ proofs over deterministic blinded
outputs. It is generated by `vendor/cdk-wallet-ffi/src/fixtures.rs` through the
same exported functions the Zig code calls, so the two sides cannot drift
silently. If a vendored derivation change makes that test fail, regenerate:

```text
CDK_SPILMAN_WRITE_FIXTURES=1 \
  cargo +stable test --locked spilman_fixture -- --nocapture
```

`cargo +stable test` always recomputes the fixture and fails on any drift, so
the checked-in file cannot go stale unnoticed.

---

## Deviations from the original brief

* **Zig 0.17 removed `@cImport`.** `src/cdk.zig` therefore does **not** use
  `@cImport`. Instead, `build.zig` runs `b.addTranslateC` on the generated
  header to produce a `cdk_c` module, and `src/cdk.zig` re-exports it:

  ```zig
  pub const c = @import("cdk_c");
  ```

  This is the official replacement and keeps the same "one generated header"
  contract; `header-check` still guards freshness.
* **`libunwind` instead of `libgcc_s`.** The Rust staticlib is built with
  `panic = "unwind"` (needed for `catch_unwind` across the ABI), so `_Unwind_*`
  symbols must resolve. This host ships `libunwind.so` but no `libgcc_s.so` dev
  symlink, so the build links `unwind` (plus `pthread`, `dl`, `rt`, `util`, `m`).
  Do not copy Iroh's macOS `-lSystem` flags.
