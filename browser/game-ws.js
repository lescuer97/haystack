// Browser-only transport. Zig owns the wire protocol and gameplay state.
mergeInto(LibraryManager.library, {
  $haystackWs__deps: ['$haystackOnboarding', 'malloc', 'free'],
  $haystackWs: {
    socket: null,
    signer: null,
    listening: false,
    // Keep these tags aligned with Event in src/browser_ws.zig.
    event: {prepared: 1, opened: 2, message: 3, closed: 4, proof: 5, walletError: 6},
    // Match max_channel_open_with_params_bytes and max_channel_status_reply_bytes.
    maxOutboundBytes: 7232,
    maxInboundBytes: 61483,
    emit: function (callback, token, kind, bytes) {
      var ptr = 0, len = bytes ? bytes.length : 0;
      try {
        if (len) {
          ptr = _malloc(len);
          if (!ptr) { kind = this.event.closed; len = 0; }
          else HEAPU8.set(bytes, ptr);
        }
        {{{ makeDynCall('viiii', 'callback') }}}(token, kind, ptr, len);
      } finally { if (ptr) _free(ptr); }
    },
    prepare: function (token, generation, callback) {
      var self = this, wallet = haystackOnboarding.session;
      if (!self.listening) {
        self.listening = true;
        window.addEventListener('pagehide', function () {
          var s = self.socket;
          if (s) self.end(s);
          self.clearSigner();
        });
      }
      if (!wallet || wallet.closing || wallet.generation !== generation || !wallet.service) {
        queueMicrotask(function () { self.emit(callback, token, self.event.walletError); });
        return;
      }
      var h = self.signer;
      if (!h || h.wallet !== wallet) {
        self.clearSigner();
        h = { wallet: wallet, value: null, waiting: null };
        self.signer = h;
        wallet.chain = wallet.chain.then(async function () {
          if (self.signer !== h || wallet.closing) return;
          var signer = null;
          try { signer = await wallet.service.open_game_signer(); } catch (_) {}
          if (self.signer !== h || wallet.closing) {
            if (signer) signer.free();
            return;
          }
          h.value = signer;
          var waiting = h.waiting;
          h.waiting = null;
          if (!signer) self.signer = null;
          if (waiting) self.emit(waiting.callback, waiting.token, signer ? self.event.prepared : self.event.walletError);
        }).catch(function () {});
      }
      if (h.value) queueMicrotask(function () {
        if (self.signer === h) self.emit(callback, token, self.event.prepared);
      });
      else h.waiting = { callback: callback, token: token };
    },
    clearSigner: function () {
      var h = this.signer;
      this.signer = null;
      if (h && h.value) h.value.free();
    },
    open: function (token, callback) {
      var self = this, ws;
      try { ws = new WebSocket('ws://127.0.0.1:9224/'); }
      catch (_) { queueMicrotask(function () { self.emit(callback, token, self.event.closed); }); return; }
      var s = { token: token, callback: callback, ws: ws };
      self.socket = s;
      ws.binaryType = 'arraybuffer';
      ws.onopen = function () { if (self.socket === s) self.emit(callback, token, self.event.opened); };
      ws.onmessage = function (event) {
        if (self.socket !== s) return;
        if (!(event.data instanceof ArrayBuffer) || event.data.byteLength > self.maxInboundBytes) { self.end(s); return; }
        self.emit(callback, token, self.event.message, new Uint8Array(event.data));
      };
      ws.onclose = ws.onerror = function () { if (self.socket === s) self.end(s); };
    },
    end: function (s) {
      this.close(s.token);
      this.emit(s.callback, s.token, this.event.closed);
    },
    close: function (token) {
      var h = this.signer;
      if (h && h.waiting && h.waiting.token === token) h.waiting = null;
      var s = this.socket;
      if (!s || s.token !== token) return;
      this.socket = null;
      s.ws.onopen = s.ws.onmessage = s.ws.onclose = s.ws.onerror = null;
      try { s.ws.close(); } catch (_) {}
    },
    send: function (token, ptr, len) {
      var s = this.socket;
      if (!s || s.token !== token || s.ws.readyState !== WebSocket.OPEN ||
          ptr < 0 || len <= 0 || len > this.maxOutboundBytes || ptr + len > HEAPU8.length ||
          s.ws.bufferedAmount + len > this.maxOutboundBytes) return 0;
      try { s.ws.send(HEAPU8.subarray(ptr, ptr + len)); return 1; } catch (_) { return 0; }
    },
    sign: function (token, ptr) {
      var self = this, s = self.socket, h = self.signer;
      if (!s || s.token !== token || ptr < 0 || ptr + 32 > HEAPU8.length) return;
      var nonce = HEAPU8.slice(ptr, ptr + 32);
      queueMicrotask(function () {
        if (self.socket !== s || self.signer !== h) return;
        var proof, aux = new Uint8Array(32);
        try {
          crypto.getRandomValues(aux);
          proof = h.value.sign(nonce, aux);
        } catch (_) {} finally { aux.fill(0); }
        if (proof instanceof Uint8Array && proof.length === 97) self.emit(s.callback, token, self.event.proof, proof);
        else self.emit(s.callback, token, self.event.walletError);
      });
    },
  },
  haystack_ws_prepare__deps: ['$haystackWs'],
  haystack_ws_prepare__sig: 'viii',
  haystack_ws_prepare: function (token, generation, callback) { haystackWs.prepare(token, generation, callback); },
  haystack_ws_open__deps: ['$haystackWs'],
  haystack_ws_open__sig: 'vii',
  haystack_ws_open: function (token, callback) { haystackWs.open(token, callback); },
  haystack_ws_close__deps: ['$haystackWs'],
  haystack_ws_close__sig: 'vi',
  haystack_ws_close: function (token) { haystackWs.close(token); },
  haystack_ws_clear_signer__deps: ['$haystackWs'],
  haystack_ws_clear_signer__sig: 'v',
  haystack_ws_clear_signer: function () { haystackWs.clearSigner(); },
  haystack_ws_send__deps: ['$haystackWs'],
  haystack_ws_send__sig: 'iiii',
  haystack_ws_send: function (token, ptr, len) { return haystackWs.send(token, ptr, len); },
  haystack_ws_sign__deps: ['$haystackWs'],
  haystack_ws_sign__sig: 'vii',
  haystack_ws_sign: function (token, ptr) { haystackWs.sign(token, ptr); },
  haystack_ws_now__sig: 'd',
  haystack_ws_now: function () { return performance.now() / 1000; },
});
