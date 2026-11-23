// See paid-hoe-browser-test.md for fixture builds and the isolated invocation.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {access, mkdir} from 'node:fs/promises';
import {createConnection} from 'node:net';
import {networkInterfaces} from 'node:os';
import {join, resolve} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {setTimeout as sleep} from 'node:timers/promises';
import {bounded, CdpConnection, discoverEndpoint, launchBrowser, makeProfile, removeProfile, stopBrowser} from './cdp-runner.mjs';

const modes = ['--smoke-only', '--renderer-only', '--funding-recovery', '--funding-change-recovery', '--funding-resume', '--renderer-funding-resume', '--tools'];
const args = process.argv.slice(2).filter(arg => !modes.includes(arg));
const selected = process.argv.slice(2).filter(arg => modes.includes(arg));
if (args.length !== 3 || selected.length > 1) throw new Error(`Usage: paid-hoe-browser-test.mjs MINT_EXE SERVER_EXE WASM_TEST_DIR [${modes.join(' | ')}]`);
const [mode] = selected;
const smoke = mode === '--smoke-only';
const renderer = mode === '--renderer-only';
const changeRecovery = mode === '--funding-change-recovery';
const fundingRecovery = mode === '--funding-recovery' || changeRecovery;
const rendererResume = mode === '--renderer-funding-resume';
const fundingResume = mode === '--funding-resume' || rendererResume;
// Sampled from shared/world.zig's sampleTile(public_seed, x, y), terrain v2.
const toolsFixture = mode === '--tools' ? {
  start:[80, 11],
  axe:{name:'axe', tag:0, price:'2', terrain:3, tile:[80, 10]},
  pickaxe:{name:'pickaxe', tag:2, price:'10', terrain:2, tile:[80, 12]},
} : null;
const [mintExe, serverExe, assets] = args.map(arg => resolve(arg));
const mintOrigin = 'http://127.0.0.1:18787'; // Matches the native fixture build option.
const gamePort = 9224; // Fixed by server/ws_config.zig.
const origin = `${mintOrigin}/v1/info`; // Same-origin idle document; no renderer/competing wallet lock.

// The limited loopback namespace also prevents reaching a public mint if a
// wrong artifact is supplied. A port already in use is a failure, not a target.
const interfaces = Object.values(networkInterfaces()).flat();
assert(interfaces.length && interfaces.every(nic => nic.internal), 'Run in a private loopback-only network namespace (see test docs)');
await Promise.all([access(mintExe), access(serverExe), access(join(assets, 'wallet/cdk_wallet_browser.js'))]);
async function listening(port) {
  return await new Promise((resolve, reject) => {
    const socket = createConnection({host:'127.0.0.1', port});
    socket.once('connect', () => { socket.destroy(); resolve(true); });
    socket.once('error', error => error.code === 'ECONNREFUSED' ? resolve(false) : reject(error));
    socket.setTimeout(500, () => { socket.destroy(); reject(new Error('Loopback probe timed out')); });
  });
}
assert(!(await listening(18787)) && !(await listening(gamePort)), 'A fixture port is already occupied');

const directory = await makeProfile('haystack-paid-hoe-');
const children = [];
const abort = new AbortController();
let cdp, session, stage = 'fixture startup', swaps = 0, cuts = 0, opens = 0, mintSwapSuccesses = 0;
let requirementsRequests = 0;
const send = (method, params = {}) => cdp.send(method, params, session);
function child(executable, args, env, label) {
  const process = spawn(executable, args, {cwd:directory, env, stdio:['ignore', 'pipe', 'pipe']});
  children.push(process);
  process.on('error', () => {});
  process.stderr.resume(); // Never log seed, token, proofs or raw child output.
  const done = once(process, 'exit').then(([code, signal]) => {
    throw new Error(`${label} exited (${code ?? signal})`);
  });
  done.catch(() => {});
  return {process, done};
}
async function evaluate(expression) {
  const {result, exceptionDetails} = await send('Runtime.evaluate', {expression, awaitPromise:true, returnByValue:true});
  if (exceptionDetails) throw new Error('Browser assertion or wallet call failed');
  return result.value;
}
async function dropSwap(afterCommit) {
  const {params:{requestId, request, responseStatusCode}} = await bounded(
    cdp.once('Fetch.requestPaused', session), 15000, 'fake mint swap interception',
  );
  assert(request.method === 'POST' && request.url === `${mintOrigin}/v1/swap`, 'expected a raw swap POST');
  assert.equal(responseStatusCode, afterCommit ? 200 : undefined, 'swap must pause at the selected HTTP stage');
  // Do not fetch or print either body. A request-stage failure never reaches the mint.
  await send('Fetch.failRequest', {requestId, errorReason:'Failed'});
  if (afterCommit) mintSwapSuccesses++;
}
async function load(reload = false, url = origin) {
  const loaded = cdp.once('Page.loadEventFired', session);
  if (reload) {
    await send('Page.reload');
  } else {
    const {errorText} = await send('Page.navigate', {url});
    assert(!errorText, 'Could not load the local fixture page');
  }
  await loaded;
  assert.equal(await evaluate('location.origin'), mintOrigin);
}

