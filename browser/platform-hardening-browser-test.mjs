// Real-Chromium regression coverage for browser/wallet/platform.js hardening.
//
// The runner owns Chromium and a disposable profile, serves only a minimal
// non-application page and the actual platform module bytes over loopback HTTP,
// and drives the production module directly. It needs no Wasm bundle, no Rust
// fixture and no fake mint. Each scenario runs in a disposable browser context;
// Web Lock scenarios use two tabs in the same context and origin so the browser,
// not a JS fake, enforces contention. The runner prints fixed case labels and a
// sanitized pass/fail only.
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {
  bounded, CdpConnection, discoverEndpoint, launchBrowser, makeProfile,
  removeProfile, stopBrowser,
} from './cdp-runner.mjs';

const MNEMONIC = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const OTHER_MNEMONIC = 'legal winner thank year wave sausage worth useful legal winner thank yellow';
const USER = 'haystack-user';

const PAGE = String.raw`<!doctype html>
<meta charset="utf-8">
<title>platform hardening</title>
<script>
(() => {
  const nativeOpen = indexedDB.open.bind(indexedDB);
  const state = {opens: [], preventRequestErrors: false};
  Object.defineProperty(window, '__hardening', {value: state});
  indexedDB.open = function (name, version) {
    const request = version === undefined ? nativeOpen(name) : nativeOpen(name, version);
    const record = {
      version: version === undefined ? null : version,
      request,
      blocked: false,
      upgraded: false,
      success: false,
      error: null,
      closed: false,
      versionchange: false,
    };
    state.opens.push(record);
    request.addEventListener('blocked', () => { record.blocked = true; });
    request.addEventListener('upgradeneeded', () => { record.upgraded = true; });
    request.addEventListener('error', () => { record.error = request.error ? request.error.name : 'error'; });
    request.addEventListener('success', () => {
      record.success = true;
      const database = request.result;
      const close = database.close.bind(database);
      database.close = () => { record.closed = true; close(); };
      database.addEventListener('error', event => {
        if (state.preventRequestErrors) event.preventDefault();
      });
      database.addEventListener('versionchange', () => { record.versionchange = true; });
    });
    return request;
  };
})();
</script>`;

const PRELUDE = `
const MNEMONIC = ${JSON.stringify(MNEMONIC)};
const OTHER_MNEMONIC = ${JSON.stringify(OTHER_MNEMONIC)};
const USER = ${JSON.stringify(USER)};
const DB = 'haystack-wallet';
const canonical = value => {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') {
    return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
  }
  return JSON.stringify(value);
};
const eq = (actual, expected, code) => {
  if (canonical(actual) !== canonical(expected)) throw new Error(code);
};
const truth = (value, code) => { if (!value) throw new Error(code); };
const rejects = async (promise, code) => {
  try { await promise; } catch (error) { return error; }
  throw new Error(code);
};
const rawOpen = (name, version, create) => new Promise((resolve, reject) => {
  const request = version === undefined ? indexedDB.open(name) : indexedDB.open(name, version);
  if (create) request.onupgradeneeded = () => create(request.result, request.transaction);
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(new Error('raw open failed'));
  request.onblocked = () => reject(new Error('raw open blocked'));
});
const rawPut = (database, storeName, value, key) => new Promise((resolve, reject) => {
  let transaction;
  try { transaction = database.transaction(storeName, 'readwrite'); }
  catch (_) { reject(new Error('raw transaction failed')); return; }
  transaction.objectStore(storeName).put(value, key);
  transaction.oncomplete = () => resolve();
  transaction.onabort = () => reject(new Error('raw put aborted'));
  transaction.onerror = () => {};
});
const rawGet = (database, storeName, key) => new Promise((resolve, reject) => {
  let transaction;
  try { transaction = database.transaction(storeName, 'readonly'); }
  catch (_) { reject(new Error('raw read failed')); return; }
  const request = transaction.objectStore(storeName).get(key);
  transaction.oncomplete = () => resolve(request.result);
  transaction.onabort = () => reject(new Error('raw read aborted'));
  transaction.onerror = () => {};
});
const rawKeys = (database, storeName) => new Promise((resolve, reject) => {
  let transaction;
  try { transaction = database.transaction(storeName, 'readonly'); }
  catch (_) { reject(new Error('raw keys failed')); return; }
  const request = transaction.objectStore(storeName).getAllKeys();
  transaction.oncomplete = () => resolve(Array.from(request.result));
  transaction.onabort = () => reject(new Error('raw keys aborted'));
  transaction.onerror = () => {};
});
// readyState can already be 'done' during upgradeneeded, before the open settles.
const waitForOpen = ({request, success, error}) => {
  if (success || error) return Promise.resolve();
  return new Promise(resolve => {
    request.addEventListener('success', resolve, {once: true});
    request.addEventListener('error', resolve, {once: true});
  });
};
const rawStoreNames = database => Array.from(database.objectStoreNames);
`;

