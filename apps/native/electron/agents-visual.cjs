const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
async function runAgentVisuals({ win, origin, output }) {
  const js = source => win.webContents.executeJavaScript(source);
  const selectChild = id => js(`(()=>{const id=${JSON.stringify(id)}, button=document.querySelector('[data-child-agent="'+id+'"]');if(button){button.click();return;}const select=document.querySelector('[aria-label="Select sub-agent"]');Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(select,id);select.dispatchEvent(new Event('change',{bubbles:true}));})()`);
  const wait = async source => { for (let i = 0; i < 100; i++) { if (await js(source)) return; await new Promise(r => setTimeout(r, 40)); } console.error(await js('document.body.innerText')); fs.writeFileSync(path.join(output, 'agents-failed.png'), (await win.webContents.capturePage()).toPNG()); throw Error(`Agent visual timeout: ${source}`); };
  win.webContents.on('console-message', (_e, level, message) => { if (level >= 2) console.error('Agent fixture:', message); });
  win.show(); win.focus();
  await win.loadURL(`${origin}/visual-tests/agents`);
  await wait(`document.body.textContent.includes('Implement navigation')`);
  assert.equal(await js(`document.querySelector('button[type="submit"]').disabled`), true);
  for (const theme of ['light', 'dark', 'codegraff']) {
    await js(`document.querySelector('[data-agent-theme="${theme}"]').click()`);
    await js('document.fonts.ready.then(()=>true)');
    const bounds = await js(`(()=>{const a=document.querySelector('aside').getBoundingClientRect(),b=document.querySelector('textarea').getBoundingClientRect();return {right:a.right,bottom:b.bottom,height:innerHeight,width:innerWidth}})()`);
    assert.ok(bounds.right <= bounds.width && bounds.bottom < bounds.height, JSON.stringify(bounds));
    fs.writeFileSync(path.join(output, `agents-${theme}.png`), (await win.webContents.capturePage()).toPNG());
  }
  await js(`document.querySelectorAll('[aria-label="Agent scope"] button')[1].click()`);
  await wait(`document.body.textContent.includes('Review accessibility')`);
  await js(`document.querySelectorAll('li button')[1].click()`);
  await wait(`document.querySelector('[data-child-agent="child-working"]')`);
  assert.notEqual(await js(`document.activeElement.getAttribute('aria-label')`), 'Message to Graff', 'Inspection should not move focus into the send form');
  await selectChild('child-working');
  await wait(`document.querySelector('[aria-label="Sub-agent activity"]')?.textContent.includes('Live')`);
  assert.equal(await js(`document.querySelector('[data-tool-summary]')?.getAttribute('aria-expanded')`), 'false');
  await selectChild('child-completed');
  await wait(`document.querySelector('[aria-label="Sub-agent activity"]')?.textContent.includes('The focus order is correct.')`);
  await js(`document.querySelector('[data-tool-summary]').click()`);
  await wait(`document.querySelector('[aria-label="Sub-agent activity"]')?.textContent.includes('navigation.ts')`);
  await js(`document.querySelector('[data-tool-row]').click()`);
  await wait(`document.querySelector('[aria-label="Sub-agent activity"]')?.textContent.includes('navigation result')`);
  assert.equal(await js(`document.querySelector('[data-agent-sent]').textContent`), '', 'Reading activity must not send messages');
  assert.equal(await js(`document.querySelector('[aria-label="Sub-agent activity"]').textContent.includes('Recent activity only')`), true);
  await js(`document.querySelector('[data-tool-row]').click()`);
  await js(`Promise.all(document.getAnimations().filter(a=>a.effect?.getTiming().iterations!==Infinity).map(a=>a.finished.catch(()=>{}))).then(()=>true)`);
  assert.equal(await js(`getComputedStyle(document.querySelector('[aria-label="Sub-agent activity"] article')).opacity`), '1');
  for (const theme of ['light', 'dark', 'codegraff']) {
    await js(`document.querySelector('[data-agent-theme="${theme}"]').click()`);
    await js('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))');
    fs.writeFileSync(path.join(output, `agents-child-${theme}.png`), (await win.webContents.capturePage()).toPNG());
  }
  // Switch before the deliberately late working-child response arrives.
  await selectChild('child-working');
  await selectChild('child-failed');
  await wait(`document.querySelector('[aria-label="Sub-agent activity"]')?.textContent.includes('Worker could not finish.')`);
  await new Promise(resolve => setTimeout(resolve, 500));
  assert.equal(await js(`document.querySelector('[aria-label="Sub-agent activity"] strong').textContent`), 'Interrupted worker');
  await js(`document.querySelector('[aria-label="Close sub-agent activity"]').click()`);
  await wait(`!document.querySelector('[aria-label="Sub-agent activity"]')`);
  await js(`Array.from(document.querySelectorAll('button')).find(b => b.textContent === 'Message this Graff…').click()`);
  await js(`(()=>{const t=document.querySelector('textarea');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(t,'Please review this update.');t.dispatchEvent(new Event('input',{bubbles:true}));})()`);
  await wait(`!document.querySelector('button[type="submit"]').disabled`);
  await js(`document.querySelector('button[type="submit"]').click()`);
  await wait(`document.body.textContent.includes('Queued · Graff')`);
  const sent = JSON.parse(await js(`document.querySelector('[data-agent-sent]').textContent`));
  assert.equal(sent.target, 'peer-b'); assert.equal(sent.startId, '12'); assert.equal(sent.kind, 'message');
  await js(`document.querySelector('[data-agent-case="empty"]').click()`);
  await wait(`document.body.textContent.includes('No connected Graffs')`);
  assert.equal(await js(`document.querySelector('button[type="submit"]').disabled`), true);
  await js(`document.querySelector('[data-agent-case="error"]').click()`);
  await wait(`document.querySelector('[role="alert"]')?.textContent.includes('Observer unavailable')`);
  console.log('Agents visual checks passed: themes, scope, live/completed/failed children, tool disclosure, selection races, read-only inspection, explicit send, disconnection and errors.');
}
module.exports = { runAgentVisuals };
