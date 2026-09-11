const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runBounded } = require('../scripts/process-deadline.mjs');
test('test watchdog kills a worker that ignores termination', {timeout:6000}, async () => {
  const start = Date.now();
  const result = await runBounded(process.execPath, ['-e', "process.on('SIGTERM',()=>{}); setInterval(()=>{},1000)"], {stdio:'ignore'}, {timeoutMs:1000, graceMs:100});
  assert.equal(result.timedOut,true);
  assert.ok(Date.now()-start<4000);
});
test('test watchdog passes a normal worker and reports launch failure promptly', async () => {
  assert.deepEqual(await runBounded(process.execPath,['-e','process.exit(0)'],{stdio:'ignore'},{timeoutMs:3000}),{code:0,timedOut:false});
  await assert.rejects(runBounded('/nonexistent-fixture-binary',[],{stdio:'ignore'},{timeoutMs:1000}),/ENOENT/);
});
