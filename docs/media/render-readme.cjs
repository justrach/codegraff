// Deterministic presentation layouts. Source UI captures and artwork remain unchanged.
const { app, BrowserWindow } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const assert = require('node:assert/strict');
const plates = require('./readme-plates.cjs');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-readme-'));
app.setPath('userData', path.join(temporary, 'profile'));
app.commandLine.appendSwitch('force-device-scale-factor', '1');
let win;
const output = path.resolve(__dirname, '../images');
app.whenReady().then(async () => {
  win = new BrowserWindow({ show:false, width:1920, height:1530, useContentSize:true, webPreferences:{ sandbox:true, contextIsolation:true, nodeIntegration:false, backgroundThrottling:false } });
  win.webContents.session.webRequest.onBeforeRequest((details, callback) => callback({cancel: /^https?:/.test(details.url)}));
  for (const plate of plates) {
    win.setContentSize(plate.width, plate.height);
    const html = path.join(temporary, `${plate.name}.html`);
    fs.writeFileSync(html, plate.html());
    await win.loadFile(html);
    const state = await win.webContents.executeJavaScript(`(async()=>{await document.fonts.ready;await Promise.all([...document.images].map(i=>i.decode()));await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return {width:innerWidth,height:innerHeight,overflow:document.documentElement.scrollWidth>innerWidth,images:[...document.images].every(i=>i.naturalWidth>0)}})()`);
    assert.deepEqual(state, {width:plate.width,height:plate.height,overflow:false,images:true});
    const capture = await win.webContents.capturePage();
    // Normalize Retina captures so export size is independent of the display.
    const frame = capture.resize({width:plate.width,height:plate.height,quality:'best'});
    const file = path.join(output, `${plate.name}.jpg`);
    fs.writeFileSync(file, frame.toJPEG(94));
    console.log(`${plate.name}: ${frame.getSize().width}×${frame.getSize().height}, ${Math.round(fs.statSync(file).size/1024)} KiB`);
  }
}).then(()=>finish(0)).catch(error=>{console.error(error);finish(1)});
function finish(code) { if(win&&!win.isDestroyed())win.destroy(); fs.rmSync(temporary,{recursive:true,force:true}); app.exit(code); }
