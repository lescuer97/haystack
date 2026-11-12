// Node-only harness for browser/game-storage.js.
//
// Chromium is not always available, so this test evaluates the Emscripten JS
// library against a small in-memory IndexedDB implementation. It covers the
// content bridge (round-trip, Blob reads, list ordering, limits, transaction
// failures) and settings validation (64 KiB cap, schema, preserve/reset).
//
// It does not emulate a real browser's IndexedDB durability, Web Locks or
// storage quotas. Run `zig build test -Dplatform=wasm` for the Chromium suite.

import {readFile} from "node:fs/promises";
import {strict as assert} from "node:assert";

const DB_NAME = "haystack-game";
const STORE_CONFIG = "config";
const STORE_CONTENT = "content";
const CONFIG_KEY = "settings";
const MAX_CONFIG = 64 * 1024;
const MAX_CONTENT = 64 * 1024 * 1024;

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
    this.transaction.add(request, () => Array.from(this.data.keys()));
    return request;
  }

  getKey(key) {
    const request = new FakeRequest();
    this.transaction.add(request, () => (this.data.has(key) ? key : undefined));
    return request;
  }

  put(value, key) {
    const request = new FakeRequest();
    this.transaction.add(request, () => {
      if (this.transaction.db.failStore === this.name) throw new Error("injected write failure");
      this.data.set(key, value instanceof Uint8Array ? value.slice() : value);
      return key;
    });
    return request;
  }

  delete(key) {
    const request = new FakeRequest();
    this.transaction.add(request, () => {
      if (this.transaction.db.failStore === this.name) throw new Error("injected delete failure");
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
    this.snapshots = names.map((name) => [name, new Map(db.stores.get(name))]);
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
    if (this.db.abortStore === this.names[0] && this.mode === "readwrite") {
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
  constructor(record) {
    this.stores = record.stores;
    this.failStore = null;
    this.abortStore = null;
    this.objectStoreNames = {
      contains: (name) => this.stores.has(name),
    };
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
}

class FakeIndexedDB {
  constructor() {
    this.records = new Map();
    this.instances = [];
    this.nextOpenFailure = false;
  }

  open(name, version) {
    const request = new FakeRequest();
    queueMicrotask(() => {
      if (this.nextOpenFailure) {
        request.error = new Error("injected open failure");
        if (request.onerror) request.onerror();
        return;
      }
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
      const db = new FakeDatabase(record);
      this.instances.push(db);
      request.result = db;
      if (upgrade && request.onupgradeneeded) request.onupgradeneeded();
      if (request.onsuccess) request.onsuccess();
    });
    return request;
  }

  seed(store, key, value) {
    let record = this.records.get(DB_NAME);
    if (!record) {
      record = {version: 1, stores: new Map()};
      this.records.set(DB_NAME, record);
    }
    if (!record.stores.has(STORE_CONFIG)) record.stores.set(STORE_CONFIG, new Map());
    if (!record.stores.has(STORE_CONTENT)) record.stores.set(STORE_CONTENT, new Map());
    record.stores.get(store).set(key, value);
  }

  peek(store, key) {
    const record = this.records.get(DB_NAME);
    return record && record.stores.has(store) ? record.stores.get(store).get(key) : undefined;
  }

  latest() {
    return this.instances[this.instances.length - 1];
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

test("missing Web Locks fails closed", async () => {
  const env = await new Environment({navigator: {}}).init();
  assert.equal((await env.start()).status, 4);
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
