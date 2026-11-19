import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('./game-onboarding.js', import.meta.url), 'utf8')
  .replace(/\{\{\{ makeDynCall\('viiii', 'callback'\) \}\}\}/g, 'callback')
  .replace(/\{\{\{ makeDynCall\('viiiii', 'callback'\) \}\}\}/g, 'callback')
  .replace(/\{\{\{ makeDynCall\('[iv]+', '(probe|paste|success)'\) \}\}\}/g, '$1');
const heap = new Uint8Array(131072), library = {};
let alloc = 8192;
const context = vm.createContext({ LibraryManager: { library }, mergeInto: Object.assign,
  HEAPU8: heap, TextEncoder, TextDecoder, URL, Promise,
  _malloc: n => { const p = alloc; alloc += n; return p; }, _free: () => {} });
vm.runInContext(source, context);
const bridge = context.haystackOnboarding = library.$haystackOnboarding;
const calls = [], events = [];
let release;
const deferred = new Promise(r => { release = r; });
const service = {
  async request(op, args) {
    calls.push([op, args]);
    if (op === 'create') await deferred;
    if (op === 'fail') throw new Error('secret');
    if (op === 'large') return 'x'.repeat(4097);
    return JSON.stringify({ event: op });
  },
  close() { calls.push(['close']); },
  free() { calls.push(['free']); },
};
bridge.resolveModule = async () => ({ default: async () => {}, onboarding_mint: () => 'fixture',
  start_onboarding: async () => service });
const callback = (status, gen, ...tail) => {
  const len = tail.pop(), ptr = tail.pop();
  events.push([status, gen, ...tail, new TextDecoder().decode(heap.slice(ptr, ptr + len))]);
};
const tick = () => new Promise(r => setImmediate(r));
bridge.start(1, callback);
await tick();
assert.equal(events.length, 1);
assert.equal(calls.length, 0, 'startup acknowledgement precedes inspect');
heap.set(new TextEncoder().encode('create'), 0);
heap.set(new TextEncoder().encode('{"x":1}'), 100);
bridge.request(1, 5, 0, 6, 100, 7, callback);
heap.fill(0, 0, 110);
bridge.request(1, 6, 0, 0, 0, 0, callback);
bridge.close(1);
bridge.start(2, callback);
await tick();
assert.equal(events.length, 1); // closing session suppresses all callbacks
assert.deepEqual(calls[0], ['create', '{"x":1}']);
assert.equal(calls.some(c => c[0] === 'close'), false);
release();
await tick();
assert.deepEqual(calls.slice(1).map(c => c[0]), ['', 'close', 'free']);
assert.equal(events.length, 1, 'queued work completes without callbacks after close');
bridge.start(3, callback);
await tick();
assert.equal(events.at(-1)[1], 3);
heap.set(new TextEncoder().encode('fail'), 200);
bridge.request(3, 10, 200, 4, 0, 0, callback);
heap.set(new TextEncoder().encode('large'), 200);
bridge.request(3, 11, 200, 5, 0, 0, callback);
await tick();
assert.deepEqual(events.slice(-2).map(e => [e[0], e[2], e[3]]), [[0, 10, ''], [0, 11, '']]);
bridge.request(1, 9, 0, 0, 0, 0, callback);
await tick();
assert.equal(events.at(-1)[0], 0);
assert.equal(events.at(-1)[1], 1);
bridge.close(3);
await tick();
console.log('onboarding transport tests passed');

const listeners = new Map();
const canvas = {
  addEventListener: (name, fn) => listeners.set(name, fn),
  removeEventListener: (name, fn) => { if (listeners.get(name) === fn) listeners.delete(name); },
  getBoundingClientRect: () => ({ left: 10, top: 20, width: 200, height: 100 }),
};
context.document = { getElementById: () => canvas, activeElement: canvas };
let resolveWrite, writes = [], pasted = [], copied = [], code = 1, epoch = 1;
context.navigator = { clipboard: {
  writeText: text => { writes.push(text); return new Promise(r => { resolveWrite = r; }); },
  readText: () => Promise.resolve('read phrase'),
} };
alloc = 8192;
const probe = (kind, x, y, ptr, cap) => {
  assert.equal(cap, 4097);
  if (kind === 0) assert.deepEqual([x, y], [500000, 500000]);
  if (code === 14 || code === 16) new DataView(heap.buffer).setBigUint64(ptr, BigInt(epoch), true);
  else heap.set(new TextEncoder().encode('secret'), ptr);
  return code;
};
const paste = (ptr, len) => pasted.push(new TextDecoder().decode(heap.slice(ptr, ptr + len)));
const success = value => copied.push(value);
bridge.bindInput(probe, paste, success);
const pointer = trusted => ({ isTrusted: trusted, button: 0, clientX: 110, clientY: 70 });
listeners.get('pointerdown')(pointer(false));
assert.equal(writes.length, 0);
listeners.get('pointerdown')(pointer(true));
assert.deepEqual(writes, ['secret']); // invoked before handler returns
assert.deepEqual(copied, []);
assert.ok(heap.slice(8192, 12289).every(x => x === 0));
resolveWrite(); await tick();
assert.deepEqual(copied, [1]);
code = 14;
listeners.get('keydown')({ isTrusted: true, key: 'v', ctrlKey: true });
assert.deepEqual(pasted, []);
let prevented = false;
const pasteEvent = text => ({ isTrusted: true, clipboardData: { getData: () => text }, preventDefault: () => { prevented = true; } });
listeners.get('paste')(pasteEvent('x'.repeat(1025)));
assert.equal(prevented, false);
listeners.get('paste')(pasteEvent('phrase'));
assert.equal(prevented, true);
assert.deepEqual(pasted, ['phrase']);
listeners.get('keydown')({ isTrusted: true, key: 'Enter' });
await tick();
assert.deepEqual(pasted, ['phrase', 'read phrase']);
code = 1;
listeners.get('pointerdown')(pointer(true));
bridge.unbindInput();

