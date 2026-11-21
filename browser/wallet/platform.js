// Browser wallet platform: IndexedDB storage plus the lifetime Web Lock.
//
// The wallet owns a dedicated `haystack-wallet` database, separate from the
// game's `haystack-game` database. Each wallet name has exactly two records:
//
//   * `mnemonics` — the plaintext English BIP-39 words, stored as a string.
//   * `states`    — `{revision, data}`, where `data` is the complete serialized
//                   CDK `Store` v1 JSON document.
//
// `revision` is the compare-and-swap token: a writer must present the revision
// it read, and the write transaction only commits when it still matches. Every
// promise resolves on `transaction.oncomplete`, never on a request success, so
// a failed or aborted write can never be reported as persisted. Reads always
// open a fresh transaction; nothing is cached in JS.
//
// No secrets are written to logs or URLs. The mnemonic is only ever passed to
// the module that stores it.

const DATABASE = "haystack-wallet";
const MNEMONIC_STORE = "mnemonics";
const STATE_STORE = "states";
const ONBOARDING_STORE = "onboarding";
const DATABASE_VERSION = 2;

let connection = null;
const OPEN_ERROR = "IndexedDB could not be opened";

// Open the wallet database at most once. Each attempt owns its cache entry, so a
// late `success`, `upgradeneeded` or `versionchange` from an abandoned attempt
// can never clear or replace a newer connection. `blocked` is nonterminal;
// `error` normally is terminal, but late callbacks are defended against too. A handle
// that succeeds after abandonment is closed, and an abandoned upgrade is
// aborted before it can create schema.
function openDatabase() {
  if (connection) return connection;
  if (typeof indexedDB === "undefined" || !indexedDB) {
    return Promise.reject(new Error("IndexedDB is required for wallet storage"));
  }
  let resolveAttempt;
  let rejectAttempt;
  const promise = new Promise((resolve, reject) => { resolveAttempt = resolve; rejectAttempt = reject; });
  const attempt = {settled: false, abandoned: false};
  connection = promise;

  const rejectOnce = error => {
    if (attempt.settled) return;
    attempt.settled = true;
    attempt.abandoned = true;
    if (connection === promise) connection = null;
    rejectAttempt(error instanceof Error ? error : new Error(OPEN_ERROR));
  };
  const abortUpgrade = request => {
    try { request.transaction.abort(); } catch (_) {}
  };

  let request;
  try {
    request = indexedDB.open(DATABASE, DATABASE_VERSION);
  } catch (_) {
    rejectOnce(new Error(OPEN_ERROR));
    return promise;
  }
  if (!request || typeof request !== "object") {
    rejectOnce(new Error(OPEN_ERROR));
    return promise;
  }

  request.onupgradeneeded = () => {
    if (attempt.abandoned) {
      // Nobody owns this attempt any more; do not create schema for it.
      abortUpgrade(request);
      return;
    }
    try {
      const database = request.result;
      if (!database.objectStoreNames.contains(MNEMONIC_STORE)) database.createObjectStore(MNEMONIC_STORE);
      if (!database.objectStoreNames.contains(STATE_STORE)) database.createObjectStore(STATE_STORE);
      if (!database.objectStoreNames.contains(ONBOARDING_STORE)) database.createObjectStore(ONBOARDING_STORE);
    } catch (_) {
      attempt.abandoned = true;
      abortUpgrade(request);
      rejectOnce(new Error(OPEN_ERROR));
    }
  };
  request.onsuccess = () => {
    const database = request.result;
    if (attempt.abandoned || attempt.settled) {
      // The caller already saw a failure; never hand out or retain this handle.
      try { database.close(); } catch (_) {}
      return;
    }
    attempt.settled = true;
    // A newer version in another tab supersedes this connection.
    database.onversionchange = () => {
      try { database.close(); } catch (_) {}
      if (connection === promise) connection = null;
    };
    // An unexpected close must not leave a dead handle cached; only this
    // attempt may clear the cache entry it owns.
    database.onclose = () => { if (connection === promise) connection = null; };
    resolveAttempt(database);
  };
  request.onerror = () => rejectOnce(new Error(OPEN_ERROR));
  request.onblocked = () => rejectOnce(new Error("IndexedDB is blocked by another connection"));
  return promise;
}

// One wallet's storage operations run in order. The Web Lock already excludes
// other tabs; this queue keeps an open handle's own reads and writes from
// interleaving at the JS boundary.
const queues = new Map();
function serialize(name, action) {
  const previous = queues.get(name) || Promise.resolve();
  const next = previous.then(action, action);
  const settled = next.then(() => {}, () => {});
  queues.set(name, settled);
  settled.then(() => { if (queues.get(name) === settled) queues.delete(name); });
  return next;
}

