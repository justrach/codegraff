const { app, BrowserWindow } = require('electron');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const assert = require('node:assert/strict');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-visual-'));
app.setPath('userData', path.join(temporary, 'profile'));
let server, win;
const deadline = setTimeout(() => { console.error('Visual run exceeded 240 seconds'); finish(1); }, 240000);
app.whenReady().then(async () => {
  const root = path.resolve(__dirname, '..'), output = process.env.GRAFF_VISUAL_OUTPUT || path.resolve(root, '../../zig-out/visual-tests');
  fs.mkdirSync(output, { recursive: true });
  assert.ok(fs.existsSync(path.join(root, '.next/BUILD_ID')), 'Run bun run build before visual tests.');
  const socket = net.createServer(); await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
  const port = socket.address().port; await new Promise(resolve => socket.close(resolve));
  const origin = `http://127.0.0.1:${port}`;
  const log = fs.openSync(path.join(output, 'server.log'), 'w');
  server = spawn(process.env.GRAFF_TEST_BUN || 'bun', ['node_modules/next/dist/bin/next', 'start', '--port', String(port), '--hostname', '127.0.0.1'], { cwd: root, env: { ...process.env, GRAFF_VISUAL_TESTS: '1', GRAFF_DESKTOP_TOKEN: '', NEXT_TELEMETRY_DISABLED: '1' }, detached: true, stdio: ['ignore', log, log] });
  fs.closeSync(log);
  for (let i = 0; i < 100; i++) { try { if ((await fetch(`${origin}/visual-tests`)).ok) break; } catch {} if (i === 99) throw Error('Visual fixture server did not start'); await sleep(100); }
  win = new BrowserWindow({ width: 900, height: 600, show: true, webPreferences: { sandbox: true, contextIsolation: true, nodeIntegration: false, backgroundThrottling: false } });
  app.focus({ steal: true }); win.show(); win.focus();
  const apiRequests = [];
  win.webContents.session.webRequest.onBeforeRequest((details, callback) => {
    const url = new URL(details.url);
    if (url.origin === origin && url.pathname.startsWith('/api/')) apiRequests.push(url.pathname);
    callback({ cancel: !details.url.startsWith(origin) && !details.url.startsWith('data:') || url.pathname.startsWith('/api/') });
  });
  await win.loadURL(`${origin}/visual-tests`);
  const js = source => win.webContents.executeJavaScript(source);
  const wait = async source => { for (let i = 0; i < 100; i++) { if (await js(source)) return; await sleep(50); } throw Error(`Visual check timed out: ${source}`); };
  await wait(`!!document.querySelector('[data-case="waiting"]')`);
  await js('document.fonts.ready.then(()=>true)');
  const cases = { starting: 'Starting Graff…', thinking: 'Thinking…', writing: 'Writing response…', running: 'Running 1 tool…', waiting: 'Waiting for Graff…', done: 'Turn finished', stopped: 'Stopped', error: 'Response interrupted', 'missing-result': 'Turn finished' };
  const results = [];
  for (const theme of ['light', 'dark', 'codegraff']) {
    await js(`document.querySelector('[data-theme-choice="${theme}"]').click()`);
    for (const [name, label] of Object.entries(cases)) {
      console.log('Visual:', theme, name);
      await js(`document.querySelector('[data-case="${name}"]').click()`);
      await wait(`document.querySelector('[data-turn-activity]')?.textContent.includes(${JSON.stringify(label)})`);
      await js(`Promise.all(document.getAnimations().filter(a=>a.effect?.getTiming().iterations!==Infinity).map(a=>a.finished.catch(()=>{}))).then(()=>true)`);
      await js('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))');
      assert.equal(await js(`getComputedStyle(document.querySelector('article')).opacity`), '1');
      const rect = await js(`(()=>{const a=document.querySelector('[data-turn-activity]').getBoundingClientRect(),b=document.querySelector('[data-fixture-composer]').getBoundingClientRect();return {top:a.top,bottom:a.bottom,width:a.width,composer:b.top,viewport:innerHeight}})()`);
      assert.ok(rect.width > 100 && rect.top > 0 && rect.bottom < rect.composer && rect.composer < rect.viewport, JSON.stringify(rect));
      if (name === 'waiting') assert.match(await js(`document.querySelector('[data-activity-detail]').textContent`), /since the last event/);
      const summary = await js(`document.querySelector('[data-tool-summary]')?.getAttribute('aria-expanded')`);
      if (summary !== undefined) assert.equal(summary, 'false', 'progress never auto-expands tool details');
      if (['done', 'stopped', 'error', 'missing-result'].includes(name)) assert.equal(await js(`document.querySelector('article').getAttribute('aria-busy')`), 'false');
      fs.writeFileSync(path.join(output, `${theme}-${name}.png`), (await win.webContents.capturePage()).toPNG());
      results.push(`${theme}/${name}`);
    }
  }
  await require('./stress-visual.cjs').runStressVisuals({ win, origin, output });
  await require('./navigation-visual.cjs').runNavigationVisuals({ win, origin, output });
  await require('./agents-visual.cjs').runAgentVisuals({ win, origin, output });
  if (process.env.GRAFF_PERFORMANCE_TESTS) await require('./performance-scenarios.cjs').runPerformance({ win, origin, output });
  assert.deepEqual(apiRequests, [], 'Visual fixtures must not call the engine or model APIs');
  fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify({ passed: results, apiRequests }, null, 2));
  console.log(`${results.length} visual scenarios passed. No engine or model API calls. Screenshots: ${output}`);
}).then(() => finish(0)).catch(error => { console.error(error); finish(1); });
function finish(code) {
  clearTimeout(deadline);
  if (win && !win.isDestroyed()) win.destroy();
  if (server?.pid) try { process.kill(-server.pid, 'SIGTERM'); } catch {}
  app.once('quit', () => { fs.rmSync(temporary, { recursive: true, force: true }); });
  app.exit(code);
}
