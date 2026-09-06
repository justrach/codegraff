const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const readline = require('node:readline');
const path = require('node:path');
async function smokeDesktop({ automation, computer, win, browser }) {
  const handle = automation.handle('smoke');
  const child = spawn(path.join(process.resourcesPath, 'bun'), [path.join(__dirname, 'desktop-mcp.cjs')], {
    env: { ...process.env, GRAFF_DESKTOP_ENDPOINT: `http://127.0.0.1:${handle.port}`, GRAFF_DESKTOP_SECRET: handle.token, GRAFF_DESKTOP_CHAT: 'smoke' },
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  let id = 0;
  const waiters = new Map();
  readline.createInterface({ input: child.stdout }).on('line', line => {
    const reply = JSON.parse(line); const waiter = waiters.get(reply.id);
    if (waiter) { clearTimeout(waiter.timer); waiters.delete(reply.id); waiter.resolve(reply.result); }
  });
  function rpc(method, params) {
    return new Promise((resolve, reject) => {
      const next = ++id;
      const timer = setTimeout(() => { waiters.delete(next); reject(new Error('MCP test timeout')); }, 10000);
      waiters.set(next, { resolve, timer });
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: next, method, params }) + '\n');
    });
  }
  try {
    assert.ok((await rpc('initialize', {})).capabilities.tools);
    const catalog = await rpc('tools/list');
    assert.deepEqual(catalog.tools.map(t => t.name), ['profiler', 'browser', 'computer']);
    const invoke = (name, args) => rpc('tools/call', { name, arguments: args });
    const snapshot = await invoke('browser', { action: 'snapshot' });
    assert.match(snapshot.content[0].text, /Browser fixture/);
    const screenshot = await invoke('browser', { action: 'screenshot' });
    assert.equal(screenshot.content[0].type, 'image');
    assert.ok(screenshot.content[0].data.length > 100);
    const status = await invoke('computer', { action: 'status' });
    assert.equal(JSON.parse(status.content[0].text).enabled, false);
    assert.equal((await invoke('computer', { action: 'apps' })).isError, true);
    assert.equal((await invoke('computer', { action: 'requestPermissions' })).isError, true);
    // Native discovery is read-only; never request OS permission from an automated test.
    const apps = computer.native('apps');
    assert.ok(apps.apps.some(app => app.pid === process.pid));
    assert.equal(await win.webContents.executeJavaScript(`fetch('/api/browser').then(r=>r.status)`), 410);
    const permissions = computer.status();
    let nativeInput = process.env.GRAFF_SMOKE_SKIP_INPUT ? 'Skipped interactive input for this run' : 'OS permission unavailable';
    if (!process.env.GRAFF_SMOKE_SKIP_INPUT && permissions.accessibility && permissions.screenRecording) {
      computer.enabled = true;
      try {
        const wc = browser.tabs.get('smoke').view.webContents;
        win.show(); win.focus(); wc.focus();
        await wc.executeJavaScript("document.querySelector('#name').focus();document.querySelector('#name').select()");
        await new Promise(resolve => setTimeout(resolve, 300));
        const tree = await computer.command('snapshot', { pid: process.pid });
        assert.ok(tree.elements.length > 0);
        await computer.command('type', { pid: process.pid, text: 'native-input' });
        await new Promise(resolve => setTimeout(resolve, 300));
        assert.equal(await wc.executeJavaScript("document.querySelector('#name').value"), 'native-input');
        const screen = await computer.command('screenshot');
        assert.ok(screen.data.length > 100); assert.ok(screen.bounds);
        nativeInput = 'native AX snapshot, CGEvent typing into test page, and screen capture passed';
      } finally { computer.enabled = false; }
    }
    return { mcp: 'stdio discovery, browser snapshot/image, disabled computer gate passed', permissions, nativeApps: apps.apps.length, nativeInput };
  } finally { child.stdin.end(); child.kill(); for (const waiter of waiters.values()) clearTimeout(waiter.timer); }
}
module.exports = { smokeDesktop };
