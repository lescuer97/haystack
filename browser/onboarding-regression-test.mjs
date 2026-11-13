// Meta-regressions: a broken game must make the real onboarding runner fail.
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const input = new URL(process.argv[2]);
if (input.protocol !== 'http:' || input.hostname !== '127.0.0.1' || !input.port) throw new Error('Expected local fake mint URL');
const runner = fileURLToPath(new URL('./onboarding-browser-test.mjs', import.meta.url));
const failures = {
  'drop-ready': 'gameplay after ready reload changes persisted grid',
  'drop-complete': 'gameplay after completion changes persisted grid',
  'backup-error': 'no uncaught runtime errors across reload',
  'backup-rejection': 'no uncaught runtime errors across reload',
};

for (const flow of ['create', 'recovery']) {
  for (const [fault, expected] of Object.entries(failures)) {
    const result = await new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [runner, input.href], {
        env:{...process.env, ONBOARDING_TEST_FLOW:flow, ONBOARDING_TEST_FAULT:fault},
        stdio:['ignore', 'pipe', 'pipe'],
      });
      let output = '';
      const collect = chunk => { if (output.length < 64 * 1024) output += chunk; };
      child.stdout.on('data', collect);
      child.stderr.on('data', collect);
      child.once('error', reject);
      child.once('close', code => resolve({code, output}));
    });
    // Require proof that the fault fired AND the intended assertion failed;
    // unrelated startup failures or timeouts must not pass a negative test.
    if (result.code !== 1 ||
        result.output.includes('Disposable onboarding browser profile cleanup failed') ||
        !result.output.includes(`Fault injected: ${fault} (${flow})`) ||
        !result.output.includes(`Onboarding browser test failed or timed out: ${flow}: ${expected}`)) {
      console.error(`Onboarding regression failed: ${flow}/${fault}`);
      process.exitCode = 1;
      break;
    }
    console.log(`ok - ${flow}/${fault} is rejected by its intended assertion`);
  }
  if (process.exitCode) break;
}
