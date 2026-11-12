// Test-only IndexedDB helpers for the dedicated `haystack-wallet` database.
//
// This module is installed by the test targets only; the production game never
// ships it. It reads the same records `browser/wallet/platform.js` writes, so
// the regression suites can inspect and deliberately corrupt a disposable test
// wallet. Deletion targets exactly one wallet's two records and then verifies
// that both are gone; the fixed user wallet is refused outright. It never
// deletes the database, never clears a store, and never touches
// `haystack-game` or localStorage.

export const DATABASE = "haystack-wallet";
export const MNEMONIC_STORE = "mnemonics";
export const STATE_STORE = "states";
export const DATABASE_VERSION = 1;
export const USER_WALLET_NAME = "haystack-user";

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
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(new Error("IndexedDB could not be opened"));
  }).catch(error => {
    connection = null;
    throw error instanceof Error ? error : new Error("IndexedDB could not be opened");
  });
  return connection;
}

function isStateRecord(value) {
  return typeof value === "object"
    && value !== null
    && Number.isSafeInteger(value.revision)
    && value.revision >= 0
    && typeof value.data === "string";
}

// `{mnemonic: string|null, state: {revision, data}|null}` in one snapshot.
export async function readWallet(name) {
  const database = await openDatabase();
  let transaction;
  try {
    transaction = database.transaction([MNEMONIC_STORE, STATE_STORE], "readonly");
  } catch (_) {
    throw new Error("wallet storage is unavailable");
  }
  const mnemonicRequest = transaction.objectStore(MNEMONIC_STORE).get(name);
  const stateRequest = transaction.objectStore(STATE_STORE).get(name);
  await new Promise((resolve, reject) => {
    transaction.oncomplete = resolve;
    transaction.onabort = () => reject(new Error("wallet storage read failed"));
    transaction.onerror = () => {};
  });
  const record = stateRequest.result;
  if (record !== undefined && !isStateRecord(record)) throw new Error("wallet state record is malformed");
  const mnemonic = mnemonicRequest.result;
  return {
    mnemonic: mnemonic === undefined ? null : mnemonic,
    state: record === undefined ? null : {revision: record.revision, data: record.data},
  };
}

// Compare-and-swap write used by the tests (also exercises conflict rejection).
export async function writeState(name, expectedRevision, data) {
  if (!Number.isSafeInteger(expectedRevision) || expectedRevision < 0) throw new Error("wallet state revision is invalid");
  if (typeof data !== "string" || data.length === 0) throw new Error("wallet state is required");
  const database = await openDatabase();
  await new Promise((resolve, reject) => {
    const transaction = database.transaction(STATE_STORE, "readwrite");
    let failure = null;
    transaction.oncomplete = () => { if (failure) reject(failure); else resolve(); };
    transaction.onabort = () => reject(failure || new Error("wallet storage write failed"));
    transaction.onerror = () => {};
    const current = transaction.objectStore(STATE_STORE).get(name);
    current.onerror = () => { failure = new Error("wallet storage write failed"); };
    current.onsuccess = () => {
      const record = current.result;
      if (!isStateRecord(record)) {
        failure = new Error("wallet state is missing or malformed");
        try { transaction.abort(); } catch (_) {}
        return;
      }
      if (record.revision !== expectedRevision) {
        failure = new Error("wallet state conflict");
        try { transaction.abort(); } catch (_) {}
        return;
      }
      try {
        const put = transaction.objectStore(STATE_STORE).put({revision: expectedRevision + 1, data}, name);
        put.onerror = () => { failure = new Error("wallet storage write failed"); };
      } catch (_) {
        failure = new Error("wallet storage write failed");
        try { transaction.abort(); } catch (_) {}
      }
    };
  });
}

// Rewrite the serialized store of a provisioned test wallet. Used to inject
// partial, truncated or incompatible records.
export async function setStateData(name, data) {
  const {state} = await readWallet(name);
  if (!state) throw new Error("wallet state is missing");
  await writeState(name, state.revision, data);
}

export async function deleteMnemonic(name) {
  const database = await openDatabase();
  await new Promise((resolve, reject) => {
    const transaction = database.transaction(MNEMONIC_STORE, "readwrite");
    transaction.objectStore(MNEMONIC_STORE).delete(name);
    transaction.oncomplete = resolve;
    transaction.onabort = () => reject(new Error("wallet mnemonic deletion failed"));
    transaction.onerror = () => {};
  });
}

// Leave a wallet with only its mnemonic record. Used to reproduce the
// dangerous "not state-only, not absent" fixture shape; never used on the user
// wallet by the suites.
export async function deleteState(name) {
  const database = await openDatabase();
  await new Promise((resolve, reject) => {
    const transaction = database.transaction(STATE_STORE, "readwrite");
    transaction.objectStore(STATE_STORE).delete(name);
    transaction.oncomplete = resolve;
    transaction.onabort = () => reject(new Error("wallet state deletion failed"));
    transaction.onerror = () => {};
  });
}

// Delete exactly this wallet's two records in one transaction, then verify both
// are gone. Never deletes the database or clears an object store. The fixed
// user wallet is never a disposable fixture: refuse it before any transaction
// even if a caller passes it by mistake.
export async function deleteWallet(name) {
  if (name === USER_WALLET_NAME) throw new Error("refusing to delete the user wallet");
  const database = await openDatabase();
  await new Promise((resolve, reject) => {
    const transaction = database.transaction([MNEMONIC_STORE, STATE_STORE], "readwrite");
    transaction.objectStore(MNEMONIC_STORE).delete(name);
    transaction.objectStore(STATE_STORE).delete(name);
    transaction.oncomplete = resolve;
    transaction.onabort = () => reject(new Error("wallet deletion failed"));
    transaction.onerror = () => {};
  });
  const {mnemonic, state} = await readWallet(name);
  if (mnemonic !== null || state !== null) throw new Error("wallet deletion did not remove both records");
}
