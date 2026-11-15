// Focused tests for the shared in-memory IndexedDB model.
//
// These lock down the semantics both browser storage harnesses rely on:
// request-before-complete ordering, abort rollback, the injected failure
// hooks, structured-clone copying of typed arrays, and open upgrade /
// VersionError / blocking behaviour. This is a model, not a browser: see the
// module header for the documented limitations.

import {strict as assert} from "node:assert";
import {FakeIndexedDB} from "./fake-indexeddb.mjs";

const tests = [];
const test = (name, fn) => tests.push({name, fn});

function openDatabase(indexedDB, name = "fixture", version = 1, upgrade) {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(name, version);
    request.onupgradeneeded = () => { if (upgrade) upgrade(request.result); };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    request.onblocked = () => reject(new Error("upgrade was blocked"));
  });
}

function runTransaction(db, names, mode, action) {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(names, mode);
    transaction.oncomplete = () => resolve();
    transaction.onabort = () => reject(transaction.error || new Error("aborted"));
    transaction.onerror = () => {};
    action(transaction);
  });
}

const createStore = database => database.createObjectStore("s");

test("a request succeeds before its transaction completes", async () => {
  const indexedDB = new FakeIndexedDB({database: "fixture"});
  const db = await openDatabase(indexedDB, "fixture", 1, createStore);
  const order = [];
  await new Promise((resolve, reject) => {
    const transaction = db.transaction("s", "readwrite");
    transaction.oncomplete = () => { order.push("complete"); resolve(); };
    transaction.onabort = () => reject(transaction.error);
    const put = transaction.objectStore("s").put("value", "k");
    put.onsuccess = () => order.push("request");
  });
  assert.deepEqual(order, ["request", "complete"]);
  assert.equal(indexedDB.peek("s", "k"), "value");
  db.close();
  assert.equal(db.closed, true);
});

test("a failed request aborts and rolls back the whole transaction", async () => {
  const indexedDB = new FakeIndexedDB({database: "fixture"});
  indexedDB.seed("s", "k", "original", {create: true});
  const db = await openDatabase(indexedDB, "fixture");

  // A store-wide request failure bubbles to the transaction.
  const events = [];
  indexedDB.latest().failStore = "s";
  await new Promise(resolve => {
    const transaction = db.transaction("s", "readwrite");
    transaction.onerror = () => events.push("error");
    transaction.onabort = () => { events.push("abort"); resolve(); };
    const request = transaction.objectStore("s").put("changed", "k");
    request.onerror = () => events.push("request-error");
  });
  assert.deepEqual(events, ["request-error", "error", "abort"]);
  assert.equal(indexedDB.peek("s", "k"), "original");

  // An abort at completion discards writes whose requests already succeeded.
  indexedDB.latest().failStore = null;
  indexedDB.latest().abortStore = "s";
  await new Promise(resolve => {
    const transaction = db.transaction("s", "readwrite");
    transaction.onabort = () => resolve();
    transaction.objectStore("s").put("changed", "k");
  });
  assert.equal(indexedDB.peek("s", "k"), "original");
  db.close();
});

test("wallet failure hooks fire exactly once", async () => {
  const indexedDB = new FakeIndexedDB({database: "fixture"});
  indexedDB.seed("s", "k", "value", {create: true});
  const db = await openDatabase(indexedDB, "fixture");

  indexedDB.writeFailures = 1;
  const failure = await new Promise(resolve => {
    const transaction = db.transaction("s", "readwrite");
    transaction.onabort = () => resolve(transaction.error);
    transaction.objectStore("s").put("first", "k");
  });
  assert.match(String(failure), /injected write failure/);
  assert.equal(indexedDB.writeFailures, 0);
  assert.equal(indexedDB.peek("s", "k"), "value");

  indexedDB.abortNextWrite = true;
  const aborted = await new Promise(resolve => {
    const transaction = db.transaction("s", "readwrite");
    transaction.onabort = () => resolve(transaction.error);
    transaction.objectStore("s").put("second", "k");
  });
  assert.match(String(aborted), /injected transaction abort/);
  assert.equal(indexedDB.abortNextWrite, false);
  assert.equal(indexedDB.peek("s", "k"), "value");
  db.close();
});

test("get, getKey, getAllKeys, add and delete match IndexedDB results", async () => {
  const indexedDB = new FakeIndexedDB({database: "fixture"});
  indexedDB.seed("s", "a", 1, {create: true});
  const db = await openDatabase(indexedDB, "fixture");

  const read = await new Promise((resolve, reject) => {
    const transaction = db.transaction("s", "readonly");
    const results = {};
    transaction.oncomplete = () => resolve(results);
    transaction.onabort = () => reject(transaction.error);
    const store = transaction.objectStore("s");
    const missing = store.get("missing");
    missing.onsuccess = () => { results.missing = missing.result; };
    const keys = store.getAllKeys();
    keys.onsuccess = () => { results.keys = keys.result; };
    const present = store.getKey("a");
    present.onsuccess = () => { results.present = present.result; };
    const absent = store.getKey("missing");
    absent.onsuccess = () => { results.absent = absent.result; };
  });
  assert.deepEqual(read, {missing: undefined, keys: ["a"], present: "a", absent: undefined});

  await runTransaction(db, "s", "readwrite", transaction => {
    transaction.objectStore("s").add("b", "b");
  });
  const duplicate = await new Promise(resolve => {
    const transaction = db.transaction("s", "readwrite");
    transaction.onabort = () => resolve(transaction.error);
    transaction.objectStore("s").add("again", "b");
  });
  assert.equal(duplicate.name, "ConstraintError");

  await runTransaction(db, "s", "readwrite", transaction => {
    transaction.objectStore("s").delete("a");
  });
  assert.equal(indexedDB.peek("s", "a"), undefined);
  assert.equal(indexedDB.peek("s", "b"), "b");
  db.close();
});

