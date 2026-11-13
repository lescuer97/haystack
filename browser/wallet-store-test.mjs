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
import {readFile} from "node:fs/promises";
import vm from "node:vm";
import * as walletStore from "./wallet-store.js";

const DATABASE = "haystack-wallet";
const MNEMONIC_STORE = "mnemonics";
const STATE_STORE = "states";
const ONBOARDING_STORE = "onboarding";

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

  getAllKeys() {
    const request = new FakeRequest();
    this.transaction.add(request, () => [...this.data.keys()]);
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
    this.record = record;
    this.stores = record.stores;
    this.indexedDB = indexedDB;
    this.objectStoreNames = {contains: name => this.stores.has(name)};
    this.closed = false;
    record.connections.add(this);
  }

  close() { this.closed = true; this.record.connections.delete(this); }

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
      record.connections ||= new Set();
      if (version < record.version) {
        request.error = new Error("VersionError");
        request.error.name = "VersionError";
        if (request.onerror) request.onerror();
        return;
      }
      if (version > record.version) {
        for (const db of [...record.connections]) if (db.onversionchange) db.onversionchange();
        if (record.connections.size) {
          if (request.onblocked) request.onblocked();
          return;
        }
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

// Exercise both independent openers against fresh, v1, and newer databases.
const originalListeners = new Map(listeners);

// Load the actual Emscripten library, replacing only its build-time macro.
const gameSource = (await readFile(new URL("./game-wallet.js", import.meta.url), "utf8"))
  .replace(/\{\{\{ makeDynCall\([^\n]+?\) \}\}\}/, "(function () {})");
function gameSmoke(indexedDB) {
  const library = {};
  vm.runInNewContext(gameSource, {indexedDB, LibraryManager: {library}, mergeInto: Object.assign});
  return library.$haystackWalletSmoke;
}
for (const scenario of ["fresh", "upgrade", "existing", "newer"]) {
  const isolated = new FakeIndexedDB();
  const state = {revision: 17, data: "existing", extra: "preserve"};
  if (scenario !== "fresh") {
    const stores = new Map([
      [MNEMONIC_STORE, new Map([["existing", MNEMONIC]])],
      [STATE_STORE, new Map([["existing", state]])],
    ]);
    if (scenario === "existing") stores.set(ONBOARDING_STORE, new Map([["marker", "preserve"]]));
    isolated.records.set(DATABASE, {version: scenario === "upgrade" ? 1 : scenario === "existing" ? 2 : 3, stores});
  }
  const smoke = gameSmoke(isolated);
  if (scenario === "newer") {
    await assert.rejects(smoke.openDatabase(), /wallet smoke failed/);
    assert.equal(isolated.records.get(DATABASE).version, 3);
    assert.equal(isolated.peek(MNEMONIC_STORE, "existing"), MNEMONIC);
    assert.deepEqual(isolated.peek(STATE_STORE, "existing"), state);
    assert.equal(isolated.records.get(DATABASE).stores.has(ONBOARDING_STORE), false);
  } else {
    const db = await smoke.openDatabase();
    assert.equal(isolated.records.get(DATABASE).version, 2);
    assert.ok(isolated.records.get(DATABASE).stores.has(ONBOARDING_STORE));
    if (scenario !== "fresh") {
      assert.equal(isolated.peek(MNEMONIC_STORE, "existing"), MNEMONIC);
      assert.deepEqual(isolated.peek(STATE_STORE, "existing"), state);
    }
    if (scenario === "existing") assert.equal(isolated.peek(ONBOARDING_STORE, "marker"), "preserve");
    Object.defineProperty(globalThis, "indexedDB", {value: isolated, configurable: true});
    const isolatedPlatform = await import(`./wallet/platform.js?game-${scenario}`);
    await isolatedPlatform.provisionWallet("new-wallet", MNEMONIC, "new-state");
    assert.equal(isolated.peek(MNEMONIC_STORE, "new-wallet"), MNEMONIC);
    // A subsequent upgrade must not be held up by the smoke connection.
    const upgrade = isolated.open(DATABASE, 3);
    await new Promise((resolve, reject) => {
      upgrade.onsuccess = resolve;
      upgrade.onerror = reject;
      upgrade.onblocked = () => reject(new Error("upgrade blocked"));
    });
    assert.equal(db.closed, true);
    assert.equal(smoke.connection, null);
    upgrade.result.close();
  }
  check();
}
// A blocked (or errored) request may later succeed; that handle must be closed,
// and must not replace a subsequent successful connection.
for (const failure of ["onblocked", "onerror"]) {
  const requests = [];
  const smoke = gameSmoke({open() { const request = new FakeRequest(); requests.push(request); return request; }});
  const first = smoke.openDatabase();
  requests[0][failure]();
  await assert.rejects(first, /wallet smoke failed/);
  const second = smoke.openDatabase();
  const current = {close() { this.closed = true; }};
  requests[1].result = current;
  requests[1].onsuccess();
  assert.equal(await second, current);
  const late = {close() { this.closed = true; }};
  requests[0].result = late;
  requests[0].onsuccess();
  assert.equal(late.closed, true);
  assert.equal(await smoke.openDatabase(), current);
  check();
}
for (const [label, load] of [
  ["platform", async suffix => (await import(`./wallet/platform.js?${suffix}`)).loadWallet],
  ["helper", async suffix => (await import(`./wallet-store.js?${suffix}`)).readWallet],
]) {
  for (const scenario of ["fresh", "upgrade", "newer"]) {
    const isolated = new FakeIndexedDB();
    const state = {revision: 17, data: '{ "version": 1, "contents": [1,2] }', extra: "preserve"};
    if (scenario !== "fresh") {
      isolated.records.set(DATABASE, {
        version: scenario === "upgrade" ? 1 : 3,
        stores: new Map([
          [MNEMONIC_STORE, new Map([["existing", MNEMONIC]])],
          [STATE_STORE, new Map([["existing", state]])],
        ]),
      });
    }
    Object.defineProperty(globalThis, "indexedDB", {value: isolated, configurable: true});
    const read = await load(`${label}-${scenario}`);
    if (scenario === "newer") {
      await assert.rejects(read("existing"), /IndexedDB could not be opened/);
      assert.equal(isolated.records.get(DATABASE).version, 3);
      assert.equal(isolated.records.get(DATABASE).stores.has(ONBOARDING_STORE), false);
    } else {
      await read("existing");
      assert.equal(isolated.records.get(DATABASE).version, 2);
      assert.deepEqual([...isolated.records.get(DATABASE).stores.keys()].sort(),
        [MNEMONIC_STORE, ONBOARDING_STORE, STATE_STORE].sort());
      assert.equal(isolated.store(ONBOARDING_STORE).size, 0);
      if (scenario === "upgrade") {
        assert.equal(isolated.peek(MNEMONIC_STORE, "existing"), MNEMONIC);
        assert.deepEqual(isolated.peek(STATE_STORE, "existing"), state);
      }
    }
    check();
  }
}
Object.defineProperty(globalThis, "indexedDB", {value: fake, configurable: true});
for (const [type, handler] of originalListeners) listeners.set(type, handler);

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

// --- Onboarding transactions -------------------------------------------------
{
  const user = "haystack-user";
  const fingerprint = "ab".repeat(32);
  const marker = {version: 1, revision: 0, step: "backup_seed", fingerprint};
  const data = '{"wallet":true}';
  let expected = '[]';
  const create = () => platform.createOnboardingWallet(user, MNEMONIC, data, marker, expected);
  const complete = (revision = 0, fp = fingerprint, stateRevision = 0, mnemonic = MNEMONIC, state = data) =>
    platform.completeOnboardingWallet(user, revision, fp, stateRevision, mnemonic, state, expected);
  const clearUser = () => {
    for (const store of [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE]) fake.store(store).delete(user);
  };
  clearUser();
  let absent = parse(await platform.loadOnboardingSnapshot());
  assert.equal(absent.hasMarker, false);
  assert.deepEqual(absent.wallets.find(w => w.name === user), {name: user, hasMnemonic: false, mnemonic: null, hasState: false, state: null});
  for (const store of [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE]) fake.seed(store, user, null);
  const nulls = parse(await platform.loadOnboardingSnapshot());
  assert.equal(nulls.hasMarker, true);
  assert.deepEqual(nulls.wallets.find(w => w.name === user), {name: user, hasMnemonic: true, mnemonic: null, hasState: true, state: null});
  for (const value of [undefined, 1n, NaN, Infinity, new Date(), (() => { const v = {}; v.self = v; return v; })()]) {
    fake.seed(STATE_STORE, user, value);
    await assert.rejects(platform.loadOnboardingSnapshot());
  }
  clearUser();
  const other = fake.peek(STATE_STORE, "wallet-a");
  fake.seed(MNEMONIC_STORE, user, MNEMONIC);
  await assert.rejects(create());
  assert.equal(fake.peek(MNEMONIC_STORE, user), MNEMONIC);
  assert.equal(fake.peek(STATE_STORE, user), undefined);
  clearUser();
  fake.seed(STATE_STORE, user, {revision: 5, data: "existing"});
  await assert.rejects(create());
  assert.deepEqual(fake.peek(STATE_STORE, user), {revision: 5, data: "existing"});
  clearUser();
  const stage = `haystack-recovery-${"a".repeat(32)}`;
  fake.seed(STATE_STORE, stage, null);
  assert.deepEqual(parse(await platform.loadOnboardingSnapshot()).wallets.find(w => w.name === stage),
    {name: stage, hasMnemonic: false, mnemonic: null, hasState: true, state: null});
  fake.store(STATE_STORE).delete(stage);
  fake.seed(MNEMONIC_STORE, "haystack-recovery-invalid", MNEMONIC);
  assert.ok(parse(await platform.loadOnboardingSnapshot()).wallets.some(w => w.name === "haystack-recovery-invalid"));
  await assert.rejects(create());
  fake.store(MNEMONIC_STORE).delete("haystack-recovery-invalid");
  fake.seed(ONBOARDING_STORE, "unexpected", {version: 99});
  assert.ok(parse(await platform.loadOnboardingSnapshot()).entries.some(entry => entry.key === "unexpected"));
  await assert.rejects(create());
  fake.store(ONBOARDING_STORE).delete("unexpected");
  fake.seed(MNEMONIC_STORE, stage, MNEMONIC);
  await assert.rejects(create());
  fake.seed(STATE_STORE, stage, {revision: 0, data});
  await assert.rejects(create());
  const retiredKey = `retired:${"a".repeat(32)}`;
  fake.seed(ONBOARDING_STORE, retiredKey, {version: 1, step: "retired", id: "a".repeat(32), fingerprint,
    mint: "https://mint.example", spendable_sats: "0", pending_sats: "0", spent_sats: "0"});
  expected = JSON.stringify([{id: "a".repeat(32), mnemonic: MNEMONIC, state: {revision: 0, data}, marker: fake.peek(ONBOARDING_STORE, retiredKey)}]);
  fake.peek(ONBOARDING_STORE, retiredKey).extra = true;
  await assert.rejects(create());
  delete fake.peek(ONBOARDING_STORE, retiredKey).extra;
  fake.peek(STATE_STORE, stage).extra = true;
  await assert.rejects(create());
  delete fake.peek(STATE_STORE, stage).extra;
  fake.abortNextWrite = true;
  await assert.rejects(create());
  assert.equal(fake.peek(MNEMONIC_STORE, user), undefined);
  assert.equal(fake.peek(STATE_STORE, user), undefined);
  assert.equal(fake.peek(ONBOARDING_STORE, user), undefined);
  fake.writeFailures = 1;
  await assert.rejects(create());
  assert.equal(fake.peek(MNEMONIC_STORE, user), undefined);
  await create();
  const snapshot = parse(await platform.loadOnboardingSnapshot());
  assert.deepEqual(snapshot.marker, marker);
  assert.deepEqual(snapshot.entries, [{key: retiredKey, marker: fake.peek(ONBOARDING_STORE, retiredKey)}]);
  assert.deepEqual(snapshot.wallets.find(w => w.name === user), {name: user, hasMnemonic: true, mnemonic: MNEMONIC, hasState: true, state: {revision: 0, data}});
  assert.ok(snapshot.wallets.some(w => w.name === stage));
  assert.ok(!snapshot.wallets.some(w => w.name === "wallet-a"));
  await assert.rejects(create());
  for (const attempt of [() => complete(1), () => complete(0, "cd".repeat(32)), () => complete(0, fingerprint, 1),
    () => complete(0, fingerprint, 0, OTHER_MNEMONIC), () => complete(0, fingerprint, 0, MNEMONIC, "different")]) {
    await assert.rejects(attempt());
    assert.deepEqual(fake.peek(ONBOARDING_STORE, user), marker);
  }
  fake.seed(ONBOARDING_STORE, "unexpected", null);
  await assert.rejects(complete());
  fake.store(ONBOARDING_STORE).delete("unexpected");
  fake.peek(ONBOARDING_STORE, retiredKey).extra = true;
  await assert.rejects(complete());
  delete fake.peek(ONBOARDING_STORE, retiredKey).extra;
  fake.peek(STATE_STORE, user).extra = true;
  await assert.rejects(complete());
  delete fake.peek(STATE_STORE, user).extra;
  fake.store(STATE_STORE).delete(stage);
  await assert.rejects(complete());
  fake.seed(STATE_STORE, stage, {revision: 0, data});
  await assert.rejects(complete(Number.MAX_SAFE_INTEGER));
  fake.abortNextWrite = true;
  await assert.rejects(complete());
  assert.deepEqual(fake.peek(ONBOARDING_STORE, user), marker);
  await complete();
  assert.deepEqual(fake.peek(ONBOARDING_STORE, user), {...marker, revision: 1, step: "complete"});
  await assert.rejects(complete());
  assert.deepEqual(fake.peek(STATE_STORE, user), {revision: 0, data});
  assert.deepEqual(fake.peek(STATE_STORE, "wallet-a"), other);
  clearUser();
  fake.store(MNEMONIC_STORE).delete(stage);
  fake.store(STATE_STORE).delete(stage);
  fake.store(ONBOARDING_STORE).delete(retiredKey);
  check("Onboarding creation and completion are atomic and compare all validated values");
}

// Recovery transitions preserve the audited raw stage and commit atomically.
{
  const user = "haystack-user", id = "1".repeat(32), key = `haystack-recovery-${id}`;
  const fingerprint = "ab".repeat(32), data = '{"stage":true}';
  const scan = {version: 1, revision: 0, step: "scanning", id, fingerprint, mint: "https://mint.example"};
  const failed = {...scan, revision: 1, step: "failed"};
  const retry = {...scan, revision: 2};
  const result = {...retry, revision: 3, step: "result", spendable_sats: "1", pending_sats: "0", spent_sats: "0"};
  const zero = {...result, spendable_sats: "0"};
  const backup = {version: 1, revision: 0, step: "backup_seed", fingerprint: "cd".repeat(32)};
  let expected = '[]';
  const stage = () => platform.stageOnboardingWallet(user, id, MNEMONIC, data, scan, expected);
  const update = (a, b, rev = 0, mnemonic = MNEMONIC, raw = data) => platform.updateOnboardingScan(user, a, b, rev, mnemonic, raw, expected);
  const restore = (m = result, rev = 0) => platform.finishOnboardingRestore(user, m, rev, MNEMONIC, data, expected);
  const generate = (m = zero, rev = 0, b = backup) => platform.generateOnboardingWallet(user, m, rev, MNEMONIC, data, OTHER_MNEMONIC, "new", b, expected);
  fake.seed(MNEMONIC_STORE, user, MNEMONIC);
  await assert.rejects(stage());
  fake.store(MNEMONIC_STORE).delete(user);
  fake.seed(MNEMONIC_STORE, "haystack-recovery-bad", MNEMONIC);
  await assert.rejects(stage());
  fake.store(MNEMONIC_STORE).delete("haystack-recovery-bad");
  fake.abortNextWrite = true;
  await assert.rejects(stage());
  assert.equal(fake.peek(MNEMONIC_STORE, key), undefined);
  await stage();
  await assert.rejects(update(scan, failed, 1));
  await assert.rejects(update({...scan, mint: "different"}, failed));
  await assert.rejects(update(scan, {...failed, extra: true}));
  await update(scan, failed);
  assert.equal(fake.peek(MNEMONIC_STORE, key), MNEMONIC);
  await update(failed, retry);
  await assert.rejects(update(retry, {...result, spendable_sats: "18446744073709551616"}));
  await update(retry, result);
  await assert.rejects(generate(result));
  await assert.rejects(restore(result, 1));
  fake.seed(STATE_STORE, user, {revision: 0, data: "half"});
  await assert.rejects(restore());
  fake.store(STATE_STORE).delete(user);
  fake.abortNextWrite = true;
  await assert.rejects(restore());
  assert.equal(fake.peek(MNEMONIC_STORE, key), MNEMONIC);
  assert.equal(fake.peek(MNEMONIC_STORE, user), undefined);
  await restore();
  assert.equal(fake.peek(MNEMONIC_STORE, key), undefined);
  assert.equal(fake.peek(MNEMONIC_STORE, user), MNEMONIC);
  assert.deepEqual(fake.peek(ONBOARDING_STORE, user), {version: 1, revision: 4, step: "complete", fingerprint});
  for (const store of [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE]) fake.store(store).delete(user);
  await stage();
  await update(scan, {...zero, revision: 1});
  const zero1 = {...zero, revision: 1};
  await assert.rejects(restore(zero1));
  await assert.rejects(generate(zero1, 1));
  await assert.rejects(generate(zero1, 0, {...backup, fingerprint}));
  fake.abortNextWrite = true;
  await assert.rejects(generate(zero1));
  assert.equal(fake.peek(ONBOARDING_STORE, `retired:${id}`), undefined);
  await generate(zero1);
  assert.equal(fake.peek(MNEMONIC_STORE, key), MNEMONIC);
  assert.deepEqual(fake.peek(STATE_STORE, key), {revision: 0, data});
  assert.equal(fake.peek(MNEMONIC_STORE, user), OTHER_MNEMONIC);
  assert.equal(fake.peek(ONBOARDING_STORE, `retired:${id}`).step, "retired");
  for (const store of [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE]) fake.store(store).delete(user);
  fake.store(MNEMONIC_STORE).delete(key);
  fake.store(STATE_STORE).delete(key);
  fake.store(ONBOARDING_STORE).delete(`retired:${id}`);
  check("Recovery transitions enforce CAS, gating, orphan checks and rollback");
}

// Retired records must match the previously audited snapshot for every transition.
{
  const user = "haystack-user", id = "2".repeat(32), active = "3".repeat(32);
  const key = `haystack-recovery-${id}`, activeKey = `haystack-recovery-${active}`;
  const fingerprint = "ab".repeat(32), mint = "mint";
  const retired = {version: 1, step: "retired", id, fingerprint, mint, spendable_sats: "0", pending_sats: "0", spent_sats: "0"};
  const entry = {id, mnemonic: MNEMONIC, state: {revision: 4, data: "raw"}, marker: retired};
  const expected = JSON.stringify([entry]);
  const backup = {version: 1, revision: 0, step: "backup_seed", fingerprint};
  const scan = {version: 1, revision: 0, step: "scanning", id: active, fingerprint, mint};
  const result = {...scan, step: "result", spendable_sats: "1", pending_sats: "0", spent_sats: "0"};
  const zero = {...result, spendable_sats: "0"};
  const cases = [
    [null, e => platform.createOnboardingWallet(user, MNEMONIC, "data", backup, e)],
    [backup, e => platform.completeOnboardingWallet(user, 0, fingerprint, 0, MNEMONIC, "data", e)],
    [null, e => platform.stageOnboardingWallet(user, active, MNEMONIC, "data", scan, e)],
    [scan, e => platform.updateOnboardingScan(user, scan, {...scan, revision: 1}, 0, MNEMONIC, "data", e)],
    [result, e => platform.finishOnboardingRestore(user, result, 0, MNEMONIC, "data", e)],
    [zero, e => platform.generateOnboardingWallet(user, zero, 0, MNEMONIC, "data", OTHER_MNEMONIC, "new", {...backup, fingerprint: "cd".repeat(32)}, e)],
  ];
  const clear = () => {
    for (const store of [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE]) {
      for (const k of [user, key, activeKey, `retired:${id}`]) fake.store(store).delete(k);
    }
  };
  for (let i = 0; i < cases.length; i++) {
    const [marker, run] = cases[i];
    const setup = () => {
      clear();
      fake.seed(MNEMONIC_STORE, key, MNEMONIC);
      fake.seed(STATE_STORE, key, {revision: 4, data: "raw"});
      fake.seed(ONBOARDING_STORE, `retired:${id}`, {...retired});
      if (i === 1) {
        fake.seed(MNEMONIC_STORE, user, MNEMONIC);
        fake.seed(STATE_STORE, user, {revision: 0, data: "data"});
      }
      if (i >= 3) {
        fake.seed(MNEMONIC_STORE, activeKey, MNEMONIC);
        fake.seed(STATE_STORE, activeKey, {revision: 0, data: "data"});
      }
      if (marker) fake.seed(ONBOARDING_STORE, user, {...marker});
    };
    const mutations = [
      () => fake.seed(MNEMONIC_STORE, key, OTHER_MNEMONIC),
      () => fake.seed(STATE_STORE, key, {revision: 4, data: "changed"}),
      () => fake.seed(STATE_STORE, key, {revision: 5, data: "raw"}),
      () => fake.seed(ONBOARDING_STORE, `retired:${id}`, {...retired, mint: "other"}),
      () => fake.store(ONBOARDING_STORE).delete(`retired:${id}`),
    ];
    for (const mutate of mutations) {
      setup(); mutate();
      const before = await platform.loadOnboardingSnapshot();
      await assert.rejects(run(expected));
      assert.equal(await platform.loadOnboardingSnapshot(), before);
    }
    setup();
    for (const invalid of [undefined, null, "null", "{}", "bad", JSON.stringify([entry, entry]),
      JSON.stringify([{...entry, extra: 1}]), JSON.stringify([{...entry, state: {...entry.state, extra: 1}}]),
      JSON.stringify([{...entry, marker: {...retired, extra: 1}}]), '[]']) {
      const before = await platform.loadOnboardingSnapshot();
      await assert.rejects(run(invalid));
      assert.equal(await platform.loadOnboardingSnapshot(), before);
    }
    // Marker property order is not significant.
    const reversed = Object.fromEntries(Object.entries(retired).reverse());
    await run(JSON.stringify([{...entry, marker: reversed}]));
  }
  clear();
  check("All onboarding transitions bind retired records to the audited snapshot");
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
