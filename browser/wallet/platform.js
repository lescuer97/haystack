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
const DATABASE_VERSION = 1;

let connection = null;

function openDatabase() {
  if (connection) return connection;
  if (typeof indexedDB === "undefined" || !indexedDB) {
    return Promise.reject(new Error("IndexedDB is required for wallet storage"));
  }
  connection = new Promise((resolve, reject) => {
    let request;
    try {
      request = indexedDB.open(DATABASE, DATABASE_VERSION);
    } catch (_) {
      reject(new Error("IndexedDB could not be opened"));
      return;
    }
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(MNEMONIC_STORE)) database.createObjectStore(MNEMONIC_STORE);
      if (!database.objectStoreNames.contains(STATE_STORE)) database.createObjectStore(STATE_STORE);
    };
    request.onsuccess = () => {
      const database = request.result;
      // A newer version in another tab supersedes this connection.
      database.onversionchange = () => {
        try { database.close(); } catch (_) {}
        connection = null;
      };
      resolve(database);
    };
    request.onerror = () => reject(new Error("IndexedDB could not be opened"));
    request.onblocked = () => reject(new Error("IndexedDB is blocked by another connection"));
  }).catch(error => {
    connection = null;
    throw error instanceof Error ? error : new Error("IndexedDB could not be opened");
  });
  return connection;
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

function isStateRecord(value) {
  return typeof value === "object"
    && value !== null
    && Number.isSafeInteger(value.revision)
    && value.revision >= 0
    && typeof value.data === "string";
}

// Returns `{"mnemonic": string|null, "state": {"revision": n, "data": s}|null}`
// as a JSON string, read in one consistent snapshot.
export function loadWallet(name) {
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
      const mnemonicRequest = transaction.objectStore(MNEMONIC_STORE).get(name);
      const stateRequest = transaction.objectStore(STATE_STORE).get(name);
      transaction.oncomplete = () => {
        const mnemonic = mnemonicRequest.result;
        const state = stateRequest.result;
        if (mnemonic !== undefined && typeof mnemonic !== "string") {
          reject(new Error("wallet mnemonic record is malformed"));
          return;
        }
        if (state !== undefined && !isStateRecord(state)) {
          reject(new Error("wallet state record is malformed"));
          return;
        }
        resolve(JSON.stringify({
          mnemonic: mnemonic === undefined ? null : mnemonic,
          state: state === undefined ? null : {revision: state.revision, data: state.data},
        }));
      };
      transaction.onabort = () => reject(new Error("wallet storage read failed"));
      transaction.onerror = () => {};
    });
  });
}

// Atomically creates BOTH records with `add`, which fails if either key already
// exists. The transaction either commits both records or neither.
export function provisionWallet(name, mnemonic, state) {
  return serialize(name, async () => {
    if (typeof mnemonic !== "string" || mnemonic.length === 0) throw new Error("wallet mnemonic is required");
    if (typeof state !== "string" || state.length === 0) throw new Error("wallet state is required");
    const database = await openDatabase();
    await new Promise((resolve, reject) => {
      let transaction;
      try {
        transaction = database.transaction([MNEMONIC_STORE, STATE_STORE], "readwrite");
      } catch (_) {
        reject(new Error("wallet storage is unavailable"));
        return;
      }
      let failure = null;
      const duplicate = () => { failure = new Error("wallet already exists"); };
      transaction.oncomplete = () => {
        if (failure) reject(failure); else resolve();
      };
      transaction.onabort = () => reject(failure || new Error("wallet provisioning was aborted"));
      transaction.onerror = () => {};
      try {
        const stores = transaction.objectStore(MNEMONIC_STORE).add(mnemonic, name);
        const stateStore = transaction.objectStore(STATE_STORE).add({revision: 0, data: state}, name);
        stores.onerror = duplicate;
        stateStore.onerror = duplicate;
      } catch (_) {
        failure = new Error("wallet provisioning failed");
        try { transaction.abort(); } catch (_) {}
      }
    });
  });
}

// Compare-and-swap write. The expected revision comes from the immediately
// preceding fresh read; a concurrent writer causes an abort and a rejection, so
// a stale read-modify-write can never overwrite committed state.
export function writeWalletState(name, expectedRevision, data) {
  return serialize(name, async () => {
    const expected = Number(expectedRevision);
    if (!Number.isSafeInteger(expected) || expected < 0) throw new Error("wallet state revision is invalid");
    if (typeof data !== "string" || data.length === 0) throw new Error("wallet state is required");
    const database = await openDatabase();
    await new Promise((resolve, reject) => {
      let transaction;
      try {
        transaction = database.transaction(STATE_STORE, "readwrite");
      } catch (_) {
        reject(new Error("wallet storage is unavailable"));
        return;
      }
      let failure = null;
      transaction.oncomplete = () => {
        if (failure) reject(failure); else resolve();
      };
      transaction.onabort = () => reject(failure || new Error("wallet storage write failed"));
      transaction.onerror = () => {};
      let current;
      try {
        current = transaction.objectStore(STATE_STORE).get(name);
      } catch (_) {
        failure = new Error("wallet storage write failed");
        try { transaction.abort(); } catch (_) {}
        return;
      }
      current.onerror = () => { failure = new Error("wallet storage write failed"); };
      current.onsuccess = () => {
        const record = current.result;
        if (!isStateRecord(record)) {
          failure = new Error("wallet state is missing or malformed");
          try { transaction.abort(); } catch (_) {}
          return;
        }
        if (record.revision !== expected) {
          failure = new Error("wallet state conflict");
          try { transaction.abort(); } catch (_) {}
          return;
        }
        try {
          const put = transaction.objectStore(STATE_STORE).put({revision: expected + 1, data}, name);
          put.onerror = () => { failure = new Error("wallet storage write failed"); };
        } catch (_) {
          failure = new Error("wallet storage write failed");
          try { transaction.abort(); } catch (_) {}
        }
      };
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
let invalidated = false;
// A Wasm trap poisons the module: every held handle may still be alive in
// linear memory, but its Rust destructors and close path may never run again.
// Never release a lock here. Dropping it early would let a second tab or handle
// open the same wallet while a live, partially usable handle still exists. The
// held locks stay until document destruction, and all later acquisitions fail.
function invalidate(error) {
  if (error instanceof WebAssembly.RuntimeError) invalidated = true;
}
window.addEventListener("error", event => invalidate(event.error));
window.addEventListener("unhandledrejection", event => invalidate(event.reason));

export async function acquireWalletLock(name) {
  if (!navigator.locks) throw new Error("Web Locks are required; wallet opening refused");
  if (invalidated) throw new Error("Wasm instance failed; reload before opening a wallet");
  const previous = activeLocks.get(name);
  // Resolving the held promise starts release, but the browser lock manager
  // releases asynchronously. A reopen must wait for that completion.
  if (previous?.closing) await previous.finished;
  let release;
  const held = new Promise(resolve => { release = resolve; });
  let granted, rejected;
  const ready = new Promise((resolve, reject) => { granted = resolve; rejected = reject; });
  const entry = { closing: false, finished: null };
  entry.finished = navigator.locks.request(name, { mode: "exclusive", ifAvailable: true }, async lock => {
    if (!lock) { rejected(new Error("Wallet is already open in another tab or handle")); return; }
    activeLocks.set(name, entry);
    entry.release = () => { entry.closing = true; release(); return entry.finished; };
    granted(entry.release);
    await held;
  });
  entry.finished.then(() => { if (activeLocks.get(name) === entry) activeLocks.delete(name); }, rejected);
  return ready;
}
