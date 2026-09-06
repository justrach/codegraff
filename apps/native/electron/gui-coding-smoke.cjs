// Opt-in: a real GUI coding turn in a disposable workspace. Uses configured credentials.
const {app,BrowserWindow,ipcMain}=require('electron');
const {spawn,spawnSync}=require('node:child_process');
const fs=require('node:fs');const path=require('node:path');const os=require('node:os');const net=require('node:net');const assert=require('node:assert/strict');
const {installWindowState}=require('./window-state.cjs');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'graff-gui-coding-'));
app.setPath('userData',path.join(temp,'profile'));
const root=path.join(temp,'workspace');fs.mkdirSync(root);
fs.writeFileSync(path.join(temp,'mcp.json'),'{"mcpServers":{}}');
fs.writeFileSync(path.join(root,'median.ts'),'export function median(values: number[]) { const sorted = values.sort(); return sorted[Math.floor(sorted.length / 2)]; }\n');
fs.writeFileSync(path.join(root,'median.test.ts'),`import {test,expect} from 'bun:test';import {median} from './median';
test('numeric ordering',()=>expect(median([10,2,3])).toBe(3));
test('even arrays',()=>expect(median([4,1,2,3])).toBe(2.5));
test('does not mutate',()=>{const input=[3,1,2];median(input);expect(input).toEqual([3,1,2]);});
test('empty arrays',()=>expect(()=>median([])).toThrow());\n`);
spawnSync('git',['init','-q'],{cwd:root});
let server,win;const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const deadline=setTimeout(()=>finish(1,new Error('Coding GUI audit timed out')),420000);
async function finish(code,error){clearTimeout(deadline);if(error)console.error(error.message);if(win&&!win.isDestroyed())win.destroy();if(server?.pid)try{process.kill(-server.pid,'SIGTERM');}catch{}console.log(`Audit artifacts: ${temp}`);app.exit(code);}
app.whenReady().then(async()=>{
 const ui=path.resolve(__dirname,'..');const probe=net.createServer();await new Promise(r=>probe.listen(0,'127.0.0.1',r));const port=probe.address().port;await new Promise(r=>probe.close(r));const origin=`http://127.0.0.1:${port}`;
 const log=fs.openSync(path.join(temp,'server.log'),'w');
 server=spawn(process.env.GRAFF_TEST_BUN||'bun',['node_modules/next/dist/bin/next','start','--port',String(port),'--hostname','127.0.0.1'],{cwd:ui,detached:true,stdio:['ignore',log,log],env:{...process.env,GRAFF_CWD:root,GRAFF_BIN:path.resolve(ui,'../../zig-out/bin/graff'),GRAFF_DESKTOP_TOKEN:'',GRAFF_MCP_CONFIG:path.join(temp,'mcp.json'),GRAFF_THEMES_DIR:path.join(temp,'themes'),NEXT_TELEMETRY_DISABLED:'1'}});fs.closeSync(log);
 for(let n=0;n<100;n++){try{if((await fetch(origin)).ok)break;}catch{}await sleep(100);}
 win=new BrowserWindow({width:1440,height:920,show:true,titleBarStyle:'hiddenInset',webPreferences:{preload:path.join(__dirname,'preload.cjs'),sandbox:true,contextIsolation:true,nodeIntegration:false,backgroundThrottling:false}});installWindowState(win);ipcMain.handle('browser',()=>null);
 const js=c=>win.webContents.executeJavaScript(c);const wait=async(c,ms=30000)=>{const end=Date.now()+ms;while(Date.now()<end){if(await js(c))return;await sleep(100);}throw Error(`GUI condition timed out: ${c}`);};
 await win.loadURL(origin);win.focus();await wait(`!!document.querySelector('textarea[aria-label="Prompt"]')`);
 const input=async text=>js(`(()=>{const e=document.querySelector('textarea[aria-label="Prompt"]');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,${JSON.stringify(text)});e.dispatchEvent(new Event('input',{bubbles:true}));})()`);
 const send=async text=>{await input(text);await wait(`!document.querySelector('[aria-label="Send"]').disabled`);await js(`document.querySelector('[aria-label="Send"]').click()`);await wait(`!!document.querySelector('article[aria-busy="true"]')`);await wait(`!document.querySelector('article[aria-busy="true"]')`,240000);};
 await send('Fix median.ts so every existing test passes. Preserve the tests. Use Bun to run them and report the result. Work only in this disposable workspace; do not use MCP or spawn subagents.');
 const checked=spawnSync(process.env.GRAFF_TEST_BUN||'bun',['test'],{cwd:root,encoding:'utf8'});fs.writeFileSync(path.join(temp,'verification.log'),checked.stdout+checked.stderr);
 fs.writeFileSync(path.join(temp,'coding.png'),(await win.webContents.capturePage()).toPNG());
 assert.equal(checked.status,0,'The GUI coding turn must produce a passing implementation');
 assert.equal(await js(`document.querySelectorAll('article [role="alert"]').length`),0);
 assert.equal(await js(`Array.from(document.querySelectorAll('[data-tool-summary]')).some(e=>/\\b(?:running|interrupted)\\b/.test(e.textContent))`),false,'Finished tools must not remain running or interrupted');
 console.log('Real GUI coding turn passed all four independent tests with completed tool rows.');
 await input('/compact');await wait(`!!document.querySelector('[role="listbox"]') || !!document.querySelector('[role="menu"]')`);
 assert.equal(await js(`document.body.textContent.includes('No matches for "compact"')`),false);
 await js(`document.querySelector('textarea[aria-label="Prompt"]').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))`);
 await send('/compact');
 fs.writeFileSync(path.join(temp,'compact.png'),(await win.webContents.capturePage()).toPNG());
 const result=await js(`JSON.stringify({errors:[...document.querySelectorAll('article [role="alert"]')].map(e=>e.textContent),last:document.querySelector('article:last-of-type')?.textContent})`);
 fs.writeFileSync(path.join(temp,'compact-result.json'),result);assert.equal(JSON.parse(result).errors.length,0);
 console.log('Compact command completed through the GUI.');
 await finish(0);
}).catch(error=>finish(1,error));