// One transaction's terminal contract. Install it before issuing any request:
// a request or transaction error is recorded and the transaction is explicitly
// aborted even when an error listener called `preventDefault`, and success is
// reported only on `complete` with no recorded failure and every tracked
// request finished. Callback exceptions abort too.
function transactionGuard(transaction, errorMessage, {resolve, reject}) {
  const state = {failure: null, pending: 0, settled: false};
  const safeError = error => new Error([
    "wallet already exists", "wallet state conflict", "wallet state is missing or malformed",
  ].includes(error?.message) ? error.message : errorMessage);
  const abort = () => { try { transaction.abort(); } catch (_) {} };
  const shield = event => {
    if (event && typeof event.preventDefault === "function") event.preventDefault();
  };
  const fail = error => {
    if (!state.failure) state.failure = safeError(error);
    abort();
  };
  transaction.onerror = event => { shield(event); fail(event?.target?.error); };
  transaction.oncomplete = () => {
    if (state.settled) return;
    state.settled = true;
    if (state.failure || state.pending !== 0) { reject(state.failure || new Error(errorMessage)); return; }
    try { resolve(); }
    catch (error) { reject(safeError(error)); }
  };
  transaction.onabort = () => {
    if (state.settled) return;
    state.settled = true;
    reject(state.failure || new Error(errorMessage));
  };
  return {
    fail,
    track(request, handlers = {}) {
      state.pending += 1;
      request.onsuccess = () => {
        try { if (handlers.success) handlers.success(request); }
        catch (error) { fail(error); return; }
        state.pending -= 1;
      };
      request.onerror = event => {
        shield(event);
        let error = request.error;
        try { if (handlers.error) error = handlers.error(request) || error; }
        catch (caught) { error = caught; }
        fail(error);
      };
      return request;
    },
  };
}

// Wallet records are exactly `{revision, data}`: extra envelope fields are
// rejected rather than silently dropped, so a migration never reinterprets an
// unknown record as compatible. `revision` is a non-negative safe integer and
// -0 is malformed (JSON.stringify cannot round-trip it losslessly). The
// serialized store stays the raw string owned by the Rust side.
function validRevision(value) {
  return Number.isSafeInteger(value) && value >= 0 && !Object.is(value, -0);
}
function isStateRecord(value) {
  return exactKeys(value, ["revision", "data"])
    && validRevision(value.revision)
    && typeof value.data === "string";
}

// Browser wallet names are the same 1-64 ASCII letter/digit/underscore/hyphen
// identifiers the Rust bridge accepts. The namespaced Web Lock identifiers
// (`haystack-wallet-lock:...`, `haystack-onboarding:...`) contain `:` and are
// deliberately not run through this check. The negative character class rejects
// trailing line terminators that a `$`-anchored pattern would accept.
const WALLET_NAME_CHARS = /[^A-Za-z0-9_-]/;
const INVALID_NAME = "wallet name is invalid";
function validWalletName(name) {
  return typeof name === "string" && name.length >= 1 && name.length <= 64
    && !WALLET_NAME_CHARS.test(name);
}

// Canonical decimal string check: ASCII digits only, no leading zeros, optional
// upper bound compared as decimal text. The explicit non-digit test rejects a
// trailing line terminator that `$` would otherwise permit.
function canonicalDecimal(value, max) {
  if (typeof value !== "string" || value.length === 0 || /[^0-9]/.test(value)) return false;
  if (value.length > 1 && value[0] === "0") return false;
  return max === undefined || value.length < max.length || (value.length === max.length && value <= max);
}

// Revisions cross the bridge as canonical decimal strings. Convert only inside
// the safe-integer range, so an oversized decimal can never be rounded onto an
// adjacent revision.
const MAX_SAFE_REVISION = "9007199254740991";
function parseRevision(value) {
  return canonicalDecimal(value, MAX_SAFE_REVISION) ? Number(value) : null;
}

// Fixed-width lowercase hex identifiers (ids and fingerprints).
function exactHex(value, length) {
  return typeof value === "string" && value.length === length && !/[^0-9a-f]/.test(value);
}