const platformSource = await readFile(new URL('./wallet/platform.js', import.meta.url));

const server = createServer((request, response) => {
  let pathname;
  try { pathname = new URL(request.url, 'http://127.0.0.1').pathname; }
  catch (_) { response.writeHead(400); response.end(); return; }
  if (request.method !== 'GET') { response.writeHead(405); response.end(); return; }
  if (pathname === '/') {
    response.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    });
    response.end(PAGE);
    return;
  }
  if (pathname === '/platform.js') {
    response.writeHead(200, {
      'Content-Type': 'text/javascript; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    });
    response.end(platformSource);
    return;
  }
  response.writeHead(404, {'Content-Type': 'text/plain; charset=utf-8'});
  response.end('not found');
});

let origin;
let profile;
let browser;
const contexts = new Set();
const results = [];
let incomplete = false;
let cleanupFailure = false;
let connection = null;

const send = (method, params = {}, sessionId) => connection.send(method, params, sessionId);
const once = (method, sessionId) => connection.once(method, sessionId);

async function newContext() {
  const {browserContextId} = await send('Target.createBrowserContext');
  contexts.add(browserContextId);
  return browserContextId;
}

async function openTab(browserContextId, tag) {
  const {targetId} = await send('Target.createTarget', {url: 'about:blank', browserContextId});
  const {sessionId} = await send('Target.attachToTarget', {targetId, flatten: true});
  await send('Runtime.enable', {}, sessionId);
  await send('Page.enable', {}, sessionId);
  const loaded = once('Page.loadEventFired', sessionId);
  await send('Page.navigate', {url: `${origin}/?${tag}`}, sessionId);
  await bounded(loaded, 15000, 'page load');
  return {targetId, sessionId};
}

async function evaluate(sessionId, body, label) {
  const expression = `(async()=>{${PRELUDE}${body}})()`;
  const response = await bounded(send('Runtime.evaluate', {
    expression, awaitPromise: true, returnByValue: true,
  }, sessionId), 20000, label);
  if (!response || response.exceptionDetails) throw new Error(label);
  return response.result?.value;
}

async function runCase(label, action) {
  try {
    await action();
    results.push([label, true]);
  } catch (_) {
    results.push([label, false]);
  }
}

const freshPlatform = label => `await import('/platform.js?case=' + ${JSON.stringify(label)})`;

// --- Scenario bodies -------------------------------------------------------

const freshSchemaBody = `
const platform = ${freshPlatform('fresh-schema')};
eq(JSON.parse(await platform.loadWallet('hardening-fresh')), {mnemonic: null, state: null}, 'fresh wallet not empty');
const database = await rawOpen(DB);
eq(database.version, 2, 'fresh database version');
eq(rawStoreNames(database), ['mnemonics', 'onboarding', 'states'], 'fresh stores');
for (const store of rawStoreNames(database)) eq(await rawKeys(database, store), [], 'fresh store not empty');
database.close();
return true;
`;

const olderVersionBody = `
const seed = await rawOpen(DB, 1, database => {
  database.createObjectStore('mnemonics');
  database.createObjectStore('states');
});
await rawPut(seed, 'mnemonics', MNEMONIC, 'hardening-legacy');
await rawPut(seed, 'states', {revision: 2, data: 'legacy-state'}, 'hardening-legacy');
seed.close();
const platform = ${freshPlatform('older')};
const before = __hardening.opens.length;
await rejects(platform.loadWallet('hardening-legacy'), 'older version accepted');
const record = __hardening.opens[before];
await waitForOpen(record);
truth(record.upgraded && !record.blocked && !record.success && record.error === 'AbortError', 'open did not abort');
const database = await rawOpen(DB);
eq(database.version, 1, 'older version changed');
eq(rawStoreNames(database), ['mnemonics', 'states'], 'older schema changed');
eq(await rawGet(database, 'mnemonics', 'hardening-legacy'), MNEMONIC, 'legacy mnemonic changed');
eq(await rawGet(database, 'states', 'hardening-legacy'), {revision: 2, data: 'legacy-state'}, 'legacy state changed');
database.close();
return true;
`;

