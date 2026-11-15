// Node-only harness for browser/game-storage.js.
//
// Chromium is not always available, so this test evaluates the Emscripten JS
// library against the shared in-memory IndexedDB model in
// `test-support/fake-indexeddb.mjs`. It covers the content bridge (round-trip,
// Blob reads, list ordering, limits, transaction failures) and settings
// validation (64 KiB cap, schema, preserve/reset).
//
// The model does not emulate a real browser's IndexedDB durability, Web Locks,
// storage quotas, or a shared database across tabs; see its module header for
// the documented limits. Run `zig build test -Dplatform=wasm` for the Chromium
// suite.

import {readFile} from "node:fs/promises";
import {strict as assert} from "node:assert";
import {FakeIndexedDB as SharedFakeIndexedDB} from "./test-support/fake-indexeddb.mjs";

const DB_NAME = "haystack-game";
const STORE_CONFIG = "config";
const STORE_CONTENT = "content";
const CONFIG_KEY = "settings";
const MAX_CONFIG = 64 * 1024;
const MAX_CONTENT = 64 * 1024 * 1024;

// The request/transaction/upgrade model lives in test-support/fake-indexeddb.mjs
// and is shared with the wallet harness. This adapter only adds the game's
// single-database seed/peek helpers.
class FakeIndexedDB extends SharedFakeIndexedDB {
  constructor() {
    super({database: DB_NAME, version: 1, stores: [STORE_CONFIG, STORE_CONTENT]});
  }

  seed(store, key, value) {
    return super.seed(store, key, value, {create: true});
  }
}

const defaultNavigator = {
  locks: {
    request: (name, options, callback) => Promise.resolve(callback({name})),
  },
};

function makeDynCall(_signature, getFunction) {
  return (...args) => getFunction()(...args);
}

async function buildLibrary({indexedDB, navigator, HEAPU8}) {
  const source = await readFile(new URL("./game-storage.js", import.meta.url), "utf8");
  const transformed = source.replace(
    /\{\{\{\s*makeDynCall\(\s*'([^']+)'\s*,\s*'([^']+)'\s*\)\s*\}\}\}/g,
    (_match, signature, name) => `__makeDynCall(${JSON.stringify(signature)}, function () { return ${name}; })`,
  );
  const factory = new Function(
    "mergeInto",
    "LibraryManager",
    "HEAPU8",
    "navigator",
    "indexedDB",
    "__makeDynCall",
    `var haystackStorage;
${transformed}
haystackStorage = LibraryManager.library["$haystackStorage"];
return LibraryManager.library;`,
  );
  const library = {};
  return factory(
    (target, values) => Object.assign(target, values),
    {library},
    HEAPU8,
    navigator,
    indexedDB,
    makeDynCall,
  );
}

class Environment {
  constructor(options = {}) {
    const {indexedDB, navigator, heapSize = 4 * 1024 * 1024} = options;
    this.indexedDB = indexedDB ?? new FakeIndexedDB();
    this.navigator = navigator ?? defaultNavigator;
    this.H = new Uint8Array(heapSize);
    // Never return pointer 0 for a successful allocation: the bridge treats 0
    // as allocation failure.
    this.heapTop = 64;
    this.bridgeAllocations = [];
  }

  async init() {
    this.library = await buildLibrary({indexedDB: this.indexedDB, navigator: this.navigator, HEAPU8: this.H});
    this.storage = this.library.$haystackStorage;
    return this;
  }

  // Argument staging is not owned by the bridge; keep it separate from the
  // result allocations that the bridge must release through its callbacks.
  stage(bytes) {
    if (this.heapTop + bytes.length > this.H.length) throw new Error("test heap exhausted");
    const pointer = this.heapTop;
    this.heapTop += bytes.length;
    this.H.set(bytes, pointer);
    return {pointer, length: bytes.length};
  }

  put(bytes) {
    return this.stage(bytes);
  }

  ascii(text) {
    return this.stage(Uint8Array.from(text, (character) => character.charCodeAt(0)));
  }

  alloc(length) {
    if (length === 0) return 0;
    if (this.heapTop + length > this.H.length) throw new Error("test heap exhausted");
    const pointer = this.heapTop;
    this.heapTop += length;
    this.bridgeAllocations.push(pointer);
    return pointer;
  }