const USER = "haystack-user";
const STAGE = "haystack-recovery-";
function ownDataKeys(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
  let keys;
  try { keys = Reflect.ownKeys(value); } catch (_) { return null; }
  for (const key of keys) {
    if (typeof key !== "string") return null;
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !descriptor.enumerable || !("value" in descriptor)) return null;
  }
  return keys;
}
// Exact own-key-set comparison: a key count plus membership test rejects
// comma-containing key collisions, symbol keys, non-enumerable keys and
// accessors, none of which `Object.keys().join()` can distinguish. Requiring
// own enumerable data properties also means an inherited value can never stand
// in for a missing field.
function exactKeys(value, keys) {
  const names = ownDataKeys(value);
  if (!names || names.length !== keys.length) return false;
  const expected = new Set(keys);
  return names.every(name => expected.has(name));
}
function validMarker(value, step) {
  return exactKeys(value, ["version", "revision", "step", "fingerprint"])
    && value.version === 1 && validRevision(value.revision)
    && value.step === step && exactHex(value.fingerprint, 64);
}
const RETIRED_IDENTITY_FIELDS = ["version", "step", "id", "fingerprint", "mint"];
function validRetired(key, value) {
  const zeroTotals = unit => {
    const totals = ["spendable", "pending", "spent"].map(kind => `${kind}_${unit}`);
    return exactKeys(value, [...RETIRED_IDENTITY_FIELDS, ...totals]) && totals.every(field => value[field] === "0");
  };
  return (zeroTotals("msats") || zeroTotals("sats"))
    && value.version === 1 && value.step === "retired" && exactHex(value.id, 32)
    && key === `retired:${value.id}` && exactHex(value.fingerprint, 64)
    && typeof value.mint === "string" && value.mint.length > 0;
}

function parseRetired(json) {
  try {
    if (typeof json !== "string") throw new Error();
    const entries = JSON.parse(json), ids = new Set();
    if (!Array.isArray(entries)) throw new Error();
    for (const entry of entries) {
      if (!exactKeys(entry, ["id", "mnemonic", "state", "marker"])
        || !exactHex(entry.id, 32) || ids.has(entry.id)
        || typeof entry.mnemonic !== "string" || !isStateRecord(entry.state)
        || !exactKeys(entry.state, ["revision", "data"])
        || !validRetired(`retired:${entry.id}`, entry.marker)) throw new Error();
      ids.add(entry.id);
    }
    return entries;
  } catch (_) { throw new Error("invalid onboarding retired expectation"); }
}

function matchesRetired([mnemonics, states, onboarding], expected) {
  const keys = [...onboarding.keys()].filter(key => key !== USER);
  return keys.length === expected.length && expected.every(entry => {
    const key = STAGE + entry.id, state = states.get(key), marker = onboarding.get(`retired:${entry.id}`);
    return mnemonics.has(key) && states.has(key) && onboarding.has(`retired:${entry.id}`)
      && mnemonics.get(key) === entry.mnemonic && isStateRecord(state)
      && exactKeys(state, ["revision", "data"]) && state.revision === entry.state.revision
      && state.data === entry.state.data && validRetired(`retired:${entry.id}`, marker)
      // Both markers have validated zero totals, even if one uses legacy field names.
      && RETIRED_IDENTITY_FIELDS.every(k => marker[k] === entry.marker[k]);
  });
}

function withRetired(name, json, action) {
  if (!validWalletName(name)) return Promise.reject(new Error(INVALID_NAME));
  let expected;
  try { expected = parseRetired(json); }
  catch (error) { return Promise.reject(error); }
  return serialize(name, () => action(expected));
}

// The compare-and-swap transitions share one expected snapshot: the audited
// marker, the staged wallet state and mnemonic it was derived from, and the
// previously audited retired entries (still a serialized string so it is
// compared exactly). It arrives from the Rust bridge as one named object; every
// field is validated strictly before any transaction opens.
function validExpectedSnapshot(value) {
  return exactKeys(value, ["marker", "state", "mnemonic", "retired"])
    && exactKeys(value.state, ["revision", "data"])
    && validRevision(value.state.revision)
    && typeof value.state.data === "string" && value.state.data.length > 0
    && typeof value.mnemonic === "string" && value.mnemonic.length > 0
    && typeof value.retired === "string";
}

// `prepare` validates the operation-specific inputs on the caller's object and
// returns the marker fields to retain. Only validated primitive fields are
// copied into the private record used after the queue and database waits, so a
// caller mutating its argument later cannot change what is committed.
function withSnapshot(name, snapshot, prepare, action) {
  if (!validWalletName(name)) return Promise.reject(new Error(INVALID_NAME));
  if (!validExpectedSnapshot(snapshot)) {
    return Promise.reject(new Error("invalid onboarding expected snapshot"));
  }
  let retired, captured;
  try {
    retired = parseRetired(snapshot.retired);
    captured = {
      marker: prepare(snapshot),
      state: {revision: snapshot.state.revision, data: snapshot.state.data},
      mnemonic: snapshot.mnemonic,
    };
  } catch (error) {
    return Promise.reject(error instanceof Error ? error : new Error("invalid onboarding input"));
  }
  return serialize(name, () => action(retired, captured));
}