const currentVersionBody = `
const seed = await rawOpen(DB, 2, database => {
  database.createObjectStore('mnemonics');
  database.createObjectStore('states');
  database.createObjectStore('onboarding');
});
await rawPut(seed, 'mnemonics', MNEMONIC, 'hardening-valid');
await rawPut(seed, 'states', {revision: 3, data: '{"raw":true}'}, 'hardening-valid');
await rawPut(seed, 'mnemonics', MNEMONIC, 'hardening-extra');
await rawPut(seed, 'states', {revision: 0, data: 'unknown', extra: 1}, 'hardening-extra');
seed.close();
const platform = ${freshPlatform('current')};
const before = __hardening.opens.length;
const wallet = JSON.parse(await platform.loadWallet('hardening-valid'));
eq(wallet, {mnemonic: MNEMONIC, state: {revision: 3, data: '{"raw":true}'}}, 'valid record not read');
const database = await rawOpen(DB);
truth(__hardening.opens[before].success && !__hardening.opens[before].upgraded, 'v2 did not reopen without upgrade');
eq(database.version, 2, 'v2 version changed');
eq(rawStoreNames(database), ['mnemonics', 'onboarding', 'states'], 'v2 schema changed');
eq(await rawGet(database, 'mnemonics', 'hardening-valid'), MNEMONIC, 'mnemonic changed');
eq(await rawGet(database, 'states', 'hardening-valid'), {revision: 3, data: '{"raw":true}'}, 'state changed');
await rejects(platform.loadWallet('hardening-extra'), 'malformed state accepted');
eq(await rawGet(database, 'states', 'hardening-extra'), {revision: 0, data: 'unknown', extra: 1}, 'malformed state changed');
eq(await rawGet(database, 'mnemonics', 'hardening-extra'), MNEMONIC, 'malformed mnemonic changed');
database.close();
return true;
`;

const futureVersionBody = `
const seed = await rawOpen(DB, 3, database => {
  database.createObjectStore('mnemonics');
  database.createObjectStore('states');
  database.createObjectStore('onboarding');
});
await rawPut(seed, 'mnemonics', MNEMONIC, 'hardening-future');
await rawPut(seed, 'states', {revision: 7, data: 'future'}, 'hardening-future');
seed.close();
const platform = ${freshPlatform('future')};
await rejects(platform.loadWallet('hardening-future'), 'future version accepted');
const database = await rawOpen(DB);
truth(database.version === 3, 'version downgraded');
eq(await rawGet(database, 'states', 'hardening-future'), {revision: 7, data: 'future'}, 'future state changed');
eq(await rawGet(database, 'mnemonics', 'hardening-future'), MNEMONIC, 'future mnemonic changed');
database.close();
return true;
`;

const blockedOpenBody = `
const legacy = await rawOpen(DB, 1, database => {
  database.createObjectStore('mnemonics');
  database.createObjectStore('states');
});
await rawPut(legacy, 'mnemonics', MNEMONIC, 'hardening-legacy');
await rawPut(legacy, 'states', {revision: 2, data: 'legacy-state'}, 'hardening-legacy');
const platform = ${freshPlatform('blocked')};
const before = __hardening.opens.length;
const error = await rejects(platform.loadWallet('hardening-legacy'), 'blocked open accepted');
truth(error.message === 'IndexedDB is blocked by another connection', 'blocked error not reported');
const record = __hardening.opens[before];
truth(record && record.blocked, 'blocked event missing');
const openFinished = waitForOpen(record);
legacy.close();
await openFinished;
truth(record.upgraded && !record.success && record.error === 'AbortError', 'abandoned open did not abort');
const beforeRetry = __hardening.opens.length;
await rejects(platform.loadWallet('hardening-legacy'), 'retry accepted older database');
const retry = __hardening.opens[beforeRetry];
truth(retry && retry !== record, 'retry did not open a new request');
await waitForOpen(retry);
truth(retry.upgraded && !retry.blocked && !retry.success && retry.error === 'AbortError', 'unblocked retry did not abort');
const database = await rawOpen(DB);
eq(database.version, 1, 'blocked path changed older version');
eq(rawStoreNames(database), ['mnemonics', 'states'], 'blocked path changed older schema');
eq(await rawGet(database, 'states', 'hardening-legacy'), {revision: 2, data: 'legacy-state'}, 'legacy state changed');
eq(await rawGet(database, 'mnemonics', 'hardening-legacy'), MNEMONIC, 'legacy mnemonic changed');
database.close();
return true;
`;

