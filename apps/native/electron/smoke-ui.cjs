const assert = require('node:assert/strict');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function smokeUI({ win, browser, backend }) {
  require('electron').app.focus({ steal: true }); win.show(); win.focus();
  const js = expression => win.webContents.executeJavaScript(expression);
  const wait = async expression => {
    for (let n = 0; n < 100; n++) { if (await js(expression)) return; await sleep(100); }
    throw Error(`UI did not reach: ${expression}; visible=${await js('document.visibilityState')}`);
  };
  const click = async selector => {
    await wait(`!!document.querySelector(${JSON.stringify(selector)})`);
    await js(`document.querySelector(${JSON.stringify(selector)}).click()`); await sleep(100);
  };
  await wait(`!!document.querySelector('[aria-label="Appearance"]')`);
  await click('[aria-label="Appearance"]');
  await wait(`!!document.querySelector('[role="dialog"][aria-label="Appearance"]')`);
  for (const [name, expected] of [['White', 'light'], ['Black', 'dark'], ['Website', 'website'], ['CodeGraff', 'codegraff']]) {
    await js(`[...document.querySelectorAll('[role="dialog"] button')].find(b=>b.textContent.includes(${JSON.stringify(name)})).click()`);
    await wait(`document.documentElement.dataset.theme===${JSON.stringify(expected)}`);
    assert.equal(await js(`document.documentElement.classList.contains('dark')`), expected === 'dark');
  }
  await click('[aria-label="Close appearance"]');
  await win.loadURL(backend.origin);
  await wait(`!!document.querySelector('[aria-label="Appearance"]')`);
  assert.equal(await js('document.documentElement.dataset.theme'), 'codegraff');
  assert.equal(await js(`document.querySelector('[aria-label="Start dictation"]').disabled`), true);

  const customization = await require('./smoke-gui-customization.cjs').smokeGuiCustomization({ win, backend });
  const modelPicker = await require('./smoke-model-picker.cjs').smokeModelPicker({ win });

  const toolDisclosure = await require('./smoke-tool-disclosure.cjs').smokeToolDisclosure({ win, backend });

  // Composer upload delay: sending must remain disabled until all bytes are staged.
  await js(`window.auditFetch=window.fetch; window.fetch=(url,...args)=>url==='/api/attach'?new Promise(resolve=>{window.auditFinishUpload=()=>resolve(new Response(JSON.stringify({path:'/tmp/audit-fixture.txt',name:'audit-fixture.txt'}),{headers:{'content-type':'application/json'}}))}):window.auditFetch(url,...args);
    const input=document.querySelector('input[type=file]'), data=new DataTransfer(); data.items.add(new File(['fixture'],'audit-fixture.txt',{type:'text/plain'})); input.files=data.files; input.dispatchEvent(new Event('change',{bubbles:true}));`);
  await wait(`!!window.auditFinishUpload`);
  assert.equal(await js(`document.querySelector('[aria-label="Send"]').disabled`), true);
  await js('window.auditFinishUpload(); window.fetch=window.auditFetch; void 0');
  await wait(`!document.querySelector('[aria-label="Send"]').disabled`);
  // No prompt is sent. Reload discards this synthetic attachment.
  await win.loadURL(backend.origin);
  await click('[aria-label="Review workspace changes"]');
  await wait(`!!document.querySelector('[aria-label="File diff"]')`);
  await wait(`document.querySelector('[aria-label="File diff"]').getAttribute('aria-busy')==='false'`);
  assert.ok(await js(`document.querySelector('[aria-label="Workspace changes"]').textContent.includes('Changes')`));
  const reviewResize = await require('./smoke-review-resize.cjs').smokeReviewResize({ win });
  const hasFiles = await js(`!!document.querySelector('[aria-label="Toggle changed file list"]')`);
  if (hasFiles) {
    await click('[aria-label="Toggle changed file list"]');
    await js(`const input=document.querySelector('[aria-label="Filter changed files"]'); Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,'no-file-with-this-name'); input.dispatchEvent(new Event('input',{bubbles:true}));`);
    await wait(`document.querySelector('[aria-label="Changed files"]').textContent.includes('No matching files')`);
    await click('[aria-label="Next changed section"]');
  }
  await click('[aria-label="Close changes"]');

  // A native page must yield to an HTML modal and return without losing its state.
  browser.setBounds('overlay-fixture', { x: 700, y: 150, width: 300, height: 300 });
  await browser.navigate('overlay-fixture', 'about:blank');
  await click('[aria-label="Appearance"]');
  await wait(`!!document.querySelector('[role="dialog"][aria-label="Appearance"]')`);
  for (let n = 0; n < 30 && !browser.overlay; n++) await sleep(50);
  assert.equal(browser.overlay, true, await js(`JSON.stringify({visibility:document.visibilityState,dialogs:[...document.querySelectorAll('[role=dialog]')].map(el=>({label:el.getAttribute('aria-label'),visible:el.checkVisibility()}))})`));
  assert.equal(browser.tabs.get('overlay-fixture').view.getVisible(), false);
  await click('[aria-label="Close appearance"]');
  for (let n = 0; n < 30 && browser.overlay; n++) await sleep(50);
  assert.equal(browser.tabs.get('overlay-fixture').view.getVisible(), true);
  browser.close('overlay-fixture');
  const result = { customization, modelPicker, toolDisclosure, reviewResize, themes: 'four choices and reload persistence', composer: 'demo dictation disabled and upload blocks send', review: hasFiles ? 'file filter, section navigation, close' : 'empty review and close', overlays: 'native page hidden and restored around app dialog' };
  return result;
}
module.exports = { smokeUI };
