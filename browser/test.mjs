// Dependency-free, event-driven Chromium/CDP runner. Start the local fake mint
// first; this exits nonzero on failed checks, browser errors, or timeout.
import {spawn} from "node:child_process";
import {mkdtemp, writeFile, rm, mkdir} from "node:fs/promises";

await mkdir("/tmp/opencode",{recursive:true});
const directory=await mkdtemp("/tmp/opencode/cdk-browser-test-");
const browser=spawn(process.env.CHROMIUM || "chromium",["--headless","--no-sandbox","--use-gl=angle","--use-angle=swiftshader","--enable-unsafe-swiftshader",`--user-data-dir=${directory}`,"--remote-debugging-port=0","about:blank"],{stdio:["ignore","ignore","pipe"]});
let socket;
let timeoutReject;
const timeout=new Promise((_,reject) => { timeoutReject=reject; });
const timer=setTimeout(() => timeoutReject(new Error("Browser test timed out")),120_000);
try {
  const endpoint=await new Promise((resolve,reject) => {
    let stderr="";
    browser.stderr.on("data",chunk => { stderr+=chunk; const match=stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/); if(match) resolve(match[1]); });
    browser.on("error",reject);
    browser.on("exit",code => reject(new Error(`Chromium exited: ${code}`)));
  });
  socket=new WebSocket(endpoint);
  await new Promise((resolve,reject) => { socket.onopen=resolve; socket.onerror=reject; });
  let sequence=0;
  const requests=new Map();
  let complete;
  const report=new Promise(resolve => { complete=resolve; });
  const exceptions=[];
  const events=new Map();
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
      complete({ok:false,error:message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text});
    }
    if(message.method === "Runtime.consoleAPICalled" && message.params.type === "error") console.error(message.params.args.map(v => v.value || v.description).join(" "));
  };
  function send(method,params={},sessionId) {
    const id=++sequence;
    return new Promise((resolve,reject) => { requests.set(id,{resolve,reject}); socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})); });
  }
  function once(method,sessionId) { return new Promise(resolve => events.set(`${sessionId}:${method}`,resolve)); }
  async function evaluate(sessionId,expression) {
    const response=await send("Runtime.evaluate",{expression,awaitPromise:true,returnByValue:true},sessionId);
    if(response.exceptionDetails) throw new Error(response.exceptionDetails.exception?.description || response.exceptionDetails.text);
    return response.result.value;
  }
  const {targetId}=await send("Target.createTarget",{url:"about:blank"});
  const {sessionId}=await send("Target.attachToTarget",{targetId,flatten:true});
  await send("Runtime.enable",{},sessionId);
  await send("Page.enable",{},sessionId);
  await send("Runtime.addBinding",{name:"reportBrowserTests"},sessionId);
  await send("Page.navigate",{url:process.argv[2] || "http://127.0.0.1:18787/?smoke"},sessionId);
  const result=await Promise.race([report,timeout]);
  if(!result.ok) {
    const progress=await send("Runtime.evaluate",{expression:"window.browserTestProgress",returnByValue:true},sessionId);
    result.checks=progress.result.value;
  }
  if(result.ok) {
    // Actual separate-tab and document-reload checks, not just two Rust handles.
    const name=`lifecycle-${crypto.randomUUID().replaceAll("-","")}`;
    const open=`await walletApp.open(new Uint8Array(64).fill(51),${JSON.stringify(name)})`;
    await evaluate(sessionId,`(async()=>{${open}; const r=await walletApp.call("add_mint",[location.origin]);if(r.status)throw new Error("lifecycle mint registration failed");})()`);
    const extra=await send("Target.createTarget",{url:"about:blank"});
    const second=await send("Target.attachToTarget",{targetId:extra.targetId,flatten:true});
    await send("Runtime.enable",{},second.sessionId);
    await send("Page.enable",{},second.sessionId);
    const loaded=once("Page.loadEventFired",second.sessionId);
    await send("Page.navigate",{url:new URL("/?lifecycle",process.argv[2] || "http://127.0.0.1:18787").href},second.sessionId);
    await loaded;
    const rejected=await evaluate(second.sessionId,`(async()=>{await (await import("./app.js")).ready;try{${open};await walletApp.close();return false;}catch{return true;}})()`);
    if(!rejected) throw new Error("Cross-tab exclusive lock failed");
    result.checks.push("A separate browser tab cannot open the same wallet concurrently");
    await evaluate(sessionId,"walletApp.close()");
    const handoff=await evaluate(second.sessionId,`(async()=>{${open};const r=await walletApp.call("list_mints");await walletApp.close();return r.status===0 && r.mints.includes(location.origin);})()`);
    if(!handoff) throw new Error("Cross-tab persistent handoff failed");
    result.checks.push("Wallet state survives handoff to a separate browser tab");
    const reloaded=once("Page.loadEventFired",sessionId);
    await send("Page.navigate",{url:new URL("/?reload-check",process.argv[2] || "http://127.0.0.1:18787").href},sessionId);
    await reloaded;
    const persisted=await evaluate(sessionId,`(async()=>{await (await import("./app.js")).ready;${open};const r=await walletApp.call("list_mints");await walletApp.close();localStorage.removeItem(${JSON.stringify(`cdk_wallet_browser_v1_${name}`)});return r.status===0 && r.mints.includes(location.origin);})()`);
    if(!persisted) throw new Error("Wallet persistence across page reload failed");
    result.checks.push("Wallet storage survives destruction and reload of the Wasm instance");
    result.count=result.checks.length;
    await send("Target.closeTarget",{targetId:extra.targetId});
    await evaluate(sessionId,`document.getElementById("status").textContent="BROWSER TESTS PASSED";document.getElementById("result").textContent=${JSON.stringify(JSON.stringify(result,null,2))};document.querySelector("details").open=true;`);
  }
  result.uncaughtExceptions=exceptions;
  if(exceptions.length) result.ok=false;
  const {data}=await send("Page.captureScreenshot",{format:"png",captureBeyondViewport:true},sessionId);
  await writeFile("/tmp/opencode/cdk-browser-test.png",Buffer.from(data,"base64"));
  await writeFile("/tmp/opencode/cdk-browser-test.json",JSON.stringify(result,null,2));
  console.log(JSON.stringify(result,null,2));
  process.exitCode=result.ok?0:1;
} catch(error) {
  console.error(String(error.message || error)); process.exitCode=1;
} finally {
  clearTimeout(timer);
  socket?.close();
  const exited=new Promise(resolve => { if(browser.exitCode !== null) resolve(); else browser.once("exit",resolve); });
  browser.kill();
  await exited;
  await rm(directory,{recursive:true,force:true,maxRetries:5,retryDelay:100}).catch(() => {});
}
