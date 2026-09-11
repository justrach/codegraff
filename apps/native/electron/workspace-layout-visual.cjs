// Headless, synthetic checks against the production GUI. No agent/provider calls.
const testDesktop = require('./test-desktop.cjs');
const { app } = require('electron');
const { spawn } = require('node:child_process');
const { installGalleryFixture } = require('./gallery-fixture.cjs');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const output = path.resolve(root, '../../zig-out/visual-tests/workspace');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-workspace-visual-'));
app.setPath('userData', path.join(temporary, 'profile'));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let server, win;
let stage = "startup";
const deadline = setTimeout(() => { console.error(`Workspace deadline during ${stage}`); finish(1); }, 120000);
app.whenReady().then(async () => {
  fs.mkdirSync(output, { recursive: true });
  const socket = net.createServer();
  await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  const origin = `http://127.0.0.1:${port}`;
  const env = { ...process.env, GRAFF_VISUAL_TESTS: '1', GRAFF_DESKTOP_TOKEN: '', NEXT_TELEMETRY_DISABLED: '1' };
  delete env.__NEXT_PRIVATE_STANDALONE_CONFIG;
  const log = fs.openSync(path.join(output, 'server.log'), 'w');
  server = spawn(process.env.GRAFF_TEST_BUN || 'bun', ['node_modules/next/dist/bin/next', 'start', '--port', String(port), '--hostname', '127.0.0.1'],
    { cwd: root, env, detached: process.env.GRAFF_TEST_MANAGED_GROUP !== '1', stdio: ['ignore', log, log] });
  fs.closeSync(log);
  for (let i = 0; ; i++) {
    try { if ((await fetch(origin)).ok) break; } catch {}
    if (i === 100) throw Error('Production GUI did not start');
    await sleep(100);
  }
  stage = "create hidden window";
  win = testDesktop.createWindow({ width: 1440, height: 920, show: false, webPreferences: {
    sandbox: true, contextIsolation: true, nodeIntegration: false, backgroundThrottling: false,
  } });
  const wc = win.webContents;
  // Start the hidden renderer before sending commands to its Page domain.
  await wc.loadURL('about:blank');
  const unexpected = [];
  wc.session.webRequest.onBeforeRequest((details, callback) => {
    const url = new URL(details.url);
    if (url.origin === origin && url.pathname.startsWith('/api/')) unexpected.push(url.pathname);
    callback({ cancel: url.origin === origin ? url.pathname.startsWith('/api/') : !details.url.startsWith('data:') });
  });
  testDesktop.attachTestDebugger(wc);
  stage = 'enable page debugger';
  await wc.debugger.sendCommand('Page.enable');
  stage = 'install fixture';
  await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument', { source: `(${installGalleryFixture.toString()})();
    const fixtureFetch=window.fetch;
    window.fetch=async(input,options)=>{
      if(String(input).includes('/api/acp') && options?.body && JSON.parse(options.body).method==='session/prompt') {
        const updates=[{sessionUpdate:'tool_call',toolCallId:'todo',title:'todo_write',kind:'think',status:'completed',rawInput:{todos:[{id:'a',content:'Review the layout',status:'in_progress'}]}},
          {sessionUpdate:'agent_message_chunk',content:{type:'text',text:'The layout is ready to inspect.'}}];
        const lines=updates.map(update=>({jsonrpc:'2.0',method:'session/update',params:{sessionId:'demo',update}}));
        lines.push({jsonrpc:'2.0',id:1,result:{stopReason:'end_turn'}});
        return new Response(lines.map(line=>JSON.stringify(line)).join('\\n')+'\\n');
      }
      return fixtureFetch(input,options);
    };` });
  const js = source => { stage = source; return wc.executeJavaScript(source); };
  const wait = async source => {
    for (let i = 0; i < 150; i++) { if (await js(source)) return; await sleep(40); }
    throw Error(`Workspace check timed out: ${source}`);
  };
  const click = async selector => { await js(`document.querySelector(${JSON.stringify(selector)}).click()`); await sleep(100); };
  const key = async (key, extra = {}) => {
    await js(`document.activeElement.dispatchEvent(new KeyboardEvent('keydown',${JSON.stringify({key,bubbles:true,cancelable:true,...extra})}))`);
    await sleep(100);
  };
  stage = "load production GUI";
  await wc.loadURL(origin);
  await wait(`!!document.querySelector('textarea[aria-label="Prompt"]')`);
  await js(`(()=>{const e=document.querySelector('textarea[aria-label="Prompt"]');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,'Check the layout');e.dispatchEvent(new Event('input',{bubbles:true}));})()`);
  await wait(`!document.querySelector('[aria-label="Send"]').disabled`);
  await click('[aria-label="Send"]');
  await wait(`document.querySelector('[aria-label="Show tasks"]').textContent.includes('(1)')`);
  assert.equal(await js(`!!document.querySelector('[data-tasks-sidebar]')`), false, 'Tasks does not open itself');
  await click('[aria-label="Show tasks"]');
  await wait(`!!document.querySelector('[aria-label="Close tasks"]')`);
  await click('[aria-label="Close tasks"]');
  await js(`(()=>{const e=document.querySelector('textarea[aria-label="Prompt"]');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,'Unsent follow-up');e.dispatchEvent(new Event('input',{bubbles:true}));})()`);
  await click('[aria-label="Show agents"]');
  await wait(`!!document.querySelector('[aria-label="Agents panel"]')`);
  assert.equal(await js(`document.querySelector('[data-chat-layout]').parentElement.style.display`), 'none');
  const geometry = await js(`(()=>{const t=document.querySelector('[data-workspace-toolbar]').getBoundingClientRect(),a=document.querySelector('[aria-label="Agents panel"]').getBoundingClientRect();return {toolbar:t.width,agents:a.width,below:a.top>=t.bottom}})()`);
  assert.ok(geometry.below && Math.abs(geometry.toolbar - geometry.agents) < 4, JSON.stringify(geometry));
  await click('[aria-label="Close agents"]');
  assert.equal(await js(`document.querySelector('textarea[aria-label="Prompt"]').value`), 'Unsent follow-up', 'Switching to Agents preserves chat drafts');
  assert.equal(await js(`!!document.querySelector('[data-tasks-sidebar]')`), false, 'Tasks remains dismissed after navigation');
  await key('d', { metaKey: true });
  await wait(`document.querySelectorAll('[data-chat]').length===2`);
  const checkToolbar = async () => {
    const bounds = await js(`(()=>{const bars=[...document.querySelectorAll('[data-workspace-toolbar]')],t=bars[0].getBoundingClientRect();return {count:bars.length,inside:!!bars[0].closest('[data-chat]'),panes:[...document.querySelectorAll('[data-chat]')].map(p=>{const r=p.getBoundingClientRect();return {below:r.top>=t.bottom,left:r.left>=t.left-1,right:r.right<=t.right+1}})}})()`);
    assert.equal(bounds.count, 1); assert.equal(bounds.inside, false);
    assert.ok(bounds.panes.every(p => p.below && p.left && p.right), JSON.stringify(bounds));
  };
  await checkToolbar();
  await js(`document.querySelectorAll('[data-chat]')[1].querySelector('textarea').focus()`);
  await checkToolbar();
  await js('document.fonts.ready.then(()=>true)');
  fs.writeFileSync(path.join(output, 'shared-toolbar-splits.png'), (await wc.capturePage()).toPNG());
  await key('d', { metaKey: true, shiftKey: true });
  await checkToolbar();
  await click('[aria-label="Show agents"]');
  await wait(`!!document.querySelector('[aria-label="Agents panel"]')`);
  fs.writeFileSync(path.join(output, 'agents-workspace.png'), (await wc.capturePage()).toPNG());
  await wc.reload();
  await wait(`!!document.querySelector('[aria-label="Show tasks"]')`);
  assert.equal(await js(`document.querySelector('[aria-label="Show tasks"]').getAttribute('aria-pressed')`), 'false');
  assert.deepEqual(unexpected, [], 'Synthetic checks must never reach real agent APIs');
  console.log('PASS: shared toolbar above horizontal/vertical splits; full-width Agents; Tasks close persists across navigation/reload. No engine calls.');
}).then(() => finish(0)).catch(error => { console.error(error); finish(1); });
function finish(code) {
  clearTimeout(deadline);
  try { testDesktop.assertSafe(); } catch (error) { console.error(error); code = 1; }
  testDesktop.cleanup();
  if (server?.pid) try { process.env.GRAFF_TEST_MANAGED_GROUP === '1' ? server.kill('SIGTERM') : process.kill(-server.pid, 'SIGTERM'); } catch {}
  fs.rmSync(temporary, { recursive: true, force: true });
  app.exit(code);
}
