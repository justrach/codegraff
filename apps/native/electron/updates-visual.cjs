const testDesktop = require('./test-desktop.cjs');
const { BrowserWindow } = require('electron');
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path');
async function runUpdateVisuals({ origin, output }) {
  const win = testDesktop.createWindow({ width: 900, height: 650, webPreferences: { sandbox: true, contextIsolation: true, backgroundThrottling: false } });
  const wc = win.webContents, js = source => wc.executeJavaScript(source);
  const wait = async source => { for (let i = 0; i < 100; i++) { if (await js(source)) return; await new Promise(r => setTimeout(r, 30)); } throw Error(source); };
  try {
    await wc.loadURL('about:blank');
    testDesktop.attachTestDebugger(wc);
    await wc.debugger.sendCommand('Page.enable');
    await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument', { source: `
      window.__restarts=0;window.__automatic=true;let listener;
      const base=()=>({currentVersion:'1.0.0',automatic:window.__automatic,interactive:false});
      window.__update=state=>listener?.({...base(),...state});
      window.graffDesktop={updateSubscribe:fn=>{listener=fn;return()=>{}},updates:async(action,value)=>{
        if(action==='restart'){window.__restarts++;const s={...base(),status:'installing'};listener?.(s);return s;}
        if(action==='check'){const s={...base(),status:'checking',interactive:true};listener?.(s);return s;}
        if(action==='automatic'){window.__automatic=!!value;const s={...base(),status:'idle'};listener?.(s);return s;}
        return {...base(),status:'idle'};
      }};` });
    await win.loadURL(`${origin}/visual-tests`);
    testDesktop.present(win);
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
    await testDesktop.testInput(wc, { type: 'mouseDown', x: Math.round(target.x), y: Math.round(target.y), button: 'left', clickCount: 1 });
    await testDesktop.testInput(wc, { type: 'mouseUp', x: Math.round(target.x), y: Math.round(target.y), button: 'left', clickCount: 1 });
    await wait(`window.__restarts===1`);
    await wait(`document.querySelector('[data-desktop-update]')?.textContent.includes('Preparing to restart')`);
    await js(`document.querySelector('[data-desktop-update-settings]').click()`);
    await wait(`!!document.querySelector('[data-desktop-update-panel]')`);
    assert.equal(await js(`document.querySelector('[data-desktop-update-panel]')?.textContent.includes('every six hours')`), true, 'settings explain the six-hour poll');
    await js(`document.querySelector('[data-desktop-update-check]').click()`);
    await wait(`document.querySelector('[data-desktop-update-panel]')?.textContent.includes('Checking for updates')`);
    await js(`document.querySelector('[data-desktop-update-automatic]').click()`);
    await wait(`document.querySelector('[data-desktop-update-automatic]')?.getAttribute('aria-checked')==='false'`);
    assert.equal(await js('window.__automatic'), false, 'settings toggle persists automatic downloads');
    fs.writeFileSync(path.join(output, 'update-settings.png'), (await wc.capturePage(undefined, { stayAwake: true })).toPNG());
    console.log('Update UI passed: quiet checks/errors, download progress, explicit restart, in-app settings.');
  } finally { win.destroy(); }
}
module.exports = { runUpdateVisuals };
