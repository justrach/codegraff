const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
async function runAgentVisuals({ win, origin, output }) {
  const js = source => win.webContents.executeJavaScript(source);
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
  assert.equal(await js(`document.activeElement.getAttribute('aria-label')`), 'Message to Graff');
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
  console.log('Agents visual checks passed: themes, bounds, scope, targeting, queued send, disconnected recipient, error.');
}
module.exports = { runAgentVisuals };
