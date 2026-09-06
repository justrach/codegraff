const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { ipcMain } = require('electron');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function run({ win, browser, automation, backend, metrics, activity, computer, profiler }) {
  const report = {};
  const fixture = http.createServer((_req, res) => {
    res.setHeader('content-type', 'text/html');
    res.end('<!doctype html><title>Browser fixture</title><label>Name <input id="name"></label><button id="button" onclick="this.textContent=\'Clicked\'">Click me</button>');
  });
  await new Promise(resolve => fixture.listen(0, '127.0.0.1', resolve));
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-acp-electron-'));
  try {
    await win.webContents.executeJavaScript("localStorage.setItem('graff.native.browser.open','0')");
    await win.loadURL(backend.origin);
    await sleep(1500);
    assert.equal(browser.liveCount, 0);
    report.ui = await require('./smoke-ui.cjs').smokeUI({ win, browser, backend });
    const catalog = await win.webContents.executeJavaScript(`fetch('/api/models').then(r=>r.json())`);
    assert.ok(catalog.result.current.model); assert.ok(catalog.result.models.length > 0);
    assert.ok(catalog.result.current.effortLevels.length > 0);
    report.catalog = { current: catalog.result.current.model, effort: catalog.result.current.effort };
    await profiler.start();
    report.idle = await metrics();
    assert.equal((await fetch(`${backend.origin}/api/acp`)).status, 403);
    assert.equal(await win.webContents.executeJavaScript(`fetch('/api/acp').then(r=>r.status)`), 200);
    browser.setBounds('smoke', { x: 700, y: 120, width: 500, height: 500 });
    await browser.navigate('smoke', `http://127.0.0.1:${fixture.address().port}`);
    assert.equal(browser.liveCount, 1);
    const handle = automation.handle('smoke');
    const endpoint = `http://127.0.0.1:${handle.port}/command`;
    const request = async (method, params = {}) => {
      const res = await fetch(endpoint, { method: 'POST', headers: { authorization: `Bearer ${handle.token}`, 'content-type': 'application/json' }, body: JSON.stringify({ chat: 'smoke', method, params }) });
      assert.equal(res.status, 200); return (await res.json()).result;
    };
    assert.equal((await fetch(endpoint, { method: 'POST' })).status, 401);
    assert.match((await request('snapshot')).text, /Click me/);
    assert.equal(await request('evaluate', { expression: 'typeof window.graffDesktop+":"+typeof require' }), 'undefined:undefined');
    await request('fill', { selector: '#name', text: 'ACP browser' });
    assert.equal(await request('evaluate', { expression: 'document.querySelector("#name").value' }), 'ACP browser');
    await request('click', { selector: '#button' });
    assert.match((await request('snapshot')).text, /Clicked/);
    const pinReceived = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { ipcMain.removeListener('browser-pin', listener); reject(new Error('Picker did not send a pin')); }, 3000);
      const listener = (_event, pin) => { clearTimeout(timeout); ipcMain.removeListener('browser-pin', listener); resolve(pin); };
      ipcMain.on('browser-pin', listener);
    });
    await browser.command('smoke', 'pick', { enabled: true });
    const wc = browser.tabs.get('smoke').view.webContents;
    const point = await wc.executeJavaScript('(()=>{const r=document.querySelector("#button").getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()');
    win.show(); win.focus(); wc.focus(); await sleep(300);
    wc.sendInputEvent({type:'mouseMove', ...point});
    wc.sendInputEvent({ type: 'mouseDown', ...point, button: 'left', clickCount: 1 });
    wc.sendInputEvent({ type: 'mouseUp', ...point, button: 'left', clickCount: 1 });
    assert.equal((await pinReceived).element.selector, '#button');
    report.desktop = await require('./smoke-desktop.cjs').smokeDesktop({ automation, computer, win, browser });
    await request('zoom', { factor: 1.2 });
    assert.equal(wc.getZoomFactor(), 1.2);
    await request('zoom', { factor: 1 });
    await request('find', { text: 'Clicked' });
    profiler.mark('candidate'); await profiler.capture(0); profiler.stop();
    report.profiler = profiler.report();
    report.browser = await metrics();
    browser.suspendMs = 100;
    browser.hide('smoke'); await sleep(200);
    assert.equal(browser.liveCount, 0);
    assert.equal(browser.tabs.get('smoke').url, `http://127.0.0.1:${fixture.address().port}/`);
    await browser.navigate('smoke', browser.tabs.get('smoke').url);
    browser.closeAll(); assert.equal(browser.liveCount, 0);
    require('node:child_process').execFileSync('git', ['init', '-q', cwd]);
    fs.writeFileSync(path.join(cwd, 'review.txt'), 'Shared review fixture\n');
    const bootstrap = await win.webContents.executeJavaScript(`fetch('/api/acp',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({chat:'electron-smoke',method:'bootstrap',params:{cwd:${JSON.stringify(cwd)},mcp:false}})}).then(async r=>({status:r.status,body:await r.json()}))`);
    assert.equal(bootstrap.status, 200, JSON.stringify(bootstrap.body));
    assert.ok(bootstrap.body.sessionId); report.acp = 'real graff ACP initialized';
    for (const text of ['/effort high', '/fast on']) {
      const output = await win.webContents.executeJavaScript(`fetch('/api/acp',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({chat:'electron-smoke',method:'session/prompt',params:{prompt:[{type:'text',text:${JSON.stringify(text)}}]}})}).then(r=>r.text())`);
      assert.match(output, /session\/update/);
    }
    const settings = await win.webContents.executeJavaScript(`fetch('/api/acp',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({chat:'electron-smoke',method:'graff/models'})}).then(r=>r.json())`);
    assert.equal(settings.result.current.effort, 'high'); assert.equal(settings.result.current.fast, true);
    const review = await win.webContents.executeJavaScript(`fetch('/api/acp',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({chat:'electron-smoke',method:'graff/changes',params:{action:'status'}})}).then(r=>r.json())`);
    assert.match(review.result.status, /review.txt/);
    const diff = await win.webContents.executeJavaScript(`fetch('/api/acp',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({chat:'electron-smoke',method:'graff/changes',params:{action:'diff',path:'review.txt'}})}).then(r=>r.json())`);
    assert.match(diff.result.diff, /Shared review fixture/);
    report.review = 'real ACP shared status and untracked diff';
    report.settings = 'real ACP effort and fast commands updated harness state';

    await win.webContents.executeJavaScript(`fetch('/api/acp',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({chat:'electron-smoke',method:'dispose'})})`);
    await activity(); report.swiftUI = 'native module loaded and sheet presented';
    await sleep(500);
    const output = process.env.GRAFF_ELECTRON_SMOKE;
    fs.writeFileSync(output, JSON.stringify(report, null, 2));
    console.log('Electron smoke passed: navigation, isolation, pins, automation, suspension, real ACP, SwiftUI.');
  } finally { fixture.close(); fs.rmSync(cwd, { recursive: true, force: true }); }
}
module.exports = { run };
