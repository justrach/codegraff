const desktop=require('./test-desktop.cjs');
const {app}=require('electron');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'graff-browser-resource-'));
app.setPath('userData',path.join(temp,'profile'));
const output=path.resolve(process.argv[2]||path.join(__dirname,'../../../zig-out/browser-resources'));fs.mkdirSync(output,{recursive:true});
const {BrowserTabs}=require(process.env.GRAFF_BROWSER_SOURCE||'./browser-tabs.cjs');
const {treeSample}=require('./process-metrics.cjs');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let browser,win,server;
const deadline=setTimeout(()=>finish(Error('Browser resource probe exceeded 30 seconds')),30000);
async function finish(error){clearTimeout(deadline);try{browser?.closeAll();desktop.assertSafe();}catch(e){error||=e;}server?.close();desktop.cleanup();fs.rmSync(temp,{recursive:true,force:true});if(error)console.error(error);app.exit(error?1:0);}
app.whenReady().then(async()=>{
  win=desktop.createWindow({width:1000,height:720,webPreferences:{sandbox:true}});
  await win.webContents.loadURL('data:text/html,<p>Browser resource fixture</p>');
  browser=new BrowserTabs(win,()=>{});
  // Accelerate only the grace period; production keeps its normal one-minute policy.
  browser.suspendMs=1000;
  server=require('node:http').createServer((_req,res)=>res.end('<body><script>window.payload=new Uint8Array(16*1024*1024);payload.fill(1);for(let i=0;i<2000;i++){const p=document.createElement("p");p.textContent="Browser fixture row "+i;document.body.append(p)}</script></body>'));
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  const url=`http://127.0.0.1:${server.address().port}`,samples=[];
  const sample=async(label)=>{const p=await treeSample(process.pid);samples.push({label,liveViews:browser.liveCount,rssMiB:p.rssMiB,processes:p.processes});};
  await sample('idle');
  for(let i=0;i<12;i++){
    browser.setBounds(String(i),{x:0,y:0,width:800,height:600});
    await browser.navigate(String(i),url);
    assert.ok(browser.liveCount<=3,'View churn must respect the live-renderer cap');
    if(i===2||i===11)await sample(`after-${i+1}-pages`);
  }
  browser.hide(browser.visible);await sleep(1600);
  assert.equal(browser.liveCount,0,'All hidden views should suspend');
  await sample('suspended');browser.closeAll();assert.equal(browser.tabs.size,0);
  await sleep(300);await sample('closed');
  const result={pagesOpened:12,payloadMiBPerPage:16,acceleratedGraceMs:1000,samples,desktop:desktop.assertSafe()};
  fs.writeFileSync(path.join(output,'browser-resources.json'),JSON.stringify(result,null,2));console.log('PASS Browser resource churn',JSON.stringify(result));
}).then(()=>finish()).catch(finish);
