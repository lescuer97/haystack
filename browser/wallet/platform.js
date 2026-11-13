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
      if (!database.objectStoreNames.contains(ONBOARDING_STORE)) database.createObjectStore(ONBOARDING_STORE);
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

const USER = "haystack-user";
const STAGE = "haystack-recovery-";
const ID = /^[0-9a-f]{32}$/;
const FINGERPRINT = /^[0-9a-f]{64}$/;
function exactKeys(value, keys) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    && Object.keys(value).sort().join(",") === [...keys].sort().join(",");
}
function validMarker(value, step) {
  return exactKeys(value, ["version", "revision", "step", "fingerprint"])
    && value.version === 1 && Number.isSafeInteger(value.revision) && value.revision >= 0
    && value.step === step && typeof value.fingerprint === "string" && FINGERPRINT.test(value.fingerprint);
}
function validRetired(key, value) {
  return exactKeys(value, ["version", "step", "id", "fingerprint", "mint", "spendable_sats", "pending_sats", "spent_sats"])
    && value.version === 1 && value.step === "retired" && typeof value.id === "string" && ID.test(value.id)
    && key === `retired:${value.id}` && typeof value.fingerprint === "string" && FINGERPRINT.test(value.fingerprint)
    && typeof value.mint === "string" && value.mint.length > 0
    && value.spendable_sats === "0" && value.pending_sats === "0" && value.spent_sats === "0";
}

