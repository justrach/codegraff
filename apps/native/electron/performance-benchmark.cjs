// Same workload for both builds. Runs a visible production renderer in an isolated profile.
// Usage: electron electron/performance-benchmark.cjs /absolute/app/root /absolute/output
const { app, BrowserWindow, ipcMain, screen, contentTracing } = require('electron');
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
const output = path.resolve(process.argv[3] || path.join(root, '../../zig-out/performance/current'));
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-benchmark-'));
app.setPath('userData', path.join(temporary, 'profile'));
let server, win;
const deadline = setTimeout(() => { console.error('Benchmark exceeded 180 seconds'); finish(1); }, 180000);

app.whenReady().then(async () => {
  console.log('Benchmark: launching isolated production app');
  fs.mkdirSync(output, { recursive: true });
  assert.ok(fs.existsSync(path.join(root, '.next/BUILD_ID')), 'Build the selected app first');
  // Match production accessibility policy; never disable assistive technology.
  if (fs.readFileSync(path.join(root, 'electron/main.cjs'), 'utf8').includes('app.setAccessibilitySupportEnabled(true)')) app.setAccessibilitySupportEnabled(true);
  for (const [channel, result] of [['updates', { status: 'unavailable', currentVersion: '1.0.0', automatic: false, interactive: false }], ['projects', null], ['browser', null]]) ipcMain.handle(channel, () => result);
  const socket = net.createServer();
  await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  const origin = `http://127.0.0.1:${port}`;
  const log = fs.openSync(path.join(output, 'server.log'), 'w');
  server = spawn(process.env.GRAFF_TEST_BUN || 'bun', ['node_modules/next/dist/bin/next', 'start', '--port', String(port), '--hostname', '127.0.0.1'], {
    cwd: root, env: { ...process.env, GRAFF_VISUAL_TESTS: '1', GRAFF_DESKTOP_TOKEN: '', NEXT_TELEMETRY_DISABLED: '1' }, detached: true, stdio: ['ignore', log, log]
  });
  fs.closeSync(log);
  for (let i = 0; i < 200; i++) {
    try { if ((await fetch(origin, { signal: AbortSignal.timeout(1000) })).ok) break; } catch {}
    if (i === 199) throw Error('Benchmark server did not start');
    await sleep(100);
  }
  win = new BrowserWindow(require('./test-window.cjs').testWindowOptions({ width: 1440, height: 920, titleBarStyle: 'hiddenInset',
    webPreferences: { preload: path.join(root, 'electron/preload.cjs'), sandbox: true, contextIsolation: true, nodeIntegration: false, backgroundThrottling: true } }));
  require('./test-window.cjs').presentWindow(win, app);
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
  wc.debugger.attach('1.3');
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
      memory: await memory() };
    fs.writeFileSync(path.join(output, `${name}-frames.json`), JSON.stringify(raw));
    console.log(JSON.stringify(result));
    return result;
  };
  console.log('Benchmark: warmup');
  await send('warmup'); await sleep(1500);
  const report = { workloadVersion: 2, build: fs.readFileSync(path.join(root, '.next/BUILD_ID'), 'utf8').trim(),
    runtime: { electron: process.versions.electron, chrome: process.versions.chrome },
    display: (() => { const display = screen.getDisplayMatching(win.getBounds()); return { frequencyHz: display.displayFrequency, scaleFactor: display.scaleFactor, window: win.getBounds() }; })(),
    acceleration: app.getGPUFeatureStatus(), accessibility: app.accessibilitySupportEnabled,
    note: 'Identical synthetic workload, fresh app profile, production build, no engine calls. RSS is summed process RSS (shared pages can be double counted). Heap checkpoints follow explicit GC. rAF measures callback scheduling, not presentation. Trace is separate from memory workloads.',
    idle: await memory(), scenarios: [] };
  const startTrace = () => contentTracing.startRecording({ recording_mode: 'record-until-full', included_categories: ['cc', 'benchmark', 'viz', 'gpu', 'input', 'devtools.timeline', 'disabled-by-default-devtools.timeline.frame'], trace_buffer_size_in_kb: 32768 });
  for (let i = 1; i <= 3; i++) {
    if (i === 1 && process.env.GRAFF_BENCHMARK_TRACE === 'code') await startTrace();
    report.scenarios.push(await run(`code-${i}`, () => send('code')));
    if (i === 1 && process.env.GRAFF_BENCHMARK_TRACE === 'code') await contentTracing.stopRecording(path.join(output, 'code-trace.json'));
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
      wc.sendInputEvent({ type: 'mouseWheel', ...point, deltaY: i % 180 < 90 ? -24 : 24, deltaX: 0, canScroll: true });
      await sleep(8);
    }
  };
  report.scenarios.push(await run('scroll', scroll));
  if (process.env.GRAFF_BENCHMARK_TRACE && !['0', 'code', 'mermaid'].includes(process.env.GRAFF_BENCHMARK_TRACE)) {
    await startTrace();
    await scroll();
    await contentTracing.stopRecording(path.join(output, 'scroll-trace.json'));
  }
  // Closing the only chat must release renderer content; global caches remain observable.
  wc.send('desktop-action', 'close');
  await wait(`!document.querySelector('article')`); await sleep(1500);
  report.afterClose = await memory();
  report.unexpectedApiRequests = unexpected;
  assert.deepEqual(unexpected, [], 'Benchmark must not call engine/model APIs');
  fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
  console.log('Benchmark complete:', output);
}).then(() => finish(0)).catch(error => { console.error(error); finish(1); });

function finish(code) {
  clearTimeout(deadline);
  if (win && !win.isDestroyed()) win.destroy();
  if (server?.pid) try { process.kill(-server.pid, 'SIGTERM'); } catch {}
  fs.rmSync(temporary, { recursive: true, force: true });
  app.exit(code);
}
process.on('SIGTERM', () => finish(1));
process.on('SIGINT', () => finish(1));
