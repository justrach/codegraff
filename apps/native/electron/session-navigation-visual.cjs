const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const desktop = require('./test-desktop.cjs');

async function runSessionNavigation({ win, output }) {
  const wc = win.webContents, js = source => wc.executeJavaScript(source);
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  const wait = async source => {
    for (let n=0;n<150;n++) { if (await js(source)) return; await pause(40); }
    throw Error(`Session navigation timeout: ${source}`);
  };
  const click = async selector => {
    const point = await js(`(()=>{const e=document.querySelector(${JSON.stringify(selector)});if(!e)throw Error('Missing target');const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
    for (const type of ['mouseDown','mouseUp']) await desktop.testInput(wc,{type,...point,button:'left',clickCount:1});
    await pause(80);
  };
  const active = () => js(`Number(document.querySelector('[data-chat][data-focused="true"]').dataset.chat)`);
  const ids = () => js(`Array.from(document.querySelectorAll('[data-tab-id]'),e=>Number(e.dataset.tabId))`);
  const capture = async name => {
    await js('document.fonts.ready.then(()=>true)'); await pause(320);
    fs.writeFileSync(path.join(output,name+'.png'),(await wc.capturePage()).toPNG());
  };
  await wait(`!!document.querySelector('[data-session-navigation="sidebar"]')`);
  assert.equal(await js(`document.querySelector('[data-session-tab-strip]').getBoundingClientRect().height`),0);
  await click('[aria-label="Workspace navigation"] button[aria-label="Appearance"]');
  await wait(`!!document.querySelector('[role="dialog"][aria-label="Appearance"]')`);
  const appearance = await js(`(()=>{const d=document.querySelector('[role="dialog"][aria-label="Appearance"]');const r=d.getBoundingClientRect();const h=[...d.querySelectorAll('strong')].find(el=>el.textContent==='Appearance');const hr=h.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,headingTop:hr.top,headingVisible:hr.bottom>0&&hr.top<innerHeight,vw:innerWidth};})()`);
  assert.ok(appearance.left >= 0, 'appearance stays on-screen from the sidebar gear');
  assert.ok(appearance.right <= appearance.vw, 'appearance does not overflow the right edge');
  assert.ok(appearance.headingVisible && appearance.headingTop >= appearance.top, 'Appearance heading stays visible');
  await click('[aria-label="Close appearance"]');
  await wait(`!document.querySelector('[role="dialog"][aria-label="Appearance"]')`);
  await click('[aria-label="Workspace navigation"] button[aria-label="New chat"]');
  const drafted = await active();
  for (const keyCode of 'Keep this draft') await desktop.testInput(wc,{type:'char',keyCode});
  await click('[aria-label="Workspace navigation"] button[aria-label="New chat"]');
  const last = await active(), before = await ids();
  assert.equal(before.length,3);
  await click(`[data-tab-id="${drafted}"] button[aria-pressed]`);
  assert.equal(await js(`document.querySelector('[data-chat="${drafted}"] textarea').value`),'Keep this draft');
  await capture('sidebar-open');
  // Sidebar reordering uses the vertical midpoint, while pane-edge drops remain available.
  const points = await js(`(()=>{const a=document.querySelector('[data-tab-id="${last}"]').getBoundingClientRect(),b=document.querySelector('[data-tab-id="${before[0]}"]').getBoundingClientRect();return {a:{x:a.x+a.width/2,y:a.y+a.height/2},b:{x:b.x+b.width/2,y:b.y+2}}})()`);
  await desktop.testInput(wc,{type:'mouseDown',...points.a,button:'left',clickCount:1});
  for(let i=1;i<=8;i++){await desktop.testInput(wc,{type:'mouseMove',x:points.a.x+(points.b.x-points.a.x)*i/8,y:points.a.y+(points.b.y-points.a.y)*i/8,button:'left',buttons:['left']});await pause(20);}
  await desktop.testInput(wc,{type:'mouseUp',...points.b,button:'left',clickCount:1});
  await wait(`Number(document.querySelector('[data-tab-id]').dataset.tabId)===${last}`);
  await click('[aria-label="Collapse sidebar"]');
  await wait(`!!document.querySelector('[data-session-navigation="tabs"]')`);
  assert.equal(await js(`document.querySelectorAll('[data-session-navigation]').length`),1);
  await click(`[data-tab-id="${drafted}"] button[aria-pressed]`);
  assert.equal(await active(),drafted);
  assert.equal(await js(`document.querySelector('[data-chat="${drafted}"] textarea').value`),'Keep this draft');
  assert.equal(await js(`!!document.querySelector('[data-chat-empty] h1')`),false,'focused mode keeps the empty composer compact');
  await click('[data-workspace-toolbar] button[aria-label="Appearance"]');
  await wait(`!!document.querySelector('[role="dialog"][aria-label="Appearance"]')`);
  await click('[aria-label="Close appearance"]');
  await desktop.testInput(wc,{type:'keyDown',keyCode:'Escape'});
  await desktop.testInput(wc,{type:'keyUp',keyCode:'Escape'});
  await capture('tabs-only');
  wc.send('desktop-action','split-right');
  await wait(`document.querySelectorAll('[data-chat]').length===2`);
  const splitIds = await js(`Array.from(document.querySelectorAll('[data-chat]'),e=>Number(e.dataset.chat))`);
  await click('[aria-label="Expand sidebar"]');
  await wait(`!!document.querySelector('[data-session-navigation="sidebar"]')`);
  const group = await js(`document.querySelector('[data-tab-members*="${drafted},"]')?.dataset.tabId`);
  assert.ok(group,'split group remains navigable in sidebar');
  await click(`[data-tab-id="${last}"] button[aria-pressed]`);
  await click(`[data-tab-id="${group}"] button[aria-pressed]`);
  assert.deepEqual(await js(`Array.from(document.querySelectorAll('[data-chat]'),e=>Number(e.dataset.chat))`),splitIds);
  win.setContentSize(800,760);
  await wait(`!!document.querySelector('[data-session-navigation="tabs"]')`);
  await click('[aria-label="Open navigation"]');
  await wait(`!!document.querySelector('[data-session-navigation="sidebar"]')`);
  assert.equal(await js(`document.querySelector('[data-session-tab-strip]').getBoundingClientRect().height`),0);
  await capture('narrow-sidebar');
  await click('[aria-label="Close navigation"]');
  await wait(`!!document.querySelector('[data-session-navigation="tabs"]')`);
  assert.equal(await js(`document.querySelectorAll('[data-session-navigation]').length`),1);
  assert.equal(await js(`document.querySelector('[data-chat="${drafted}"] textarea').value`),'Keep this draft');
  console.log('Session navigation passed: one surface, unsaved chats, drafts, vertical reorder, split groups and narrow popover.');
}
module.exports = { runSessionNavigation };