test("typed array payloads are copied on write", async () => {
  const indexedDB = new FakeIndexedDB({database: "fixture"});
  const db = await openDatabase(indexedDB, "fixture", 1, createStore);
  const payload = Uint8Array.from([1, 2, 3]);
  await runTransaction(db, "s", "readwrite", transaction => {
    transaction.objectStore("s").put(payload, "k");
  });
  payload[0] = 9;
  assert.deepEqual(indexedDB.peek("s", "k"), Uint8Array.from([1, 2, 3]));
  db.close();
});

test("open reports VersionError, versionchange and blocking", async () => {
  const indexedDB = new FakeIndexedDB({database: "fixture"});
  const first = await openDatabase(indexedDB, "fixture", 2, createStore);

  const newer = indexedDB.open("fixture", 1);
  const versionError = await new Promise(resolve => {
    newer.onerror = () => resolve(newer.error);
  });
  assert.equal(versionError.name, "VersionError");

  // A connection that ignores `versionchange` keeps the upgrade blocked.
  let notified = false;
  first.onversionchange = () => { notified = true; };
  const blocker = indexedDB.open("fixture", 3);
  const blocked = await new Promise(resolve => {
    blocker.onblocked = () => resolve(true);
  });
  assert.equal(blocked, true);
  assert.equal(notified, true);
  assert.equal(first.closed, false);
  first.close();

  let upgraded = false;
  const database = await openDatabase(indexedDB, "fixture", 3, db => {
    upgraded = true;
    db.createObjectStore("extra");
  });
  assert.equal(upgraded, true);
  assert.equal(indexedDB.records.get("fixture").version, 3);
  assert.equal(indexedDB.records.get("fixture").stores.has("extra"), true);
  database.close();
});

test("an injected open failure reaches onerror without creating a database", async () => {
  const indexedDB = new FakeIndexedDB({database: "fixture"});
  indexedDB.nextOpenFailure = true;
  const request = indexedDB.open("fixture", 1);
  const error = await new Promise(resolve => {
    request.onerror = () => resolve(request.error);
  });
  assert.match(String(error), /injected open failure/);
  assert.equal(indexedDB.records.has("fixture"), false);
});

test("seed can initialise the database and its default stores", () => {
  const indexedDB = new FakeIndexedDB({database: "fixture", stores: ["config", "content"]});
  indexedDB.seed("content", "key", Uint8Array.from([1]), {create: true});
  const record = indexedDB.records.get("fixture");
  assert.equal(record.version, 1);
  assert.deepEqual([...record.stores.keys()].sort(), ["config", "content"]);
  assert.deepEqual(indexedDB.peek("content", "key"), Uint8Array.from([1]));
});

test("preventDefault cancels default abort but explicit abort still rolls back", async () => {
  const indexedDB = new FakeIndexedDB({database: "fixture"});
  const db = await openDatabase(indexedDB, "fixture", 1, createStore);
  indexedDB.seed("s", "duplicate", "original");
  for (const explicit of [false, true]) {
    let bubbled = false;
    await new Promise(resolve => {
      const tx = db.transaction("s", "readwrite");
      tx.oncomplete = resolve;
      tx.onabort = resolve;
      tx.onerror = event => { bubbled = true; assert.equal(event.defaultPrevented, true); };
      tx.objectStore("s").put("value", "new");
      tx.objectStore("s").add("replacement", "duplicate").onerror = event => {
        event.preventDefault();
        if (explicit) tx.abort();
      };
    });
    assert.equal(bubbled, true);
    assert.equal(indexedDB.peek("s", "new"), explicit ? undefined : "value");
    indexedDB.store("s").delete("new");
    assert.equal(indexedDB.peek("s", "duplicate"), "original");
  }
});

test("read/key faults and callback exceptions abort without committing", async () => {
  const indexedDB = new FakeIndexedDB({database: "fixture"});
  const db = await openDatabase(indexedDB, "fixture", 1, createStore);
  for (const inject of [
    () => { indexedDB.readFailures = 1; },
    () => { indexedDB.failReadKeys.add("key"); },
    () => { indexedDB.failWriteKeys.add("new"); },
    () => {},
  ]) {
    inject();
    await assert.rejects(runTransaction(db, "s", "readwrite", tx => {
      tx.objectStore("s").put("value", "new");
      tx.objectStore("s").get("key").onsuccess = () => { throw new Error("callback failure"); };
    }));
    assert.equal(indexedDB.peek("s", "new"), undefined);
    indexedDB.failReadKeys.clear();
    indexedDB.failWriteKeys.clear();
  }
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
  console.error(`${failed} IndexedDB fixture test(s) failed`);
  process.exitCode = 1;
} else {
  console.log(`${tests.length} IndexedDB fixture tests passed`);
}
