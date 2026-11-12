// Emscripten JS library: browser settings/content storage and single-tab guard.
//
// This is deliberately separate from `game-wallet.js`. The wallet gate runs
// first and never touches this file; only after the wallet callback succeeds
// does the Zig startup code call `haystack_storage_start`.
//
// The bridge:
//   * acquires one exclusive Web Lock for the origin and holds it for the page
//     lifetime, so a second game tab fails startup;
//   * opens a dedicated IndexedDB database (`haystack-game`) with separate
//     `config` and `content` object stores;
//   * loads, validates and versions the settings JSON asynchronously;
//   * reports one status plus two booleans to Zig, copying them into the wasm
//     call and never retaining a wasm view across an `await`;
//   * queues saves so the frame loop never awaits or blocks;
//   * refuses to overwrite malformed or newer configuration until an explicit
//     reset removes it;
//   * exposes a flat content store: keys are copied into JS before the first
//     await, results are copied into Zig-owned memory after the await.
//
// Write/delete/reset success is the transaction's `oncomplete` event, never a
// request's `onsuccess`. `onabort`/`onerror` are failures. Content delete checks
// existence in the same readwrite transaction and reports `not_found` for a
// missing key instead of pretending a delete happened.
//
// No localStorage is used here and Asyncify is not required.

