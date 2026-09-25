const desktop = require('./test-desktop.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
async function runTabDrag({win, origin, output, injectMissedCollapseClick=false}) {
  const wc=win.webContents, js=code=>wc.executeJavaScript(code);
  desktop.attachTestDebugger(wc);
  console.log('Host reduced motion:', await js(`matchMedia('(prefers-reduced-motion: reduce)').matches`));
  // Both motion modes are explicit test inputs, independent of runner settings.
  await wc.debugger.sendCommand('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'no-preference'}]});
  const wait=async code=>{for(let i=0;i<100;i++){if(await js(code))return;await new Promise(r=>setTimeout(r,50));}throw Error(`Tab drag condition failed: ${code}`);};
  const collapseObservations=[];
  let missedCollapseInjected=false;
  const ready=async()=>{
    await wait(`!!document.querySelector('[data-workspace-ready="true"] textarea[aria-label="Prompt"]')`);
    // setSize returns before the responsive navigation has committed wide mode.
    await wait(`innerWidth>=1024 && !!document.querySelector('[data-navigation-panel]:not([popover])')`);
    const tabs=`!!document.querySelector('[data-session-navigation="tabs"]')`;
    if(await js(tabs))return;
    // A hidden Electron window can hit-test the collapse control before its
    // trusted click is delivered. Observe delivery and retry only while the
    // sidebar still owns navigation; never toggle an already-collapsed one.
    for(let attempt=0;attempt<3;attempt++){
      const expanded=await js(`!!document.querySelector('[aria-label="Collapse sidebar"]:not([aria-hidden="true"])')?.checkVisibility()`);
      if(!expanded)break;
      await js(`(()=>{window.__tabCollapseClick=false;window.__tabCollapseObserver=e=>{if(e.isTrusted&&e.target?.closest?.('[aria-label="Collapse sidebar"]'))window.__tabCollapseClick=true};document.addEventListener('click',window.__tabCollapseObserver,true)})()`);
      const skipped=injectMissedCollapseClick&&!missedCollapseInjected;
      if(skipped)missedCollapseInjected=true;
      try{
        if(!skipped)await click('[aria-label="Collapse sidebar"]');
        const end=Date.now()+1000;
        while(Date.now()<end&&!await js(tabs))await new Promise(r=>setTimeout(r,50));
        const state={attempt:attempt+1,skipped,clicked:await js('window.__tabCollapseClick'),tabs:await js(tabs)};
        collapseObservations.push(state);
        fs.writeFileSync(path.join(output,'tab-navigation-readiness.json'),JSON.stringify(collapseObservations));
        if(state.tabs&&state.clicked)return;
        if(state.tabs)break;
      }finally{await js(`document.removeEventListener('click',window.__tabCollapseObserver,true)`);}
    }
    throw Error(`Tab navigation did not accept a trusted collapse click: ${JSON.stringify(collapseObservations.at(-1))}`);
  };
  const tabs=()=>js(`Array.from(document.querySelectorAll('[data-tab-id]')).map(t=>Number(t.dataset.tabId))`);
  const panes=()=>js(`Array.from(document.querySelectorAll('[data-chat]')).map(t=>Number(t.dataset.chat))`);
  const point=selector=>js(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)}})()`);
  const settledPoint=async selector=>{
    // Hydration and workspace discovery move the tab strip after loadURL.
    // Hit-test settled coordinates before sending real pointer input.
    for(let i=0;i<50;i++) {
      const before=await point(selector);
      await new Promise(resolve=>setTimeout(resolve,100));
      const p=await point(selector);
      if(before.x!==p.x||before.y!==p.y)continue;
      if(!await js(`document.querySelector(${JSON.stringify(selector)})?.contains(document.elementFromPoint(${p.x},${p.y}))`))continue;
      return p;
    }
    throw Error(`Pointer target did not settle: ${selector}`);
  };
  const click=async selector=>{
    const p=await settledPoint(selector);
    for(const type of ['mouseDown','mouseUp'])await desktop.testInput(wc,{type,button:'left',clickCount:1,...p});
  };
  const focusComposer=async()=>{
    // The landing composer moves when the browser closes and workspace health arrives.
    // Wait for its layout, then retry only the harmless focus click if it moved again.
    for(let i=0;i<30;i++) {
      const before=await point('textarea[aria-label="Prompt"]');
      await new Promise(resolve=>setTimeout(resolve,100));
      const after=await point('textarea[aria-label="Prompt"]');
      if(before.x!==after.x||before.y!==after.y)continue;
      await click('textarea[aria-label="Prompt"]');
      if(await js(`document.activeElement===document.querySelector('textarea[aria-label="Prompt"]')`))return;
    }
    throw Error('Composer did not settle and accept pointer focus');
  };
  const down=async id=>{
    const p=await settledPoint(`[data-tab-id="${id}"]`);
    // CDP mousePressed without a preceding move often misses the tab after the composer click.
    await desktop.testInput(wc,{type:'mouseMove',...p});
    await desktop.testInput(wc,{type:'mouseDown',button:'left',clickCount:1,...p});
    return p;
  };
  const move=async(from,to)=>{
    for(let i=1;i<=10;i++){
      await desktop.testInput(wc,{type:'mouseMove',button:'left',x:Math.round(from.x+(to.x-from.x)*i/10),y:Math.round(from.y+(to.y-from.y)*i/10)});
      await new Promise(r=>setTimeout(r,16));
    }
  };
  const up=to=>desktop.testInput(wc,{type:'mouseUp',button:'left',clickCount:1,...to});
  const drag=async(id,to)=>{await move(await down(id),to);await up(to);};
  // This fixture starts a new layout. Earlier frontend legs now leave their
  // open tabs recoverable across navigation, so clear that one test record.
  await js(`localStorage.removeItem('graff.native.open-tabs.v1')`);
  await wc.loadURL(origin);win.setSize(1320,850);
  await ready();
  await click('[aria-label="New chat"]');
  await wait(`document.querySelectorAll('[data-tab-id]').length===2`);
  const [one,two]=await tabs();
  await click('textarea[aria-label="Prompt"]');
  for(const keyCode of 'Draft survives dragging')await desktop.testInput(wc,{type:'char',keyCode});
  await wait(`document.querySelector('textarea[aria-label="Prompt"]').value==='Draft survives dragging'`);
  await settledPoint(`[data-tab-id="${one}"]`);
  await settledPoint(`[data-tab-id="${two}"]`);
  const target=await js(`(()=>{const r=document.querySelector('[data-tab-id="${one}"]').getBoundingClientRect();return {x:Math.round(r.left+r.width*0.25),y:Math.round(r.top+r.height/2)}})()`);
  await drag(two,target);
  await wait(`Number(document.querySelector('[data-tab-id]').dataset.tabId)===${two}`);
  assert.deepEqual(await panes(),[two]);
  assert.equal(await js(`document.querySelector('textarea[aria-label="Prompt"]').value`),'Draft survives dragging');
  const edge=await js(`(()=>{const r=document.querySelector('[data-chat]').getBoundingClientRect();return {x:Math.round(r.right-24),y:Math.round(r.top+r.height/2)}})()`);
  await move(await down(one),edge);
  await wait(`!!document.querySelector('[data-tab-drop="split"]')`);
  assert.ok(await js(`!!document.querySelector('[data-tab-drag-ghost]')`), 'A lifted tab must follow the pointer');
  fs.writeFileSync(path.join(output,'tab-drag-preview.png'),(await wc.capturePage()).toPNG());
  await up(edge);
  await wait(`document.querySelectorAll('[data-chat]').length===2`);
  assert.deepEqual(await panes(),[two,one]);
  assert.equal(await js(`document.querySelector('[data-chat="${two}"] textarea').value`),'Draft survives dragging');
  await wait(`!Array.from(document.querySelectorAll('[data-chat]')).some(p=>p.getAnimations().some(a=>a.playState==='running')) && !document.querySelector('[data-tab-drop]')`);
  await js(`new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))`);
  fs.writeFileSync(path.join(output,'tabs-split-right.png'),(await wc.capturePage()).toPNG());
  assert.deepEqual(await tabs(),[two], 'A split must occupy one combined tab');
  assert.equal(await js(`document.querySelector('[data-tab-id]').dataset.tabMembers`),`${two},${one}`);
  // Escape cancels the whole-group gesture without changing layout or ordering.
  const order=await tabs();
  await move(await down(two),edge);
  await desktop.testInput(wc,{type:'keyDown',keyCode:'Escape'});await desktop.testInput(wc,{type:'keyUp',keyCode:'Escape'});await up(target);
  await wait(`!document.querySelector('[data-tab-drag-ghost], [data-tab-drop]')`);
  assert.deepEqual(await tabs(),order);assert.deepEqual(await panes(),[two,one]);
  // Real drop handler: a hidden fifth tab cannot create a fifth pane.
  for (let i=0;i<2;i++) {
    for(const type of ['keyDown','keyUp'])await desktop.testInput(wc,{type,keyCode:'d',modifiers:['meta']});
    await wait(`document.querySelectorAll('[data-chat]').length===${i+3}`);
  }
  await wait(`document.querySelectorAll('[data-chat]').length===4`);
  const four=await panes();
  await click('[aria-label="New chat"]');
  await wait(`document.querySelectorAll('[data-tab-id]').length===2 && document.querySelectorAll('[data-chat]').length===1`);
  const hidden=(await panes())[0];
  await click(`[data-tab-id="${four[0]}"] button[aria-pressed]`);
  await wait(`document.querySelectorAll('[data-chat]').length===4`);
  const before=await panes();
  const capEdge=await js(`(()=>{const r=document.querySelector('[data-chat]').getBoundingClientRect();return {x:Math.round(r.right-16),y:Math.round(r.top+r.height/2)}})()`);
  await drag(hidden,capEdge);
  await wait(`!!document.querySelector('[data-split-limit]')`);
  assert.deepEqual(await panes(),before);
  // A fresh single pane can split vertically; mixed trees have separate stress coverage.
  await js(`localStorage.removeItem('graff.native.open-tabs.v1')`);
  await wc.loadURL(origin);await ready();
  if(await js(`!!document.querySelector('[aria-label="Close browser"]')`))await click('[aria-label="Close browser"]');
  await wait(`!document.querySelector('[aria-label="Close browser"]')`);
  await focusComposer();
  for(const keyCode of 'Plan the next release')await desktop.testInput(wc,{type:'char',keyCode});
  await wait(`document.querySelector('textarea[aria-label="Prompt"]').value==='Plan the next release'`);
  await click('[aria-label="New chat"]');await wait(`document.querySelectorAll('[data-tab-id]').length===2`);
  await click('textarea[aria-label="Prompt"]');
  for(const keyCode of 'Review the changes side by side')await desktop.testInput(wc,{type:'char',keyCode});
  const [first,second]=await tabs();
  const bottom=await js(`(()=>{const r=document.querySelector('[data-chat]').getBoundingClientRect();return {x:Math.round(r.left+r.width/2),y:Math.round(r.bottom-22)}})()`);
  const stopRecording = await require('./tab-motion-capture.cjs').recordTabMotion(wc, output);
  const motion = await require('./pane-motion-observer.cjs').observePaneMotion(wc);
  try {
    const from = await down(first);
    for (let i=1;i<=36;i++) {
      await desktop.testInput(wc,{type:'mouseMove',x:Math.round(from.x+(bottom.x-from.x)*i/36),y:Math.round(from.y+(bottom.y-from.y)*i/36)});
      await new Promise(resolve=>setTimeout(resolve,16));
    }
    await wait(`document.querySelector('[data-tab-drop]')?.textContent.includes('Split below')`);
    await new Promise(resolve=>setTimeout(resolve,220));
    fs.writeFileSync(path.join(output,'tabs-drop-below-preview.png'),(await wc.capturePage()).toPNG());
    await up(bottom);await wait(`document.querySelectorAll('[data-chat]').length===2`);
    await wait(`!Array.from(document.querySelectorAll('[data-chat]')).some(p=>p.getAnimations().some(a=>a.playState==='running'))`);
    await motion.assertStarted(); // Start evidence remains valid after playback ends.
    await new Promise(resolve=>setTimeout(resolve,300));
  } finally { await motion.stop(); await stopRecording(); }
  assert.deepEqual(await panes(),[second,first]);
  assert.equal(await js(`document.querySelector('[data-chat="${first}"] textarea').value`),'Plan the next release');
  assert.equal(await js(`getComputedStyle(document.querySelector('[data-chat-layout]')).flexDirection`),'column');
  assert.deepEqual(await tabs(),[second], 'Stacked panes share one combined tab');
  fs.writeFileSync(path.join(output,'tabs-split-below.png'),(await wc.capturePage()).toPNG());
  const bounds=await js(`Array.from(document.querySelectorAll('[data-chat]')).map(p=>{const r=p.getBoundingClientRect();return {top:r.top,bottom:r.bottom}})`);
  assert.ok(bounds[0].bottom<=bounds[1].top+1, 'Settled stacked panes must not overlap');
  await require('./tab-groups-visual.cjs').runTabGroups({wc,click,wait,js,panes,tabs,drag,point,output,group:[second,first]});
  // Reduced motion keeps the destination cue but removes lift and settling effects.
  desktop.attachTestDebugger(wc);
  await wc.debugger.sendCommand('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'reduce'}]});
  try {
    await js(`localStorage.removeItem('graff.native.open-tabs.v1')`);
    await wc.loadURL(origin);await ready();
    await click('[aria-label="New chat"]');await wait(`document.querySelectorAll('[data-tab-id]').length===2`);
    const [source]=await tabs();
    await move(await down(source),bottom);await wait(`!!document.querySelector('[data-tab-drop="split"]')`);
    assert.ok(await js(`getComputedStyle(document.querySelector('[data-tab-drop]')).transitionDuration.split(',').every(value=>parseFloat(value)<=0.00001)`), 'Reduced motion must eliminate perceptible target transitions');
    assert.equal(await js(`getComputedStyle(document.querySelector('[data-tab-drag-ghost]').firstElementChild).animationName`),'none');
    await up(bottom);await wait(`document.querySelectorAll('[data-chat]').length===2`);
    assert.equal(await js(`Array.from(document.querySelectorAll('[data-chat], [data-tab-id]')).flatMap(p=>p.getAnimations()).filter(a=>Number(a.effect.getTiming().duration)>1).length`),0, 'Reduced motion must skip pane and tab settling; global instant color transitions are allowed');
  } finally { await wc.debugger.sendCommand('Emulation.setEmulatedMedia',{features:[]}); }
  if(injectMissedCollapseClick)assert.ok(collapseObservations.some(row=>row.skipped&&!row.clicked&&!row.tabs)&&collapseObservations.some(row=>row.clicked&&row.tabs),'missed collapse click must recover through trusted input');
  console.log('PASS pointer tab drag: reorder, right/below splits, preserved draft, Escape cancellation, reduced motion and settled geometry');
}
module.exports={runTabDrag};
