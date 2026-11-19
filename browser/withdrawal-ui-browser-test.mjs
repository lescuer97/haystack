// Real renderer/input/CDK functional regression. No screenshots or public wallets.
import {bounded, CdpConnection, discoverEndpoint, launchBrowser, makeProfile, removeProfile, stopBrowser, watchdog} from './cdp-runner.mjs';
const origin = new URL(process.argv[2]);
if (origin.protocol !== 'http:' || origin.hostname !== '127.0.0.1' || !origin.port) throw new Error('Local fixture required');
const profile = await makeProfile('haystack-withdrawal-ui-');
const browser = launchBrowser(profile);
let connection, context, session, label = 'startup';
const send = (method, params = {}) => connection.send(method, params, session);
async function evaluate(expression) {
  const result = await send('Runtime.evaluate', {expression, awaitPromise:true, returnByValue:true});
  if (result.exceptionDetails) throw new Error('Evaluation failed');
  return result.result?.value;
}
async function expect(name, expression) {
  label = name;
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (await evaluate(expression)) { console.log(`ok - ${name}`); return; }
    await new Promise(resolve => setTimeout(resolve, 60));
  }
  throw new Error('Functional check failed');
}
const frames = () => evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r(true))))');
// Two 20 Hz game ticks, independent of how quickly display frames are drawn.
const settleTicksExpression = `new Promise(resolve=>{
  const start=performance.now();
  function tick(now){if(now-start>=100)resolve(true);else requestAnimationFrame(tick);}
  requestAnimationFrame(tick);
})`;
const settleTicks = () => evaluate(settleTicksExpression);
async function key(key, code, number) {
  await send('Input.dispatchKeyEvent', {type:'rawKeyDown', key, code, windowsVirtualKeyCode:number});
  // Use only a short display-frame hold, not 100ms logical settling,
  // to avoid deliberately triggering directional repeat.
  await frames();
  await send('Input.dispatchKeyEvent', {type:'keyUp', key, code, windowsVirtualKeyCode:number});
  await settleTicks();
}
async function click(x, y) {
  await send('Input.dispatchMouseEvent', {type:'mouseMoved',x,y});
  await settleTicks();
  await send('Input.dispatchMouseEvent', {type:'mousePressed',button:'left',clickCount:1,x,y});
  await frames();
  await send('Input.dispatchMouseEvent', {type:'mouseReleased',button:'left',clickCount:1,x,y});
  await settleTicks();
}
// Shared layout's documented dimensions, used only to target real input events.
async function row(page, index) {
  const [count, content, extra, width] = {
    Main:[2,0,0,420], Wallet:[5,62,0,420], Deposit:[7,62,0,420],
    Invoice:[3,340,0,760], Withdraw:[5,62,112,760], Withdrawal:[2,320,0,760],
  }[page];
  const height = Math.min(592,40+44+content+extra+count*56+(count-1)*10);
  const scale = Math.min((height-40-44)/(content+extra+count*56+(count-1)*10),1);
  const top = (640-height)/2+20+44+content*scale;
  await click(500,top+index*66*scale+(index>0?extra*scale:0)+(56+(index===0?extra:0))*scale/2);
}
const idle = () => expect('renderer consumes reply before next action', `(async()=>{if(checks.active)return false;const count=checks.requests.length;await ${settleTicksExpression};return !checks.active&&checks.requests.length===count})()`);
async function counts() {
  const reply = await fetch(new URL('/test-withdrawal-counts',origin));
  if (!reply.ok) throw new Error('Fixture counts unavailable');
  return reply.json();
}
async function invoice(sats = 21, pending = false) {
  const reply = await fetch(new URL(`/test-withdrawal-invoice?sats=${sats}&description_bytes=600&pending=${pending}`,origin));
  if (!reply.ok) throw new Error('Fixture invoice unavailable');
  const value = await reply.json();
  if (typeof value.invoice !== 'string' || value.invoice.length <= 1024 || value.invoice.length > 4096) throw new Error('Fixture invoice length invalid');
  return value.invoice;
}
const instrumentation = `(() => {
  window.checks={generation:crypto.randomUUID(),active:0,overlap:false,errors:0,requests:[],replies:[],operations:{},events:[],snapshot:null,history:null,paste:'',pasteDelivered:0,pasteBytes:0,recoveryPending:true,creationRecovery:null,recoverySerial:0,holdPrepare:false,release:null};
  addEventListener('error',()=>checks.errors++);addEventListener('unhandledrejection',()=>checks.errors++);
  Object.defineProperty(navigator,'clipboard',{value:{readText:async()=>checks.paste,writeText:async()=>{throw Error('Unexpected copy')}}});
  Object.defineProperty(window,'haystackOnboarding',{configurable:true,get(){return this.__bridge},set(bridge){
    this.__bridge=bridge;const request=bridge.walletRequest,deliver=bridge.deliver,bind=bridge.bindInput;
    bridge.bindInput=function(probe,paste,success){
      // Observe only the already registered clipboard callback; never invoke a wallet pointer.
      const lookup=globalThis.getWasmTableEntry;
      if(typeof lookup!=='function')throw Error('Clipboard callback observer unavailable');
      globalThis.getWasmTableEntry=function(index){const fn=lookup(index);if(index!==paste)return fn;return function(ptr,len){const result=fn(ptr,len);checks.pasteDelivered++;checks.pasteBytes=len;return result}};
      return bind.apply(this,arguments);
    };
    bridge.walletRequest=function(g,s,o){if(++checks.active>1)checks.overlap=true;checks.requests.push(o);checks.operations[s]=o;return request.apply(this,arguments)};
    bridge.deliver=function(callback,g,s,text,startup,limit){
      if(limit===131072){
        const operation=checks.operations[s];
        if(operation===9&&checks.holdPrepare){checks.holdPrepare=false;const args=arguments;checks.release=()=>{checks.release=null;bridge.deliver.apply(bridge,args)};return}
        checks.active--;const value=typeof text==='string'?JSON.parse(text):null;
        checks.replies.push({operation,serial:s,value});
        if(typeof value?.recovery_pending==='boolean'){checks.recoveryPending=value.recovery_pending;checks.recoverySerial=s}
        if(typeof value?.creation_recovery==='string')checks.creationRecovery=value.creation_recovery;
        if(value?.sats!==undefined)checks.snapshot=value;
        if(Array.isArray(value?.rows))checks.history=value;
      }else if(typeof text==='string')checks.events.push(JSON.parse(text).event);
      return deliver.apply(this,arguments);
    };
  }});
})();`;
async function openWallet() { await settleTicks(); await key('Escape','Escape',27); await row('Main',0); }
async function openWithdraw() { await row('Wallet',2); }
async function paste(text) {
  const delivered = await evaluate('checks.pasteDelivered');
  await evaluate(`checks.paste=${JSON.stringify(text)}`);
  await row('Withdraw',1); // Trusted Paste gesture reads the stubbed clipboard.
  await expect('trusted clipboard callback receives complete atomic invoice',`checks.pasteDelivered===${delivered+1} && checks.pasteBytes===${Buffer.byteLength(text,'utf8')}`);
  await settleTicks(); // Consume the clipboard mailbox before Review is activated.
}
async function reviewWithdrawal() {
  await expect('CDK recovery is clear before explicit Review',`(async()=>{
    if(checks.recoveryPending||checks.creationRecovery!=='none'||checks.active)return false;
    const serial=checks.recoverySerial;
    await ${settleTicksExpression};
    return !checks.recoveryPending&&checks.creationRecovery==='none'&&!checks.active&&checks.recoverySerial===serial;
  })()`);
  const prepares = await evaluate('checks.requests.filter(n=>n===9).length');
  await row('Withdraw',3);
  await expect('explicit Review queues exactly one preparation',`checks.requests.filter(n=>n===9).length===${prepares+1}`);
}
async function run() {
  connection = await CdpConnection.connect(await discoverEndpoint(browser));
  ({browserContextId:context}=await connection.send('Target.createBrowserContext',{disposeOnDetach:true}));
  const {targetId}=await connection.send('Target.createTarget',{url:new URL('/wallet/cdk_wallet_browser.js',origin).href,browserContextId:context});
  ({sessionId:session}=await connection.send('Target.attachToTarget',{targetId,flatten:true}));
  await send('Page.enable');await send('Runtime.enable');
  await send('Emulation.setDeviceMetricsOverride',{width:1000,height:640,deviceScaleFactor:1,mobile:false});
  await expect('isolated fixture origin',`location.origin===${JSON.stringify(origin.origin)}`);
  // A fresh random wallet via the production onboarding service, never a saved user seed.
  await evaluate(`(async()=>{const m=await import('/wallet/cdk_wallet_browser.js');await m.default();const s=await m.start_onboarding(m.onboarding_mint());try{await s.request('inspect','{}');await s.request('create','{}');const r=JSON.parse(await s.request('complete_backup','{}'));if(r.event!=='complete_success')throw 0}finally{await s.close();s.free()}return true})()`);
  await send('Page.addScriptToEvaluateOnNewDocument',{source:instrumentation});
  await send('Page.navigate',{url:new URL('/renderer/index.html',origin).href});
  await expect('Ready real renderer wallet','window.checks?.snapshot?.sats==="0" && checks.events.includes("ready")');
  await evaluate('document.getElementById("canvas").focus()');
  await openWallet();await row('Wallet',1);await row('Deposit',4);
  // Wallet navigation requests a snapshot. Wait for its reply to be consumed
  // before the one explicit Create click; busy actions must not be replayed.
  await idle();
  const fundingStart = await evaluate('({generation:checks.generation,creates:checks.requests.filter(n=>n===2).length,replies:checks.replies.length})');
  await row('Deposit',5);
  await expect('one explicit funding deposit request is published',`checks.generation===${JSON.stringify(fundingStart.generation)} && checks.requests.filter(n=>n===2).length===${fundingStart.creates+1}`);
  await expect('funding reply saves the requested 1000-sat quote',`checks.generation===${JSON.stringify(fundingStart.generation)} && checks.replies.slice(${fundingStart.replies}).some(r=>r.operation===2&&r.value?.amount==='1000'&&typeof r.value.id==='string'&&r.value.id.length>0&&typeof r.value.invoice==='string'&&r.value.invoice.length>0)`);
  const funding = await evaluate(`(()=>{const r=checks.replies.slice(${fundingStart.replies}).find(r=>r.operation===2&&r.value?.amount==='1000');return {serial:r.serial,id:r.value.id,amount:r.value.amount}})()`);
  await expect('actual CDK funding balance','checks.snapshot?.sats==="1000"');
  await expect('funding retains its original reply and has no duplicate create',`checks.generation===${JSON.stringify(fundingStart.generation)} && checks.requests.filter(n=>n===2).length===${fundingStart.creates+1} && checks.replies.some(r=>r.operation===2&&r.serial===${funding.serial}&&r.value?.id===${JSON.stringify(funding.id)}&&r.value.amount===${JSON.stringify(funding.amount)})`);
  await idle();await row('Invoice',2);await openWithdraw();
  await paste('not-a-lightning-invoice');await reviewWithdrawal();
  await expect('invalid invoice has typed feedback and cannot produce a confirmation','checks.replies.some(r=>r.operation===9&&r.value?.operation_error?.status===2)');
  if ((await counts()).melt_posts!==0) throw new Error('Invalid input submitted payment');
  // Failed preparation remains unknown until explicit Back; no automatic quote retry.
  await row('Withdrawal',1);await openWithdraw();
  await paste(await invoice(2000));await reviewWithdrawal();
  await expect('insufficient funds has distinct typed feedback and completes the request','checks.replies.some(r=>r.operation===9&&r.value?.operation_error?.status===14) && !checks.active');
  if ((await counts()).melt_posts!==0) throw new Error('Insufficient funds submitted payment');
  await row('Withdrawal',1);await openWithdraw();
  const long = await invoice();
  await paste(long);await reviewWithdrawal();
  await expect('long invoice traverses full renderer buffer and bridge',`checks.replies.some(r=>r.operation===9&&r.value?.invoice===${JSON.stringify(long)})`);
  await idle();
  const review = await evaluate('checks.replies.findLast(r=>r.operation===9&&r.value)?.value');
  for (const field of ['amount','fee_reserve','swap_fee','input_fee','estimated_total','quote_expiry','invoice_expiry']) {
    if (typeof review[field]!=='string' || !/^\d+$/.test(review[field])) throw new Error('Invalid CDK review decimal field');
  }
  if ((await counts()).melt_posts!==0) throw new Error('Review submitted payment');
  await row('Withdrawal',1);
  await expect('Cancel uses exact ephemeral operation and rereads actual funds','checks.replies.some(r=>r.operation===11&&r.value?.cancelled) && checks.snapshot?.sats==="1000"');
  if ((await counts()).melt_posts!==0) throw new Error('Cancel submitted payment');
  // Delay only delivery, not Rust/CDK: close during preparation must cancel on arrival.
  await evaluate('checks.holdPrepare=true');await paste(await invoice());await reviewWithdrawal();
  await expect('preparation reply held at renderer boundary','!!checks.release');
  const cancels = await evaluate('checks.requests.filter(n=>n===11).length');
  await key('Escape','Escape',27);await evaluate('checks.release();true');
  await expect('closed inflight preparation cancelled before recovery',`checks.requests.filter(n=>n===11).length===${cancels+1} && checks.snapshot?.sats==="1000" && !checks.active`);
  if ((await counts()).melt_posts!==0) throw new Error('Abandoned review submitted payment');
  await openWallet();await openWithdraw();
  const paidInvoice = await invoice();await paste(paidInvoice);await reviewWithdrawal();
  await expect('new explicit review available',`checks.replies.some(r=>r.operation===9&&r.value?.invoice===${JSON.stringify(paidInvoice)}) && !checks.active`);
  await idle();await row('Withdrawal',0);await row('Withdrawal',0); // Double activation must consume one token.
  await expect('explicit confirmation returns the saved CDK payment','checks.replies.some(r=>r.operation===10&&["pending","completed"].includes(r.value?.payment_status))');
  const paid = await evaluate('checks.replies.findLast(r=>r.operation===10&&r.value)?.value');
  await expect('explicitly authorized payment actually completes in CDK',`checks.replies.some(r=>{
    const view=r.operation===13?r.value?.withdrawal:r.operation===10?r.value:null;
    return view?.quote_id===${JSON.stringify(paid.quote_id)}&&view.payment_status==='completed';
  })`);
  // Native CDK primary test: zero-input-fee FakeWallet spends 64 for a 63-sat invoice.
  // This fixture uses the same one-sat routing fee, so 21 sat settles at 978, not a reservation balance.
  await expect('actual completed-payment balance is 978 sat','checks.snapshot?.sats==="978" && !checks.active');
  const balance = await evaluate('checks.snapshot.sats');
  if ((await counts()).melt_posts!==1) throw new Error('Explicit payment was not exactly once');
  await row('Withdrawal',1);await row('Wallet',3);
  const paidHistory = `checks.history?.rows.some(r=>r.direction==='Out'&&r.id===${JSON.stringify(paid.quote_id)}&&r.payment_status==='completed'&&typeof r.quote_expiry==='string'&&/^[0-9]+$/.test(r.quote_expiry)&&r.expired===false&&typeof r.created_at==='string'&&/^[0-9]+$/.test(r.created_at))`;
  await expect('outgoing history persists completed status and expiry from CDK',paidHistory);
  const generation = await evaluate('checks.generation');await send('Page.reload');
  await expect('reload rereads authoritative balance',`window.checks?.generation!==${JSON.stringify(generation)} && checks.snapshot?.sats===${JSON.stringify(balance)}`);
  await evaluate('document.getElementById("canvas").focus()');await openWallet();await row('Wallet',3);
  await expect('withdrawal survives restart with completed status and expiry',`${paidHistory} && !checks.active`);
  const index = await evaluate(`checks.history.rows.findIndex(r=>r.id===${JSON.stringify(paid.quote_id)})`);
  // History content: 352 scaled with the one Back row; first eight rows unchanged.
  const h=40+44+352+56, top=(640-h)/2+20+44;
  await click(500,top+(index+0.5)*352/8);
  await expect('completed history selection is read-only local CDK lookup',`checks.replies.some(r=>r.operation===12&&r.value?.quote_id===${JSON.stringify(paid.quote_id)}&&r.value.payment_status==='completed')`);
  await row('Withdrawal',0);
  if (await evaluate('checks.requests.some(n=>n===9||n===10)')) throw new Error('History enabled a payment');
  if ((await counts()).melt_posts!==1) throw new Error('Reload duplicated payment');
  const mode = await fetch(new URL('/test-withdrawal-mode?mode=pending',origin));
  if(!mode.ok)throw new Error('Pending fixture mode unavailable');
  await row('Withdrawal',1);await openWithdraw();
  await paste(await invoice(21,true));await reviewWithdrawal();await idle();await row('Withdrawal',0);
  await expect('explicit second payment is actually Pending in CDK','checks.replies.some(r=>r.operation===10&&r.value?.payment_status==="pending")');
  const pending = await evaluate('checks.replies.findLast(r=>r.operation===10&&r.value?.payment_status==="pending").value');
  if((await counts()).melt_posts!==2)throw new Error('Pending confirmation did not submit exactly once');
  await key('Escape','Escape',27);
  await expect('closed-menu CDK checks retain Pending',`checks.replies.some(r=>r.operation===13&&r.value?.withdrawal?.quote_id===${JSON.stringify(pending.quote_id)}&&r.value.withdrawal.payment_status==='pending')`);
  const pendingGeneration = await evaluate('checks.generation');await send('Page.reload');
  await expect('held Pending survives fresh document and startup recovery',`window.checks?.generation!==${JSON.stringify(pendingGeneration)} && !!checks.snapshot`);
  await evaluate('document.getElementById("canvas").focus()');await openWallet();await row('Wallet',3);
  await expect('local history reports Pending rather than UNPAID alone or EXPIRED',`checks.history?.rows.some(r=>r.id===${JSON.stringify(pending.quote_id)}&&r.direction==='Out'&&r.payment_status==='pending'&&r.expired===false) && !checks.active`);
  if((await counts()).melt_posts!==2)throw new Error('Pending polling or reload duplicated POST');
  const release = await fetch(new URL('/test-withdrawal-mode?mode=paid',origin));
  if(!release.ok)throw new Error('Pending fixture release unavailable');
  // The native fixture verifies CDK's second selection needs no paid routing fee: 957 sat.
  await expect('released Pending completes through CDK checks without confirmation',`checks.replies.some(r=>(r.operation===13?r.value?.withdrawal:r.operation===12?r.value:null)?.quote_id===${JSON.stringify(pending.quote_id)}&&(r.operation===13?r.value?.withdrawal:r.value)?.payment_status==='completed') && checks.snapshot?.sats==='957' && !checks.active`);
  if((await counts()).melt_posts!==2)throw new Error('Recovery issued another payment POST');
  await expect('no uncaught renderer error or overlapping wallet request','!checks.errors && !checks.overlap');
}
const timer=watchdog(240000,'withdrawal UI');
const work=run();work.catch(()=>{});
try { await Promise.race([work,timer.promise]); }
catch (_) {
  let state = null;
  try {
    state = await bounded(evaluate(`(()=>{
      const c=window.checks;if(!c)return null;
      const id=value=>typeof value==='string'?value.slice(0,128).replace(/[^a-zA-Z0-9_.:/-]/g,'?'):null;
      const balance=c.snapshot?.sats;
      return {active:c.active,overlap:c.overlap,errors:c.errors,
        knownBalance:typeof balance==='string'&&/^[0-9]{1,20}$/.test(balance)?balance:null,
        requests:c.requests.slice(-64),pendingFlags:{heldPrepare:!!c.release,holdNextPrepare:c.holdPrepare,recovery:c.recoveryPending,creationRecovery:c.creationRecovery},
        operations:Object.entries(c.operations).slice(-64).map(([serial,op])=>({serial,op})),
        replies:c.replies.slice(-64).map(r=>({op:r.operation,serial:r.serial,quoteID:id(r.value?.quote_id),
          checkedID:id(r.value?.checked_id),payment_status:id(r.value?.payment_status??r.value?.withdrawal?.payment_status),
          recovery_pending:r.value?.recovery_pending,errorStatus:r.value?.operation_error?.status??r.value?.error?.status,
          failed:r.value===null})),
        history:c.history?.rows.map(r=>({quoteID:id(r.id),payment_status:id(r.payment_status),expired:r.expired}))};
    })()`),1000,'sanitized diagnostics');
  } catch (_) {}
  console.error(`Withdrawal UI regression failed: ${label}`);
  console.error(JSON.stringify(state));
  process.exitCode=1;
}
finally {
  timer.stop();
  if(connection?.isOpen&&context)try{await bounded(connection.send('Target.disposeBrowserContext',{browserContextId:context}),1000,'context disposal')}catch(_){}
  connection?.close();await stopBrowser(browser);await removeProfile(profile);
}
