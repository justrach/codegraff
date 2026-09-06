const { BrowserWindow } = require('electron');
const { BrowserTabs } = require('./browser-tabs.cjs');
const { startAutomation } = require('./automation.cjs');
const { callTool } = require('./desktop-tools.cjs');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
async function runDevPreview({ output }) {
  const root = path.join(output, 'dev-project'); fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({ scripts: { dev: 'bun server.ts' } }));
  fs.writeFileSync(path.join(root, 'server.ts'), `const server=Bun.serve({port:0,hostname:'127.0.0.1',fetch(){return new Response(Bun.file('index.html'),{headers:{'content-type':'text/html'}})}});console.log(server.url.href);`);
  const html = title => `<!doctype html><title>${title}</title><h1>${title}</h1><input id="name" aria-label="Name"><button id="go" onclick="document.querySelector('h1').textContent='Hello '+document.querySelector('input').value">Greet</button>`;
  fs.writeFileSync(path.join(root, 'index.html'), html('Initial preview'));
  const bun = process.env.GRAFF_TEST_BUN || 'bun';
  const child = spawn(bun, ['run', 'dev'], { cwd: root, detached: true, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, PATH: `${path.dirname(bun)}:${process.env.PATH}` } });
  const win = new BrowserWindow({ width: 900, height: 600, show: true });
  const events = [], browser = new BrowserTabs(win, event => events.push(event));
  let bridge;
  try {
    const url = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(Error('Bun dev server did not start')), 10000);
      let text = ''; child.stdout.on('data', chunk => { text += chunk; const match = text.match(/http:\/\/127\.0\.0\.1:\d+\//); if (match) { clearTimeout(timer); resolve(match[0]); } });
      child.once('error', error => { clearTimeout(timer); reject(error); });
      child.once('exit', code => { clearTimeout(timer); reject(Error(`Dev server exited: ${code}`)); });
    });
    bridge = await startAutomation(browser, null, null);
    const handle = bridge.handle('preview-test');
    const env = { GRAFF_DESKTOP_ENDPOINT: `http://127.0.0.1:${handle.port}`, GRAFF_DESKTOP_SECRET: handle.token, GRAFF_DESKTOP_CHAT: 'preview-test' };
    const tool = args => callTool('browser', args, env);
    await tool({ action: 'open', url });
    browser.setBounds('preview-test', { x: 0, y: 0, width: 900, height: 550 });
    assert.ok(events.some(e => e.type === 'show'), 'Opening a preview requests the shared browser pane');
    assert.match(JSON.stringify(await tool({ action: 'snapshot' })), /Initial preview/);
    await tool({ action: 'fill', selector: '#name', text: 'Codegraff' });
    await tool({ action: 'click', selector: '#go' });
    assert.match(JSON.stringify(await tool({ action: 'snapshot' })), /Hello Codegraff/);
    fs.writeFileSync(path.join(root, 'index.html'), html('Updated preview'));
    await tool({ action: 'navigate', url });
    assert.match(JSON.stringify(await tool({ action: 'snapshot' })), /Updated preview/);
    const shot = await tool({ action: 'screenshot' });
    const image = shot.content.find(c => c.type === 'image'); assert.ok(image?.data);
    fs.writeFileSync(path.join(output, 'bun-dev-preview.png'), Buffer.from(image.data, 'base64'));
    console.log('Bun dev preview passed through desktop tool transport: open, snapshot, fill, click, edit/reload, screenshot.');
  } finally {
    browser.closeAll(); bridge?.server.close(); win.destroy();
    if (child.pid) try { process.kill(-child.pid, 'SIGTERM'); } catch {}
  }
}
module.exports = { runDevPreview };
