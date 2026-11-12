// Node-only harness for browser/wallet/platform.js.
//
// Chromium is not always available, so this test runs the wallet IndexedDB
// layer against a small in-memory implementation of the IndexedDB primitives it
// uses. It covers atomic provisioning, compare-and-swap writes, conflict
// rejection, injected write/abort failures, fresh reads and the persistent
// storage request helper.
//
// It does not emulate real browser durability, Web Locks, or a shared database
// across tabs. Run `zig build test -Dplatform=wasm` for the Chromium suite.

import {strict as assert} from "node:assert";
import * as walletStore from "./wallet-store.js";

const DATABASE = "haystack-wallet";
const MNEMONIC_STORE = "mnemonics";
const STATE_STORE = "states";

class FakeRequest {
  constructor() {
    this.result = undefined;
    this.error = null;
    this.onsuccess = null;
    this.onerror = null;
    this.onupgradeneeded = null;
    this.onblocked = null;
  }
}

class FakeObjectStore {
  constructor(transaction, name) {
    this.transaction = transaction;
    this.name = name;
    this.data = transaction.db.stores.get(name);
  }

  get(key) {
    const request = new FakeRequest();
    this.transaction.add(request, () => (this.data.has(key) ? this.data.get(key) : undefined));
    return request;
  }

  put(value, key) {
    const request = new FakeRequest();
    this.transaction.add(request, () => {
      this.transaction.db.checkWrite();
      this.data.set(key, value);
      return key;
    });
    return request;
  }

  add(value, key) {
    const request = new FakeRequest();
    this.transaction.add(request, () => {
      if (this.data.has(key)) {
        const duplicate = new Error("ConstraintError");
        duplicate.name = "ConstraintError";
        throw duplicate;
      }
      this.transaction.db.checkWrite();
      this.data.set(key, value);
      return key;
    });
    return request;
  }

  delete(key) {
    const request = new FakeRequest();
    this.transaction.add(request, () => {
      this.transaction.db.checkWrite();
      this.data.delete(key);
      return undefined;
    });
    return request;
  }
}

class FakeTransaction {
  constructor(db, names, mode) {
    this.db = db;
    this.names = names;
    this.mode = mode;
    this.error = null;
    this.pending = 0;
    this.finished = false;
    this.aborted = false;
    this.oncomplete = null;
    this.onerror = null;
    this.onabort = null;
    this.snapshots = names.map(name => [name, new Map(db.stores.get(name))]);
  }

  objectStore(name) {
    if (!this.names.includes(name)) throw new Error(`store ${name} is not in this transaction`);
    return new FakeObjectStore(this, name);
  }

  add(request, action) {
    this.pending += 1;
    queueMicrotask(() => {
      if (this.aborted) return;
      try {
        request.result = action();
        if (request.onsuccess) request.onsuccess();
      } catch (error) {
        request.error = error;
        if (request.onerror) request.onerror();
        this.abort(error);
        return;
      }
      this.pending -= 1;
      this.maybeComplete();
    });
  }

  maybeComplete() {
    if (this.pending !== 0 || this.finished) return;
    if (this.db.indexedDB.abortNextWrite && this.mode === "readwrite") {
      this.db.indexedDB.abortNextWrite = false;
      this.abort(new Error("injected transaction abort"));
      return;
    }
    this.finished = true;
    queueMicrotask(() => {
      if (this.oncomplete) this.oncomplete();
    });
  }

  abort(error) {
    if (this.finished) return;
    this.finished = true;
    this.aborted = true;
    this.error = error;
    for (const [name, snapshot] of this.snapshots) this.db.stores.set(name, snapshot);
    queueMicrotask(() => {
      if (this.onerror) this.onerror();
      queueMicrotask(() => {
        if (this.onabort) this.onabort();
      });
    });
  }
}

class FakeDatabase {
  constructor(record, indexedDB) {
    this.stores = record.stores;
    this.indexedDB = indexedDB;
    this.objectStoreNames = {contains: name => this.stores.has(name)};
  }

  createObjectStore(name) {
    this.stores.set(name, new Map());
    return {name};
  }

  transaction(names, mode) {
    if (typeof names === "string") names = [names];
    for (const name of names) {
      if (!this.stores.has(name)) throw new Error(`missing object store ${name}`);
    }
    return new FakeTransaction(this, names, mode);
  }

  // Injected failure for the next write request.
  checkWrite() {
    if (this.indexedDB.writeFailures > 0) {
      this.indexedDB.writeFailures -= 1;
      throw new Error("injected write failure");
    }
  }
}