// Runs entirely in the Chromium page: only the production Wasm wallet sees
// the seed, and no proof/signature bytes are returned to Node. This small test
// peer implements the TLV subset in shared/wire.zig.
async function pageFlow({phase, smoke, channel, changeRecovery, savedOperation, resumeOffer, tools, toolChannels}) {
  const check = (condition, step) => {
    if (!condition) {
      window.paidHoeStep = step;
      throw new Error('Assertion failed');
    }
  };
  const step = label => {
    window.paidHoeStep = label;
    window.paidHoeDiagnostic = null;
  };
  // Exact literals only: never forward arbitrary wallet text or response fields.
  const safeWalletErrors = new Set([
    'could not derive the game channel identity',
    'could not read or commit hoe funding state',
    'could not read or commit hoe sender state',
    'exact hoe funding proofs changed; request a new quote',
    'expected a compressed public key',
    'expected scope, receiver key, amount, refund time and player key',
    'funded hoe channel has expired',
    'hoe funding belongs to another server',
    'hoe funding exceeds the channel payload limit',
    'hoe funding is pending; resume the saved swap',
    'hoe keyset ID does not match its keys',
    'hoe mint or active keyset is unavailable',
    'hoe operation needs reconciliation',
    'hoe quote changed or expired',
    'hoe quote expired',
    'hoe quote expired before submission',
    'hoe quote identity or mint changed',
    'hoe quote keyset changed',
    'hoe requirements do not match the wallet game identity',
    'invalid compressed public key',
    'invalid hoe amount or refund time',
    'invalid hoe funding layout or channel material',
    'invalid hoe operation arguments',
    'invalid hoe quote ID',
    'invalid hoe server scope',
    'invalid or expired hoe requirements',
    'missing hoe funding argument',
    'no exact active-keyset proofs for a whole hoe cut',
    'no live hoe quote',
    'unsupported hoe keyset denominations',
    'unsupported hoe mint fee, unit, expiry or denominations',
  ]);
  function walletFailure(result) {
    const {status, error} = result ?? {};
    const code = Number.isInteger(status) && status >= 0 && status <= 255 ? status : 'unknown';
    window.paidHoeDiagnostic = `wallet status ${code}: ${safeWalletErrors.has(error) ? error : 'message withheld'}`;
    throw new Error('Wallet call failed');
  }
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  const scope = 'ws://127.0.0.1:9224/';
  const bytes = (...values) => Uint8Array.of(...values);
  const random = length => crypto.getRandomValues(new Uint8Array(length));
  const hex = value => Array.from(value, byte => byte.toString(16).padStart(2, '0')).join('');
  const unhex = value => bytes(...value.match(/../g).map(byte => Number.parseInt(byte, 16)));
  const text = value => new TextEncoder().encode(value);
  const view = value => new DataView(value.buffer, value.byteOffset, value.byteLength);
  const u64 = (value, offset = 0) => view(value).getBigUint64(offset, true).toString();
  const encodeU64 = value => {
    const out = new Uint8Array(8);
    view(out).setBigUint64(0, BigInt(value), true);
    return out;
  };
  const point = (x, y) => {
    const out = new Uint8Array(8);
    view(out).setInt32(0, x, true);
    view(out).setInt32(4, y, true);
    return out;
  };
  const tlv = (tag, value) => [tag, value.length & 255, value.length >> 8, ...value];
  function sendFrame(tag, fields) {
    const body = fields.flatMap(([field, value]) => tlv(field, value));
    socket.send(bytes(tag, body.length & 255, body.length >> 8, ...body, 0x7e));
  }
  function readFrame(raw) {
    const data = new Uint8Array(raw);
    const end = data.length - 1;
    if (data.length < 4 || data[end] !== 0x7e || view(data).getUint16(1, true) !== end - 3) throw new Error('Invalid envelope');
    const fields = new Map();
    for (let i = 3; i < end;) {
      if (i + 3 > end) throw new Error('Truncated field');
      const tag = data[i];
      const length = view(data).getUint16(i + 1, true);
      i += 3;
      if (i + length > end || fields.has(tag)) throw new Error('Invalid field');
      fields.set(tag, data.subarray(i, i + length));
      i += length;
    }
    return {tag:data[0], fields};
  }
  const inbox = [];
  let socket, service, wallet, signer;
  const closingChannels = new Set();
  const failureCode = value => value && value.length >= 2 ? view(value).getUint16(0, true) : null;
  async function next(tag) {
    const deadline = performance.now() + 8000;
    let message;
    while (performance.now() < deadline) {
      if (!inbox.length) {
        if (socket.readyState >= WebSocket.CLOSING) break;
        await pause(10);
        continue;
      }
      const frame = readFrame(inbox.shift());
      if (frame.tag === 0xa6) {
        // The unsolicited notice can arrive before the close reply. Only status proves settlement.
        const id = frame.fields.get(0x20);
        check(id?.length === 32 && closingChannels.has(hex(id)), 'settlement notice identifies the closing channel');
        continue;
      }
      message = frame;
      break;
    }
    if (!message) {
      window.paidHoeDiagnostic = `no native reply for tag ${tag} (socket state ${socket.readyState})`;
      throw new Error('Missing game reply');
    }
    if (message.tag !== tag) {
      window.paidHoeDiagnostic = `native reply tag ${message.tag}, expected ${tag}`;
      throw new Error('Unexpected game reply');
    }
    const code = failureCode(message.fields.get(4));
    window.paidHoeDiagnostic = code === null ? null : `native failure code ${code}`;
    return message.fields;
  }
  async function request(tag, reply, fields, id = random(16)) {
    sendFrame(tag, [[1, id], ...fields]);
    const response = await next(reply);
    check(response.get(1)?.length === id.length && hex(response.get(1)) === hex(id), 'native reply matches request ID');
    return response;
  }
  async function walletCall(op, args) {
    const result = JSON.parse(await wallet.call(op, JSON.stringify(args)));
    if (result?.status !== 0) walletFailure(result);
    return result.value === undefined ? result : JSON.parse(result.value);
  }
  async function hoeResult(op, ...args) {
    step(`wallet hoe ${op}`);
    return JSON.parse(await wallet.hoe_request(op, JSON.stringify(args)));
  }
  async function hoe(op, ...args) {
    const result = await hoeResult(op, ...args);
    if (result?.status !== 0) walletFailure(result);
    return result;
  }
  function pendingOperation(result) {
    if (result?.status !== 19 || result.error !== 'hoe funding is pending; resume the saved swap') walletFailure(result);
    check(/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(result.operation_id), 'pending funding identifies the saved operation');
    return result.operation_id;
  }
  async function walletSnapshot() {
    // Read only the wallet state record, not the mnemonic. Keep all proof data in Chromium.
    const db = await new Promise((resolve, reject) => {
      const open = indexedDB.open('haystack-wallet');
      open.onsuccess = () => resolve(open.result);
      open.onerror = () => reject(new Error('Could not read wallet snapshot'));
      open.onupgradeneeded = () => open.transaction.abort();
    });
    try {
      const saved = await new Promise((resolve, reject) => {
        const read = db.transaction('states').objectStore('states').get('haystack-user');
        read.onsuccess = () => resolve(read.result);
        read.onerror = () => reject(new Error('Could not read wallet state'));
      });
      return {revision:saved.revision, proofs:Object.values(JSON.parse(saved.data).proofs)};
    } finally { db.close(); }
  }
  async function status(capacity, accepted, expectedPhase = 0, id = channel) {
    step('native channel status');
    const deadline = performance.now() + 8000;
    do {
      const response = await request(0x25, 0xa5, [[0x20, unhex(id)]]);
      const failure = response.get(4);
      if (!(failure?.length === 2 && failureCode(failure) === 12)) {
        const value = response.get(3);
        // This fixture expects no sender change, even when the channel is settled.
        check(value?.length === 17 && u64(value) === capacity && u64(value, 8) === accepted,
          'native channel status matches capacity and cumulative accepted amount without sender proofs');
        const actualPhase = value[16]; // active=0, depleted=1, settlement_pending=2, settled=3
        if (actualPhase === expectedPhase) return {capacity:u64(value), accepted:u64(value, 8)};
        check(expectedPhase === 3 && (actualPhase === 1 || actualPhase === 2), 'native channel has the expected phase');
      }
      // Retry reads only; never resubmit a cut or close while waiting for settlement.
      await pause(50);
    } while (performance.now() < deadline);
    check(false, 'native channel reached the expected phase before timeout');
  }
  async function areaCut(x, y) {
    step('native area snapshot');
    const cx = Math.floor(x / 16), cy = Math.floor(y / 16);
    const chunk = bytes(...point(cx, cy), ...point(cx, cy));
    const value = (await request(2, 0x82, [[2, chunk]])).get(3);
    check(value?.length === 86 && hex(value.subarray(0, 16)) === hex(chunk) &&
      view(value).getUint16(52, true) === 1, 'native snapshot covers the requested chunk');
    const index = (y - cy * 16) * 16 + x - cx * 16;
    return Boolean(value[54 + (index >> 3)] & (1 << (index & 7)));
  }
  const walletBalance = async mint => (await walletCall('wallet_screen', [mint])).msats;
  const recoveryReads = mint => performance.getEntriesByType('resource')
    .filter(({name}) => name === `${mint}/v1/checkstate` || name === `${mint}/v1/restore`)
    .map(({name}) => name.slice(mint.length));
  async function deposit(mint, amount, total) {
    step(`issue real ${amount}-msat fake-mint deposit`);
    const quote = await walletCall('create_deposit', [mint, amount]);
    const deadline = performance.now() + 12000;
    let invoice;
    do {
      invoice = await walletCall('check_deposit', [mint, quote.id]);
      if (invoice.confirmed) break;
      await pause(100);
    } while (performance.now() < deadline);
    check(invoice?.confirmed === true && invoice.state === 'ISSUED', 'deposit issued');
    check(await walletBalance(mint) === total, 'deposit spendable in IndexedDB');
  }
  const requirements = async ({name, tag, price} = {name:'hoe', tag:1, price:'5'}) => {
    step(`fetch real ${name} requirements`);
    const terms = (await request(0x21, 0xa1, [[0x23, bytes(tag)]])).get(3);
    check(terms?.length === 49 && u64(terms, 33) === price && Number(u64(terms, 41)) > Date.now() / 1000,
      `native server offers a ${price}-msat ${name} cut with a future refund`);
    return terms;
  };
  async function fund(mint, player, terms, capacity) {
    const argumentsForTerms = [scope, hex(terms.subarray(0, 33)), '5', u64(terms, 41), hex(player)];
    const swapUrl = `${mint}/v1/swap`;
    const beforeQuote = performance.getEntriesByName(swapUrl).length;
    const quote = await hoe('quote', ...argumentsForTerms);
    check(quote.capacity_msats === capacity && quote.max_debit_msats === capacity && quote.cuts === (BigInt(capacity) / 5n).toString(),
      'quote offers the expected cuts with zero fixture fees');
    check(await walletBalance(mint) === (changeRecovery ? '64' : capacity) && performance.getEntriesByName(swapUrl).length === beforeQuote,
      'quote neither swaps nor debits before consent');
    const fresh = await requirements();
    check(hex(fresh.subarray(0, 41)) === hex(terms.subarray(0, 41)) && BigInt(u64(fresh, 41)) >= BigInt(u64(terms, 41)),
      'native terms still match the consented quote');
    if (phase === 'funding-drop') {
      const operationId = pendingOperation(await hoeResult('fund', quote.quote_id, ...argumentsForTerms));
      check(await walletBalance(mint) === '0', 'submitted funding inputs are no longer spendable');
      if (changeRecovery) {
        const {proofs} = await walletSnapshot();
        const inputs = proofs.filter(proof => proof.used_by_operation === operationId);
        check(inputs.length === 1 && String(inputs[0].proof.amount) === '64' && inputs[0].state === 'RESERVED' &&
          !proofs.some(proof => proof.created_by_operation === operationId),
          'the operation reserves the single 64-msat input and credits no change yet');
      }
      return {operationId, refundTime:quote.refund_time};
    }
    const funding = await hoe('fund', quote.quote_id, ...argumentsForTerms);
    check(/^[0-9a-f]{64}$/.test(funding.channel_id) && funding.channel_id !== channel, 'wallet funds a new channel ID');
    channel = funding.channel_id;
    await openAndBind(mint, funding, capacity);
  }
  async function openAndBind(mint, funding, capacity, balance = '0', tool) {
    const id = tool ? funding.channel_id : channel;
    if (!tool) check(funding.channel_id === id, 'opening payload matches the wallet channel ID');
    check(funding.capacity_msats === capacity && await walletBalance(mint) === balance, 'wallet debits exactly the funded capacity');
    step(`admit funded ${tool?.name ?? 'hoe'} channel on the native server`);
    const opened = await request(0x24, 0xa2, [[0x20, unhex(id)], ...(tool ? [[0x23, bytes(tool.tag)]] : []),
      [0x24, text(funding.funding_proofs_json)], [0x25, text(funding.params_json)]]);
    check(opened.get(3)?.length === 0, 'native server accepted real mint funding proofs');
    const admitted = await status(capacity, '0', 0, id);
    const bound = tool ? await toolCall(tool, 'bind', scope, id, admitted.capacity, admitted.accepted)
      : await hoe('bind', scope, id, admitted.capacity, admitted.accepted);
    check(bound.balance_msats === '0', 'wallet binds new channel at zero accepted');
  }
  const sendCut = (id, tile, channelId, amount, payment, tool) => request(1, 0x81,
    [[2, tile], [0x20, unhex(channelId)], [0x21, encodeU64(amount)], [0x22, unhex(payment.signature)],
      ...(tool ? [[0x23, bytes(tool.tag)]] : [])], id);
  async function cut(x, y, amount, duplicate = false) {
    const id = random(16);
    const payment = await hoe('prepare_cut', scope, channel, hex(id));
    check(payment.balance_msats === amount, 'wallet signs the next cumulative 5-msat increment');
    const tile = point(x, y);
    step(duplicate ? 'submit paid duplicate cut' : 'submit signed paid cut');
    const reply = await sendCut(id, tile, channel, amount, payment);
    const failure = reply.get(4);
    if (duplicate) check(failure?.length === 12 && failureCode(failure) === 10, 'native server rejects already-cut tile');
    const state = duplicate ? failure.subarray(2) : reply.get(3);
    check(state?.length === 10 && hex(state.subarray(0, 8)) === hex(tile) && state[8] === 0 && state[9] === 1,
      'native cut result identifies the correct cut grass tile');
    return hex(id);
  }
  async function toolCall(tool, op, ...args) {
    step(`wallet ${tool.name} ${op}`);
    const result = JSON.parse(await wallet.tool_request(tool.name, op, JSON.stringify(args)));
    if (result?.status !== 0) walletFailure(result);
    return result;
  }
  async function toolsFlow(mint, player, auth) {
    const {axe, pickaxe, start} = tools;
    const at = tile => hex(auth.get(3)) === hex(point(...tile));
    async function fundTool(tool) {
      await deposit(mint, tool.price, tool.price);
      const terms = await requirements(tool);
      const args = [scope, hex(terms.subarray(0, 33)), u64(terms, 33), u64(terms, 41), hex(player)];
      const swapUrl = `${mint}/v1/swap`;
      const beforeQuote = performance.getEntriesByName(swapUrl).length;
      const quote = await toolCall(tool, 'quote', ...args);
      check(quote.price_msats === tool.price && quote.capacity_msats === tool.price &&
        quote.max_debit_msats === tool.price && quote.cuts === '1', `quote offers exactly one ${tool.name} use without fees`);
      check(await walletBalance(mint) === tool.price && performance.getEntriesByName(swapUrl).length === beforeQuote,
        `${tool.name} quote neither swaps nor debits before consent`);
      const funding = await toolCall(tool, 'fund', quote.quote_id, ...args);
      check(/^[0-9a-f]{64}$/.test(funding.channel_id), `${tool.name} funding returns a channel ID`);
      await openAndBind(mint, funding, tool.price, '0', tool);
      return funding.channel_id;
    }
    async function harvest(target, tool, payer, expectedFailure) {
      const channelId = toolChannels[payer.name];
      const id = random(16);
      const payment = await toolCall(payer, 'prepare_cut', scope, channelId, hex(id));
      check(payment.balance_msats === payer.price, `wallet signs exactly one ${payer.name} increment`);
      const tile = point(...target.tile);
      step(`submit ${tool.name} cut on ${target.name} terrain using ${payer.name} channel`);
      const reply = await sendCut(id, tile, channelId, payer.price, payment, tool);
      const charged = expectedFailure === undefined;
      if (charged) {
        const state = reply.get(3);
        check(state?.length === 10 && hex(state.subarray(0, 8)) === hex(tile) && state[8] === target.terrain && state[9] === 1,
          `${target.name} cut identifies the expected tile and preserves its base terrain`);
      } else {
        const failure = reply.get(4);
        check(!reply.has(3) && failure?.length === 2 && failureCode(failure) === expectedFailure,
          `native server rejects ${tool === payer ? 'wrong tool for terrain' : 'wrong channel for tool'}`);
      }
      const resolved = await toolCall(payer, 'resolve_cut', scope, channelId, hex(id), charged ? 'charged' : 'not_charged');
      check(resolved.balance_msats === (charged ? payer.price : '0'), `${payer.name} wallet accepted balance matches the outcome`);
    }
    async function move(tile, allowed) {
      step(`move to (${tile.join(',')}) expecting ${allowed ? 'success' : 'blocked terrain'}`);
      const reply = await request(3, 0x83, [[2, point(...tile)]]);
      const failure = reply.get(4);
      check(allowed ? reply.get(3)?.length === 0 : !reply.has(3) && failure?.length === 2 && failureCode(failure) === 1,
        'native movement agrees with harvest state');
    }
    const toolStatus = (tool, depleted) => status(tool.price, depleted ? tool.price : '0', depleted ? 1 : 0, toolChannels[tool.name]);
    async function checkBoth(axeDepleted, pickaxeDepleted) {
      for (const [tool, depleted] of [[axe, axeDepleted], [pickaxe, pickaxeDepleted]]) {
        const saved = await toolCall(tool, 'inspect', scope);
        check(saved.admitted && saved.channel_id === toolChannels[tool.name] && saved.capacity_msats === tool.price &&
          saved.balance_msats === (depleted ? tool.price : '0'), `${tool.name} local binding and balance are independent`);
        await toolStatus(tool, depleted);
        check(await areaCut(...tool.tile) === depleted, `${tool.name} tile bitmap matches the expected harvest state`);
      }
    }
    const entries = auth.get(0x28);
    if (phase === 'tools') {
      check(at(start) && !entries && !auth.has(0x20), 'fresh tools player is at fixture start with no channels');
      const axeChannel = await fundTool(axe);
      // The wallet shares a whole-second setup watermark across tools to keep
      // deterministic funding outputs distinct. Never retry a funding call.
      const nextSetup = (Math.floor(Date.now() / 1000) + 1) * 1000;
      while (Date.now() < nextSetup) await pause(nextSetup - Date.now());
      toolChannels = {axe:axeChannel, pickaxe:await fundTool(pickaxe)};
      check(toolChannels.axe !== toolChannels.pickaxe, 'the tools have distinct funded channel IDs');
      await move(axe.tile, false);
      await harvest(axe, pickaxe, pickaxe, 9); // Valid pickaxe payment, wrong terrain.
      await harvest(axe, axe, pickaxe, 1); // Right terrain and tool, wrong channel.
      await checkBoth(false, false);
      await harvest(axe, axe, axe);
      await checkBoth(true, false);
      await move(axe.tile, true);
      return toolChannels; // Public IDs only.
    }
    check(at(axe.tile), 're-authentication confirms movement onto the harvested tree');
    check(!auth.has(0x20) && entries?.length === 98, 're-authentication reports exactly two tool channels');
    for (const [index, tool] of [axe, pickaxe].entries()) {
      const entry = entries.subarray(index * 49, (index + 1) * 49);
      check(entry[0] === tool.tag && hex(entry.subarray(1, 33)) === toolChannels[tool.name] &&
        u64(entry, 33) === tool.price && u64(entry, 41) === (tool === axe ? axe.price : '0'),
        `native auth restores the ${tool.name} channel at its own balance`);
    }
    await checkBoth(true, false);
    await move(start, true);
    await move(pickaxe.tile, false);
    await harvest(pickaxe, pickaxe, pickaxe);
    await checkBoth(true, true);
    await move(pickaxe.tile, true);
    for (const tool of [axe, pickaxe]) {
      const id = toolChannels[tool.name];
      step(`close the depleted ${tool.name} channel`);
      closingChannels.add(id);
      const closed = await request(0x23, 0xa3, [[0x20, unhex(id)]]);
      const failed = closed.get(4);
      check(closed.get(3)?.length === 0 || (failed?.length === 2 && failureCode(failed) === 25),
        `${tool.name} close succeeded or entered settlement`);
      const settled = await status(tool.price, tool.price, 3, id);
      await toolCall(tool, 'finalize', scope, id, settled.capacity, settled.accepted, '');
      check((await toolCall(tool, 'inspect', scope)).channel_id === null, `${tool.name} settlement releases only its funding slot`);
      if (tool === axe) {
        await toolStatus(pickaxe, true);
        check((await toolCall(pickaxe, 'inspect', scope)).channel_id === toolChannels.pickaxe,
          'axe settlement leaves the pickaxe journal untouched');
      }
    }
    check(await walletBalance(mint) === '0', 'harvests, reconnect and depleted settlements do not debit ordinary wallet proofs');
    return true;
  }
  try {
    step('initialize production browser wallet');
    const module = await import('/wallet/cdk_wallet_browser.js');
    await module.default();
    const mint = module.onboarding_mint();
    check(mint === location.origin, 'local mint Wasm fixture');
    check(smoke || typeof module.BrowserWallet.prototype.hoe_request === 'function', 'paid-hoe Wasm bindings (rebuild browser-fixture)');
    if (tools) check(typeof module.BrowserWallet.prototype.tool_request === 'function', 'paid-tool Wasm bindings (rebuild browser-fixture)');
    if (phase === 'bootstrap') {
      // Public BIP-39 test vector; isolated IndexedDB and fake funds only.
      await module.provision_wallet('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about', 'haystack-user');
    }
    service = await module.start_onboarding(mint);
    signer = await service.open_game_signer();
    wallet = await service.open_ready_wallet();
    if (phase === 'bootstrap') {
      await walletCall('add_mint', [mint]);
      if (changeRecovery) {
        // CDK first fills its inventory of small denominations (three of each
        // from 1 to 32). Fill those slots so the next deposit issues one 64.
        await deposit(mint, '189', '189');
        await deposit(mint, '64', '253');
        for (let i = 0; i < 3; i++) await walletCall('send', [mint, '63', '0']);
        const {proofs} = await walletSnapshot();
        const spendable = proofs.filter(proof => proof.state === 'UNSPENT');
        check(spendable.length === 1 && String(spendable[0].proof.amount) === '64' && await walletBalance(mint) === '64',
          'fixture leaves exactly one spendable 64-msat proof after setting aside the smaller denominations');
      } else if (!tools) {
        await deposit(mint, '10', '10');
      }
    }
    if (phase === 'renderer-verify' || phase === 'renderer-resume-verify') {
      // Read durable state before authenticating: a new connection must not
      // reconcile an unresolved payment on behalf of the renderer under test.
      const saved = await hoe('inspect', scope);
      const resumed = phase === 'renderer-resume-verify';
      check(saved.admitted && saved.capacity_msats === '10' && saved.balance_msats === (resumed ? '0' : '5') &&
        (resumed ? saved.channel_id === channel : /^[0-9a-f]{64}$/.test(saved.channel_id)),
        'renderer persisted the expected channel binding and accepted balance');
      channel = saved.channel_id;
      check(await walletBalance(mint) === '0', 'renderer refill debited exactly the deposited 10 msat');
    }

    step('authenticate real native game socket');
    socket = new WebSocket(scope);
    socket.binaryType = 'arraybuffer';
    socket.onmessage = ({data}) => inbox.push(data);
    const nonce = (await next(0xf0)).get(0x10);
    check(nonce?.length === 32, 'native auth challenge has a 32-byte nonce');
    const proof = signer.sign(nonce, random(32));
    const player = proof.subarray(0, 33);
    sendFrame(0xf1, [[0x11, player], [0x12, proof.subarray(33)]]);
    const auth = await next(0xf2);
    check(auth.get(3)?.length === 8, 'native auth accepted');
    if (phase === 'bootstrap') return true;
    if (tools) return await toolsFlow(mint, player, auth);
    check(auth.get(3).every(byte => byte === 0), 'native auth uses fixture position (0,0)');
    if (phase === 'funding-inspect') {
      check(!auth.has(0x20), 'interrupted funding never opened a native channel');
      const {revision} = await walletSnapshot();
      const beforeInspect = recoveryReads(mint).length;
      const operationId = pendingOperation(await hoeResult('inspect', scope));
      check(operationId === savedOperation.operationId, 'inspect reports the original pending operation after reopening');
      check(recoveryReads(mint).slice(beforeInspect).join(',') === '/v1/checkstate', 'inspect only checks input state');
      check(await walletBalance(mint) === '0', 'inspect leaves the input reserved');
      const beforeOffer = recoveryReads(mint).length;
      const offer = await hoe('resume_quote', scope);
      check(recoveryReads(mint).length === beforeOffer, 'resume quote requests no mint recovery evidence');
      check(offer.operation_id === operationId && offer.scope === scope && offer.mint_url === mint &&
        /^[0-9a-f]{64}$/.test(offer.channel_id) && offer.refund_time === savedOperation.refundTime &&
        offer.cuts === '2' && offer.capacity_msats === '10' && offer.max_debit_msats === '10',
        'resume quote shows the exact saved operation and debit');
      check((await walletSnapshot()).revision === revision, 'inspect and resume quote did not write wallet state');
      return {operationId, channel:offer.channel_id, debit:offer.max_debit_msats, refundTime:offer.refund_time};
    }
    if (phase === 'funding-recover' || phase === 'funding-resume') {
      check(!auth.has(0x20), 'interrupted funding never opened a native channel');
      const capacity = changeRecovery ? '50' : '10';
      const balance = changeRecovery ? '14' : '0';
      let funding;
      if (phase === 'funding-resume') {
        funding = await hoe('resume', scope, resumeOffer.operationId, resumeOffer.debit);
        check(funding.channel_id === resumeOffer.channel && funding.refund_time === resumeOffer.refundTime,
          'explicit consent funds the saved channel and preserves the refund time');
        channel = resumeOffer.channel;
      } else {
        const before = changeRecovery ? await walletSnapshot() : null;
        const beforeReads = changeRecovery ? recoveryReads(mint).length : 0;
        const recovered = await hoe('inspect', scope);
        check(recovered.admitted === false && recovered.capacity_msats === capacity && recovered.balance_msats === '0' &&
          /^[0-9a-f]{64}$/.test(recovered.channel_id), 'inspect recovered a funded but not yet admitted channel');
        if (changeRecovery) {
          check(recoveryReads(mint).slice(beforeReads).join(',') === '/v1/checkstate,/v1/restore',
            'inspect checks input state and restores outputs exactly once, excluding wallet startup');
          const after = await walletSnapshot();
          const prior = before.proofs.find(proof => proof.used_by_operation === savedOperation.operationId);
          const input = after.proofs.find(proof => proof.y === prior?.y);
          const change = after.proofs.filter(proof => proof.state === 'UNSPENT');
          check(after.revision === before.revision + 1 && input?.state === 'SPENT' &&
            change.length > 0 && change.every(proof => proof.spending_condition === null &&
              proof.created_by_operation === savedOperation.operationId) &&
            change.reduce((total, proof) => total + BigInt(proof.proof.amount), 0n) === 14n,
            'one IndexedDB commit recovers funding, marks the 64-msat input spent and credits 14 msat of ordinary change');
        }
        channel = recovered.channel_id;
        funding = await hoe('open_payload', scope, channel);
      }
      await openAndBind(mint, funding, capacity, balance);
      const saved = await hoe('inspect', scope);
      check(saved.admitted === true && saved.channel_id === channel && saved.capacity_msats === capacity && saved.balance_msats === '0',
        'wallet saved the recovered channel binding at zero accepted');
      return channel;
    }
    if (phase === 'funding-change-verify') {
      check(auth.get(0x20)?.length === 32 && hex(auth.get(0x20)) === channel, 'reloaded native player has the recovered channel');
      const saved = await hoe('inspect', scope);
      check(saved.admitted === true && saved.channel_id === channel && saved.capacity_msats === '50' &&
        saved.balance_msats === '0' && await walletBalance(mint) === '14', 'admission and exactly 14 msat of ordinary change survive reload');
      await status('50', '0');
      step('spend the recovered change as ordinary wallet funds');
      const sent = await walletCall('send', [mint, '14', '0']);
      check(sent.sender_fee_msats === '0' && typeof sent.token === 'string' && sent.token.length > 0 &&
        await walletBalance(mint) === '0', 'the ordinary wallet can send all 14 recovered msat without a fee');
      return true;
    }
    if (phase === 'initial' || phase === 'funding-drop') {
      check(!auth.has(0x20), 'fresh player has no admitted channel');
      const terms = await requirements();
      check(!(await areaCut(0, 1)), 'native tile starts uncut');
      if (smoke) return true;
      const pending = await fund(mint, player, terms, changeRecovery ? '50' : '10');
      if (phase === 'funding-drop') return pending;
      // Issuing this after the first funding keeps its exact proofs in reserve for channel two.
      await deposit(mint, '5', '5');
      await cut(0, 1, '5');
      // The test peer checks the wire reply, but deliberately leaves the wallet cut pending.
      return channel; // Public identifier only.
    }

    const accepted = phase === 'renderer-resume-verify' ? '0' : '5';
    check(auth.get(0x20)?.length === 32 && hex(auth.get(0x20)) === channel &&
      auth.get(0x26)?.length === 8 && u64(auth.get(0x26)) === '10' &&
      auth.get(0x27)?.length === 8 && u64(auth.get(0x27)) === accepted,
      'new authenticated socket resumes the same channel at the expected accepted balance');
    if (phase === 'renderer-resume-verify') {
      await status('10', '0');
      return true;
    }
    if (phase === 'renderer-verify') {
      await status('10', '5');
      check(await areaCut(0, 1), 'native snapshot marks the grass clicked by the renderer cut');
      return true;
    }
    const saved = await hoe('inspect', scope);
    const locallyAccepted = phase === 'recover' ? '0' : '5';
    check(saved.channel_id === channel && saved.capacity_msats === '10' && saved.balance_msats === locallyAccepted && saved.admitted,
      'wallet retains the expected local balance across reload');
    if (phase === 'recover') {
      const authoritative = await status('10', '5');
      // A plausible but unsent cumulative balance must not overwrite the pending payment.
      step('reject a bind above the pending payment');
      const wrong = JSON.parse(await wallet.hoe_request('bind', JSON.stringify([scope, channel, authoritative.capacity, '10'])));
      check(wrong.status === 19, 'wallet rejects a nonmatching accepted balance');
      step('check durable pending cut blocks a new payment');
      const blocked = JSON.parse(await wallet.hoe_request('prepare_cut', JSON.stringify([scope, channel, hex(random(16))])));
      check(blocked.status === 19, 'pending cut survives reload and blocks a new payment');
      const bound = await hoe('bind', scope, channel, authoritative.capacity, authoritative.accepted);
      check(bound.balance_msats === authoritative.accepted, 'wallet binds the exact authoritative cumulative balance');
      await status('10', '5');
      check(await areaCut(0, 1), 'native snapshot still marks the tile cut after reload');
      check(await walletBalance(mint) === '5', 'reconciliation preserves the replacement deposit');
      return true;
    }

    const duplicate = await cut(0, 1, '10', true);
    const rejected = await hoe('resolve_cut', scope, channel, duplicate, 'not_charged');
    check(rejected.balance_msats === '5', 'duplicate did not increase the wallet balance');
    await status('10', '5');
    check(!(await areaCut(1, 0)), 'second grass tile starts uncut');
    const finalCut = await cut(1, 0, '10');
    const charged = await hoe('resolve_cut', scope, channel, finalCut, 'charged');
    check(charged.balance_msats === '10', 'second grass cut consumes the remaining capacity');
    await status('10', '10', 1);
    check(await areaCut(1, 0), 'depleting cut is visible in the world');

    step('close the depleted channel');
    closingChannels.add(channel);
    const closed = await request(0x23, 0xa3, [[0x20, unhex(channel)]]);
    const closeFailure = closed.get(4);
    check(closed.get(3)?.length === 0 || (closeFailure?.length === 2 && failureCode(closeFailure) === 25),
      'native close succeeded or started settlement');
    const settled = await status('10', '10', 3);
    await hoe('finalize', scope, channel, settled.capacity, settled.accepted, '');
    check((await hoe('inspect', scope)).channel_id === null, 'finalize releases the settled wallet funding slot');
    check(await walletBalance(mint) === '5', 'fully depleted settlement credits no sender change');
    await fund(mint, player, await requirements(), '5');
    return channel;
  } finally {
    socket?.close();
    signer?.free();
    if (wallet) { await wallet.close(); wallet.free(); }
    if (service) { await service.close(); service.free(); }
  }
}

