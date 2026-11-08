import init, {open_wallet, call_pure} from "./wallet/cdk_wallet_browser.js";

let rawWallet = null;
let queue = Promise.resolve();
let failed = false;
let rejectFatal;
const fatalSignal = new Promise((_, reject) => { rejectFatal = reject; });
fatalSignal.catch(() => {});
const status = document.getElementById("status");
const result = document.getElementById("result");
const input = id => document.getElementById(id).value;
export const ready = init();

function failInstance(error) {
  if (error instanceof WebAssembly.RuntimeError && !failed) {
    failed = true;
    status.textContent = "Fatal Wasm error; reload and recover before continuing";
    rejectFatal(error);
  }
}
window.addEventListener("error", event => failInstance(event.error));
window.addEventListener("unhandledrejection", event => failInstance(event.reason));

function serialize(action) {
  const next = queue.then(async () => {
    await ready;
    if (failed) throw new Error("Wasm instance failed; reload the page before using the wallet");
    try { return await Promise.race([action(), fatalSignal]); }
    catch (error) {
      failInstance(error);
      throw error;
    }
  });
  queue = next.catch(() => {});
  return next;
}

export const walletApp = {
  ready,
  pure: (operation, args = []) => serialize(() => JSON.parse(call_pure(operation, JSON.stringify(args)))),
  open: (seed, name) => serialize(async () => {
    if (rawWallet) throw new Error("Close the current wallet first");
    rawWallet = await open_wallet(seed, name);
    return JSON.parse(rawWallet.startup_reports());
  }),
  call: (operation, args = []) => serialize(async () => {
    if (!rawWallet) throw new Error("Open a wallet first");
    return JSON.parse(await rawWallet.call(operation, JSON.stringify(args)));
  }),
  close: () => serialize(async () => {
    if (rawWallet) { await rawWallet.close(); rawWallet.free(); rawWallet = null; }
  }),
};
window.walletApp = walletApp;

function check(response) {
  if (response.status !== 0) throw new Error(response.error || `Wallet status ${response.status}`);
  return response;
}
function bind(id, action) {
  document.getElementById(id).onclick = async () => {
    try { const value = await action(); result.textContent = JSON.stringify(value ?? {status: "ok"}, null, 2); }
    catch (error) { result.textContent = String(error.message || error); }
  };
}
bind("generate", async () => {
  const generated = check(await walletApp.pure("generate_mnemonic"));
  document.getElementById("mnemonic").value = generated.value;
  // Explicit user action; never log or persist the mnemonic.
  alert(`TEST mnemonic — save privately:\n${generated.value}`);
  return {status: "Test mnemonic generated; not persisted"};
});
bind("open", async () => {
  const derived = check(await walletApp.pure("mnemonic_to_seed", [input("mnemonic")]));
  const seed = Uint8Array.from(derived.hex.match(/../g), byte => parseInt(byte,16));
  try { const reports = await walletApp.open(seed, input("name")); status.textContent = "Browser wallet open — CDK 0.18.3"; return {reports}; }
  finally { seed.fill(0); }
});
bind("close", async () => { await walletApp.close(); status.textContent = "Wallet closed"; });
bind("approve", async () => check(await walletApp.call("add_mint", [input("mint")])));
bind("balance", async () => check(await walletApp.call("list_balances")));
bind("recover", async () => check(await walletApp.call("recover")));
bind("receive", async () => check(await walletApp.call("receive", [input("token")])));
bind("send", async () => {
  const sent = check(await walletApp.call("send", [input("mint"), input("amount"), input("fee")]));
  document.getElementById("token").value = sent.token;
  return {operation_id: sent.operation_id, sender_fee_sats: sent.sender_fee_sats, status: "Token shown above; it is a bearer secret"};
});
bind("pending", async () => {
  const response = check(await walletApp.call("list_pending_tokens"));
  return {pending: response.pending.map(p => p.operation_id)};
});
ready.then(() => { status.textContent = "Rust wallet WebAssembly loaded — ready to open"; }).catch(() => { status.textContent = "Failed to load browser wallet WebAssembly"; });

if (new URLSearchParams(location.search).has("smoke")) {
  import("./smoke.js").then(({runSmoke}) => runSmoke(walletApp)).then(report => {
    window.browserTestReport = report;
    status.textContent = report.ok ? "BROWSER TESTS PASSED" : "BROWSER TESTS FAILED";
    result.textContent = JSON.stringify(report, null, 2);
    window.reportBrowserTests?.(JSON.stringify(report));
  }).catch(error => {
    window.browserTestReport = {ok:false,error:String(error.message || error)};
    status.textContent = "BROWSER TESTS FAILED";
    result.textContent = JSON.stringify(window.browserTestReport);
    window.reportBrowserTests?.(JSON.stringify(window.browserTestReport));
  });
}
