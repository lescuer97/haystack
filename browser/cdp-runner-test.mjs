// Node-only harness for browser/cdp-runner.mjs. No Chromium required: a fake
// socket and a fake child process exercise request correlation, event
// dispatch, disconnect cleanup, bounded watchdogs, and profile removal.
import {EventEmitter} from 'node:events';
import {access, mkdir, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {strict as assert} from 'node:assert';
import {
  bounded, CdpConnection, discoverEndpoint, disposableRoot, launchBrowser, makeProfile,
  removeProfile, stopBrowser, watchdog,
} from './cdp-runner.mjs';

class FakeSocket {
  constructor() {
    this.readyState = 1;
    this.sent = [];
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;
  }
  send(payload) {
    this.sent.push(JSON.parse(payload));
  }
  close() {
    this.readyState = 3;
    this.onclose?.();
  }
  receive(message) {
    this.onmessage({data: JSON.stringify(message)});
  }
}

class FakeBrowser extends EventEmitter {
  constructor() {
    super();
    this.exitCode = null;
    this.signalCode = null;
    this.signals = [];
  }
  kill(signal) {
    this.signals.push(signal);
    // Simulate a wedged browser that only honours SIGKILL.
    if (signal === 'SIGKILL') {
      this.exitCode = 1;
      this.emit('exit', 1);
    }
    return true;
  }
}

const tests = [];
const test = (name, fn) => tests.push({name, fn});
const tick = () => new Promise(resolve => setTimeout(resolve, 0));

test('browser launch isolates macOS test profiles from the real keychain', async () => {
  const previous = process.env.CHROMIUM;
  process.env.CHROMIUM = '/usr/bin/true';
  try {
    const browser = launchBrowser('/test-profile', ['--test-flag']);
    assert.equal(browser.spawnargs.includes('--use-mock-keychain'), process.platform === 'darwin');
    assert.ok(browser.spawnargs.includes('--test-flag'));
    await new Promise(resolve => browser.once('close', resolve));
  } finally {
    if (previous === undefined) delete process.env.CHROMIUM;
    else process.env.CHROMIUM = previous;
  }
});

test('correlates out-of-order CDP responses with their requests', async () => {
  const socket = new FakeSocket();
  const connection = new CdpConnection(socket);
  const first = connection.send('Target.createTarget', {url:'a'}, 'session-1');
  const second = connection.send('Runtime.evaluate', {expression:'1'});
  assert.equal(socket.sent.length, 2);
  assert.equal(socket.sent[0].id, 1);
  assert.equal(socket.sent[0].sessionId, 'session-1');
  assert.equal(socket.sent[1].id, 2);
  assert.equal('sessionId' in socket.sent[1], false);
  socket.receive({id:2, result:{value:'second'}});
  socket.receive({id:1, result:{targetId:'first'}});
  assert.deepEqual(await first, {targetId:'first'});
  assert.deepEqual(await second, {value:'second'});
});

test('rejects protocol errors without leaking details into the message', async () => {
  const socket = new FakeSocket();
  const connection = new CdpConnection(socket);
  const request = connection.send('Page.navigate');
  socket.receive({id:socket.sent[0].id, error:{code:-32000, message:'secret detail'}});
  await assert.rejects(request, error => error.message === 'CDP command failed' && error.cdp.message === 'secret detail');
});

test('dispatches to multiple subscribers and honours unsubscribe', async () => {
  const socket = new FakeSocket();
  const connection = new CdpConnection(socket);
  const seen = [];
  const offA = connection.on('Runtime.bindingCalled', message => seen.push(`a:${message.sessionId}`));
  connection.on('Runtime.bindingCalled', message => seen.push(`b:${message.sessionId}`));
  socket.receive({method:'Runtime.bindingCalled', sessionId:'one', params:{name:'x'}});
  offA();
  socket.receive({method:'Runtime.bindingCalled', sessionId:'two', params:{name:'x'}});
  connection.on('Runtime.consoleAPICalled', () => seen.push('ignored'));
  assert.deepEqual(seen, ['a:one', 'b:one', 'b:two']);
});

test('once resolves per session and unsubscribes itself', async () => {
  const socket = new FakeSocket();
  const connection = new CdpConnection(socket);
  const loaded = connection.once('Page.loadEventFired', 'session-2');
  socket.receive({method:'Page.loadEventFired', sessionId:'session-1'});
  socket.receive({method:'Page.loadEventFired', sessionId:'session-2'});
  const message = await loaded;
  assert.equal(message.sessionId, 'session-2');
  // No listener remains after resolution.
  socket.receive({method:'Page.loadEventFired', sessionId:'session-2'});
  assert.equal(connection.isOpen, true);
});

test('disconnect rejects pending requests and notifies every close subscriber', async () => {
  const socket = new FakeSocket();
  const connection = new CdpConnection(socket);
  const pending = connection.send('Runtime.evaluate');
  const closed = [];
  connection.onClose(error => closed.push(error.message));
  connection.onClose(error => closed.push(error.message));
  socket.readyState = 3;
  socket.onclose();
  await assert.rejects(pending, /CDP connection closed/);
  assert.deepEqual(closed, ['CDP connection closed', 'CDP connection closed']);
  assert.equal(connection.isOpen, false);
  await assert.rejects(connection.send('Runtime.evaluate'), /CDP connection closed/);
  // A late error event must not double-reject or throw.
  socket.onerror(new Error('late'));
});

test('disconnect rejects once waits and stops late event dispatch', async () => {
  const socket = new FakeSocket();
  const connection = new CdpConnection(socket);
  const seen = [];
  connection.on('Page.loadEventFired', message => seen.push(message.sessionId));
  const loaded = connection.once('Page.loadEventFired', 'session-1');
  socket.readyState = 3;
  socket.onclose();
  await assert.rejects(loaded, /CDP connection closed/);
  socket.receive({method:'Page.loadEventFired', sessionId:'session-1'});
  socket.receive({id:1, result:{}});
  assert.deepEqual(seen, []);
  assert.equal(connection.isOpen, false);
});

test('abandoned once wait does not leak an unhandled rejection', async () => {
  const socket = new FakeSocket();
  const connection = new CdpConnection(socket);
  const unhandled = [];
  const listener = error => unhandled.push(error);
  process.on('unhandledRejection', listener);
  connection.once('Page.loadEventFired', 'session-1');
  const pending = connection.send('Runtime.evaluate');
  socket.readyState = 3;
  socket.onclose();
  await assert.rejects(pending, /CDP connection closed/);
  await new Promise(resolve => setTimeout(resolve, 25));
  process.off('unhandledRejection', listener);
  assert.deepEqual(unhandled, []);
});

test('explicit close settles waiters even when socket.close throws', async () => {
  const socket = new FakeSocket();
  // Neither notifies onclose nor succeeds: settlement must not depend on it.
  socket.close = () => { socket.readyState = 3; throw new Error('socket already closed'); };
  const connection = new CdpConnection(socket);
  const pending = connection.send('Runtime.evaluate');
  const loaded = connection.once('Page.loadEventFired', 'session-1');
  const closed = [];
  connection.onClose(error => closed.push(error.message));
  connection.close();
  await assert.rejects(pending, /CDP connection closed/);
  await assert.rejects(loaded, /CDP connection closed/);
  assert.deepEqual(closed, ['CDP connection closed']);
  assert.equal(connection.isOpen, false);
  // A later socket close event is a harmless no-op.
  socket.onclose();
  assert.deepEqual(closed, ['CDP connection closed']);
  await assert.rejects(connection.send('Runtime.evaluate'), /CDP connection closed/);
});

test('synchronous socket.send failure rejects the request and forgets it', async () => {
  const socket = new FakeSocket();
  socket.send = () => { throw new Error('socket is closed'); };
  const connection = new CdpConnection(socket);
  await assert.rejects(connection.send('Runtime.evaluate'), /socket is closed/);
  // Receiving a response for the failed id must be a harmless no-op.
  socket.receive({id:1, result:{}});
  assert.equal(connection.isOpen, true);
});

test('bounded times out and suppresses a losing rejection', async () => {
  const unhandled = [];
  const listener = error => unhandled.push(error);
  process.on('unhandledRejection', listener);
  let rejectLate;
  const late = new Promise((_, reject) => { rejectLate = reject; });
  await assert.rejects(bounded(late, 10, 'watchdog'), /watchdog timed out/);
  rejectLate(new Error('late failure'));
  await new Promise(resolve => setTimeout(resolve, 25));
  process.off('unhandledRejection', listener);
  assert.deepEqual(unhandled, []);
});

test('watchdog rejects with its label and stop cancels an unreached timeout', async () => {
  const running = watchdog(10, 'run');
  await assert.rejects(running.promise, /run timed out/);
  const stopped = watchdog(10, 'stopped');
  stopped.stop();
  await new Promise(resolve => setTimeout(resolve, 25));
});

test('stopBrowser escalates from SIGTERM to SIGKILL within bounds', async () => {
  const browser = new FakeBrowser();
  const stopped = await stopBrowser(browser, {exitTimeout:20});
  assert.equal(stopped, true);
  assert.deepEqual(browser.signals, ['SIGTERM', 'SIGKILL']);
});

test('stopBrowser returns immediately for an exited browser', async () => {
  const browser = new FakeBrowser();
  browser.exitCode = 0;
  assert.equal(await stopBrowser(browser, {exitTimeout:20}), true);
});

test('discoverEndpoint resolves the reported DevTools URL', async () => {
  const browser = new EventEmitter();
  browser.stderr = new EventEmitter();
  const endpoint = discoverEndpoint(browser);
  browser.stderr.emit('data', 'noise\n');
  browser.stderr.emit('data', 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n');
  assert.equal(await endpoint, 'ws://127.0.0.1:9222/devtools/browser/abc');
  assert.equal(browser.listenerCount('exit'), 0);
});

test('profiles live under the preferred scratch root and are removed', async () => {
  const directory = await makeProfile('cdp-runner-test-');
  assert.equal(directory.startsWith(disposableRoot()), true);
  await mkdir(join(directory, 'nested'));
  await writeFile(join(directory, 'nested', 'file'), 'x');
  await removeProfile(directory);
  await assert.rejects(access(directory));
  // force:true keeps repeated cleanup idempotent.
  await removeProfile(directory);
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
  await tick();
}

if (failed !== 0) {
  console.error(`${failed} CDP runner test(s) failed`);
  process.exitCode = 1;
} else {
  console.log(`${tests.length} CDP runner tests passed`);
}
