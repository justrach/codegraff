const assert = require('node:assert/strict');
const testDesktop = require('./test-desktop.cjs');
const { installGalleryFixture } = require('./gallery-fixture.cjs');

// Real pointer dispatch: HTMLElement.click() misses the browser's focus default.
async function runNavigationPromptFocus({ win, origin }) {
  const wc = win.webContents, js = source => wc.executeJavaScript(source);
  const pause = () => new Promise(resolve => setTimeout(resolve, 50));
  const wait = async source => {
    for (let i = 0; i < 120; i++) { if (await js(source)) return; await pause(); }
    throw Error(`Navigation prompt focus timeout: ${source}`);
  };
  const click = async selector => {
    const composer = selector.includes('textarea[aria-label="Prompt"]');
    for (let attempt = 0; attempt < (composer ? 2 : 1); attempt++) {
      const point = await js(`(()=>{const e=document.querySelector(${JSON.stringify(selector)});if(!e)throw Error('Missing click target');if(${composer})e.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'});const r=e.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2;return {x,y,hit:e.contains(document.elementFromPoint(x,y))};})()`);
      if (composer && !point.hit) { await pause(); continue; }
      await testDesktop.testInput(wc, { type: 'mouseDown', ...point, button: 'left', clickCount: 1 });
      const release = await js(`(()=>{const e=document.querySelector(${JSON.stringify(selector)});if(!e)return null;const r=e.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2;return e.contains(document.elementFromPoint(x,y))?{x,y}:null;})()`);
      await testDesktop.testInput(wc, { type: 'mouseUp', ...point, ...release, button: 'left', clickCount: 1 });
      await pause();
      if (!composer || await js(`document.activeElement===document.querySelector(${JSON.stringify(selector)})`)) return;
    }
    throw Error(`Composer click did not focus ${selector}`);
  };
  const focused = id => wait(`document.activeElement===document.querySelector('[data-chat="${id}"] textarea[aria-label="Prompt"]') && document.activeElement?.tagName==='TEXTAREA'`);
  const active = () => js(`document.querySelector('[data-chat][data-focused="true"]').dataset.chat`);
  const tab = id => `[data-tab-members="${id}"] button[aria-pressed]`;
  const sidebar = '[aria-label="Workspace navigation"]';
  testDesktop.attachTestDebugger(wc);
  await wc.debugger.sendCommand('Page.enable');
  const { identifier } = await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument', { source: `
    (${installGalleryFixture.toString()})();
    const previous=window.fetch;
    window.fetch=async(input,options)=>{
      const url=new URL(String(input),location.origin);
      if(url.pathname!=='/api/sessions')return previous(input,options);
      const row={name:'focus-history',title:'Focus history',updatedMs:100,size:100,model:null,provider:null};
      return new Response(JSON.stringify(url.searchParams.has('name')?{...row,messages:[]}:{sessions:[row],total:1,nextCursor:null}),{headers:{'content-type':'application/json'}});
    };
  ` });
  try {
    await wc.loadURL(origin); testDesktop.present(win);
    await wait(`!!document.querySelector('[data-workspace-ready="true"] textarea[aria-label="Prompt"]')`);
    const first = await active();
    await click(`${sidebar} button[aria-label="Home"]`); await focused(first);
    await click(`${sidebar} button[aria-label="Home"]`); await focused(first);
    await click(`${sidebar} button[aria-label="Projects"]`);
    await click(`${sidebar} button[aria-label="Home"]`); await focused(first);
    for (const keyCode of 'return draft') await testDesktop.testInput(wc, { type: 'char', keyCode });
    await click(`${sidebar} button[aria-label="New chat"]`);
    const second = await active(); assert.notEqual(second, first); await focused(second);
    await click('[aria-label="Collapse sidebar"]');
    await wait(`!!document.querySelector('[data-session-navigation="tabs"]')`);
    await click('[data-workspace-toolbar] button[aria-label="New chat"]');
    const third = await active(); assert.notEqual(third, second); await focused(third);
    await click(tab(first)); await focused(first);
    assert.deepEqual(await js(`(()=>{const prompt=document.querySelector('[data-chat="${first}"] textarea[aria-label="Prompt"]');return {value:prompt.value,start:prompt.selectionStart,end:prompt.selectionEnd};})()`),
      { value: 'return draft', start: 12, end: 12 }, 'Returning to a chat restores its draft with the caret at the end');
    await click(tab(first)); await focused(first);

    await click('[aria-label="Expand sidebar"]');
    await wait(`!!document.querySelector('[data-session-navigation="sidebar"]')`);
    // A saved conversation moves into the open-chat list once selected.
    await click(`${sidebar} button[title^="Focus history"]`);
    await wait(`!!document.querySelector('[data-continue-snapshot]') || document.querySelectorAll('[data-tab-id]').length===4`);
    if (await js(`!!document.querySelector('[data-continue-snapshot]')`)) await click('[data-continue-snapshot]');
    const saved = await active();
    await click(tab(first));
    await click(tab(saved)); await focused(saved);
    await click(tab(saved)); await focused(saved);

    wc.send('desktop-action', 'split-right');
    await wait(`document.querySelectorAll('[data-chat]').length===2`);
    const right = await active(); await focused(right);
    const order = await js(`Array.from(document.querySelectorAll('[data-chat]'),e=>e.dataset.chat)`);
    await click(`[data-chat="${saved}"] textarea[aria-label="Prompt"]`);
    for (const keyCode of 'left draft') await testDesktop.testInput(wc, { type: 'char', keyCode });
    await focused(saved);
    await click(`[data-chat="${right}"] textarea[aria-label="Prompt"]`);
    for (const keyCode of 'right draft') await testDesktop.testInput(wc, { type: 'char', keyCode });
    await focused(right);
    await click(`${sidebar} button[aria-label="Home"]`); await focused(right);
    assert.deepEqual(await js(`Array.from(document.querySelectorAll('[data-chat]'),e=>e.dataset.chat)`), order, 'Focus must not reorder split panes');
    assert.equal(await js(`document.querySelector('[data-chat="${saved}"] textarea').value`), 'left draft');
    assert.equal(await js(`document.querySelector('[data-chat="${right}"] textarea').value`), 'right draft');
    // Ordinary pane activation must leave a clicked non-composer control alone.
    await click(`[data-chat="${saved}"] button[title="Focus this chat"]`);
    assert.equal(await active(), saved);
    assert.equal(await js(`document.activeElement.matches('button[title="Focus this chat"]')`), true);
    await pause();
    assert.equal(await js(`document.activeElement.matches('button[title="Focus this chat"]')`), true, 'No delayed focus retry');
    console.log('Navigation prompt focus passed: real New chat/Home/session clicks, repeated navigation, split targeting, drafts and non-composer focus.');
  } finally {
    await wc.debugger.sendCommand('Page.removeScriptToEvaluateOnNewDocument', { identifier });
    await wc.loadURL(origin);
  }
}
module.exports = { runNavigationPromptFocus };
