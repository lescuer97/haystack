// Test-only fetch fault injector for the pinned CDK transport.
//
// The transport posts a Request to the mint and then reads its body. This
// wrapper intercepts at most one armed POST whose origin and path are exactly
// this page's /v1/swap. It never logs or copies request bodies, tokens, or
// seeds: it only observes the response status and body shape at the commit
// boundary.
//
// Modes:
//   before   - hold the request before it reaches the mint.
//   malformed- commit at the mint, then return an unparseable 200 response.
//   reject   - commit at the mint, then reject with a generic network error.
//   hold     - commit at the mint, then hold the response indefinitely.
//
// For every "after commit" mode the real response must be successful and its
// body valid JSON before the commit boundary is signalled, so recovery tests
// always start from a real mint-side swap.
let active = null;

export function installSwapFaults() {
  if (active) return active;

  const realFetch = globalThis.fetch.bind(globalThis);
  let armed = null;
  let firedCount = 0;
  let committedCount = 0;

  const isSwap = request => {
    if (request.method !== "POST") return false;
    try {
      const url = new URL(request.url);
      return url.origin === location.origin && url.pathname === "/v1/swap";
    } catch {
      return false;
    }
  };

  async function afterCommit(request, fault) {
    const response = await realFetch(request);
    if (!response.ok) {
      fault.rejectCommitted(new Error(`injected fault observed a non-OK /v1/swap response (${response.status})`));
      return response;
    }
    // Consume and validate a clone, so the mint really accepted the swap and
    // the application still sees the fault we return below.
    const body = await response.clone().text();
    try {
      JSON.parse(body);
    } catch (error) {
      fault.rejectCommitted(new Error(`injected fault observed an invalid /v1/swap response: ${error.message || error}`));
      return response;
    }
    committedCount += 1;
    fault.resolveCommitted();
    if (fault.mode === "malformed") {
      const headers = new Headers(response.headers);
      headers.set("content-type", "application/json");
      return new Response('{"signatures":', {status: 200, headers});
    }
    if (fault.mode === "reject") throw new TypeError("injected network failure after mint commit");
    return await fault.hold();
  }

  globalThis.fetch = function(input, init) {
    let request;
    try {
      request = input instanceof Request ? input : new Request(input, init);
    } catch {
      return realFetch(input, init);
    }
    if (!armed || !isSwap(request)) return realFetch(input, init);

    // One armed operation is consumed synchronously before any await, so a
    // second concurrent /v1/swap request can never inherit the fault.
    const fault = armed;
    armed = null;
    firedCount += 1;
    fault.resolveFired();
    if (fault.mode === "before") return fault.hold();
    return afterCommit(request, fault);
  };

  const controller = {
    arm(mode) {
      if (armed) throw new Error("a /v1/swap fault is already armed");
      if (!["before", "malformed", "reject", "hold"].includes(mode)) throw new Error(`unknown /v1/swap fault mode: ${mode}`);
      let resolveFired;
      let resolveCommitted;
      let rejectCommitted;
      const fired = new Promise(resolve => { resolveFired = resolve; });
      const committed = new Promise((resolve, reject) => { resolveCommitted = resolve; rejectCommitted = reject; });
      // Tests may legitimately only await `fired` (before-request holds); keep
      // an unobserved committed rejection from surfacing as unhandled.
      committed.catch(() => {});
      armed = {
        mode,
        resolveFired,
        resolveCommitted,
        rejectCommitted,
        hold: () => new Promise(() => {}),
      };
      return {fired, committed};
    },
    restore() {
      armed = null;
      globalThis.fetch = realFetch;
      active = null;
    },
    stats() {
      return {armed: armed !== null, fired: firedCount, committed: committedCount};
    },
  };
  active = controller;
  return controller;
}
