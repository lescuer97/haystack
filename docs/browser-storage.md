# Browser settings and content storage

The browser build keeps the single-tab Web Lock and both persistent stores in
one IndexedDB database, `haystack-game` (version `1`). The browser wallet uses a
separate database, `haystack-wallet`; see
[browser wallet](browser-wallet.md#wallet-storage-and-provisioning).

| Object store | Contents |
| --- | --- |
| `config` | One JSON document under the key `settings`. |
| `content` | Flat key → whole-file value entries. |

There is no browser directory hierarchy. Content keys are 1–128 ASCII bytes
from `[A-Za-z0-9_-]`; each key maps to one whole entry of at most **64 MiB**.
This matches the desktop content store's addressing rules
(`src/content_key.zig`), so a future browser/desktop sync can use the same keys.

The renderer uses Emscripten **without Asyncify**. Every bridge call returns
immediately; asynchronous results arrive through a function-pointer callback
from a JS continuation.

## Settings document

```json
{
  "version": 1,
  "debug": { "tile_grid": true, "chunk_borders": false }
}
```

Rules enforced before `JSON.parse` and during validation:

- The stored value must be a string of at most **64 KiB** (UTF-8 bytes). Larger
  values are treated as malformed without parsing.
- The document must be a non-array object with an integer `version`.
- Unknown fields at either level are rejected for the current version, so a
  document this build does not fully understand is preserved rather than
  overwritten.
- `debug`, when present, must be an object; `tile_grid` and `chunk_borders` must
  be booleans. Missing optional fields fall back to this build's defaults.
- A newer `version` is preserved and reported separately.
- Malformed, unrecognised and newer documents set the autosave block. The game
  starts with built-in defaults and never overwrites the stored value.
- An explicit reset deletes the config and re-enables autosave.

## JS bridge API

The JS library is `browser/game-storage.js`. Zig declares the C functions in
`src/browser_storage.zig`. All indices are Wasm `i32`/`usize`; keys are raw ASCII
bytes, not NUL-terminated strings.

| C function | Parameters | Result |
| --- | --- | --- |
| `haystack_storage_start` | `callback, default_tile_grid, default_chunk_borders` | One callback: `(status, tile_grid, chunk_borders, autosave_blocked)`. |
| `haystack_storage_save` | `tile_grid, chunk_borders` | Fire-and-forget. |
| `haystack_storage_reset` | — | Fire-and-forget delete. |
| `haystack_content_write` | `key_ptr, key_len, data_ptr, data_len, callback, context` | `callback(context, status)`. |
| `haystack_content_read` | `key_ptr, key_len, callback, context, allocate, release` | `callback(context, status, ptr, len)`. |
| `haystack_content_list` | `callback, context, allocate, release` | `callback(context, status, ptr, len, count)`. |
| `haystack_content_delete` | `key_ptr, key_len, callback, context` | `callback(context, status)`. |

Content status codes:

| Code | Meaning |
| --- | --- |
| `0` | Success. |
| `1` | Not found. |
| `2` | Invalid key. |
| `3` | Entry or result exceeds 64 MiB. |
| `4` | IndexedDB unavailable. |
| `5` | Transaction or bridge failure. |

List results are the committed keys joined by single `\n` bytes in byte order;
`count` is the number of keys. Keys cannot contain `\n`. An empty store delivers
a null pointer, zero length and zero count.

### Memory ownership

- **Input before await.** The JS side copies the key and write payload out of
  Wasm memory synchronously. It never retains a `HEAPU8` view across an `await`.
  Zig may free or reuse the input as soon as `contentWrite`/`contentDelete`
  returns.
- **Result after await.** The JS side asks Zig for result memory through the
  `allocate` function pointer, copies bytes into it, then invokes the callback.
  The Zig callback owns the buffer and must call
  `browser_storage.freeResult(ptr)` exactly once. Null pointers are safe.
- **Allocator.** `allocContentResult`/`freeContentResult` use the Wasm libc
  allocator. The JS side must not use `_malloc`/`_free` for these results.
- **Bounds checks.** A read checks the stored value's size before converting or
  copying: a Blob's `size`, or an ArrayBuffer/view's `byteLength`, must be at
  most 64 MiB. Oversize values are rejected without allocating their copy.
  List output is measured against the 64 MiB result limit before the newline
  buffer is allocated, so an oversize list never allocates a larger result.
- **Callback threading.** Callbacks always run from a JS continuation, never
  synchronously from the initiating call. The one exception is Zig-side argument
  validation, which returns `error.InvalidKey`/`error.FileTooLarge` synchronously
  before crossing the bridge.

### Transaction semantics

Writes and config reset resolve only on the IndexedDB transaction's `oncomplete`
event. `onabort` and `onerror` are failures; an individual request's `onsuccess`
is never treated as a successful write. Reads and `getAllKeys` use a read-only
transaction and resolve on the request result.

Content delete uses one readwrite transaction for both the existence check and
the delete. It resolves on `oncomplete` with success when the key existed and
`not_found` when it was already absent; `onabort`/`onerror` remain failures.

Content operations are serialised through one promise queue, so a subsequent
read/list observes an earlier completed write. Configuration writes have their
own queue.

## Desktop behaviour and differences

- Desktop content writes create the Haystack-owned directories lazily and use an
  atomic rename. Browser values are replaced by a transaction.
- Desktop and browser read/delete of a missing key both report not found
  (`FileNotFound` and status `1` respectively).
- Desktop rejects symlinked content roots and entries on read/list/delete as well
  as write. There are no symlinks in IndexedDB.
- Desktop config files are strict `0600`; the browser relies on same-origin
  IndexedDB isolation, not file permissions.
- Both implementations parse the version first and preserve a newer document
  even when its body is not understood. A current-version document with unknown
  fields blocks autosave instead of being accepted and later overwritten.

## Testing

The Node harness runs the real JS library against a small in-memory IndexedDB.
It needs no Chromium or Wasm bundle:

```sh
node browser/game-storage-test.mjs
zig build test-storage -Dplatform=wasm
```

It covers content round-trip, Blob/Uint8Array reads and the pre-copy size guard
(including the `too_large` status), missing-key delete reporting, list
ordering/filtering and the list size cap, key and size limits, transaction
rollback/failure, the 64 KiB config cap, strict schema preservation,
newer-version preservation, reset, missing Web Locks and IndexedDB
unavailability.

The Chromium suite (`zig build test -Dplatform=wasm`) remains the check for a
real browser; it requires Chromium and the fake-mint fixture.

## Limitations

- The content API is implemented and linked, but the game UI does not use it
  yet. There is no upload/download screen, sync, or directory view.
- Entries are whole-file and must fit in memory. There is no streaming, chunking
  or partial read.
- IndexedDB work runs on the main thread. Large operations may still cause
  browser-visible latency; they do not block the Zig frame loop.
- No quota management or eviction handling beyond surfacing failures.
- One tab per origin is enforced by the Web Lock; a second tab fails startup.
- Browser content is origin-scoped and is not shared with the desktop
  filesystem store.
