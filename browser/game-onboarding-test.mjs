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
assert.deepEqual(calls[0], ['inspect', '{}']);
heap.set(new TextEncoder().encode('create'), 0);
heap.set(new TextEncoder().encode('{"x":1}'), 100);
bridge.request(1, 5, 0, 6, 100, 7, callback);
heap.fill(0, 0, 110);
bridge.request(1, 6, 0, 0, 0, 0, callback);
bridge.close(1);
bridge.start(2, callback);
await tick();
assert.equal(events.length, 2); // rejected second startup, while first request is in flight
assert.equal(events[1][0], 0);
assert.deepEqual(calls[1], ['create', '{"x":1}']);
assert.equal(calls.some(c => c[0] === 'close'), false);
release();
await tick();
assert.deepEqual(calls.slice(2).map(c => c[0]), ['', 'close', 'free']);
assert.deepEqual(events.slice(2).map(e => e[2]), [5, 6]);
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
let resolveWrite, writes = [], pasted = [], copied = [], code = 1;
context.navigator = { clipboard: {
  writeText: text => { writes.push(text); return new Promise(r => { resolveWrite = r; }); },
  readText: () => Promise.resolve('read phrase'),
} };
alloc = 8192;
const probe = (kind, x, y, ptr, cap) => {
  assert.equal(cap, 4097);
  if (kind === 0) assert.deepEqual([x, y], [500000, 500000]);
  heap.set(new TextEncoder().encode('secret'), ptr);
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
    async call(op,args) { walletCalls.push(op); walletArgs.push([op,JSON.parse(args)]); const status=walletStatus; await walletBlocked; return JSON.stringify({status,value:status===0?'{}':null,net_msats:op==='receive'&&status===0?'5':undefined,error:'untrusted secret invoice/proofs must not escape'}); },
    async close() { walletCalls.push('close'); },
    free() { walletCalls.push('free'); },
  };
};
bridge.start(4, callback);
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
bridge.close(4);
assert.equal(walletCalls.includes('close'), false);
finishWallet(); await tick();
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
bridge.walletRequest(5,1,0,0,0,callback);await tick();
for(const [operation,status] of [[9,2],[10,14],[11,19],[12,13],[13,23]]) {
  walletStatus=status;
  bridge.walletRequest(5,operation,operation,0,0,callback);await tick();
  assert.equal(events.at(-1)[0],1,'definite withdrawal errors are successful bounded JSON deliveries');
  assert.deepEqual(JSON.parse(events.at(-1).at(-1)),{operation_error:{status,message:'Withdrawal request failed'}});
}
for (const status of [0, 16, 13]) {
  walletStatus = status;
  const token = 'cashuBfixture';
  heap.set(new TextEncoder().encode(token), 200);
  bridge.walletRequest(5, 14, 14, 200, token.length, callback);
  heap.fill(0, 200, 200 + token.length);
  await tick();
  assert.deepEqual(walletArgs.at(-1), ['receive', [token]]);
  assert.deepEqual(JSON.parse(events.at(-1).at(-1)), status === 0 ? {status, net_msats:'5'} : {status});
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