  release(pointer) {
    const index = this.bridgeAllocations.indexOf(pointer);
    if (index === -1) throw new Error(`released an unknown or already released pointer ${pointer}`);
    this.bridgeAllocations.splice(index, 1);
  }

  read(pointer, length) {
    return this.H.slice(pointer, pointer + length);
  }

  write(key, bytes) {
    const k = this.ascii(key);
    const d = this.put(bytes);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("write timed out")), 2000);
      this.library.haystack_content_write(k.pointer, k.length, d.pointer, d.length, (context, status) => {
        clearTimeout(timer);
        resolve({context, status});
      }, 7);
    });
  }

  readContent(key) {
    const k = this.ascii(key);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("read timed out")), 2000);
      this.library.haystack_content_read(k.pointer, k.length, (context, status, pointer, length) => {
        clearTimeout(timer);
        let bytes = new Uint8Array(0);
        if (pointer) {
          bytes = this.read(pointer, length);
          this.release(pointer);
        }
        resolve({context, status, bytes});
      }, 9, (length) => this.alloc(length), (pointer) => this.release(pointer));
    });
  }

  list() {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("list timed out")), 2000);
      this.library.haystack_content_list((context, status, pointer, length, count) => {
        clearTimeout(timer);
        let keys = [];
        if (pointer) {
          const text = Buffer.from(this.read(pointer, length)).toString("latin1");
          this.release(pointer);
          keys = text.split("\n");
          assert.equal(keys.length, count, "list count matches the newline encoding");
        } else {
          assert.equal(count, 0);
        }
        resolve({context, status, keys});
      }, 11, (length) => this.alloc(length), (pointer) => this.release(pointer));
    });
  }

  remove(key) {
    const k = this.ascii(key);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("delete timed out")), 2000);
      this.library.haystack_content_delete(k.pointer, k.length, (context, status) => {
        clearTimeout(timer);
        resolve({context, status});
      }, 13);
    });
  }

  start() {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("start timed out")), 2000);
      this.library.haystack_storage_start((status, tileGrid, chunkBorders, blocked) => {
        clearTimeout(timer);
        resolve({status, tileGrid, chunkBorders, blocked});
      }, 0, 0);
    });
  }

  settleSaveQueue() {
    return this.storage.saveQueue;
  }

  close() {
    assert.deepEqual(this.bridgeAllocations, [], "every bridge allocation was released");
  }
}

const encoder = new TextEncoder();
const tests = [];
const test = (name, fn) => tests.push({name, fn});

test("queue initializers survive library-object serialization", async () => {
  const env = await new Environment().init();
  assert.equal(env.storage.saveQueue, null);
  assert.equal(env.storage.contentQueue, null);
  // Targeted simulation of the emcc boundary, not a full emcc integration test.
  // The old Promise-valued initializers become {} under this serialization.
  const initial = JSON.parse(JSON.stringify({saveQueue: env.storage.saveQueue, contentQueue: env.storage.contentQueue}));
  Object.assign(env.storage, initial);
  env.storage.save(true, false);
  await env.settleSaveQueue();
  assert.equal(JSON.parse(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY)).debug.tile_grid, true);
  assert.equal((await env.write("serialized", new Uint8Array([1]))).status, 0);
  env.close();
});

test("settings saves serialize before startup and startup preserves the queue", async () => {
  const env = await new Environment().init();
  env.storage.save(true, false);
  env.storage.save(false, true);
  const queue = env.storage.saveQueue;
  await env.settleSaveQueue();
  assert.deepEqual(JSON.parse(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY)), {
    version: 1, debug: {tile_grid: false, chunk_borders: true},
  });
  await env.start();
  assert.equal(env.storage.saveQueue, queue);
  env.storage.start(() => assert.fail("startup must notify only once"), 0, 0);
  assert.equal(env.storage.saveQueue, queue);
  env.close();
});

test("reset initializes the settings queue without startup", async () => {
  const env = await new Environment().init();
  env.indexedDB.seed(STORE_CONFIG, CONFIG_KEY, "{ malformed");
  env.storage.reset();
  await env.settleSaveQueue();
  assert.equal(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY), undefined);
  assert.equal(env.storage.started, false);
  env.close();
});