const revisionCanonicalBody = `
const platform = ${freshPlatform('revision-canonical')};
await platform.provisionWallet('hardening-rev', MNEMONIC, 'start');
eq(JSON.parse(await platform.loadWallet('hardening-rev')), {mnemonic: MNEMONIC, state: {revision: 0, data: 'start'}}, 'provision');
await platform.writeWalletState('hardening-rev', '0', 'zero');
eq(JSON.parse(await platform.loadWallet('hardening-rev')).state, {revision: 1, data: 'zero'}, 'canonical zero');
return true;
`;

const revisionBoundaryBody = `
const platform = ${freshPlatform('revision-boundary')};
const MAX_SAFE = Number.MAX_SAFE_INTEGER;
await platform.loadWallet('hardening-max-probe');
let database = await rawOpen(DB);
await rawPut(database, 'mnemonics', MNEMONIC, 'hardening-max');
await rawPut(database, 'states', {revision: MAX_SAFE - 1, data: 'before'}, 'hardening-max');
database.close();
await platform.writeWalletState('hardening-max', String(MAX_SAFE - 1), 'at-max');
database = await rawOpen(DB);
eq(await rawGet(database, 'states', 'hardening-max'), {revision: MAX_SAFE, data: 'at-max'}, 'max transition');
database.close();
await rejects(platform.writeWalletState('hardening-max', String(MAX_SAFE), 'overflow'), 'overflow accepted');
database = await rawOpen(DB);
eq(await rawGet(database, 'states', 'hardening-max'), {revision: MAX_SAFE, data: 'at-max'}, 'overflow changed');
database.close();
return true;
`;

const revisionInvalidBody = `
const platform = ${freshPlatform('revision-invalid')};
await platform.loadWallet('hardening-rev-probe');
let database = await rawOpen(DB);
await rawPut(database, 'mnemonics', MNEMONIC, 'hardening-rev-invalid');
await rawPut(database, 'states', {revision: 0, data: 'invalid-base'}, 'hardening-rev-invalid');
database.close();
const invalid = [null, true, false, 0, 1, -1, 1.5, {}, [], '', ' ', ' 0', '0 ', '00', '0x0', '1e0', '1.0', '1.5', '0.5', '+0', '-0', '9007199254740992', ...['\\n', '\\r', '\\u2028', '\\u2029'].map(end => '0' + end)];
for (const value of invalid) {
  await rejects(platform.writeWalletState('hardening-rev-invalid', value, 'bad'), 'invalid revision accepted');
}
database = await rawOpen(DB);
eq(await rawGet(database, 'states', 'hardening-rev-invalid'), {revision: 0, data: 'invalid-base'}, 'invalid revision changed');
database.close();
return true;
`;

const namesBody = `
const platform = ${freshPlatform('names')};
const invalid = ['', ' ', 'bad name', 'bad/name', 'bad:name', '\\u00e9', 'a'.repeat(65), 'bad\\nname', ...['\\n', '\\r', '\\u2028', '\\u2029'].map(end => 'name' + end)];
for (const name of invalid) {
  await rejects(platform.loadWallet(name), 'invalid name read');
  await rejects(platform.writeWalletState(name, '0', 'x'), 'invalid name write');
  await rejects(platform.provisionWallet(name, MNEMONIC, 'x'), 'invalid name provision');
}
eq(JSON.parse(await platform.loadWallet('A'.repeat(64))), {mnemonic: null, state: null}, '64-char name rejected');
eq(JSON.parse(await platform.loadWallet('a')), {mnemonic: null, state: null}, '1-char name rejected');
await platform.provisionWallet('hardening_ok-9', MNEMONIC, 'state');
eq(JSON.parse(await platform.loadWallet('hardening_ok-9')).state, {revision: 0, data: 'state'}, 'valid name rejected');
return true;
`;

