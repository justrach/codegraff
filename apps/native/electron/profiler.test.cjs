const { test } = require('node:test');
const assert = require('node:assert/strict');
const { Profiler } = require('./profiler.cjs');
test('profiler reports only approved measurements and compares phases', async () => {
  let memory = 100;
  const p = new Profiler(async () => ({ rssMiB: memory, cpuPercent: 2, processes: 3, browsers: 1, url: 'https://private.example', prompt: 'SECRET', path: '/Users/private' }));
  await p.start(); p.record('page-loaded', 30); p.record('SECRET', 20);
  p.mark('candidate'); memory = 80; await p.capture(4); p.stop();
  const report = p.report();
  assert.equal(report.comparison.meanRssMiBDelta, -20);
  assert.equal(report.events.length, 1);
  assert.doesNotMatch(JSON.stringify(report), /SECRET|private\.example|\/Users\/private/);
  assert.throws(() => p.mark('private project name'), /Phase/);
});
test('profiler is idle by default and bounds event retention', () => {
  const p = new Profiler(async () => ({}));
  p.record('page-loaded', 1); assert.equal(p.report().events.length, 0);
  p.active = true;
  for (let i = 0; i < 1500; i++) p.record('renderer-long-task', i);
  assert.equal(p.report().events.length, 1000); p.stop();
});
test('CPU time parser preserves fractions and hour fields', () => {
  const { cpuMilliseconds } = require('./process-metrics.cjs');
  assert.equal(cpuMilliseconds('2:01.50'), 121500);
  assert.equal(cpuMilliseconds('1:02:03.25'), 3723250);
});