// Observe the production bridge without changing its calls or replies. Keep
// only completed operation numbers and allowlisted scalar result fields.
function observeRendererHoe(savedOperation) {
  const replies = window.rendererHoeReplies = {};
  const requests = window.rendererHoeRequests = {};
  const toolInspects = window.rendererToolInspects = {};
  let bridge;
  Object.defineProperty(window, 'haystackOnboarding', {
    configurable: true,
    get: () => bridge,
    set(value) {
      bridge = value;
      const pending = new Map();
      const request = bridge.toolRequest;
      const deliver = bridge.deliverResponse;
      bridge.toolRequest = function(generation, serial, tool, op) {
        if (tool === 1) requests[op] = (requests[op] ?? 0) + 1;
        pending.set(`${generation}:${serial}`, {tool, op});
        return request.apply(this, arguments);
      };
      bridge.deliverResponse = function(callback, generation, serial, text, startup, limit) {
        if (limit === 65536) {
          const key = `${generation}:${serial}`;
          const request = pending.get(key);
          pending.delete(key);
          if (request) {
            const {tool, op} = request;
            let data;
            try { data = JSON.parse(text); } catch (_) {}
            if (op === 1 && data?.status === 0) toolInspects[tool] = (toolInspects[tool] ?? 0) + 1;
            if (tool !== 1) return deliver.apply(this, arguments);
            replies[op] = {
              ok: data?.status === 0,
              twoCutQuote: (op === 2 || op === 9) && data?.cuts === '2' && data.capacity_msats === '10' && data.max_debit_msats === '10',
              pendingSaved: op === 1 && data?.status === 19 && data.operation_id === savedOperation?.operationId,
              savedQuote: op === 9 && data?.operation_id === savedOperation?.operationId &&
                data?.refund_time === savedOperation?.refundTime && data?.mint_url === location.origin,
              channel: op === 9 && /^[0-9a-f]{64}$/.test(data?.channel_id) ? data.channel_id : null,
              zeroAccepted: op === 5 && data?.balance_msats === '0',
              fiveAccepted: op === 7 && data?.balance_msats === '5',
            };
          }
        }
        return deliver.apply(this, arguments);
      };
    },
  });
}