test("content operations serialize before startup without replacing the queue", async () => {
  const env = await new Environment().init();
  const order = [];
  let release;
  const first = env.storage.queueContent(() => new Promise(resolve => {
    order.push("first started");
    release = () => { order.push("first finished"); resolve({status: 0}); };
  }));
  const second = env.storage.queueContent(async () => { order.push("second"); return {status: 0}; });
  const queue = env.storage.contentQueue;
  await env.start();
  assert.equal(env.storage.contentQueue, queue);
  assert.deepEqual(order, ["first started"]);
  release();
  await Promise.all([first, second]);
  assert.deepEqual(order, ["first started", "first finished", "second"]);
  env.close();
});

test("content round-trip writes, reads, lists and deletes", async () => {
  const env = await new Environment().init();
  const payload = encoder.encode("hello content");
  assert.equal((await env.write("alpha", payload)).status, 0);
  const read = await env.readContent("alpha");
  assert.equal(read.status, 0);
  assert.deepEqual(read.bytes, payload);
  const listed = await env.list();
  assert.equal(listed.status, 0);
  assert.deepEqual(listed.keys, ["alpha"]);
  assert.equal((await env.remove("alpha")).status, 0);
  assert.equal((await env.readContent("alpha")).status, 1);
  env.close();
});

test("content delete reports not_found for a missing key", async () => {
  const env = await new Environment().init();
  assert.equal((await env.remove("absent")).status, 1);
  assert.equal(env.indexedDB.peek(STORE_CONTENT, "absent"), undefined);

  // An existing entry is still deleted and reported as success.
  assert.equal((await env.write("present", Uint8Array.from([1]))).status, 0);
  assert.equal((await env.remove("present")).status, 0);
  assert.equal(env.indexedDB.peek(STORE_CONTENT, "present"), undefined);
  env.close();
});

test("content reads Blob and Uint8Array values written by other code", async () => {
  const env = await new Environment().init();
  env.indexedDB.seed(STORE_CONTENT, "blob", new Blob([Uint8Array.from([1, 2, 3])]));
  env.indexedDB.seed(STORE_CONTENT, "view", Uint8Array.from([4, 5]));
  assert.deepEqual((await env.readContent("blob")).bytes, Uint8Array.from([1, 2, 3]));
  assert.deepEqual((await env.readContent("view")).bytes, Uint8Array.from([4, 5]));
  env.close();
});

test("content read reports too_large for oversize stored values", async () => {
  const env = await new Environment().init();
  const payload = Uint8Array.from([1, 2, 3, 4, 5]);
  env.indexedDB.seed(STORE_CONTENT, "blob", new Blob([payload]));
  env.indexedDB.seed(STORE_CONTENT, "view", payload);
  env.indexedDB.seed(STORE_CONTENT, "buffer", payload.buffer);

  const originalLimit = env.storage.MAX_CONTENT_BYTES;
  env.storage.MAX_CONTENT_BYTES = 4;
  try {
    assert.equal((await env.readContent("blob")).status, 3);
    assert.equal((await env.readContent("view")).status, 3);
    assert.equal((await env.readContent("buffer")).status, 3);
  } finally {
    env.storage.MAX_CONTENT_BYTES = originalLimit;
  }
  env.close();
});

test("content list sorts keys and skips invalid stored names", async () => {
  const env = await new Environment().init();
  env.indexedDB.seed(STORE_CONTENT, "zeta", new Uint8Array([1]));
  env.indexedDB.seed(STORE_CONTENT, "alpha", new Uint8Array([1]));
  env.indexedDB.seed(STORE_CONTENT, "bad key", new Uint8Array([1]));
  env.indexedDB.seed(STORE_CONTENT, "nested/path", new Uint8Array([1]));
  const listed = await env.list();
  assert.equal(listed.status, 0);
  assert.deepEqual(listed.keys, ["alpha", "zeta"]);
  env.close();
});

test("content rejects invalid keys and oversize writes without touching storage", async () => {
  const env = await new Environment().init();
  assert.equal((await env.write("bad/key", new Uint8Array([1]))).status, 2);
  assert.equal((await env.readContent("../escape")).status, 2);
  assert.equal((await env.remove("has space")).status, 2);

  const key = env.ascii("large");
  const data = env.ascii("x");
  const status = await new Promise((resolve) => {
    env.library.haystack_content_write(key.pointer, key.length, data.pointer, MAX_CONTENT + 1, (_context, code) => resolve(code), 0);
  });
  assert.equal(status, 3);
  assert.equal(env.indexedDB.peek(STORE_CONTENT, "large"), undefined);
  env.close();
});

