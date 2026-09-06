const fs = require('node:fs');
const assert = require('node:assert/strict');
const path = require('node:path');
const { app, BrowserWindow, ipcMain } = require('electron');
const { Profiler } = require('./profiler.cjs');
const { intervalSampler } = require('./process-metrics.cjs');
const { rendererSample } = require('./renderer-profile.cjs');
const { chromiumSample } = require('./hardware-profile.cjs');
const { installGalleryFixture } = require('./gallery-fixture.cjs');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function runPerformance({ win: fixtureWindow, origin, output }) {
  const win = new BrowserWindow({ width: 1440, height: 920, show: true, titleBarStyle: 'hiddenInset',
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), sandbox: true, contextIsolation: true, nodeIntegration: false, backgroundThrottling: false } });
  fixtureWindow.destroy();
  await win.loadURL('about:blank');
  ipcMain.handle('browser', () => null);
  // The gallery uses the real desktop preload but no engine or browser backends.

  const wc = win.webContents, js = code => wc.executeJavaScript(code);
  wc.on('console-message', event => { if (/Error|error|Illegal/.test(event.message || '')) console.error('Fixture renderer:', event.message); });
  const wait = async expression => { for (let n = 0; n < 300; n++) { if (await js(expression)) return; await sleep(50); } throw Error(`Scenario timeout: ${expression}; ${await js("JSON.stringify({state:document.querySelector('[data-turn-activity]')?.textContent,text:document.querySelector('article')?.textContent,visibility:document.visibilityState})")}`); };
  wc.debugger.attach('1.3');
  await wc.debugger.sendCommand('Page.enable');
  await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument', { source: `(${installGalleryFixture.toString()})()` });
  win.setSize(1440, 920); win.show(); win.focus();
  const sampleTree = intervalSampler(process.pid, () => 0);
  const profiler = new Profiler(async () => ({ ...await sampleTree(), ...await rendererSample(wc), ...chromiumSample(app.getAppMetrics()) }), enabled => { wc.send('profile-enabled', enabled); }, () => app.getGPUFeatureStatus());
  const longTask = (event, duration) => { if (event.sender === wc && Number.isFinite(duration)) profiler.record('renderer-long-task', duration); };
  ipcMain.on('profile-longtask', longTask);
  try {
    console.log('Performance: loading desktop fixture');
    await wc.loadURL(origin);
    console.log('Performance: desktop loaded');
    await wait(`document.querySelector('[aria-label="Appearance"]') && document.querySelector('textarea[aria-label="Prompt"]')`);
    console.log('Performance: recording');
    await profiler.start(); await sleep(2200); await profiler.capture(0);
    const send = async text => {
      await js(`(()=>{const input=document.querySelector('textarea[aria-label="Prompt"]');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(input,${JSON.stringify(text)});input.dispatchEvent(new Event('input',{bubbles:true}));})()`);
      await wait(`!document.querySelector('[aria-label="Send"]').disabled`);
      await js(`document.querySelector('[aria-label="Send"]').click()`);
      await wait(`!!document.querySelector('article[aria-busy="true"]')`);
      await wait(`!document.querySelector('article[aria-busy="true"]')`);
    };
    console.log('Performance: first reply');
    await send('Make this workspace feel calm and easy to use.');
    await js('document.fonts.ready.then(()=>true)');
    const click = async selector => {
      const point = await js(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()`);
      wc.sendInputEvent({ type: 'mouseDown', ...point, button: 'left', clickCount: 1 });
      wc.sendInputEvent({ type: 'mouseUp', ...point, button: 'left', clickCount: 1 });
    };
    const capture = async name => {
      console.log('Performance: capture', name);
      await js(`document.activeElement?.blur(); document.querySelector('button[title^="graff session "] span').textContent='Demo workspace'`);
      await js(`Promise.all(document.getAnimations().filter(a=>a.effect?.getTiming().iterations!==Infinity).map(a=>a.finished.catch(()=>{}))).then(()=>true)`);
      await sleep(200);
      fs.writeFileSync(path.join(output, name), (await wc.capturePage()).toPNG());
    };
    const chooseTheme = async label => {
      await click('[aria-label="Appearance"]');
      await wait(`!!document.querySelector('[aria-label="Close appearance"]')`);
      await js(`[...document.querySelectorAll('[role="dialog"] button')].find(b=>b.textContent.startsWith(${JSON.stringify(label)})).click(); document.querySelector('[aria-label="Close appearance"]').click()`);
    };
    for (const [label, name] of [['White', 'desktop-chat-light.png'], ['Black', 'desktop-chat-dark.png'], ['CodeGraff', 'desktop-chat-codegraff.png']]) {
      await chooseTheme(label);
      await capture(name);
    }
    await js(`document.querySelector('[aria-label="Review workspace changes"]').click()`);
    await wait(`document.querySelector('[aria-label="File diff"]')?.getAttribute('aria-busy')==='false'`);
    await capture('desktop-review-codegraff.png');
    await js(`document.querySelector('[aria-label="Close changes"]').click(); document.querySelector('[aria-label="Show agents"]').click()`);
    await wait(`document.querySelector('[aria-label="Agents panel"]')?.textContent.includes('Refine navigation')`);
    assert.ok(await js(`!!document.querySelector('.sidebar-logo [data-codegraff-mark] use')`));
    await capture('desktop-agents-codegraff.png');
    await js(`document.querySelector('[aria-label="Close agents"]').click(); document.querySelector('[aria-label="Review workspace changes"]').click()`);
    await wait(`document.querySelector('[aria-label="File diff"]')?.getAttribute('aria-busy')==='false'`);
    await chooseTheme('Black');
    await capture('desktop-review-dark.png');
    await chooseTheme('CodeGraff');
    await js(`document.querySelector('[aria-label="Close changes"]').click(); window.galleryBenchmark=true`);
    console.log('Performance: stream');
    profiler.mark('candidate');
    await send('Stream the demonstration transcript.');
    await profiler.capture(0); profiler.stop();
    const report = profiler.report();
    report.scenario = 'Synthetic full GUI: baseline startup and controls; candidate streamed transcript. Different workloads, not a before/after optimization claim. No engine or model calls.';
    fs.writeFileSync(path.join(output, 'performance.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify({ baseline: report.baseline, streaming: report.candidate, acceleration: report.acceleration }));
  } finally { profiler.stop(); await rendererSample(wc, false); wc.debugger.detach(); ipcMain.removeHandler('browser'); ipcMain.removeListener('profile-longtask', longTask); win.destroy(); }
}
module.exports = { runPerformance };
