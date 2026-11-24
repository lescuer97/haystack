// Start browser-test-mint with the browser-fixture wasm-test directory, then run:
// node browser/hoe-settlement-browser-test.mjs http://127.0.0.1:18787
import {bounded, CdpConnection, discoverEndpoint, launchBrowser, makeProfile, removeProfile, stopBrowser} from './cdp-runner.mjs';

async function settlementPreflight() {
  const check = (ok, message) => {
    if (!ok) throw Object.assign(new Error(message), {name:'HoeFixtureAssertion'});
  };
  const wasm = await import('/wallet/cdk_wallet_browser.js');
  await wasm.default();
  const mint = wasm.onboarding_mint();
  check(mint === location.origin, 'expected the local-mint Wasm fixture');
  const name = 'haystack-user';
  await wasm.provision_wallet('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about', name);
  const service = await wasm.start_onboarding(mint);
  let wallet, signer;
  const ok = (reply, op) => {
    const value = JSON.parse(reply);
    check(value.status === 0, `${op} failed (status ${value.status})`);
    return value;
  };
  const call = async (op, ...args) => ok(await wallet.call(op, JSON.stringify(args)), op);
  const hoeReply = async (op, ...args) => wallet.hoe_request(op, JSON.stringify(args));
  const hoe = async (op, ...args) => ok(await hoeReply(op, ...args), op);
  const pure = (op, ...args) => ok(wasm.call_pure(op, JSON.stringify(args)), op);
  const balance = async () => JSON.parse((await call('wallet_screen', mint)).value).msats;
  const snapshot = async () => {
    const result = request => new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(new Error('could not read wallet state'));
    });
    const open = indexedDB.open('haystack-wallet');
    open.onupgradeneeded = () => open.transaction.abort();
    const db = await result(open);
    try { return await result(db.transaction('states').objectStore('states').get(name)); }
    finally { db.close(); }
  };
  const deposit = async amount => {
    const {id} = JSON.parse((await call('create_deposit', mint, amount)).value);
    const deadline = performance.now() + 12000;
    do {
      if (JSON.parse((await call('check_deposit', mint, id)).value).state === 'ISSUED') return;
      await new Promise(resolve => setTimeout(resolve, 100));
    } while (performance.now() < deadline);
    throw new Error('fixture deposit was not issued');
  };
  const price = 4;
  const twoCuts = String(2 * price);
  const withdrawalBalance = 32;
  const depositWithChange = String(withdrawalBalance + price);
  try {
    signer = await service.open_game_signer();
    wallet = await service.open_ready_wallet();
    await call('add_mint', mint);
    await deposit(twoCuts);
    const player = Array.from(signer.sign(new Uint8Array(32), new Uint8Array(32)).subarray(0, 33),
      byte => byte.toString(16).padStart(2, '0')).join('');
    const scope = 'settlement-preflight-fixture';
    const terms = [scope, pure('spilman_generate_keypair').pubkey_hex, String(price), String(Math.floor(Date.now() / 1000) + 600), player];
    const quote = await hoe('quote', ...terms);
    const {channel_id: channel, capacity_msats: capacity} = await hoe('fund', quote.quote_id, ...terms);
    check(capacity === twoCuts, 'expected a two-cut channel');
    await hoe('bind', scope, channel, capacity, '0');
    await hoe('prepare_cut', scope, channel, '01'.repeat(16));

    // Use real, unspent mint proofs; the fixture isolates wallet finalization,
    // not the native server's construction of conditional sender change.
    await deposit(depositWithChange);
    const {token} = await call('send', mint, String(price), '0');
    const keyset = (await call('get_active_keyset_info_json', mint)).value;
    const proofs = pure('token_to_proofs_json', token, keyset).value;
    check(await balance() === String(withdrawalBalance), 'fixture leaves the expected balance before withdrawal');
    const invoice = await fetch('/test-withdrawal-invoice?msats=21');
    check(invoice.ok, 'fixture withdrawal invoice unavailable');
    const review = JSON.parse((await call('prepare_withdrawal', mint, (await invoice.json()).invoice)).value);
    const before = await snapshot();
    const swaps = () => performance.getEntriesByName(`${mint}/v1/swap`).length;
    const beforePreflight = swaps();
    const finalize = [scope, channel, capacity, String(price), proofs];
    const blocked = JSON.parse(await hoeReply('finalize', ...finalize));
    check(blocked.status === 19 && blocked.error === 'hoe_settlement_preflight: cancel or confirm the active withdrawal review first',
      'finalize must reach and return the real withdrawal preflight rejection');
    const after = await snapshot();
    check(after.revision === before.revision && after.data === before.data,
      'preflight rejection must not write an unknown receipt, change the pending cut, or release funding');
    check(swaps() === beforePreflight, 'preflight rejection must not start a mint swap');

    const cancel = JSON.parse((await call('cancel_withdrawal', mint, review.operation_id)).value);
    check(cancel.cancelled === true && await balance() === String(withdrawalBalance), 'cancellation restores the original spendable balance');
    const beforeRetry = swaps();
    await hoe('finalize', ...finalize);
    check(swaps() === beforeRetry + 1, 'retry performs exactly one mint swap');
    check((await hoe('inspect', scope)).channel_id === null, 'retry releases the funding slot');
    check(await balance() === depositWithChange, `retry credits exactly ${price} msat`);
    const completed = await snapshot();
    const receipt = JSON.parse(new TextDecoder().decode(Uint8Array.from(JSON.parse(completed.data).kv['browser_hoe\x1f\x1fpayment_v1'])));
    check(receipt.balance === price && receipt.pending === null && receipt.receipt?.net === price,
      'retry reconciles the pending cut and persists the completed credit receipt');
    return true;
  } finally {
    signer?.free();
    if (wallet) { await wallet.close(); wallet.free(); }
    await service.close();
    service.free();
  }
}

const origin = new URL(process.argv[2]);
if (origin.protocol !== 'http:' || origin.hostname !== '127.0.0.1' || !origin.port) throw new Error('Local mint fixture required');
const profile = await makeProfile('haystack-hoe-settlement-');
const browser = launchBrowser(profile);
let cdp;
async function run() {
  cdp = await CdpConnection.connect(await discoverEndpoint(browser));
  const {targetId} = await cdp.send('Target.createTarget', {url:'about:blank'});
  const {sessionId} = await cdp.send('Target.attachToTarget', {targetId, flatten:true});
  const send = (method, args = {}) => cdp.send(method, args, sessionId);
  await send('Page.enable');
  const loaded = cdp.once('Page.loadEventFired', sessionId);
  await send('Page.navigate', {url:new URL('/test-withdrawal-counts', origin).href});
  await loaded;
  const {result} = await send('Runtime.evaluate', {
    expression:`(${settlementPreflight})().catch(error => error?.name === 'HoeFixtureAssertion' ? error.message : 'unexpected fixture error')`,
    awaitPromise:true, returnByValue:true,
  });
  if (result?.value !== true) throw new Error(result?.value || 'settlement fixture evaluation failed');
  console.log('ok - withdrawal preflight leaves no receipt; identical settlement credits after cancel');
}
try { await bounded(run(), 45000, 'hoe settlement fixture'); }
finally {
  cdp?.close();
  await stopBrowser(browser);
  await removeProfile(profile);
}
