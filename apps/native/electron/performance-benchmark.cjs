const testDesktop = require('./test-desktop.cjs');
// Same workload for both builds. Hidden by default; display measurements opt in.
// Usage: electron electron/performance-benchmark.cjs /absolute/app/root /absolute/output
const { app, BrowserWindow, ipcMain, screen, contentTracing } = require('electron');
require('./test-window.cjs').installTestWindowPolicy(app);
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const assert = require('node:assert/strict');
const { installGalleryFixture } = require('./gallery-fixture.cjs');
const { installPerformanceWorkload, frameRecorder, summarizeFrames } = require('./performance-workload.cjs');
const { treeSample } = require('./process-metrics.cjs');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const root = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const dist = process.env.GRAFF_NEXT_DIST_DIR || '.next';
const output = path.resolve(process.argv[3] || path.join(root, '../../zig-out/performance/current'));
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-benchmark-'));
app.setPath('userData', path.join(temporary, 'profile'));
let server, win;
const deadline = setTimeout(() => { console.error('Benchmark exceeded 180 seconds'); finish(1); }, 180000);

app.whenReady().then(async () => {
  console.log('Benchmark: launching isolated production app');
  fs.mkdirSync(output, { recursive: true });
  assert.ok(fs.existsSync(path.join(root, dist, 'BUILD_ID')), 'Build the selected app first');
  // Match production accessibility policy; never disable assistive technology.
  if (fs.readFileSync(path.join(root, 'electron/main.cjs'), 'utf8').includes('app.setAccessibilitySupportEnabled(true)')) app.setAccessibilitySupportEnabled(true);
  for (const [channel, result] of [['updates', { status: 'unavailable', currentVersion: '1.0.0', automatic: false, interactive: false }], ['projects', null], ['browser', null]]) ipcMain.handle(channel, () => result);
  const socket = net.createServer();
  await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  const origin = `http://127.0.0.1:${port}`;
  const log = fs.openSync(path.join(output, 'server.log'), 'w');
  const standalone = !fs.existsSync(path.join(root, 'node_modules/next/dist/bin/next'));
  server = spawn(process.env.GRAFF_TEST_BUN || 'bun', standalone ? ['server.js'] : ['node_modules/next/dist/bin/next', 'start', '--port', String(port), '--hostname', '127.0.0.1'], {
    cwd: root, env: { ...process.env, PORT: String(port), HOSTNAME: '127.0.0.1', GRAFF_VISUAL_TESTS: '1', GRAFF_DESKTOP_TOKEN: '', NEXT_TELEMETRY_DISABLED: '1' }, detached: process.env.GRAFF_TEST_MANAGED_GROUP !== '1', stdio: ['ignore', log, log]
  });
  fs.closeSync(log);
  let spawnError;
  server.on('error', error => { spawnError = error; });
  const readyDeadline = Date.now() + 20000;
  for (;;) {
    if (spawnError) throw spawnError;
    if (server.exitCode !== null || server.signalCode) throw Error('Benchmark server exited before becoming ready; see server.log');
    try { if ((await fetch(origin, { signal: AbortSignal.timeout(500) })).ok) break; } catch {}
    if (Date.now() >= readyDeadline) throw Error('Benchmark server did not start within 20 seconds');
    await sleep(100);
  }
  win = testDesktop.createWindow({ width: 1440, height: 920, titleBarStyle: 'hiddenInset',
    webPreferences: { preload: path.join(root, 'electron/preload.cjs'), sandbox: true, contextIsolation: true, nodeIntegration: false, backgroundThrottling: true } });
  testDesktop.present(win);
  const wc = win.webContents, js = code => wc.executeJavaScript(code);
  await wc.loadURL('about:blank');
  wc.on('console-message', event => { if (/Error|error|Illegal/.test(event.message || '')) console.error('Benchmark renderer:', event.message); });
  const wait = async expression => {
    for (let i = 0; i < 1200; i++) { if (await js(expression)) return; await sleep(25); }
    throw Error(`Benchmark timeout: ${expression}`);
  };
  const unexpected = [];
  wc.session.webRequest.onBeforeRequest((details, callback) => {
    const url = new URL(details.url);
    const blocked = url.origin !== origin && !details.url.startsWith('data:') || url.pathname.startsWith('/api/');
    if (url.origin === origin && url.pathname.startsWith('/api/')) unexpected.push(url.pathname);
    callback({ cancel: blocked });
  });
  testDesktop.attachTestDebugger(wc);
  await wc.debugger.sendCommand('Page.enable');
  await wc.debugger.sendCommand('Performance.enable');
  await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument', { source: `(${installGalleryFixture.toString()})();(${installPerformanceWorkload.toString()})()` });
  console.log('Benchmark: loading renderer');
  await wc.loadURL(origin);
  console.log('Benchmark: waiting for composer');
  await wait(`!!document.querySelector('textarea[aria-label="Prompt"]')`);
  await js('document.fonts.ready.then(()=>true)');
  const metrics = async () => Object.fromEntries((await wc.debugger.sendCommand('Performance.getMetrics')).metrics.map(({ name, value }) => [name, value]));
  const memory = async () => {
    // Force collection only at defined checkpoints to compare retained allocations.
    await wc.debugger.sendCommand('HeapProfiler.collectGarbage');
    await sleep(100);
    const [tree, renderer] = await Promise.all([treeSample(process.pid), metrics()]);
    return { summedProcessRssMiB: tree.rssMiB, processes: tree.processes,
      rendererHeapMiB: renderer.JSHeapUsedSize / 1048576, domNodes: renderer.Nodes,
      processMetrics: app.getAppMetrics().map(item => ({ type: item.type, rssMiB: item.memory.workingSetSize / 1024 })) };
  };
  const send = async name => {
    await js(`(()=>{window.benchmarkCase=${JSON.stringify(name)};const input=document.querySelector('textarea[aria-label="Prompt"]');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(input,'Run the synthetic '+window.benchmarkCase+' workload');input.dispatchEvent(new Event('input',{bubbles:true}));})()`);
    await wait(`!document.querySelector('[aria-label="Send"]').disabled`);
    await js(`document.querySelector('[aria-label="Send"]').click()`);
    await wait(`!!document.querySelector('article[aria-busy="true"]')`);
    await wait(`!document.querySelector('article[aria-busy="true"]')`);
  };
  const run = async (name, action) => {
    console.log('Benchmark:', name);
    await js(`(${frameRecorder.toString()})()`);
    const before = await metrics();
    const start = Date.now();
    await action();
    await sleep(500);
    const raw = await js('window.stopBenchmarkFrames()');
    const after = await metrics();
    const result = { name, elapsedMs: Date.now() - start, frames: summarizeFrames(raw),
      scriptMs: 1000 * (after.ScriptDuration - before.ScriptDuration),
      layoutMs: 1000 * (after.LayoutDuration - before.LayoutDuration),
      styleMs: 1000 * (after.RecalcStyleDuration - before.RecalcStyleDuration),
      memory: await memory(), transcript: await js(`(()=>{const e=document.querySelector('[data-chat-transcript]');return e?{following:e.dataset.following,tailDistance:e.scrollHeight-e.clientHeight-e.scrollTop,articles:e.querySelectorAll('article').length}:null})()`) };
    fs.writeFileSync(path.join(output, `${name}-frames.json`), JSON.stringify(raw));
    console.log(JSON.stringify(result));
    return result;
  };
  console.log('Benchmark: warmup');
  await send('warmup'); await sleep(1500);
  const report = { workloadVersion: 2, testDesktop: testDesktop.assertSafe(), build: fs.readFileSync(path.join(root, dist, 'BUILD_ID'), 'utf8').trim(),
    runtime: { electron: process.versions.electron, chrome: process.versions.chrome },
    display: (() => { const display = screen.getDisplayMatching(win.getBounds()); return { frequencyHz: display.displayFrequency, scaleFactor: display.scaleFactor, window: win.getBounds() }; })(),
    acceleration: app.getGPUFeatureStatus(), accessibility: app.accessibilitySupportEnabled,
    note: 'Identical synthetic workload, fresh app profile, production build, no engine calls. RSS is summed process RSS (shared pages can be double counted). Heap checkpoints follow explicit GC. rAF measures callback scheduling, not presentation. Trace is separate from memory workloads.',
    idle: await memory(), scenarios: [] };
  const startTrace = () => contentTracing.startRecording({ recording_mode: 'record-until-full', included_categories: ['cc', 'benchmark', 'viz', 'gpu', 'input', 'devtools.timeline', 'disabled-by-default-devtools.timeline.frame'], trace_buffer_size_in_kb: 32768 });
  if (process.env.GRAFF_BENCHMARK_CASES === 'history') {
    report.scenarios.push(await require('./history-performance.cjs').historyPerformance({wc,run,wait,output}));
  } else {
  for (let i = 1; i <= 3; i++) {
    if (i === 1 && process.env.GRAFF_BENCHMARK_TRACE === 'code') await startTrace();
    report.scenarios.push(await run(`code-${i}`, () => send('code')));
    if (i === 1 && process.env.GRAFF_BENCHMARK_TRACE === 'code') await contentTracing.stopRecording(path.join(output, 'code-trace.json'));
  }
  if (process.env.GRAFF_BENCHMARK_REQUIRE_BOUNDED_HISTORY === '1') {
    assert.ok(await js(`document.querySelectorAll('article').length <= 2`), 'Long live tails should retire older rendered code replies');
    assert.ok(await js(`Array.from(document.querySelectorAll('button')).some(b=>b.textContent.startsWith('Show earlier messages'))`), 'Older live replies must remain available');
  }
  if (process.env.GRAFF_BENCHMARK_TRACE === 'mermaid') await startTrace();
  report.scenarios.push(await run('mermaid', async () => {
    await send('mermaid');
    await wait(`!!document.querySelector('[data-streamdown="mermaid-block"] svg')`);
  }));
  if (process.env.GRAFF_BENCHMARK_TRACE === 'mermaid') await contentTracing.stopRecording(path.join(output, 'mermaid-trace.json'));
  report.scenarios.push(await run('prose', () => send('prose')));
  const scroll = async () => {
    // Real wheel input exercises Chromium's scroll path, including main-thread listeners.
    const point = await js(`(()=>{const r=document.querySelector('[data-chat-transcript]').getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()`);
    for (let i = 0; i < 360; i++) {
      await testDesktop.testInput(wc, { type: 'mouseWheel', ...point, deltaY: i % 180 < 90 ? -24 : 24, deltaX: 0, canScroll: true });
      await sleep(8);
    }
  };
  report.scenarios.push(await run('scroll', scroll));
  if (process.env.GRAFF_BENCHMARK_TRACE && !['0', 'code', 'mermaid'].includes(process.env.GRAFF_BENCHMARK_TRACE)) {
    await startTrace();
    await scroll();
    await contentTracing.stopRecording(path.join(output, 'scroll-trace.json'));
  }
  }
  // Closing the only chat must release renderer content; global caches remain observable.
  // Saved history opens a second tab; release it and the warm-up conversation.
  for (let i = 0; i < 10 && await js(`!!document.querySelector('article')`); i++) {
    wc.send('desktop-action', 'close'); await sleep(150);
  }
  await wait(`!document.querySelector('article')`); await sleep(1500);
  report.afterClose = await memory();
  report.unexpectedApiRequests = unexpected;
  assert.deepEqual(unexpected, [], 'Benchmark must not call engine/model APIs');
  fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
  console.log('Benchmark complete:', output);
}).then(() => finish(0)).catch(error => { console.error(error); finish(1); });

function finish(code) {
  clearTimeout(deadline);
  try { console.log('Test desktop:', JSON.stringify(testDesktop.assertSafe())); }
  catch (error) { console.error(error); code = 1; }
  testDesktop.cleanup();
  if (server?.pid) try { if (process.env.GRAFF_TEST_MANAGED_GROUP === '1') server.kill('SIGTERM'); else process.kill(-server.pid, 'SIGTERM'); } catch {}
  fs.rmSync(temporary, { recursive: true, force: true });
  app.exit(code);
}
process.on('SIGTERM', () => finish(1));
process.on('SIGINT', () => finish(1));
