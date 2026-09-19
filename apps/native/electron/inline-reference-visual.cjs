const assert = require('node:assert/strict');
const desktop = require('./test-desktop.cjs');

/** Real Markdown click → reference dispatch → visible native BrowserTabs page.
 * The API reply uses a loopback destination; server Git resolution is tested separately. */
async function inlineReferenceVisual({ wc, js, wait, browser, destination, closeBrowser, screenshot }) {
  await closeBrowser();
  await js(`(() => {
    const previous = window.fetch;
    window.referenceRequests = [];
    window.fetch = async (input, options) => {
      const url = new URL(typeof input === 'string' ? input : input.url, location.origin);
      if (url.pathname === '/api/inline-reference') {
        window.referenceRequests.push(Object.fromEntries(url.searchParams));
        return new Response(JSON.stringify({kind:'browser',url:${JSON.stringify(destination + '/branch')}}), {headers:{'content-type':'application/json'}});
      }
      if (url.pathname === '/api/acp' && options?.body && JSON.parse(options.body).method === 'session/prompt') {
        const rows = [
          {jsonrpc:'2.0',method:'session/update',params:{sessionId:'demo',update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'The branch is ' + String.fromCharCode(96) + 'release/v1.2.3' + String.fromCharCode(96) + '.'}}}},
          {jsonrpc:'2.0',id:1,result:{stopReason:'end_turn'}}
        ];
        return new Response(rows.map(row=>JSON.stringify(row)).join('\\n')+'\\n', {headers:{'content-type':'application/x-ndjson'}});
      }
      return previous(input, options);
    };
    window.restoreReferenceFetch = () => { window.fetch = previous; };
    const input = document.querySelector('[data-chat][data-focused="true"] textarea[aria-label="Prompt"]') || document.querySelector('textarea[aria-label="Prompt"]');
    input.focus();
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(input, 'Show the release branch.');
    input.dispatchEvent(new Event('input', {bubbles:true}));
  })()`);
  try {
    await desktop.testInput(wc, { type: 'keyDown', keyCode: 'Enter' });
    await desktop.testInput(wc, { type: 'keyUp', keyCode: 'Enter' });
    await wait(`Array.from(document.querySelectorAll('code')).some(e=>e.textContent==='release/v1.2.3')`, 'branch rendered as inline code');
    await js(`Array.from(document.querySelectorAll('code')).find(e=>e.textContent==='release/v1.2.3').click()`);
    await wait(() => { const tab = browser.tabs.get(browser.visible); return tab?.view?.getVisible() && tab.view.webContents.getURL() === destination + '/branch' && !tab.view.webContents.isLoading(); }, 'inline branch opens visible embedded browser');
    assert.equal(await js(`window.referenceRequests.at(-1).path`), 'release/v1.2.3');
    assert.equal(await js(`document.body.textContent.includes('ENOENT')`), false);
    assert.ok(await js(`!!document.querySelector('input[aria-label="Address"]')`));
    await screenshot('inline-reference-browser.png');
  } finally { await js('window.restoreReferenceFetch()'); }
}
module.exports = { inlineReferenceVisual };
