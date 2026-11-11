// Document-destruction recovery scenarios driven by browser/test.mjs.
//
// Every function runs in the current document. The Node runner starts an
// operation, waits for the requested fault boundary, then navigates away
// without a graceful wallet close. The next document re-imports this module and
// inspects the persisted wallet after startup recovery.
import {open_wallet} from "./wallet/cdk_wallet_browser.js";
import {installSwapFaults} from "./test-faults.js";

const faults = installSwapFaults();
const MINT = location.origin;
const walletKey = name => `cdk_wallet_browser_v1_${name}`;
const sumBalances = balances => balances.reduce((total, entry) => total + Number(entry.sats), 0);

const json = async (operation, args = []) => {
  try {
    return await walletApp.call(operation, args);
  } catch (error) {
    throw new Error(`${operation} [${args.map(value => typeof value).join(",")}]: ${error.message || error}`);
  }
};
const must = async (operation, args = []) => {
  const response = await json(operation, args);
  if (response.status !== 0) {
    throw new Error(`${operation} failed (status ${response.status}): ${response.error || "no error message"}`);
  }
  return response;
};
const parseSeed = hex => Uint8Array.from(hex.match(/../g), byte => parseInt(byte, 16));
const openApp = async (name, seedHex) => {
  const seed = parseSeed(seedHex);
  try { return await walletApp.open(seed, name); } finally { seed.fill(0); }
};
const addMint = async () => {
  const response = await must("add_mint", [MINT]);
  return response;
};
const fund = async () => {
  await addMint();
  const token = await fetch("/test-token").then(response => {
    if (!response.ok) throw new Error("Local fake mint is required for recovery tests");
    return response.json();
  });
  const receipt = await must("receive", [token.token]);
  if (receipt.net_sats !== "100") throw new Error(`unexpected funding amount ${receipt.net_sats}`);
};
const currentBalance = async () => {
  const balances = await must("list_balances");
  return balances.balances.reduce((total, entry) => total + Number(entry.sats), 0);
};
const unspentOneCount = name => {
  const raw = localStorage.getItem(walletKey(name));
  const state = raw ? JSON.parse(raw) : {};
  return Object.values(state.proofs || {})
    .filter(proof => proof.state === "UNSPENT" && proof.proof.amount === 1).length;
};
// Move the four 1-sat refill proofs to a sink wallet so an odd 37-sat send
// cannot be composed directly and must perform an online /v1/swap.
async function shapeForSwap(name, seedHex) {
  const ones = unspentOneCount(name);
  if (ones !== 4) throw new Error(`expected four 1-sat proofs for shaping, found ${ones}`);
  const drained = [];
  for (let index = 0; index < ones; index += 1) {
    drained.push(await must("send", [MINT, "1", "0"]));
  }
  const sinkName = `${name.slice(0, name.lastIndexOf("-"))}-sink`;
  const sinkSeed = parseSeed(seedHex);
  for (let index = 0; index < sinkSeed.length; index += 1) sinkSeed[index] ^= 0x5a;
  let sink;
  try {
    sink = await open_wallet(sinkSeed, sinkName);
    const call = async (operation, args = []) => {
      let raw;
      try { raw = await sink.call(operation, JSON.stringify(args)); }
      catch (error) { throw new Error(`sink ${operation}: ${error.message || error}`); }
      const response = JSON.parse(raw);
      if (response.status !== 0) throw new Error(`sink ${operation} failed (status ${response.status})`);
      return response;
    };
    await call("add_mint", [MINT]);
    for (const token of drained) await call("receive", [token.token]);
  } finally {
    if (sink) { try { await sink.close(); } catch {} try { sink.free(); } catch {} }
    sinkSeed.fill(0);
  }
  // The drained sends are now claimed, so recovery clears their sagas.
  await must("recover");
  const shaped = await currentBalance();
  if (shaped !== 96) throw new Error(`expected 96 sats after shaping, got ${shaped}`);
  return {sinkName, drained: ones, expected: shaped};
}

async function waitForFault(armed, boundary) {
  if (boundary === "fired") await armed.fired;
  else await armed.committed;
  const stats = faults.stats();
  if (stats.fired !== 1 || stats.armed) {
    throw new Error(`expected exactly one consumed /v1/swap fault, got ${JSON.stringify(stats)}`);
  }
}

export async function startSendBeforeRequest(name, seedHex) {
  await openApp(name, seedHex);
  await fund();
  const shaped = await shapeForSwap(name, seedHex);
  const armed = faults.arm("before");
  const pending = walletApp.call("send", [MINT, "37", "0"]);
  pending.catch(() => {});
  await waitForFault(armed, "fired");
  return {fired: true, sinkName: shaped.sinkName, expected: shaped.expected};
}

export async function startReceiveBeforeRequest(name, seedHex) {
  await openApp(name, seedHex);
  await addMint();
  const token = await fetch("/test-token").then(response => response.json());
  const armed = faults.arm("before");
  const pending = walletApp.call("receive", [token.token]);
  pending.catch(() => {});
  await waitForFault(armed, "fired");
  return {fired: true};
}

