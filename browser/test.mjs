// Dependency-free, event-driven Chromium/CDP runner. Start the local fake mint
// first; this exits nonzero on failed checks, browser errors, or timeout.
//
// Known production defects are reported in `failures` as structured entries
// (scenario/expected/actual/message) instead of being asserted as successful
// behavior. Their presence makes the run exit nonzero while the remaining
// independent scenarios still execute. Unexpected check failures abort the run.
import {spawn} from "node:child_process";
import {existsSync} from "node:fs";
import {mkdtemp, writeFile, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";

const base=existsSync("/tmp/opencode")? "/tmp/opencode" : tmpdir();
const directory=await mkdtemp(join(base,"cdk-browser-test-"));
const artifacts=await mkdtemp(join(base,"cdk-browser-test-artifacts-"));
const browser=spawn(process.env.CHROMIUM || "chromium",["--headless","--no-sandbox","--use-gl=angle","--use-angle=swiftshader","--enable-unsafe-swiftshader",`--user-data-dir=${directory}`,"--remote-debugging-port=0","about:blank"],{stdio:["ignore","ignore","pipe"]});

// The Python wrapper prints the fake mint's normal application URL (`/?smoke`).
// Wallet checks run on the explicit non-interactive test fixture, while `/` is
// only a redirect to the game. Normalize the input once and reuse the origin.
const inputUrl=process.argv[2] || "http://127.0.0.1:18787/?smoke";
const parsedInput=new URL(inputUrl);
const baseOrigin=parsedInput.origin;
const fixtureUrl=search => {
  const url=new URL("/wallet-test.html",baseOrigin);
  url.search=search===undefined? (parsedInput.search || "?smoke") : `?${search}`;
  return url.href;
};

const result={ok:false,completed:false,checks:[],failures:[],count:0,failureCount:0,uncaughtExceptions:[]};
const addFailure=failure => {
  if(result.failures.some(existing => existing.scenario === failure.scenario && existing.message === failure.message)) return;
  result.failures.push(failure);
};
const randomSeedHex=() => Array.from(crypto.getRandomValues(new Uint8Array(64)),byte => byte.toString(16).padStart(2,"0")).join("");
const seedExpr=hex => `Uint8Array.from(${JSON.stringify(hex)}.match(/../g),byte=>parseInt(byte,16))`;

let socket=null;
let sequence=0;
let activeSession=null;
let exceptions=[];
let dumpProgress=async () => {};
const requests=new Map();
function send(method,params={},sessionId) {
  const id=++sequence;
  return new Promise((resolve,reject) => { requests.set(id,{resolve,reject}); socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})); });
}

const bounded=async (promise,milliseconds,label) => {
  let handle;
  const guarded=Promise.resolve(promise);
  // If the timeout wins, the losing operation must not surface later as an
  // unhandled rejection while the browser is being torn down.
  guarded.catch(() => {});
  try {
    return await Promise.race([
      guarded,
      new Promise((_,reject) => { handle=setTimeout(() => reject(new Error(`${label} timed out`)),milliseconds); }),
    ]);
  } finally {
    clearTimeout(handle);
  }
};

let timeoutReject;
const timeout=new Promise((_,reject) => { timeoutReject=reject; });
const timer=setTimeout(() => timeoutReject(new Error("Browser test timed out")),240_000);
// Test-only hook used to validate that a disconnected/killed browser still
// produces bounded diagnostics, a JSON artifact, and an escalated shutdown.
const killAfter=Number(process.env.BROWSER_TEST_KILL_MS || 0);
const killHook=killAfter>0? setTimeout(() => { try { browser.kill("SIGKILL"); } catch {} },killAfter) : null;

