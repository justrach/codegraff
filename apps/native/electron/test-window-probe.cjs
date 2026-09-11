// Real Electron acceptance check, including later windows and activation events.
const { app, BrowserWindow } = require('electron');
const { installTestWindowPolicy, testWindowOptions, presentWindow } = require('./test-window.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
installTestWindowPolicy(app);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-window-probe-'));
app.setPath('userData', temporary);
app.on('window-all-closed', () => {});
const timeout = setTimeout(() => finish(1), 15000);
let win;
assert.equal(require('./single-instance.cjs').claimDesktopInstance(app, () => win), true);
app.whenReady().then(async () => {
  for (let index = 0; index < 3; index++) {
    win = new BrowserWindow(testWindowOptions({ width: 400, height: 300 }));
    presentWindow(win, app);
    await win.loadURL('data:text/html,<style>body{background:rgb(30,150,80)}</style><input id="first"><button id="next">Next</button>');
    assert.equal(win.isVisible(), false); assert.equal(win.isFocusable(), false); assert.equal(win.isFocused(), false);
    for (const action of ['show', 'focus', 'showInactive', 'restore', 'moveTop']) assert.throws(() => win[action](), /#832/);
    assert.throws(() => win.setFullScreen(true), /#832/);
    // The packaged smoke branch must also keep reopen/second-instance hidden.
    process.env.GRAFF_ELECTRON_SMOKE = 'probe';
    app.emit('activate'); app.emit('second-instance');
    delete process.env.GRAFF_ELECTRON_SMOKE;
    await win.webContents.executeJavaScript('document.querySelector("input").focus()');
    win.webContents.sendInputEvent({ type: 'keyDown', keyCode: 'Tab' });
    win.webContents.sendInputEvent({ type: 'keyUp', keyCode: 'Tab' });
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(await win.webContents.executeJavaScript('document.activeElement.id'), 'next');
    assert.equal(win.isFocused(), false);
    const shot = await win.webContents.capturePage();
    assert.ok(!shot.isEmpty());
    assert.equal(win.isVisible(), false, 'capture must leave its window hidden');
    win.destroy();
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert.equal(BrowserWindow.getAllWindows().length, 0);
  console.log('#832 real-window probe passed: three hidden windows, Tab input, screenshots, reopen events, blocked activation/fullscreen, cleanup.');
  finish(0);
}).catch(error => { console.error(error); finish(1); });
function finish(code) {
  clearTimeout(timeout);
  if (win && !win.isDestroyed()) win.destroy();
  fs.rmSync(temporary, { recursive: true, force: true });
  app.exit(code);
}
