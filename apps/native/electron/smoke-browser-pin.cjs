const assert = require('node:assert/strict');
const { ipcMain } = require('electron');
async function smokeBrowserPin({ browser, win }) {
  if (!require('./test-window.cjs').visibleWindowCheck('embedded browser native pin input')) return 'Skipped: requires visible-window opt-in';
  const testDesktop = require('./test-desktop.cjs');
  const wc = browser.tabs.get('smoke').view.webContents;
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const pinReceived = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { ipcMain.removeListener('browser-pin', listener); reject(new Error('Picker did not send a pin')); }, 3000);
    const listener = (_event, pin) => { clearTimeout(timeout); ipcMain.removeListener('browser-pin', listener); resolve(pin); };
    ipcMain.on('browser-pin', listener);
  });
  await browser.command('smoke', 'pick', { enabled: true });
  const point = await wc.executeJavaScript('(()=>{const r=document.querySelector("#button").getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()');
  require('./test-window.cjs').presentWindow(win); await sleep(300);
  await testDesktop.testInput(wc, {type:'mouseMove', ...point});
  await testDesktop.testInput(wc, { type: 'mouseDown', ...point, button: 'left', clickCount: 1 });
  await testDesktop.testInput(wc, { type: 'mouseUp', ...point, button: 'left', clickCount: 1 });
  assert.equal((await pinReceived).element.selector, '#button');
  return 'native pin input passed';
}
module.exports = { smokeBrowserPin };
