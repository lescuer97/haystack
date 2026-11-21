// Node-only harness for browser/wallet/platform.js.
//
// Chromium is not always available, so this test runs the wallet IndexedDB
// layer against the shared in-memory model in
// `test-support/fake-indexeddb.mjs`. It covers atomic provisioning,
// compare-and-swap writes, conflict rejection, injected write/abort failures,
// fresh reads and the persistent storage request helper.
//
// The model does not emulate real browser durability, Web Locks, or a shared
// database across tabs; see its module header for the documented limits. Run
// `zig build test -Dplatform=wasm` for the Chromium suite.

import {strict as assert} from "node:assert";
import {readFile} from "node:fs/promises";
import vm from "node:vm";
import * as walletStore from "./wallet-store.js";
import {FakeIndexedDB as SharedFakeIndexedDB, FakeDatabase, FakeRequest} from "./test-support/fake-indexeddb.mjs";

const DATABASE = "haystack-wallet";
const MNEMONIC_STORE = "mnemonics";
const STATE_STORE = "states";
const ONBOARDING_STORE = "onboarding";

// The request/transaction/upgrade model is shared with the game storage
// harness; this adapter only binds it to the wallet database.
class FakeIndexedDB extends SharedFakeIndexedDB {
  constructor() {
    super({database: DATABASE});
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
const setIndexedDB = value => Object.defineProperty(globalThis, "indexedDB", {value, configurable: true});

const MNEMONIC = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const OTHER_MNEMONIC = "legal winner thank year wave sausage worth useful legal winner thank yellow";
const parse = raw => JSON.parse(raw);
let checks = 0;
function check() {
  checks += 1;
}

const originalListeners = new Map(listeners);

// The game library only notifies the UI; no wallet helpers or entrypoints remain.
const uiSource = await readFile(new URL("./game-ui.js", import.meta.url), "utf8");
for (const module of [undefined, {}, {onHaystackStartup() { throw new Error("cosmetic"); }}]) {
  const library = {};
  vm.runInNewContext(uiSource, {Module: module, LibraryManager: {library}, mergeInto: Object.assign});
  assert.deepEqual(Object.keys(library).sort(), ["haystack_ui_result", "haystack_ui_result__sig"]);
  assert.equal(library.haystack_ui_result__sig, "vi");
  assert.doesNotThrow(() => library.haystack_ui_result(1));
  assert.doesNotThrow(() => library.haystack_ui_result(0));
  check();
}
{
  const library = {};
  const results = [];
  vm.runInNewContext(uiSource, {Module: {onHaystackStartup: value => results.push(value)}, LibraryManager: {library}, mergeInto: Object.assign});
  library.haystack_ui_result(1);
  library.haystack_ui_result(0);
  assert.deepEqual(results, ["ready", "error"]);
  check();
}
// Exercise both independent openers against fresh, v1, and newer databases.
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
      if (label === "platform" && scenario === "upgrade") {
        await assert.rejects(read("existing"), /wallet state record is malformed/);
      } else {
        await read("existing");
      }
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
  const expectedPayload = (marker, stateRevision = 0, mnemonic = MNEMONIC, state = data) =>
    ({marker, state: {revision: stateRevision, data: state}, mnemonic, retired: expected});
  const complete = (revision = 0, fp = fingerprint, stateRevision = 0, mnemonic = MNEMONIC, state = data) =>
    platform.completeOnboardingWallet(user, expectedPayload({...marker, revision, fingerprint: fp}, stateRevision, mnemonic, state));
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
    mint: "https://mint.example", spendable_msats: "0", pending_msats: "0", spent_msats: "0"});
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
  // The expected snapshot is one named payload validated before any transaction
  // opens: strict field keys, a whole marker and safe-integer revisions.
  for (const malformed of [
    {...expectedPayload(marker), extra: true},
    {...expectedPayload(marker), state: {...expectedPayload(marker).state, extra: true}},
    {...expectedPayload(marker), marker: {...marker, extra: true}},
    {...expectedPayload(marker), state: {revision: -1, data}},
    {...expectedPayload(marker), state: {revision: 1.5, data}},
    {...expectedPayload(marker), state: {revision: Number.MAX_SAFE_INTEGER + 1, data}},
    {...expectedPayload(marker), mnemonic: ""},
    {...expectedPayload(marker), retired: 7},
  ]) {
    await assert.rejects(platform.completeOnboardingWallet(user, malformed));
    assert.deepEqual(fake.peek(ONBOARDING_STORE, user), marker);
  }
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
  const result = {...retry, revision: 3, step: "result", spendable_msats: "1", pending_msats: "0", spent_msats: "0"};
  const zero = {...result, spendable_msats: "0"};
  const backup = {version: 1, revision: 0, step: "backup_seed", fingerprint: "cd".repeat(32)};
  let expected = '[]';
  const stage = () => platform.stageOnboardingWallet(user, id, MNEMONIC, data, scan, expected);
  const expectedPayload = (marker, revision = 0, mnemonic = MNEMONIC, state = data) =>
    ({marker, state: {revision, data: state}, mnemonic, retired: expected});
  const update = (a, b, rev = 0, mnemonic = MNEMONIC, raw = data) => platform.updateOnboardingScan(user, expectedPayload(a, rev, mnemonic, raw), b);
  const restore = (m = result, rev = 0) => platform.finishOnboardingRestore(user, expectedPayload(m, rev));
  const generate = (m = zero, rev = 0, b = backup) => platform.generateOnboardingWallet(user, expectedPayload(m, rev), {mnemonic: OTHER_MNEMONIC, state: "new", marker: b});
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
  await assert.rejects(update(retry, {...result, spendable_msats: "18446744073709551616"}));
  await update(retry, result);
  // The expected snapshot and the replacement wallet both have strict field keys.
  await assert.rejects(platform.finishOnboardingRestore(user, {...expectedPayload(result), extra: true}));
  await assert.rejects(platform.generateOnboardingWallet(user, expectedPayload(zero), {mnemonic: OTHER_MNEMONIC, state: "new", marker: backup, extra: true}));
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
  const retired = {version: 1, step: "retired", id, fingerprint, mint, spendable_msats: "0", pending_msats: "0", spent_msats: "0"};
  const entry = {id, mnemonic: MNEMONIC, state: {revision: 4, data: "raw"}, marker: retired};
  const expected = JSON.stringify([entry]);
  const backup = {version: 1, revision: 0, step: "backup_seed", fingerprint};
  const scan = {version: 1, revision: 0, step: "scanning", id: active, fingerprint, mint};
  const result = {...scan, step: "result", spendable_msats: "1", pending_msats: "0", spent_msats: "0"};
  const zero = {...result, spendable_msats: "0"};
  const payload = (e, marker, revision = 0, mnemonic = MNEMONIC, state = "data") =>
    ({marker, state: {revision, data: state}, mnemonic, retired: e});
  const cases = [
    [null, e => platform.createOnboardingWallet(user, MNEMONIC, "data", backup, e)],
    [backup, e => platform.completeOnboardingWallet(user, payload(e, backup))],
    [null, e => platform.stageOnboardingWallet(user, active, MNEMONIC, "data", scan, e)],
    [scan, e => platform.updateOnboardingScan(user, payload(e, scan), {...scan, revision: 1})],
    [result, e => platform.finishOnboardingRestore(user, payload(e, result))],
    [zero, e => platform.generateOnboardingWallet(user, payload(e, zero), {mnemonic: OTHER_MNEMONIC, state: "new", marker: {...backup, fingerprint: "cd".repeat(32)}})],
  ];
  const clear = () => {
    for (const store of [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE]) {
      for (const k of [user, key, activeKey, `retired:${id}`, `retired:${active}`]) fake.store(store).delete(k);
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
    setup();
    // Rust serializes audited retired records with the new field names.
    const legacy = Object.fromEntries(Object.entries(retired).map(([k, v]) => [k.replace(/_msats$/, "_sats"), v]));
    fake.seed(ONBOARDING_STORE, `retired:${id}`, legacy);
    await run(expected);
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

// Strict bridge inputs and stored envelopes never silently lose information.
{
  const name = "strict-record";
  const original = {revision: 0, data: "raw"};
  fake.seed(STATE_STORE, name, original);
  for (const revision of [null, true, false, 0, 1, {}, [], "", " ", "00", " 0", "0 ", "+0", "-0", "0x0", "0e0", "0.0",
    ...["\n", "\r", "\u2028", "\u2029"].map(end => "0" + end)]) {
    await assert.rejects(platform.writeWalletState(name, revision, "changed"), /revision is invalid/);
    assert.equal(fake.peek(STATE_STORE, name), original);
  }
  for (const end of ["\n", "\r", "\u2028", "\u2029"]) {
    for (const call of [() => platform.loadWallet("valid" + end),
      () => platform.provisionWallet("valid" + end, MNEMONIC, "raw"),
      () => platform.writeWalletState("valid" + end, "0", "raw")]) await assert.rejects(call(), /name is invalid/);
    const id = "a".repeat(32), fingerprint = "b".repeat(64);
    await assert.rejects(platform.createOnboardingWallet("haystack-user", MNEMONIC, "raw",
      {version: 1, revision: 0, step: "backup_seed", fingerprint: fingerprint + end}, "[]"));
    const marker = {version: 1, revision: 0, step: "scanning", id, fingerprint, mint: "mint"};
    await assert.rejects(platform.stageOnboardingWallet("haystack-user", id + end, MNEMONIC, "raw", {...marker, id: id + end}, "[]"));
    const result = {...marker, step: "result", spendable_msats: "1" + end, pending_msats: "0", spent_msats: "0"};
    await assert.rejects(platform.finishOnboardingRestore("haystack-user", {
      marker: result, state: original, mnemonic: MNEMONIC, retired: "[]",
    }), /invalid onboarding restore input/);
  }
  for (const state of [undefined, null, {...original, extra: true}, {"revision,data": 0, data: "raw"},
    {...original, [Symbol("hidden")]: true}, Object.defineProperty({...original}, "hidden", {value: 1}),
    {get revision() { throw new Error("must not access"); }, data: "raw"},
    Object.assign(Object.create({revision: 0}), {data: "raw"}), {...original, revision: -0}]) {
    fake.seed(STATE_STORE, name, state);
    await assert.rejects(platform.loadWallet(name), /state record is malformed/);
    assert.equal(fake.store(STATE_STORE).has(name), true);
    assert.equal(fake.peek(STATE_STORE, name), state);
  }
  fake.seed(STATE_STORE, name, {revision: Number.MAX_SAFE_INTEGER - 1, data: "raw"});
  await platform.writeWalletState(name, String(Number.MAX_SAFE_INTEGER - 1), "max");
  assert.equal(parse(await platform.loadWallet(name)).state.revision, Number.MAX_SAFE_INTEGER);
  await assert.rejects(platform.writeWalletState(name, String(Number.MAX_SAFE_INTEGER), "unsafe"), /revision is invalid/);
  for (const value of [undefined, null]) {
    fake.seed(MNEMONIC_STORE, "present-invalid", value);
    await assert.rejects(platform.loadWallet("present-invalid"), /mnemonic record is malformed/);
    assert.equal(fake.store(MNEMONIC_STORE).has("present-invalid"), true);
  }
  assert.deepEqual(parse(await platform.loadWallet("strict-record")), {mnemonic: null, state: {revision: Number.MAX_SAFE_INTEGER, data: "max"}});
  check("Strict revisions, names, fixed hex, totals, presence and own data keys");
}

// Request errors cannot half-commit even when another listener cancels default
// abort. Unexpected request/setup/callback messages never cross the bridge.
{
  fake.preventRequestErrors = true;
  for (const store of [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE]) fake.store(store).delete("haystack-user");
  fake.seed(STATE_STORE, "prevented-duplicate", {revision: 0, data: "original"});
  await assert.rejects(platform.provisionWallet("prevented-duplicate", MNEMONIC, "raw"), /wallet already exists/);
  assert.equal(fake.peek(MNEMONIC_STORE, "prevented-duplicate"), undefined);
  fake.writeFailures = 1;
  await assert.rejects(platform.provisionWallet("prevented-io", MNEMONIC, "raw"), /^Error: wallet provisioning failed$/);
  assert.equal(fake.peek(STATE_STORE, "prevented-io"), undefined);
  fake.readFailures = 1;
  await assert.rejects(platform.loadWallet("wallet-a"), /^Error: wallet storage read failed$/);
  fake.failReadKeys.add("wallet-a");
  await assert.rejects(platform.writeWalletState("wallet-a", "7", "raw"), /^Error: wallet storage write failed$/);
  fake.failReadKeys.clear();
  fake.failWriteKeys.add("haystack-user");
  await assert.rejects(platform.createOnboardingWallet("haystack-user", MNEMONIC, "raw",
    {version: 1, revision: 0, step: "backup_seed", fingerprint: "a".repeat(64)}, "[]"), /^Error: onboarding transition refused$/);
  assert.equal(fake.peek(STATE_STORE, "haystack-user"), undefined);
  fake.failWriteKeys.clear();
  fake.preventRequestErrors = false;
  check("Prevented errors explicitly abort all wallet and onboarding writes");
}

// Controlled opens exercise callbacks the deliberately small shared fake does
// not model (a blocked request resuming, and a stale connection's late events).
{
  const flush = () => new Promise(resolve => setImmediate(resolve));
  for (const failure of ["onblocked", "onerror"]) {
    const isolated = new FakeIndexedDB();
    const record = isolated.ensure({version: 2, stores: [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE]});
    const requests = [];
    setIndexedDB({open() { const r = new FakeRequest(); requests.push(r); return r; }});
    const p = await import(`./wallet/platform.js?ownership-${failure}`);
    const first = p.loadWallet("absent");
    await flush();
    requests[0][failure]();
    await assert.rejects(first);
    const second = p.loadWallet("absent");
    await flush();
    const current = new FakeDatabase(record, isolated);
    requests[1].result = current;
    requests[1].onsuccess();
    await second;
    let aborted = false, created = false;
    requests[0].transaction = {abort() { aborted = true; }};
    requests[0].result = {objectStoreNames: {contains() { created = true; return false; }}};
    requests[0].onupgradeneeded();
    assert.equal(aborted, true);
    assert.equal(created, false);
    const late = {close() { this.closed = true; }};
    requests[0].result = late;
    requests[0].onsuccess();
    assert.equal(late.closed, true);
    await p.loadWallet("absent");
    assert.equal(requests.length, 2);
    current.onversionchange();
    assert.equal(current.closed, true);
    const third = p.loadWallet("absent");
    await flush();
    const newest = new FakeDatabase(record, isolated);
    requests[2].result = newest;
    requests[2].onsuccess();
    await third;
    current.onclose();
    await p.loadWallet("absent");
    assert.equal(requests.length, 3, "stale close cannot clear the current cache");
    newest.onclose();
    const fourth = p.loadWallet("absent");
    await flush();
    requests[3].result = new FakeDatabase(record, isolated);
    requests[3].onsuccess();
    await fourth;
    check("Open ownership survives late upgrade, success, versionchange and close");
  }
  // Upgrade callback exceptions abort and reject without caching the attempt.
  const requests = [];
  setIndexedDB({open() { const r = new FakeRequest(); requests.push(r); return r; }});
  const p = await import("./wallet/platform.js?upgrade-throws");
  const pending = p.loadWallet("absent");
  await flush();
  let aborted = false;
  requests[0].transaction = {abort() { aborted = true; }};
  requests[0].result = {objectStoreNames: {contains() { throw new Error(MNEMONIC); }}};
  requests[0].onupgradeneeded();
  await assert.rejects(pending, /^Error: IndexedDB could not be opened$/);
  assert.equal(aborted, true);
  setIndexedDB(fake);
  check("Upgrade callback errors are sanitized and abort");
}

// Capture inputs while blocked on opening, then while queued behind the create.
{
  const isolated = new FakeIndexedDB();
  const record = isolated.ensure({version: 2, stores: [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE]});
  const request = new FakeRequest();
  setIndexedDB({open() { return request; }});
  const p = await import("./wallet/platform.js?capture-open-and-queue");
  const marker = {version: 1, revision: 0, step: "backup_seed", fingerprint: "a".repeat(64)};
  const creation = p.createOnboardingWallet("haystack-user", MNEMONIC, "raw", marker, "[]");
  await new Promise(resolve => setImmediate(resolve));
  const snapshot = {marker: {...marker}, state: {revision: 0, data: "raw"}, mnemonic: MNEMONIC, retired: "[]"};
  const completion = p.completeOnboardingWallet("haystack-user", snapshot);
  marker.fingerprint = "b".repeat(64);
  snapshot.marker.fingerprint = "c".repeat(64);
  snapshot.state.data = "changed";
  snapshot.mnemonic = OTHER_MNEMONIC;
  request.result = new FakeDatabase(record, isolated);
  request.onsuccess();
  await creation;
  await completion;
  assert.deepEqual(isolated.peek(ONBOARDING_STORE, "haystack-user"), {
    version: 1, revision: 1, step: "complete", fingerprint: "a".repeat(64),
  });
  assert.deepEqual(isolated.peek(STATE_STORE, "haystack-user"), {revision: 0, data: "raw"});
  for (const name of [MNEMONIC_STORE, STATE_STORE, ONBOARDING_STORE]) isolated.store(name).clear();
  const id = "d".repeat(32), key = `haystack-recovery-${id}`;
  const scan = {version: 1, revision: 0, step: "scanning", id, fingerprint: "e".repeat(64), mint: "mint"};
  const staged = p.stageOnboardingWallet("haystack-user", id, MNEMONIC, "stage", scan, "[]");
  const scanSnapshot = {marker: {...scan}, state: {revision: 0, data: "stage"}, mnemonic: MNEMONIC, retired: "[]"};
  const result = {...scan, revision: 1, step: "result", spendable_msats: "0", pending_msats: "0", spent_msats: "0"};
  const updated = p.updateOnboardingScan("haystack-user", scanSnapshot, result);
  const generationSnapshot = {...scanSnapshot, marker: {...result}, state: {...scanSnapshot.state}};
  const replacement = {mnemonic: OTHER_MNEMONIC, state: "replacement", marker: {...marker, fingerprint: "f".repeat(64)}};
  const generated = p.generateOnboardingWallet("haystack-user", generationSnapshot, replacement);
  scan.id = "0".repeat(32);
  scanSnapshot.state.data = "changed";
  scanSnapshot.marker.mint = "changed";
  result.pending_msats = "1";
  generationSnapshot.marker.spendable_msats = "1";
  generationSnapshot.state.data = "changed";
  replacement.mnemonic = MNEMONIC;
  replacement.state = "changed";
  replacement.marker.fingerprint = "0".repeat(64);
  await Promise.all([staged, updated, generated]);
  assert.equal(isolated.peek(MNEMONIC_STORE, key), MNEMONIC);
  assert.deepEqual(isolated.peek(STATE_STORE, key), {revision: 0, data: "stage"});
  assert.equal(isolated.peek(MNEMONIC_STORE, "haystack-user"), OTHER_MNEMONIC);
  assert.deepEqual(isolated.peek(STATE_STORE, "haystack-user"), {revision: 0, data: "replacement"});
  assert.equal(isolated.peek(ONBOARDING_STORE, "haystack-user").fingerprint, "f".repeat(64));
  assert.equal(isolated.peek(ONBOARDING_STORE, `retired:${id}`).fingerprint, "e".repeat(64));
  setIndexedDB(fake);
  check("All mutable onboarding inputs are captured across open and queue waits");
}

// Synthetic transaction faults prove success needs all request callbacks, and
// setup/callback exceptions cannot expose arbitrary database error text.
{
  const isolated = new FakeIndexedDB();
  setIndexedDB(isolated);
  const p = await import("./wallet/platform.js?transaction-faults");
  await p.loadWallet("absent");
  const db = isolated.latest();
  const transaction = db.transaction.bind(db);
  db.transaction = () => {
    const tx = {objectStore() { return {getKey: () => new FakeRequest(), get: () => new FakeRequest()}; }};
    queueMicrotask(() => tx.oncomplete());
    return tx;
  };
  await assert.rejects(p.loadWallet("absent"), /^Error: wallet storage read failed$/);
  db.transaction = (...args) => {
    const tx = transaction(...args);
    tx.objectStore = () => { throw new Error(MNEMONIC); };
    return tx;
  };
  await assert.rejects(p.provisionWallet("absent", MNEMONIC, "raw"), /^Error: wallet provisioning failed$/);
  db.transaction = (...args) => {
    const tx = transaction(...args);
    const objectStore = tx.objectStore.bind(tx);
    tx.objectStore = name => {
      const store = objectStore(name);
      const getAllKeys = store.getAllKeys.bind(store);
      store.getAllKeys = () => {
        const request = getAllKeys();
        Object.defineProperty(request, "result", {get() { throw new Error(MNEMONIC); }, set() {}});
        return request;
      };
      return store;
    };
    return tx;
  };
  await assert.rejects(p.loadOnboardingSnapshot(), /^Error: onboarding storage read failed$/);
  db.transaction = transaction;
  setIndexedDB(fake);
  check("Incomplete complete events and setup/callback exceptions fail closed");
}

// Isolated modules allow poison races without poisoning the main harness.
{
  const originalLocks = navigator.locks;
  const flush = () => new Promise(resolve => setImmediate(resolve));
  navigator.locks = {request(_name, _options, grant) { return Promise.resolve().then(() => grant({})); }};
  const before = await import("./wallet/platform.js?poison-before-grant");
  const pending = before.acquireWalletLock("lock:before");
  listeners.get("unhandledrejection")({reason: new WebAssembly.RuntimeError("fixture")});
  await assert.rejects(pending, /Wasm instance failed/);
  // A previous release has begun but the lock manager's request never settles.
  let finish;
  navigator.locks = {request(_name, _options, grant) {
    queueMicrotask(() => grant({}));
    return new Promise(resolve => { finish = resolve; });
  }};
  const closing = await import("./wallet/platform.js?poison-during-close");
  const release = await closing.acquireWalletLock("lock:closing");
  release();
  const reopen = closing.acquireWalletLock("lock:closing");
  const rejected = assert.rejects(reopen, /Wasm instance failed/);
  listeners.get("error")({error: new WebAssembly.RuntimeError("fixture")});
  await Promise.race([rejected, new Promise((_, reject) => {
    const timer = setTimeout(() => reject(new Error("poison rejection was not prompt")), 1000);
    rejected.finally(() => clearTimeout(timer));
  })]);
  finish();
  await flush();
  for (const sync of [true, false]) {
    navigator.locks = {request() { if (sync) throw new Error("fixture"); return Promise.reject(new Error("fixture")); }};
    const p = await import(`./wallet/platform.js?lock-request-error-${sync}`);
    await assert.rejects(p.acquireWalletLock("lock:failed"));
    navigator.locks = originalLocks;
    const release = await p.acquireWalletLock("lock:failed");
    await Promise.all([release(), release()]);
    const again = await p.acquireWalletLock("lock:failed");
    await again();
  }
  navigator.locks = undefined;
  const absent = await import("./wallet/platform.js?no-lock-api");
  await assert.rejects(absent.acquireWalletLock("lock:absent"), /Web Locks are required/);
  navigator.locks = originalLocks;
  const plain = await import("./wallet/platform.js?plain-error");
  listeners.get("error")({error: new Error("fixture")});
  const normal = await plain.acquireWalletLock("lock:plain");
  await normal();
  for (const [type, handler] of originalListeners) listeners.set(type, handler);
  check("Poison races, request failure cleanup, repeated release and plain errors");
}

// --- Wasm runtime traps keep held locks and reject new acquisitions ----------
{
  const release = await platform.acquireWalletLock("trap-wallet");
  assert.equal(typeof release, "function");
  listeners.get("error")({error: new WebAssembly.RuntimeError("trap")});
  await assert.rejects(platform.acquireWalletLock("trap-wallet"), /Wasm instance failed/);
  await assert.rejects(platform.acquireWalletLock("other-wallet"), /Wasm instance failed/);
  assert.ok(lockState.held.has("trap-wallet"), "the held lock stays until document destruction");
  let settled = false;
  release().then(() => { settled = true; });
  await Promise.resolve();
  assert.equal(settled, false);
  assert.ok(lockState.held.has("trap-wallet"), "late release must not unlock a poisoned document");
  check("Wasm runtime traps retain held locks and reject new acquisitions");
}

console.log(`wallet IndexedDB tests passed (${checks} checks)`);
