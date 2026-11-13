# `cdk-wallet-ffi`

A minimal, boring **C ABI** over a small subset of
[`cdk::wallet::WalletRepository`] (upstream CDK `0.18.3`), designed to be linked
into the Zig application as a Rust `staticlib`.

It is deliberately small: one SQLite database, one 64-byte seed, Sat-only
balances, explicit mint approval, BIP-39 mnemonic generation plus
entropy/seed derivation, and a handful of synchronous calls. Everything else
(Lightning, history, mnemonic storage/backup/restore, multi-unit,
callbacks/jobs/futures, other currencies, cross-mint operations) is out of scope.

[`cdk::wallet::WalletRepository`]: https://docs.rs/cdk/0.18.3/cdk/wallet/struct.WalletRepository.html

---

## Scope

Supported:

| Call | Purpose |
| --- | --- |
| `cdk_wallet_open` | Create/open the wrapper-owned database with a 64-byte seed. |
| `cdk_wallet_close` | Flush rate limits and destroy a handle. |
| `cdk_wallet_add_mint` | Durably approve a mint (network fetch on first add). |
| `cdk_wallet_list_mints` | List approved mints. |
| `cdk_wallet_list_balances` | List approved mints with locally spendable sats. |
| `cdk_wallet_receive` | Receive a token, returning the **net** spendable sats. |
| `cdk_wallet_send` | Send from one explicit mint, returning the bearer token. |
| `cdk_wallet_list_pending_tokens` | List outgoing tokens not yet claimed. |
| `cdk_wallet_get_pending_token` | Retrieve one pending token by operation id. |
| `cdk_wallet_recover` | Explicitly retry unresolved sagas (all mints or one). |
| `cdk_generate_mnemonic` | Generate a new 12-word English BIP-39 phrase. |
| `cdk_mnemonic_to_entropy` | Phrase → raw entropy (16/20/24/28/32 bytes). |
| `cdk_mnemonic_to_seed` | Phrase → 64-byte wallet seed (empty passphrase). |
| `cdk_string_free` | Free an owned string (scrubs it first). |
| `cdk_bytes_free` | Free an owned byte payload (scrubs it first). |
| `cdk_mint_list_free` | Free an owned mint list. |
| `cdk_balance_list_free` | Free an owned balance list. |
| `cdk_pending_list_free` | Free an owned pending-token list. |
| `cdk_recovery_reports_free` | Free an owned per-mint recovery-report vector. |

