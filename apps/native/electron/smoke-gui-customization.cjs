const assert = require('node:assert/strict');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function smokeGuiCustomization({ win, backend }) {
  const js = source => win.webContents.executeJavaScript(source);
  const wait = async source => { for (let i = 0; i < 100; i++) { if (await js(source)) return; await sleep(100); } throw Error(`Customization check timed out: ${source}`); };
  const type = text => js(`(()=>{const input=document.querySelector('textarea[aria-label="Prompt"]');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(input,${JSON.stringify(text)});input.dispatchEvent(new Event('input',{bubbles:true}));})()`);
  for (const prefix of ['$', '@']) {
    await type(`${prefix}gui-th`);
    await wait(`!![...document.querySelectorAll('button')].find(b=>b.textContent.includes('GUI skill ·'))`);
    await js(`[...document.querySelectorAll('button')].find(b=>b.textContent.includes('GUI skill ·')).click()`);
    await wait(`document.querySelector('textarea[aria-label="Prompt"]').value==='$gui-theme '`);
  }
  // No model request: verify the composer inserts a reviewable draft, then clear it.
  await type('');
  const fixture = { version: 1, id: 'smoke-ocean', name: 'Smoke Ocean', base: 'dark', colors: { page: '#112233', surface: '#172d43', ink: '#f0f7ff', 'ink-2': '#d0e0f0', 'ink-3': '#bdcddd', accent: '#89d6ed', 'accent-ink': '#a0dfff', 'accent-tint': '#21425a' }, font: 'serif', corners: 4 };
  assert.equal(await js(`fetch('/api/themes',{method:'POST',headers:{'content-type':'application/json'},body:${JSON.stringify(JSON.stringify(fixture))}}).then(r=>r.status)`), 200);
  await js(`document.querySelector('[aria-label="Appearance"]').click()`);
  await wait(`!!document.querySelector('[aria-label="Use theme Smoke Ocean"]')`);
  await js(`document.querySelector('[aria-label="Use theme Smoke Ocean"]').click()`);
  assert.equal(await js(`getComputedStyle(document.documentElement).getPropertyValue('--page').trim()`), '#112233');
  assert.equal(await js('document.documentElement.classList.contains("dark")'), true);
  assert.equal(await js('document.body.style.fontFamily.includes("Georgia")'), true);
  await win.loadURL(backend.origin);
  await wait(`!!document.querySelector('[aria-label="Appearance"]')`);
  assert.equal(await js(`getComputedStyle(document.documentElement).getPropertyValue('--page').trim()`), '#112233');
  await js(`document.querySelector('[aria-label="Appearance"]').click()`);
  await wait(`!!document.querySelector('[aria-label="Close appearance"]')`);
  await js(`[...document.querySelectorAll('[role="dialog"] button')].find(b=>b.textContent.includes('Official · Japanese palette')).click()`);
  assert.equal(await js('document.documentElement.style.getPropertyValue("--page")'), '');
  assert.equal(await js('document.body.style.fontFamily'), '');
  assert.equal(await js('document.documentElement.style.getPropertyValue("--radius-control")'), '');
  await js(`document.querySelector('[aria-label="Close appearance"]').click()`);
  return 'both skill mention menus, editable draft, theme import, selection, reload persistence and complete built-in reset';
}
module.exports = { smokeGuiCustomization };
