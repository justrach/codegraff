const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path');
const desktop = require('./test-desktop.cjs');
async function runNarrowNavigation({win, output, click, until, report}) {
  const wc = win.webContents, js = code => wc.executeJavaScript(code);
  const escape = async () => {
    for (const type of ['keyDown','keyUp']) await desktop.testInput(wc, {type,keyCode:'Escape'});
  };
  assert.equal(await js(`innerWidth < 1024`), true, 'Exercise the breakpoint that hid navigation');
  await click('[aria-label="Open navigation"]');
  await until(() => js(`!!document.querySelector('[data-navigation-panel]:popover-open')`), 'navigation opens');
  await click('[data-workspace-trigger]');
  await until(() => js(`!!document.querySelector('[data-navigation-panel] [data-workspace-menu]')`), 'folder picker stays inside native popover layer');
  await escape();
  await until(() => js(`!document.querySelector('[data-workspace-menu]') && !!document.querySelector('[data-navigation-panel]:popover-open')`), 'Escape closes nested picker first');
  await escape();
  await until(() => js(`!document.querySelector('[data-navigation-panel]:popover-open') && document.activeElement?.getAttribute('aria-label') === 'Open navigation'`), 'Escape dismisses and restores trigger focus');
  await click('[aria-label="Open navigation"]');
  // Open conversations live in the session list; closing moves the saved one to History.
  await click('[data-session-navigation="sidebar"] [data-tab-id]:has(button[aria-pressed="true"]) [aria-label="Close tab"]');
  await until(() => js(`!!document.querySelector('#sidebar-chat-list button[data-row]')`), 'closed saved conversation available in History');
  await js(`document.querySelector('#sidebar-chat-list button[data-row]').parentElement.querySelector('button[aria-label^="Actions for "]').setAttribute('data-narrow-actions','true')`);
  await click('[data-narrow-actions="true"]');
  await until(() => js(`!!document.querySelector('button[aria-label^="Delete "]')?.checkVisibility()`), 'actual saved chat actions visible');
  await until(() => js(`document.activeElement?.getAttribute('aria-label')?.startsWith('Archive ')`), 'nested action menu keeps keyboard focus');
  await js(`new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))`);
  await new Promise(resolve=>setTimeout(resolve,150));
  fs.writeFileSync(path.join(output,'narrow-navigation-actions.png'),(await wc.capturePage()).toPNG());
  await escape();
  await until(() => js(`!document.querySelector('button[aria-label^="Delete "]')?.checkVisibility()`), 'Escape closes actions');
  await click('[aria-label="Close navigation"]');
  await until(() => js(`!document.querySelector('[data-navigation-panel]:popover-open')`), 'sidebar close control dismisses drawer');
  // Give the composer space beside the drawer so an outside input click is possible.
  if (await js(`!!document.querySelector('[aria-label="Close browser"]')?.checkVisibility()`)) await click('[aria-label="Close browser"]');
  const composerBefore = await js(`document.querySelector('textarea[aria-label="Prompt"]').getBoundingClientRect().toJSON()`);
  await click('[aria-label="Open navigation"]');
  assert.deepEqual(await js(`document.querySelector('textarea[aria-label="Prompt"]').getBoundingClientRect().toJSON()`), composerBefore, 'overlay navigation must not move the underlying composer');
  const outside = await js(`(()=>{const e=document.querySelector('textarea[aria-label="Prompt"]'),r=e.getBoundingClientRect();const x=Math.round(r.right-8),y=Math.round(r.top+r.height/2);return{x,y,hit:e.contains(document.elementFromPoint(x,y))};})()`);
  assert.equal(outside.hit, true, 'Visible part of composer remains reachable beside navigation');
  await js(`window.__dismissEvents=[];for(const type of ['pointerdown','pointerup','focusin','focusout','click'])document.addEventListener(type,e=>window.__dismissEvents.push({type,label:e.target.getAttribute?.('aria-label'),tag:e.target.tagName}),{capture:true});`);
  for (const type of ['mouseDown','mouseUp']) await desktop.testInput(wc, {type,x:outside.x,y:outside.y,button:'left',clickCount:1});
  await new Promise(resolve=>setTimeout(resolve,200));
  report.navigationDismiss = await js(`({events:window.__dismissEvents,active:document.activeElement?.outerHTML,open:!!document.querySelector('[data-navigation-panel]:popover-open')})`);
  await until(() => js(`!document.querySelector('[data-navigation-panel]:popover-open') && document.activeElement?.getAttribute('aria-label') === 'Prompt'`), 'outside click dismisses without swallowing composer focus');
  await click('[data-desktop-update-settings]');
  await until(() => js(`!!document.querySelector('[data-desktop-update-panel]')?.checkVisibility()`), 'update settings remain available');
  assert.equal(await js(`(()=>{const e=document.querySelector('[data-desktop-update-panel]'),r=e.getBoundingClientRect();return e.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2))})()`), true, 'update settings are not clipped by toolbar');
  await click('[data-desktop-update-settings]');
  await until(() => js(`!document.querySelector('[data-desktop-update-panel]')`), 'update button toggles its panel closed');
  for (let i=0;i<8;i++) await click('[title="New chat (⌘T)"]');
  await click('[aria-label="Open navigation"]');
  await until(() => js(`!!document.querySelector('[data-navigation-panel]:popover-open')`), 'navigation remains reachable after tab strip scrolls');
  await click('[aria-label="Close navigation"]');
  await until(() => js(`!!document.querySelector('[data-session-navigation="tabs"]')?.checkVisibility()`), 'overflow tabs visible after navigation closes');
  await js(`new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))`);
  fs.writeFileSync(path.join(output,'narrow-overflow-tabs.png'),(await wc.capturePage()).toPNG());
  for (let i=0;i<8;i++) await click('[data-tab-id]:has(button[aria-pressed="true"]) [aria-label="Close tab"]');
  // Resizing must not leave a popover or another copy of the sidebar behind.
  win.setContentSize(1320, 868);
  await until(() => js(`innerWidth >= 1024 && document.querySelector('[aria-label="Workspace navigation"]').getBoundingClientRect().width > 200 && !document.querySelector('[data-navigation-panel]').hasAttribute('popover')`), 'wide sidebar restored');
  assert.equal(await js(`document.querySelectorAll('[aria-label="Workspace navigation"]').length`), 1);
  report.passed.push('update controls stay unclipped and eight new chats cannot hide the navigation button');
  report.passed.push('narrow window: workspace picker and real saved-chat actions reachable; nested Escape, close control, outside dismissal and focus work; widening restores one sidebar');
}
module.exports = { runNarrowNavigation };
