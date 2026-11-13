import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('./game-onboarding.js', import.meta.url), 'utf8')
  .replace(/\{\{\{ makeDynCall\('viiii', 'callback'\) \}\}\}/g, 'callback')
  .replace(/\{\{\{ makeDynCall\('viiiii', 'callback'\) \}\}\}/g, 'callback')
  .replace(/\{\{\{ makeDynCall\('[iv]+', '(probe|paste|success)'\) \}\}\}/g, '$1');
const heap = new Uint8Array(16384), library = {};
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
  assert.equal(cap, 1024);
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
assert.ok(heap.slice(8192, 9216).every(x => x === 0));
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
resolveWrite(); await tick();
assert.deepEqual(copied, [1]);
assert.equal(listeners.size, 0);
bridge.bindInput(probe, paste, success);
bridge.unbindInput();
assert.equal(listeners.size, 0);
console.log('onboarding input tests passed');
