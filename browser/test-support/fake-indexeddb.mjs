// Shared, test-only in-memory IndexedDB model.
//
// Both Node harnesses (`game-storage-test.mjs` and `wallet-store-test.mjs`)
// import this module so the request/transaction/open lifecycle and the
// injected-failure hooks live in one place.
//
// The model is deliberately small. It reproduces only the behaviour the
// storage bridges depend on:
//
//   * a request fires its `onsuccess`/`onerror` before the transaction
//     completes, and writes are only successful once `oncomplete` fires;
//   * an error or an explicit `abort()` rolls every store back to the snapshot
//     taken when the transaction opened, then fires `onabort`; request errors
//     bubble to `onerror` before the default abort unless canceled;
//   * opens report version-change events and roll back schema changes on
//     upgrade abort, report `VersionError`, notify `onversionchange` and block
//     while another connection is still open;
//   * `Uint8Array` payloads are copied on write; plain records are stored by
//     reference rather than fully structured-cloned.
//
// It is NOT a durable or spec-complete IndexedDB: nothing survives the
// process, there are no quotas, cursors, indexes, key ranges or cross-tab
// semantics, and every operation runs on the microtask queue in one process.
// Use the Chromium suite for real browser integration; this model does not
// establish durability or quota guarantees.

export class FakeRequest {
  constructor() {
    this.result = undefined;
    this.error = null;
    this.onsuccess = null;
    this.onerror = null;
    this.onupgradeneeded = null;
    this.onblocked = null;
  }
}

// Minimal `error` event shape: `preventDefault` records that a listener handled
// the error, which (as in IndexedDB) cancels default abort, not bubbling.
function errorEvent(target, error) {
  return {
    type: "error",
    target,
    error,
    defaultPrevented: false,
    preventDefault() { this.defaultPrevented = true; },
  };
}

export class FakeObjectStore {
  constructor(transaction, name) {
    this.transaction = transaction;
    this.name = name;
    this.data = transaction.db.stores.get(name);
  }

  get(key) {
    const request = new FakeRequest();
    this.transaction.add(request, () => {
      this.checkRead(key);
      return this.data.has(key) ? this.data.get(key) : undefined;
    });
    return request;
  }

  getAllKeys() {
    const request = new FakeRequest();
    this.transaction.add(request, () => {
      this.checkRead();
      return Array.from(this.data.keys());
    });
    return request;
  }

  getKey(key) {
    const request = new FakeRequest();
    this.transaction.add(request, () => {
      this.checkRead(key);
      return this.data.has(key) ? key : undefined;
    });
    return request;
  }

  put(value, key) {
    const request = new FakeRequest();
    this.transaction.add(request, () => {
      this.checkWrite(key);
      this.data.set(key, copyPayload(value));
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
      this.checkWrite(key);
      this.data.set(key, copyPayload(value));
      return key;
    });
    return request;
  }

  delete(key) {
    const request = new FakeRequest();
    this.transaction.add(request, () => {
      this.checkWrite(key);
      this.data.delete(key);
      return undefined;
    });
    return request;
  }

  checkRead(key) {
    const indexedDB = this.transaction.db.indexedDB;
    if (indexedDB.readFailures > 0) {
      indexedDB.readFailures -= 1;
      throw new Error("injected read failure");
    }
    if (key !== undefined && indexedDB.failReadKeys.has(key)) throw new Error("injected read failure");
  }

  checkWrite(key) {
    if (this.transaction.db.failStore === this.name) throw new Error("injected write failure");
    if (key !== undefined && this.transaction.db.indexedDB.failWriteKeys.has(key)) throw new Error("injected write failure");
    this.transaction.db.checkWrite();
  }
}

// Structured cloning copies typed-array payloads; plain records are handed to
// the bridge by reference, as the wallet layer never mutates them.
function copyPayload(value) {
  return value instanceof Uint8Array ? value.slice() : value;
}