const presenceBody = `
const platform = ${freshPlatform('presence')};
eq(JSON.parse(await platform.loadWallet('hardening-missing')), {mnemonic: null, state: null}, 'missing pair');
let database = await rawOpen(DB);
await rawPut(database, 'mnemonics', null, 'hardening-null-mnemonic');
await rawPut(database, 'states', null, 'hardening-null-state');
await rawPut(database, 'mnemonics', MNEMONIC, 'hardening-null-state');
await rawPut(database, 'mnemonics', undefined, 'hardening-undefined-mnemonic');
await rawPut(database, 'states', undefined, 'hardening-undefined-state');
await rawPut(database, 'mnemonics', MNEMONIC, 'hardening-undefined-state');
database.close();
await rejects(platform.loadWallet('hardening-null-mnemonic'), 'null mnemonic accepted');
await rejects(platform.loadWallet('hardening-null-state'), 'null state accepted');
await rejects(platform.loadWallet('hardening-undefined-mnemonic'), 'undefined mnemonic accepted');
await rejects(platform.loadWallet('hardening-undefined-state'), 'undefined state accepted');
database = await rawOpen(DB);
const probe = async (storeName, key) => {
  const keys = await rawKeys(database, storeName);
  const value = await rawGet(database, storeName, key);
  return {
    present: keys.includes(key),
    isNull: value === null,
    isUndefined: value === undefined,
  };
};
eq(await probe('mnemonics', 'hardening-null-mnemonic'), {present: true, isNull: true, isUndefined: false}, 'null mnemonic changed');
eq(await probe('states', 'hardening-null-state'), {present: true, isNull: true, isUndefined: false}, 'null state changed');
eq(await probe('mnemonics', 'hardening-undefined-mnemonic'), {present: true, isNull: false, isUndefined: true}, 'undefined mnemonic changed');
eq(await probe('states', 'hardening-undefined-state'), {present: true, isNull: false, isUndefined: true}, 'undefined state changed');
database.close();
return true;
`;

const captureCreationBody = `
const platform = ${freshPlatform('capture-creation')};
const marker = {version: 1, revision: 0, step: 'backup_seed', fingerprint: 'a'.repeat(64)};
const original = {version: 1, revision: 0, step: 'backup_seed', fingerprint: 'a'.repeat(64)};
const pending = platform.createOnboardingWallet(USER, MNEMONIC, 'capture-state', marker, '[]');
marker.fingerprint = 'b'.repeat(64);
marker.step = 'complete';
marker.revision = 9;
await pending;
let database = await rawOpen(DB);
eq(await rawGet(database, 'onboarding', USER), original, 'creation marker swapped');
eq(await rawGet(database, 'mnemonics', USER), MNEMONIC, 'creation mnemonic changed');
eq(await rawGet(database, 'states', USER), {revision: 0, data: 'capture-state'}, 'creation state changed');
database.close();
const snapshot = {
  marker: {version: 1, revision: 0, step: 'backup_seed', fingerprint: 'a'.repeat(64)},
  state: {revision: 0, data: 'capture-state'},
  mnemonic: MNEMONIC,
  retired: '[]',
};
const completion = platform.completeOnboardingWallet(USER, snapshot);
snapshot.marker.fingerprint = 'c'.repeat(64);
snapshot.marker.revision = 6;
snapshot.state.data = 'swapped';
snapshot.mnemonic = OTHER_MNEMONIC;
await completion;
database = await rawOpen(DB);
eq(await rawGet(database, 'onboarding', USER), {version: 1, revision: 1, step: 'complete', fingerprint: 'a'.repeat(64)}, 'completion marker swapped');
eq(await rawGet(database, 'mnemonics', USER), MNEMONIC, 'completion mnemonic swapped');
eq(await rawGet(database, 'states', USER), {revision: 0, data: 'capture-state'}, 'completion state swapped');
database.close();
return true;
`;

