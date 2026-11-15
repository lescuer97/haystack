// Shared Node-side lifecycle primitives for the Chromium/CDP browser runners.
//
// This module owns only resource concerns: disposable profiles, browser launch
// and shutdown, CDP request correlation and event dispatch, bounded watchdogs,
// and profile cleanup retries. Scenario logic, assertions, runtime counters and
// reporting stay in each runner. It is imported by the Node test runners only
// and is never bundled into the Wasm application.
import {spawn} from 'node:child_process';
import {existsSync} from 'node:fs';
import {mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const websocketOpen = 1;
const devtoolsEndpoint = /DevTools listening on (ws:\/\/[^\s]+)/;

// Keep heavy temporary profiles off tmpfs when the shared scratch exists.
export function disposableRoot() {
  return existsSync('/tmp/opencode') ? '/tmp/opencode' : tmpdir();
}

export async function makeProfile(prefix) {
  return await mkdtemp(join(disposableRoot(), prefix));
}

// `flags` carries per-runner switches such as wallet GL options.
export function launchBrowser(profile, flags = []) {
  const browser = spawn(process.env.CHROMIUM || 'chromium', [
    '--headless', '--no-sandbox', ...flags, `--user-data-dir=${profile}`,
    '--remote-debugging-port=0', 'about:blank',
  ], {stdio:['ignore', 'ignore', 'pipe']});
  // Discovery attaches its own bounded listeners; a later spawn error must not
  // crash the runner as an unhandled event.
  browser.on('error', () => {});
  return browser;
}

export function discoverEndpoint(browser) {
  return new Promise((resolve, reject) => {
    let stderr = '';
    const cleanup = () => {
      browser.stderr?.off('data', onData);
      browser.off('error', onError);
      browser.off('exit', onExit);
    };
    const onData = chunk => {
      stderr += chunk;
      const match = stderr.match(devtoolsEndpoint);
      if (match) { cleanup(); resolve(match[1]); }
    };
    const onError = error => { cleanup(); reject(error); };
    const onExit = () => { cleanup(); reject(new Error('browser exited')); };
    browser.stderr?.on('data', onData);
    browser.on('error', onError);
    browser.on('exit', onExit);
  });
}

// One CDP WebSocket. Pending requests are rejected on disconnect, protocol
// failure, and synchronous socket.send failures so no caller waits forever.
export class CdpConnection {
  #socket;
  #sequence = 0;
  #pending = new Map();
  #listeners = new Map();
  #closeListeners = new Set();
  #closed = null;

  static async connect(endpoint) {
    const socket = new WebSocket(endpoint);
    await new Promise((resolve, reject) => {
      socket.onopen = resolve;
      socket.onerror = () => reject(new Error('CDP connection failed'));
    });
    return new CdpConnection(socket);
  }

  constructor(socket) {
    this.#socket = socket;
    socket.onmessage = ({data}) => this.#receive(data);
    socket.onclose = () => this.#disconnect();
    socket.onerror = () => this.#disconnect();
  }

  get isOpen() {
    return this.#closed === null && this.#socket.readyState === websocketOpen;
  }

  send(method, params = {}, sessionId) {
    if (!this.isOpen) return Promise.reject(this.#closed ?? new Error('CDP connection closed'));
    const id = ++this.#sequence;
    return new Promise((resolve, reject) => {
      this.#pending.set(id, {resolve, reject});
      try {
        this.#socket.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}));
      } catch (error) {
        this.#pending.delete(id);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  // Multiple subscribers per method; returns an unsubscribe function.
  on(method, handler) {
    let handlers = this.#listeners.get(method);
    if (!handlers) this.#listeners.set(method, handlers = new Set());
    handlers.add(handler);
    return () => {
      handlers.delete(handler);
      if (handlers.size === 0 && this.#listeners.get(method) === handlers) this.#listeners.delete(method);
    };
  }

  once(method, sessionId) {
    let offEvent = () => {};
    let offClose = () => {};
    const cleanup = () => { offEvent(); offClose(); };
    const promise = new Promise((resolve, reject) => {
      offEvent = this.on(method, message => {
        if (sessionId !== undefined && message.sessionId !== sessionId) return;
        cleanup();
        resolve(message);
      });
      // A disconnect settles the wait as an error instead of hanging forever.
      offClose = this.onClose(error => {
        cleanup();
        reject(error);
      });
    });
    // An abandoned wait must not surface as an unhandled rejection when the
    // runner is awaiting a different CDP operation that rejects first.
    promise.catch(() => {});
    return promise;
  }

  onClose(handler) {
    if (this.#closed) {
      handler(this.#closed);
      return () => {};
    }
    this.#closeListeners.add(handler);
    return () => this.#closeListeners.delete(handler);
  }

  close() {
    // Settle pending requests and close listeners now; socket.close may be
    // asynchronous, never fire, or throw.
    this.#disconnect();
    try { this.#socket.close(); } catch {}
  }

  #receive(data) {
    if (this.#closed) return;
    let message;
    try { message = JSON.parse(data); } catch { return; }
    if (message.id) {
      const pending = this.#pending.get(message.id);
      if (!pending) return;
      this.#pending.delete(message.id);
      if (message.error) {
        // Keep details off the message string so runners can choose what to
        // surface; onboarding diagnostics stay label-only.
        const failure = new Error('CDP command failed');
        failure.cdp = message.error;
        pending.reject(failure);
      } else {
        pending.resolve(message.result);
      }
      return;
    }
    if (typeof message.method !== 'string') return;
    const handlers = this.#listeners.get(message.method);
    if (!handlers) return;
    for (const handler of [...handlers]) handler(message);
  }

  #disconnect() {
    if (this.#closed) return;
    this.#closed = new Error('CDP connection closed');
    for (const pending of this.#pending.values()) pending.reject(this.#closed);
    this.#pending.clear();
    for (const handler of [...this.#closeListeners]) handler(this.#closed);
    this.#closeListeners.clear();
    // Late protocol events are ignored and no subscriber outlives the socket.
    this.#listeners.clear();
  }
}

// Bound a promise and suppress a losing rejection when the timeout wins.
export function bounded(promise, milliseconds, label) {
  const guarded = Promise.resolve(promise);
  guarded.catch(() => {});
  let handle;
  return Promise.race([
    guarded,
    new Promise((_, reject) => { handle = setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds); }),
  ]).finally(() => clearTimeout(handle));
}

// Standalone watchdog for a whole run. `stop` cancels an unreached timeout.
export function watchdog(milliseconds, label) {
  let handle;
  const promise = new Promise((_, reject) => { handle = setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds); });
  promise.catch(() => {});
  return {promise, stop() { clearTimeout(handle); }};
}

// Bounded SIGTERM, then SIGKILL, so a wedged browser still releases its profile.
export async function stopBrowser(browser, {exitTimeout = 3000} = {}) {
  const waitExit = milliseconds => new Promise(resolve => {
    if (browser.exitCode !== null || browser.signalCode !== null) { resolve(true); return; }
    let handle;
    const onExit = () => { clearTimeout(handle); resolve(true); };
    browser.once('exit', onExit);
    handle = setTimeout(() => { browser.off('exit', onExit); resolve(false); }, milliseconds);
  });
  try { browser.kill('SIGTERM'); } catch {}
  if (await waitExit(exitTimeout)) return true;
  try { browser.kill('SIGKILL'); } catch {}
  return await waitExit(exitTimeout);
}

// fs.rm retries transient EBUSY/ENOTEMPTY/EPERM; the outer race bounds it.
export async function removeProfile(directory, {timeout = 5000} = {}) {
  const removal = rm(directory, {recursive:true, force:true, maxRetries:5, retryDelay:100});
  removal.catch(() => {});
  let handle;
  try {
    await Promise.race([
      removal,
      new Promise((_, reject) => { handle = setTimeout(() => reject(new Error('profile cleanup timed out')), timeout); }),
    ]);
  } finally {
    clearTimeout(handle);
  }
}