// Check the actual renderer socket received an area snapshot covering (0,1)
// with that grass still uncut. No socket frames are modified or replayed.
function containsUncutFixtureGrass(frame) {
  if (frame[0] !== 0x82) return false;
  for (let i = 3; i + 3 <= frame.length - 1;) {
    const tag = frame[i];
    const length = frame.readUInt16LE(i + 1);
    i += 3;
    if (i + length > frame.length - 1) return false;
    if (tag === 3 && length >= 54) {
      const x0 = frame.readInt32LE(i), y0 = frame.readInt32LE(i + 4);
      const x1 = frame.readInt32LE(i + 8), y1 = frame.readInt32LE(i + 12);
      if (x0 > 0 || x1 < 0 || y0 > 0 || y1 < 0) return false;
      const chunk = -y0 * (x1 - x0 + 1) - x0;
      if (chunk >= frame.readUInt16LE(i + 52)) return false;
      const grassByte = 54 + chunk * 32 + 2; // Tile index 16 = (0,1).
      return grassByte < length && (frame[i + grassByte] & 1) === 0;
    }
    i += length;
  }
  return false;
}

async function rendererFlow(areaReady, savedOperation = null) {
  const width = 1000, height = 640;
  const settle = () => evaluate(`new Promise(resolve => {
    const start = performance.now();
    function tick(now) { if (now - start >= 120) resolve(true); else requestAnimationFrame(tick); }
    requestAnimationFrame(tick);
  })`);
  async function expect(label, condition) {
    stage = label;
    const deadline = Date.now() + 12000;
    while (Date.now() < deadline) {
      if (typeof condition === 'function' ? condition() : await evaluate(condition)) return;
      await sleep(50, undefined, {signal:abort.signal});
    }
    const progress = await evaluate(`({requests: rendererHoeRequests, replies: Object.fromEntries(
      Object.entries(rendererHoeReplies).map(([op, {channel, ...flags}]) => [op, flags]))})`);
    throw new Error(`Renderer check timed out (${JSON.stringify(progress)})`);
  }
  async function click(x, y, dragX = 0) {
    await send('Input.dispatchMouseEvent', {type:'mouseMoved', x, y});
    await settle();
    await send('Input.dispatchMouseEvent', {type:'mousePressed', x, y, button:'left', buttons:1, clickCount:1});
    await evaluate('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve(true))))');
    if (dragX) {
      await send('Input.dispatchMouseEvent', {type:'mouseMoved', x:x + dragX, y, buttons:1});
      await settle();
      await send('Input.dispatchMouseEvent', {type:'mouseMoved', x, y, buttons:1});
      await settle();
    }
    await send('Input.dispatchMouseEvent', {type:'mouseReleased', x, y, button:'left', clickCount:1});
    await settle();
  }

  stage = 'load real game renderer';
  await send('Emulation.setDeviceMetricsOverride', {width, height, deviceScaleFactor:1, mobile:false});
  const {identifier} = await send('Page.addScriptToEvaluateOnNewDocument', {source:`(${observeRendererHoe})(${JSON.stringify(savedOperation)})`});
  const beforeRequirements = requirementsRequests;
  await send('Page.bringToFront');
  await load(false, `${mintOrigin}/renderer/index.html`);
  if (savedOperation) {
    await expect('renderer inspect finds the original pending refill', 'rendererHoeReplies[1]?.pendingSaved');
  } else {
    await expect('renderer inspects the ready wallet on the native connection', 'rendererHoeReplies[1]?.ok');
  }
  assert.deepEqual(await evaluate(`(() => {
    const {x, y, width, height} = document.querySelector('canvas').getBoundingClientRect();
    return {x, y, width, height};
  })()`), {x:0, y:0, width, height});
  await settle();

  if (!savedOperation) {
    // The hotbar's slots are centered at -90, 0, +90 from viewport center.
    // A slot click and then number keys must load the selected tool's own journal.
    await click(width / 2, height - 32);
    await expect('clicking the Axe slot inspects the axe journal', 'rendererToolInspects[0] === 1');
    for (const number of [1, 3]) {
      const event = {key:String(number), code:`Digit${number}`, windowsVirtualKeyCode:48 + number};
      await send('Input.dispatchKeyEvent', {type:'keyDown', ...event});
      await settle();
      await send('Input.dispatchKeyEvent', {type:'keyUp', ...event});
      await expect(`number key ${number} selects its tool`, number === 1 ? 'rendererToolInspects[2] === 1' : 'rendererToolInspects[1] === 2');
    }
    assert.equal(cuts, 0, 'switching hotbar slots does not harvest');
  }

  // src/game.zig: the refill button is centered 84 px right of the viewport
  // center and 88 px above the bottom, both before and after the quote.
  const clickRefill = () => click(width / 2 + 84, height - 88);
  if (savedOperation) {
    const assertNoResume = async () => {
      assert.equal(swaps, 1, 'only the pre-dispatch attempt is allowed before consent');
      assert.equal(mintSwapSuccesses, 0, 'no successful swap before consent');
      assert.equal(opens, 0, 'no native open before consent');
      assert.equal(requirementsRequests, beforeRequirements, 'no native requirements request before consent');
      assert(await evaluate('!rendererHoeRequests[3] && !rendererHoeRequests[10]'), 'no wallet funding or resume before consent');
    };
    await assertNoResume();
    assert.equal(await evaluate('rendererHoeRequests[9] ?? 0'), 0, 'inspect does not request a resume quote');
    stage = 'click Review saved refill in the HUD';
    await clickRefill();
    await expect('HUD click quotes the original saved refill for two cuts and 10 msat',
      'rendererHoeReplies[9]?.ok && rendererHoeReplies[9].twoCutQuote && rendererHoeReplies[9].savedQuote && rendererHoeReplies[9].channel');
    const channel = await evaluate('rendererHoeReplies[9].channel');
    await assertNoResume();

    stage = 'click Resume refill in the HUD';
    await clickRefill();
    await expect('HUD resumes the saved swap and binds at zero accepted',
      'rendererHoeReplies[10]?.ok && rendererHoeReplies[5]?.ok && rendererHoeReplies[5].zeroAccepted');
    assert.equal(requirementsRequests, beforeRequirements + 1, 'the consent click fetches fresh native requirements once');
    assert(await evaluate('!rendererHoeRequests[2] && !rendererHoeRequests[3] && rendererHoeRequests[9] === 1 && rendererHoeRequests[10] === 1'),
      'one saved quote and one resume, never a fresh quote or fund');
    await send('Page.removeScriptToEvaluateOnNewDocument', {identifier});
    return channel;
  }

  stage = 'click Get refill quote in the HUD';
  await clickRefill();
  await expect('HUD click obtains a two-cut quote for 10 msat', 'rendererHoeReplies[2]?.ok && rendererHoeReplies[2].twoCutQuote');
  await settle();
  assert.equal(swaps, 0, 'the quote must not swap before a second click');
  assert.equal(cuts, 0, 'the quote click must not send a cut');
  assert.equal(await evaluate('rendererHoeRequests[3] ?? 0'), 0, 'quote did not request funding');

  stage = 'click Refill hoe in the HUD';
  await clickRefill();
  await expect('refill binds the real server channel at zero accepted', 'rendererHoeReplies[3]?.ok && rendererHoeReplies[5]?.ok && rendererHoeReplies[5].zeroAccepted');
  assert.equal(swaps, 1, 'consent performs exactly one mint swap');
  assert.equal(cuts, 0, 'the refill click must not send a cut');
  console.log('ok - real renderer HUD quoted two cuts for 10 msat, then refilled on a separate click with one mint swap');
  await expect('native area supplies the renderer with uncut grass at (0,1)', areaReady);
  await settle();

  // Camera centers on the authenticated player at (0,0), with 32 px tiles.
  const grassX = width / 2, grassY = height / 2 + 32;
  stage = 'drag on grass at (0,1) without paying';
  // Leave the click tolerance, then return to the same point before release.
  await click(grassX, grassY, 8);
  assert.equal(await evaluate('rendererHoeRequests[6] ?? 0'), 0, 'drag did not prepare a payment');
  assert.equal(cuts, 0, 'drag did not send a paid cut');

  stage = 'click the player tile without paying';
  await click(width / 2, height / 2);
  assert.equal(await evaluate('rendererHoeRequests[6] ?? 0'), 0, 'click on the player did not prepare a payment');
  assert.equal(cuts, 0, 'click on the player did not send a paid cut');

  stage = 'aim from four tiles down and one tile right in the renderer';
  await click(grassX + 32, height / 2 + 4 * 32);
  await expect('distant click aims at the adjacent grass', 'rendererHoeRequests[6] === 1');
  await expect('renderer resolves the cut at 5 msat', 'rendererHoeReplies[7]?.ok && rendererHoeReplies[7].fiveAccepted');
  assert.equal(cuts, 1, 'the grass click sends exactly one paid cut');
  assert.equal(swaps, 1, 'the grass click uses the channel without another mint swap');
  await send('Page.removeScriptToEvaluateOnNewDocument', {identifier});
}