const TOTALS = ["spendable_msats", "pending_msats", "spent_msats"];
function validScan(value) {
  const result = value?.step === "result";
  return exactKeys(value, ["version", "revision", "step", "id", "fingerprint", "mint", ...(result ? TOTALS : [])])
    && value.version === 1 && validRevision(value.revision)
    && ["scanning", "failed", "result"].includes(value.step)
    && exactHex(value.id, 32)
    && exactHex(value.fingerprint, 64)
    && typeof value.mint === "string" && value.mint.length > 0
    && (!result || TOTALS.every(k => canonicalDecimal(value[k], "18446744073709551615")));
}
function sameMarker(a, b) {
  return validScan(a) && validScan(b) && Object.keys(a).length === Object.keys(b).length
    && Object.keys(a).every(k => a[k] === b[k]);
}
function validRaw(revision, mnemonic, data) {
  return validRevision(revision) && typeof mnemonic === "string" && mnemonic.length > 0
    && typeof data === "string" && data.length > 0;
}

// Read all reserved records in the same transaction that performs the transition.
// The guard records any request/transaction error and explicitly aborts before
// the transition can commit; `action` runs only after every read completed.
function onboardingTransition(expected, action) {
  return openDatabase().then(database => new Promise((resolve, reject) => {
    let transaction;
    try { transaction = database.transaction([MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE], "readwrite"); }
    catch (_) { reject(new Error("onboarding storage is unavailable")); return; }
    let acted = false;
    let reads = 0;
    const guard = transactionGuard(transaction, "onboarding transition refused", {
      resolve: () => {
        // Success requires the action to have run and every read to be done.
        if (!acted || reads !== 0) { reject(new Error("onboarding transition refused")); return; }
        resolve();
      },
      reject,
    });
    const finishRead = () => {
      reads -= 1;
      if (reads !== 0 || acted) return;
      acted = true;
      try {
        if (!matchesRetired(records, expected)) { guard.fail(new Error("onboarding transition refused")); return; }
        action(writers, records, error => guard.fail(error || new Error("onboarding transition refused")));
      } catch (error) {
        guard.fail(error instanceof Error ? error : new Error("onboarding transition refused"));
      }
    };
    let stores, writers, records;
    try {
      stores = [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE].map(name => transaction.objectStore(name));
      // Every scheduled write participates in the same explicit error/complete
      // contract as the reads, including errors whose default abort is canceled.
      writers = stores.map(store => ({
        add: (value, key) => guard.track(store.add(value, key)),
        put: (value, key) => guard.track(store.put(value, key)),
        delete: key => guard.track(store.delete(key)),
      }));
      records = stores.map(() => new Map());
      reads = stores.length;
      stores.forEach((store, index) => {
        guard.track(store.getAllKeys(), {
          success: keys => {
            for (const key of keys.result) {
              if (index !== 2 && !(typeof key === "string" && (key === USER || key.startsWith(STAGE)))) continue;
              reads += 1;
              guard.track(store.get(key), {
                success: request => { records[index].set(key, request.result); finishRead(); },
              });
            }
            finishRead();
          },
        });
      });
    } catch (error) {
      guard.fail(error instanceof Error ? error : new Error("onboarding transition refused"));
    }
  }));
}

function validReserved([mnemonics, states, onboarding], activeId) {
  const stages = new Set([...mnemonics.keys(), ...states.keys()].filter(k => typeof k === "string" && k.startsWith(STAGE)));
  for (const key of onboarding.keys()) {
    if (key === USER) continue;
    if (typeof key !== "string" || !validRetired(key, onboarding.get(key)) || !stages.has(STAGE + key.slice(8))) return false;
  }
  for (const key of stages) {
    const id = key.slice(STAGE.length);
    const state = states.get(key);
    if (!exactHex(id, 32) || !mnemonics.has(key) || !states.has(key)
      || typeof mnemonics.get(key) !== "string" || !isStateRecord(state)
      || !exactKeys(state, ["revision", "data"])) return false;
    if (id === activeId) {
      if (onboarding.has(`retired:${id}`)) return false;
    } else if (!onboarding.has(`retired:${id}`)) return false;
  }
  return true;
}

export function onboardingRandomId() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
}

export function stageOnboardingWallet(name, id, mnemonic, state, marker, expectedRetiredJson) {
  if (!validWalletName(name)) return Promise.reject(new Error(INVALID_NAME));
  let input;
  try {
    if (name !== USER || typeof id !== "string" || !validRaw(0, mnemonic, state) || !validScan(marker)
      || marker.step !== "scanning" || marker.revision !== 0 || marker.id !== id) {
      throw new Error("invalid onboarding stage input");
    }
    input = {id, mnemonic, state, marker: {...marker}};
  } catch (error) {
    return Promise.reject(error instanceof Error ? error : new Error("invalid onboarding stage input"));
  }
  return withRetired(name, expectedRetiredJson, async expected => {
    await onboardingTransition(expected, (stores, records, fail) => {
      const [m, s, o] = records, key = STAGE + input.id;
      if (m.has(USER) || s.has(USER) || o.has(USER) || m.has(key) || s.has(key)
        || o.has(`retired:${input.id}`) || !validReserved(records, null)) return fail();
      stores[0].add(input.mnemonic, key); stores[1].add({revision: 0, data: input.state}, key);
      stores[2].add(input.marker, USER);
    });
  });
}

