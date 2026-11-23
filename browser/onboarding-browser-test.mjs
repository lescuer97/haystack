// Isolated CDP runner: all wallet data lives in disposable browser contexts.
import {gameSocketFixture} from './test-support/game-ws-fixture.mjs';
import {bounded, CdpConnection, discoverEndpoint, launchBrowser, makeProfile, removeProfile, stopBrowser, watchdog} from './cdp-runner.mjs';

const input = new URL(process.argv[2]);
if (input.protocol !== 'http:' || input.hostname !== '127.0.0.1' || !input.port) throw new Error('Expected local fake mint URL');
const fault = process.env.ONBOARDING_TEST_FAULT || '';
const selectedFlow = process.env.ONBOARDING_TEST_FLOW || 'all';
if (!['', 'drop-ready', 'drop-complete', 'backup-error', 'backup-rejection'].includes(fault) ||
    !['all', 'create', 'recovery'].includes(selectedFlow) || (fault && selectedFlow === 'all')) {
  throw new Error('Invalid onboarding test fault/flow selection');
}
const profile = await makeProfile('haystack-onboarding-');
const browser = launchBrowser(profile);
let connection;
const contexts = [];
const runtimeBinding = 'haystackTestRuntime';
// Node owns these counters: destroying a document must never erase its errors.
const runtimeReports = new Map();
let failureLabel = 'browser startup';
function send(method, params = {}, sessionId) {
  return connection.send(method, params, sessionId);
}
async function run() {
  const endpoint = await discoverEndpoint(browser);
  connection = await CdpConnection.connect(endpoint);
  connection.on('Runtime.bindingCalled', message => {
    if (message.params.name !== runtimeBinding) return;
    const report = runtimeReports.get(message.sessionId);
    if (!report) return;
    // Deliberately discard exception messages, values, stacks and URLs.
    switch (message.params.payload) {
      case 'error': report.errors++; break;
      case 'rejection': report.rejections++; break;
      case 'barrier': report.barriers++; break;
      case 'fault':
        if (!report.faultInjected) console.log(`Fault injected: ${fault} (${report.flow})`);
        report.faultInjected = true;
        break;
      default: report.monitorErrors++;
    }
  });
  // Fault runs isolate one actual-game flow; normal runs keep the Rust fixture.
  for (const flow of fault ? [] : ['create', 'restore']) {
    const {browserContextId} = await send('Target.createBrowserContext', {disposeOnDetach:true});
    contexts.push(browserContextId);
    const url = new URL('/onboarding-test.html', input.origin);
    url.searchParams.set('flow', flow);
    const {targetId} = await send('Target.createTarget', {url:url.href, browserContextId});
    const {sessionId} = await send('Target.attachToTarget', {targetId, flatten:true});
    let report;
    while (!report) {
      // Navigation/reload can temporarily leave the target without an execution context.
      try {
        const result = await send('Runtime.evaluate', {expression:'window.onboardingTestReport || null', returnByValue:true}, sessionId);
        report = result.result?.value;
      } catch (_) {
        if (!connection.isOpen) throw new Error('CDP closed');
      }
      if (!report) await new Promise(resolve => setTimeout(resolve, 200));
    }
    console.log(JSON.stringify({flow, ...report}));
    if (!report.ok) throw new Error('onboarding checks failed');
  }
  for (const flow of selectedFlow === 'all' ? ['create', 'recovery'] : [selectedFlow]) {
    await runGame(flow);
  }
  if (!fault && selectedFlow === 'all') {
    for (const mode of ['sat-only', 'inactive-msat']) await runGame(mode);
  }
  for (const [sessionId, report] of runtimeReports) {
    await flushRuntime(sessionId);
    assertRuntimeClean(sessionId, `${report.flow}: no uncaught runtime errors across reload`);
  }
}