async function run() {
  const env = {...process.env, HOME:directory, XDG_CONFIG_HOME:join(directory, 'config'), XDG_DATA_HOME:join(directory, 'data'), TMPDIR:directory};
  await Promise.all([mkdir(env.XDG_CONFIG_HOME), mkdir(env.XDG_DATA_HOME)]);
  abort.signal.throwIfAborted();
  const mintEnv = {...env, BROWSER_TEST_PORT:'18787'};
  delete mintEnv.BROWSER_TEST_PAYMENT_GATE;
  const mint = child(mintExe, [assets], mintEnv, 'fake mint');
  const ready = new Promise(resolve => {
    let tail = '';
    mint.process.stdout.on('data', chunk => {
      tail = (tail + chunk).slice(-4096);
      if (tail.includes(`Local fake mint ready: ${mintOrigin}/ (TEST FUNDS ONLY)`)) resolve();
    });
  });
  await bounded(Promise.race([ready, mint.done]), 30000, 'fake mint readiness');
  abort.signal.throwIfAborted();
  async function startServer(mode) {
    abort.signal.throwIfAborted();
    const server = child(serverExe, ['4194304', '65536', mode], env, 'native fixture server');
    server.process.stdout.resume();
    const ready = async () => {
      while (!(await listening(gamePort))) await sleep(50, undefined, {signal:abort.signal});
    };
    await bounded(Promise.race([ready(), server.done, mint.done]), 15000, 'native fixture readiness');
    abort.signal.throwIfAborted();
    return server.process;
  }
  const server = await startServer('provision');
  stage = 'launch Chromium';
  const flags = ['--disable-background-networking'];
  if (renderer || rendererResume) flags.push('--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader');
  const browser = launchBrowser(join(directory, 'chromium'), flags);
  children.push(browser);
  const endpoint = await bounded(discoverEndpoint(browser), 10000, 'Chromium readiness');
  browser.stderr.resume();
  abort.signal.throwIfAborted();
  cdp = await CdpConnection.connect(endpoint);
  if (abort.signal.aborted) { cdp.close(); abort.signal.throwIfAborted(); }
  let {targetId} = await cdp.send('Target.createTarget', {url:'about:blank'});
  async function attachPage() {
    ({sessionId:session} = await cdp.send('Target.attachToTarget', {targetId, flatten:true}));
    await send('Page.enable');
    await send('Network.enable', {maxPostDataSize:0});
  }
  await attachPage();
  const recoveryQueries = [];
  cdp.on('Network.requestWillBeSent', ({sessionId, params:{request}}) => {
    if (sessionId !== session || request.method !== 'POST') return;
    if (request.url === `${mintOrigin}/v1/swap`) swaps++;
    // Pending setup sends also check proof state on wallet startup. The change
    // scenario measures NUT-07 around inspect, after startup has finished.
    if (!changeRecovery && request.url === `${mintOrigin}/v1/checkstate`) recoveryQueries.push('NUT-07');
    if (request.url === `${mintOrigin}/v1/restore`) recoveryQueries.push('NUT-09');
  });
  if (fundingResume) {
    cdp.on('Network.responseReceived', ({sessionId, params:{response}}) => {
      if (sessionId === session && response.url === `${mintOrigin}/v1/swap` && response.status === 200) mintSwapSuccesses++;
    });
  }
  cdp.on('Network.webSocketFrameSent', ({sessionId, params:{response}}) => {
    // CDP sends binary frame payloads as base64. Count the opcode, never log the payload.
    if (sessionId !== session || response.opcode !== 2) return;
    const opcode = Buffer.from(response.payloadData, 'base64')[0];
    if (opcode === 0x01) cuts++;
    if (opcode === 0x24) opens++;
    if (opcode === 0x21) requirementsRequests++;
  });

  stage = 'bootstrap wallet and native player';
  await load();
  const flow = options => evaluate(`(${pageFlow})(${JSON.stringify({changeRecovery, tools:toolsFixture, ...options})})`);
  assert.equal(await flow({phase:'bootstrap', smoke}), true);
  if (changeRecovery) {
    assert.equal(swaps, 0, 'fixture setup sets aside exact denominations without swapping');

  }

  stage = 'position isolated fixture player';
  assert(await stopBrowser(server), 'Could not stop owned fixture server');
  assert.equal(server.exitCode, 0, 'Fixture server must flush the newly authenticated player on shutdown');
  // Spawn is randomized. The real server creates the schema and player row;
  // move that one row offline next to known terrain, without modifying world or ledger.
  const db = new DatabaseSync(join(env.XDG_DATA_HOME, 'haystack-server/game.sqlite'));
  try {
    assert.equal(db.prepare('UPDATE game_users SET x = ?, y = ?').run(...(toolsFixture?.start ?? [0, 0])).changes, 1);
  } finally { db.close(); }
  await startServer('existing');

  if (toolsFixture) {
    stage = 'fund both tools, reject mismatches and harvest the tree';
    await load(true);
    const toolChannels = await flow({phase:'tools', smoke});
    assert.equal(swaps, 2, 'one browser mint swap per one-use channel');
    assert.equal(opens, 2, 'one native open per tool');
    assert.equal(cuts, 3, 'one wrong tool, one wrong channel, and one charged axe cut');
    stage = 'restore distinct tool bindings and harvest the rock after reload';
    await load(true);
    assert.equal(await flow({phase:'tools-reconnect', toolChannels}), true);
    assert.equal(swaps, 2, 'reconnect and pickaxe harvest must not swap');
    assert.equal(opens, 2, 'reconnect must not reopen either channel');
    assert.equal(cuts, 4, 'only one more cut after reconnect');
    console.log('ok - axe (2 msat) and pickaxe (10 msat): mismatches not charged, independent depletion and settlement, restored auth bindings, and movement onto both harvested tiles');
    return;
  }

  if (renderer) {
    let areaReady = false;
    cdp.on('Network.webSocketFrameReceived', ({sessionId, params:{response}}) => {
      if (!areaReady && sessionId === session && response.opcode === 2) {
        areaReady = containsUncutFixtureGrass(Buffer.from(response.payloadData, 'base64'));
      }
    });
    await rendererFlow(() => areaReady);
    stage = 'verify durable renderer result and native world';
    await load();
    assert.equal(await flow({phase:'renderer-verify'}), true);
    assert.equal(swaps, 1, 'readback must not swap');
    assert.equal(cuts, 1, 'readback must not send a cut');
    console.log('ok - renderer drag did not pay; stationary grass click sent one paid cut that persisted in the wallet and native world');
    return;
  }

  if (fundingRecovery || fundingResume) {
    stage = fundingResume ? 'drop the raw funding request before dispatch' : 'drop the committed raw funding swap response';
    await load(true);
    await send('Fetch.enable', {patterns:[{urlPattern:`${mintOrigin}/v1/swap`, requestStage:fundingResume ? 'Request' : 'Response'}]});
    const dropped = dropSwap(fundingRecovery);
    const [savedOperation] = await Promise.all([flow({phase:'funding-drop'}), dropped]);
    await send('Fetch.disable');
    assert.equal(swaps, 1, 'interrupted funding must attempt exactly one raw swap');
    assert.equal(mintSwapSuccesses, fundingResume ? 0 : 1);
    assert.equal(opens, 0, 'interrupted funding must not send an open frame');
    assert.deepEqual(recoveryQueries, [], 'no recovery queries before reopening');

    if (fundingResume) {
      stage = 'close the interrupted tab and inspect the saved swap in a new tab';
      const oldTarget = targetId;
      ({targetId} = await cdp.send('Target.createTarget', {url:'about:blank'}));
      await cdp.send('Target.closeTarget', {targetId:oldTarget});
      await attachPage();
      if (rendererResume) {
        const channel = await rendererFlow(null, savedOperation);
        stage = 'verify durable renderer resume and native channel';
        await load();
        assert.equal(await flow({phase:'renderer-resume-verify', channel}), true);
        assert.deepEqual(recoveryQueries, ['NUT-07', 'NUT-07'], 'inspect and explicit resume each check inputs; neither restores');
        assert.equal(swaps, 2, 'one blocked request and one explicitly authorized request across both tabs');
        assert.equal(mintSwapSuccesses, 1, 'only the explicit retry succeeded at the mint');
        assert.equal(opens, 1, 'the resumed channel opens exactly once');
        assert.equal(cuts, 0, 'review and resume do not send a cut');
        console.log('ok - real canvas reviewed the saved refill without a swap, then resumed on a separate click; one mint success and one durable native admission and wallet bind');
        return;
      }
      await load();
      const resumeOffer = await flow({phase:'funding-inspect', savedOperation});
      assert.deepEqual(recoveryQueries, ['NUT-07'], 'inspect only checks input state; resume quote does not query the mint');
      assert.equal(swaps, 1, 'inspect and resume quote must not POST a swap');
      assert.equal(mintSwapSuccesses, 0, 'nothing reached the mint swap endpoint before explicit consent');
      assert.equal(opens, 0, 'nothing opened a native channel before explicit consent');

      stage = 'explicitly resume exact saved operation, then open and bind';
      assert.equal(await flow({phase:'funding-resume', resumeOffer}), resumeOffer.channel);
      assert.deepEqual(recoveryQueries, ['NUT-07', 'NUT-07'], 'explicit resume rechecks unspent inputs before submitting');
      assert.equal(swaps, 2, 'one blocked request and one authorized request');
      assert.equal(mintSwapSuccesses, 1, 'exactly one swap reached and succeeded at the mint');
      assert.equal(opens, 1, 'the resumed channel opened exactly once');
      assert.equal(cuts, 0);
      console.log('ok - swap dropped before mint; inspect stayed pending after reopening; explicit consent resumed the saved operation, opened and bound with one mint success');
      return;
    }

    stage = 'recover funding with inspect after reload, then open and bind';
    await load(true);
    const channel = await flow({phase:'funding-recover', savedOperation});
    if (changeRecovery) {
      stage = 'verify recovered 14-msat wallet change and binding after another reload';
      await load(true);
      assert.equal(await flow({phase:'funding-change-verify', channel}), true);
    }
    assert.deepEqual(recoveryQueries, changeRecovery ? ['NUT-09'] : ['NUT-07', 'NUT-09'],
      'inspect restores the saved outputs only once');
    assert.equal(swaps, 1, 'recovery must not submit a second swap POST');
    assert.equal(mintSwapSuccesses, 1);
    assert.equal(opens, 1, 'the recovered channel opened exactly once');
    assert.equal(cuts, 0, 'funding recovery must not send a cut');
    console.log(changeRecovery
      ? 'ok - lost swap response recovered ten cuts (50 msat) and 14 msat of ordinary wallet change in one commit; opened and bound with one swap POST'
      : 'ok - committed swap response dropped; inspect recovered via NUT-07 and NUT-09 after reload; channel opened and bound with one swap POST total');
    return;
  }

  stage = 'fund and leave the accepted cut unresolved in the wallet';
  await load(true);
  const channel = await flow({phase:'initial', smoke});
  if (smoke) {
    assert.equal(swaps, 0);
    assert.equal(cuts, 0);
    console.log('ok - Chromium wallet deposit, native authentication, hoe requirements and area (smoke only; no paid cut)');
    return;
  }
  assert.match(channel, /^[0-9a-f]{64}$/);
  assert.equal(swaps, 1, 'expected exactly one browser mint swap for first funding');
  assert.equal(cuts, 1, 'expected exactly one initial cut frame');

  stage = 'reconcile the pending cut after reload';
  await load(true);
  assert.equal(await flow({phase:'recover', channel}), true);
  assert.equal(swaps, 1, 'recovery must not submit a second funding swap');
  assert.equal(cuts, 1, 'recovery must not retransmit the cut');
  console.log('ok - unresolved cut bound to exactly 5 msat from native status after reload; no repeated cut or swap');

  stage = 'reject duplicate, deplete, close, finalize and replace';
  await load(true);
  const replacement = await flow({phase:'replace', channel});
  assert.match(replacement, /^[0-9a-f]{64}$/);
  assert.notEqual(replacement, channel);
  assert.equal(cuts, 3, 'expected two charged cuts and one rejected duplicate frame overall');
  assert.equal(swaps, 2, 'expected exactly two browser mint swaps, one per funding');
  console.log('ok - duplicate not charged; first channel depleted, settled and finalized; distinct second channel admitted and bound');
}