class FakeIndexedDB {
  constructor() {
    this.records = new Map();
    this.writeFailures = 0;
    this.abortNextWrite = false;
  }

  open(name, version) {
    const request = new FakeRequest();
    queueMicrotask(() => {
      let record = this.records.get(name);
      let upgrade = false;
      if (!record) {
        record = {version: 0, stores: new Map()};
        this.records.set(name, record);
      }
      if (version > record.version) {
        upgrade = true;
        record.version = version;
      }
      const database = new FakeDatabase(record, this);
      request.result = database;
      if (upgrade && request.onupgradeneeded) request.onupgradeneeded();
      if (request.onsuccess) request.onsuccess();
    });
    return request;
  }

  store(storeName) {
    const record = this.records.get(DATABASE);
    assert.ok(record, "wallet database was created");
    assert.ok(record.stores.has(storeName), `${storeName} store exists`);
    return record.stores.get(storeName);
  }

  peek(storeName, key) {
    return this.store(storeName).get(key);
  }

  seed(storeName, key, value) {
    this.store(storeName).set(key, value);
  }
}

const fake = new FakeIndexedDB();
let persist = async () => true;
const listeners = new Map();
globalThis.window = {addEventListener(type, handler) { listeners.set(type, handler); }};
const lockState = {held: new Map()};
const locks = {
  request(name, _options, callback) {
    if (lockState.held.has(name)) return Promise.resolve(callback(null));
    let release;
    const gate = new Promise(resolve => { release = resolve; });
    lockState.held.set(name, release);
    return Promise.resolve()
      .then(() => callback({name}))
      .then(result => {
        release();
        lockState.held.delete(name);
        return result;
      });
  },
};
Object.defineProperty(globalThis, "indexedDB", {value: fake, configurable: true});
Object.defineProperty(globalThis, "navigator", {value: {storage: {persist: () => persist()}, locks}, configurable: true});

const platform = await import("./wallet/platform.js");

const MNEMONIC = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const OTHER_MNEMONIC = "legal winner thank year wave sausage worth useful legal winner thank yellow";
const parse = raw => JSON.parse(raw);
let checks = 0;
function check() {
  checks += 1;
}

// --- Fresh wallet: both records absent ---------------------------------------
{
  const records = parse(await platform.loadWallet("fresh"));
  assert.deepEqual(records, {mnemonic: null, state: null});
  assert.equal(fake.peek(MNEMONIC_STORE, "fresh"), undefined);
  assert.equal(fake.peek(STATE_STORE, "fresh"), undefined);
  check("Wallet storage starts empty");
}

// --- Atomic provisioning writes both records --------------------------------
{
  await platform.provisionWallet("wallet-a", MNEMONIC, '{"version":1}');
  const records = parse(await platform.loadWallet("wallet-a"));
  assert.equal(records.mnemonic, MNEMONIC);
  assert.deepEqual(records.state, {revision: 0, data: '{"version":1}'});
  assert.equal(fake.peek(MNEMONIC_STORE, "wallet-a"), MNEMONIC);
  check("Provisioning stores the plaintext mnemonic and initial state");
}

// --- Provisioning never replaces an existing wallet -------------------------
{
  await assert.rejects(platform.provisionWallet("wallet-a", OTHER_MNEMONIC, '{"version":2}'), /wallet already exists/);
  const records = parse(await platform.loadWallet("wallet-a"));
  assert.equal(records.mnemonic, MNEMONIC);
  assert.deepEqual(records.state, {revision: 0, data: '{"version":1}'});
  check("Provisioning an existing name is rejected without replacement");
}

// --- Provisioning is atomic when one record already exists ------------------
{
  fake.seed(STATE_STORE, "partial", {revision: 0, data: '{"version":1}'});
  await assert.rejects(platform.provisionWallet("partial", MNEMONIC, '{"version":1}'), /wallet already exists/);
  assert.equal(fake.peek(MNEMONIC_STORE, "partial"), undefined);
  check("Failed provisioning leaves neither record behind");
}

// --- Compare-and-swap writes -------------------------------------------------
{
  await platform.writeWalletState("wallet-a", "0", '{"version":2}');
  let records = parse(await platform.loadWallet("wallet-a"));
  assert.deepEqual(records.state, {revision: 1, data: '{"version":2}'});

  await assert.rejects(platform.writeWalletState("wallet-a", "0", '{"stale":true}'), /wallet state conflict/);
  records = parse(await platform.loadWallet("wallet-a"));
  assert.deepEqual(records.state, {revision: 1, data: '{"version":2}'});
  check("A stale revision is rejected without changing committed state");
}

