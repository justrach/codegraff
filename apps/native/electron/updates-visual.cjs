const { BrowserWindow } = require('electron');
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path');
async function runUpdateVisuals({ origin, output }) {
  const win = new BrowserWindow({ width: 900, height: 650, show: true, webPreferences: { sandbox: true, contextIsolation: true, backgroundThrottling: false } });
  const wc = win.webContents, js = source => wc.executeJavaScript(source);
  const wait = async source => { for (let i = 0; i < 100; i++) { if (await js(source)) return; await new Promise(r => setTimeout(r, 30)); } throw Error(source); };
  try {
    await wc.loadURL('about:blank');
    wc.debugger.attach('1.3');
    await wc.debugger.sendCommand('Page.enable');
    await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument', { source: `
      window.__restarts=0;let listener;window.__update=state=>listener?.({currentVersion:'1.0.0',automatic:true,interactive:false,...state});
      window.graffDesktop={updateSubscribe:fn=>{listener=fn;return()=>{}},updates:async action=>{if(action==='restart'){window.__restarts++;return {status:'installing'}}return {status:'idle'}}};` });
    await win.loadURL(`${origin}/visual-tests`);
    win.focus();
    console.log('Update visual fixture loaded.');
    await wait(`!!document.querySelector('[data-case="waiting"]')`);
    for (const status of ['checking', 'error', 'current']) {
      await js(`window.__update({status:'${status}',message:'Check your connection.'})`);
      await new Promise(r => setTimeout(r, 50));
      assert.equal(await js(`!!document.querySelector('[data-desktop-update]')`), false, 'background checks never interrupt the conversation');
    }
    await js(`window.__update({status:'downloading',version:'1.0.1',percent:42})`);
    await wait(`document.querySelector('progress')?.value===42`);
    await js(`document.querySelector('[aria-label="Dismiss update notification"]').click()`);
    await js(`window.__update({status:'downloading',version:'1.0.1',percent:43})`);
    await new Promise(r => setTimeout(r, 50));
    assert.equal(await js(`!!document.querySelector('[data-desktop-update]')`), false, 'progress does not reopen a dismissed notification');
    await js(`window.__update({status:'ready',version:'1.0.1'})`);
    await wait(`document.querySelector('[data-desktop-update]')?.textContent.includes('Restart to update')`);
    assert.equal(await js('window.__restarts'), 0);
    await js('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
    await new Promise(resolve => setTimeout(resolve, 100));
    const target = await js(`(()=>{
      const b=Array.from(document.querySelectorAll('[data-desktop-update] button')).find(b=>b.textContent==='Restart to update'),r=b.getBoundingClientRect();
      const x=r.x+r.width/2,y=r.y+r.height/2;return {x,y,visible:x>0&&y>0&&x<innerWidth&&y<innerHeight&&b.contains(document.elementFromPoint(x,y))};
    })()`);
    assert.equal(target.visible, true, 'restart action is visible and receives pointer input');
    fs.writeFileSync(path.join(output, 'update-ready.png'), (await wc.capturePage(undefined, { stayAwake: true })).toPNG());
    wc.sendInputEvent({ type: 'mouseDown', x: Math.round(target.x), y: Math.round(target.y), button: 'left', clickCount: 1 });
    wc.sendInputEvent({ type: 'mouseUp', x: Math.round(target.x), y: Math.round(target.y), button: 'left', clickCount: 1 });
    await wait(`window.__restarts===1`);
    await wait(`document.querySelector('[data-desktop-update]')?.textContent.includes('Preparing to restart')`);
    console.log('Update UI passed: quiet checks/errors, download progress, explicit restart only.');
  } finally { win.destroy(); }
}
module.exports = { runUpdateVisuals };
