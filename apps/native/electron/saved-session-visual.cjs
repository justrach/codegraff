const testDesktop = require('./test-desktop.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { installGalleryFixture } = require('./gallery-fixture.cjs');

// Exercise the real conversation picker, decoder, transcript and composer.
// Only transport is synthetic; no provider calls or real session files.
async function runSavedSessionVisuals({ win, origin, output }) {
  const wc = win.webContents, js = async source => {
    try { return await wc.executeJavaScript(source); }
    catch (error) {
      console.error('Saved session expression:', source);
      fs.writeFileSync(path.join(output, 'saved-session-failed.png'), (await wc.capturePage()).toPNG());
      throw error;
    }
  };
  const wait = async source => {
    for (let i = 0; i < 150; i++) {
      if (await js(source)) return;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    fs.writeFileSync(path.join(output, 'saved-session-failed.png'), (await wc.capturePage()).toPNG());
    throw Error(`Saved session timeout: ${source}`);
  };
  await wc.loadURL('about:blank');
  testDesktop.attachTestDebugger(wc);
  await wc.debugger.sendCommand('Page.enable');
  const { identifier } = await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument', { source: `
    (${installGalleryFixture.toString()})();
    const previousFetch = window.fetch;
    window.savedFixture = { completed: false, fail: false, requests: [] };
    const row = name => ({ name, title: name, updatedMs: 100, model: null, provider: null, size: 100 });
    window.fetch = async (input, options) => {
      const url = new URL(String(input), location.origin), fixture = window.savedFixture;
      if (url.pathname === '/api/acp' && options?.body) fixture.requests.push(JSON.parse(options.body));
      if (url.pathname !== '/api/sessions') return previousFetch(input, options);
      const json = value => new Response(JSON.stringify(value), { headers: { 'content-type': 'application/json' } });
      const name = url.searchParams.get('name');
      if (!name) return json({ sessions: [row('active-repl'), row('empty-repl')], total: 2, nextCursor: null });
      if (fixture.fail) return new Response('Snapshot unavailable', { status: 503 });
      return json({ ...row(name), messages: name === 'empty-repl' ? [] : [
        { role: 'user', content: 'Check the files and report the result.' },
        { role: 'assistant', content: 'I am checking the remaining files.', tool_calls: [
          { id: 'check', function: { name: 'bash', arguments: '{"command":"check-files"}' } }
        ] },
        ...(fixture.completed ? [{ role: 'tool', tool_call_id: 'check', content: 'Checks passed.' },
          { role: 'assistant', content: 'All files checked.' }] : [])
      ] });
    };
  ` });
  try {
    await wc.loadURL(origin);
    await wait(`!!document.querySelector('[aria-label="Conversations"]')`);
    await js(`document.querySelector('[aria-label="Conversations"]').click()`);
    await wait(`document.querySelector('[data-conversation-library]')?.textContent.includes('active-repl')`);
    await js(`Array.from(document.querySelectorAll('[data-conversation-library] li button')).find(e=>e.textContent.includes('active-repl')).click()`);
    await wait(`document.body.textContent.includes('I am checking the remaining files.')`);
    await wait(`!!document.querySelector('[data-saved-snapshot]')`);
    assert.match(await js(`document.querySelector('[data-saved-snapshot]').textContent`), /Live status unknown/);
    assert.equal(await js(`document.querySelector('[data-chat] textarea[aria-label="Prompt"]')`), null, 'Snapshot cannot accept follow-ups');
    assert.equal(await js(`document.querySelector('article')?.dataset.turnStatus`), 'snapshot', 'Intermediate prose is not a completed turn');
    assert.equal(await js(`document.querySelector('[data-turn-activity]')?.textContent.includes('Turn finished')`), false);
    const resumed = () => js(`window.savedFixture.requests.filter(r=>r.method==='bootstrap'&&r.params?.resume==='active-repl').length`);
    assert.equal(await resumed(), 0, 'Opening shared history must not resume its writer');
    assert.equal(await js(`window.savedFixture.requests.some(r=>r.method==='session/prompt')`), false);
    await js(`window.savedFixture.fail=true;document.querySelector('[data-saved-snapshot] [data-refresh-snapshot]').click()`);
    await wait(`!!document.querySelector('[data-saved-snapshot] [role="alert"]')`);
    assert.ok(await js(`document.body.textContent.includes('I am checking the remaining files.')`), 'Refresh failure preserves history');
    await js(`window.savedFixture.fail=false;window.savedFixture.completed=true;document.querySelector('[data-refresh-snapshot]').click()`);
    await wait(`document.body.textContent.includes('All files checked.')`);
    assert.match(await js(`document.querySelector('[data-saved-snapshot]').textContent`), /Live status unknown/, 'Successful refresh is still a snapshot');
    assert.equal(await resumed(), 0);
    await js('document.fonts.ready.then(()=>true)');
    await js(`Promise.all(document.getAnimations().filter(a=>a.effect?.getTiming().iterations!==Infinity).map(a=>a.finished.catch(()=>{}))).then(()=>true)`);
    assert.equal(await js(`getComputedStyle(document.querySelector('article')).opacity`), '1');
    fs.writeFileSync(path.join(output, 'saved-session-snapshot.png'), (await wc.capturePage()).toPNG());
    await js(`document.querySelector('[data-continue-snapshot]').click()`);
    await wait(`!!document.querySelector('[data-chat] textarea[aria-label="Prompt"]')`);
    assert.equal(await resumed(), 0, 'Explicit continuation enables the composer; spawning waits for a prompt');
    await js(`(()=>{const e=document.querySelector('[data-chat] textarea[aria-label="Prompt"]');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,'Continue the review.');e.dispatchEvent(new Event('input',{bubbles:true}));})()`);
    await js(`document.querySelector('[data-chat] textarea').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}))`);
    await wait(`window.savedFixture.requests.some(r=>r.method==='session/prompt')`);
    assert.equal(await resumed(), 1);
    await wait(`!!document.querySelector('[data-turn-activity="done"]')`);
    await js(`document.querySelector('[aria-label="Conversations"]').click()`);
    await wait(`document.querySelector('[data-conversation-library]')?.textContent.includes('empty-repl')`);
    await js(`Array.from(document.querySelectorAll('[data-conversation-library] li button')).find(e=>e.textContent.includes('empty-repl')).click()`);
    await wait(`!!document.querySelector('[data-saved-snapshot]')`);
    assert.equal(await js(`document.querySelector('[data-chat] textarea')`), null, 'Empty saved sessions also require explicit continuation');
    console.log('Saved session GUI checks passed: intermediate commentary, read-only ownership, failed/completed refresh, explicit continuation, empty history.');
  } finally {
    await wc.debugger.sendCommand('Page.removeScriptToEvaluateOnNewDocument', { identifier });
    wc.debugger.detach();
  }
}
module.exports = { runSavedSessionVisuals };
