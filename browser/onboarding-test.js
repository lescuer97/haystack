import init, {onboarding_mint, start_onboarding} from './wallet/cdk_wallet_browser.js';

const checks = [];
let service;
function check(label, condition) {
  checks.push({label, ok: !!condition});
  if (!condition) throw new Error('check failed');
}
async function request(op, args = {}) {
  return JSON.parse(await service.request(op, JSON.stringify(args)));
}
async function keys(store) {
  const db = await new Promise((resolve, reject) => {
    const r = indexedDB.open('haystack-wallet');
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject();
  });
  try {
    return await new Promise((resolve, reject) => {
      const r = db.transaction(store).objectStore(store).getAllKeys();
      r.onsuccess = () => resolve(r.result);
      r.onerror = () => reject();
    });
  } finally { db.close(); }
}
async function storageKeys() {
  return JSON.stringify(await Promise.all(['mnemonics', 'states', 'onboarding'].map(keys)));
}
async function run() {
  await init();
  check('fixture mint is same origin', onboarding_mint() === location.origin);
  const originalFetch = window.fetch;
  let remoteFetch = false;
  window.fetch = (...args) => { remoteFetch = true; return Promise.reject(new Error()); };
  let rejected = false;
  try { const remote = await start_onboarding('https://mint.minibits.cash/Bitcoin'); remote.close(); }
  catch (_) { rejected = true; }
  finally { window.fetch = originalFetch; }
  check('remote mint rejected before network', rejected && !remoteFetch);
  service = await start_onboarding(onboarding_mint());
  const flow = new URL(location.href).searchParams.get('flow');
  if (flow === 'create') {
    check('initial choice', (await request('inspect')).event === 'choice');
    const before = await storageKeys();
    check('invalid phrase rejected', (await request('restore', {phrase:'invalid'})).event === 'invalid_phrase');
    check('invalid phrase leaves choice and storage unchanged', (await request('inspect')).event === 'choice' && await storageKeys() === before);
    check('create displays backup', (await request('create')).event === 'backup');
    check('complete backup', (await request('complete_backup')).event === 'complete_success');
    check('created wallet ready', (await request('inspect')).event === 'ready');
  } else if (flow === 'restore' && !sessionStorage.getItem('onboarding-reloaded')) {
    check('initial restore choice', (await request('inspect')).event === 'choice');
    window.fetch = () => Promise.reject(new Error());
    let result;
    try { result = await request('restore', {phrase:'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about'}); }
    finally { window.fetch = originalFetch; }
    check('failed scan creates retry-only stage', result.event === 'restore_failed' && result.stage_created === true && result.can_generate_new === false);
    check('generate blocked after failure', (await request('generate')).event === 'blocked');
    const stages = (await keys('mnemonics')).filter(key => typeof key === 'string' && key.startsWith('haystack-recovery-'));
    check('one recovery stage exists', stages.length === 1);
    sessionStorage.setItem('onboarding-stage', stages[0]);
    sessionStorage.setItem('onboarding-checks', JSON.stringify(checks));
    sessionStorage.setItem('onboarding-reloaded', '1');
    service.close(); service = null;
    location.reload();
    return;
  } else if (flow === 'restore') {
    checks.unshift(...JSON.parse(sessionStorage.getItem('onboarding-checks')));
    const resumed = await request('inspect');
    check('reload resumes retry-only failure', resumed.event === 'resume_failed' && resumed.can_generate_new === false);
    const result = await request('retry');
    const zero = result.event === 'restore_finished' && result.report?.spendable_sats === '0' && result.report?.pending_sats === '0' && result.report?.spent_sats === '0' && result.report?.can_generate_new === true;
    if (!zero) window.onboardingSafeResult = {event: ['restore_finished', 'restore_failed', 'blocked'].includes(result.event) ? result.event : 'unexpected', spendable: result.report?.spendable_sats === '0' ? 'zero' : 'nonzero-or-missing', pending: result.report?.pending_sats === '0' ? 'zero' : 'nonzero-or-missing', spent: result.report?.spent_sats === '0' ? 'zero' : 'nonzero-or-missing', can_generate_new: result.report?.can_generate_new === true};
    check('retry returns zero result eligible for generation', zero);
    check('generate displays backup', (await request('generate')).event === 'backup');
    check('complete generated backup', (await request('complete_backup')).event === 'complete_success');
    check('generated wallet ready', (await request('inspect')).event === 'ready');
    const stage = sessionStorage.getItem('onboarding-stage');
    const marker = `retired:${stage.slice('haystack-recovery-'.length)}`;
    check('original stage and retired marker retained', (await keys('mnemonics')).includes(stage) && (await keys('states')).includes(stage) && (await keys('onboarding')).includes(marker));
  } else { check('known flow', false); }
  service.close(); service = null;
  window.onboardingTestReport = {ok:true, checks};
}
run().catch(() => {
  if (service) service.close();
  window.onboardingTestReport = {ok:false, checks, failure:checks.at(-1)?.ok === false ? checks.at(-1).label : 'unexpected test error', ...(window.onboardingSafeResult ? {scan:window.onboardingSafeResult} : {})};
});
