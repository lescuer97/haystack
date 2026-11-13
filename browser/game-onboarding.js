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
          ptr = _malloc(1024);
          if (!ptr || ptr < 0 || ptr + 1024 > HEAPU8.length) return null;
          HEAPU8.fill(0, ptr, ptr + 1024);
          code = {{{ makeDynCall('iiiiii', 'probe') }}}(kind, x, y, ptr, 1024);
          if (code >= 1 && code <= 13) {
            var end = ptr;
            while (end < ptr + 1024 && HEAPU8[end]) end++;
            if (end === ptr) return null;
            text = new TextDecoder('utf-8', { fatal: true }).decode(HEAPU8.subarray(ptr, end));
          }
          return { code: code, text: text };
        } catch (_) { return null; }
        finally {
          if (ptr && ptr >= 0 && ptr + 1024 <= HEAPU8.length) HEAPU8.fill(0, ptr, ptr + 1024);
          if (ptr) _free(ptr);
        }
      }
      function deliver(text) {
        var bytes, ptr = 0;
        try {
          if (typeof text !== 'string' || text.indexOf('\0') !== -1) return false;
          bytes = new TextEncoder().encode(text);
          if (bytes.length > 1024) return false;
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
          if (result.code >= 1 && result.code <= 13 && navigator.clipboard && navigator.clipboard.writeText) {
            var promise = navigator.clipboard.writeText(result.text);
            Promise.resolve(promise).then(function () {
              if (self.input === b) {{{ makeDynCall('vi', 'success') }}}(result.code);
            }, function () {});
          } else if (result.code === 14 && navigator.clipboard && navigator.clipboard.readText) {
            Promise.resolve(navigator.clipboard.readText()).then(function (text) {
              if (self.input === b) deliver(text);
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
        if (result && result.code === 14 && deliver(event.clipboardData.getData('text/plain'))) event.preventDefault();
      };
      canvas.addEventListener('pointerdown', b.pointer);
      canvas.addEventListener('keydown', b.key);
      canvas.addEventListener('paste', b.paste);
    },
    resolveModule: function () {
      if (typeof scriptDirectory !== 'string' || !scriptDirectory) throw 0;
      return import(new URL('../wallet/cdk_wallet_browser.js', scriptDirectory).href);
    },
    deliver: function (callback, generation, token, text, startup) {
      var bytes, ptr = 0, status = 0;
      try {
        if (typeof text !== 'string') throw 0;
        bytes = new TextEncoder().encode(text);
        if (bytes.length > 4096) throw 0;
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
      var s = { generation: generation, closing: false, service: null, chain: null };
      self.session = s;
      s.chain = Promise.resolve().then(async function () {
        var result = null;
        try {
          var mod = await self.resolveModule();
          await mod.default();
          s.service = await mod.start_onboarding(mod.onboarding_mint());
          result = await s.service.request('inspect', '{}');
        } catch (_) {}
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
        if (s.service) {
          try { await s.service.close(); } catch (_) {}
          try { s.service.free(); } catch (_) {}
          s.service = null;
        }
        if (self.session === s) self.session = null;
      });
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
  haystack_onboarding_bind_input__deps: ['$haystackOnboarding', 'malloc', 'free'],
  haystack_onboarding_bind_input__sig: 'viii',
  haystack_onboarding_bind_input: function (probe, paste, success) { haystackOnboarding.bindInput(probe, paste, success); },
  haystack_onboarding_unbind_input__deps: ['$haystackOnboarding'],
  haystack_onboarding_unbind_input__sig: 'v',
  haystack_onboarding_unbind_input: function () { haystackOnboarding.unbindInput(); },
});
