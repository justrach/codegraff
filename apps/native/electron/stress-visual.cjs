const { BrowserWindow } = require('electron');
const { installWindowState } = require('./window-state.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function runStressVisuals({win: fixtureWindow, origin, output, fullscreen = true}) {
  const win = new BrowserWindow({width:1000,height:760,show:true,titleBarStyle:'hiddenInset',webPreferences:{preload:path.join(__dirname,'preload.cjs'),sandbox:true,contextIsolation:true,nodeIntegration:false,backgroundThrottling:false}});
  installWindowState(win);
  const js = code => win.webContents.executeJavaScript(code);
  const wait = async expression => {for(let i=0;i<200;i++){if(await js(expression))return;await sleep(50);}throw Error(`Stress timeout: ${expression}`);};
  const click = async selector => {await js(`document.querySelector(${JSON.stringify(selector)}).click()`);await sleep(60);};
  const select = async name => {await click(`[data-stress-case="${name}"]`); await js('document.fonts.ready.then(()=>true)');};
  const metrics=[];
  const bounds=async()=>{
    const r=await js(`(()=>{const el=document.querySelector('[aria-label="Stress composer"]'),r=el.getBoundingClientRect();return {overflow:document.documentElement.scrollWidth>innerWidth,bottom:r.bottom,top:r.top,height:innerHeight}})()`);
    assert.equal(r.overflow,false);assert.ok(r.top>=0&&r.bottom<=r.height,JSON.stringify(r));
  };
  try {
    fixtureWindow.hide();win.show();win.focus();await win.loadURL(`${origin}/visual-tests/stress`);
    await wait(`!!document.querySelector('[data-tool-summary]')`);
    for(const theme of ['light','dark','codegraff']) {
      await click(`[data-stress-theme="${theme}"]`);await select('tools');
      assert.equal(await js(`document.querySelectorAll('[data-tool-row]').length`),0,'collapsed calls must not mount hidden rows');
      assert.match(await js(`document.querySelector('[data-tool-summary]').textContent`),/1 failed/);
      const start=Date.now();await click('[data-tool-summary]');
      assert.equal(await js(`document.querySelectorAll('[data-tool-row]').length`),50);
      assert.equal(await js(`document.querySelectorAll('[data-tool-output]').length`),0);
      await click('[data-tool-row]');await bounds();
      assert.ok(await js(`(()=>{const e=document.querySelector('[data-tool-output]');return e.scrollHeight>e.clientHeight&&e.clientHeight<=256})()`));
      await click('[aria-label="Next tools"]');
      assert.match(await js(`document.querySelector('[data-tool-row]').textContent`),/file-50/);
      assert.equal(await js(`document.querySelectorAll('[data-tool-output]').length`),0);
      metrics.push({theme,toolCount:5000,renderedRows:50,disclosureMs:Date.now()-start});
      await select('output');await click('[data-tool-summary]');await click('[data-tool-row]');
      const text=await js(`document.querySelector('[data-tool-output]').textContent`);
      assert.match(text,/FIRST LINE/);assert.match(text,/FINAL ERROR/);assert.match(text,/omitted/);await bounds();
      fs.writeFileSync(path.join(output,`stress-output-${theme}.png`),(await win.webContents.capturePage()).toPNG());
    }
    await select('history');
    assert.equal(await js(`document.querySelectorAll('article').length`),40,'initial history should mount only 80 messages');
    await click('[data-chat-transcript] button');
    assert.equal(await js(`document.querySelectorAll('article').length`),80);await bounds();
    await select('user');await bounds();
    await select('text');await bounds();await click('[data-stream]');
    await js(`document.querySelector('[data-stress-scroll]').scrollTop=200`);await sleep(100);
    const before=await js(`document.querySelector('[data-stress-scroll]').scrollTop`);await sleep(600);
    assert.ok(Math.abs(await js(`document.querySelector('[data-stress-scroll]').scrollTop`)-before)<4,'streaming must preserve a reader browsing earlier text');
    await click('[data-stream]');
    const titleHeight=()=>js(`document.querySelector('[data-desktop-titlebar]').getBoundingClientRect().height`);
    assert.equal(await titleHeight(),36);
    const checkedFullscreen = fullscreen && process.platform === 'darwin';
    if(checkedFullscreen) {
      win.setFullScreen(true);await wait(`document.documentElement.dataset.desktopFullscreen==='true'`);
      assert.equal(await titleHeight(),0);await bounds();
      fs.writeFileSync(path.join(output,'stress-fullscreen.png'),(await win.webContents.capturePage()).toPNG());
      await win.reload();await wait(`document.documentElement.dataset.desktopFullscreen==='true'`);assert.equal(await titleHeight(),0);
      win.setFullScreen(false);await wait(`document.documentElement.dataset.desktopFullscreen==='false'`);assert.equal(await titleHeight(),36);
    }
    fs.writeFileSync(path.join(output,'stress-results.json'),JSON.stringify({passed:['5000 tools','bounded output','1000 messages','unbroken input','long markdown','stream reading position',...(checkedFullscreen?['fullscreen and reload']:[])],fullscreen:checkedFullscreen?'passed':'not run',metrics},null,2));
    console.log('Stress visual checks passed: long tools/output/history/text, reading position. Fullscreen:', checkedFullscreen?'passed':'not run in this suite');
  } finally {win.destroy();fixtureWindow.show();fixtureWindow.focus();}
}
module.exports={runStressVisuals};