const captureGenerationBody = `
const platform = ${freshPlatform('capture-generation')};
const id = 'a'.repeat(32);
const scanning = {version: 1, revision: 0, step: 'scanning', id, fingerprint: 'c'.repeat(64), mint: 'https://mint.invalid'};
await platform.stageOnboardingWallet(USER, id, MNEMONIC, 'stage-state', scanning, '[]');
const first = JSON.parse(await platform.loadOnboardingSnapshot());
const resultMarker = {version: 1, revision: 1, step: 'result', id, fingerprint: 'c'.repeat(64), mint: 'https://mint.invalid', spendable_msats: '0', pending_msats: '0', spent_msats: '0'};
await platform.updateOnboardingScan(USER, {marker: first.marker, state: {revision: 0, data: 'stage-state'}, mnemonic: MNEMONIC, retired: '[]'}, resultMarker);
const second = JSON.parse(await platform.loadOnboardingSnapshot());
const snapshot = {marker: second.marker, state: {revision: 0, data: 'stage-state'}, mnemonic: MNEMONIC, retired: '[]'};
const replacement = {mnemonic: OTHER_MNEMONIC, state: 'replacement-state', marker: {version: 1, revision: 0, step: 'backup_seed', fingerprint: 'd'.repeat(64)}};
const generation = platform.generateOnboardingWallet(USER, snapshot, replacement);
snapshot.marker.spendable_msats = '5';
snapshot.state.data = 'swapped';
replacement.state = 'swapped';
replacement.marker.fingerprint = 'e'.repeat(64);
replacement.mnemonic = MNEMONIC;
await generation;
const database = await rawOpen(DB);
eq(await rawGet(database, 'mnemonics', USER), OTHER_MNEMONIC, 'replacement mnemonic swapped');
eq(await rawGet(database, 'states', USER), {revision: 0, data: 'replacement-state'}, 'replacement state swapped');
eq(await rawGet(database, 'onboarding', USER), {version: 1, revision: 0, step: 'backup_seed', fingerprint: 'd'.repeat(64)}, 'replacement marker swapped');
eq(await rawGet(database, 'onboarding', 'retired:' + id), {
  version: 1, step: 'retired', id, fingerprint: 'c'.repeat(64), mint: 'https://mint.invalid',
  spendable_msats: '0', pending_msats: '0', spent_msats: '0',
}, 'retired marker swapped');
const STAGE = 'haystack-recovery-' + id;
eq(await rawKeys(database, 'mnemonics'), [STAGE, USER].sort(), 'staged mnemonic missing');
eq(await rawKeys(database, 'states'), [STAGE, USER].sort(), 'staged state missing');
eq(await rawGet(database, 'mnemonics', STAGE), MNEMONIC, 'staged mnemonic changed');
eq(await rawGet(database, 'states', STAGE), {revision: 0, data: 'stage-state'}, 'staged state changed');
database.close();
return true;
`;

const duplicateBody = `
const platform = ${freshPlatform('duplicate')};
await platform.loadWallet('hardening-duplicate-control');
let database = await rawOpen(DB);
await rawPut(database, 'states', {revision: 0, data: 'control'}, 'hardening-duplicate-control');
await rawPut(database, 'states', {revision: 0, data: 'existing'}, 'hardening-duplicate');
database.close();
const control = await rejects(platform.provisionWallet('hardening-duplicate-control', MNEMONIC, 'fresh-control'), 'control duplicate accepted');
truth(/already exists|duplicate/i.test(String(control && control.message)), 'control duplicate not identified');
database = await rawOpen(DB);
truth(!(await rawKeys(database, 'mnemonics')).includes('hardening-duplicate-control'), 'control mnemonic half-committed');
eq(await rawGet(database, 'states', 'hardening-duplicate-control'), {revision: 0, data: 'control'}, 'control state replaced');
database.close();
__hardening.preventRequestErrors = true;
const error = await rejects(platform.provisionWallet('hardening-duplicate', MNEMONIC, 'fresh-state'), 'duplicate accepted');
truth(/already exists|duplicate/i.test(String(error && error.message)), 'duplicate not identified');
database = await rawOpen(DB);
truth(!(await rawKeys(database, 'mnemonics')).includes('hardening-duplicate'), 'mnemonic half-committed');
eq(await rawGet(database, 'states', 'hardening-duplicate'), {revision: 0, data: 'existing'}, 'state replaced');
database.close();
return true;
`;

const lockContentionA = `
const platform = ${freshPlatform('lock-contention-a')};
window.__releaseA = await platform.acquireWalletLock('haystack-wallet-lock:hardening');
truth(typeof window.__releaseA === 'function', 'no release handle');
return true;
`;

const lockContentionB = `
const platform = ${freshPlatform('lock-contention-b')};
await rejects(platform.acquireWalletLock('haystack-wallet-lock:hardening'), 'second tab acquired');
return true;
`;

const lockReleaseA = `
const first = window.__releaseA();
const second = window.__releaseA();
await Promise.all([first, second]);
return true;
`;

const lockReacquireB = `
const platform = ${freshPlatform('lock-contention-b2')};
const release = await platform.acquireWalletLock('haystack-wallet-lock:hardening');
await release();
return true;
`;