test("content list refuses a result larger than the allowed output", async () => {
  const env = await new Environment().init();
  env.indexedDB.seed(STORE_CONTENT, "aa", new Uint8Array([1]));
  env.indexedDB.seed(STORE_CONTENT, "bb", new Uint8Array([1]));
  env.indexedDB.seed(STORE_CONTENT, "cc", new Uint8Array([1]));

  const originalLimit = env.storage.MAX_RESULT_BYTES;
  env.storage.MAX_RESULT_BYTES = 5; // "aa\nbb\ncc" is 8 bytes
  try {
    const listed = await env.list();
    assert.equal(listed.status, 3);
    assert.deepEqual(listed.keys, []);
  } finally {
    env.storage.MAX_RESULT_BYTES = originalLimit;
  }

  env.storage.MAX_RESULT_BYTES = 8;
  try {
    const listed = await env.list();
    assert.equal(listed.status, 0);
    assert.deepEqual(listed.keys, ["aa", "bb", "cc"]);
  } finally {
    env.storage.MAX_RESULT_BYTES = originalLimit;
  }
  env.close();
});

test("toBytes rejects oversize values before copying", async () => {
  const env = await new Environment().init();
  const originalLimit = env.storage.MAX_CONTENT_BYTES;
  env.storage.MAX_CONTENT_BYTES = 4;
  try {
    assert.equal((await env.storage.toBytes(new ArrayBuffer(5))).status, 3);
    assert.equal((await env.storage.toBytes(Uint8Array.from([1, 2, 3, 4, 5]))).status, 3);
    assert.equal((await env.storage.toBytes(new Blob([Uint8Array.from([1, 2, 3, 4, 5])]))).status, 3);
  } finally {
    env.storage.MAX_CONTENT_BYTES = originalLimit;
  }

  // Prove the ArrayBuffer/view guards run before any copying slice call.
  const arrayBufferSlice = ArrayBuffer.prototype.slice;
  const typedArraySlice = Uint8Array.prototype.slice;
  let arrayBufferCopies = 0;
  let viewCopies = 0;
  ArrayBuffer.prototype.slice = function (...args) {
    arrayBufferCopies += 1;
    return arrayBufferSlice.apply(this, args);
  };
  Uint8Array.prototype.slice = function (...args) {
    viewCopies += 1;
    return typedArraySlice.apply(this, args);
  };
  env.storage.MAX_CONTENT_BYTES = 4;
  try {
    assert.equal((await env.storage.toBytes(new ArrayBuffer(5))).status, 3);
    assert.equal((await env.storage.toBytes(Uint8Array.from([1, 2, 3, 4, 5]))).status, 3);
    assert.equal(arrayBufferCopies, 0);
    assert.equal(viewCopies, 0);
  } finally {
    ArrayBuffer.prototype.slice = arrayBufferSlice;
    Uint8Array.prototype.slice = typedArraySlice;
    env.storage.MAX_CONTENT_BYTES = originalLimit;
  }

  const bufferBytes = await env.storage.toBytes(new ArrayBuffer(4));
  assert.equal(bufferBytes.status, 0);
  assert.deepEqual(bufferBytes.bytes, new Uint8Array(4));
  const viewBytes = await env.storage.toBytes(Uint8Array.from([1, 2, 3, 4]));
  assert.equal(viewBytes.status, 0);
  assert.deepEqual(viewBytes.bytes, Uint8Array.from([1, 2, 3, 4]));
  const blobBytes = await env.storage.toBytes(new Blob([Uint8Array.from([1, 2, 3, 4])]));
  assert.equal(blobBytes.status, 0);
  assert.deepEqual(blobBytes.bytes, Uint8Array.from([1, 2, 3, 4]));
  env.close();
});

test("content write and delete report transaction failures, not request success", async () => {
  const env = await new Environment().init();
  await env.list(); // force the database to open
  env.indexedDB.latest().failStore = STORE_CONTENT;
  assert.equal((await env.write("entry", new Uint8Array([1]))).status, 5);
  env.indexedDB.seed(STORE_CONTENT, "existing", new Uint8Array([1]));
  assert.equal((await env.remove("existing")).status, 5);
  env.close();
});

