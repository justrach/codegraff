const testDesktop = require('./test-desktop.cjs');
const { BrowserWindow, ipcMain } = require('electron');
const { BrowserTabs } = require('./browser-tabs.cjs');
const { installExternalLinks } = require('./external-links.cjs');
const { installGalleryFixture } = require('./gallery-fixture.cjs');
const { linkSettings } = require('./link-settings.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function runLinkDestinationVisuals({ origin, output }) {
  fs.mkdirSync(output, { recursive: true });
  const directory = fs.mkdtempSync(path.join(output, 'link-settings-'));
  let store = linkSettings(directory);
  const fixture = http.createServer((_req, res) => {
    res.setHeader('content-type', 'text/html');
    res.end('<!doctype html><title>Link destination fixture</title><h1>Local browser destination</h1>');
  });
  await new Promise(resolve => fixture.listen(0, '127.0.0.1', resolve));
  const destination = `http://127.0.0.1:${fixture.address().port}`;
  const win = testDesktop.createWindow({ width: 1440, height: 900, webPreferences: {
    preload: path.join(__dirname, 'preload.cjs'), partition: `link-destination-${path.basename(directory)}`,
    sandbox: true, contextIsolation: true, nodeIntegration: false, backgroundThrottling: false,
  } });
  const wc = win.webContents, js = async code => {
    try { return await wc.executeJavaScript(code); }
    catch (error) { console.error('Link fixture expression:', code); throw error; }
  };
  wc.on('console-message', event => { if (event.level >= 2) console.error('Link renderer:', event.message); });
  const browser = new BrowserTabs(win, event => wc.send('browser-event', event));
  const system = [], routed = [], settings = [], blocked = [], errors = [];
  let delayNextOpen = false, delayedReplySent = false;
  // Neither session may reach the network or an engine endpoint. Only the app's
  // static assets and our loopback HTML fixture are allowed through.
  const guard = allowed => (details, callback) => {
    const url = new URL(details.url);
    const deny = !['about:', 'data:'].includes(url.protocol) && (url.origin !== allowed || url.pathname.startsWith('/api/'));
    if (deny) blocked.push(details.url);
    callback({ cancel: deny });
  };
  wc.session.webRequest.onBeforeRequest(guard(new URL(origin).origin));
  browser.session.webRequest.onBeforeRequest(guard(destination));
  ipcMain.handle('link-settings', async (_event, action, value) => {
    assert.ok(['load', 'save'].includes(action));
    const result = await (action === 'save' ? store.save(value) : store.load());
    settings.push({ action, value, result }); return result;
  });
  ipcMain.handle('browser', async (_event, { chat, method, params }) => {
    try {
      const delayed = delayNextOpen && method === 'open';
      if (delayed) delayNextOpen = false;
      const result = await browser.command(chat, method, params);
      if (delayed) {
        // An IPC reply captured during navigation can arrive after newer events.
        await wait(`document.querySelector('input[aria-label="Address"]')?.closest('aside').querySelector('header')?.textContent.includes('Link destination fixture')`);
        delayedReplySent = true;
        return { ...result, ready: 'loading', title: 'Earlier loading snapshot' };
      }
      return result;
    }
    catch (error) { errors.push(error.message); throw error; }
  });
  const overlay = (event, value) => { if (event.sender === wc) browser.setOverlay(value); };
  ipcMain.on('browser-overlay', overlay);
  installExternalLinks(wc, new URL(origin).origin, async url => {
    const choice = await store.load(); routed.push({ choice, url });
    if (choice === 'graff') wc.send('browser-event', { type: 'open-link', url });
    else system.push(url); // Deliberately never use shell.openExternal.
  });
  const wait = async (test, label) => {
    for (let i = 0; i < 150; i++) { if (await (typeof test === 'string' ? js(test) : test())) return; await sleep(50); }
    throw Error(`Link destination timeout: ${label || test}`);
  };
  const click = selector => js(`document.querySelector(${JSON.stringify(selector)}).click()`);
  const dialog = '[role="dialog"][aria-label="Settings"]';
  const labels = { system: 'System default browser', graff: 'Graff built-in Browser' };
  const option = choice => `Array.from(document.querySelectorAll('${dialog} button')).find(b=>b.textContent.trim()===${JSON.stringify(labels[choice])})`;
  const selected = async choice => {
    await wait(`${option(choice)}?.getAttribute('aria-pressed')==='true'`);
    assert.equal(await js(`${option(choice === 'system' ? 'graff' : 'system')}?.getAttribute('aria-pressed')`), 'false');
  };
  const openSettings = async () => {
    await wait(`!!document.querySelector('[aria-label="Settings"]')`, 'Settings hydrated');
    await click('[aria-label="Settings"]'); await wait(`!!document.querySelector('${dialog}')`);
    await wait(() => browser.overlay === true, 'settings hide the native browser view');
  };
  const closeSettings = async () => { await click('[aria-label="Close settings"]'); await wait(`!document.querySelector('${dialog}')`); await wait(() => browser.overlay === false, 'closing settings releases the overlay'); };
  const choose = async choice => {
    const before = settings.filter(s => s.action === 'save').length;
    await wait(`${option(choice)} && !${option(choice)}.matches(':disabled')`, 'preference loaded and ready to change');
    await js(`${option(choice)}.click()`); await selected(choice);
    await wait(() => settings.filter(s => s.action === 'save').length > before, 'setting saved through real preload');
    assert.equal(await store.load(), choice);
    assert.equal(await linkSettings(directory).load(), choice, 'a fresh store reads the UI selection');
  };
  // These anchors live inside the real conversation pane, not a test-only route.
  // Injection also permits unsafe schemes that the markdown sanitizer removes.
  const link = async (url, target = '', pane = '[data-chat][data-focused="true"]') => {
    await js(`(()=>{const p=document.querySelector(${JSON.stringify(pane)}) || document.querySelector('[data-chat]');p.querySelector('[data-link-fixture]')?.remove();const a=document.createElement('a');a.dataset.linkFixture='';a.href=${JSON.stringify(url)};a.target=${JSON.stringify(target)};a.textContent='Conversation destination';p.append(a);a.click();})()`);
  };
  const screenshot = async name => {
    await js('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve(true))))');
    await sleep(100); // Allow Chromium to present the hydrated frame before capture.
    fs.writeFileSync(path.join(output, name), (await wc.capturePage()).toPNG());
  };
  const closeBrowser = async () => {
    if (await js(`!!document.querySelector('[aria-label="Close browser"]')`)) await click('[aria-label="Close browser"]');
    await wait(`!document.querySelector('[aria-label="Close browser"]')`);
    await wait(() => browser.visible === null, 'browser closed');
  };
  const route = async (choice, target, suffix) => {
    const url = `${destination}/${suffix}`, before = routed.length, opened = system.length, appURL = wc.getURL();
    await link(url, target);
    await wait(() => routed.length === before + 1, 'conversation link intercepted exactly once');
    assert.deepEqual(routed[before], { choice, url });
    if (choice === 'system') {
      await wait(() => system.length === opened + 1, 'fake system opener');
      assert.equal(system.at(-1), url);
      assert.equal(browser.liveCount, 0, 'system links do not create a browser page');
      assert.equal(await js(`!!document.querySelector('[aria-label="Close browser"]')`), false);
    } else {
      await wait(`!!document.querySelector('[aria-label="Close browser"]')`);
      await wait(() => { const tab = browser.tabs.get(browser.visible); return tab?.view?.webContents.getURL() === url && !tab.view.webContents.isLoading(); }, 'real BrowserTabs navigation');
      const page = browser.tabs.get(browser.visible).view.webContents;
      assert.equal(await page.executeJavaScript('document.querySelector("h1").textContent'), 'Local browser destination');
      await wait(() => browser.tabs.get(browser.visible)?.view?.getVisible(), 'native browser revealed');
      assert.equal(system.length, opened, 'Graff never invokes even the fake system opener');
    }
    assert.equal(wc.getURL(), appURL, 'external links preserve the main app URL');
    assert.ok(await js(`!!document.querySelector('textarea[aria-label="Prompt"]')`), 'conversation survives routing');
  };
  try {
    await wc.loadURL('about:blank'); wc.debugger.attach('1.3'); await wc.debugger.sendCommand('Page.enable');
    await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument', { source: `(${installGalleryFixture.toString()})();` });
    await wc.loadURL(origin); testDesktop.present(win); await wait(`!!document.querySelector('textarea[aria-label="Prompt"]')`);
    assert.equal(await js(`typeof window.graffDesktop.linkSettings`), 'function', 'real preload exposes linkSettings');
    await openSettings(); await selected('system');
    assert.equal(await store.load(), 'system');
    await screenshot('link-destination-default.png');
    await closeSettings();
    await route('system', '', 'default-normal'); await route('system', '_blank', 'default-blank');
    await openSettings(); await choose('graff'); await closeSettings();
    await route('graff', '', 'graff-normal');
    await openSettings();
    assert.equal(browser.tabs.get(browser.visible).view.getVisible(), false, 'Settings covers the native page');
    await selected('graff'); await closeSettings();
    await closeBrowser(); await route('graff', '_blank', 'graff-blank');
    await screenshot('link-destination-graff.png');
    await closeBrowser();
    await new Promise(resolve => { wc.once('did-finish-load', resolve); wc.reload(); });
    await wait(`!!document.querySelector('textarea[aria-label="Prompt"]')`);
    await openSettings(); await selected('graff'); await closeSettings();
    store = linkSettings(directory);
    await new Promise(resolve => { wc.once('did-finish-load', resolve); wc.reload(); });
    await wait(`!!document.querySelector('textarea[aria-label="Prompt"]')`);
    await openSettings(); await selected('graff'); await closeSettings();
    await route('graff', '', 'persisted'); await closeBrowser();
    await openSettings(); await choose('system'); await closeSettings();
    await route('system', '', 'switched-normal'); await route('system', '_blank', 'switched-blank');
    await openSettings(); await choose('graff'); await closeSettings();
    await route('graff', '_blank', 'switched-back'); await closeBrowser();

    for (const choice of ['system', 'graff']) {
      if (await store.load() !== choice) { await openSettings(); await choose(choice); await closeSettings(); }
      const before = routed.length, appURL = wc.getURL();
      for (const url of ['file:///graff-link-fixture-denied', 'data:text/html,denied', `http://user:password@127.0.0.1:${fixture.address().port}/denied`]) {
        for (const target of ['', '_blank']) await link(url, target);
      }
      await sleep(300);
      assert.equal(routed.length, before, `${choice}: unsafe and credential-bearing links never reach either opener`);
      assert.equal(browser.liveCount, 0); assert.equal(wc.getURL(), appURL);
    }
    // Split focus must choose a different real browser tab without moving panes.
    await js(`document.querySelector('textarea').focus();document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'d',metaKey:true,bubbles:true,cancelable:true}))`);
    await wait(`document.querySelectorAll('[data-chat]').length===2`);
    const panes = await js(`Array.from(document.querySelectorAll('[data-chat]')).map(p=>p.dataset.chat)`);
    const handles = [];
    for (const id of panes) {
      const selector = `[data-chat="${id}"] textarea`;
      const point = await js(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()`);
      await testDesktop.testInput(wc, { type: 'mouseDown', button: 'left', clickCount: 1, ...point });
      await testDesktop.testInput(wc, { type: 'mouseUp', button: 'left', clickCount: 1, ...point });
      await wait(`document.querySelector('[data-chat][data-focused="true"]')?.dataset.chat===${JSON.stringify(id)}`);
      await route('graff', '', `split-${id}`); handles.push(browser.visible);
      assert.equal(await js(`document.querySelector('[data-chat][data-focused="true"]').dataset.chat`), id);
      await closeBrowser();
    }
    assert.notEqual(handles[0], handles[1], 'focused split chats own distinct browser tabs');
    assert.deepEqual(await js(`Array.from(document.querySelectorAll('[data-chat]')).map(p=>p.dataset.chat)`), panes);
    const before = routed.length;
    await link(`${origin}/#link-destination-local`);
    await wait(() => wc.getURL() === `${origin}/#link-destination-local`, 'same-origin anchor retains native navigation');
    assert.equal(routed.length, before, 'same-origin links bypass external routing');
    assert.ok(await js(`!!document.querySelector('textarea[aria-label="Prompt"]')`));
    assert.deepEqual(errors, [], 'browser IPC completes without errors');
    await require('./browser-address-visual.cjs').runBrowserAddress({ wc, browser, destination, guard, wait, delayOpenReply: () => { delayNextOpen = true; }, openReplySent: () => delayedReplySent });
    assert.deepEqual(blocked, [], 'no external network or engine/model requests attempted');
    console.log('Link destination visuals passed: default/save/switch, reload and fresh-store persistence, normal/blank links, closed-browser reveal, overlays, unsafe/same-origin links, split focus and preserved app.');
  } finally {
    ipcMain.removeHandler('link-settings'); ipcMain.removeHandler('browser'); ipcMain.removeListener('browser-overlay', overlay);
    browser.closeAll(); win.destroy(); browser.session.webRequest.onBeforeRequest(null);
    await new Promise(resolve => fixture.close(resolve));
    fs.rmSync(directory, { recursive: true, force: true });
  }
}
module.exports = { runLinkDestinationVisuals };