function assertRuntimeClean(sessionId, label) {
  failureLabel = label;
  const report = runtimeReports.get(sessionId);
  if (!report || report.errors || report.rejections || report.monitorErrors) throw new Error('game runtime error');
}

async function flushRuntime(sessionId) {
  const report = runtimeReports.get(sessionId);
  const before = report.barriers;
  // Run a task after earlier error/rejection tasks. The binding notification is
  // a wire-order barrier: Node must receive it before this evaluation finishes.
  const result = await send('Runtime.evaluate', {
    expression:`new Promise(resolve => setTimeout(() => { window.${runtimeBinding}('barrier'); resolve(true); }, 0))`,
    awaitPromise:true, returnByValue:true,
  }, sessionId);
  if (result.exceptionDetails || report.barriers <= before) throw new Error('runtime monitoring unavailable');
}

async function prepareGame(sessionId, flow) {
  runtimeReports.set(sessionId, {flow, errors:0, rejections:0, barriers:0, monitorErrors:0, faultInjected:false});
  await send('Runtime.enable', {}, sessionId);
  // No executionContextId: the binding also exists in future/reloaded contexts.
  await send('Runtime.addBinding', {name:runtimeBinding}, sessionId);
  await send('Page.enable', {}, sessionId);
  await send('Emulation.setDeviceMetricsOverride', {width:1000, height:640, deviceScaleFactor:1, mobile:false}, sessionId);
  await send('Page.addScriptToEvaluateOnNewDocument', {source:gameSocketFixture + '\n' + gameInstrumentation}, sessionId);
  await send('Page.bringToFront', {}, sessionId);
}

// Exercise the actual renderer, Wasm callbacks and Zig frame mailbox. The Rust
// test page above intentionally bypasses all three. Keep only event/operation
// names: never retain backup payloads or send words to the system clipboard.
const gameInstrumentation = `(() => {
  window.gameOnboardingChecks = {events: [], operations: [], copies: 0};
  addEventListener('error', () => { window.${runtimeBinding}('error'); });
  addEventListener('unhandledrejection', () => { window.${runtimeBinding}('rejection'); });
  const fault = ${JSON.stringify(fault)};
  let injected = false;
  Object.defineProperty(navigator, 'clipboard', {value: {
    writeText: async () => { window.gameOnboardingChecks.copies++; }
  }});
  Object.defineProperty(window, 'haystackOnboarding', {
    configurable: true,
    get() { return this.__gameOnboardingBridge; },
    set(bridge) {
      this.__gameOnboardingBridge = bridge;
      const deliver = bridge.deliver, request = bridge.request;
      bridge.deliver = function(callback, generation, token, text, startup) {
        const event = typeof text === 'string' ? JSON.parse(text).event : 'transport_error';
        const allowed = ['choice', 'backup', 'ready', 'complete_success', 'blocked', 'invalid_phrase', 'transport_error', 'restore_failed', 'resume_failed', 'restore_finished', 'mint_unavailable'];
        window.gameOnboardingChecks.events.push(allowed.includes(event) ? event : 'other');
        const drop = (fault === 'drop-ready' && event === 'ready') || (fault === 'drop-complete' && event === 'complete_success');
        if (!injected && (drop || (event === 'backup' && (fault === 'backup-error' || fault === 'backup-rejection')))) {
          injected = true;
          window.${runtimeBinding}('fault');
          if (fault === 'backup-error') setTimeout(() => { throw new Error('Synthetic onboarding test error'); }, 0);
          if (fault === 'backup-rejection') setTimeout(() => { Promise.reject(new Error('Synthetic onboarding test rejection')); }, 0);
        }
        if (drop) return;
        return deliver.apply(this, arguments);
      };
      bridge.request = function(generation, token, opPtr, opLen) {
        const op = new TextDecoder().decode(HEAPU8.subarray(opPtr, opPtr + opLen));
        window.gameOnboardingChecks.operations.push(['create', 'restore', 'complete_backup', 'retry', 'generate'].includes(op) ? op : 'other');
        return request.apply(this, arguments);
      };
    }
  });
})();`;

