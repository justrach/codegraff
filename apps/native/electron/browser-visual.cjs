const testDesktop = require('./test-desktop.cjs');
const { BrowserWindow, ipcMain, nativeImage } = require('electron');
const { BrowserTabs } = require('./browser-tabs.cjs');
const { browserAction } = require('./browser-actions.cjs');
const assert = require('node:assert/strict');
const http = require('node:http');
const path = require('node:path');
const fs = require('node:fs');
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function runBrowserVisuals({ win: fixtureWindow, origin, output }) {
  if (!require('./test-window.cjs').visibleWindowCheck('embedded browser native pin input and captures')) return;
  const fixture = http.createServer((_req, res) => {
    res.setHeader('content-type', 'text/html');
    res.end('<!doctype html><title>Pin fixture</title><style>body{margin:0;background:#e5f3ff}button{margin:50px;width:180px;height:80px}article{height:1600px}</style><button id="target" onpointerdown="document.body.dataset.activated=1" onclick="document.body.dataset.clicked=1">Choose this element</button><article>Scroll fixture</article>');
  });
  await new Promise(r => fixture.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${fixture.address().port}/`;
  const win = testDesktop.createWindow({ width: 1000, height: 760, webPreferences: { preload: path.join(__dirname, 'preload.cjs'), sandbox: true, contextIsolation: true } });
  const wc = win.webContents, js = code => wc.executeJavaScript(code);
  const browser = new BrowserTabs(win, event => wc.send('browser-event', event));
  ipcMain.handle('browser', (_event, { chat, method, params }) => ['find', 'zoom'].includes(method) ? browserAction(browser, chat, method, params) : browser.command(chat, method, params));
  const pin = (event, value) => { if (event.sender === browser.tabs.get('browser-test')?.view?.webContents) { void testDesktop.focusTestPage(wc); wc.send('browser-event', { type: 'pin', chat: 'browser-test', pin: value }); } };
  const cancelled = event => { if (event.sender === browser.tabs.get('browser-test')?.view?.webContents) wc.send('browser-event', { type: 'pick-cancelled', chat: 'browser-test' }); };
  ipcMain.on('browser-pin', pin); ipcMain.on('browser-pick-cancelled', cancelled);
  const wait = async (fn, what) => { for (let i = 0; i < 100; i++) { if (await fn()) return; await sleep(50); } throw Error(`Browser visual timed out: ${what}`); };
  try {
    fixtureWindow.hide();
    testDesktop.present(win);
    await win.loadURL(`${origin}/visual-tests/browser?url=${encodeURIComponent(url)}`);
    await wait(() => js(`!!document.querySelector('[aria-pressed="false"]:not(:disabled)')`), 'pin control');
    await wait(() => browser.tabs.get('browser-test')?.view?.webContents.getURL() === url, 'fixture URL');
    const page = browser.tabs.get('browser-test').view.webContents;
    const picking = () => page.executeJavaScript(`!![...document.querySelectorAll('div')].some(el => el.textContent === 'Click an element to pin · Esc to cancel')`);
    await wait(async () => !page.isLoading(), 'page idle');
    await wait(() => { const rect = browser.tabs.get('browser-test')?.rect; return rect && rect.width > 80 && rect.height > 80; }, 'page bounds');
    await js(`document.querySelector('button[aria-pressed]').click()`);
    await wait(() => js(`document.querySelector('button[aria-pressed]').getAttribute('aria-pressed')==='true'`), 'pick armed');
    await wait(() => picking(), 'pick mode on page');
    await testDesktop.focusTestPage(page);
    await testDesktop.testInput(page, { type: 'keyDown', keyCode: 'Escape' });
    await wait(() => js(`document.querySelector('button[aria-pressed]').getAttribute('aria-pressed')==='false'`), 'Escape cancel');
    await js(`document.querySelector('button[aria-pressed]').click()`);
    await wait(() => picking(), 'pick mode after recancel');
    await testDesktop.testInput(page, { type: 'mouseMove', x: 100, y: 80 });
    await testDesktop.testInput(page, { type: 'mouseDown', x: 100, y: 80, button: 'left', clickCount: 1 });
    await testDesktop.testInput(page, { type: 'mouseUp', x: 100, y: 80, button: 'left', clickCount: 1 });
    await wait(() => js(`!!document.querySelector('[aria-label="Note for pin 1"]')`), 'pin note');
    await wait(() => page.executeJavaScript(`document.querySelector('[data-graff-pins]')?.textContent==='1'`), 'pin marker');
    assert.equal(await page.executeJavaScript('document.body.dataset.activated || document.body.dataset.clicked || null'), null, 'pinning must not activate the target');
    assert.equal(await js(`document.activeElement.getAttribute('aria-label')`), 'Note for pin 1');
    for (const zoom of [1, 1.25]) {
      wc.setZoomFactor(zoom); await sleep(200);
      const rect = await js(`(()=>{const r=document.querySelector('aside .bg-canvas').getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}})()`);
      browser.setBounds('browser-test', rect);
      assert.equal(browser.tabs.get('browser-test').view.getBounds().x, Math.round(rect.x * zoom));
      const shot = await browserAction(browser, 'browser-test', 'screenshot');
      const image = nativeImage.createFromBuffer(Buffer.from(shot.data, 'base64'));
      assert.ok(!image.isEmpty() && image.getSize().width > 100);
      assert.ok(shot.viewport.width > 100 && shot.imageSize.height > 100);
      // The known blue background distinguishes an actual page grab from an empty frame.
      const pixel = image.toBitmap(); assert.ok(pixel[0] > 220 && pixel[1] > 220 && pixel[2] > 200);
      fs.writeFileSync(path.join(output, `browser-capture-${zoom}.png`), image.toPNG());
    }
    fs.writeFileSync(path.join(output, 'browser-pin.png'), (await wc.capturePage()).toPNG());
    await js(`document.querySelector('[aria-label="Remove pin 1"]').click()`);
    await wait(() => page.executeJavaScript(`!document.querySelector('[data-graff-pins]')?.textContent`), 'pin removed');
    await wc.loadURL('about:blank'); // Leave the pane so its ResizeObserver no longer reattaches it.
    browser.hide('browser-test');
    const hidden = await browserAction(browser, 'browser-test', 'screenshot'); assert.ok(hidden.data.length > 100);
    assert.equal(browser.visible, null, 'capture leaves inactive page hidden');
    browser.release(browser.tabs.get('browser-test'));
    await assert.rejects(browserAction(browser, 'browser-test', 'screenshot'), /closed or suspended/);
    console.log('Browser visuals passed: pin/cancel/numbered markers/remove, no target activation, zoom geometry, real and hidden PNG captures, suspended errors.');
  } finally {
    ipcMain.removeHandler('browser'); ipcMain.removeListener('browser-pin', pin); ipcMain.removeListener('browser-pick-cancelled', cancelled);
    browser.closeAll(); win.destroy(); fixture.close(); testDesktop.present(fixtureWindow);
  }
}
module.exports = { runBrowserVisuals };