function matchesStage(records, marker, revision, mnemonic, data) {
  const [m, s, o] = records, key = STAGE + marker.id, state = s.get(key);
  return !m.has(USER) && !s.has(USER) && sameMarker(o.get(USER), marker)
    && validReserved(records, marker.id) && m.get(key) === mnemonic && isStateRecord(state)
    && exactKeys(state, ["revision", "data"]) && state.revision === revision && state.data === data;
}

export function updateOnboardingScan(name, snapshot, newMarker) {
  let next;
  return withSnapshot(name, snapshot, supplied => {
    const marker = supplied.marker;
    if (name !== USER || !validScan(marker) || !validScan(newMarker)
      || marker.revision >= Number.MAX_SAFE_INTEGER || newMarker.revision !== marker.revision + 1
      || newMarker.id !== marker.id || newMarker.fingerprint !== marker.fingerprint || newMarker.mint !== marker.mint
      || !(newMarker.step === "scanning" || (marker.step === "scanning" && ["failed", "result"].includes(newMarker.step)))) throw new Error("invalid onboarding scan input");
    next = {...newMarker};
    return {...marker};
  }, async (retired, captured) => {
    await onboardingTransition(retired, (stores, records, fail) => {
      if (!matchesStage(records, captured.marker, captured.state.revision, captured.mnemonic, captured.state.data)) return fail();
      stores[2].put(next, USER);
    });
  });
}

export function finishOnboardingRestore(name, snapshot) {
  return withSnapshot(name, snapshot, supplied => {
    const marker = supplied.marker;
    if (name !== USER || !validScan(marker) || marker.step !== "result" || marker.revision >= Number.MAX_SAFE_INTEGER
      || TOTALS.every(k => marker[k] === "0")) throw new Error("invalid onboarding restore input");
    return {...marker};
  }, async (retired, captured) => {
    const marker = captured.marker;
    await onboardingTransition(retired, (stores, records, fail) => {
      if (!matchesStage(records, marker, captured.state.revision, captured.mnemonic, captured.state.data)) return fail();
      const key = STAGE + marker.id;
      stores[0].add(captured.mnemonic, USER);
      stores[1].add({revision: captured.state.revision, data: captured.state.data}, USER);
      stores[0].delete(key); stores[1].delete(key);
      stores[2].put({version: 1, revision: marker.revision + 1, step: "complete", fingerprint: marker.fingerprint}, USER);
    });
  });
}

export function generateOnboardingWallet(name, snapshot, replacement) {
  let replacement_ = null;
  return withSnapshot(name, snapshot, supplied => {
    const marker = supplied.marker;
    if (name !== USER || !validScan(marker) || marker.step !== "result" || !TOTALS.every(k => marker[k] === "0")
      || !exactKeys(replacement, ["mnemonic", "state", "marker"])
      || !validRaw(0, replacement.mnemonic, replacement.state)
      || !validMarker(replacement.marker, "backup_seed") || replacement.marker.revision !== 0
      || replacement.marker.fingerprint === marker.fingerprint) throw new Error("invalid onboarding generation input");
    replacement_ = {mnemonic: replacement.mnemonic, state: replacement.state, marker: {...replacement.marker}};
    return {...marker};
  }, async (retired, captured) => {
    const marker = captured.marker, next = replacement_;
    await onboardingTransition(retired, (stores, records, fail) => {
      if (!matchesStage(records, marker, captured.state.revision, captured.mnemonic, captured.state.data)) return fail();
      stores[2].add({version: 1, step: "retired", id: marker.id, fingerprint: marker.fingerprint, mint: marker.mint,
        spendable_msats: "0", pending_msats: "0", spent_msats: "0"}, `retired:${marker.id}`);
      stores[0].add(next.mnemonic, USER); stores[1].add({revision: 0, data: next.state}, USER);
      stores[2].put(next.marker, USER);
    });
  });
}

// A single transaction reads all onboarding entries and the user/reserved wallet
// records. Unknown onboarding keys and malformed reserved names are retained.
// Presence flags distinguish missing records from stored null values.
// Values are left unmodified so callers can reject malformed records themselves.
function jsonLossless(value, ancestors = new Set()) {
  if (value === null || typeof value === "string" || typeof value === "boolean") return true;
  if (typeof value === "number") return Number.isFinite(value) && !Object.is(value, -0);
  if (typeof value !== "object" || ancestors.has(value)) return false;
  const array = Array.isArray(value);
  if (!array && Object.getPrototypeOf(value) !== Object.prototype) return false;
  const keys = Reflect.ownKeys(value);
  if (array && (keys.length !== value.length + 1 || keys[keys.length - 1] !== "length"
    || !keys.slice(0, -1).every((key, i) => key === String(i)))) return false;
  ancestors.add(value);
  const valid = keys.every(key => {
    if (array && key === "length") return true;
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    return typeof key === "string" && descriptor.enumerable && "value" in descriptor
      && jsonLossless(descriptor.value, ancestors);
  });
  ancestors.delete(value);
  return valid;
}

