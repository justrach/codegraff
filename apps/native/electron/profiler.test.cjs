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
test('restarting a recording cannot import an in-flight sample from the previous recording', async () => {
  let finish;
  const p = new Profiler(() => new Promise(resolve => { finish = resolve; }));
  const old = p.start();
  p.stop(); await p.start();
  finish({ rssMiB: 900 }); await old;
  assert.equal(p.report().samples.length, 0); p.stop();
});
test('hardware and renderer reporting never exports device identity or unsupported metrics as zero', async () => {
  const { chromiumSample } = require('./hardware-profile.cjs');
  assert.deepEqual(chromiumSample([{ type: 'GPU', cpu: { percentCPUUsage: 4 }, memory: { workingSetSize: 2048 }, name: 'PRIVATE' }]), { gpuProcessCpuPercent: 4, gpuProcessRssMiB: 2 });
  const p = new Profiler(async () => ({ lcpMs: 120, interactionMaxMs: null, rendererHeapMiB: 12, domNodes: 90 }), () => {}, () => ({ gpu_compositing: 'enabled', webgpu: 'SECRET', renderer: 'PRIVATE' }));
  await p.start(); p.stop(); const report = p.report();
  assert.equal(report.acceleration.gpu_compositing, 'enabled');
  assert.equal(report.acceleration.webgpu, 'unknown');
  assert.equal(report.baseline.peaks.interactionMaxMs, null);
  assert.equal(report.baseline.peaks.lcpMs, 120);
  assert.equal(report.gpuUtilizationPercent, null);
  assert.doesNotMatch(JSON.stringify(report), /SECRET|PRIVATE/);
});
test('renderer observers stay off until recording and disconnect on stop', () => {
  const { collectRendererMetrics } = require('./renderer-profile.cjs');
  const originalObserver = globalThis.PerformanceObserver, originalDocument = globalThis.document;
  const observers = [];
  globalThis.PerformanceObserver = class {
    static supportedEntryTypes = ['largest-contentful-paint', 'paint', 'event', 'layout-shift'];
    constructor(callback) { this.callback = callback; observers.push(this); }
    observe(options) { this.options = options; }
    disconnect() { this.disconnected = true; }
  };
  globalThis.document = { getElementsByTagName: () => Array(20) };
  try {
    collectRendererMetrics(false); assert.equal(observers.length, 0);
    collectRendererMetrics(true); assert.equal(observers.length, 4);
    observers[0].callback({ getEntries: () => [{ startTime: 150, url: 'SECRET', element: 'PRIVATE' }] });
    observers[2].callback({ getEntries: () => [{ duration: 48, interactionId: 1, target: 'PRIVATE' }] });
    const metrics = collectRendererMetrics(true);
    assert.equal(metrics.lcpMs, 150); assert.equal(metrics.interactionMaxMs, 48);
    assert.equal(observers.length, 4); assert.doesNotMatch(JSON.stringify(metrics), /SECRET|PRIVATE/);
    collectRendererMetrics(false); assert.ok(observers.every(observer => observer.disconnected));
  } finally { collectRendererMetrics(false); globalThis.PerformanceObserver = originalObserver; globalThis.document = originalDocument; }
});