export class FakeTransaction {
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
        const event = errorEvent(request, error);
        if (this.db.indexedDB.preventRequestErrors) event.preventDefault();
        try {
          if (request.onerror) request.onerror(event);
          if (this.onerror) this.onerror(event);
        } catch (caught) {
          this.abort(caught);
          return;
        }
        if (!event.defaultPrevented) this.abort(error);
        this.pending -= 1;
        this.maybeComplete();
        return;
      }
      this.pending -= 1;
      this.maybeComplete();
    });
  }

  maybeComplete() {
    if (this.pending !== 0 || this.finished) return;
    if (this.mode === "readwrite") {
      if (this.db.indexedDB.abortNextWrite) {
        this.db.indexedDB.abortNextWrite = false;
        this.abort(new Error("injected transaction abort"));
        return;
      }
      if (this.db.abortStore === this.names[0]) {
        this.abort(new Error("injected transaction abort"));
        return;
      }
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
      if (this.onabort) this.onabort();
    });
  }
}

export class FakeDatabase {
  constructor(record, indexedDB) {
    this.record = record;
    this.stores = record.stores;
    this.indexedDB = indexedDB;
    this.objectStoreNames = {contains: name => this.stores.has(name)};
    this.closed = false;
    // Injected failures for the whole store (game harness).
    this.failStore = null;
    this.abortStore = null;
    record.connections.add(this);
  }

  close() {
    this.closed = true;
    this.record.connections.delete(this);
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

  // Injected failure for the next write request (wallet harness).
  checkWrite() {
    if (this.indexedDB.writeFailures > 0) {
      this.indexedDB.writeFailures -= 1;
      throw new Error("injected write failure");
    }
  }
}

export class FakeIndexedDB {
  constructor({database, version = 1, stores = []} = {}) {
    if (typeof database !== "string" || !database.length) throw new Error("a database name is required");
    this.database = database;
    this.defaultVersion = version;
    this.defaultStores = stores;
    this.records = new Map();
    this.instances = [];
    this.nextOpenFailure = false;
    this.writeFailures = 0;
    this.readFailures = 0;
    this.failReadKeys = new Set();
    this.failWriteKeys = new Set();
    this.preventRequestErrors = false;
    this.abortNextWrite = false;
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
      const oldVersion = record.version;
      const upgrade = version > oldVersion;
      if (upgrade) {
        // Another connection must close before this upgrade can proceed.
        for (const db of [...record.connections]) if (db.onversionchange) db.onversionchange();
        if (record.connections.size) {
          if (request.onblocked) request.onblocked();
          return;
        }
      }
      const database = new FakeDatabase(record, this);
      this.instances.push(database);
      request.result = database;
      if (upgrade) {
        const stores = new Map(record.stores);
        record.version = version;
        let aborted = false;
        request.transaction = {abort() { aborted = true; }};
        try {
          request.onupgradeneeded?.({type: "upgradeneeded", target: request, oldVersion, newVersion: version});
        } catch (_) {
          aborted = true;
        }
        request.transaction = null;
        if (aborted) {
          database.close();
          record.version = oldVersion;
          record.stores = stores;
          if (oldVersion === 0) this.records.delete(name);
          request.result = undefined;
          request.error = new Error("AbortError");
          request.error.name = "AbortError";
          if (request.onerror) request.onerror();
          return;
        }
      }
      if (request.onsuccess) request.onsuccess();
    });
    return request;
  }

  ensure(options = {}) {
    let record = this.records.get(this.database);
    if (!record) {
      record = {version: options.version ?? this.defaultVersion, stores: new Map(), connections: new Set()};
      this.records.set(this.database, record);
    }
    for (const name of options.stores ?? this.defaultStores) {
      if (!record.stores.has(name)) record.stores.set(name, new Map());
    }
    return record;
  }

  store(storeName) {
    const record = this.records.get(this.database);
    if (!record) throw new Error(`database ${this.database} was created`);
    const store = record.stores.get(storeName);
    if (!store) throw new Error(`${storeName} store exists`);
    return store;
  }

  peek(storeName, key) {
    const record = this.records.get(this.database);
    return record && record.stores.has(storeName) ? record.stores.get(storeName).get(key) : undefined;
  }

  seed(storeName, key, value, {create = false} = {}) {
    const record = create ? this.ensure() : this.records.get(this.database);
    if (!record) throw new Error(`database ${this.database} was created`);
    if (!record.stores.has(storeName)) {
      if (!create) throw new Error(`${storeName} store exists`);
      record.stores.set(storeName, new Map());
    }
    record.stores.get(storeName).set(key, value);
  }

  latest() {
    return this.instances[this.instances.length - 1];
  }
}