Explicitly **not** supported: Lightning, transaction history, mint/seed deletion,
mnemonic **storage / backup / restore** (the wallet-fund restore engine),
spending conditions / signing keys, currencies other than Sat,
callbacks/jobs/futures across the FFI boundary, and cross-compilation machinery.
Mnemonic *generation* and entropy/seed *conversion* **are** supported (see
[Mnemonics](#mnemonics-bip-39) below). There is **no** production test-mint or
test-funding export.

---

## Threading and blocking

Every exported call is **synchronous and blocking**. Internally it drives a
future on a single, process-wide, multi-threaded Tokio runtime created lazily
with `OnceLock` and never shut down.

* Call the ABI from a dedicated **worker thread**, never from the UI thread.
* A handle is **not** thread-safe: the caller must **serialize every call that
  uses the same handle**, and must not free a handle while a call is in flight.
* Do not call the ABI from inside another async runtime: it uses
  `Runtime::block_on`, which panics when nested. (This is also why the Rust
  tests are plain `#[test]`, not `#[tokio::test]`.)

### Deadlines

Upstream `bitreq` HTTP has **no timeout** of its own, so the wrapper bounds every
network-facing export with a documented deadline:

| Operation | Deadline |
| --- | --- |
| `add_mint`, `receive`, `send` (prepare / cancel / confirm) | `60s` (`NETWORK_DEADLINE`) |
| `recover` | `120s` (`RECOVERY_DEADLINE`) |

The deadline is implemented with `tokio::time::timeout` around the whole future.
Dropping the future cancels the in-flight request (bitreq's async transport uses
`AsyncTcpStream` and `PendingReader`, whose `Drop` closes the connection), so a
timeout does **not** leave a detached blocking request behind. `BITREQ_TIMEOUT`
is intentionally left unset.

For a **mutation**, hitting the deadline is treated as **crash-equivalent**: the
mint is marked unresolved and the caller gets `SendUncertain` / `NetworkError`.
The operation is **never retried automatically**; recovery must be run
explicitly. This avoids the classic "ambiguous send retried twice" bug.

---

## The ABI

The generated header is committed at [`include/cdk_wallet.h`](include/cdk_wallet.h)
and must be regenerated whenever the Rust sources change:

```sh
cargo run --features headers --bin generate-headers      # rewrite it
cargo run --features headers --bin generate-headers -- --check   # verify it
```

### Pointer and ownership contract

* `CdkWallet_t *` handles come **only** from `cdk_wallet_open` and are freed
  **only** by `cdk_wallet_close`. `cdk_wallet_close` consumes the handle even on
  error and returns a status.
* Owned strings (`char_p::Box`) are freed **only** by `cdk_string_free`.
* Owned lists are freed **only** by their matching `*_free` function.
* **Never** hand a Rust-owned pointer to another allocator, and never free the
  same pointer twice.
* Nullable arguments (`seed`, `db_path`, `mint_url`, `token`, `operation_id`)
  are modelled as `Option<...>` in Rust, so a `NULL` pointer (or, for a slice, a
  null data pointer) yields `CDK_STATUS_NULL_ARGUMENT` instead of undefined
  behaviour. A non-null pointer must still point at a valid, live object for the
  duration of the call; the wrapper cannot verify that.
* `cdk_wallet_open` requires a seed slice of **exactly 64 bytes**.
* Result structs are **opaque**: read their named fields only. Never `memcmp`,
  hash, or raw-serialize them — padding and internal layout are unspecified.

### Status codes

The numeric values are part of the ABI and must not be renumbered:

| Value | Name | Meaning |
| --- | --- | --- |
| 0 | `OK` | Success. |
| 1 | `NULL_ARGUMENT` | A required pointer argument was null. |
| 2 | `INVALID_ARGUMENT` | Structurally invalid argument. |
| 3 | `INVALID_SEED` | Seed was not exactly 64 bytes. |
| 4 | `INVALID_PATH` | Database path invalid or not creatable. |
| 5 | `ALREADY_OPEN` | The database is locked by another live handle. |
| 6 | `UNSUPPORTED_DATABASE` | Existing DB without the wrapper marker. |
| 7 | `SEED_MISMATCH` | Stored seed fingerprint does not match. |
| 8 | `UNSUPPORTED_FORMAT_VERSION` | Written by an incompatible wrapper version. |
| 9 | `INVALID_MINT_URL` | Rejected by URL policy. |
| 10 | `MINT_UNSUPPORTED_UNIT` | Mint does not advertise Sat. |
| 11 | `MINT_NOT_REGISTERED` | Mint not approved with this wallet. |
| 12 | `MINT_REGISTRATION_FAILED` | Registering the mint failed. |
| 13 | `NETWORK_ERROR` | Network operation failed. |
| 14 | `INSUFFICIENT_FUNDS` | Not enough locally spendable sats. |
| 15 | `FEE_LIMIT_EXCEEDED` | Sender fee would exceed the caller maximum. |
| 16 | `INVALID_TOKEN` | Token could not be parsed. |
| 17 | `UNSUPPORTED_TOKEN` | Multi-mint / wrong-unit token. |
| 18 | `TOKEN_UNKNOWN_MINT` | Token's mint is not approved. |
| 19 | `RECOVERY_PENDING` | Unresolved recovery state blocks this mint. |
| 20 | `SEND_FAILED` | Send definitively failed; no token exists. |
| 21 | `SEND_UNCERTAIN` | Send outcome unknown; **do not retry blindly**. |
| 22 | `RECEIVE_FAILED` | Receiving failed. |
| 23 | `DATABASE_ERROR` | Local database operation failed. |
| 24 | `INTERNAL_ERROR` | Unexpected internal error (including a caught panic). |
| 25 | `CANCELLATION_FAILED` | Over-fee send could not be cancelled; mint is fail-closed. |
| 26 | `OPERATION_NOT_FOUND` | No pending operation with that id. |
| 27 | `INSECURE_DATABASE_PERMISSIONS` | Pre-existing DB is group/other accessible; fix it, don't chmod silently. |

Every result struct carries its own `error` string (freed with
`cdk_string_free`). There is **no** global "last error" state, so concurrent
calls cannot race on diagnostics.

---

## Send / receive / fee semantics

`cdk_wallet_send(mint_url, amount_sats, max_sender_fee_sats)` is a single
one-shot call that internally does **prepare → check fee → confirm**:

1. Validate locally, before any network access: `amount_sats` must be non-zero,
   and `amount_sats` / `max_sender_fee_sats` must fit the signed integer storage
   used by SQLite (`i64`). Violations return `INVALID_ARGUMENT` locally.
2. Prepare a send using upstream's default `SendKind::OnlineExact` with
   `include_fee = false`. The requested `amount_sats` is therefore the **token
   face value**; the sender pays the fee on top.
3. Compare the prepared total fee (`prepared.fee()`, i.e. swap fee + send fee)
   against `max_sender_fee_sats`.
   * If it is over the limit, the send is **cancelled** and `FEE_LIMIT_EXCEEDED`
     is returned, preserving the operation id and the known fee. If cancellation
     itself fails, the mint is marked unresolved and `CANCELLATION_FAILED` is
     returned.
4. Confirm the send and return the bearer token, the operation id, and the
   actual `sender_fee_sats`.

Every failure **after** a successful prepare routes through the same explicit
cancellation path (releasing the reserved proofs), so a rejected send never
leaves proofs stranded. A definitive rejection is `SEND_FAILED` (no token
exists). An ambiguous outcome is `SEND_UNCERTAIN`; the mint is marked unresolved
and the caller must run recovery rather than repeat the send.

`cdk_wallet_receive(token)` validates the token **locally first** (length bound,
parse, single mint, Sat unit, mint approved) and rejects unknown mints with
`TOKEN_UNKNOWN_MINT` **before any network access**. Tokens longer than the
documented 1 MiB bound are rejected with `INVALID_ARGUMENT` before any
base64/CBOR parsing or large allocation. On success it returns the actual **net**
sats credited.

Amounts and fees use checked arithmetic: values that do not fit the signed
integer storage used by SQLite, and `amount + fee` overflows, are rejected
rather than wrapped.

---

## Mnemonics (BIP-39)

Three helpers cover the minimal mnemonic flow, using the same `bip39` dependency
and semantics as upstream CDK:

| Call | Returns |
| --- | --- |
| `cdk_generate_mnemonic()` | A new **12-word English** phrase (128-bit entropy). |
| `cdk_mnemonic_to_entropy(mnemonic)` | The phrase's **raw entropy**: 16 bytes for 12 words (20/24/28/32 for 15/18/21/24). |
| `cdk_mnemonic_to_seed(mnemonic)` | The **64-byte wallet seed**, always, via BIP-39 PBKDF2 with an **empty passphrase**. |

* Generation uses `bip39`'s `rand` feature (a cryptographically secure,
  OS-seeded `rand::thread_rng`). There is **no** deterministic fallback: an RNG
  failure is contained by the panic guard and reported as `INTERNAL_ERROR`, with
  no phrase.
* Conversion accepts any valid English BIP-39 phrase (12/15/18/21/24 words). The
  input is bounds-checked (≤ 1024 bytes), required to be valid UTF-8, and parsed
  against the explicit English word list, verifying word count and checksum.
  Failures return `INVALID_ARGUMENT` with a **static** message that never echoes
  the phrase; a `NULL` phrase returns `NULL_ARGUMENT`.
* **Do not** pass the 16-byte entropy to `cdk_wallet_open` — it needs the
  **64-byte seed** from `cdk_mnemonic_to_seed`. The entropy helper exists to
  inspect the phrase's entropy, matching CDK's `mnemonic_to_entropy`.
* The derived seed uses an **empty** BIP-39 passphrase, matching CDK's default.
  Wallets created with a non-empty BIP-39 passphrase are **not** supported.

The phrase, the entropy, and the derived seed are all secrets:

* the phrase is an owned string (free with `cdk_string_free`);
* entropy/seed are an owned byte payload (free with `cdk_bytes_free`);
* both free helpers scrub the bytes with `zeroize` before releasing the
  allocation, and `CdkBytesResult` has a redacted `Debug` (it never dumps the
  payload). `bip39::Mnemonic` is `ZeroizeOnDrop`.

Scrubbing is **best-effort**: it covers the Rust-owned allocations this library
frees, not caller copies, CPU stacks, or the rest of the heap. The application
remains responsible for mnemonic **backup** and secure storage; this library
never persists a phrase, entropy, or a derived seed anywhere.

---

## Recovery

`cdk_wallet_open` runs startup recovery over **all** mints
(`recover_incomplete_sagas`, covering interrupted Receive/Swap/Send sagas).
`cdk_wallet_recover` runs the same recovery on demand for all mints or a single
mint. Both report **per mint**:

* `mint_url` — the affected mint;
* `recovered` / `compensated` / `skipped` / `failed` — counters for that mint;
* `status` — the status of the recovery **call** for this mint: `OK` if the call
  itself completed (even if some sagas were skipped or failed), otherwise the
  error;
* `message` — a non-secret diagnostic, present when a mint was skipped, failed,
  or the recovery call itself errored, and `NULL` when the mint recovered
  cleanly.

A mint with `skipped > 0` or `failed > 0` is recorded as **unresolved**: inspect
those counters (and the resulting gated-mint behaviour) to know whether a mint
still needs recovery — `status == OK` does **not** by itself mean the mint is
clean. A non-`OK` `status` carrying a `message` means the recovery call itself
failed for that mint. `cdk_wallet_open` also exposes aggregate `recovered` /
`compensated` / `skipped` / `failed` counts alongside the per-mint vector for
convenience.

While a mint is unresolved, all **mutations** for it — including `receive` — are
refused with `RECOVERY_PENDING`. Other mints are unaffected. Read-only access
(balances, mint list, pending tokens) stays available, and pending tokens remain
retrievable. `cdk_wallet_recover` clears the unresolved state on success; the
caller decides when to retry.

An ambiguous mutation outcome (timeout, 5xx, malformed mint response) is treated
as **crash-equivalent**: the mint is marked unresolved and the saga is left for
recovery. It is **never** retried automatically. A clearly-definitive failure
(validation, 4xx, insufficient funds) does **not** wedge the mint.

---

## Security notes

### Seed

The seed is exactly 64 bytes. The application owns backup and secure storage;
it may generate a seed itself, or derive one from a BIP-39 mnemonic with
`cdk_mnemonic_to_seed` (see [Mnemonics](#mnemonics-bip-39)) — the library never
stores the phrase or the seed. On open, the wrapper stores **one** marker record
in the CDK key-value store (namespace `cdk_wallet_ffi`, secondary `""`, key
`marker`):

* a 4-byte little-endian **format version** (`1`), followed by
* a 32-byte **domain-separated** SHA-256 fingerprint of the seed, hashed as
  `SHA256("cdk-wallet-ffi:v1:seed:" || seed)`.

The 36-byte marker is written in a single `kv_write` under the exclusive file
lock, before any wallet is used. No bespoke cryptography is used: SHA-256 comes
from the existing CDK/bitcoin dependency graph.

On open the wrapper validates an existing marker **read-only, before** upstream
migrations run:

* no marker table/row (including an empty or foreign file) → `UNSUPPORTED_DATABASE`;
* wrong length → `UNSUPPORTED_DATABASE`;
* wrong format version → `UNSUPPORTED_FORMAT_VERSION`;
* fingerprint mismatch → `SEED_MISMATCH`.

An existing database is never reset or overwritten. Reopening with a different
seed fails with `SEED_MISMATCH`; do not reuse the same seed with independent
database states.

### Bearer tokens and mnemonics

Tokens are bearer secrets. The wrapper never logs tokens, and error strings are
written so they do not embed raw tokens, mnemonics, entropy, or the seed.
Secret-bearing types (`CdkWallet`, `SendOutcome`, `PendingToken`, and the
token/result structs, including `CdkBytesResult`) have hand-written `Debug` impls
that redact secret material, so `{:?}` cannot leak a token, a phrase, or a
derived seed. Treat any token, mnemonic, entropy, or seed returned through the
ABI as sensitive and free it promptly with `cdk_string_free` /
`cdk_bytes_free` / `cdk_pending_list_free`.

### Database

* Plain (unencrypted) SQLite. The **filesystem and directory** are the security
  boundary: keep the database and its WAL/SHM siblings on an encrypted volume
  and back up the whole directory, not just the `.sqlite` file.
* New database files are created with restrictive `0o600` permissions, and any
  newly created parent directories with `0o700`. Existing directories are never
  re-permissioned.
* A pre-existing file whose group/other permission bits are set is **rejected**
  with `INSECURE_DATABASE_PERMISSIONS` (checked via `fstat` at open time). The
  wrapper never silently `chmod`s it.
* On macOS, **any** extended ACL on the opened database descriptor is rejected
  with `INSECURE_DATABASE_PERMISSIONS`, including a deny-only ACL and one
  inherited from the directory. The probe uses `acl_get_fd_np` with
  `ACL_TYPE_EXTENDED` on the already-open fd (no path is followed), fails closed
  if the ACL cannot be inspected, and never clears or rewrites the ACL. Mode
  `0600` plus no ACL is the supported state; this intentionally rejects harmless
  deny-only ACLs too.
* Permission/ACL rejection happens before marker inspection or any SQLite
  migration, so a foreign file with broad permissions reports
  `INSECURE_DATABASE_PERMISSIONS` rather than being read first.
* A symlinked database path is rejected at open time (`O_NOFOLLOW`); the opened
  file must also be a regular file.
* The wrapper refuses to open a **pre-existing** database that does not carry
  its marker (`UNSUPPORTED_DATABASE`), that carries a truncated marker, or that
  was written by an incompatible format version (`UNSUPPORTED_FORMAT_VERSION`).
* Simultaneous live handles are prevented by an exclusive advisory lock on the
  **database file**, held for the lifetime of the handle, so a second
  `cdk_wallet_open` on the same database (same path, another process or a
  hard-link alias) returns `ALREADY_OPEN`.
  * On Linux this is `flock` (`std::fs::File::try_lock`), which is independent of
    SQLite's `fcntl` byte-range locks.
  * On macOS, `flock` and SQLite's `fcntl` locks share one per-vnode lock
    list; locking the database with `flock` would make SQLite report "database
    is locked". macOS therefore takes a non-blocking open-file-description lock
    (`F_OFD_SETLK`) on byte 0. SQLite only locks `0x40000000..=0x400001ff`, so
    the ranges never overlap. OFD locks are tied to the open file description,
    so same-process second handles and hard links still conflict, and closing
    the descriptor releases the lock. macOS 14+ xnu defines this command
    publicly; this project targets macOS 15.0. If the kernel/filesystem rejects
    `F_OFD_SETLK`, opening fails closed instead of weakening exclusivity.
  * Keep the database directory owner-only; the lock is advisory, so unrelated
    processes that ignore it can still access the file.

### URL policy

`MintUrl` is not a validator, so the wrapper parses the URL strictly and rejects
userinfo (credentials), query strings, and fragments before any fetch or
persistence. `https` is required off-loopback; plain `http` is allowed **only**
for loopback addresses, to support local test mints. Keys are stored in
normalized form.

### Panic safety

`safer_ffi` aborts if a Rust panic unwinds across the ABI boundary. To avoid
that, each exported function wraps its work in `catch_unwind`. If a panic is
caught, the handle is marked **poisoned**: every subsequent call except
`cdk_wallet_close` returns `INTERNAL_ERROR` until the handle is closed and
reopened. Release profiles keep `panic = "unwind"` so this works; a crate-root
`#[cfg(panic = "abort")] compile_error!` fails the build if `panic = "abort"` is
ever configured, because that would turn a caught panic into a process abort.

---

## Building

Requires stable Rust (`cargo +stable`, tested on `1.99`) and, for the Zig side,
Zig `0.17`.

```sh
# Rust staticlib (release, locked)
cargo +stable build --release --locked

# Header regeneration / freshness check
cargo +stable run --locked --features headers --bin generate-headers
cargo +stable run --locked --features headers --bin generate-headers -- --check

# Rust tests: URL/seed/path policy + local fake-mint end-to-end
cargo +stable test --locked

# Format / lint
cargo +stable fmt --check
cargo +stable clippy --locked --all-targets --features headers
```

The crate is pinned: `cdk` and `cdk-sqlite` at `=0.18.3` with
`default-features = false, features = ["wallet"]`, `safer-ffi = "=0.1.13"`, and
`bip39 = "=2.2.2"` (with `rand` + `zeroize`) for the mnemonic helpers.
`Cargo.lock` is committed and builds are expected to use `--locked`.

### Native linking (Linux and macOS)

The staticlib is built with `panic = "unwind"` so the ABI can `catch_unwind`, so
its `_Unwind_*` references must resolve. Verified on Linux with:

```sh
cargo +stable rustc --release --locked --lib -- --print=native-static-libs
# -lgcc_s -lutil -lrt -lpthread -lm -ldl -lc
```

On Linux hosts that ship `libunwind` but **no `libgcc_s.so` dev symlink** (e.g.
Arch / Omarchy), link `-lunwind` instead of `-lgcc_s`; the Zig build does this via
`native_libs = ["unwind", "pthread", "dl", "rt", "util", "m"]`.

For `aarch64-apple-darwin`, rustc's native-static-libs baseline is
`-lSystem -lc -lm`; macOS libSystem also supplies libunwind and pthread. The Zig
build links `System` and `m` (libc comes from Zig's libc linkage) and does **not**
add the Linux-only `rt`, `util`, `dl` or `pthread` libraries. The pinned raylib
build supplies its own macOS frameworks. The bundled SQLite from `cdk-sqlite` is
used; do not link a second system SQLite.

### Testing

The Rust suite covers seed/path/URL policy, wrong-seed, unmarked-database,
truncated-marker, incompatible-version, insecure-permission, symlink, and
live-handle-lock rejection, ABI argument validation (invalid UTF-8, null
required strings, bad seed/operation-id lengths, zero amount, out-of-range
amounts/fees, oversized tokens), the BIP-39 mnemonic helpers (generation,
published 12- and 24-word vectors, entropy/seed lengths, invalid input, and
redacted debug), secret redaction, the panic guard, and local fake-mint
end-to-end tests. The fake mint runs **in process**; no external or public mint
and no real money are involved.

The fake-mint tests inject faults into the mint's HTTP layer to exercise
fail-closed behaviour deterministically:

* a pending outgoing token survives a crash/reopen (same operation id and
  token), is still retrievable after startup recovery, and is redeemable by an
  independent wallet;
* an interrupted receive (mint accepted the swap, response malformed) and a
  receive timeout both mark the mint unresolved (`RECOVERY_PENDING` blocks
  `send`/`receive`), and an explicit recovery replays the NUT-19-cached swap and
  credits the funds exactly once;
* an interrupted prepare (reserved proofs, no confirm) is compensated on reopen,
  restoring the spendable balance;
* a fee-charging receive credits less than the token face value by exactly the
  per-proof input fee;
* a two-mint wallet where one mint's recovery fails reports per-mint
  diagnostics, blocks only the affected mint, keeps the healthy mint usable, and
  exposes the same detail through the startup result (with its report vector
  freed through the ABI).

---

## Deviations from the original brief

* **`@cImport` removed in Zig 0.17.** The Zig module no longer uses `@cImport`;
  the build system translates the generated header with `b.addTranslateC` into a
  `cdk_c` module that `src/cdk.zig` re-exports as `cdk.c`. See
  [`../../docs/cdk-wallet-ffi.md`](../../docs/cdk-wallet-ffi.md).
* **`libunwind` instead of `libgcc_s`.** See above; the Cargo-verified native
  libraries list `-lgcc_s`, but this host has no `libgcc_s.so` dev symlink.