test("config with an unknown field is preserved and blocks autosave", async () => {
  const env = await new Environment().init();
  const raw = JSON.stringify({version: 1, debug: {tile_grid: true}, extra: true});
  env.indexedDB.seed(STORE_CONFIG, CONFIG_KEY, raw);
  const started = await env.start();
  assert.equal(started.status, 2);
  assert.equal(started.blocked, 1);

  env.storage.save(true, true);
  await env.settleSaveQueue();
  assert.equal(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY), raw, "malformed config is never overwritten");
  env.close();
});

test("config over 64 KiB is rejected before JSON.parse", async () => {
  const env = await new Environment().init();
  const raw = JSON.stringify({version: 1, debug: {}, pad: "x".repeat(MAX_CONFIG)});
  assert.ok(raw.length > MAX_CONFIG);
  env.indexedDB.seed(STORE_CONFIG, CONFIG_KEY, raw);
  const started = await env.start();
  assert.equal(started.status, 2);
  assert.equal(started.blocked, 1);
  assert.equal(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY), raw);
  env.close();
});

test("newer config version is preserved", async () => {
  const env = await new Environment().init();
  const raw = JSON.stringify({version: 99, debug: {}});
  env.indexedDB.seed(STORE_CONFIG, CONFIG_KEY, raw);
  const started = await env.start();
  assert.equal(started.status, 3);
  assert.equal(started.blocked, 1);
  assert.equal(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY), raw);
  env.close();
});

test("valid config loads values and saves after a completed transaction", async () => {
  const env = await new Environment().init();
  env.indexedDB.seed(STORE_CONFIG, CONFIG_KEY, JSON.stringify({version: 1, debug: {tile_grid: true, chunk_borders: false}}));
  const started = await env.start();
  assert.equal(started.status, 0);
  assert.equal(started.tileGrid, 1);
  assert.equal(started.chunkBorders, 0);
  assert.equal(started.blocked, 0);

  env.storage.save(false, true);
  await env.settleSaveQueue();
  const stored = JSON.parse(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY));
  assert.deepEqual(stored, {version: 1, debug: {tile_grid: false, chunk_borders: true}});
  env.close();
});

test("config transaction abort blocks autosave even if the request succeeded", async () => {
  const env = await new Environment().init();
  await env.start();
  env.indexedDB.latest().abortStore = STORE_CONFIG;
  const originalError = console.error;
  console.error = () => {};
  try {
    env.storage.save(true, true);
    await env.settleSaveQueue();
  } finally {
    console.error = originalError;
  }
  assert.equal(env.storage.autosaveBlocked, true);
  assert.equal(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY), undefined);
  env.close();
});

test("reset deletes the config and re-enables autosave", async () => {
  const env = await new Environment().init();
  const raw = "{ not json";
  env.indexedDB.seed(STORE_CONFIG, CONFIG_KEY, raw);
  const started = await env.start();
  assert.equal(started.status, 2);
  assert.equal(started.blocked, 1);

  env.storage.reset();
  await env.settleSaveQueue();
  assert.equal(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY), undefined);
  assert.equal(env.storage.autosaveBlocked, false);

  env.storage.save(true, false);
  await env.settleSaveQueue();
  assert.deepEqual(JSON.parse(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY)), {
    version: 1,
    debug: {tile_grid: true, chunk_borders: false},
  });
  env.close();
});

test("a successful reset clears the block left by an earlier failed save", async () => {
  const env = await new Environment().init();
  await env.start();

  // The queued save fails after the reset request has already been queued.
  // Previously the reset cleared the block before the queue ran and never
  // cleared it again afterwards, so autosave stayed blocked for the page.
  env.indexedDB.writeFailures = 1;
  const originalError = console.error;
  console.error = () => {};
  try {
    env.storage.save(true, true);
    env.storage.reset();
    await env.settleSaveQueue();
  } finally {
    console.error = originalError;
  }
  assert.equal(env.indexedDB.writeFailures, 0);
  assert.equal(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY), undefined);
  assert.equal(env.storage.autosaveBlocked, false);

  env.storage.save(true, false);
  await env.settleSaveQueue();
  assert.deepEqual(JSON.parse(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY)), {
    version: 1,
    debug: {tile_grid: true, chunk_borders: false},
  });
  env.close();
});

