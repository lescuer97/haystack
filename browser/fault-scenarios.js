// In-page browser fault and recovery scenarios.
//
// Each scenario runs against the live local fake mint with the test-only fetch
// fault wrapper installed. Wallets, seeds, and tokens are fresh per scenario and
// are kept in this function scope; only the wallet database persists anything.
import {open_wallet} from "./wallet/cdk_wallet_browser.js";
import {createWallet, deleteWallet, readWallet} from "./test-wallet.js";

const sumBalances = balances => balances.reduce((total, entry) => total + Number(entry.sats), 0);

export async function runFaultScenarios({assert, faults, recordFailure}) {
  const mint = location.origin;
  const suffix = crypto.randomUUID().replaceAll("-", "");
  const names = [];
  const seeds = [];
  const wallets = [];
  let walletCount = 0;
  const json = async (wallet, operation, args = []) =>
    JSON.parse(await wallet.call(operation, JSON.stringify(args)));
  const must = async (wallet, operation, args = []) => {
    const response = await json(wallet, operation, args);
    if (response.status !== 0) {
      throw new Error(`${operation} failed (status ${response.status}): ${response.error || "no error message"}`);
    }
    return response;
  };
  const open = async () => {
    const name = `fault-${++walletCount}-${suffix}`;
    names.push(name);
    const seed = await createWallet(name);
    seeds.push(seed);
    const wallet = await open_wallet(seed, name);
    wallet.__testName = name;
    wallets.push(wallet);
    return wallet;
  };
  const unspentAmounts = async wallet => {
    const {state} = await readWallet(wallet.__testName);
    const record = state ? JSON.parse(state.data) : {};
    return Object.values(record.proofs || {})
      .filter(proof => proof.state === "UNSPENT")
      .map(proof => proof.proof.amount);
  };
  // CDK's receive refill leaves four 1-sat proofs. Spending them locally makes
  // an odd amount like 37 impossible to compose from the remaining even
  // denominations, so the send must perform an online swap.
  const shapeForSwap = async (wallet, label) => {
    const ones = (await unspentAmounts(wallet)).filter(amount => amount === 1).length;
    assert(ones === 4, `${label}: funding produces four 1-sat proofs`);
    const drained = [];
    for (let index = 0; index < ones; index += 1) {
      drained.push(await must(wallet, "send", [mint, "1", "0"]));
    }
    const sink = await open();
    await must(sink, "add_mint", [mint]);
    for (const token of drained) await must(sink, "receive", [token.token]);
    await recover(wallet, `${label} shaping cleanup`);
    assert(await balance(wallet) === 100 - ones, `${label}: shaped wallet holds ${100 - ones} sats`);
    return {sink, drained: ones};
  };
  const newToken = () => fetch("/test-token").then(response => {
    if (!response.ok) throw new Error("Local fake mint is required for fault tests");
    return response.json();
  });
  const balance = async wallet => sumBalances((await must(wallet, "list_balances")).balances);
  const spendAll = async (wallet, label) => {
    const before = await balance(wallet);
    assert(before > 0, `${label}: wallet has a recoverable balance`);
    const sent = await must(wallet, "send", [mint, String(before), "0"]);
    const recipient = await open();
    await must(recipient, "add_mint", [mint]);
    const received = await must(recipient, "receive", [sent.token]);
    assert(received.net_sats === String(before), `${label}: full recovered balance redeems into a fresh wallet`);
    assert(await balance(wallet) === 0, `${label}: source wallet is emptied by the full send`);
    assert(await balance(recipient) === before, `${label}: recipient holds the full recovered balance`);
    await recover(wallet, `${label} spend cleanup`);
    assert(await balance(wallet) === 0, `${label}: source stays empty after spend recovery`);
    await recover(wallet, `${label} spend cleanup`);
    assert(await balance(wallet) === 0, `${label}: repeated spend recovery is stable`);
  };
  const start = (wallet, operation, args) => {
    const pending = wallet.call(operation, JSON.stringify(args));
    // Attach immediately so an interrupted operation never becomes an
    // unhandled rejection if the test later destroys the document.
    pending.catch(() => {});
    return pending;
  };
  // Fail loudly if an operation never reaches /v1/swap instead of hanging.
  const awaitCommit = async (armed, pending, label) => {
    const outcome = await Promise.race([
      armed.committed.then(() => ({committed: true})),
      pending.then(result => ({result})),
    ]);
    if (!outcome.committed) {
      let status = "unparsed";
      try {
        const raw = typeof outcome.result === "string" ? JSON.parse(outcome.result) : outcome.result;
        status = raw && raw.status;
      } catch {}
      throw new Error(`${label}: operation did not reach /v1/swap (status ${status})`);
    }
  };
  const recover = async (wallet, label) => {
    const response = await must(wallet, "recover");
    assert(response.reports.some(report => report.mint_url === mint), `${label}: recovery reports the live mint`);
    assert(response.reports.every(report => report.failed === 0 && report.skipped === 0),
      `${label}: recovery has no failed or skipped mints`);
    return response;
  };
  const gated = async (wallet, label) => {
    const send = await json(wallet, "send", [mint, "1", "0"]);
    assert(send.status === 19, `${label}: send is gated by RecoveryPending`);
    const token = (await newToken()).token;
    const receive = await json(wallet, "receive", [token]);
    assert(receive.status === 19, `${label}: receive is gated by RecoveryPending`);
    const swap = await json(wallet, "post_swap", [mint, "{}"]);
    assert(swap.status === 19, `${label}: post_swap is gated by RecoveryPending`);
  };
  const expectOneFault = (label, before) => {
    const after = faults.stats();
    assert(after.fired === before.fired + 1, `${label}: the injected fault fired exactly once`);
    assert(after.committed === before.committed + 1, `${label}: the mint committed the swap before the fault`);
    assert(!after.armed, `${label}: the fault is disarmed after one use`);
  };
  const fund = async (wallet, label) => {
    await must(wallet, "add_mint", [mint]);
    const receipt = await must(wallet, "receive", [(await newToken()).token]);
    assert(receipt.net_sats === "100", `${label}: wallet is funded with 100 test sats`);
  };

  try {
    // --- Receive: malformed response after the mint committed ---------------
    {
      const wallet = await open("receive-malformed");
      await must(wallet, "add_mint", [mint]);
      const before = faults.stats();
      const armed = faults.arm("malformed");
      const pending = start(wallet, "receive", [(await newToken()).token]);
      await awaitCommit(armed, pending, "Malformed receive");
      const result = JSON.parse(await pending);
      assert(result.status !== 0, "Malformed receive response fails");
      expectOneFault("Malformed receive", before);
      assert(await balance(wallet) === 0, "Malformed receive does not credit a premature balance");
      await gated(wallet, "Malformed receive");
      await recover(wallet, "Malformed receive");
      assert(await balance(wallet) === 100, "Recovery credits the malformed receive exactly once");
      await recover(wallet, "Malformed receive");
      assert(await balance(wallet) === 100, "Repeated malformed-receive recovery is unchanged");
      assert((await must(wallet, "list_pending_tokens")).pending.length === 0,
        "Malformed receive leaves no pending token");

      await spendAll(wallet, "Malformed receive");
    }

    // --- Receive: dropped response after the mint committed -----------------
    {
      const wallet = await open("receive-dropped");
      await must(wallet, "add_mint", [mint]);
      const before = faults.stats();
      const armed = faults.arm("reject");
      const pending = start(wallet, "receive", [(await newToken()).token]);
      await awaitCommit(armed, pending, "Dropped receive");
      const result = JSON.parse(await pending);
      assert(result.status !== 0, "Dropped receive response fails ambiguously");
      expectOneFault("Dropped receive", before);
      assert(await balance(wallet) === 0, "Dropped receive does not credit a premature balance");
      await gated(wallet, "Dropped receive");
      await recover(wallet, "Dropped receive");
      assert(await balance(wallet) === 100, "Recovery credits the dropped receive exactly once");
      await recover(wallet, "Dropped receive");
      assert(await balance(wallet) === 100, "Repeated dropped-receive recovery is unchanged");
      await spendAll(wallet, "Dropped receive");
    }

    // --- Send: dropped response after the swap committed --------------------
    //
    // The wallet is shaped to 96 sats first (four 1-sat refill proofs moved to
    // a sink) so the 37-sat send must perform an online swap. The mint commits
    // the swap and the response is rejected.
    //
    // CDK's nested send-swap saga owns no input proofs, so recovery restores
    // the swap outputs but cannot mark the swap inputs spent. The parent
    // ProofsReserved send compensation then releases those already-spent inputs
    // as unspent. The correct post-recovery balance is the pre-send balance;
    // this scenario records a structured failure instead of asserting the
    // observed over-count as success.
    {
      const wallet = await open("send-dropped");
      await fund(wallet, "Send dropped");
      const shaped = await shapeForSwap(wallet, "Send dropped");
      const expected = 100 - shaped.drained;
      const before = faults.stats();
      assert((await must(wallet, "list_pending_tokens")).pending.length === 0,
        "Send dropped: shaping leaves no pending token");
      const armed = faults.arm("reject");
      const pending = start(wallet, "send", [mint, "37", "0"]);
      await awaitCommit(armed, pending, "Dropped send");
      const result = JSON.parse(await pending);
      assert(result.status === 21, "Dropped send response is SendUncertain");
      assert(result.token == null, "Dropped send response carries no success token");
      expectOneFault("Dropped send", before);
      assert((await must(wallet, "list_pending_tokens")).pending.length === 0,
        "Dropped send has no pending token before recovery");
      await gated(wallet, "Dropped send");
      await recover(wallet, "Dropped send");
      const recoveredSend = await balance(wallet);
      const sinkBalance = await balance(shaped.sink);
      assert(sinkBalance === shaped.drained, `Dropped send shaping value remains in the sink wallet (expected ${shaped.drained}, got ${sinkBalance})`);
      if (recoveredSend !== expected) {
        recordFailure({
          scenario: "dropped send after mint commit",
          expected: `${expected} sats restored`,
          actual: `${recoveredSend} sats restored`,
          message: `nested send-swap recovery released already-spent swap inputs as unspent (${recoveredSend - expected} extra sats); recovered value spendability is not established`,
        });
      }
      assert((await must(wallet, "list_pending_tokens")).pending.length === 0,
        "Dropped send recovery leaves no pending token");
      const firstRecoveryBalance = recoveredSend;
      await recover(wallet, "Dropped send");
      assert(await balance(wallet) === firstRecoveryBalance,
        "Repeated dropped-send recovery does not change the observed balance");
      if (recoveredSend === expected) {
        await spendAll(wallet, "Dropped send");
      }
    }

    // --- Receive: response held after commit until the network deadline -----
    {
      const wallet = await open("receive-held");
      await must(wallet, "add_mint", [mint]);
      const before = faults.stats();
      const armed = faults.arm("hold");
      const pending = start(wallet, "receive", [(await newToken()).token]);
      await awaitCommit(armed, pending, "Held receive");
      const result = JSON.parse(await pending);
      assert(result.status === 13, "Held receive response times out as NetworkError");
      expectOneFault("Held receive", before);
      assert(await balance(wallet) === 0, "Held receive does not credit a premature balance");
      await gated(wallet, "Held receive");
      await recover(wallet, "Held receive");
      assert(await balance(wallet) === 100, "Recovery credits the held receive exactly once");
      await recover(wallet, "Held receive");
      assert(await balance(wallet) === 100, "Repeated held-receive recovery is unchanged");
      await spendAll(wallet, "Held receive");
    }
  } finally {
    for (const wallet of wallets) {
      try { await wallet.close(); } catch {}
      try { wallet.free(); } catch {}
    }
    for (const name of names) {
      // Each disposable wallet is deleted (and its deletion verified) after all
      // handles are closed. Only this scenario's generated names are touched.
      await deleteWallet(name);
    }
    for (const seed of seeds) seed.fill(0);
  }
}