const work=(async () => {
  const endpoint=await new Promise((resolve,reject) => {
    let stderr="";
    browser.stderr.on("data",chunk => { stderr+=chunk; const match=stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/); if(match) resolve(match[1]); });
    browser.on("error",reject);
    browser.on("exit",code => reject(new Error(`Chromium exited: ${code}`)));
  });
  socket=new WebSocket(endpoint);
  await new Promise((resolve,reject) => { socket.onopen=resolve; socket.onerror=reject; });

  let complete;
  let reportReject;
  const report=new Promise((resolve,reject) => { complete=resolve; reportReject=reject; });
  report.catch(() => {});
  const events=new Map();
  const disconnected=() => {
    const error=new Error("CDP connection closed");
    for(const pending of requests.values()) pending.reject(error);
    requests.clear();
    reportReject(error);
  };
  socket.onclose=disconnected;
  socket.onerror=disconnected;
  socket.onmessage=({data}) => {
    const message=JSON.parse(data);
    const key=`${message.sessionId}:${message.method}`;
    if(events.has(key)) { events.get(key)(message.params); events.delete(key); }
    if(message.id) {
      const pending=requests.get(message.id); requests.delete(message.id);
      if(message.error) pending.reject(new Error(message.error.message)); else pending.resolve(message.result);
    }
    if(message.method === "Runtime.bindingCalled" && message.params.name === "reportBrowserTests") complete(JSON.parse(message.params.payload));
    if(message.method === "Runtime.exceptionThrown") {
      exceptions.push(message.params.exceptionDetails.text);
      complete({ok:false,completed:false,error:message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text});
    }
    if(message.method === "Runtime.consoleAPICalled" && message.params.type === "error") console.error(message.params.args.map(v => v.value || v.description).join(" "));
  };
  const once=(method,sessionId) => new Promise(resolve => events.set(`${sessionId}:${method}`,resolve));
  async function evaluate(sessionId,expression) {
    const response=await send("Runtime.evaluate",{expression,awaitPromise:true,returnByValue:true},sessionId);
    if(response.exceptionDetails) throw new Error(response.exceptionDetails.exception?.description || response.exceptionDetails.text);
    return response.result.value;
  }
  dumpProgress=async () => {
    if(!activeSession) return;
    try {
      const progress=await send("Runtime.evaluate",{expression:"window.browserTestProgress",returnByValue:true},activeSession);
      if(Array.isArray(progress.result.value)) {
        result.checks=progress.result.value;
        result.count=result.checks.length;
      }
    } catch {}
  };

  const {targetId}=await send("Target.createTarget",{url:"about:blank"});
  const {sessionId}=await send("Target.attachToTarget",{targetId,flatten:true});
  activeSession=sessionId;
  await send("Runtime.enable",{},sessionId);
  await send("Page.enable",{},sessionId);
  await send("Runtime.addBinding",{name:"reportBrowserTests"},sessionId);
  await send("Page.navigate",{url:fixtureUrl()},sessionId);

  const smoke=await report;
  Object.assign(result,smoke);
  result.checks=Array.isArray(smoke.checks)? smoke.checks.slice() : [];
  result.failures=Array.isArray(smoke.failures)? smoke.failures.slice() : [];
  result.completed=smoke.completed === true;
  result.count=result.checks.length;
  result.failureCount=result.failures.length;
  if(!result.completed) {
    await dumpProgress();
    result.count=result.checks.length;
    return result;
  }

  // Actual separate-tab and document-reload checks, not just two Rust handles.
  const name=`lifecycle-${crypto.randomUUID().replaceAll("-","")}`;
  const lifecycleSeed=randomSeedHex();
  const open=`await walletApp.open(${seedExpr(lifecycleSeed)},${JSON.stringify(name)})`;
  await evaluate(sessionId,`(async()=>{${open}; const r=await walletApp.call("add_mint",[location.origin]);if(r.status)throw new Error("lifecycle mint registration failed");})()`);
  const extra=await send("Target.createTarget",{url:"about:blank"});
  const second=await send("Target.attachToTarget",{targetId:extra.targetId,flatten:true});
  await send("Runtime.enable",{},second.sessionId);
  await send("Page.enable",{},second.sessionId);
  const loaded=once("Page.loadEventFired",second.sessionId);
  await send("Page.navigate",{url:fixtureUrl("lifecycle")},second.sessionId);
  await loaded;
  const rejected=await evaluate(second.sessionId,`(async()=>{await (await import("./app.js")).ready;try{${open};await walletApp.close();return false;}catch{return true;}})()`);
  if(!rejected) throw new Error("Cross-tab exclusive lock failed");
  result.checks.push("A separate browser tab cannot open the same wallet concurrently");
  await evaluate(sessionId,"walletApp.close()");
  const handoff=await evaluate(second.sessionId,`(async()=>{${open};const r=await walletApp.call("list_mints");await walletApp.close();return r.status===0 && r.mints.includes(location.origin);})()`);
  if(!handoff) throw new Error("Cross-tab persistent handoff failed");
  result.checks.push("Wallet state survives handoff to a separate browser tab");
  const reloaded=once("Page.loadEventFired",sessionId);
  await send("Page.navigate",{url:fixtureUrl("reload-check")},sessionId);
  await reloaded;
  const persisted=await evaluate(sessionId,`(async()=>{await (await import("./app.js")).ready;${open};const r=await walletApp.call("list_mints");await walletApp.close();localStorage.removeItem(${JSON.stringify(`cdk_wallet_browser_v1_${name}`)});return r.status===0 && r.mints.includes(location.origin);})()`);
  if(!persisted) throw new Error("Wallet persistence across page reload failed");
  result.checks.push("Wallet storage survives destruction and reload of the Wasm instance");

  // --- Actual document destruction after interrupted operations ----------
  const origin=baseOrigin;
  const q=value => JSON.stringify(value);
  const recoveryName=label => `rec-${label.replace(/[^a-z0-9]/gi,"").slice(0,12)}-${crypto.randomUUID().replaceAll("-","")}`;
  async function openRecoveryPage(suffix) {
    const pageLoaded=once("Page.loadEventFired",sessionId);
    await send("Page.navigate",{url:fixtureUrl(suffix)},sessionId);
    await pageLoaded;
    await evaluate(sessionId,`(async()=>{await (await import("./app.js")).ready;window.recoveryScenarios=await import("./recovery.js");return true;})()`);
  }
  function requireCleanReports(reports,label) {
    if(!Array.isArray(reports) || reports.length === 0) throw new Error(`${label}: empty recovery report`);
    if(!reports.some(report => report.mint_url === origin)) throw new Error(`${label}: recovery report is missing the mint`);
    if(!reports.every(report => report.failed === 0 && report.skipped === 0)) throw new Error(`${label}: recovery reported a failed or skipped mint: ${JSON.stringify(reports)}`);
  }
  const same=(left,right) => JSON.stringify(left) === JSON.stringify(right);
  async function inspect(name,seedHex) {
    return await evaluate(sessionId,`recoveryScenarios.inspectWallet(${q(name)},${q(seedHex)})`);
  }
  async function recoverNow() {
    return await evaluate(sessionId,`recoveryScenarios.recoverWallet()`);
  }
  async function closeAndRemove(name) {
    await evaluate(sessionId,`recoveryScenarios.closeWallet()`);
    await evaluate(sessionId,`recoveryScenarios.removeWallet(${q(name)})`);
  }

  // Send interrupted before its swap request reached the mint. The wallet is
  // shaped to 96 sats so the 37-sat send must attempt an online swap. The
  // required invariants are the pre-send balance at startup, first explicit
  // recovery and repeated recovery, with clean reports and no gating at each
  // step. Observed deviations are structured failures, never accepted values.
  {
    const name=recoveryName("send-before");
    const seedHex=randomSeedHex();
    await openRecoveryPage("recovery-send-before");
    const started=await evaluate(sessionId,`recoveryScenarios.startSendBeforeRequest(${q(name)},${q(seedHex)})`);
    await openRecoveryPage("recovery-send-before-resume");
    const info=await inspect(name,seedHex);
    const startup=info.startup.find(report => report.mint_url === origin);
    if(!startup) throw new Error("Send interrupted before request: startup report is missing the mint");
    if(info.pending.pending.length !== 0) throw new Error("Send interrupted before request left a pending token");
    const first=await recoverNow();
    const firstReport=first.reports.find(report => report.mint_url === origin);
    if(!firstReport) throw new Error("Send interrupted before request: first recovery is missing the mint");
    const repeated=await recoverNow();
    const repeatedReport=repeated.reports.find(report => report.mint_url === origin);
    if(!repeatedReport) throw new Error("Send interrupted before request: repeated recovery is missing the mint");
    const sendStatus=await evaluate(sessionId,`recoveryScenarios.trySend(1)`);
    const expected={
      startupBalance:started.expected, startupFailed:0, startupSkipped:0,
      firstBalance:started.expected, firstFailed:0, firstSkipped:0,
      repeatedBalance:started.expected, repeatedFailed:0, repeatedSkipped:0,
      sendStatus:0,
    };
    const actual={
      startupBalance:info.sats, startupFailed:startup.failed, startupSkipped:startup.skipped,
      firstBalance:first.sats, firstFailed:firstReport.failed, firstSkipped:firstReport.skipped,
      repeatedBalance:repeated.sats, repeatedFailed:repeatedReport.failed, repeatedSkipped:repeatedReport.skipped,
      sendStatus,
    };
    if(!same(expected,actual)) addFailure({
      scenario:"send interrupted before request",
      expected:JSON.stringify(expected),
      actual:JSON.stringify(actual),
      message:"orphaned nested swap saga cannot restore an empty response, so recovery reports failure and leaves the mint gated even though the send reservation was compensated",
    });
    if(same(expected,actual)) {
      const recipient=recoveryName("send-before-spend");
      const recipientSeed=randomSeedHex();
      const spend=await evaluate(sessionId,`recoveryScenarios.spendAllFromApp(${q(recipient)},${q(recipientSeed)})`);
      if(spend.before !== started.expected || spend.net_sats !== String(started.expected) || spend.after !== 0 || spend.recovered !== 0 || spend.repeat !== 0) throw new Error(`Send-before recovery proofs were not fully spendable: ${JSON.stringify(spend)}`);
      await evaluate(sessionId,`recoveryScenarios.removeWallet(${q(recipient)})`);
      result.checks.push("Destroyed send-before recovery proofs are fully spendable");
    }
    await evaluate(sessionId,`recoveryScenarios.removeWallet(${q(started.sinkName)})`);
    await closeAndRemove(name);
  }

  // Receive interrupted before its swap request reached the mint.
  {
    const name=recoveryName("receive-before");
    const seedHex=randomSeedHex();
    await openRecoveryPage("recovery-receive-before");
    await evaluate(sessionId,`recoveryScenarios.startReceiveBeforeRequest(${q(name)},${q(seedHex)})`);
    await openRecoveryPage("recovery-receive-before-resume");
    const info=await inspect(name,seedHex);
    requireCleanReports(info.startup,"Receive interrupted before request");
    if(info.sats !== 100) throw new Error(`Receive interrupted before request expected 100 recovered sats, got ${info.sats}`);
    if(info.pending.pending.length !== 0) throw new Error("Receive interrupted before request left a pending token");
    const recovery=await recoverNow();
    requireCleanReports(recovery.reports,"Receive interrupted before request explicit recovery");
    if(recovery.sats !== 100) throw new Error(`Receive interrupted before request recovery expected 100 sats, got ${recovery.sats}`);
    const repeat=await recoverNow();
    if(repeat.sats !== 100 || repeat.pending.pending.length !== 0) throw new Error("Repeated receive-before recovery changed the wallet");
    const recipient=recoveryName("receive-before-spend");
    const recipientSeed=randomSeedHex();
    const spend=await evaluate(sessionId,`recoveryScenarios.spendAllFromApp(${q(recipient)},${q(recipientSeed)})`);
    if(spend.before !== 100 || spend.net_sats !== "100" || spend.after !== 0 || spend.recovered !== 0 || spend.repeat !== 0) throw new Error(`Receive-before recovery proofs were not fully spendable: ${JSON.stringify(spend)}`);
    await evaluate(sessionId,`recoveryScenarios.removeWallet(${q(recipient)})`);
    await closeAndRemove(name);
    result.checks.push("Destroyed receive before any mint request recovers exactly 100 sats on reload");
    result.checks.push("Destroyed receive-before recovery proofs are fully spendable");
  }

  // Send whose swap committed at the mint, then the response was held. The
  // required invariant is the pre-send balance at startup, first explicit
  // recovery and repeated recovery, with clean reports at each step. The
  // observed stale swap-input release is a structured failure, not a contract.
  {
    const name=recoveryName("send-commit");
    const seedHex=randomSeedHex();
    await openRecoveryPage("recovery-send-commit");
    const started=await evaluate(sessionId,`recoveryScenarios.startSendAfterCommitHold(${q(name)},${q(seedHex)})`);
    await openRecoveryPage("recovery-send-commit-resume");
    const info=await inspect(name,seedHex);
    const startup=info.startup.find(report => report.mint_url === origin);
    if(!startup) throw new Error("Send interrupted after commit: startup report is missing the mint");
    if(info.pending.pending.length !== 0) throw new Error("Send interrupted after commit left a pending token");
    const first=await recoverNow();
    const firstReport=first.reports.find(report => report.mint_url === origin);
    if(!firstReport) throw new Error("Send interrupted after commit: first recovery is missing the mint");
    const repeated=await recoverNow();
    const repeatedReport=repeated.reports.find(report => report.mint_url === origin);
    if(!repeatedReport) throw new Error("Send interrupted after commit: repeated recovery is missing the mint");
    const expected={
      startupBalance:started.expected, startupFailed:0, startupSkipped:0,
      firstBalance:started.expected, firstFailed:0, firstSkipped:0,
      repeatedBalance:started.expected, repeatedFailed:0, repeatedSkipped:0,
    };
    const actual={
      startupBalance:info.sats, startupFailed:startup.failed, startupSkipped:startup.skipped,
      firstBalance:first.sats, firstFailed:firstReport.failed, firstSkipped:firstReport.skipped,
      repeatedBalance:repeated.sats, repeatedFailed:repeatedReport.failed, repeatedSkipped:repeatedReport.skipped,
    };
    if(!same(expected,actual)) addFailure({
      scenario:"send interrupted after mint commit",
      expected:JSON.stringify(expected),
      actual:JSON.stringify(actual),
      message:"nested send-swap recovery restores outputs but releases already-spent swap inputs as unspent; the observed balance is not a valid success contract and spendability is not established",
    });
    if(same(expected,actual)) {
      const recipient=recoveryName("send-commit-spend");
      const recipientSeed=randomSeedHex();
      const spend=await evaluate(sessionId,`recoveryScenarios.spendAllFromApp(${q(recipient)},${q(recipientSeed)})`);
      if(spend.before !== started.expected || spend.net_sats !== String(started.expected) || spend.after !== 0 || spend.recovered !== 0 || spend.repeat !== 0) throw new Error(`Send-after-commit recovery proofs were not fully spendable: ${JSON.stringify(spend)}`);
      await evaluate(sessionId,`recoveryScenarios.removeWallet(${q(recipient)})`);
      result.checks.push("Destroyed send-after-commit recovery proofs are fully spendable");
    }
    await evaluate(sessionId,`recoveryScenarios.removeWallet(${q(started.sinkName)})`);
    await closeAndRemove(name);
  }

  // Receive whose swap committed at the mint, then the response was held.
  {
    const name=recoveryName("receive-commit");
    const seedHex=randomSeedHex();
    await openRecoveryPage("recovery-receive-commit");
    await evaluate(sessionId,`recoveryScenarios.startReceiveAfterCommitHold(${q(name)},${q(seedHex)})`);
    await openRecoveryPage("recovery-receive-commit-resume");
    const info=await inspect(name,seedHex);
    requireCleanReports(info.startup,"Receive interrupted after commit");
    if(info.sats !== 100) throw new Error(`Receive interrupted after commit expected 100 sats, got ${info.sats}`);
    if(info.pending.pending.length !== 0) throw new Error("Receive interrupted after commit left a pending token");
    const recovery=await recoverNow();
    requireCleanReports(recovery.reports,"Receive interrupted after commit explicit recovery");
    if(recovery.sats !== 100) throw new Error(`Receive interrupted after commit recovery expected 100 sats, got ${recovery.sats}`);
    const repeat=await recoverNow();
    if(repeat.sats !== 100 || repeat.pending.pending.length !== 0) throw new Error("Repeated receive-after-commit recovery changed the wallet");
    const recipient=recoveryName("receive-commit-spend");
    const recipientSeed=randomSeedHex();
    const spend=await evaluate(sessionId,`recoveryScenarios.spendAllFromApp(${q(recipient)},${q(recipientSeed)})`);
    if(spend.before !== 100 || spend.net_sats !== "100" || spend.after !== 0 || spend.recovered !== 0 || spend.repeat !== 0) throw new Error(`Receive-after-commit recovery proofs were not fully spendable: ${JSON.stringify(spend)}`);
    await evaluate(sessionId,`recoveryScenarios.removeWallet(${q(recipient)})`);
    await closeAndRemove(name);
    result.checks.push("Destroyed receive after mint commit recovers exactly 100 sats on reload");
    result.checks.push("Destroyed receive-after-commit recovery proofs are fully spendable");
  }

  // Successful local send, but its JS result is never delivered.
  {
    const name=recoveryName("send-delivery");
    const seedHex=randomSeedHex();
    await openRecoveryPage("recovery-send-delivery");
    await evaluate(sessionId,`recoveryScenarios.startSendBeforeDelivery(${q(name)},${q(seedHex)})`);
    await openRecoveryPage("recovery-send-delivery-resume");
    const info=await inspect(name,seedHex);
    requireCleanReports(info.startup,"Send interrupted before result delivery");
    if(info.sats !== 63) throw new Error(`Send interrupted before delivery expected 63 sats, got ${info.sats}`);
    if(info.pending.pending.length !== 1) throw new Error(`Send interrupted before delivery expected one pending token, got ${info.pending.pending.length}`);
    const token=info.pending.pending[0].token;
    if(typeof token !== "string" || !token.startsWith("cashu")) throw new Error("Pending token is not a Cashu bearer token");

    const recipient=recoveryName("send-delivery-recipient");
    const recipientSeed=randomSeedHex();
    const redeemed=await evaluate(sessionId,`recoveryScenarios.redeemToken(${q(recipient)},${q(recipientSeed)},${q(token)})`);
    if(redeemed.net_sats !== "37") throw new Error("Pending token was not redeemable exactly once");
    const secondRecipient=recoveryName("send-delivery-second");
    const secondSeed=randomSeedHex();
    const second=await evaluate(sessionId,`recoveryScenarios.redeemTokenResult(${q(secondRecipient)},${q(secondSeed)},${q(token)})`);
    if(second.status === 0) throw new Error("Already-claimed pending token was redeemable twice");
    // Pinned mapping: CDK TokenAlreadySpent/UnexpectedProofState maps to
    // InvalidToken (16). The recipient wallet and mint registration succeeded
    // inside redeemTokenResult; any setup or transport failure would have
    // thrown instead of returning this status.
    if(second.status !== 16) throw new Error(`Second redemption returned unexpected status ${second.status}: ${second.error || "no error"}`);
    if(!/already spent|TokenAlreadySpent|token.*spent/i.test(String(second.error || ""))) throw new Error(`Second redemption was not a token-spent failure: ${second.error || "no error"}`);
    result.checks.push("Already-claimed pending token is rejected with token-spent status 16");
    await evaluate(sessionId,`recoveryScenarios.removeWallet(${q(secondRecipient)})`);

    const recovery=await recoverNow();
    requireCleanReports(recovery.reports,"Pending token explicit recovery");
    if(recovery.pending.pending.length !== 0) throw new Error("Recovery did not remove the claimed pending token");
    if(recovery.sats !== 63) throw new Error(`Pending token recovery expected 63 sats, got ${recovery.sats}`);
    const repeat=await recoverNow();
    if(repeat.pending.pending.length !== 0 || repeat.sats !== 63) throw new Error("Repeated pending-token recovery changed the wallet");

    const spend=await evaluate(sessionId,`recoveryScenarios.sendFromApp(37)`);
    const finalRecipient=recoveryName("send-delivery-final");
    const finalSeed=randomSeedHex();
    const finalRedeemed=await evaluate(sessionId,`recoveryScenarios.redeemToken(${q(finalRecipient)},${q(finalSeed)},${q(spend.token)})`);
    if(finalRedeemed.net_sats !== "37") throw new Error("Recovered pending-token balance was not spendable");
    await evaluate(sessionId,`recoveryScenarios.removeWallet(${q(finalRecipient)})`);
    await evaluate(sessionId,`recoveryScenarios.removeWallet(${q(recipient)})`);
    await closeAndRemove(name);
    result.checks.push("Pending token survives destruction before JS delivery and is redeemable exactly once");
  }

  result.count=result.checks.length;
  result.failureCount=result.failures.length;
  result.completed=true;
  result.ok=result.failures.length === 0;
  try { await send("Target.closeTarget",{targetId:extra.targetId}); } catch {}
  try {
    await evaluate(sessionId,`document.getElementById("status").textContent=${JSON.stringify(result.ok?"BROWSER TESTS PASSED":`BROWSER TESTS: ${result.failureCount} KNOWN FAILURE(S)`) };document.getElementById("result").textContent=${JSON.stringify(JSON.stringify(result,null,2))};`);
  } catch {}
  return result;
})();
// If the watchdog wins the race, the losing execution must not surface as an
// unhandled rejection while the browser is being torn down.
work.catch(() => {});