// Only settings booleans leave the page. Read the actual committed record, not
// just the bridge's saveQueue (which catches write failures).
const gridSetting = `(async () => {
  const db = await new Promise((resolve, reject) => {
    const request = indexedDB.open('haystack-game');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(new Error('settings read failed'));
  });
  try {
    const raw = await new Promise((resolve, reject) => {
      const request = db.transaction('config', 'readonly').objectStore('config').get('settings');
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(new Error('settings read failed'));
    });
    if (raw === undefined) return {persisted:false, value:haystackStorage.defaultTileGrid};
    const value = JSON.parse(raw);
    if (value.version !== 1 || typeof value.debug?.tile_grid !== 'boolean') throw new Error('invalid game settings');
    return {persisted:true, value:value.debug.tile_grid};
  } finally { db.close(); }
})()`;

async function runGame(flow) {
  const checks = [];
  const {browserContextId} = await send('Target.createBrowserContext', {disposeOnDetach:true});
  contexts.push(browserContextId);
  const {targetId} = await send('Target.createTarget', {url:'about:blank', browserContextId});
  const {sessionId} = await send('Target.attachToTarget', {targetId, flatten:true});
  const evaluate = async expression => {
    const result = await send('Runtime.evaluate', {expression, returnByValue:true, awaitPromise:true}, sessionId);
    if (result.exceptionDetails) throw new Error('game evaluation failed');
    return result.result?.value;
  };
  const frames = () => evaluate('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve(true))))');
  // Display frames keep physical holds short; UI/mailboxes advance at 20 Hz.
  const settleTicks = () => evaluate(`new Promise(resolve => {
    const start = performance.now();
    function tick(now) { if (now - start >= 100) resolve(true); else requestAnimationFrame(tick); }
    requestAnimationFrame(tick);
  })`);
  async function expect(label, expression) {
    failureLabel = label;
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      try {
        if (await evaluate(expression)) { checks.push(label); return; }
      } catch (_) {
        // Reload temporarily destroys the old execution context.
        if (!connection.isOpen) throw new Error('CDP closed');
      }
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw new Error('game check timed out');
  }
  async function click(y) {
    // src/onboarding.zig: 560x500 panel centered in a 1000x640 viewport.
    await settleTicks();
    await send('Input.dispatchMouseEvent', {type:'mouseMoved', x:500, y}, sessionId);
    await settleTicks();
    await send('Input.dispatchMouseEvent', {type:'mousePressed', x:500, y, button:'left', clickCount:1}, sessionId);
    await frames();
    await send('Input.dispatchMouseEvent', {type:'mouseReleased', x:500, y, button:'left', clickCount:1}, sessionId);
    await settleTicks();
  }
  async function reload() {
    await flushRuntime(sessionId);
    const previousOrigin = await evaluate('performance.timeOrigin');
    await send('Page.reload', {}, sessionId);
    await expect('game reload initializes transport', `performance.timeOrigin !== ${previousOrigin} && !!window.gameOnboardingChecks && !!window.haystackOnboarding?.session?.service`);
    await settleTicks();
    await flushRuntime(sessionId);
    assertRuntimeClean(sessionId, `${flow}: no uncaught runtime errors across reload`);
  }
  async function pressGridKey() {
    await evaluate('document.getElementById("canvas").focus()');
    await send('Input.dispatchKeyEvent', {type:'rawKeyDown', key:'g', code:'KeyG', windowsVirtualKeyCode:71}, sessionId);
    await frames();
    await send('Input.dispatchKeyEvent', {type:'keyUp', key:'g', code:'KeyG', windowsVirtualKeyCode:71}, sessionId);
    await settleTicks();
  }
  async function expectGameplay(transition) {
    await expect(`${flow}: game socket authenticates after ${transition}`, 'window.gameSocketChecks?.ready === true');
    await settleTicks();
    const baseline = (await evaluate(gridSetting)).value;
    await pressGridKey();
    await expect(`${flow}: gameplay after ${transition} changes persisted grid`, `${gridSetting}.then(setting => setting.persisted && setting.value === ${!baseline})`);
    await pressGridKey();
    await expect(`${flow}: gameplay after ${transition} restores grid baseline`, `${gridSetting}.then(setting => setting.persisted && setting.value === ${baseline})`);
  }
  await prepareGame(sessionId, flow);
  const renderer = new URL('/renderer/index.html', input.origin).href;
  if (flow === 'sat-only' || flow === 'inactive-msat') {
    await send('Network.enable', {}, sessionId);
    await send('Network.setExtraHTTPHeaders', {headers:{'x-browser-test-keysets':flow}}, sessionId);
    const keysetsUrl = new URL('/v1/keysets', input.origin).href;
    let keysetsRequest;
    const unsubscribe = connection.on('Network.responseReceived', message => {
      const {response, requestId} = message.params;
      if (message.sessionId === sessionId && response.url.split('?')[0] === keysetsUrl && response.status === 200) {
        keysetsRequest = requestId;
      }
    });
    try {
      await send('Page.navigate', {url:renderer}, sessionId);
      await expect(`${flow}: startup refuses to begin onboarding`, `window.gameOnboardingChecks?.events.includes('mint_unavailable') && !window.haystackOnboarding?.session && document.getElementById('startup')?.textContent === 'Unable to start game.'`);
      failureLabel = `${flow}: startup checked live keysets and never offered wallet setup`;
      if (!keysetsRequest) throw new Error('missing live keysets response');
      const response = await send('Network.getResponseBody', {requestId:keysetsRequest}, sessionId);
      const {keysets} = JSON.parse(response.base64Encoded ? Buffer.from(response.body, 'base64').toString() : response.body);
      const expected = flow === 'sat-only' ? {unit:'sat', active:true} : {unit:'msat', active:false};
      if (keysets.length !== 1 || keysets[0].unit !== expected.unit || keysets[0].active !== expected.active) throw new Error('unexpected keysets fixture');
      if (!await evaluate(`gameOnboardingChecks.operations.length === 0 && !gameOnboardingChecks.events.some(event => ['choice', 'backup', 'ready'].includes(event))`)) throw new Error('wallet setup was offered');
      checks.push(failureLabel);
    } finally {
      unsubscribe();
    }
    console.log(JSON.stringify({flow, ok:true, checks}));
    return;
  }
  await send('Page.navigate', {url:renderer}, sessionId);
  if (flow === 'create') {
    await expect('game startup delivers choice', 'window.gameOnboardingChecks?.events.includes("choice")');
    await click(344); // Create new: panel.y + 252 + 22
    await expect('game consumes startup and creates backup', 'window.gameOnboardingChecks.operations.includes("create") && window.gameOnboardingChecks.events.includes("backup")');
    await click(514); // Continue, without the backup checkbox
    await expect('game gates unconfirmed backup', '!window.gameOnboardingChecks.operations.includes("complete_backup")');
    await expect('game never connects during backup', 'gameSocketChecks.connections === 0');
    await click(344); // Copy: a stub, never the system clipboard
    await expect('game consumes backup and supports trusted copy', 'window.gameOnboardingChecks.copies === 1');
    await reload();
    await expect('game reload resumes backup', 'window.gameOnboardingChecks.events.includes("backup")');
    await click(344);
    await expect('game consumes reloaded backup', 'window.gameOnboardingChecks.copies === 1');
    await click(400); // Confirm saved
    await click(514); // Continue
    await expect('game completes confirmed backup', 'window.gameOnboardingChecks.operations.includes("complete_backup") && window.gameOnboardingChecks.events.includes("complete_success")');
    await expectGameplay('completion');
    const moveRight = async () => {
      await evaluate('document.getElementById("canvas").focus()');
      await send('Input.dispatchKeyEvent', {type:'rawKeyDown', key:'ArrowRight', code:'ArrowRight', windowsVirtualKeyCode:39}, sessionId);
      await frames();
      await send('Input.dispatchKeyEvent', {type:'keyUp', key:'ArrowRight', code:'ArrowRight', windowsVirtualKeyCode:39}, sessionId);
      await settleTicks();
    };
    await moveRight();
    await expect('first tap turns without sending movement', 'gameSocketChecks.moves.length === 0');
    await moveRight();
    await expect('committed movement reaches game socket', 'gameSocketChecks.moves.some(([x,y]) => x === 1 && y === 0)');
    const moves = await evaluate('gameSocketChecks.moves.length');
    await evaluate('gameSocketChecks.disconnect(); true');
    await settleTicks();
    await moveRight();
    await expect('disconnected gameplay sends no moves', `gameSocketChecks.moves.length === ${moves}`);
    await evaluate('gameSocketChecks.online = true');
    await expect('reconnect authenticates with the same key', 'gameSocketChecks.ready && gameSocketChecks.keys.length === 2 && gameSocketChecks.keys[0] === gameSocketChecks.keys[1]');
    await settleTicks();
    await moveRight();
    await expect('reconnect starts at spawn', `gameSocketChecks.moves[${moves}]?.join() === '1,0'`);
    const beforeReject = await evaluate('gameSocketChecks.rejectNext = true; gameSocketChecks.moves.length');
    await moveRight();
    await expect('fixture rejects the second step', `gameSocketChecks.moves[${beforeReject}]?.join() === '2,0'`);
    await moveRight();
    await expect('rejected step rolls back before the next move', `gameSocketChecks.moves[${beforeReject + 1}]?.join() === '2,0'`);
    await click(344);
    await expect('game dismisses backup controls', 'window.gameOnboardingChecks.copies === 1');
    await reload();
    await expect('game reload recognizes ready wallet', 'window.gameOnboardingChecks.events.includes("ready")');
    await expectGameplay('ready reload');
    await click(344);
    await expect('ready game does not reprovision wallet', 'window.gameOnboardingChecks.operations.length === 0 && window.gameOnboardingChecks.copies === 0');
    await flushRuntime(sessionId);
    assertRuntimeClean(sessionId, 'create: no uncaught runtime errors across reload');
    checks.push('game has no uncaught runtime errors across reloads');
    console.log(JSON.stringify({flow:'game-create-reload', ok:true, checks}));

    // The settings lifetime guard rejects a second game before wallet startup.
    const second = await send('Target.createTarget', {url:'about:blank', browserContextId});
    const attached = await send('Target.attachToTarget', {targetId:second.targetId, flatten:true});
    await prepareGame(attached.sessionId, 'second-tab');
    await send('Page.navigate', {url:new URL('/renderer/index.html', input.origin).href}, attached.sessionId);
    failureLabel = 'second game is blocked by lifetime guard';
    const deadline = Date.now() + 15000;
    let blocked = false;
    while (Date.now() < deadline && !blocked) {
      const result = await send('Runtime.evaluate', {expression:'document.getElementById("startup")?.textContent === "Unable to start game." && !window.haystackOnboarding?.session', returnByValue:true}, attached.sessionId);
      blocked = result.result?.value === true;
      if (!blocked) await new Promise(resolve => setTimeout(resolve, 50));
    }
    if (!blocked) throw new Error('game lock check timed out');
    await flushRuntime(attached.sessionId);
    assertRuntimeClean(attached.sessionId, 'second-tab: no uncaught runtime errors');
    console.log(JSON.stringify({flow:'game-second-tab', ok:true, checks:['second game is blocked by lifetime guard']}));
    return;
  }
  await expect('recovery game starts at choice', 'window.gameOnboardingChecks?.events.includes("choice")');
  await click(400);
  async function type(text) {
    // Raylib's character mailbox is bounded per display-frame raw sample; do not overflow it.
    for (let i = 0; i < text.length; i += 8) {
      for (const character of text.slice(i, i + 8)) {
        // GLFW listens for keypress characters, not DOM text-field insertion.
        await send('Input.dispatchKeyEvent', {type:'char', text:character, unmodifiedText:character}, sessionId);
      }
      await settleTicks();
    }
  }
  await type('invalid');
  await click(400);
  await expect('game rejects typed invalid recovery phrase', 'window.gameOnboardingChecks.events.includes("invalid_phrase")');
  await reload();
  await expect('invalid game recovery leaves storage unprovisioned', 'window.gameOnboardingChecks.events.includes("choice")');
  await click(400);
  // Public BIP-39 vector only; never a user's phrase.
  await type('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about');
  await evaluate(`(() => {
    const original = window.fetch;
    window.fetch = (...args) => new URL(typeof args[0] === 'string' ? args[0] : args[0].url, location.href).pathname.startsWith('/v1/')
      ? Promise.reject(new Error('test mint unavailable')) : original(...args);
  })()`);
  await click(400);
  await expect('game recovery failure preserves retry stage', 'window.gameOnboardingChecks.events.includes("restore_failed")');
  await click(400); // Generate must not exist on failure.
  await expect('failed game recovery cannot generate', '!window.gameOnboardingChecks.operations.includes("generate")');
  await reload(); // Also removes the fetch fault.
  await expect('game reload resumes retry-only recovery', 'window.gameOnboardingChecks.events.includes("resume_failed")');
  await click(344);
  await expect('game retry completes local zero recovery', 'window.gameOnboardingChecks.operations.includes("retry") && window.gameOnboardingChecks.events.includes("restore_finished")');
  await click(400);
  await expect('game safely generates after zero recovery', 'window.gameOnboardingChecks.operations.includes("generate") && window.gameOnboardingChecks.events.includes("backup")');
  await click(344);
  await expect('game consumes recovered backup', 'window.gameOnboardingChecks.copies === 1');
  await click(400);
  await click(514);
  await expect('game completes recovered wallet setup', 'window.gameOnboardingChecks.events.includes("complete_success")');
  await expectGameplay('completion');
  await reload();
  await expect('recovered game wallet survives reload', 'window.gameOnboardingChecks.events.includes("ready")');
  await expectGameplay('ready reload');
  await flushRuntime(sessionId);
  assertRuntimeClean(sessionId, 'recovery: no uncaught runtime errors across reload');
  checks.push('recovery game has no uncaught errors across reloads');
  console.log(JSON.stringify({flow:'game-recovery-reload', ok:true, checks}));
}
const watch = watchdog(fault ? 45000 : 240000, 'onboarding test');
const work = run();
// If the watchdog wins the race, the losing execution must not surface as an
// unhandled rejection while the browser is being torn down.
work.catch(() => {});
try {
  await Promise.race([work, watch.promise]);
} catch (_) {
  console.error(`Onboarding browser test failed or timed out: ${failureLabel}`);
  process.exitCode = 1;
} finally {
  watch.stop();
  if (connection?.isOpen) {
    for (const browserContextId of contexts) {
      try { await bounded(send('Target.disposeBrowserContext', {browserContextId}), 1000, 'context disposal'); } catch (_) {}
    }
    connection.close();
  }
  await stopBrowser(browser);
  // Chromium helpers can finish touching the disposable profile just after the
  // main process exits. Retry bounded transient ENOTEMPTY/EBUSY failures.
  try { await removeProfile(profile); }
  catch (_) { console.error('Disposable onboarding browser profile cleanup failed'); process.exitCode = 1; }
}
