// Emscripten JS library: disposable wallet gate for the in-game browser
// renderer.
//
// The renderer Zig code calls two tiny C functions:
//   * `haystack_wallet_smoke_start(callback)` starts one async task and returns
//     at once. `callback` is a wasm function pointer invoked exactly once with
//     1 on success or 0 on failure. The game context and main loop are only
//     created by the Zig side after a 1.
//   * `haystack_ui_result(ok)` hides or replaces the shell's startup layer.
//
// The task imports the real browser wallet adapter relative to this renderer
// (`../wallet/cdk_wallet_browser.js`), generates a fresh mnemonic, derives a
// 64-byte seed, explicitly provisions a unique disposable wallet pair in the
// dedicated `haystack-wallet` IndexedDB database, opens it, verifies it is
// empty, then closes/frees it and deletes only the records this task created.
// The deletion is verified before startup can succeed. No mint, network, prompt,
// secret log, or secret global is involved. This gate never creates or touches
// the persistent user wallet. Every rejection is caught and becomes a generic
// failure, never a raw error.

mergeInto(LibraryManager.library, {
  $haystackWalletSmoke: {
    started: false,
    finished: false,
    ready: 0,
    database: "haystack-wallet",
    mnemonicStore: "mnemonics",
    stateStore: "states",
    namePrefix: "game-smoke-",
    connection: null,

    notifyReady: function (ok) {
      if (!this.ready) return;
      // Emscripten rewrites this macro to a wasm-table lookup, so the callback
      // pointer captured at startup is invoked from this async continuation
      // without Asyncify or a blocking call.
      {{{ makeDynCall('vi', 'haystackWalletSmoke.ready') }}}(ok ? 1 : 0);
    },

    finish: function (ok) {
      if (this.finished) return;
      this.finished = true;
      // The continuation is single-shot on both sides. A failure passes 0 so
      // Zig records the generic failure and never builds a game context.
      this.notifyReady(ok);
    },

    uuid: function () {
      if (typeof crypto === "undefined" || !crypto) throw new Error("wallet smoke unavailable");
      if (typeof crypto.randomUUID === "function") {
        return crypto.randomUUID().replace(/-/g, "");
      }
      var bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      var out = "";
      for (var i = 0; i < bytes.length; i++) out += bytes[i].toString(16).padStart(2, "0");
      return out;
    },

    callPure: function (mod, operation, args) {
      if (!mod || typeof mod.call_pure !== "function") throw new Error("wallet smoke unavailable");
      var parsed = JSON.parse(mod.call_pure(operation, JSON.stringify(args)));
      if (!parsed || parsed.status !== 0) throw new Error("wallet smoke failed");
      return parsed;
    },

    openDatabase: function () {
      var self = this;
      if (self.connection) return self.connection;
      if (typeof indexedDB === "undefined" || !indexedDB) throw new Error("wallet smoke unavailable");
      self.connection = new Promise(function (resolve, reject) {
        var request;
        try {
          request = indexedDB.open(self.database, 1);
        } catch (_) {
          reject(new Error("wallet smoke unavailable"));
          return;
        }
        request.onupgradeneeded = function () {
          var database = request.result;
          if (!database.objectStoreNames.contains(self.mnemonicStore)) database.createObjectStore(self.mnemonicStore);
          if (!database.objectStoreNames.contains(self.stateStore)) database.createObjectStore(self.stateStore);
        };
        request.onsuccess = function () { resolve(request.result); };
        request.onerror = function () { reject(new Error("wallet smoke failed")); };
        request.onblocked = function () { reject(new Error("wallet smoke failed")); };
      });
      return self.connection;
    },

    readPair: async function (name) {
      var self = this;
      var database = await self.openDatabase();
      return new Promise(function (resolve, reject) {
        var transaction;
        try {
          transaction = database.transaction([self.mnemonicStore, self.stateStore], "readonly");
        } catch (_) {
          reject(new Error("wallet smoke failed"));
          return;
        }
        var mnemonic = transaction.objectStore(self.mnemonicStore).get(name);
        var state = transaction.objectStore(self.stateStore).get(name);
        transaction.oncomplete = function () {
          resolve({ mnemonic: mnemonic.result, state: state.result });
        };
        transaction.onabort = function () { reject(new Error("wallet smoke failed")); };
        transaction.onerror = function () {};
      });
    },

    // Deletes exactly this disposable wallet's two records, then verifies that
    // both are gone. Never deletes the database, clears a store, or touches any
    // other wallet or the game's `haystack-game` database.
    deletePair: async function (name) {
      var self = this;
      var database = await self.openDatabase();
      await new Promise(function (resolve, reject) {
        var transaction;
        try {
          transaction = database.transaction([self.mnemonicStore, self.stateStore], "readwrite");
        } catch (_) {
          reject(new Error("wallet smoke failed"));
          return;
        }
        transaction.objectStore(self.mnemonicStore).delete(name);
        transaction.objectStore(self.stateStore).delete(name);
        transaction.oncomplete = resolve;
        transaction.onabort = function () { reject(new Error("wallet smoke failed")); };
        transaction.onerror = function () {};
      });
      var pair = await self.readPair(name);
      if (pair.mnemonic !== undefined || pair.state !== undefined) throw new Error("wallet smoke failed");
    },

    run: async function (mod) {
      var name = this.namePrefix + this.uuid();
      var ownsPair = false;
      var failed = false;
      var wallet = null;
      var generated = null;
      var derived = null;
      var seed = null;
      var mnemonic = null;
      var hex = null;

      try {
        // Never overwrite or later delete a wallet that already exists.
        var existing = await this.readPair(name);
        if (existing.mnemonic !== undefined || existing.state !== undefined) throw new Error("wallet smoke failed");

        generated = this.callPure(mod, "generate_mnemonic", []);
        if (typeof generated.value !== "string" || generated.value.length === 0) throw new Error("wallet smoke failed");
        mnemonic = generated.value;
        // Drop the payload object field and reference as soon as it is copied.
        generated.value = null;
        generated = null;

        derived = this.callPure(mod, "mnemonic_to_seed", [mnemonic]);
        if (typeof derived.hex !== "string" || !/^[0-9a-fA-F]{128}$/.test(derived.hex)) throw new Error("wallet smoke failed");
        hex = derived.hex;
        // Drop the payload object field and reference before the seed copy.
        derived.hex = null;
        derived = null;
        seed = Uint8Array.from(hex.match(/../g), function (byte) { return parseInt(byte, 16); });
        hex = null;
        if (!seed || seed.length !== 64) throw new Error("wallet smoke failed");

        if (typeof mod.provision_wallet !== "function") throw new Error("wallet smoke unavailable");
        await mod.provision_wallet(mnemonic, name);
        // Provisioning committed both records atomically; only now does cleanup
        // own this pair.
        ownsPair = true;
        // The phrase is no longer needed once the pair is provisioned.
        mnemonic = null;

        try {
          wallet = await mod.open_wallet(seed, name);
        } finally {
          // open_wallet has copied the seed or rejected; do not keep the JS
          // copy alive while the wallet is listed or closed.
          if (seed) {
            seed.fill(0);
            seed = null;
          }
        }
        if (!wallet || typeof wallet.startup_reports !== "function") throw new Error("wallet smoke failed");

        var reports = JSON.parse(wallet.startup_reports());
        if (!Array.isArray(reports) || reports.length !== 0) throw new Error("wallet smoke failed");

        var balances = JSON.parse(await wallet.call("list_balances", "[]"));
        if (!balances || balances.status !== 0 || !Array.isArray(balances.balances) || balances.balances.length !== 0) {
          throw new Error("wallet smoke failed");
        }
      } catch (_) {
        failed = true;
      } finally {
        if (wallet) {
          var opened = wallet;
          wallet = null;
          try {
            await opened.close();
          } catch (_) {
            failed = true;
          }
          try {
            opened.free();
          } catch (_) {
            failed = true;
          }
        }
        if (ownsPair) {
          try {
            await this.deletePair(name);
          } catch (_) {
            failed = true;
          }
        }
        // Failure-path scrubbing for any reference the normal path did not drop.
        if (seed) {
          seed.fill(0);
          seed = null;
        }
        if (generated) {
          generated.value = null;
          generated = null;
        }
        if (derived) {
          derived.hex = null;
          derived = null;
        }
        mnemonic = null;
        hex = null;
      }

      if (failed) throw new Error("wallet smoke failed");
    },

    start: function (callback) {
      if (this.started) return;
      this.started = true;
      this.ready = callback | 0;

      var self = this;
      var walletModule = null;
      Promise.resolve()
        .then(function () {
          return self.resolveModule();
        })
        .then(function (mod) {
          walletModule = mod;
          if (!mod || typeof mod.default !== "function") throw new Error("wallet smoke unavailable");
          return mod.default();
        })
        .then(function () {
          return self.run(walletModule);
        })
        .then(function () {
          self.finish(true);
        }, function () {
          self.finish(false);
        });
    },

    resolveModule: function () {
      if (typeof scriptDirectory !== "string" || scriptDirectory.length === 0) {
        throw new Error("wallet smoke unavailable");
      }
      return import(new URL("../wallet/cdk_wallet_browser.js", scriptDirectory).href);
    },
  },

  haystack_wallet_smoke_start__deps: ["$haystackWalletSmoke"],
  haystack_wallet_smoke_start__sig: "vi",
  haystack_wallet_smoke_start: function (callback) {
    haystackWalletSmoke.start(callback);
  },

  haystack_ui_result__sig: "vi",
  haystack_ui_result: function (ok) {
    try {
      if (typeof Module !== "undefined" && typeof Module["onHaystackStartup"] === "function") {
        Module["onHaystackStartup"](ok ? "ready" : "error");
      }
    } catch (_) {
      // The startup layer is cosmetic; the game must not depend on it.
    }
  },
});