test("a failed reset keeps autosave blocked and preserves the stored config", async () => {
  const env = await new Environment().init();
  const raw = JSON.stringify({version: 1, debug: {tile_grid: true}, extra: true});
  env.indexedDB.seed(STORE_CONFIG, CONFIG_KEY, raw);
  const started = await env.start();
  assert.equal(started.status, 2);
  assert.equal(started.blocked, 1);

  env.indexedDB.latest().failStore = STORE_CONFIG;
  const originalError = console.error;
  console.error = () => {};
  try {
    env.storage.reset();
    // The reset has not committed yet, so a save requested now must be
    // refused rather than queued behind an unknown outcome.
    assert.equal(env.storage.autosaveBlocked, true);
    env.storage.save(true, true);
    await env.settleSaveQueue();
  } finally {
    console.error = originalError;
    env.indexedDB.latest().failStore = null;
  }
  assert.equal(env.storage.autosaveBlocked, true);
  assert.equal(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY), raw);

  env.storage.reset();
  await env.settleSaveQueue();
  assert.equal(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY), undefined);
  assert.equal(env.storage.autosaveBlocked, false);
  env.close();
});

test("missing Web Locks fails closed", async () => {
  const env = await new Environment({navigator: {}}).init();
  assert.equal((await env.start()).status, 4);
  env.close();
});

for (const [name, navigator] of [
  ["missing", {}],
  ["denied", {locks: {request: (_name, _options, callback) => Promise.resolve(callback(null))}}],
  ["rejected", {locks: {request: () => Promise.reject(new Error("denied"))}}],
  ["sync throw", {locks: {request: () => { throw new Error("denied"); }}}],
]) {
  test(`${name} lock denies every storage API before and after startup`, async () => {
    let opens = 0;
    const env = await new Environment({navigator, indexedDB: {open() { opens++; throw new Error("must not open"); }}}).init();
    const originalError = console.error;
    console.error = () => {};
    try {
      for (let pass = 0; pass < 2; pass++) {
        env.storage.save(true, true);
        env.storage.reset();
        await env.settleSaveQueue();
        assert.equal((await env.write("entry", new Uint8Array([1]))).status, 4);
        assert.equal((await env.readContent("entry")).status, 4);
        assert.equal((await env.list()).status, 4);
        assert.equal((await env.remove("entry")).status, 4);
        if (!pass) assert.equal((await env.start()).status, 4);
      }
      assert.equal(opens, 0);
    } finally { console.error = originalError; }
    env.close();
  });
}

test("pending acquisition is shared by pre-start operations and startup", async () => {
  let grant;
  let requests = 0;
  let requestDone;
  const env = await new Environment({navigator: {locks: {request: (_name, _options, callback) => {
    requests++;
    return new Promise(resolve => { grant = () => {
      requestDone = Promise.resolve(callback({name: "held"}));
      resolve(requestDone);
    }; });
  }}}}).init();
  const writing = env.write("entry", new Uint8Array([1]));
  env.storage.save(true, false);
  const starting = env.start();
  assert.equal(requests, 1);
  assert.equal(env.storage.dbPromise, null);
  grant();
  assert.equal((await writing).status, 0);
  assert.equal((await starting).status, 0);
  await env.settleSaveQueue();
  assert.equal(requests, 1);
  const db = env.storage.db;
  env.storage.holdLock();
  assert.equal(db.closed, true);
  assert.equal((await env.write("entry", new Uint8Array([2]))).status, 4);
  assert.equal((await env.readContent("entry")).status, 4);
  await requestDone;
  env.close();
});