// Service startup and operational opening are separate from durable requests.
{
  alloc = 8192;
  let resolveInit, resolveOpen, opens = 0, failOpen = true, locked = false;
  const log = [], received = [];
  const lifecycleWallet = {
    async call(op) { log.push(op); return '{"status":0,"value":"{}"}'; },
    async close() { log.push('wallet-close'); },
    free() { log.push('wallet-free'); },
  };
  const lifecycleService = {
    async request(op) {
      locked = true;
      log.push(op);
      locked = false;
      return JSON.stringify({ event: op === 'inspect' ? 'ready' : 'complete_success' });
    },
    async open_ready_wallet() {
      assert.equal(locked, false, 'request lock is released before open');
      opens++;
      if (failOpen) throw Error('open');
      if (resolveOpen) await new Promise(r => { resolveOpen = r; });
      return lifecycleWallet;
    },
    async close() { log.push('service-close'); },
    free() { log.push('service-free'); },
  };
  const cb = (status, gen, ...rest) => {
    const len = rest.pop(), ptr = rest.pop();
    received.push([status, gen, ...rest, new TextDecoder().decode(heap.subarray(ptr, ptr + len))]);
  };
  const send = (gen, token, op) => {
    const bytes = new TextEncoder().encode(op);
    heap.set(bytes, 0);
    bridge.request(gen, token, 0, bytes.length, 100, 2, cb);
  };
  heap.set(new TextEncoder().encode('{}'), 100);
  bridge.resolveModule = async () => ({ default: async () => {}, onboarding_mint: () => 'fixture',
    start_onboarding: () => new Promise(r => { resolveInit = r; }) });
  bridge.start(10, cb);
  await tick();
  assert.equal(received.length, 0);
  resolveInit(lifecycleService);
  await tick();
  assert.deepEqual(received.map(x => x[0]), [1]);
  assert.deepEqual(log, [], 'startup never inspects');
  for (const [token, op] of [[1, 'inspect'], [2, 'complete_backup'], [3, 'finish_restore']]) {
    send(10, token, op);
    await tick();
    assert.equal(JSON.parse(received.at(-1).at(-1)).event, 'open_failed');
  }
  assert.equal(opens, 3);
  const requestsBeforeRetry = log.length;
  failOpen = false;
  resolveOpen = true;
  send(10, 4, 'retry_open');
  await tick();
  assert.equal(received.length, 4, 'success waits for open');
  assert.equal(log.length, requestsBeforeRetry, 'retry does not repeat persistence');
  resolveOpen();
  await tick();
  assert.equal(JSON.parse(received.at(-1).at(-1)).event, 'open_success');
  bridge.walletRequest(10, 5, 0, 0, 0, cb);
  await tick();
  assert.equal(opens, 4, 'wallet screen reuses retained handle');
  assert.equal(log.at(-1), 'wallet_screen');
  bridge.close(10);
  await tick();
  assert.deepEqual(log.slice(-4), ['wallet-close', 'wallet-free', 'service-close', 'service-free']);

  received.length = 0;
  bridge.resolveModule = async () => { throw Error('init'); };
  bridge.start(11, cb);
  await tick();
  assert.equal(received[0][0], 0);
  bridge.close(11);
  await tick();

  received.length = 0;
  bridge.resolveModule = async () => ({ default: async () => {}, onboarding_mint: () => 'fixture',
    start_onboarding: () => new Promise(r => { resolveInit = r; }) });
  bridge.start(12, cb);
  await tick();
  bridge.close(12);
  resolveInit(lifecycleService);
  await tick();
  assert.equal(received.length, 0, 'close during init suppresses startup');
  assert.deepEqual(log.slice(-2), ['service-close', 'service-free']);

  received.length = 0;
  bridge.resolveModule = async () => ({ default: async () => {}, onboarding_mint: () => 'fixture',
    start_onboarding: async () => lifecycleService });
  bridge.start(17, () => { throw Error('callback'); });
  await tick();
  assert.deepEqual(log.slice(-2), ['service-close', 'service-free'], 'throwing startup callback closes service');

  received.length = 0;
  resolveOpen = true;
  bridge.resolveModule = async () => ({ default: async () => {}, onboarding_mint: () => 'fixture',
    start_onboarding: async () => lifecycleService });
  bridge.start(13, cb);
  await tick();
  send(13, 1, 'inspect');
  await tick();
  assert.equal(received.length, 1, 'ready is not delivered before open');
  bridge.close(13);
  resolveOpen();
  await tick();
  assert.equal(received.length, 1, 'close during open suppresses ready');
  assert.deepEqual(log.slice(-4), ['wallet-close', 'wallet-free', 'service-close', 'service-free']);

  for (const [gen, op, expected] of [[14, 'inspect', 'ready'], [15, 'complete_backup', 'complete_success'], [16, 'finish_restore', 'complete_success']]) {
    resolveOpen = false;
    bridge.start(gen, cb);
    await tick();
    send(gen, 1, op);
    await tick();
    assert.equal(JSON.parse(received.at(-1).at(-1)).event, expected);
    bridge.close(gen);
    await tick();
  }
  let response = '';
  lifecycleService.request = async () => response;
  resolveOpen = false;
  bridge.start(18, cb);
  await tick();
  const before = opens;
  for (const [op, text] of [
    ['inspect', '{ "event":"ready"}'],
    ['inspect', '{"event":"\\u0072eady"}'],
    ['complete_backup', '{"event": "complete_success"}'],
    ['finish_restore', '{"event":"complete_success","extra":1}'],
    ['inspect', '{"event":"backup","mnemonic":"one two three"}'],
  ]) {
    response = text;
    send(18, 1, op);
    await tick();
    assert.equal(received.at(-1).at(-1), text, 'noncanonical and backup responses pass through unchanged');
  }
  assert.equal(opens, before, 'only canonical success opens the wallet');
  bridge.close(18);
  await tick();
  bridge.resolveModule = async () => ({ default: async () => {}, onboarding_mint: () => 'fixture',
    start_onboarding: async () => service });
}
alloc = 8192;
code = 16;
bridge.bindInput(probe, paste, success);
const longInvoice = 'x'.repeat(4096);
listeners.get('paste')(pasteEvent(longInvoice));
assert.equal(pasted.at(-1), longInvoice, 'withdrawal paste keeps the entire 4096-byte value');
const priorPastes = pasted.length;
listeners.get('paste')(pasteEvent('x'.repeat(4097)));
assert.equal(pasted.length, priorPastes, 'oversized invoice is refused atomically');
code = 14;
listeners.get('paste')(pasteEvent(longInvoice));
assert.equal(pasted.length, priorPastes, 'onboarding still has its own 1024-byte limit');
let resolveRead;
context.navigator.clipboard.readText = () => new Promise(resolve => { resolveRead = resolve; });
code = 16;
listeners.get('pointerdown')(pointer(true));
code = 14; // Focus changed to onboarding while the asynchronous read was pending.
resolveRead(longInvoice); await tick();
assert.equal(pasted.length, priorPastes, 'late clipboard data cannot cross the target focus boundary');
code = 16;
listeners.get('pointerdown')(pointer(true));
epoch++;
resolveRead('stale'); await tick();
assert.equal(pasted.length, priorPastes, 'same action with a new focus epoch rejects delayed data');
listeners.get('pointerdown')(pointer(true));
resolveRead('current'); await tick();
assert.equal(pasted.at(-1), 'current', 'unchanged focus epoch accepts delayed data');
bridge.unbindInput();
const walletCalls = [];
const walletArgs = [];
let requestHeld = false, finishWallet, walletStatus = 0;
const walletBlocked = new Promise(resolve => { finishWallet = resolve; });
const originalRequest = service.request;
service.request = async (...args) => {
  requestHeld = true;
  try { return await originalRequest(...args); }
  finally { requestHeld = false; }
};
service.open_ready_wallet = async () => {
  assert.equal(requestHeld, false, 'temporary Ready request lock must have dropped');
  walletCalls.push('open');
  return {
    async call(op,args) { walletCalls.push(op); walletArgs.push([op,JSON.parse(args)]); const status=walletStatus; await walletBlocked; return JSON.stringify({status,value:status===0?'{}':null,error:'untrusted secret invoice/proofs must not escape'}); },
    async close() { walletCalls.push('close'); },
    free() { walletCalls.push('free'); },
  };
};
bridge.start(4, callback);
await tick();
service.request = async (...args) => {
  requestHeld = true;
  try { calls.push(args); return '{"event":"ready"}'; }
  finally { requestHeld = false; }
};
heap.set(new TextEncoder().encode('inspect'), 200);
bridge.request(4, 50, 200, 7, 0, 0, callback);
await tick();
bridge.walletRequest(4, 1, 0, 0, 0, callback);
await tick();
assert.deepEqual(walletCalls, ['open', 'wallet_screen']);
bridge.walletRequest(4, 2, 1, 0, 0, callback);
heap.set(new TextEncoder().encode('0'),100);
bridge.walletRequest(4,3,4,100,1,callback);
heap.set(new TextEncoder().encode('after'),200);
bridge.walletRequest(4,4,5,200,5,callback);
bridge.walletRequest(4,5,6,0,0,callback);
bridge.walletRequest(4,7,7,200,5,callback);
bridge.walletRequest(4,8,8,200,5,callback);
bridge.walletRequest(4,9,3,200,5,callback);
heap.set(new TextEncoder().encode(longInvoice), 1000);
bridge.walletRequest(4,10,9,1000,4096,callback);
heap.fill(0,1000,5096); // Publication must have copied the argument.
for (const operation of [10,11,12,13]) bridge.walletRequest(4,10+operation,operation,200,5,callback);
bridge.walletRequest(4,30,9,1000,4097,callback); // Refused before any wallet call.
bridge.walletRequest(4,6,99,0,0,callback);
const beforeWalletClose = events.length;
bridge.close(4);
assert.equal(walletCalls.includes('close'), false);
finishWallet(); await tick();
assert.equal(events.length, beforeWalletClose, 'close suppresses wallet callbacks');
assert.deepEqual(walletCalls, ['open', 'wallet_screen', 'wallet_screen', 'quote_history_page', 'resume_deposit', 'deposit_update', 'deposit_update', 'saved_invoice', 'deposit_update', 'prepare_withdrawal', 'confirm_withdrawal', 'cancel_withdrawal', 'saved_withdrawal', 'poll_withdrawals', 'close', 'free']);
assert.deepEqual(walletArgs.slice(2),[['quote_history_page',['0']],['resume_deposit',['fixture']],['deposit_update',['fixture','recover','']],['deposit_update',['fixture','poll','after']],['saved_invoice',['fixture','after']],['deposit_update',['fixture','check','after']],['prepare_withdrawal',['fixture',longInvoice]],['confirm_withdrawal',['fixture','after']],['cancel_withdrawal',['fixture','after']],['saved_withdrawal',['fixture','after']],['poll_withdrawals',['fixture','after']]]);
assert.equal(walletCalls.includes('check_deposit'),false,'unknown operation must not fall through to check');
console.log('wallet service ownership and queue tests passed');
resolveWrite(); await tick();
assert.deepEqual(copied, [1]);
assert.equal(listeners.size, 0);
bridge.bindInput(probe, paste, success);
bridge.unbindInput();
bridge.start(5, callback);await tick();
heap.set(new TextEncoder().encode('inspect'),200);
bridge.request(5,50,200,7,0,0,callback);await tick();
bridge.walletRequest(5,1,0,0,0,callback);await tick();
for(const [operation,status] of [[9,2],[10,14],[11,19],[12,13],[13,23]]) {
  walletStatus=status;
  bridge.walletRequest(5,operation,operation,0,0,callback);await tick();
  assert.equal(events.at(-1)[0],1,'definite withdrawal errors are successful bounded JSON deliveries');
  assert.deepEqual(JSON.parse(events.at(-1).at(-1)),{operation_error:{status,message:'Withdrawal request failed'}});
}
walletStatus=14;
bridge.walletRequest(5,40,1,0,0,callback);await tick();
assert.equal(events.at(-1)[0],0,'legacy operation errors retain the original failure path');
for(const status of [28,1.5]) {
  walletStatus=status;bridge.walletRequest(5,41,9,0,0,callback);await tick();
  assert.equal(events.at(-1)[0],0,'malformed/out-of-range status is not a typed backend error');
}
bridge.close(5);await tick();
console.log('typed withdrawal error transport tests passed');
assert.equal(listeners.size, 0);
console.log('onboarding input tests passed');
code = 15; // Full invoice copy, distinct from seed/word feedback codes.
bridge.bindInput(probe, paste, success);
listeners.get('pointerdown')(pointer(true));
assert.equal(writes.at(-1), 'secret');
resolveWrite(); await tick();
assert.equal(copied.at(-1), 15);
bridge.unbindInput();
