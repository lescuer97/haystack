// Isolated CDP runner: all wallet data lives in disposable browser contexts.
import {spawn} from 'node:child_process';
import {mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const input = new URL(process.argv[2]);
if (input.protocol !== 'http:' || input.hostname !== '127.0.0.1' || !input.port) throw new Error('Expected local fake mint URL');
const profile = await mkdtemp(join(tmpdir(), 'haystack-onboarding-'));
const browser = spawn(process.env.CHROMIUM || 'chromium', ['--headless', '--no-sandbox', `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank'], {stdio:['ignore','ignore','pipe']});
let socket, sequence = 0;
const pending = new Map(), contexts = [];
let timer;
function send(method, params = {}, sessionId) {
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    pending.set(id, {resolve, reject});
    socket.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}));
  });
}
async function run() {
  const endpoint = await new Promise((resolve, reject) => {
    let stderr = '';
    browser.stderr.on('data', chunk => {
      stderr += chunk;
      const match = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) resolve(match[1]);
    });
    browser.once('error', reject);
    browser.once('exit', () => reject(new Error('browser exited')));
  });
  socket = new WebSocket(endpoint);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  socket.onclose = () => { for (const p of pending.values()) p.reject(new Error('CDP closed')); pending.clear(); };
  socket.onmessage = ({data}) => {
    const message = JSON.parse(data);
    if (!message.id) return;
    const p = pending.get(message.id);
    if (!p) return;
    pending.delete(message.id);
    if (message.error) p.reject(new Error('CDP command failed')); else p.resolve(message.result);
  };
  for (const flow of ['create', 'restore']) {
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
        if (socket.readyState !== WebSocket.OPEN) throw new Error('CDP closed');
      }
      if (!report) await new Promise(resolve => setTimeout(resolve, 200));
    }
    console.log(JSON.stringify({flow, ...report}));
    if (!report.ok) throw new Error('onboarding checks failed');
  }
}
try {
  await Promise.race([run(), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('onboarding test timed out')), 240000); })]);
} catch (_) {
  console.error('Onboarding browser test failed or timed out');
  process.exitCode = 1;
} finally {
  clearTimeout(timer);
  if (socket?.readyState === WebSocket.OPEN) {
    for (const browserContextId of contexts) {
      try { await Promise.race([send('Target.disposeBrowserContext', {browserContextId}), new Promise(resolve => setTimeout(resolve, 1000))]); } catch (_) {}
    }
    socket.close();
  }
  browser.kill('SIGKILL');
  await new Promise(resolve => { if (browser.exitCode !== null || browser.signalCode !== null) resolve(); else { browser.once('exit', resolve); setTimeout(resolve, 3000); } });
  await rm(profile, {recursive:true, force:true});
}
