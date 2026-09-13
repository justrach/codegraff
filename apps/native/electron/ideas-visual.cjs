const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { testInput } = require('./test-desktop.cjs');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function runIdeasVisuals({ win, origin, output }) {
  const js = source => win.webContents.executeJavaScript(source);
  const wait = async fn => { for(let i=0;i<100;i++){if(await fn())return;await sleep(50);}throw Error('Ideas preview did not reach the expected state'); };
  let attachedTarget, sessionId;
  const childJs = async expression => {
    try {
    if(!win.webContents.debugger.isAttached())win.webContents.debugger.attach('1.3');
    const {targetInfos}=await win.webContents.debugger.sendCommand('Target.getTargets');
    const target=targetInfos.find(item=>item.type==='iframe' && item.url==='about:srcdoc');
    if(!target)return undefined;
    if(attachedTarget!==target.targetId){
      ({sessionId}=await win.webContents.debugger.sendCommand('Target.attachToTarget',{targetId:target.targetId,flatten:true}));
      attachedTarget=target.targetId;
    }
    const result=await win.webContents.debugger.sendCommand('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true},sessionId);
    if(result.exceptionDetails)throw Error(result.exceptionDetails.text);
    return result.result.value;
    } catch (error) {
      // Replacing srcdoc retires its OOPIF target. The bounded wait reconnects.
      if (/navigated or closed|Cannot find context|No target with given id|Session with given id not found/.test(error.message)) {
        attachedTarget=undefined; sessionId=undefined; return undefined;
      }
      throw error;
    }
  };
  const click = async (selector, frame) => {
    const target = frame ? childJs : js;
    await target(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block:'center',behavior:'instant'})`);
    await sleep(50);
    const point = await target(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
    if(frame){const offset=await js(`(()=>{const r=document.querySelector('iframe').getBoundingClientRect();return{x:r.x,y:r.y}})()`);point.x+=offset.x;point.y+=offset.y;}
    for(const type of ['mouseDown','mouseUp'])await testInput(win.webContents,{type,...point,button:'left',clickCount:1});
  };
  const frame = () => win.webContents.mainFrame.frames.find(child=>child.url==='about:srcdoc');
  const screenshot = async name => { await sleep(180); fs.writeFileSync(path.join(output,name),(await win.webContents.capturePage()).toPNG()); };
  win.setSize(1120, 980);
  await win.loadURL(`${origin}/visual-tests/ideas`);
  await wait(()=>js(`document.querySelector('[data-ideas-ready]')?.dataset.ideasReady==='true'`));
  await wait(async()=>!!frame());
  await wait(async()=>(await childJs(`document.querySelector('h1')?.textContent`))==='Where the memory goes.');
  await screenshot('inline-html-preview.png');
  await click('summary',frame());
  assert.equal(await childJs(`document.querySelector('details').open`),true,'native HTML interaction stays inside the reply');
  await screenshot('inline-html-expanded.png');
  await click('[data-html-source]');
  await wait(()=>js(`!!document.querySelector('[data-html-source-body]') && !document.querySelector('iframe')`));
  const original = await js(`document.querySelector('[data-html-source-body]').textContent`);
  await js(`Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async text=>{window.fixtureCopiedHtml=text}}})`);
  await click('[data-html-copy]');
  assert.equal(await js('window.fixtureCopiedHtml'), original, 'copy includes the entire original HTML');
  await click('[data-html-preview]');
  await wait(async()=>!!frame());
  await click('[data-html-hide]');
  assert.equal(await js(`document.querySelectorAll('iframe').length`),0,'hidden preview releases its iframe');
  await click('[data-html-hide]');
  await wait(async()=>!!frame());
  const malicious = `<h1>Isolation check</h1><script>window.previewEscaped=true;parent.previewEscaped=true</script><p onclick="window.previewEscaped=true">Test</p><meta http-equiv="refresh" content="0;url=https://example.invalid"><base href="https://example.invalid"><img src="https://example.invalid/image"><iframe src="https://example.invalid"></iframe><form action="https://example.invalid"><input></form><style>body{background-image:url(https://example.invalid/image)}</style>`;
  await js(`window.dispatchEvent(new CustomEvent('fixture-html',{detail:${JSON.stringify(malicious)}}))`);
  await wait(async()=>!!frame() && await childJs(`document.querySelector('h1')?.textContent==='Isolation check'`));
  assert.equal(await childJs(`!!document.querySelector('script,iframe,img,base,form,[onclick],meta[http-equiv="refresh"]')`),false);
  assert.equal(await childJs(`window.previewEscaped===undefined && window.electron===undefined`),true);
  assert.equal(await childJs(`(()=>{try{return !!parent.document}catch{return false}})()`),false,'opaque frame cannot read the application document');
  assert.equal(await js(`document.querySelector('iframe').getAttribute('sandbox')`),'');
  await click('[data-ideas-diagnostics]');
  await wait(()=>js(`!!document.querySelector('[data-diagnostics-toggle]')`));
  assert.equal(await js(`document.querySelector('[data-diagnostics-toggle]').getAttribute('aria-checked')`),'false');
  await screenshot('diagnostics-settings.png');
  await click('[data-diagnostics-toggle]');
  assert.equal(await js(`document.querySelector('[data-diagnostics-toggle]').getAttribute('aria-checked')`),'true');
  assert.equal(await js(`document.querySelectorAll('iframe').length`),0,'switching away releases the preview');
  fs.writeFileSync(path.join(output,'ideas-results.json'),JSON.stringify({prototype:true,passed:['inline HTML rendering','trusted native details click','full source copy','source/hide release iframe','restricted elements removed','opaque origin','diagnostics switch defaults off'],telemetryUploaded:false},null,2));
  console.log('Ideas prototype passed: inline preview, trusted input, source fidelity, teardown, isolation and local diagnostics settings.');
}
module.exports={runIdeasVisuals};