mergeInto(LibraryManager.library, {
  $haystackStorage: {
    DB_NAME: "haystack-game",
    DB_VERSION: 1,
    STORE_CONFIG: "config",
    STORE_CONTENT: "content",
    CONFIG_KEY: "settings",
    LOCK_NAME: "haystack-game-v1",
    CURRENT_VERSION: 1,
    MAX_CONFIG_BYTES: 64 * 1024,
    MAX_CONTENT_BYTES: 64 * 1024 * 1024,
    MAX_KEY_BYTES: 128,
    MAX_RESULT_BYTES: 64 * 1024 * 1024,

    started: false,
    notified: false,
    ready: 0,
    defaultTileGrid: false,
    defaultChunkBorders: false,
    autosaveBlocked: false,
    dbPromise: null,
    saveQueue: Promise.resolve(),
    contentQueue: Promise.resolve(),
    holdLock: null,

    notify: function (status, tileGrid, chunkBorders) {
      if (this.notified) return;
      this.notified = true;
      try {
        {{{ makeDynCall('viiii', 'haystackStorage.ready') }}}(
          status | 0,
          tileGrid ? 1 : 0,
          chunkBorders ? 1 : 0,
          this.autosaveBlocked ? 1 : 0,
        );
      } catch (_) {
        // A failure in the Zig callback must not keep the lock or the page in a
        // half-started state; nothing else is safe to do from here.
      }
    },

    notifyDefault: function (status) {
      this.notify(status, this.defaultTileGrid, this.defaultChunkBorders);
    },

    hasOwn: function (object, key) {
      return Object.prototype.hasOwnProperty.call(object, key);
    },

    hasOnlyKeys: function (object, allowed) {
      for (var key in object) {
        if (this.hasOwn(object, key) && allowed.indexOf(key) === -1) return false;
      }
      return true;
    },

    byteLength: function (text) {
      try {
        if (typeof TextEncoder !== "undefined") return new TextEncoder().encode(text).length;
      } catch (_) {}
      return text.length;
    },

    validKey: function (key) {
      return typeof key === "string" &&
        key.length >= 1 &&
        key.length <= this.MAX_KEY_BYTES &&
        /^[A-Za-z0-9_-]+$/.test(key);
    },

    // Copy a key out of wasm memory. The caller must not retain the view.
    decodeKey: function (pointer, length) {
      var size = length >>> 0;
      if (size === 0 || size > this.MAX_KEY_BYTES) return null;
      if (pointer < 0 || pointer + size > HEAPU8.length) return null;
      var key = "";
      for (var i = 0; i < size; i++) key += String.fromCharCode(HEAPU8[pointer + i]);
      return this.validKey(key) ? key : null;
    },

    openDb: function () {
      var self = this;
      if (!this.dbPromise) {
        this.dbPromise = new Promise(function (resolve, reject) {
          if (typeof indexedDB === "undefined" || !indexedDB) {
            reject(new Error("IndexedDB unavailable"));
            return;
          }
          var request;
          try {
            request = indexedDB.open(self.DB_NAME, self.DB_VERSION);
          } catch (_) {
            reject(new Error("IndexedDB unavailable"));
            return;
          }
          request.onupgradeneeded = function () {
            var db = request.result;
            if (!db.objectStoreNames.contains(self.STORE_CONFIG)) db.createObjectStore(self.STORE_CONFIG);
            if (!db.objectStoreNames.contains(self.STORE_CONTENT)) db.createObjectStore(self.STORE_CONTENT);
          };
          request.onsuccess = function () { resolve(request.result); };
          request.onerror = function () { reject(request.error || new Error("IndexedDB open failed")); };
          request.onblocked = function () { reject(new Error("IndexedDB blocked")); };
        });
        // Do not cache a permanently rejected promise forever if the browser
        // was merely opening the database; a later save may retry.
        this.dbPromise.catch(function () { self.dbPromise = null; });
      }
      return this.dbPromise;
    },

    // Reads resolve on the request result; there is no write to wait for.
    idbGet: function (db, store, key) {
      return new Promise(function (resolve, reject) {
        var transaction;
        try {
          transaction = db.transaction(store, "readonly");
        } catch (_) {
          reject(new Error("IndexedDB read failed"));
          return;
        }
        var request;
        try {
          request = transaction.objectStore(store).get(key);
        } catch (_) {
          reject(new Error("IndexedDB read failed"));
          return;
        }
        request.onsuccess = function () { resolve(request.result); };
        request.onerror = function () { reject(request.error || new Error("IndexedDB read failed")); };
      });
    },

    idbGetAllKeys: function (db, store) {
      return new Promise(function (resolve, reject) {
        var transaction;
        try {
          transaction = db.transaction(store, "readonly");
        } catch (_) {
          reject(new Error("IndexedDB read failed"));
          return;
        }
        var request;
        try {
          request = transaction.objectStore(store).getAllKeys();
        } catch (_) {
          reject(new Error("IndexedDB read failed"));
          return;
        }
        request.onsuccess = function () { resolve(request.result || []); };
        request.onerror = function () { reject(request.error || new Error("IndexedDB read failed")); };
      });
    },

    // Writes succeed only when the transaction completes. A request error
    // bubbles to the transaction and aborts it; do not resolve early.
    idbWrite: function (db, store, action) {
      return new Promise(function (resolve, reject) {
        var transaction;
        try {
          transaction = db.transaction(store, "readwrite");
        } catch (_) {
          reject(new Error("IndexedDB write failed"));
          return;
        }
        var settled = false;
        var fail = function (error) {
          if (settled) return;
          settled = true;
          reject(error || new Error("IndexedDB transaction failed"));
        };
        transaction.oncomplete = function () {
          if (settled) return;
          settled = true;
          resolve();
        };
        transaction.onabort = function () { fail(transaction.error); };
        transaction.onerror = function () { fail(transaction.error); };
        try {
          action(transaction.objectStore(store));
        } catch (error) {
          try { transaction.abort(); } catch (_) {}
          fail(error);
        }
      });
    },

    // Delete one entry and report whether it existed. The existence check and
    // the delete share one readwrite transaction, so no other transaction can
    // remove or recreate the key in between. The result is only reported after
    // `oncomplete`, like every other write/delete.
    idbDelete: function (db, store, key) {
      return new Promise(function (resolve, reject) {
        var transaction;
        try {
          transaction = db.transaction(store, "readwrite");
        } catch (_) {
          reject(new Error("IndexedDB delete failed"));
          return;
        }
        var settled = false;
        var found = false;
        var fail = function (error) {
          if (settled) return;
          settled = true;
          reject(error || new Error("IndexedDB transaction failed"));
        };
        transaction.oncomplete = function () {
          if (settled) return;
          settled = true;
          resolve(found);
        };
        transaction.onabort = function () { fail(transaction.error); };
        transaction.onerror = function () { fail(transaction.error); };
        try {
          // `getKey` checks presence without materialising the stored value;
          // deleting a large entry only needs the key back.
          var request = transaction.objectStore(store).getKey(key);
          request.onsuccess = function () {
            found = request.result !== undefined;
            if (!found) return;
            try {
              transaction.objectStore(store).delete(key);
            } catch (error) {
              try { transaction.abort(); } catch (_) {}
              fail(error);
            }
          };
          request.onerror = function () {
            fail(request.error || new Error("IndexedDB read failed"));
          };
        } catch (error) {
          try { transaction.abort(); } catch (_) {}
          fail(error);
        }
      });
    },

    parseConfig: function (raw) {
      if (typeof raw !== "string") return { status: 2 };
      if (this.byteLength(raw) > this.MAX_CONFIG_BYTES) return { status: 2 };

      var parsed;
      try {
        parsed = JSON.parse(raw);
      } catch (_) {
        return { status: 2 };
      }
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { status: 2 };
      if (!this.hasOwn(parsed, "version") || !Number.isInteger(parsed.version)) return { status: 2 };
      if (parsed.version > this.CURRENT_VERSION) return { status: 3 };
      // Current-version documents must match the complete schema. A field this
      // build does not understand is preserved, never silently overwritten.
      if (!this.hasOnlyKeys(parsed, ["version", "debug"])) return { status: 2 };
      if (parsed.version !== this.CURRENT_VERSION) return { status: 2 };

      var tileGrid = this.defaultTileGrid;
      var chunkBorders = this.defaultChunkBorders;
      if (this.hasOwn(parsed, "debug")) {
        var debug = parsed.debug;
        if (!debug || typeof debug !== "object" || Array.isArray(debug)) return { status: 2 };
        if (!this.hasOnlyKeys(debug, ["tile_grid", "chunk_borders"])) return { status: 2 };
        if (this.hasOwn(debug, "tile_grid")) {
          if (typeof debug.tile_grid !== "boolean") return { status: 2 };
          tileGrid = debug.tile_grid;
        }
        if (this.hasOwn(debug, "chunk_borders")) {
          if (typeof debug.chunk_borders !== "boolean") return { status: 2 };
          chunkBorders = debug.chunk_borders;
        }
      }
      return { status: 0, tileGrid: tileGrid, chunkBorders: chunkBorders };
    },

    loadConfig: function () {
      var self = this;
      return this.openDb().then(function (db) {
        return self.idbGet(db, self.STORE_CONFIG, self.CONFIG_KEY).then(function (raw) {
          if (raw === undefined) {
            return { status: 0, tileGrid: self.defaultTileGrid, chunkBorders: self.defaultChunkBorders };
          }
          if (typeof raw !== "string") return { status: 2 };
          if (self.byteLength(raw) > self.MAX_CONFIG_BYTES) return { status: 2 };
          return self.parseConfig(raw);
        });
      });
    },

    finishLoad: function (result) {
      if (result.status === 2 || result.status === 3) {
        // Preserve the existing value and stop every automatic overwrite until
        // an explicit reset removes it.
        this.autosaveBlocked = true;
      } else if (result.status === 1) {
        // IndexedDB is unavailable; starting is safe, but writes would only
        // fail repeatedly.
        this.autosaveBlocked = true;
      }
      this.notifyDefaultOr(result);
    },

    notifyDefaultOr: function (result) {
      if (result.status === 0) {
        this.notify(0, result.tileGrid, result.chunkBorders);
      } else {
        this.notifyDefault(result.status);
      }
    },

    start: function (callback, defaultTileGrid, defaultChunkBorders) {
      if (this.started) return;
      this.started = true;
      this.ready = callback;
      this.defaultTileGrid = defaultTileGrid !== 0;
      this.defaultChunkBorders = defaultChunkBorders !== 0;

      var self = this;
      if (typeof navigator === "undefined" || !navigator.locks || typeof navigator.locks.request !== "function") {
        // The wallet gate also requires Web Locks. Failing closed here keeps
        // the one-tab invariant instead of silently allowing a second tab.
        this.notifyDefault(4);
        return;
      }

      navigator.locks.request(
        this.LOCK_NAME,
        { mode: "exclusive", ifAvailable: true },
        function (lock) {
          if (!lock) {
            self.notifyDefault(4);
            return Promise.resolve();
          }

          // Load while the lock is held, then keep the lock for the page
          // lifetime without blocking the frame loop.
          return self.loadConfig().then(
            function (result) { self.finishLoad(result); },
            function () { self.finishLoad({ status: 1 }); },
          ).then(function () {
            return new Promise(function (resolve) {
              // Resolving this promise would release the lock. Closing the tab
              // releases it automatically.
              self.holdLock = resolve;
            });
          });
        },
      ).catch(function () {
        self.notifyDefault(4);
      });
    },

    save: function (tileGrid, chunkBorders) {
      if (this.autosaveBlocked) return;

      var self = this;
      var payload;
      try {
        payload = JSON.stringify({
          version: this.CURRENT_VERSION,
          debug: {
            tile_grid: !!tileGrid,
            chunk_borders: !!chunkBorders,
          },
        });
      } catch (_) {
        return;
      }
      if (this.byteLength(payload) > this.MAX_CONFIG_BYTES) {
        this.autosaveBlocked = true;
        return;
      }

      this.saveQueue = this.saveQueue.then(function () {
        if (self.autosaveBlocked) return;
        return self.openDb().then(function (db) {
          return self.idbWrite(db, self.STORE_CONFIG, function (store) {
            store.put(payload, self.CONFIG_KEY);
          });
        });
      }).catch(function (err) {
        // Fire-and-forget: log, block further automatic writes, and let the
        // game continue with the in-memory settings.
        self.autosaveBlocked = true;
        try { console.error("haystack storage: settings save failed", err); } catch (_) {}
      });
    },

    reset: function () {
      var self = this;
      this.autosaveBlocked = false;
      this.saveQueue = this.saveQueue.then(function () {
        return self.openDb().then(function (db) {
          return self.idbWrite(db, self.STORE_CONFIG, function (store) {
            store.delete(self.CONFIG_KEY);
          });
        });
      }).catch(function (err) {
        self.autosaveBlocked = true;
        try { console.error("haystack storage: settings reset failed", err); } catch (_) {}
      });
    },

    // ── content store ────────────────────────────────────────────────────────

    queueContent: function (operation) {
      var run = function () {
        try {
          return operation().catch(function () { return { status: 5 }; });
        } catch (_) {
          return Promise.resolve({ status: 5 });
        }
      };
      var next = this.contentQueue.then(run, run);
      // Keep the queue alive after an unexpected rejection.
      this.contentQueue = next.then(function () {}, function () {});
      return next;
    },

    deliverWrite: function (callback, context, status) {
      try {
        {{{ makeDynCall('vii', 'callback') }}}(context | 0, status | 0);
      } catch (_) {}
    },

    deliverRead: function (callback, context, allocate, release, result) {
      var status = result.status;
      var pointer = 0;
      var length = 0;
      if (status === 0) {
        var bytes = result.bytes || new Uint8Array(0);
        length = bytes.length;
        if (length > this.MAX_RESULT_BYTES) {
          status = 3;
          length = 0;
        } else if (length > 0) {
          try { pointer = {{{ makeDynCall('ii', 'allocate') }}}(length) | 0; } catch (_) { pointer = 0; }
          if (!pointer) {
            status = 5;
            length = 0;
          } else {
            try {
              HEAPU8.set(bytes, pointer);
            } catch (_) {
              try { {{{ makeDynCall('vi', 'release') }}}(pointer); } catch (_) {}
              pointer = 0;
              length = 0;
              status = 5;
            }
          }
        }
      }
      try {
        {{{ makeDynCall('viiii', 'callback') }}}(context | 0, status | 0, pointer | 0, length | 0);
      } catch (_) {}
    },

    deliverList: function (callback, context, allocate, release, result) {
      var status = result.status;
      var keys = result.keys || [];
      var pointer = 0;
      var length = 0;
      var count = 0;
      if (status === 0 && keys.length > 0) {
        // Measure the newline-joined encoding before allocating anything.
        // Keys are ASCII, so their JS length is their byte length. This also
        // avoids building a joined string that could exceed the result limit.
        var total = keys.length - 1;
        for (var i = 0; i < keys.length; i++) total += keys[i].length;
        if (total > this.MAX_RESULT_BYTES) {
          status = 3;
        } else {
          var bytes = new Uint8Array(total);
          var offset = 0;
          for (var k = 0; k < keys.length; k++) {
            if (k > 0) bytes[offset++] = 0x0a;
            var key = keys[k];
            for (var j = 0; j < key.length; j++) bytes[offset++] = key.charCodeAt(j) & 0xff;
          }
          length = bytes.length;
          if (length > this.MAX_RESULT_BYTES) {
            status = 3;
            length = 0;
          } else {
            try { pointer = {{{ makeDynCall('ii', 'allocate') }}}(length) | 0; } catch (_) { pointer = 0; }
            if (!pointer) {
              status = 5;
              length = 0;
            } else {
              try {
                HEAPU8.set(bytes, pointer);
                count = keys.length;
              } catch (_) {
                try { {{{ makeDynCall('vi', 'release') }}}(pointer); } catch (_) {}
                pointer = 0;
                length = 0;
                status = 5;
              }
            }
          }
        }
      }
      try {
        {{{ makeDynCall('viiiii', 'callback') }}}(context | 0, status | 0, pointer | 0, length | 0, count | 0);
      } catch (_) {}
    },

    toBytes: function (value) {
      try {
        var limit = this.MAX_CONTENT_BYTES;
        if (typeof Blob !== "undefined" && value instanceof Blob) {
          if (value.size > limit) return Promise.resolve({ status: 3 });
          return value.arrayBuffer().then(function (buffer) {
            // Re-check after conversion in case the browser hands back an
            // unexpectedly different buffer; never hand an oversize copy on.
            if (buffer.byteLength > limit) return { status: 3 };
            return { status: 0, bytes: new Uint8Array(buffer) };
          }, function () { return { status: 5 }; });
        }
        if (typeof ArrayBuffer !== "undefined" && value instanceof ArrayBuffer) {
          // Check before `slice`, which would otherwise allocate a full copy.
          if (value.byteLength > limit) return Promise.resolve({ status: 3 });
          return Promise.resolve({ status: 0, bytes: new Uint8Array(value.slice(0)) });
        }
        if (typeof ArrayBuffer !== "undefined" && ArrayBuffer.isView && ArrayBuffer.isView(value)) {
          // Check the view span before the slicing copy below.
          if (value.byteLength > limit) return Promise.resolve({ status: 3 });
          return Promise.resolve({
            status: 0,
            bytes: new Uint8Array(value.buffer, value.byteOffset, value.byteLength).slice(),
          });
        }
      } catch (_) {}
      return Promise.resolve({ status: 5 });
    },

    contentWrite: function (keyPointer, keyLength, dataPointer, dataLength, callback, context) {
      var self = this;
      var key = this.decodeKey(keyPointer, keyLength);
      var status = 0;
      var bytes = null;
      if (!key) {
        status = 2;
      } else {
        var size = dataLength >>> 0;
        if (dataLength < 0 || size !== dataLength) {
          status = 5;
        } else if (size > this.MAX_CONTENT_BYTES) {
          status = 3;
        } else if (dataPointer < 0 || dataPointer + size > HEAPU8.length) {
          status = 5;
        } else {
          try { bytes = HEAPU8.slice(dataPointer, dataPointer + size); } catch (_) { status = 5; }
        }
      }

      if (status !== 0) {
        this.queueContent(function () { return Promise.resolve({ status: status }); })
          .then(function (result) { self.deliverWrite(callback, context, result.status); });
        return;
      }

      this.queueContent(function () {
        return self.openDb().then(function (db) {
          return self.idbWrite(db, self.STORE_CONTENT, function (store) {
            store.put(bytes, key);
          }).then(function () {
            return { status: 0 };
          }, function () {
            return { status: 5 };
          });
        }, function () {
          return { status: 4 };
        });
      }).then(function (result) { self.deliverWrite(callback, context, result.status); });
    },

    contentRead: function (keyPointer, keyLength, callback, context, allocate, release) {
      var self = this;
      var key = this.decodeKey(keyPointer, keyLength);
      if (!key) {
        this.queueContent(function () { return Promise.resolve({ status: 2 }); })
          .then(function (result) { self.deliverRead(callback, context, allocate, release, result); });
        return;
      }

      this.queueContent(function () {
        return self.openDb().then(function (db) {
          return self.idbGet(db, self.STORE_CONTENT, key).then(function (value) {
            if (value === undefined) return { status: 1 };
            return self.toBytes(value).then(function (converted) {
              if (converted.status !== 0) return { status: converted.status };
              var bytes = converted.bytes;
              if (bytes.length > self.MAX_CONTENT_BYTES) return { status: 3 };
              return { status: 0, bytes: bytes };
            });
          }, function () {
            return { status: 5 };
          });
        }, function () {
          return { status: 4 };
        });
      }).then(function (result) { self.deliverRead(callback, context, allocate, release, result); });
    },

    contentList: function (callback, context, allocate, release) {
      var self = this;
      this.queueContent(function () {
        return self.openDb().then(function (db) {
          return self.idbGetAllKeys(db, self.STORE_CONTENT).then(function (keys) {
            var result = [];
            var total = 0;
            for (var i = 0; i < keys.length; i++) {
              if (!self.validKey(keys[i])) continue;
              // Account for the single `\n` separator before accepting the
              // key, so the eventual joined result never exceeds the limit.
              total += keys[i].length + (result.length > 0 ? 1 : 0);
              if (total > self.MAX_RESULT_BYTES) return { status: 3 };
              result.push(keys[i]);
            }
            result.sort();
            return { status: 0, keys: result };
          }, function () {
            return { status: 5 };
          });
        }, function () {
          return { status: 4 };
        });
      }).then(function (result) { self.deliverList(callback, context, allocate, release, result); });
    },

    contentDelete: function (keyPointer, keyLength, callback, context) {
      var self = this;
      var key = this.decodeKey(keyPointer, keyLength);
      if (!key) {
        this.queueContent(function () { return Promise.resolve({ status: 2 }); })
          .then(function (result) { self.deliverWrite(callback, context, result.status); });
        return;
      }

      this.queueContent(function () {
        return self.openDb().then(function (db) {
          return self.idbDelete(db, self.STORE_CONTENT, key).then(function (found) {
            return { status: found ? 0 : 1 };
          }, function () {
            return { status: 5 };
          });
        }, function () {
          return { status: 4 };
        });
      }).then(function (result) { self.deliverWrite(callback, context, result.status); });
    },
  },

  haystack_storage_start__deps: ["$haystackStorage"],
  haystack_storage_start__sig: "viii",
  haystack_storage_start: function (callback, defaultTileGrid, defaultChunkBorders) {
    haystackStorage.start(callback, defaultTileGrid, defaultChunkBorders);
  },

  haystack_storage_save__deps: ["$haystackStorage"],
  haystack_storage_save__sig: "vii",
  haystack_storage_save: function (tileGrid, chunkBorders) {
    haystackStorage.save(tileGrid, chunkBorders);
  },

  haystack_storage_reset__deps: ["$haystackStorage"],
  haystack_storage_reset__sig: "v",
  haystack_storage_reset: function () {
    haystackStorage.reset();
  },

  haystack_content_write__deps: ["$haystackStorage"],
  haystack_content_write__sig: "viiiiii",
  haystack_content_write: function (keyPointer, keyLength, dataPointer, dataLength, callback, context) {
    haystackStorage.contentWrite(keyPointer, keyLength, dataPointer, dataLength, callback, context);
  },

  haystack_content_read__deps: ["$haystackStorage"],
  haystack_content_read__sig: "viiiiii",
  haystack_content_read: function (keyPointer, keyLength, callback, context, allocate, release) {
    haystackStorage.contentRead(keyPointer, keyLength, callback, context, allocate, release);
  },

  haystack_content_list__deps: ["$haystackStorage"],
  haystack_content_list__sig: "viiii",
  haystack_content_list: function (callback, context, allocate, release) {
    haystackStorage.contentList(callback, context, allocate, release);
  },

  haystack_content_delete__deps: ["$haystackStorage"],
  haystack_content_delete__sig: "viiii",
  haystack_content_delete: function (keyPointer, keyLength, callback, context) {
    haystackStorage.contentDelete(keyPointer, keyLength, callback, context);
  },
});
