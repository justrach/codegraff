#!/usr/bin/env node
// Offline browser regression for the bundled app in an opaque sandbox.
const {chromium} = require('../apps/native/node_modules/@playwright/test');
const {readFileSync} = require('node:fs');
const assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({channel:'chrome',headless:true});
  try {
    const page = await browser.newPage({viewport:{width:820,height:800}});
    const errors=[];page.on('pageerror',error=>errors.push(error.message));
    await page.setContent('<iframe title="Task app" sandbox="allow-scripts" style="border:0;width:100%;height:760px"></iframe>');
    await page.evaluate(html=>{
      window.received=[];
      const frame=document.querySelector('iframe');
      window.deliver=params=>frame.contentWindow.postMessage({jsonrpc:'2.0',...params},'*');
      window.addEventListener('message',event=>{
        if(event.source!==frame.contentWindow)return;
        window.received.push(event.data);
        if(event.data.method==='ui/initialize')window.deliver({id:event.data.id,result:{protocolVersion:'2026-01-26',hostCapabilities:{},hostContext:{theme:'light'}}});
      });
      frame.srcdoc=html;
    },readFileSync(require('node:path').join(__dirname,'../src/mcp_task_app.html'),'utf8').replace('/* CODEGRAFF_THEME */',readFileSync(require('node:path').join(__dirname,'../apps/native/app/ui-theme.css'),'utf8')));
    await page.waitForFunction(()=>window.received.some(m=>m.method==='ui/notifications/initialized'));
    const app=page.frames()[1];
    await page.evaluate(()=>{
      window.deliver({method:'ui/notifications/tool-input',params:{arguments:{prompt:'Explain the configuration parser. Cite relevant files.',timeout_seconds:90,max_model_calls:6}}});
      window.deliver({method:'ui/notifications/tool-result',params:{content:[{type:'text',text:'fallback'}],structuredContent:{text:'Configuration parser review\n\nconfig.zig:42 — Missing keys retain defaults.\nconfig.zig:78 — Invalid values return a typed error.\n\nNo files changed.\n<img src=x onerror=alert(1)>',status:'completed',timeout_seconds:90,max_model_calls:6,output_truncated:false},isError:false}});
    });
    await app.locator('#status').filter({hasText:'Completed'}).waitFor();
    assert.equal(await app.locator('#output img').count(),0);
    assert.match(await app.locator('#output').innerText(),/<img src=x/);
    await app.locator('#search').fill('config.zig');
    assert.equal(await app.locator('#count').innerText(),'2 of 7 lines');
    assert.doesNotMatch(await app.locator('#output').innerText(),/<img/);
    await app.locator('#search').fill('');await app.locator('#wrap').uncheck();
    assert.match(await app.locator('#output').getAttribute('class'),/nowrap/);
    await app.locator('#wrap').check();await app.locator('summary').click();
    await page.screenshot({path:'/tmp/codegraff-mcp-task-app.png'});
    await page.evaluate(()=>window.deliver({method:'ui/notifications/tool-result',params:{content:[{type:'text',text:'Partial answer'}],isError:true,structuredContent:{text:'Partial answer',status:'timed_out',output_truncated:true}}}));
    await app.locator('#status').filter({hasText:'Timed out'}).waitFor();
    assert.equal(await app.locator('#clipped').isVisible(),true);
    await page.evaluate(()=>window.deliver({method:'ui/notifications/host-context-changed',params:{theme:'dark'}}));
    await app.waitForFunction(()=>document.documentElement.dataset.theme==='dark');
    await page.setViewportSize({width:380,height:760});
    assert.equal(await app.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),true);
    await page.evaluate(()=>window.deliver({method:'ui/notifications/tool-cancelled',params:{}}));
    await app.locator('#status').filter({hasText:'Cancelled'}).waitFor();
    await page.evaluate(()=>window.deliver({method:'ui/notifications/tool-result',params:{content:[{type:'text',text:'Plain result fallback'}],isError:false}}));
    await app.locator('#output').filter({hasText:'Plain result fallback'}).waitFor();
    await app.evaluate(()=>window.postMessage({jsonrpc:'2.0',method:'ui/notifications/tool-result',params:{content:[{type:'text',text:'Unexpected sender'}]}},'*'));
    assert.equal(await app.locator('#output').innerText(),'Plain result fallback');
    await page.evaluate(()=>window.deliver({method:'ui/resource-teardown',id:99,params:{}}));
    await page.waitForFunction(()=>window.received.some(m=>m.id===99&&m.result));
    assert.deepEqual(errors,[]);
    assert.equal(await page.evaluate(()=>window.received.some(m=>m.method==='tools/call')),false);
    console.log('MCP task app: sandbox handshake, result, text rendering, filtering, wrapping, themes, mobile layout, cancellation and teardown passed');
  } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
