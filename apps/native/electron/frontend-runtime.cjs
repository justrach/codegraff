// Built UI -> real HTTP route -> real ACP worker. Only the model is scripted.
const desktop = require('./test-desktop.cjs');
const { app, ipcMain, screen } = require('electron');
const { spawn } = require('node:child_process');
const fs = require('node:fs'), path = require('node:path');
const assert = require('node:assert/strict');
const { installWindowState } = require('./window-state.cjs');
const ui = path.resolve(__dirname, '..'), repo = path.resolve(ui, '../..');
const output = path.resolve(process.env.GRAFF_FRONTEND_OUTPUT || path.join(repo, 'zig-out/frontend-tests'));
const temp = process.argv[2];
const htmlTool = process.env.GRAFF_HTML_TOOL_TEST === '1';
assert.ok(temp, 'Launch through scripts/test-frontend.mjs for watchdog and cleanup');
const workspace = path.join(temp, 'workspace');
fs.mkdirSync(workspace); fs.mkdirSync(output, { recursive: true });
app.setPath('userData', path.join(temp, 'profile'));
const cliRequests = require('./workspace-open.cjs').workspaceOpen(target => win.webContents.send('workspace-open', target));
if (process.env.GRAFF_CLI_TEST) {
  // Use the real Electron instance lock; tests never request native focus.
  assert.ok(require('./single-instance.cjs').claimDesktopInstance(app, () => undefined, cliRequests.open, workspace));
}
const children = [], report = { status: 'running', input: 'trusted Chromium', passed: [], skipped: [] };
let win, finished = false;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(condition, label, timeout = 15000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { if (await condition()) return; await sleep(50); }
  throw Error(`Front-end timeout: ${label}`);
}
function child(command, args, env, name) {
  const fd = fs.openSync(path.join(output, `${name}.log`), 'w');
  // Inherit the runner's private group so its external watchdog owns all workers.
  const proc = spawn(command, args, { cwd: ui, env, stdio: ['ignore', fd, fd] });
  fs.closeSync(fd); children.push(proc);
  proc.on('error', finish);
  return proc;
}
async function finish(error) {
  if (finished) return;
  finished = true; clearTimeout(deadline);
  if (error) {
    report.error = error.stack; console.error(error);
    try {
      report.layout = await win.webContents.executeJavaScript(`(() => ({
        viewport: { width: innerWidth, height: innerHeight },
        prompts: Array.from(document.querySelectorAll('textarea[aria-label="Prompt"]')).map(e => {
          const r = e.getBoundingClientRect(), hit = document.elementFromPoint(r.x+r.width/2, r.y+r.height/2);
          return { rect: r.toJSON(), hit: hit?.tagName, hitClass: hit?.className, hitLabel: hit?.getAttribute('aria-label'), visible: e.checkVisibility() };
        })
      }))()`);
      fs.writeFileSync(path.join(output, 'failure.png'), (await win.webContents.capturePage()).toPNG());
    } catch {}
  }
  try { report.desktop = desktop.assertSafe(); } catch (e) { error ||= e; report.error ||= e.message; }
  report.status = error ? 'failed' : report.skipped.length ? 'passed-with-skips' : 'passed';
  fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify(report, null, 2));
  for (const proc of children) proc.kill('SIGTERM');
  desktop.cleanup(); fs.rmSync(temp, { force: true, recursive: true });
  console.log(JSON.stringify(report)); process.exit(error ? 1 : 0);
}
const deadline = setTimeout(() => finish(Error('Front-end suite exceeded 90 seconds')), 90000);
app.whenReady().then(async () => {
  const binary = path.resolve(process.env.GRAFF_FRONTEND_BIN || path.join(repo, 'zig-out/bin/graff'));
  assert.ok(fs.existsSync(binary), 'Build graff before running test:frontend');
  assert.ok(fs.existsSync(path.join(ui, '.next/BUILD_ID')), 'Build the production GUI before running test:frontend');
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.endsWith('_API_KEY')));
  Object.assign(env, { HOME: temp, LMSTUDIO_API_KEY: 'local', GRAFF_CWD: workspace, GRAFF_DESKTOP_TOKEN: '',
    GRAFF_NO_TELEMETRY: '1', GRAFF_FLEET: 'off', GRAFF_NO_SMOLIFY: '1', GRAFF_NO_CODEDB_GUARD: '1', NEXT_TELEMETRY_DISABLED: '1' });
  const mcp = path.join(temp, 'mcp.json'); fs.writeFileSync(mcp, JSON.stringify({mcpServers:htmlTool ? {codegraff_desktop:{command:process.env.GRAFF_TEST_BUN || 'bun',args:[path.join(__dirname,'desktop-mcp.cjs')]}} : {}})); env.GRAFF_MCP_CONFIG = mcp;
  const wrapper = path.join(temp, 'graff');
  fs.writeFileSync(wrapper, '#!/usr/bin/env python3\nimport os,sys\nbinary=' + JSON.stringify(binary) + '\nargs=sys.argv[1:]\nif args and args[0]=="acp": args += ["--model","lmstudio","--yolo"]\nos.execv(binary,[binary]+args)\n', { mode: 0o755 });
  env.GRAFF_BIN = wrapper;
  const script = path.join(temp, 'replies.json');
  fs.writeFileSync(script, JSON.stringify(htmlTool ? [
    {tool:'mcp_search_tools',arguments:{query:'create_html'}},
    {tool:'mcp_select_tool',arguments:{name:'mcp__codegraff_desktop__create_html'}},
    {tool:'mcp__codegraff_desktop__create_html',arguments:{title:require('./html-tool-frontend.cjs').title,html:require('./html-tool-frontend.cjs').html}},
    {text:'Your inline explanation is ready.'},
  ] : [
    { tool: 'bash', arguments: { command: 'printf kept > proof.txt' } },
    { http_status: 400, error: 'Scripted final request rejected' },
    { tool: 'bash', arguments: { command: 'cat proof.txt' } },
    { text: 'The earlier result is still present.' },
  ]));
  const requests = path.join(temp, 'requests.json');
  const model = child('python3', [path.join(repo, 'scripts/eval/frontend_model.py'), '--script', script, '--requests', requests], env, 'model');
  await until(async () => {
    assert.equal(model.exitCode, null, 'Scripted model could not start; port 1234 must be free');
    return fs.readFileSync(path.join(output, 'model.log'), 'utf8').includes('scripted model on');
  }, 'scripted model readiness');
  const net = require('node:net'), probe = net.createServer();
  await new Promise(resolve => probe.listen(0, '127.0.0.1', resolve));
  const port = probe.address().port; await new Promise(resolve => probe.close(resolve));
  const origin = `http://127.0.0.1:${port}`;
  const server = child(process.env.GRAFF_TEST_BUN || 'bun', ['node_modules/next/dist/bin/next', 'start', '--port', String(port), '--hostname', '127.0.0.1'], env, 'server');
  await until(async () => {
    assert.equal(server.exitCode, null, 'Production GUI server exited');
    try { return (await fetch(origin, { signal: AbortSignal.timeout(1000) })).ok; } catch { return false; }
  }, 'production server readiness');
  const area = screen.getPrimaryDisplay().workArea;
  // Exercise the handoff with Browser open on a small desktop: the initial
  // project context can put the composer below the scroll viewport.
  const size = process.env.GRAFF_CLI_TEST || process.env.GRAFF_SPLIT_STRESS ? { width: 1024, height: 664 } : { width: 1320, height: 900 };
  const bounds = desktop.foreground ? { x: area.x+10, y: area.y+10, width: Math.min(size.width, area.width-20), height: Math.min(size.height, area.height-20) } : size;
  win = desktop.createWindow({ ...bounds, webPreferences: {
    preload: path.join(__dirname, 'preload.cjs'), sandbox: true, contextIsolation: true, backgroundThrottling: false,
  } });
  installWindowState(win); ipcMain.handle('browser', () => null);
  const projects = require('./project-store.cjs').projectStore(app.getPath('userData'));
  if (process.env.GRAFF_CLI_TEST) {
    const remembered = path.join(temp, 'remembered'); fs.mkdirSync(remembered);
    await projects.save({ list: [{ path: remembered, name: 'Remembered project' }], active: remembered });
    ipcMain.on('workspace-ready', event => { assert.equal(event.sender, win.webContents); cliRequests.ready(); });
    win.webContents.on('did-start-navigation', (_event, _url, inPlace, mainFrame) => { if (mainFrame && !inPlace) cliRequests.loading(); });
  }
  ipcMain.handle('projects', (_event, { action, value }) => action === 'load' ? projects.load() : projects.save(value));
  // This suite does not download releases or open external browser pages.
  ipcMain.handle('updates', () => ({ status: 'unavailable', automatic: false, interactive: false }));
  const wc = win.webContents, js = code => wc.executeJavaScript(code);
  await wc.loadURL(origin); desktop.present(win);
  if (desktop.foreground) await until(() => win.isFocused(), 'foreground window focus');
  await until(() => js(`!!document.querySelector('[data-workspace-ready="true"] textarea[aria-label="Prompt"]')`), 'workspace and composer ready');
  if (process.env.GRAFF_CLI_TEST) await until(async () => (await projects.load())?.active === fs.realpathSync(workspace), 'startup CLI folder after project restoration');
  let computer;
  if (process.env.GRAFF_FRONTEND_OS_INPUT === '1') {
    assert.ok(desktop.foreground, 'OS input requires explicit foreground opt-in');
    const { ComputerUse } = require('./computer.cjs');
    computer = new ComputerUse(path.join(repo, 'zig-out/native-tests/build'), win);
    if (computer.status().accessibility) { computer.enabled = true; report.input = 'native macOS click and type'; }
    else { report.skipped.push('native OS input: Accessibility permission unavailable'); computer = null; }
    if (process.env.GRAFF_NATIVE_REQUIRE_OS_INPUT === '1') assert.ok(computer, 'Native OS input is required on this runner');
  }
  const click = async selector => {
    let p, previous;
    await until(async () => {
      p = await js(`(()=>{const e=document.querySelector(${JSON.stringify(selector)});if(!e)return null;e.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'});const r=e.getBoundingClientRect();const x=Math.round(r.left+r.width/2),y=Math.round(r.top+r.height/2);return {x,y,hit:e.contains(document.elementFromPoint(x,y))}})()`);
      const settled = p?.hit && previous?.x === p.x && previous?.y === p.y;
      previous = p; return settled;
    }, `stable pointer target: ${selector}`, 5000);
    if (computer) {
      const bounds = win.getContentBounds();
      await computer.command('click', { pid: process.pid, x: bounds.x+p.x, y: bounds.y+p.y });
    } else for (const type of ['mouseDown', 'mouseUp']) await desktop.testInput(wc, { type, button: 'left', clickCount: 1, ...p });
  };
  const send = async text => {
    await click('textarea[aria-label="Prompt"]');
    await until(() => js(`document.activeElement === document.querySelector('textarea[aria-label="Prompt"]')`), 'native composer focus before typing', 5000);
    if (computer) await computer.command('type', { pid: process.pid, text });
    else for (const keyCode of text) await desktop.testInput(wc, { type: 'char', keyCode });
    await until(() => js(`document.querySelector('textarea[aria-label="Prompt"]').value === ${JSON.stringify(text)} && !document.querySelector('[aria-label="Send"]').disabled`), 'typed prompt ready');
    await click('[aria-label="Send"]');
  };
  if(htmlTool) return require('./html-tool-frontend.cjs').runHtmlTool({win,origin,output,temp,workspace,requests,send,click,until,report});
  await send('Write the fixture file, then finish.');
  await until(() => js(`document.body.textContent.includes('Scripted final request rejected') && !document.querySelector('article[aria-busy="true"]')`), 'real failure displayed', 25000);
  assert.equal(fs.readFileSync(path.join(workspace, 'proof.txt'), 'utf8'), 'kept');
  assert.ok(await js(`document.body.textContent.includes('Response interrupted')`));
  assert.equal(await js(`document.querySelectorAll('[data-tool-summary]').length`), 1, 'The completed tool must remain visible');
  assert.equal(await js(`Array.from(document.querySelectorAll('[data-tool-summary]')).some(e=>/\\b(?:running|interrupted)\\b/.test(e.textContent))`), false, 'Completed tools must not become interrupted');
  fs.writeFileSync(path.join(output, 'error-keeps-result.png'), (await wc.capturePage()).toPNG());
  report.passed.push('typed prompt, real file write, explicit error and retained completed tool');
  await send('Read the fixture file and report its state.');
  await until(() => js(`document.body.textContent.includes('The earlier result is still present.') && !document.querySelector('article[aria-busy="true"]')`), 'successful follow-up', 25000);
  const status = () => js(`Array.from(document.querySelectorAll('article')).at(-1)?.textContent.match(/Worked for [^·]+/)?.[0]`);
  const worked = await status(); assert.ok(worked, 'Finished turn must show Worked for');
  await sleep(1200); assert.equal(await status(), worked, 'Finished elapsed time must stay frozen');
  const saved = fs.readdirSync(path.join(workspace, '.graff/sessions')).filter(name => name.endsWith('.session.json'));
  assert.ok(saved.some(name => fs.readFileSync(path.join(workspace, '.graff/sessions', name), 'utf8').includes('kept')), 'Real session must preserve tool output');
  const calls = JSON.parse(fs.readFileSync(requests, 'utf8'));
  assert.equal(calls.length, 4, 'Both turns must execute the scripted tool and terminal reply');
  assert.ok(JSON.stringify(calls.at(-1)).includes('kept'), 'Follow-up must receive retained tool output');
  fs.writeFileSync(path.join(output, 'follow-up-finished.png'), (await wc.capturePage()).toPNG());
  report.passed.push('typed follow-up, real saved history, finished status and frozen elapsed time');
  if (process.env.GRAFF_CLI_TEST) {
    await require('./cli-frontend.cjs').runCliFrontend({ app, win, temp, workspace, output, until, report, projects });
    return;
  }
  if(process.env.GRAFF_SPLIT_STRESS) {
    await require('./split-stress-visual.cjs').runSplitStress({win,output,mixed:process.env.GRAFF_SPLIT_STRESS!=='baseline'});
    report.passed.push('bounded split churn, resize, cancellation and memory checks');
    return;
  }
  await require('./tab-drag-visual.cjs').runTabDrag({ win, origin, output });
  report.passed.push('trusted pointer and keyboard: tab reorder, horizontal/vertical splits, draft retention, Escape and four-pane limit');
}).then(() => finish()).catch(finish);
