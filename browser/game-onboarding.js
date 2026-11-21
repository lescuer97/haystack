// Asynchronous, bounded transport; no borrowed Wasm memory survives a turn.
mergeInto(LibraryManager.library, {
  $haystackOnboarding: {
    session: null,
    input: null,
    unbindInput: function () {
      var b = this.input;
      this.input = null;
      if (!b) return;
      b.canvas.removeEventListener('pointerdown', b.pointer);
      b.canvas.removeEventListener('keydown', b.key);
      b.canvas.removeEventListener('paste', b.paste);
    },
    bindInput: function (probe, paste, success) {
      this.unbindInput();
      var self = this, canvas = document.getElementById('canvas');
      if (!canvas) return;
      var b = { canvas: canvas };
      self.input = b;
      function check(kind, x, y) {
        var ptr = 0, code = 0, text = '';
        try {
          ptr = _malloc(4097);
          if (!ptr || ptr < 0 || ptr + 4097 > HEAPU8.length) return null;
          HEAPU8.fill(0, ptr, ptr + 4097);
          code = {{{ makeDynCall('iiiiii', 'probe') }}}(kind, x, y, ptr, 4097);
          if ((code >= 1 && code <= 13) || code === 15) {
            var end = ptr;
            while (end < ptr + 4097 && HEAPU8[end]) end++;
            if (end === ptr) return null;
            text = new TextDecoder('utf-8', { fatal: true }).decode(HEAPU8.subarray(ptr, end));
          }
          return { code: code, text: text };
        } catch (_) { return null; }
        finally {
          if (ptr && ptr >= 0 && ptr + 4097 <= HEAPU8.length) HEAPU8.fill(0, ptr, ptr + 4097);
          if (ptr) _free(ptr);
        }
      }
      function deliver(text, code) {
        var bytes, ptr = 0;
        try {
          if (typeof text !== 'string' || text.indexOf('\0') !== -1) return false;
          bytes = new TextEncoder().encode(text);
          if (bytes.length > (code === 16 ? 4096 : 1024)) return false;
          // Read-side focus is checked again after asynchronous clipboard reads.
          var current = check(2, 0, 0);
          if (!current || current.code !== code) return false;
          if (bytes.length) {
            ptr = _malloc(bytes.length);
            if (!ptr || ptr < 0 || ptr + bytes.length > HEAPU8.length) return false;
            HEAPU8.set(bytes, ptr);
          }
          {{{ makeDynCall('vii', 'paste') }}}(ptr, bytes.length);
          return true;
        } catch (_) { return false; }
        finally {
          if (ptr && bytes && ptr >= 0 && ptr + bytes.length <= HEAPU8.length) HEAPU8.fill(0, ptr, ptr + bytes.length);
          if (bytes) bytes.fill(0);
          if (ptr) _free(ptr);
        }
      }
      function activate(result) {
        if (!result) return;
        try {
          if (((result.code >= 1 && result.code <= 13) || result.code === 15) && navigator.clipboard && navigator.clipboard.writeText) {
            var promise = navigator.clipboard.writeText(result.text);
            Promise.resolve(promise).then(function () {
              if (self.input === b) {{{ makeDynCall('vi', 'success') }}}(result.code);
            }, function () {});
          } else if ((result.code === 14 || result.code === 16) && navigator.clipboard && navigator.clipboard.readText) {
            Promise.resolve(navigator.clipboard.readText()).then(function (text) {
              if (self.input === b) deliver(text, result.code);
            }, function () {});
          }
        } catch (_) {}
      }
      b.pointer = function (event) {
        if (!event.isTrusted || event.button !== 0) return;
        var rect = canvas.getBoundingClientRect();
        if (!(rect.width > 0 && rect.height > 0)) return;
        var x = Math.floor((event.clientX - rect.left) / rect.width * 1000000);
        var y = Math.floor((event.clientY - rect.top) / rect.height * 1000000);
        if (x < 0 || x > 1000000 || y < 0 || y > 1000000) return;
        activate(check(0, x, y));
      };
      b.key = function (event) {
        if (!event.isTrusted || document.activeElement !== canvas || event.ctrlKey || event.metaKey || event.altKey) return;
        if (event.key === 'Enter' || event.key === ' ') activate(check(1, 0, 0));
      };
      b.paste = function (event) {
        if (!event.isTrusted || document.activeElement !== canvas || !event.clipboardData) return;
        var result = check(2, 0, 0);
        if (result && (result.code === 14 || result.code === 16) && deliver(event.clipboardData.getData('text/plain'), result.code)) event.preventDefault();
      };
      canvas.addEventListener('pointerdown', b.pointer);
      canvas.addEventListener('keydown', b.key);
      canvas.addEventListener('paste', b.paste);
    },
    resolveModule: function () {
      if (typeof scriptDirectory !== 'string' || !scriptDirectory) throw 0;
      return import(new URL('../wallet/cdk_wallet_browser.js', scriptDirectory).href);
    },
    deliver: function (callback, generation, token, text, startup, limit) {
      var bytes, ptr = 0, status = 0;
      try {
        if (typeof text !== 'string') throw 0;
        bytes = new TextEncoder().encode(text);
        if (bytes.length > (limit || 4096)) throw 0;
        if (bytes.length) {
          ptr = _malloc(bytes.length);
          if (!ptr) throw 0;
          HEAPU8.set(bytes, ptr);
        }
        status = 1;
      } catch (_) { bytes = null; }
      try {
        if (startup) {{{ makeDynCall('viiii', 'callback') }}}(status, generation, ptr, bytes ? bytes.length : 0);
        else {{{ makeDynCall('viiiii', 'callback') }}}(status, generation, token, ptr, bytes ? bytes.length : 0);
      } finally { if (ptr) _free(ptr); }
    },
    start: function (generation, callback) {
      var self = this;
      if (self.session) {
        Promise.resolve().then(function () { self.deliver(callback, generation, 0, null, true); });
        return;
      }
      var s = { generation: generation, closing: false, service: null, wallet: null, mint: null, chain: null };
      self.session = s;
      s.chain = Promise.resolve().then(async function () {
        var result = null;
        try {
          var mod = await self.resolveModule();
          await mod.default();
          s.mint = mod.onboarding_mint();
          s.service = await mod.start_onboarding(s.mint);
          result = await s.service.request('inspect', '{}');
        } catch (error) {
          if (error === 'mint-keyset-check-failed') result = '{"event":"mint_unavailable"}';
        }
        self.deliver(callback, generation, 0, result, true);
      }).catch(function () {});
    },
    request: function (generation, token, opPtr, opLen, argsPtr, argsLen, callback) {
      var self = this, s = self.session, op, args;
      try {
        if (!s || s.closing || s.generation !== generation || opLen > 32 || argsLen > 4096 ||
            opPtr < 0 || argsPtr < 0 || opPtr + opLen > HEAPU8.length || argsPtr + argsLen > HEAPU8.length) throw 0;
        var decoder = new TextDecoder('utf-8', { fatal: true });
        op = decoder.decode(HEAPU8.slice(opPtr, opPtr + opLen));
        args = decoder.decode(HEAPU8.slice(argsPtr, argsPtr + argsLen));
      } catch (_) {
        Promise.resolve().then(function () { self.deliver(callback, generation, token, null, false); });
        return;
      }
      s.chain = s.chain.then(async function () {
        var result = null;
        try { if (s.service) result = await s.service.request(op, args); } catch (_) {}
        self.deliver(callback, generation, token, result, false);
      }).catch(function () {});
    },
    close: function (generation) {
      var self = this, s = self.session;
      if (!s || s.generation !== generation || s.closing) return;
      s.closing = true;
      s.chain = s.chain.then(async function () {
        if (s.wallet) {
          try { await s.wallet.close(); } catch (_) {}
          try { s.wallet.free(); } catch (_) {}
          s.wallet = null;
        }
        if (s.service) {
          try { await s.service.close(); } catch (_) {}
          try { s.service.free(); } catch (_) {}
          s.service = null;
        }
        if (self.session === s) self.session = null;
      });
    },
    walletRequest: function (generation, serial, operation, ptr, len, callback) {
      var self = this, s = self.session, argument;
      try {
        if (!s || s.closing || s.generation !== generation || len > 4096 || ptr < 0 || ptr + len > HEAPU8.length) throw 0;
        argument = new TextDecoder('utf-8', { fatal: true }).decode(HEAPU8.slice(ptr, ptr + len));
      } catch (_) {
        Promise.resolve().then(function () { self.deliver(callback, generation, serial, null, false, 131072); });
        return;
      }
      s.chain = s.chain.then(async function () {
        var result = null;
        try {
          if (operation === 0) {
            if (s.wallet || !s.service) throw 0;
            // Separate call: request('inspect'/complete) has returned, dropping
            // its temporary user lock. Rust audits Ready and derives the seed.
            s.wallet = await s.service.open_ready_wallet();
          }
          if (!s.wallet) throw 0;
          if (operation === 2) {
            var added = JSON.parse(await s.wallet.call('add_mint', JSON.stringify([s.mint])));
            if (added.status !== 0) throw 0;
          }
          var op, args;
          switch (operation) {
            case 0: case 1: op = 'wallet_screen'; args = [s.mint]; break;
            case 2: op = 'create_deposit'; args = [s.mint, argument]; break;
            case 3: op = 'deposit_update'; args = [s.mint, 'check', argument]; break;
            case 4: op = 'quote_history_page'; args = [argument]; break;
            case 5: op = 'resume_deposit'; args = [s.mint]; break;
            case 6: op = 'deposit_update'; args = [s.mint, 'recover', '']; break;
            case 7: op = 'deposit_update'; args = [s.mint, 'poll', argument]; break;
            case 8: op = 'saved_invoice'; args = [s.mint, argument]; break;
            case 9: op = 'prepare_withdrawal'; args = [s.mint, argument]; break;
            case 10: op = 'confirm_withdrawal'; args = [s.mint, argument]; break;
            case 11: op = 'cancel_withdrawal'; args = [s.mint, argument]; break;
            case 12: op = 'saved_withdrawal'; args = [s.mint, argument]; break;
            case 13: op = 'poll_withdrawals'; args = [s.mint, argument]; break;
            default: throw 0;
          }
          var response = JSON.parse(await s.wallet.call(op, JSON.stringify(args)));
          if (response.status === 0 && typeof response.value === 'string') result = response.value;
          else if (operation >= 9 && operation <= 13 && Number.isInteger(response.status) && response.status >= 1 && response.status <= 27)
            result = JSON.stringify({operation_error:{status:response.status,message:'Withdrawal request failed'}});
        } catch (_) {}
        if (self.session === s && !s.closing) self.deliver(callback, generation, serial, result, false, 131072);
      }).catch(function () {});
    },
  },
  haystack_onboarding_start__deps: ['$haystackOnboarding', 'malloc', 'free'],
  haystack_onboarding_start__sig: 'vii',
  haystack_onboarding_start: function (generation, callback) { haystackOnboarding.start(generation, callback); },
  haystack_onboarding_request__deps: ['$haystackOnboarding', 'malloc', 'free'],
  haystack_onboarding_request__sig: 'viiiiiii',
  haystack_onboarding_request: function (generation, token, opPtr, opLen, argsPtr, argsLen, callback) {
    haystackOnboarding.request(generation, token, opPtr, opLen, argsPtr, argsLen, callback);
  },
  haystack_onboarding_close__deps: ['$haystackOnboarding'],
  haystack_onboarding_close__sig: 'vi',
  haystack_onboarding_close: function (generation) { haystackOnboarding.close(generation); },
  haystack_wallet_request__deps: ['$haystackOnboarding', 'malloc', 'free'],
  haystack_wallet_unix_time__sig: 'd',
  haystack_wallet_unix_time: function () { return Math.floor(Date.now() / 1000); },
  haystack_wallet_request__sig: 'viiiiii',
  haystack_wallet_request: function (generation, serial, operation, ptr, len, callback) {
    haystackOnboarding.walletRequest(generation, serial, operation, ptr, len, callback);
  },
  haystack_onboarding_bind_input__deps: ['$haystackOnboarding', 'malloc', 'free'],
  haystack_onboarding_bind_input__sig: 'viii',
  haystack_onboarding_bind_input: function (probe, paste, success) { haystackOnboarding.bindInput(probe, paste, success); },
  haystack_onboarding_unbind_input__deps: ['$haystackOnboarding'],
  haystack_onboarding_unbind_input__sig: 'v',
  haystack_onboarding_unbind_input: function () { haystackOnboarding.unbindInput(); },
});
