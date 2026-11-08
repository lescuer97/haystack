// Wallet state is origin-local; no secrets are written to logs or URLs.
export function readStore(key) { return localStorage.getItem(key); }
export function writeStore(key, value) { localStorage.setItem(key, value); }

const activeLocks = new Map();
let invalidated = false;
function invalidate(error) {
  if (error instanceof WebAssembly.RuntimeError) {
    invalidated = true;
    for (const entry of activeLocks.values()) entry.release?.();
  }
}
window.addEventListener("error", event => invalidate(event.error));
window.addEventListener("unhandledrejection", event => invalidate(event.reason));

export async function acquireWalletLock(name) {
  if (!navigator.locks) throw new Error("Web Locks are required; wallet opening refused");
  if (invalidated) throw new Error("Wasm instance failed; reload before opening a wallet");
  const previous = activeLocks.get(name);
  // Resolving the held promise starts release, but the browser lock manager
  // releases asynchronously. A reopen must wait for that completion.
  if (previous?.closing) await previous.finished;
  let release;
  const held = new Promise(resolve => { release = resolve; });
  let granted, rejected;
  const ready = new Promise((resolve, reject) => { granted = resolve; rejected = reject; });
  const entry = { closing: false, finished: null };
  entry.finished = navigator.locks.request(name, { mode: "exclusive", ifAvailable: true }, async lock => {
    if (!lock) { rejected(new Error("Wallet is already open in another tab or handle")); return; }
    activeLocks.set(name, entry);
    entry.release = () => { entry.closing = true; release(); return entry.finished; };
    granted(entry.release);
    await held;
  });
  entry.finished.then(() => { if (activeLocks.get(name) === entry) activeLocks.delete(name); }, rejected);
  return ready;
}
