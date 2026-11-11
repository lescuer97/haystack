import init, {open_wallet, call_pure} from "./wallet/cdk_wallet_browser.js";

// Test-only DOM adapter for the non-interactive wallet fixture. It exposes the
// serialized wallet API used by browser/smoke.js and browser/test.mjs; the game
// never loads this file.
let rawWallet = null;
let queue = Promise.resolve();
let failed = false;
let rejectFatal;
const fatalSignal = new Promise((_, reject) => { rejectFatal = reject; });
fatalSignal.catch(() => {});
const status = document.getElementById("status");
const result = document.getElementById("result");
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
