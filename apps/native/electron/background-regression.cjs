const { app, BrowserWindow, WebContentsView } = require('electron');
const assert = require('node:assert/strict');
const { createWindow, present, focusTestPage, testInput, assertSafe, cleanup, foreground } = require('./test-desktop.cjs');
const os = require('node:os'), fs = require('node:fs'), path = require('node:path');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-background-'));
app.setPath('userData', path.join(temporary, 'profile'));
app.on('window-all-closed', () => {}); // The test, not the last fixture window, owns exit status.
const deadline = setTimeout(() => finish(1), 30000);
async function finish(code) {
  clearTimeout(deadline);
  try { assertSafe(); } catch (error) { console.error(error); code = 1; }
  cleanup(); fs.rmSync(temporary, { recursive: true, force: true }); app.exit(code);
}
app.whenReady().then(async () => {
  assert.equal(foreground, false, 'The background regression must run without foreground opt-in');
  for (let n = 0; n < 3; n++) {
    const win = createWindow({ width: 640, height: 480, show: true, webPreferences: { sandbox: true } });
    present(win);
    const wc = win.webContents;
    await wc.loadURL('data:text/html,' + encodeURIComponent('<input id="first"><button id="second" onclick="document.body.dataset.clicked=event.isTrusted">Second</button>'));
    await focusTestPage(wc);
    await wc.executeJavaScript('document.querySelector("#first").focus()');
    await testInput(wc, { type: 'keyDown', keyCode: 'Tab' });
    await testInput(wc, { type: 'keyUp', keyCode: 'Tab' });
    assert.equal(await wc.executeJavaScript('document.activeElement.id'), 'second', 'Hidden Chromium still performs real Tab navigation');
    const point = await wc.executeJavaScript('(()=>{const r=document.querySelector("#second").getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()');
    await testInput(wc, { type: 'mouseDown', button: 'left', clickCount: 1, ...point });
    await testInput(wc, { type: 'mouseUp', button: 'left', clickCount: 1, ...point });
    assert.equal(await wc.executeJavaScript('document.body.dataset.clicked'), 'true', 'Pointer events stay trusted without desktop input');
    if (n === 1) {
      const view = new WebContentsView({ webPreferences: { sandbox: true, backgroundThrottling: true } });
      win.contentView.addChildView(view); view.setBounds({ x: 0, y: 100, width: 400, height: 200 });
      const page = view.webContents;
      await page.loadURL('data:text/html,' + encodeURIComponent('<input><script>document.addEventListener("keydown",e=>document.body.dataset.key=e.key)</script>'));
      await testInput(page, { type: 'keyDown', keyCode: 'Escape' });
      assert.equal(await page.executeJavaScript('document.body.dataset.key'), 'Escape', 'Input reaches an embedded page without native window focus');
      win.contentView.removeChildView(view); page.close();
    }
    assert.ok(!(await wc.capturePage()).isEmpty(), 'Hidden windows still render screenshots');
    assert.throws(() => win.show(), /GRAFF_TEST_FOREGROUND/);
    assert.throws(() => win.focus(), /GRAFF_TEST_FOREGROUND/);
    assertSafe();
    if (n !== 1) win.destroy(); // Leave one nested window for failure-style cleanup.
  }
  cleanup();
  assert.equal(BrowserWindow.getAllWindows().length, 0);
  console.log('Background regression passed: repeated hidden windows, trusted Tab/pointer input, embedded page input, screenshots, blocked activation and complete cleanup.');
}).then(() => finish(0)).catch(error => { console.error(error); finish(1); });