export async function loadOnboardingSnapshot() {
  const database = await openDatabase();
  return await new Promise((resolve, reject) => {
    let transaction;
    try { transaction = database.transaction([MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE], "readonly"); }
    catch (_) { reject(new Error("onboarding storage is unavailable")); return; }
    const entries = [];
    const wallets = new Map();
    const wallet = name => {
      if (!wallets.has(name)) wallets.set(name, {name, hasMnemonic: false, mnemonic: null, hasState: false, state: null});
      return wallets.get(name);
    };
    wallet(USER);
    let marker = null;
    let hasMarker = false;
    const guard = transactionGuard(transaction, "onboarding storage read failed", {
      resolve: () => {
        const snapshot = {hasMarker, marker, entries, wallets: [...wallets.values()]};
        try {
          if (!jsonLossless(snapshot)) throw new Error();
          resolve(JSON.stringify(snapshot));
        } catch (_) { reject(new Error("onboarding storage snapshot is malformed")); }
      },
      reject,
    });
    try {
      for (const storeName of [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE]) {
        const store = transaction.objectStore(storeName);
        guard.track(store.getAllKeys(), {
          success: keys => {
            for (const key of keys.result) {
              if (storeName !== ONBOARDING_STORE && !(typeof key === "string" && (key === USER || key.startsWith(STAGE)))) continue;
              guard.track(store.get(key), {
                success: request => {
                  if (storeName === ONBOARDING_STORE) {
                    if (key === USER) { hasMarker = true; marker = request.result; }
                    else entries.push({key, marker: request.result});
                  } else {
                    const record = wallet(key);
                    const mnemonic = storeName === MNEMONIC_STORE;
                    record[mnemonic ? "hasMnemonic" : "hasState"] = true;
                    record[mnemonic ? "mnemonic" : "state"] = request.result;
                  }
                },
              });
            }
          },
        });
      }
    } catch (error) {
      guard.fail(error instanceof Error ? error : new Error("onboarding storage read failed"));
    }
  });
}

export function createOnboardingWallet(name, mnemonic, state, marker, expectedRetiredJson) {
  if (!validWalletName(name)) return Promise.reject(new Error(INVALID_NAME));
  let input;
  try {
    if (name !== USER || typeof mnemonic !== "string" || !mnemonic.length || typeof state !== "string" || !state.length
      || !validMarker(marker, "backup_seed") || marker.revision !== 0) throw new Error("invalid onboarding creation input");
    input = {mnemonic, state, marker: {...marker}};
  } catch (error) {
    return Promise.reject(error instanceof Error ? error : new Error("invalid onboarding creation input"));
  }
  return withRetired(name, expectedRetiredJson, async expected => {
    await onboardingTransition(expected, (stores, records, fail) => {
      const [m, s, o] = records;
      if (m.has(USER) || s.has(USER) || o.has(USER) || !validReserved(records, null)) return fail();
      stores[0].add(input.mnemonic, USER);
      stores[1].add({revision: 0, data: input.state}, USER);
      stores[2].add(input.marker, USER);
    });
  });
}

export function completeOnboardingWallet(name, snapshot) {
  return withSnapshot(name, snapshot, supplied => {
    const marker = supplied.marker;
    if (name !== USER || !validMarker(marker, "backup_seed") || marker.revision >= Number.MAX_SAFE_INTEGER) {
      throw new Error("invalid onboarding completion input");
    }
    return {...marker};
  }, async (retired, captured) => {
    const marker = captured.marker;
    await onboardingTransition(retired, (stores, records, fail) => {
      const [m, s, o] = records;
      const mnemonic = m.get(USER), state = s.get(USER), stored = o.get(USER);
      if (!m.has(USER) || !s.has(USER) || !o.has(USER) || !validReserved(records, null)
        || mnemonic !== captured.mnemonic || !isStateRecord(state) || !exactKeys(state, ["revision", "data"])
        || state.revision !== captured.state.revision || state.data !== captured.state.data
        || !validMarker(stored, "backup_seed")
        || stored.revision !== marker.revision || stored.fingerprint !== marker.fingerprint) return fail();
      stores[2].put({...stored, revision: stored.revision + 1, step: "complete"}, USER);
    });
  });
}

