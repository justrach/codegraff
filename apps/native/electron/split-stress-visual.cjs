const desktop = require('./test-desktop.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path');
const {treeSample} = require('./process-metrics.cjs');
async function runSplitStress({win,output,mixed=true}) {
  const wc=win.webContents, js=code=>wc.executeJavaScript(code), sleep=ms=>new Promise(r=>setTimeout(r,ms));
  const wait=async code=>{for(let i=0;i<100;i++){if(await js(code))return;await sleep(30);}throw Error(`Split stress timeout: ${code}`);};
  const point=async selector=>{await settle();return js(`(()=>{const e=document.querySelector(${JSON.stringify(selector)});e.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'});const r=e.getBoundingClientRect();return {x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)}})()`);};
  const input=event=>desktop.testInput(wc,event);
  const click=async selector=>{const p=await point(selector);for(const type of ['mouseDown','mouseUp'])await input({type,button:'left',clickCount:1,...p});};
  const key=async(keyCode,modifiers=[])=>{for(const type of ['keyDown','keyUp'])await input({type,keyCode,modifiers});};
  const ids=()=>js(`Array.from(document.querySelectorAll('[data-chat]')).map(p=>Number(p.dataset.chat))`);
  const settle=async()=>{
    await js(`new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>reject(Error('Split layout did not produce a frame')),3000);
      requestAnimationFrame(()=>requestAnimationFrame(()=>{clearTimeout(timer);resolve(true)}));
    })`);
    await wait(`!Array.from(document.querySelectorAll('[data-chat], [data-tab-id]')).some(p=>p.getAnimations().some(a=>a.playState==='running'))`);
  };
  const geometry=()=>js(`Array.from(document.querySelectorAll('[data-chat]')).map(p=>{const r=p.getBoundingClientRect();return {id:Number(p.dataset.chat),x:r.x,y:r.y,width:r.width,height:r.height,style:p.style.cssText,transform:getComputedStyle(p).transform}})`);
  const valid=async()=>{
    await settle();
    const boxes=await geometry();
    for(let i=0;i<boxes.length;i++) {
      const a=boxes[i];assert.ok(a.width>30&&a.height>30,'Pane must remain usable');
      for(const b of boxes.slice(i+1))assert.ok(a.x+a.width<=b.x+1||b.x+b.width<=a.x+1||a.y+a.height<=b.y+1||b.y+b.height<=a.y+1,'Panes must not overlap: '+JSON.stringify(boxes));
    }
    assert.equal(await js(`document.querySelectorAll('[data-tab-drag-ghost], [data-tab-drop]').length`),0,'No stale drag overlay');
  };
  desktop.attachTestDebugger(wc);
  // Stress the animated layout even when the host requests reduced motion.
  await wc.debugger.sendCommand('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'no-preference' }] });
  await wc.debugger.sendCommand('Performance.enable');
  const samples=[];
  const sample=async label=>{
    await settle();await sleep(150);await wc.debugger.sendCommand('HeapProfiler.collectGarbage');
    const heap=await wc.debugger.sendCommand('Runtime.getHeapUsage'), dom=await wc.debugger.sendCommand('Memory.getDOMCounters'), proc=await treeSample(process.pid);
    const metrics=Object.fromEntries((await wc.debugger.sendCommand('Performance.getMetrics')).metrics.map(m=>[m.name,m.value]));
    const value={label,heapMiB:heap.usedSize/2**20,...dom,rssMiB:proc.rssMiB,scriptSeconds:metrics.ScriptDuration,layoutSeconds:metrics.LayoutDuration};samples.push(value);return value;
  };
  if(await js(`document.querySelector('button[title^="Sidecar browser"]')?.getAttribute('aria-pressed')==='true'`))await click('button[title^="Sidecar browser"]');
  await sleep(400);
  const base=(await ids())[0];
  await sample('before');
  const start=await treeSample(process.pid);
  let pointerMoves=0;
  // Same bounded churn workload on both builds. Actual key and pointer events only.
  for(let cycle=0;cycle<12;cycle++) {
    for(let n=2;n<=4;n++){await key('d',['meta']);await wait(`document.querySelectorAll('[data-chat]').length===${n}`);}
    await valid();
    const divider='[data-chat-divider][aria-orientation="vertical"]', from=await point(divider);
    await input({type:'mouseDown',button:'left',clickCount:1,...from});
    for(let n=0;n<48;n++){await input({type:'mouseMove',x:from.x+Math.round(Math.sin(n/3)*45),y:from.y});pointerMoves++;}
    await input({type:'mouseUp',button:'left',clickCount:1,...from});
    await key('=', ['meta','control']);await valid();
    // Burst of cancelled gestures must not leak a preview or alter membership.
    const tab=await point('[data-tab-id]');
    await input({type:'mouseDown',button:'left',clickCount:1,...tab});
    for(let n=0;n<12;n++){await input({type:'mouseMove',x:tab.x+n*3,y:tab.y+80+n});pointerMoves++;}
    await key('Escape');await input({type:'mouseUp',button:'left',clickCount:1,...tab});
    for(const id of (await ids()).filter(id=>id!==base)){await click(`[data-chat="${id}"] [aria-label="Close this split"]`);}
    await wait(`document.querySelectorAll('[data-chat]').length===1`);await valid();
    if(cycle===3||cycle===7||cycle===11)await sample(`after-${cycle+1}-cycles`);
  }
  const end=await treeSample(process.pid);
  const used=[...end.times].reduce((n,[id,time])=>n+Math.max(0,time-(start.times.get(id)??time)),0);
  if(mixed) {
    const drop=async(target,edge)=>{
      await click('[aria-label="New chat"]');await wait(`document.querySelectorAll('[data-tab-id]').length===2 && document.querySelectorAll('[data-chat]').length===1`);
      const source=(await ids())[0];
      await click(`[data-tab-id="${base}"] button[aria-pressed]`);await wait(`!!document.querySelector('[data-chat="${target}"]')`);
      const from=await point(`[data-tab-id="${source}"]`);
      const to=await js(`(()=>{const r=document.querySelector('[data-chat="${target}"]').getBoundingClientRect();return {x:Math.round(${edge==='right'?'r.right-20':'r.left+r.width/2'}),y:Math.round(${edge==='bottom'?'r.bottom-20':'r.top+r.height/2'})}})()`);
      await input({type:'mouseDown',button:'left',clickCount:1,...from});
      for(let n=1;n<=24;n++){await input({type:'mouseMove',x:Math.round(from.x+(to.x-from.x)*n/24),y:Math.round(from.y+(to.y-from.y)*n/24)});pointerMoves++;}
      await wait(`!!document.querySelector('[data-tab-drop="split"]')`);
      await input({type:'mouseUp',button:'left',clickCount:1,...to});
      await wait(`document.querySelectorAll('[data-tab-id]').length===1`);await settle();await valid();return source;
    };
    const right=await drop(base,'right'), bottomLeft=await drop(base,'bottom'), bottomRight=await drop(right,'bottom');
    const boxes=await geometry(), find=id=>boxes.find(p=>p.id===id);
    assert.deepEqual(await ids(),[base,bottomLeft,right,bottomRight]);
    assert.ok(find(base).x<find(right).x&&find(base).y<find(bottomLeft).y&&find(right).y<find(bottomRight).y);
    assert.equal(await js(`document.querySelectorAll('[data-chat-divider][aria-orientation="horizontal"]').length`),2);
    assert.equal(await js(`document.querySelector('[data-tab-id]').dataset.tabMembers.split(',').length`),4);
    await js(`document.querySelectorAll('[data-chat-divider]').forEach((e,i)=>e.dataset.stressDivider=String(i))`);
    for(let round=0;round<12;round++) for(let index=0;index<3;index++) {
      const selector=`[data-chat-divider][data-stress-divider="${index}"]`;
      const before=await js(`Array.from(document.querySelectorAll('[data-chat-divider]'))[${index}].getAttribute('aria-valuenow')`);
      const p=await js(`(()=>{const e=document.querySelector(${JSON.stringify(selector)}),r=e.getBoundingClientRect(),h=e.getAttribute('aria-orientation')==='horizontal';return {x:Math.round(r.left+r.width*(h?.25:.5)),y:Math.round(r.top+r.height*(h?.5:.25))}})()`);const horizontal=await js(`document.querySelector(${JSON.stringify(selector)}).getAttribute('aria-orientation')==='horizontal'`);
      await input({type:'mouseDown',button:'left',clickCount:1,...p});
      const sign=round%2?-1:1;
      const to={x:p.x+(horizontal?0:35*sign),y:p.y+(horizontal?25*sign:0)};
      for(let n=1;n<=24;n++){await input({type:'mouseMove',x:Math.round(p.x+(to.x-p.x)*n/24),y:Math.round(p.y+(to.y-p.y)*n/24)});pointerMoves++;}
      await input({type:'mouseUp',button:'left',clickCount:1,...to});
      await wait(`Array.from(document.querySelectorAll('[data-chat-divider]'))[${index}].getAttribute('aria-valuenow')!==${JSON.stringify(before)}`);await valid();
    }
    for(const id of [bottomLeft,right,bottomRight]) {
      await click(`[data-chat="${id}"] textarea`);
      for(const keyCode of `Draft for pane ${id}`)await input({type:'char',keyCode});
    }
    await key('=', ['meta','control']);await settle();await sleep(150);
    fs.writeFileSync(path.join(output,'four-pane-mixed.png'),(await wc.capturePage()).toPNG());
    await click('[aria-label="New chat"]');await wait(`document.querySelectorAll('[data-chat]').length===1`);
    await click(`[data-tab-id="${base}"] button[aria-pressed]`);await wait(`document.querySelectorAll('[data-chat]').length===4`);
    assert.deepEqual(await ids(),[base,bottomLeft,right,bottomRight]);await valid();
    for(const id of [bottomLeft,right,bottomRight])assert.equal(await js(`document.querySelector('[data-chat="${id}"] textarea').value`),`Draft for pane ${id}`);
    await sample('mixed-four-panes');
    await click(`[data-chat="${bottomLeft}"] [aria-label="Close this split"]`);
    await wait(`document.querySelectorAll('[data-chat]').length===3`);await valid();
    const collapsed=await geometry();
    assert.ok(collapsed.find(p=>p.id===base).height>collapsed.find(p=>p.id===right).height*1.8,'Closing one branch expands only its surviving sibling');
  }
  const result={cycles:12,createdAndClosedChats:36,pointerMoves,mixedDividerDrags:mixed?36:0,mixed,samples,cpuPercent:used/(end.at-start.at)*100,seconds:(end.at-start.at)/1000};
  // Compare late checkpoints after caches have warmed, not initial module loading.
  assert.ok(samples[3].heapMiB<samples[1].heapMiB+6,'Closed chat churn must not retain growing heaps');
  assert.ok(samples[3].nodes<samples[1].nodes+500,'Closed chat churn must not retain growing DOM trees');
  fs.writeFileSync(path.join(output,'split-stress.json'),JSON.stringify(result,null,2));
  console.log('PASS bounded split stress',JSON.stringify(result));
}
module.exports={runSplitStress};