export async function startSendAfterCommitHold(name, seedHex) {
  await openApp(name, seedHex);
  await fund();
  const shaped = await shapeForSwap(name, seedHex);
  const armed = faults.arm("hold");
  const pending = walletApp.call("send", [MINT, "37", "0"]);
  pending.catch(() => {});
  await waitForFault(armed, "committed");
  return {committed: true, sinkName: shaped.sinkName, expected: shaped.expected};
}

export async function startReceiveAfterCommitHold(name, seedHex) {
  await openApp(name, seedHex);
  await addMint();
  const token = await fetch("/test-token").then(response => response.json());
  const armed = faults.arm("hold");
  const pending = walletApp.call("receive", [token.token]);
  pending.catch(() => {});
  await waitForFault(armed, "committed");
  return {committed: true};
}

// Start a successful local send, but hold delivery of the resolved JS result.
// The token-bearing TokenCreated saga is already persisted when this returns.
export async function startSendBeforeDelivery(name, seedHex) {
  await openApp(name, seedHex);
  await fund();
  const original = walletApp.call;
  let releaseUnderlying;
  const underlying = new Promise(resolve => { releaseUnderlying = resolve; });
  walletApp.call = function(operation, args) {
    const pending = original.call(walletApp, operation, args);
    if (operation !== "send") return pending;
    pending.then(() => releaseUnderlying(), () => releaseUnderlying());
    return new Promise(() => {});
  };
  const held = walletApp.call("send", [MINT, "37", "0"]);
  held.catch(() => {});
  await underlying;
  return {delivered: false};
}

export async function inspectWallet(name, seedHex) {
  const startup = await openApp(name, seedHex);
  const balances = await must("list_balances");
  const pending = await must("list_pending_tokens");
  return {
    startup,
    mint: MINT,
    sats: sumBalances(balances.balances),
    pending,
  };
}

export async function recoverWallet() {
  const recovery = await must("recover");
  const balances = await must("list_balances");
  const pending = await must("list_pending_tokens");
  return {
    reports: recovery.reports,
    sats: sumBalances(balances.balances),
    pending,
  };
}

export async function sendFromApp(amount) {
  return await must("send", [MINT, String(amount), "0"]);
}

const recoverClean = async label => {
  const response = await must("recover");
  if(!response.reports.some(report => report.mint_url === MINT)) throw new Error(`${label}: recovery report is missing the mint`);
  if(!response.reports.every(report => report.failed === 0 && report.skipped === 0)) throw new Error(`${label}: recovery reported a failure: ${JSON.stringify(response.reports)}`);
  return response;
};

// Redeem the entire spendable balance into a fresh wallet, then show the send
// saga is cleaned by repeated recovery. Returns source/recipient totals.
export async function spendAllFromApp(recipientName, seedHex) {
  const before = await currentBalance();
  if(before === 0) throw new Error("cannot prove spendability of an empty wallet");
  const sent = await must("send", [MINT, String(before), "0"]);
  const received = await redeemToken(recipientName, seedHex, sent.token);
  const after = await currentBalance();
  await recoverClean("spend recovered proofs");
  const recovered = await currentBalance();
  await recoverClean("repeated spend recovery");
  const repeat = await currentBalance();
  return {before, net_sats: received.net_sats, after, recovered, repeat};
}

export async function trySend(amount) {
  const response = await json("send", [MINT, String(amount), "0"]);
  return response.status;
}

export async function closeWallet() {
  await walletApp.close();
}

export async function redeemToken(recipientName, seedHex, token) {
  const seed = parseSeed(seedHex);
  let wallet;
  try {
    wallet = await open_wallet(seed, recipientName);
    const call = async (operation, args = []) => {
      let raw;
      try { raw = await wallet.call(operation, JSON.stringify(args)); }
      catch (error) { throw new Error(`recipient ${operation}: ${error.message || error}`); }
      const response = JSON.parse(raw);
      if (response.status !== 0) throw new Error(`recipient ${operation} failed (status ${response.status})`);
      return response;
    };
    await call("add_mint", [MINT]);
    return await call("receive", [token]);
  } finally {
    if (wallet) { try { await wallet.close(); } catch {} try { wallet.free(); } catch {} }
    seed.fill(0);
  }
}

// Like redeemToken, but returns the receive response instead of throwing on a
// status-level failure. Wallet open and add_mint are setup steps and still
// throw, so an unexpected setup/transport failure cannot masquerade as the
// expected already-spent result.
export async function redeemTokenResult(recipientName, seedHex, token) {
  const seed = parseSeed(seedHex);
  let wallet;
  try {
    wallet = await open_wallet(seed, recipientName);
    const call = async (operation, args = []) => {
      let raw;
      try { raw = await wallet.call(operation, JSON.stringify(args)); }
      catch (error) { throw new Error(`recipient ${operation}: ${error.message || error}`); }
      return JSON.parse(raw);
    };
    const mint = await call("add_mint", [MINT]);
    if (mint.status !== 0) throw new Error(`recipient add_mint failed (status ${mint.status})`);
    return await call("receive", [token]);
  } finally {
    if (wallet) { try { await wallet.close(); } catch {} try { wallet.free(); } catch {} }
    seed.fill(0);
  }
}

export function removeWallet(name) {
  localStorage.removeItem(walletKey(name));
}

