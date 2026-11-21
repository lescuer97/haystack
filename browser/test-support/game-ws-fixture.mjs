// Injected only by CDP UI tests. It keeps unrelated wallet tests isolated from
// a real game server while exercising the browser's binary/auth boundaries.
export const gameSocketFixture = `(${function () {
  const original = window.WebSocket;
  const state = window.gameSocketChecks = {
    connections: 0, ready: false, online: true, keys: [], moves: [], socket: null, rejectNext: false,
    disconnect() { this.online = false; this.socket?.close(); },
  };
  class Socket {
    static OPEN = 1;
    constructor(url, protocols) {
      if (url !== 'ws://127.0.0.1:9224/') return new original(url, protocols);
      this.readyState = 0;
      this.bufferedAmount = 0;
      state.socket = this;
      state.connections++;
      queueMicrotask(() => {
        if (this.readyState !== 0) return;
        if (!state.online) { this.close(); return; }
        this.readyState = Socket.OPEN;
        this.onopen?.();
        this.deliver(0xf0, [0x10, 32, 0, ...new Uint8Array(32).fill(state.connections & 255)]);
      });
    }
    deliver(tag, body) {
      const data = Uint8Array.of(tag, body.length, 0, ...body, 0x7e).buffer;
      queueMicrotask(() => { if (this.readyState === Socket.OPEN) this.onmessage?.({data}); });
    }
    send(data) {
      if (this.readyState !== Socket.OPEN) throw new Error('Closed test socket');
      const bytes = new Uint8Array(data);
      if (!this.authenticated && bytes[0] === 0xf1 && bytes.length === 107 &&
          (bytes[6] === 2 || bytes[6] === 3) && bytes.slice(42, 106).some(Boolean)) {
        this.authenticated = true;
        state.keys.push(Array.from(bytes.slice(6, 39)).join(','));
        this.deliver(0xf2, [3, 0, 0]);
        queueMicrotask(() => { if (this.readyState === Socket.OPEN) state.ready = true; });
        return;
      }
      if (this.authenticated && bytes[0] === 3 && bytes.length === 34) {
        const view = new DataView(bytes.buffer);
        state.moves.push([view.getInt32(25, true), view.getInt32(29, true)]);
        const outcome = state.rejectNext ? [4, 2, 0, 1, 0] : [3, 0, 0];
        state.rejectNext = false;
        this.deliver(0x83, [...bytes.slice(3, 22), ...outcome]);
        return;
      }
      this.close();
    }
    close() {
      this.readyState = 3;
      if (state.socket === this) { state.socket = null; state.ready = false; }
      queueMicrotask(() => this.onclose?.());
    }
  }
  window.WebSocket = Socket;
}.toString()})();`;