// Returns `{"mnemonic": string|null, "state": {"revision": n, "data": s}|null}`
// as a JSON string, read in one consistent snapshot. Presence is read with
// `getKey` in the same transaction so a stored `undefined`/`null` is reported
// as malformed instead of being mistaken for an absent record.
export function loadWallet(name) {
  if (!validWalletName(name)) return Promise.reject(new Error(INVALID_NAME));
  return serialize(name, async () => {
    const database = await openDatabase();
    return await new Promise((resolve, reject) => {
      let transaction;
      try {
        transaction = database.transaction([MNEMONIC_STORE, STATE_STORE], "readonly");
      } catch (_) {
        reject(new Error("wallet storage is unavailable"));
        return;
      }
      const records = {hasMnemonic: false, hasState: false, mnemonic: undefined, state: undefined};
      const guard = transactionGuard(transaction, "wallet storage read failed", {
        resolve: () => {
          if (records.hasMnemonic && typeof records.mnemonic !== "string") {
            reject(new Error("wallet mnemonic record is malformed"));
            return;
          }
          if (records.hasState && !isStateRecord(records.state)) {
            reject(new Error("wallet state record is malformed"));
            return;
          }
          resolve(JSON.stringify({
            mnemonic: records.hasMnemonic ? records.mnemonic : null,
            state: records.hasState ? {revision: records.state.revision, data: records.state.data} : null,
          }));
        },
        reject,
      });
      try {
        guard.track(transaction.objectStore(MNEMONIC_STORE).getKey(name), {
          success: request => { records.hasMnemonic = request.result !== undefined; },
        });
        guard.track(transaction.objectStore(MNEMONIC_STORE).get(name), {
          success: request => { records.mnemonic = request.result; },
        });
        guard.track(transaction.objectStore(STATE_STORE).getKey(name), {
          success: request => { records.hasState = request.result !== undefined; },
        });
        guard.track(transaction.objectStore(STATE_STORE).get(name), {
          success: request => { records.state = request.result; },
        });
      } catch (error) {
        guard.fail(error instanceof Error ? error : new Error("wallet storage read failed"));
      }
    });
  });
}

// Atomically creates BOTH records with `add`, which fails if either key already
// exists. The transaction either commits both records or neither. Only a
// `ConstraintError` (the key already exists) maps to "wallet already exists";
// quota, I/O or any other failure aborts and reports a generic failure.
export function provisionWallet(name, mnemonic, state) {
  if (!validWalletName(name)) return Promise.reject(new Error(INVALID_NAME));
  if (typeof mnemonic !== "string" || mnemonic.length === 0) return Promise.reject(new Error("wallet mnemonic is required"));
  if (typeof state !== "string" || state.length === 0) return Promise.reject(new Error("wallet state is required"));
  return serialize(name, async () => {
    const database = await openDatabase();
    await new Promise((resolve, reject) => {
      let transaction;
      try {
        transaction = database.transaction([MNEMONIC_STORE, STATE_STORE], "readwrite");
      } catch (_) {
        reject(new Error("wallet storage is unavailable"));
        return;
      }
      const guard = transactionGuard(transaction, "wallet provisioning failed", {resolve, reject});
      const classify = request => (request.error && request.error.name === "ConstraintError")
        ? new Error("wallet already exists")
        : new Error("wallet provisioning failed");
      try {
        guard.track(transaction.objectStore(MNEMONIC_STORE).add(mnemonic, name), {error: classify});
        guard.track(transaction.objectStore(STATE_STORE).add({revision: 0, data: state}, name), {error: classify});
      } catch (error) {
        guard.fail(error instanceof Error ? error : new Error("wallet provisioning failed"));
      }
    });
  });
}

// Compare-and-swap write. The expected revision comes from the immediately
// preceding fresh read; a concurrent writer causes an abort and a rejection, so
// a stale read-modify-write can never overwrite committed state.
export function writeWalletState(name, expectedRevision, data) {
  if (!validWalletName(name)) return Promise.reject(new Error(INVALID_NAME));
  // The Rust bridge always sends a canonical decimal string. Reject every other
  // shape here rather than coercing it; the write must also be able to advance
  // the revision, so MAX_SAFE_INTEGER is readable but not writable.
  const expected = parseRevision(expectedRevision);
  if (expected === null) return Promise.reject(new Error("wallet state revision is invalid"));
  if (expected >= Number.MAX_SAFE_INTEGER) return Promise.reject(new Error("wallet state revision is invalid"));
  if (typeof data !== "string" || data.length === 0) return Promise.reject(new Error("wallet state is required"));
  return serialize(name, async () => {
    const database = await openDatabase();
    await new Promise((resolve, reject) => {
      let transaction;
      try {
        transaction = database.transaction(STATE_STORE, "readwrite");
      } catch (_) {
        reject(new Error("wallet storage is unavailable"));
        return;
      }
      const guard = transactionGuard(transaction, "wallet storage write failed", {resolve, reject});
      try {
        guard.track(transaction.objectStore(STATE_STORE).get(name), {
          success: request => {
            const record = request.result;
            if (!isStateRecord(record)) {
              guard.fail(new Error("wallet state is missing or malformed"));
              return;
            }
            if (record.revision !== expected) {
              guard.fail(new Error("wallet state conflict"));
              return;
            }
            guard.track(transaction.objectStore(STATE_STORE).put({revision: expected + 1, data}, name), {});
          },
        });
      } catch (error) {
        guard.fail(error instanceof Error ? error : new Error("wallet storage write failed"));
      }
    });
  });
}