const interrupt = signal => abort.abort(new Error(`Interrupted (${signal})`));
process.on('SIGINT', interrupt);
process.on('SIGTERM', interrupt);
const interrupted = new Promise((_, reject) => abort.signal.addEventListener('abort', () => reject(abort.signal.reason), {once:true}));
try {
  await bounded(Promise.race([run(), interrupted]), 100000, 'paid hoe browser integration');
} catch (error) {
  // Do not print CDP exception details; these calls transit synthetic wallet material.
  const detail = cdp && session && await bounded(evaluate(
    '({step: window.paidHoeStep, diagnostic: window.paidHoeDiagnostic})',
  ), 500, 'browser diagnostic').catch(() => null);
  console.error(`FAIL - ${stage}${detail?.step ? ` / ${detail.step}` : ''}: ${error.message}${detail?.diagnostic ? ` (${detail.diagnostic})` : ''}; browser mint swap attempts: ${swaps}; observed interrupted/resumed mint successes: ${mintSwapSuccesses}; open frames: ${opens}; cut frames: ${cuts}`);
  process.exitCode = 1;
} finally {
  abort.abort();
  cdp?.close();
  for (const child of children.reverse()) {
    if (child.pid && child.exitCode === null && child.signalCode === null && !(await stopBrowser(child))) {
      console.error('FAIL - an owned fixture process did not exit');
      process.exitCode = 1;
    }
  }
  await removeProfile(directory);
  process.off('SIGINT', interrupt);
  process.off('SIGTERM', interrupt);
}