const lockReopenA = `
const platform = ${freshPlatform('lock-contention-a2')};
const release = await platform.acquireWalletLock('haystack-wallet-lock:hardening');
await release();
return true;
`;

const lockBeforeA = `
const platform = ${freshPlatform('lock-before-a')};
const readiness = platform.acquireWalletLock('haystack-wallet-lock:hardening-poison-before');
window.dispatchEvent(new ErrorEvent('error', {error: new WebAssembly.RuntimeError('fixture'), message: 'fixture'}));
await rejects(readiness, 'poisoned grant retained');
await rejects(platform.acquireWalletLock('haystack-wallet-lock:hardening-poison-before-new'), 'poisoned module acquired');
return true;
`;

const lockBeforeB = `
const platform = ${freshPlatform('lock-before-b')};
const release = await platform.acquireWalletLock('haystack-wallet-lock:hardening-poison-before');
await release();
return true;
`;

const lockAfterA = `
const platform = ${freshPlatform('lock-after-a')};
const release = await platform.acquireWalletLock('haystack-wallet-lock:hardening-poison-after');
window.dispatchEvent(new ErrorEvent('error', {error: new WebAssembly.RuntimeError('fixture'), message: 'fixture'}));
await rejects(platform.acquireWalletLock('haystack-wallet-lock:hardening-poison-after-new'), 'poisoned module acquired a new lock');
let settled = false;
window.__afterPending = release().then(() => { settled = true; }, () => { settled = true; });
await navigator.locks.query();
await navigator.locks.query();
truth(settled === false, 'release settled under poison');
const query = await navigator.locks.query();
truth(query.held.some(lock => lock.name === 'haystack-wallet-lock:hardening-poison-after'), 'lock not held after poison');
return true;
`;

const lockAfterB = `
const platform = ${freshPlatform('lock-after-b')};
await rejects(platform.acquireWalletLock('haystack-wallet-lock:hardening-poison-after'), 'lock stolen');
const query = await navigator.locks.query();
truth(query.held.some(lock => lock.name === 'haystack-wallet-lock:hardening-poison-after'), 'lock not held');
return true;
`;

const lockAfterCloseB = `
const name = 'haystack-wallet-lock:hardening-poison-after';
await navigator.locks.request(name, {mode: 'exclusive'}, async () => {});
const platform = ${freshPlatform('lock-after-b2')};
const release = await platform.acquireWalletLock(name);
await release();
return true;
`;

const lockPlainBody = `
const platform = ${freshPlatform('lock-plain')};
window.dispatchEvent(new ErrorEvent('error', {error: new Error('fixture'), message: 'fixture'}));
const release = await platform.acquireWalletLock('haystack-wallet-lock:hardening-plain');
await release();
return true;
`;

// --- Scenario groups -------------------------------------------------------

async function schemaCase() {
  for (const [label, body] of [
    ['schema-fresh-creates-v2', freshSchemaBody],
    ['schema-v1-refused-without-mutation', olderVersionBody],
    ['schema-v2-reopens-without-upgrade', currentVersionBody],
    ['schema-v3-refused-without-downgrade', futureVersionBody],
  ]) {
    await runCase(label, async () => {
      const context = await newContext();
      const tab = await openTab(context, label);
      await evaluate(tab.sessionId, body, label);
    });
  }
}

async function blockedCase() {
  const context = await newContext();
  const tab = await openTab(context, 'blocked');
  await runCase('blocked-open-aborts-without-mutation', () => evaluate(tab.sessionId, blockedOpenBody, 'blocked'));
}

async function revisionCase() {
  const context = await newContext();
  const tab = await openTab(context, 'revision');
  await runCase('revision-canonical-zero', () => evaluate(tab.sessionId, revisionCanonicalBody, 'revision-canonical'));
  await runCase('revision-max-safe-boundary', () => evaluate(tab.sessionId, revisionBoundaryBody, 'revision-boundary'));
  await runCase('revision-noncanonical-rejected', () => evaluate(tab.sessionId, revisionInvalidBody, 'revision-invalid'));
  await runCase('revision-wallet-name-bounds', () => evaluate(tab.sessionId, namesBody, 'names'));
  await runCase('revision-presence-rules', () => evaluate(tab.sessionId, presenceBody, 'presence'));
}