// Only called by the Rust provisioning path, and only for the fixed user
// wallet. A denial is advisory: the wallet is still stored.
export async function requestPersistentStorage() {
  try {
    if (typeof navigator === "undefined" || !navigator.storage) return false;
    if (typeof navigator.storage.persist !== "function") return false;
    return await navigator.storage.persist();
  } catch (_) {
    return false;
  }
}

const activeLocks = new Map();
// Acquisitions waiting for a closing lock's asynchronous release. They are
// notified promptly on poison instead of waiting for a completion that may
// never arrive, and removed on normal settlement so ordinary reopens do not
// accumulate handlers on an unresolved promise.
const poisonWaiters = new Set();
let invalidated = false;
function poisonError() {
  return new Error("Wasm instance failed; reload before opening a wallet");
}
// A Wasm trap poisons the module: every held handle may still be alive in
// linear memory, but its Rust destructors and close path may never run again.
// Never release a lock here. Dropping it early would let a second tab or handle
// open the same wallet while a live, partially usable handle still exists. The
// held locks stay until document destruction, and all later acquisitions fail.
function invalidate(error) {
  if (!(error instanceof WebAssembly.RuntimeError) || invalidated) return;
  invalidated = true;
  const failure = poisonError();
  for (const notify of [...poisonWaiters]) notify(failure);
  poisonWaiters.clear();
}
window.addEventListener("error", event => invalidate(event.error));
window.addEventListener("unhandledrejection", event => invalidate(event.reason));

function waitForRelease(finished) {
  if (invalidated) return Promise.reject(poisonError());
  return new Promise((resolve, reject) => {
    let settled = false;
    const notify = error => {
      if (settled) return;
      settled = true;
      poisonWaiters.delete(notify);
      reject(error);
    };
    poisonWaiters.add(notify);
    const finish = () => {
      if (settled) return;
      settled = true;
      poisonWaiters.delete(notify);
      resolve();
    };
    finished.then(finish, finish);
  });
}

export async function acquireWalletLock(name) {
  if (!navigator.locks) throw new Error("Web Locks are required; wallet opening refused");
  if (invalidated) throw poisonError();
  const previous = activeLocks.get(name);
  // Resolving the held promise starts release, but the browser lock manager
  // releases asynchronously. A reopen must wait for that completion -- yet must
  // still fail promptly if a trap poisons the module while waiting.
  if (previous?.closing) await waitForRelease(previous.finished);
  if (invalidated) throw poisonError();
  let release;
  const held = new Promise(resolve => { release = resolve; });
  let granted, rejected;
  const ready = new Promise((resolve, reject) => { granted = resolve; rejected = reject; });
  const entry = { closing: false, finished: null, release: null };
  const failRequest = error => rejected(error instanceof Error ? error : new Error("Wallet lock request failed"));
  let request;
  try {
    request = navigator.locks.request(name, { mode: "exclusive", ifAvailable: true }, async lock => {
      if (!lock) { rejected(new Error("Wallet is already open in another tab or handle")); return; }
      // A grant can arrive after a trap poisoned the module. Do not expose a
      // usable handle; returning releases this unused grant normally.
      if (invalidated) { rejected(poisonError()); return; }
      activeLocks.set(name, entry);
      entry.release = () => {
        // An exposed lock stays held until document destruction after poison,
        // even if its release closure is called late.
        if (invalidated) return entry.finished;
        entry.closing = true;
        release();
        return entry.finished;
      };
      granted(entry.release);
      await held;
    });
  } catch (_) {
    failRequest(new Error("Wallet lock request failed"));
    return ready;
  }
  if (!request || typeof request.then !== "function") {
    failRequest(new Error("Wallet lock request failed"));
    return ready;
  }
  entry.finished = request;
  entry.finished.then(
    () => { if (activeLocks.get(name) === entry) activeLocks.delete(name); },
    error => {
      if (activeLocks.get(name) === entry) activeLocks.delete(name);
      rejected(error instanceof Error ? error : new Error("Wallet lock request failed"));
    },
  );
  return ready;
}