try {
  await Promise.race([work,timeout]);
} catch(error) {
  result.ok=false;
  result.completed=false;
  result.error=String(error.message || error);
  await bounded(dumpProgress(),5_000,"progress diagnostics").catch(() => {});
} finally {
  clearTimeout(timer);
  if(killHook) clearTimeout(killHook);
  result.uncaughtExceptions=exceptions;
  if(exceptions.length) result.ok=false;
  result.count=result.checks.length;
  result.failureCount=result.failures.length;
  if(!result.completed || result.failures.length > 0) result.ok=false;
  else if(!result.error && exceptions.length === 0) result.ok=true;
  // Diagnostics are best-effort and bounded. The JSON artifact is written even
  // when the screenshot or CDP connection fails.
  try {
    if(activeSession) {
      const {data}=await bounded(send("Page.captureScreenshot",{format:"png",captureBeyondViewport:true},activeSession),5_000,"screenshot");
      await bounded(writeFile(join(artifacts,"cdk-browser-test.png"),Buffer.from(data,"base64")),5_000,"screenshot artifact");
    }
  } catch {}
  try {
    await bounded(writeFile(join(artifacts,"cdk-browser-test.json"),JSON.stringify(result,null,2)),5_000,"json artifact");
  } catch {}
  console.error(`Browser test artifacts: ${artifacts}`);
  console.log(JSON.stringify(result,null,2));
  process.exitCode=result.ok?0:1;
  socket?.close();
  const waitExit=milliseconds => new Promise(resolve => {
    if(browser.exitCode !== null) { resolve(true); return; }
    let handle;
    const onExit=() => { clearTimeout(handle); resolve(true); };
    browser.once("exit",onExit);
    handle=setTimeout(() => { browser.off("exit",onExit); resolve(false); },milliseconds);
  });
  browser.kill("SIGTERM");
  if(!(await waitExit(3_000))) {
    try { browser.kill("SIGKILL"); } catch {}
    await waitExit(3_000);
  }
  await bounded(rm(directory,{recursive:true,force:true,maxRetries:5,retryDelay:100}),5_000,"profile cleanup").catch(() => {});
}