// --- Concurrent writers: exactly one revision wins ---------------------------
{
  const results = await Promise.allSettled([
    platform.writeWalletState("wallet-a", "1", '{"writer":1}'),
    platform.writeWalletState("wallet-a", "1", '{"writer":2}'),
  ]);
  assert.equal(results.filter(result => result.status === "fulfilled").length, 1);
  assert.ok(/wallet state conflict/.test(String(results.find(result => result.status === "rejected").reason)));
  const records = parse(await platform.loadWallet("wallet-a"));
  assert.equal(records.state.revision, 2);
  assert.equal(records.state.data, '{"writer":1}');
  check("Concurrent stale writers cannot both commit");
}

// --- Injected request failure ------------------------------------------------
{
  fake.writeFailures = 1;
  await assert.rejects(platform.writeWalletState("wallet-a", "2", '{"failed":true}'), /wallet storage write failed/);
  const records = parse(await platform.loadWallet("wallet-a"));
  assert.deepEqual(records.state, {revision: 2, data: '{"writer":1}'});
  check("A failed write is rejected and persists nothing");
}

// --- Injected transaction abort ---------------------------------------------
{
  fake.abortNextWrite = true;
  await assert.rejects(platform.writeWalletState("wallet-a", "2", '{"aborted":true}'), /wallet storage write failed/);
  const records = parse(await platform.loadWallet("wallet-a"));
  assert.deepEqual(records.state, {revision: 2, data: '{"writer":1}'});
  check("An aborted transaction is not reported as persisted");
}

// --- Missing state is not recreated ------------------------------------------
{
  await assert.rejects(platform.writeWalletState("unprovisioned", "0", '{"x":1}'), /missing or malformed/);
  assert.equal(fake.peek(STATE_STORE, "unprovisioned"), undefined);
  check("Writing to an unprovisioned wallet creates nothing");
}

// --- Reads are always fresh --------------------------------------------------
{
  fake.seed(STATE_STORE, "wallet-a", {revision: 7, data: '{"direct":true}'});
  const records = parse(await platform.loadWallet("wallet-a"));
  assert.deepEqual(records.state, {revision: 7, data: '{"direct":true}'});
  check("Reads observe externally committed state (no cache)");
}

// --- Persistent storage request helper ---------------------------------------
{
  persist = async () => true;
  assert.equal(await platform.requestPersistentStorage(), true);
  persist = async () => { throw new Error("denied"); };
  assert.equal(await platform.requestPersistentStorage(), false);
  navigator.storage = undefined;
  assert.equal(await platform.requestPersistentStorage(), false);
  check("Persistent storage requests report grant, denial and absence safely");
}

// --- The fixed user wallet is never deleted by the test helper --------------
{
  // A mnemonic-only record is exactly the dangerous fixture shape: treating it
  // as "absent" and then cleaning it up would destroy a real user's backup.
  fake.seed(MNEMONIC_STORE, walletStore.USER_WALLET_NAME, MNEMONIC);
  await assert.rejects(
    walletStore.deleteWallet(walletStore.USER_WALLET_NAME),
    /refusing to delete the user wallet/,
  );
  assert.equal(fake.peek(MNEMONIC_STORE, walletStore.USER_WALLET_NAME), MNEMONIC);
  assert.equal(fake.peek(STATE_STORE, walletStore.USER_WALLET_NAME), undefined);
  check("The user wallet is never deleted, including a mnemonic-only sentinel");
}

// --- Wasm runtime traps keep held locks and reject new acquisitions ----------
{
  const release = await platform.acquireWalletLock("trap-wallet");
  assert.equal(typeof release, "function");
  listeners.get("error")({error: new WebAssembly.RuntimeError("trap")});
  await assert.rejects(platform.acquireWalletLock("trap-wallet"), /Wasm instance failed/);
  await assert.rejects(platform.acquireWalletLock("other-wallet"), /Wasm instance failed/);
  assert.ok(lockState.held.has("trap-wallet"), "the held lock stays until document destruction");
  await release();
  assert.ok(!lockState.held.has("trap-wallet"), "the lock is released only when the document closes it");
  check("Wasm runtime traps retain held locks and reject new acquisitions");
}

console.log(`wallet IndexedDB tests passed (${checks} checks)`);