async function captureCase() {
  const creationContext = await newContext();
  const creation = await openTab(creationContext, 'capture-creation');
  await runCase('capture-creation-marker', () => evaluate(creation.sessionId, captureCreationBody, 'capture-creation'));
  const generationContext = await newContext();
  const generation = await openTab(generationContext, 'capture-generation');
  await runCase('capture-generation-replacement', () => evaluate(generation.sessionId, captureGenerationBody, 'capture-generation'));
}

async function duplicateCase() {
  const context = await newContext();
  const tab = await openTab(context, 'duplicate');
  await runCase('provision-duplicate-rolls-back', () => evaluate(tab.sessionId, duplicateBody, 'duplicate'));
}

async function lockCase() {
  const context = await newContext();
  const a = await openTab(context, 'lock-a');
  const b = await openTab(context, 'lock-b');
  await runCase('lock-real-contention', async () => {
    await evaluate(a.sessionId, lockContentionA, 'lock-a');
    await evaluate(b.sessionId, lockContentionB, 'lock-b');
    await evaluate(a.sessionId, lockReleaseA, 'lock-release');
    await evaluate(b.sessionId, lockReacquireB, 'lock-reacquire-b');
    await evaluate(a.sessionId, lockReopenA, 'lock-reopen-a');
  });
  await runCase('lock-poison-before-grant', async () => {
    const poisoned = await openTab(context, 'lock-before-a');
    const other = await openTab(context, 'lock-before-b');
    await evaluate(poisoned.sessionId, lockBeforeA, 'lock-before-a');
    await evaluate(other.sessionId, lockBeforeB, 'lock-before-b');
  });
  await runCase('lock-poison-after-grant', async () => {
    const poisoned = await openTab(context, 'lock-after-a');
    const other = await openTab(context, 'lock-after-b');
    await evaluate(poisoned.sessionId, lockAfterA, 'lock-after-a');
    await evaluate(other.sessionId, lockAfterB, 'lock-after-b');
    await bounded(send('Target.closeTarget', {targetId: poisoned.targetId}), 10000, 'close poisoned tab');
    await evaluate(other.sessionId, lockAfterCloseB, 'lock-after-close');
  });
  await runCase('lock-runtime-error-scope', async () => {
    const tab = await openTab(context, 'lock-plain');
    await evaluate(tab.sessionId, lockPlainBody, 'lock-plain');
  });
}

async function runScenarios() {
  await schemaCase();
  await blockedCase();
  await revisionCase();
  await captureCase();
  await duplicateCase();
  await lockCase();
}

try {
  await bounded(new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  }), 5000, 'server startup');
  origin = `http://127.0.0.1:${server.address().port}`;
  profile = await bounded(makeProfile('cdk-platform-hardening-'), 5000, 'profile creation');
  browser = launchBrowser(profile);
  const endpoint = await bounded(discoverEndpoint(browser), 15000, 'browser discovery');
  let acceptingConnection = true;
  const connecting = CdpConnection.connect(endpoint).then(value => {
    if (!acceptingConnection) value.close();
    return value;
  });
  try { connection = await bounded(connecting, 15000, 'browser connection'); }
  finally { acceptingConnection = false; }
  await bounded(runScenarios(), 110000, 'platform hardening run');
} catch (_) {
  incomplete = true;
} finally {
  const cleanupFailed = () => { cleanupFailure = true; };
  await Promise.all([...contexts].map(async browserContextId => {
    try {
      await bounded(connection.send('Target.disposeBrowserContext', {browserContextId}), 5000, 'context disposal');
    } catch (_) { cleanupFailed(); }
  }));
  try { connection?.close(); } catch (_) { cleanupFailed(); }
  try {
    if (browser && !await bounded(stopBrowser(browser), 10000, 'browser stop')) cleanupFailed();
  } catch (_) { cleanupFailed(); }
  try {
    server.closeAllConnections();
    if (server.listening) await bounded(new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve())), 5000, 'server close');
  } catch (_) { cleanupFailed(); }
  try { if (profile) await bounded(removeProfile(profile), 5000, 'profile removal'); } catch (_) { cleanupFailed(); }
}

for (const [label, ok] of results) console.log(`${ok ? 'PASS' : 'FAIL'} ${label}`);
if (results.length !== 17) incomplete = true;
if (incomplete) console.log('INCOMPLETE platform hardening browser test');
if (cleanupFailure) console.log('FAIL platform-cleanup');
const failed = results.filter(([, ok]) => !ok).length;
if (failed) console.log(`${failed} failed case(s)`);
if (incomplete || failed || cleanupFailure) process.exitCode = 1;