test("pre-start acquisition is reused and throwing startup callback releases it", async () => {
  let requests = 0;
  let lifetime;
  const env = await new Environment({navigator: {locks: {request: (_name, _options, callback) => {
    requests++;
    lifetime = Promise.resolve(callback({name: "held"}));
    return lifetime;
  }}}}).init();
  assert.equal((await env.write("before", new Uint8Array([1]))).status, 0);
  const db = env.storage.db;
  let calls = 0;
  let notified;
  const notification = new Promise(resolve => { notified = resolve; });
  env.storage.start(() => { calls++; notified(); throw new Error("callback failed"); }, 0, 0);
  await notification;
  await lifetime;
  assert.equal(calls, 1);
  assert.equal(requests, 1);
  assert.equal(env.storage.lockOwned, false);
  assert.equal(db.closed, true);
  assert.equal((await env.write("after", new Uint8Array([1]))).status, 4);
  assert.equal((await env.list()).status, 4);
  assert.equal((await env.remove("before")).status, 4);
  assert.equal((await env.readContent("before")).status, 4);
  const raw = JSON.stringify({version: 1, debug: {tile_grid: true}});
  env.indexedDB.seed(STORE_CONFIG, CONFIG_KEY, raw);
  const originalError = console.error;
  console.error = () => {};
  try {
    env.storage.reset();
    env.storage.save(false, false);
    await env.settleSaveQueue();
  } finally { console.error = originalError; }
  assert.equal(env.indexedDB.peek(STORE_CONFIG, CONFIG_KEY), raw);
  env.storage.start(() => assert.fail("must not notify twice"), 0, 0);
  env.close();
});

test("blocked open closes late success without invalidating a newer open", async () => {
  const requests = [];
  let opened;
  const nextOpen = () => new Promise(resolve => { opened = resolve; });
  const env = await new Environment({indexedDB: {open() {
    const request = {};
    requests.push(request);
    opened();
    return request;
  }}}).init();
  await env.storage.acquireLock();
  let opening = nextOpen();
  const first = env.storage.openDb();
  await opening;
  requests[0].onblocked();
  await assert.rejects(first, /blocked/);
  opening = nextOpen();
  const second = env.storage.openDb();
  await opening;
  const late = {closed: false, close() { this.closed = true; }};
  requests[0].result = late;
  requests[0].onsuccess();
  assert.equal(late.closed, true);
  const current = {closed: false, close() { this.closed = true; }};
  requests[1].result = current;
  requests[1].onsuccess();
  assert.equal(await second, current);
  assert.equal(await env.storage.openDb(), current);
  current.onversionchange();
  assert.equal(current.closed, true);
  opening = nextOpen();
  const third = env.storage.openDb();
  await opening;
  assert.equal(requests.length, 3);
  // An old versionchange event must not evict a new pending connection.
  const pending = env.storage.dbPromise;
  current.onversionchange();
  assert.equal(env.storage.dbPromise, pending);
  requests[2].result = {close() {}};
  requests[2].onsuccess();
  await third;
  env.close();
});

test("read helpers reject a transaction abort without a request event", async () => {
  const env = await new Environment().init();
  const transactions = [];
  const db = {transaction() {
    const transaction = {error: new Error("aborted"), objectStore() {
      return {get() { return {}; }, getAllKeys() { return {}; }};
    }};
    transactions.push(transaction);
    return transaction;
  }};
  const get = env.storage.idbGet(db, STORE_CONTENT, "entry");
  const list = env.storage.idbGetAllKeys(db, STORE_CONTENT);
  transactions.forEach(transaction => transaction.onabort());
  await assert.rejects(get, /aborted/);
  await assert.rejects(list, /aborted/);
  env.close();
});

test("write and delete results wait for completion and reject aborts", async () => {
  const env = await new Environment().init();
  await env.start();
  env.indexedDB.latest().abortStore = STORE_CONTENT;
  assert.equal((await env.write("entry", new Uint8Array([1]))).status, 5);
  env.indexedDB.seed(STORE_CONTENT, "entry", new Uint8Array([1]));
  assert.equal((await env.remove("entry")).status, 5);
  assert.deepEqual(env.indexedDB.peek(STORE_CONTENT, "entry"), new Uint8Array([1]));
  env.close();
});

test("IndexedDB unavailable still starts with defaults and blocked autosave", async () => {
  const env = await new Environment({indexedDB: {open() { throw new Error("unavailable"); }}}).init();
  const started = await env.start();
  assert.equal(started.status, 1);
  assert.equal(started.blocked, 1);
  assert.equal((await env.write("entry", new Uint8Array([1]))).status, 4);
  env.close();
});

let failed = 0;
for (const {name, fn} of tests) {
  try {
    await fn();
    console.log(`ok - ${name}`);
  } catch (error) {
    failed += 1;
    console.error(`not ok - ${name}`);
    console.error(error && error.stack ? error.stack : error);
  }
}

if (failed !== 0) {
  console.error(`${failed} browser storage test(s) failed`);
  process.exitCode = 1;
} else {
  console.log(`${tests.length} browser storage tests passed`);
}
