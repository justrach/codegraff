const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), http = require('node:http');
const { ipcMain } = require('electron');
const desktop = require('./test-desktop.cjs');
const { BrowserTabs } = require(process.env.GRAFF_BROWSER_SOURCE || './browser-tabs.cjs');
const { startAutomation } = require('./automation.cjs');
const { callTool } = require('./desktop-tools.cjs');
async function runBrowserFocus({ win, output, click, until, report }) {
  const wc = win.webContents, js = code => wc.executeJavaScript(code);
  const focused = () => js(`document.querySelector('[data-chat][data-focused="true"]').dataset.chat`);
  if (await js(`!!document.querySelector('[aria-label="Close browser"]')`)) await click('[aria-label="Close browser"]');
  const fixture = http.createServer((req, res) => {
    if (req.url === '/fail') return res.destroy();
    res.setHeader('content-type', 'text/html');
    res.end(`<title>Preview ${req.url}</title><h1>Preview ${req.url}</h1><button id="popup" onclick="window.open('/popup','_blank')">Open popup</button>`);
  });
  await new Promise(resolve => fixture.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${fixture.address().port}`;
  const events = [], browser = new BrowserTabs(win, event => { events.push(event); wc.send('browser-event', event); });
  const bridge = await startAutomation(browser, null, null);
  ipcMain.removeHandler('browser');
  ipcMain.handle('browser', (_event, { chat, method, params }) => method === 'handle' ? bridge.handle(chat) : browser.command(chat, method, params));
  try {
    const loaded = want => {
      const got = [...browser.tabs.values()].map(tab => tab.view?.webContents.getURL() || tab.url);
      return got.some(href => href === want || href === `${want}/` || href.replace(/\/$/, '') === want.replace(/\/$/, ''));
    };
    const navigateUser = async url => {
      await click('[aria-label="Address"]');
      await until(() => js(`!!document.querySelector('[aria-label="Address"]')`), 'address field present');
      await js(`(()=>{const e=document.querySelector('[aria-label="Address"]');e.focus();Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,${JSON.stringify(url)});e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));})()`);
      await until(() => js(`document.querySelector('[aria-label="Address"]').value===${JSON.stringify(url)}`), 'address value');
      await js('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))');
      if (await js(`!!document.querySelector('[aria-label="Go"]')`)) await click('[aria-label="Go"]');
      else await js(`document.querySelector('[aria-label="Address"]').form.requestSubmit()`);
      await until(() => loaded(url), 'explicit address navigation');
    };
    const openBrowser = async () => {
      await click('[aria-label="Workspace tools"]');
      await click('[aria-label="Browser"]');
    };
    const a = await focused();
    await openBrowser();
    await navigateUser(`${origin}/first`);
    const chatA = browser.visible;
    await js(`Array.from(document.querySelectorAll('button[aria-label="New chat"]')).find(e=>e.checkVisibility()).setAttribute('data-browser-new-chat','true')`);
    await click('[data-browser-new-chat="true"]');
    await until(async () => (await focused()) !== a && browser.visible !== chatA, 'second chat');
    if (!await js(`!!document.querySelector('[aria-label="Address"]')?.checkVisibility()`)) {
      await openBrowser();
    }
    await navigateUser(`${origin}/selected`);
    const b = await focused(), chatB = browser.visible;
    await click('textarea[aria-label="Prompt"]');
    for (const keyCode of 'Keep my draft here') await desktop.testInput(wc, { type: 'char', keyCode });
    const selected = async () => {
      assert.equal(await focused(), b, 'Background browser work must not change the active GUI chat');
      assert.equal(browser.visible, chatB, 'Background navigation must not replace the selected native view');
      assert.equal(await js(`document.activeElement === document.querySelector('[data-chat="${b}"] textarea[aria-label="Prompt"]')`), true, 'Composer focus must remain in the selected chat');
      assert.equal(await js(`document.querySelector('[data-chat="${b}"] textarea').value`), 'Keep my draft here');
      assert.equal(browser.tabs.get(chatB).view.webContents.getURL(), `${origin}/selected`);
    };
    const handle = bridge.handle(chatA);
    const env = { GRAFF_DESKTOP_ENDPOINT: `http://127.0.0.1:${handle.port}`, GRAFF_DESKTOP_SECRET: handle.token, GRAFF_DESKTOP_CHAT: chatA };
    const tool = args => callTool('browser', args, env);
    events.length = 0;
    await tool({ action: 'open', url: `${origin}/background` });
    await selected();
    assert.ok(!events.some(event => event.type === 'show'), 'Agent navigation must not request a GUI reveal');
    assert.match(JSON.stringify(await tool({ action: 'snapshot' })), /Preview \/background/);
    await tool({ action: 'click', selector: '#popup' });
    await until(() => browser.tabs.get(chatA).view.webContents.getURL() === `${origin}/popup`, 'background popup navigation');
    await selected();
    assert.ok(!events.some(event => event.type === 'show'), 'Hidden popups must remain hidden');
    await assert.rejects(browser.navigate(chatA, `${origin}/fail`, { background: true }));
    await selected();
    assert.ok(browser.tabs.get(chatA).timer, 'Failed background navigation still schedules inactive-page cleanup');
    fs.writeFileSync(path.join(output, 'browser-background-keeps-draft.png'), (await wc.capturePage()).toPNG());
    await browser.command(chatA, 'navigate', { url: `${origin}/explicit` });
    await until(async () => (await focused()) === a, 'explicit user browser reveal');
    assert.equal(browser.visible, chatA);
    assert.ok(events.some(event => event.type === 'show' && event.chat === chatA));
    await click(`[data-tab-members="${b}"] button[aria-pressed]`);
    assert.equal(await js(`document.querySelector('[data-chat="${b}"] textarea').value`), 'Keep my draft here');
    report.passed.push('native background browser open, popup and failed navigation preserve selected chat, composer draft and native view; explicit user reveal still works');
  } finally {
    browser.closeAll(); bridge.server.close(); fixture.close();
    ipcMain.removeHandler('browser'); ipcMain.handle('browser', () => null);
  }
}
module.exports = { runBrowserFocus };
