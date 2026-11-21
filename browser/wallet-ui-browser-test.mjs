// Functional wallet/input/FFI regression, never a public mint or a user profile.
import {gameSocketFixture} from './test-support/game-ws-fixture.mjs';
import {bounded, CdpConnection, discoverEndpoint, launchBrowser, makeProfile, removeProfile, stopBrowser, watchdog} from './cdp-runner.mjs';
const origin = new URL(process.argv[2]);
if (origin.protocol !== 'http:' || origin.hostname !== '127.0.0.1' || !origin.port) throw new Error('Local fake mint required');
const profile = await makeProfile('haystack-wallet-ui-');
const browser = launchBrowser(profile);
let connection, context, session, label = 'startup';
const diagnostics={stack:false,memory:false,undefinedBehavior:false};
const captures={};
const fixtureTrace={gates:[],counts:[]};
const send = (method, params = {}) => connection.send(method, params, session);
async function evaluate(expression) {
  const result = await send('Runtime.evaluate', {expression, awaitPromise:true, returnByValue:true});
  if (result.exceptionDetails) throw new Error('Evaluation failed');
  return result.result?.value;
}
async function expect(name, expression) {
  label = name;
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    try { if (await evaluate(expression)) { console.log(`ok - ${name}`); return; } }
    catch (_) { if(!connection?.isOpen)throw new Error('CDP closed'); }
    await new Promise(resolve => setTimeout(resolve, 60));
  }
  throw new Error('Wallet check failed');
}
const frames = () => evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r(true))))');
// Wait two 20 Hz game ticks while drawing continues at the display refresh rate.
const settleTicksExpression = `new Promise(resolve=>{
  const start=performance.now();
  function tick(now){if(now-start>=100)resolve(true);else requestAnimationFrame(tick);}
  requestAnimationFrame(tick);
})`;
const settleTicks = () => evaluate(settleTicksExpression);
async function key(key, code, number) {
  await send('Input.dispatchKeyEvent', {type:'rawKeyDown', key, code, windowsVirtualKeyCode:number});
  // Keep presses short to avoid input.Reader's 100ms directional repeat;
  // the longer neutral interval below separates consecutive key edges.
  await frames();
  await send('Input.dispatchKeyEvent', {type:'keyUp', key, code, windowsVirtualKeyCode:number});
  await settleTicks(); // Two neutral game ticks reset repeat state.
}
const enter = async () => {
  // Wait nominal game-tick intervals before dependent UI activation. Use a recent,
  // stable completion so the next poll slot cannot race input.
  await expect('wallet idle before activation', `(async()=>{
    if(walletUiChecks.active!==0 || performance.now()-walletUiChecks.settledAt>500)return false;
    const count=walletUiChecks.requests.length;
    await ${settleTicksExpression};
    return walletUiChecks.active===0 && walletUiChecks.requests.length===count;
  })()`);
  await key('Enter','Enter',13);
};
const down = () => key('ArrowDown','ArrowDown',40);
const escape = () => key('Escape','Escape',27);
async function activateRow(y) {
  // These renderer rows are measured at the fixture's fixed 1000x640 size.
  // Pointer selection avoids depending on the 100ms (two-tick) directional repeat.
  await send('Input.dispatchMouseEvent',{type:'mouseMoved',x:500,y});
  await settleTicks();
  await enter();
}
const depositRow = index => activateRow(177+65*index);
async function createDeposit(name, amount, priorIds=[]) {
  const start=await evaluate('({generation:walletUiChecks.generation,index:walletUiChecks.replies.length})');
  const matches=`r.operation===2 && r.value.amount===${JSON.stringify(amount)} && r.value.state==='UNPAID' && typeof r.value.id==='string' && r.value.id.length>0 && !${JSON.stringify(priorIds)}.includes(r.value.id) && typeof r.value.invoice==='string' && r.value.invoice.length>0`;
  await depositRow(5);
  await expect(`${name} create reply saves requested unpaid quote`,`walletUiChecks.generation===${JSON.stringify(start.generation)} && walletUiChecks.active===0 && walletUiChecks.replies.slice(${start.index}).some(r=>${matches})`);
  const reply=await evaluate(`walletUiChecks.generation===${JSON.stringify(start.generation)} ? walletUiChecks.replies.slice(${start.index}).find(r=>${matches}) : null`);
  if(!reply)throw new Error('Create reply document changed');
  captures[name]={generation:start.generation,serial:reply.serial,id:reply.value.id,amount:reply.value.amount};
  return reply.value;
}
async function reloadWallet() {
  const generation=await evaluate('walletUiChecks.generation');
  await send('Page.reload');
  await expect('reload has a fresh document and Rust reply',`window.walletUiChecks?.generation!==${JSON.stringify(generation)} && walletUiChecks.events.includes('ready') && walletUiChecks.replies.length>0`);
}
async function depositCounts() {
  const response=await fetch(new URL('/test-deposit-counts',origin));
  if(!response.ok)throw new Error('Could not read deposit counts');
  const counts=await response.json();
  fixtureTrace.counts.push({label,status:response.status,...counts});
  return counts;
}
const instrumentation = `(() => {
  window.walletUiChecks = {generation:crypto.randomUUID(),errors:0,requests:[],requestTimes:{},operations:{},replies:[],invoices:{},events:[],active:0,settledAt:0,overlap:false,invoice:null,snapshot:null,history:null,resumed:null,copied:false,copiedText:null};
  addEventListener('error',()=>walletUiChecks.errors++);
  addEventListener('unhandledrejection',()=>walletUiChecks.errors++);
  Object.defineProperty(navigator,'clipboard',{value:{writeText:async text=>{walletUiChecks.copiedText=text;walletUiChecks.copied=text===walletUiChecks.invoice?.invoice;}}});
  Object.defineProperty(window,'haystackOnboarding',{configurable:true,get(){return this.__walletUiBridge;},set(bridge){
    this.__walletUiBridge=bridge;
    const request=bridge.walletRequest,deliver=bridge.deliver;
    bridge.walletRequest=function(generation,serial,operation){
      walletUiChecks.requests.push(operation);
      walletUiChecks.operations[serial]=operation;
      walletUiChecks.requestTimes[serial]=Date.now();
      if(++walletUiChecks.active>1)walletUiChecks.overlap=true;
      return request.apply(this,arguments);
    };
    bridge.deliver=function(callback,generation,serial,text,startup,limit){
      if(limit===131072){
         walletUiChecks.active--;
         walletUiChecks.settledAt=performance.now();
         if(typeof text==='string'){
           const value=JSON.parse(text);
           const operation=walletUiChecks.operations[serial];
           walletUiChecks.replies.push({serial,operation,value,started:walletUiChecks.requestTimes[serial],finished:Date.now()});
          if(typeof value.msats==='string')walletUiChecks.snapshot=value;
          if(Array.isArray(value.rows))walletUiChecks.history=value;
           if(operation===5)walletUiChecks.resumed=value;
          const invoice=typeof value.invoice==='string'?value:(value.invoice&&typeof value.invoice==='object'?value.invoice:null);
           if(invoice){
             walletUiChecks.invoices[invoice.id]={...invoice};
            walletUiChecks.invoice=invoice;
          }
        }
      }else if(typeof text==='string')walletUiChecks.events.push(JSON.parse(text).event);
      return deliver.apply(this,arguments);
    };
  }});
})();`;
async function openWallet() {
  await expect('game socket authenticated', 'window.gameSocketChecks?.ready === true');
  await settleTicks(); // Consume ready/reload replies before opening the menu.
  await escape(); await enter(); // Main -> Wallet
}
async function run() {
  connection = await CdpConnection.connect(await discoverEndpoint(browser));
  connection.on('Runtime.consoleAPICalled',message=>{
    // Classify runtime diagnostics without retaining/logging messages or values.
    for(const argument of message.params.args||[]){
      if(typeof argument.value!=='string')continue;
      diagnostics.stack ||= /stack overflow/i.test(argument.value);
      diagnostics.memory ||= /memory access out of bounds/i.test(argument.value);
      diagnostics.undefinedBehavior ||= /runtime error:|undefined behavior/i.test(argument.value);
    }
  });
  ({browserContextId:context} = await connection.send('Target.createBrowserContext',{disposeOnDetach:true}));
  const {targetId} = await connection.send('Target.createTarget',{url:new URL('/wallet/cdk_wallet_browser.js',origin).href,browserContextId:context});
  ({sessionId:session} = await connection.send('Target.attachToTarget',{targetId,flatten:true}));
  await send('Page.enable'); await send('Runtime.enable');
  await send('Emulation.setDeviceMetricsOverride',{width:1000,height:640,deviceScaleFactor:1,mobile:false});
  await expect('isolated fixture origin',`location.origin===${JSON.stringify(origin.origin)}`);
  await evaluate(`(async()=>{const m=await import('/wallet/cdk_wallet_browser.js');await m.default();await m.provision_wallet('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about','haystack-user');return true;})()`);
  await send('Page.addScriptToEvaluateOnNewDocument',{source:gameSocketFixture + '\n' + instrumentation});
  await send('Page.navigate',{url:new URL('/renderer/index.html',origin).href});
  await expect('Ready opens Rust-owned wallet after onboarding lock release','walletUiChecks.events.includes("ready") && !!walletUiChecks.snapshot && walletUiChecks.active===0');
  await evaluate('document.getElementById("canvas").focus()');
  await openWallet();
  await expect('zero selected-mint balance','walletUiChecks.snapshot.msats==="0" && !walletUiChecks.errors');
   await down(); await enter(); // Wallet -> Deposit
  await enter(); // Custom msats
  for (const text of '1.5') await send('Input.dispatchKeyEvent',{type:'char',text,unmodifiedText:text});
  await settleTicks();
   await depositRow(5);
  await expect('custom decimal rejected before Rust/network','!walletUiChecks.requests.includes(2)');
   await depositRow(2); // preset 42000 msat
  const initial=await createDeposit('initial','42000');
  const {id,invoice}=initial;
  await enter();
  await expect('trusted copy uses complete invoice',`walletUiChecks.copied && walletUiChecks.copiedText===${JSON.stringify(invoice)}`);
   await expect('watcher checks and sweeps while gate holds unpaid','walletUiChecks.requests.filter(n=>n===3).length>=2 && walletUiChecks.requests.includes(7) && !walletUiChecks.overlap');
  const balanceReads=await evaluate('walletUiChecks.requests.filter(n=>n===1).length');
  const checksBefore=await evaluate('walletUiChecks.requests.filter(n=>n===3).length');
  await expect('unchanged unpaid checks fetch no balance or inactive history',`walletUiChecks.requests.filter(n=>n===3).length>=${checksBefore+2} && walletUiChecks.requests.filter(n=>n===1).length===${balanceReads} && !walletUiChecks.requests.includes(4)`);
  let counts=await depositCounts();
  if(counts.quotes!==1||counts.claims!==0)throw new Error('Unpaid deposit duplicated or credited');
  await reloadWallet();
  await expect('reload resumes same unissued saved quote',`walletUiChecks.events.includes('ready') && walletUiChecks.resumed?.invoice?.id===${JSON.stringify(id)} && walletUiChecks.active===0`);
  await evaluate('document.getElementById("canvas").focus()');
  await openWallet(); await down(); await enter();
  await expect('reloaded invoice watcher preserves identity',`walletUiChecks.invoice?.id===${JSON.stringify(id)}`);
  await fetch(new URL('/test-pay',origin));
  await expect('paid is actually minted, then balance reread','walletUiChecks.invoice?.state==="ISSUED" && walletUiChecks.invoice.confirmed===true && walletUiChecks.snapshot?.msats==="42000" && walletUiChecks.active===0');
  counts=await depositCounts();
  if(counts.quotes!==1||counts.claims!==1)throw new Error('Deposit was not exactly once');
   await down(); await down(); await enter(); // Invoice Back -> Wallet
  await down(); await down(); await down(); await enter(); // History
  await expect('history uses persisted quote state and creation metadata',`walletUiChecks.history?.rows.some(q=>q.id===${JSON.stringify(id)}&&q.direction==='In'&&q.amount==='42000'&&q.state==='ISSUED'&&q.created_at) && walletUiChecks.active===0`);
   const savedReads=await evaluate('walletUiChecks.requests.filter(n=>n===8).length');
   const savedReplyStart=await evaluate('walletUiChecks.replies.length');
   await enter(); // Selected History row -> Invoice
   await expect('selectable history row locally opens its saved invoice',`walletUiChecks.requests.filter(n=>n===8).length>${savedReads} && walletUiChecks.replies.slice(${savedReplyStart}).some(r=>r.operation===8 && r.value.id===${JSON.stringify(id)}) && walletUiChecks.active===0`);
   await down(); await down(); await enter(); // Invoice Back -> Wallet
  await escape();
   await reloadWallet();
   await expect('issued reload has real balance, no unfinished invoice','walletUiChecks.snapshot?.msats==="42000" && walletUiChecks.resumed?.invoice===null && walletUiChecks.active===0');
  counts=await depositCounts();
  if(counts.quotes!==1||counts.claims!==1)throw new Error('Reload duplicated persisted payment');
  // Both quotes belong to the real Rust wallet. The fixture only masks the mint's
  // payment notifications; it neither credits balances nor replaces invoices.
   const closedGate=await fetch(new URL('/test-unpay',origin));
   fixtureTrace.gates.push({action:'close',status:closedGate.status});
  if(!closedGate.ok)throw new Error('Could not close isolated payment gate');
  await evaluate('document.getElementById("canvas").focus()');
   await openWallet(); await down(); await enter(); // Wallet -> Deposit form
   const additionalStart=await evaluate('({generation:walletUiChecks.generation,index:walletUiChecks.replies.length})');
   await depositRow(1); // preset 21000 msat
   const first=await createDeposit('first','21000',[id]);
  await activateRow(505); // Invoice Deposit -> form, not resume
  await depositRow(3); // preset 100000 msat
   const second=await createDeposit('second','100000',[id,first.id]);
  await activateRow(505); // Invoice Deposit -> another independent quote
  await depositRow(1); // preset 21000 msat
   const chosen=await createDeposit('chosen','21000',[id,first.id,second.id]);
   if(new Set([first.id,second.id,chosen.id]).size!==3)throw new Error('Additional quote identities are not distinct');
   await expect('three distinct authoritative create replies have requested amounts',`walletUiChecks.generation===${JSON.stringify(additionalStart.generation)} && (()=>{
     const created=walletUiChecks.replies.slice(${additionalStart.index}).filter(r=>r.operation===2 && typeof r.value.invoice==='string' && r.value.state==='UNPAID');
     return created.length===3 && created.every((r,i)=>r.value.id===${JSON.stringify([first.id,second.id,chosen.id])}[i] && r.value.amount===['21000','100000','21000'][i]);
   })()`);
  await enter(); // Copy the displayed, chosen invoice before background settlement.
  await expect('chosen invoice clipboard is exact before settlement',`walletUiChecks.copiedText===${JSON.stringify(chosen.invoice)}`);
   counts=await depositCounts();
  if(counts.quotes!==4||counts.claims!==1)throw new Error('Multiple unpaid deposits duplicated or credited early');
  console.log('ok - three distinct saved unpaid deposits with no replacement POST');
  await escape(); // Close menu entirely; the service must continue in gameplay.
  const replyStart=await evaluate('walletUiChecks.replies.length');
  await expect('closed-menu sweep visits all eligible unpaid deposits',`[${JSON.stringify(first.id)},${JSON.stringify(second.id)},${JSON.stringify(chosen.id)}].every(id=>walletUiChecks.replies.slice(${replyStart}).some(r=>r.operation===7 && r.value.invoice?.id===id && r.value.invoice.state==='UNPAID')) && !walletUiChecks.overlap`);
  const selectivePay=new URL('/test-pay',origin);
  selectivePay.searchParams.set('except',chosen.id);
   const selectiveResponse=await fetch(selectivePay);
   fixtureTrace.gates.push({action:'pay-others',heldId:chosen.id,status:selectiveResponse.status,at:Date.now()});
   if(!selectiveResponse.ok)throw new Error('Could not selectively release payment gate');
  await expect('closed-menu service locally confirms both other real deposits',`[${JSON.stringify(first.id)},${JSON.stringify(second.id)}].every(id=>walletUiChecks.replies.slice(${replyStart}).some(r=>r.operation===7 && r.value.invoice?.id===id && r.value.invoice.state==='ISSUED' && r.value.invoice.confirmed===true)) && walletUiChecks.invoices[${JSON.stringify(chosen.id)}]?.state==='UNPAID' && walletUiChecks.snapshot?.msats==='163000' && walletUiChecks.active===0 && !walletUiChecks.overlap`);
   counts=await depositCounts();
  if(counts.quotes!==4||counts.claims!==3)throw new Error('Closed-menu deposits were not claimed exactly once');
  console.log('ok - closed-menu balance sum and exactly two additional claims, no quote replacement');
  await evaluate('walletUiChecks.copiedText=null');
  await openWallet(); await down(); await enter(); // Saved chosen invoice remains unpaid.
  await enter();
  await expect('background results preserve visible chosen invoice clipboard',`walletUiChecks.copiedText===${JSON.stringify(chosen.invoice)}`);
  await fetch(new URL('/test-pay',origin));
  await expect('chosen invoice settles once after releasing its gate',`walletUiChecks.invoices[${JSON.stringify(chosen.id)}]?.confirmed===true && walletUiChecks.snapshot?.msats==='184000' && walletUiChecks.active===0 && !walletUiChecks.overlap`);
   await reloadWallet();
  await expect('multi-deposit balance and completion survive restart','walletUiChecks.events.includes("ready") && walletUiChecks.snapshot?.msats==="184000" && walletUiChecks.resumed?.invoice===null && walletUiChecks.active===0');
  await evaluate('document.getElementById("canvas").focus()');
  await openWallet(); await down(); await down(); await down(); await enter();
  await expect('all additional deposit states persist in real Rust history',`[${JSON.stringify(first.id)},${JSON.stringify(second.id)},${JSON.stringify(chosen.id)}].every(id=>walletUiChecks.history?.rows.some(row=>row.id===id && row.state==='ISSUED')) && walletUiChecks.active===0`);
   counts=await depositCounts();
  if(counts.quotes!==4||counts.claims!==4)throw new Error('Restart reissued a settled multi-deposit payment');
  await expect('no uncaught renderer errors or overlapping requests','!walletUiChecks.errors && !walletUiChecks.overlap');
}
const timer=watchdog(240000,'wallet UI');
const work=run();
work.catch(()=>{});
try { await Promise.race([work,timer.promise]); }
catch (_) {
  let state=null;
    try{state=await bounded(evaluate(`({generation:window.walletUiChecks?.generation,errors:window.walletUiChecks?.errors,events:window.walletUiChecks?.events,requests:window.walletUiChecks?.requests,msats:window.walletUiChecks?.snapshot?.msats,replies:window.walletUiChecks?.replies.map(r=>{const invoice=typeof r.value.invoice==='string'?r.value:r.value.invoice;return {serial:r.serial,operation:r.operation,id:invoice?.id,amount:invoice?.amount,state:invoice?.state,confirmed:invoice?.confirmed,cursor:r.value.cursor,wallet_changed:r.value.wallet_changed,recovery_pending:r.value.recovery_pending,errorStatus:r.value.error?.status};}),startupFailed:document.getElementById('startup')?.textContent==='Unable to start game.'})`),1000,'diagnostics');}catch(_){}
  console.error(`Wallet UI regression failed: ${label}`);
   console.error(JSON.stringify({diagnostics,state,captures,fixtureTrace}));
   try{console.error(JSON.stringify(await bounded(evaluate('walletUiChecks.replies.map(r=>({serial:r.serial,op:r.operation,started:r.started,finished:r.finished}))'),1000,'request timing diagnostics')));}catch(_){}
  process.exitCode=1;
}
finally {
  timer.stop();
  if(connection?.isOpen&&context)try{await bounded(connection.send('Target.disposeBrowserContext',{browserContextId:context}),1000,'context disposal');}catch(_){}
  connection?.close(); await stopBrowser(browser); await removeProfile(profile);
}