function parseRetired(json) {
  try {
    if (typeof json !== "string") throw new Error();
    const entries = JSON.parse(json), ids = new Set();
    if (!Array.isArray(entries)) throw new Error();
    for (const entry of entries) {
      if (!exactKeys(entry, ["id", "mnemonic", "state", "marker"])
        || typeof entry.id !== "string" || !ID.test(entry.id) || ids.has(entry.id)
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
      && Object.keys(entry.marker).every(k => marker[k] === entry.marker[k]);
  });
}

function withRetired(name, json, action) {
  let expected;
  try { expected = parseRetired(json); }
  catch (error) { return Promise.reject(error); }
  return serialize(name, () => action(expected));
}

const TOTALS = ["spendable_sats", "pending_sats", "spent_sats"];
function validScan(value) {
  const result = value?.step === "result";
  return exactKeys(value, ["version", "revision", "step", "id", "fingerprint", "mint", ...(result ? TOTALS : [])])
    && value.version === 1 && Number.isSafeInteger(value.revision) && value.revision >= 0
    && ["scanning", "failed", "result"].includes(value.step)
    && typeof value.id === "string" && ID.test(value.id)
    && typeof value.fingerprint === "string" && FINGERPRINT.test(value.fingerprint)
    && typeof value.mint === "string" && value.mint.length > 0
    && (!result || TOTALS.every(k => typeof value[k] === "string" && /^(0|[1-9][0-9]*)$/.test(value[k])
      && (value[k].length < 20 || (value[k].length === 20 && value[k] <= "18446744073709551615"))));
}
function sameMarker(a, b) {
  return validScan(a) && validScan(b) && Object.keys(a).length === Object.keys(b).length
    && Object.keys(a).every(k => a[k] === b[k]);
}
function validRaw(revision, mnemonic, data) {
  return Number.isSafeInteger(revision) && revision >= 0 && typeof mnemonic === "string" && mnemonic.length > 0
    && typeof data === "string" && data.length > 0;
}

// Read all reserved records in the same transaction that performs the transition.
function onboardingTransition(expected, action) {
  return openDatabase().then(db => new Promise((resolve, reject) => {
    let tx;
    try { tx = db.transaction([MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE], "readwrite"); }
    catch (_) { reject(new Error("onboarding storage is unavailable")); return; }
    const fail = () => { try { tx.abort(); } catch (_) {} };
    tx.oncomplete = () => resolve();
    tx.onabort = () => reject(new Error("onboarding transition refused"));
    tx.onerror = () => {};
    try {
      const stores = [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE].map(n => tx.objectStore(n));
      const records = stores.map(() => new Map());
      let pending = stores.length;
      const done = () => {
        if (--pending) return;
        try { if (!matchesRetired(records, expected)) return fail(); action(stores, records, fail); } catch (_) { fail(); }
      };
      stores.forEach((store, i) => {
        const keys = store.getAllKeys();
        keys.onsuccess = () => {
          for (const key of keys.result) {
            if (i !== 2 && !(typeof key === "string" && (key === USER || key.startsWith(STAGE)))) continue;
            pending++;
            const request = store.get(key);
            request.onsuccess = () => { records[i].set(key, request.result); done(); };
          }
          done();
        };
      });
    } catch (_) { fail(); }
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
    if (!ID.test(id) || !mnemonics.has(key) || !states.has(key)
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
  return withRetired(name, expectedRetiredJson, async expected => {
    if (name !== USER || !validRaw(0, mnemonic, state) || !validScan(marker) || marker.step !== "scanning"
      || marker.revision !== 0 || marker.id !== id) throw new Error("invalid onboarding stage input");
    await onboardingTransition(expected, (stores, records, fail) => {
      const [m, s, o] = records, key = STAGE + id;
      if (m.has(USER) || s.has(USER) || o.has(USER) || m.has(key) || s.has(key)
        || o.has(`retired:${id}`) || !validReserved(records, null)) return fail();
      stores[0].add(mnemonic, key); stores[1].add({revision: 0, data: state}, key); stores[2].add(marker, USER);
    });
  });
}

function matchesStage(records, marker, revision, mnemonic, data) {
  const [m, s, o] = records, key = STAGE + marker.id, state = s.get(key);
  return !m.has(USER) && !s.has(USER) && sameMarker(o.get(USER), marker)
    && validReserved(records, marker.id) && m.get(key) === mnemonic && isStateRecord(state)
    && exactKeys(state, ["revision", "data"]) && state.revision === revision && state.data === data;
}

export function updateOnboardingScan(name, expectedMarker, newMarker, expectedStageRevision, expectedMnemonic, expectedStateData, expectedRetiredJson) {
  return withRetired(name, expectedRetiredJson, async expected => {
    if (name !== USER || !validScan(expectedMarker) || !validScan(newMarker)
      || expectedMarker.revision >= Number.MAX_SAFE_INTEGER || newMarker.revision !== expectedMarker.revision + 1
      || newMarker.id !== expectedMarker.id || newMarker.fingerprint !== expectedMarker.fingerprint || newMarker.mint !== expectedMarker.mint
      || !(newMarker.step === "scanning" || (expectedMarker.step === "scanning" && ["failed", "result"].includes(newMarker.step)))
      || !validRaw(expectedStageRevision, expectedMnemonic, expectedStateData)) throw new Error("invalid onboarding scan input");
    await onboardingTransition(expected, (stores, records, fail) => {
      if (!matchesStage(records, expectedMarker, expectedStageRevision, expectedMnemonic, expectedStateData)) return fail();
      stores[2].put(newMarker, USER);
    });
  });
}

export function finishOnboardingRestore(name, expectedResultMarker, stageRevision, stageMnemonic, stageData, expectedRetiredJson) {
  return withRetired(name, expectedRetiredJson, async expected => {
    const marker = expectedResultMarker;
    if (name !== USER || !validScan(marker) || marker.step !== "result" || marker.revision >= Number.MAX_SAFE_INTEGER
      || TOTALS.every(k => marker[k] === "0") || !validRaw(stageRevision, stageMnemonic, stageData)) throw new Error("invalid onboarding restore input");
    await onboardingTransition(expected, (stores, records, fail) => {
      if (!matchesStage(records, marker, stageRevision, stageMnemonic, stageData)) return fail();
      const key = STAGE + marker.id;
      stores[0].add(stageMnemonic, USER); stores[1].add({revision: stageRevision, data: stageData}, USER);
      stores[0].delete(key); stores[1].delete(key);
      stores[2].put({version: 1, revision: marker.revision + 1, step: "complete", fingerprint: marker.fingerprint}, USER);
    });
  });
}

export function generateOnboardingWallet(name, expectedResultMarker, stageRevision, stageMnemonic, stageData, newMnemonic, newState, newBackupMarker, expectedRetiredJson) {
  return withRetired(name, expectedRetiredJson, async expected => {
    const marker = expectedResultMarker;
    if (name !== USER || !validScan(marker) || marker.step !== "result" || !TOTALS.every(k => marker[k] === "0")
      || !validRaw(stageRevision, stageMnemonic, stageData) || !validRaw(0, newMnemonic, newState)
      || !validMarker(newBackupMarker, "backup_seed") || newBackupMarker.revision !== 0
      || newBackupMarker.fingerprint === marker.fingerprint) throw new Error("invalid onboarding generation input");
    await onboardingTransition(expected, (stores, records, fail) => {
      if (!matchesStage(records, marker, stageRevision, stageMnemonic, stageData)) return fail();
      stores[2].add({version: 1, step: "retired", id: marker.id, fingerprint: marker.fingerprint, mint: marker.mint,
        spendable_sats: "0", pending_sats: "0", spent_sats: "0"}, `retired:${marker.id}`);
      stores[0].add(newMnemonic, USER); stores[1].add({revision: 0, data: newState}, USER);
      stores[2].put(newBackupMarker, USER);
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
  const db = await openDatabase();
  return await new Promise((resolve, reject) => {
    let tx;
    try { tx = db.transaction([MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE], "readonly"); }
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
    tx.oncomplete = () => {
      const snapshot = {hasMarker, marker, entries, wallets: [...wallets.values()]};
      try {
        if (!jsonLossless(snapshot)) throw new Error();
        resolve(JSON.stringify(snapshot));
      } catch (_) { reject(new Error("onboarding storage snapshot is malformed")); }
    };
    tx.onabort = () => reject(new Error("onboarding storage read failed"));
    tx.onerror = () => {};
    try {
      for (const storeName of [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE]) {
        const store = tx.objectStore(storeName);
        const keys = store.getAllKeys();
        keys.onsuccess = () => {
          for (const key of keys.result) {
            if (storeName !== ONBOARDING_STORE && !(typeof key === "string" && (key === USER || key.startsWith(STAGE)))) continue;
            const request = store.get(key);
            request.onsuccess = () => {
              if (storeName === ONBOARDING_STORE) {
                if (key === USER) { hasMarker = true; marker = request.result; }
                else entries.push({key, marker: request.result});
              } else {
                const record = wallet(key);
                const mnemonic = storeName === MNEMONIC_STORE;
                record[mnemonic ? "hasMnemonic" : "hasState"] = true;
                record[mnemonic ? "mnemonic" : "state"] = request.result;
              }
            };
          }
        };
      }
    } catch (_) { try { tx.abort(); } catch (_) {} }
  });
}

export function createOnboardingWallet(name, mnemonic, state, marker, expectedRetiredJson) {
  return withRetired(name, expectedRetiredJson, async expected => {
    if (name !== USER || typeof mnemonic !== "string" || !mnemonic.length || typeof state !== "string" || !state.length
      || !validMarker(marker, "backup_seed") || marker.revision !== 0) throw new Error("invalid onboarding creation input");
    await onboardingTransition(expected, (stores, records, fail) => {
      const [m, s, o] = records;
      if (m.has(USER) || s.has(USER) || o.has(USER) || !validReserved(records, null)) return fail();
      stores[0].add(mnemonic, USER);
      stores[1].add({revision: 0, data: state}, USER);
      stores[2].add(marker, USER);
    });
  });
}

export function completeOnboardingWallet(name, expectedMarkerRevision, expectedFingerprint, expectedStateRevision, expectedMnemonic, expectedStateData, expectedRetiredJson) {
  return withRetired(name, expectedRetiredJson, async expected => {
    if (name !== USER || !Number.isSafeInteger(expectedMarkerRevision) || expectedMarkerRevision < 0
      || expectedMarkerRevision >= Number.MAX_SAFE_INTEGER || typeof expectedFingerprint !== "string" || !FINGERPRINT.test(expectedFingerprint)
      || !Number.isSafeInteger(expectedStateRevision) || expectedStateRevision < 0
      || typeof expectedMnemonic !== "string" || !expectedMnemonic.length || typeof expectedStateData !== "string" || !expectedStateData.length) {
      throw new Error("invalid onboarding completion input");
    }
    await onboardingTransition(expected, (stores, records, fail) => {
      const [m, s, o] = records;
      const mnemonic = m.get(USER), state = s.get(USER), marker = o.get(USER);
      if (!m.has(USER) || !s.has(USER) || !o.has(USER) || !validReserved(records, null)
        || mnemonic !== expectedMnemonic || !isStateRecord(state) || !exactKeys(state, ["revision", "data"])
        || state.revision !== expectedStateRevision || state.data !== expectedStateData || !validMarker(marker, "backup_seed")
        || marker.revision !== expectedMarkerRevision || marker.fingerprint !== expectedFingerprint) return fail();
      stores[2].put({...marker, revision: marker.revision + 1, step: "complete"}, USER);
    });
  });
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
