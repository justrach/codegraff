// Real Chromium -> session -> BrowserTabs -> native-dialog adapter regression (#900).
// Reference: Electron v44.2.0 webauthn-select-account-listener-throws fixture.
// This entrypoint is deliberately hidden even if the caller opted into GUI tests.
process.env.GRAFF_ELECTRON_FOREGROUND = '0';
process.env.GRAFF_TEST_FOREGROUND = '0';
process.env.GRAFF_ELECTRON_VISIBLE = '0';
const desktop = require('./test-desktop.cjs');
const { app, dialog, webContents } = require('electron');
const assert = require('node:assert/strict');
const path = require('node:path');
const http = require('node:http');
const { BrowserTabs } = require('./browser-tabs.cjs');
const temp = process.argv[2];
if (!temp) throw Error('Run through scripts/test-webauthn.mjs to isolate and clean up the browser profile.');
app.setPath('userData', path.join(temp, 'profile'));
app.commandLine.appendSwitch('disable-background-networking');
let browser, win, server, wc, lastAccounts, dialogCalls = 0, events = 0;
let respond = () => ({ response: 1 });
const originalDialog = dialog.showMessageBox;
// Replace the native boundary before any WebAuthn operation; never open a dialog.
dialog.showMessageBox = async (owner, options) => {
  dialogCalls++;
  assert.equal(owner, win);
  assert.equal(options.title, 'Choose a passkey');
  assert.equal(options.cancelId, 0);
  assert.equal(options.buttons.length, lastAccounts.length + 1);
  desktop.assertSafe();
  return respond(options);
};
let finished = false;
const deadline = setTimeout(() => finish(Error('WebAuthn integration exceeded 45 seconds')), 45000);
function finish(error) {
  if (finished) return;
  finished = true;
  clearTimeout(deadline);
  try { browser?.closeAll(); desktop.assertSafe(); desktop.cleanup(); } catch (e) { error ||= e; }
  dialog.showMessageBox = originalDialog;
  server?.close();
  if (error) console.error(error);
  app.exit(error ? 1 : 0);
}
const get = () => wc.executeJavaScript(`navigator.credentials.get({publicKey:{
  challenge:crypto.getRandomValues(new Uint8Array(32)),rpId:'localhost',userVerification:'required',timeout:10000
}}).then(c=>({ok:true,id:c.id,userHandle:Array.from(new Uint8Array(c.response.userHandle))}),e=>({ok:false,name:e.name}))`);
app.whenReady().then(async () => {
  win = desktop.createWindow({ width: 800, height: 600, webPreferences: { sandbox: true } });
  assert.equal(win.isFocusable(), false);
  server = http.createServer((_req, res) => {
    res.setHeader('Content-Type', 'text/html');
    res.end('<!doctype html><title>Offline passkey fixture</title>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://localhost:${server.address().port}`;
  browser = new BrowserTabs(win, () => {});
  browser.session.webRequest.onBeforeRequest((details, callback) => {
    callback({ cancel: !details.url.startsWith(`${origin}/`) });
  });
  // Observe, but do not invoke or replace, the real production listener/callback.
  browser.session.prependListener('select-webauthn-account', (_event, details) => {
    events++;
    assert.equal(details.relyingPartyId, 'localhost');
    assert.equal(webContents.fromFrame(details.frame), wc);
    lastAccounts = details.accounts;
  });
  browser.setBounds('passkeys', { x: 0, y: 0, width: 800, height: 600 });
  await browser.navigate('passkeys', `${origin}/`);
  wc = browser.tabs.get('passkeys').view.webContents;
  await desktop.focusTestPage(wc);
  await wc.debugger.sendCommand('WebAuthn.enable');
  const { authenticatorId } = await wc.debugger.sendCommand('WebAuthn.addVirtualAuthenticator', {
    options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true,
      hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true },
  });
  const ids = [];
  for (const [index, name] of ['alice', 'bob'].entries()) {
    const created = await wc.executeJavaScript(`navigator.credentials.create({publicKey:{
      challenge:crypto.getRandomValues(new Uint8Array(32)),rp:{id:'localhost',name:'Offline fixture'},
      user:{id:new Uint8Array([${index + 1}]),name:'${name}',displayName:'${name}'},
      pubKeyCredParams:[{type:'public-key',alg:-7}],
      authenticatorSelection:{residentKey:'required',userVerification:'required'},timeout:10000
    }}).then(c=>({ok:true,id:c.id}),e=>({ok:false,name:e.name}))`);
    assert.equal(created.ok, true, JSON.stringify(created));
    ids.push(created.id);
    if (index === 0) {
      const first = await get();
      assert.equal(first.ok, true, JSON.stringify(first));
      assert.equal(first.id, ids[0]);
      assert.deepEqual(first.userHandle, [1]);
    }
  }
  const stored = await wc.debugger.sendCommand('WebAuthn.getCredentials', { authenticatorId });
  assert.equal(stored.credentials.length, 2);
  assert.ok(stored.credentials.every(c => c.isResidentCredential));
  const before = dialogCalls;
  respond = () => ({ response: 2 });
  const selected = await get();
  assert.equal(dialogCalls, before + 1, 'Must dispatch through BrowserTabs account chooser');
  assert.equal(lastAccounts.length, 2);
  assert.equal(selected.ok, true, JSON.stringify(selected));
  const selectedId = lastAccounts[1].credentialId;
  assert.equal(selected.id, selectedId, 'Second dialog account must be the returned credential');
  assert.ok(ids.includes(selected.id));
  respond = () => ({ response: 0 });
  assert.deepEqual(await get(), { ok: false, name: 'NotAllowedError' });
  assert.equal(dialogCalls, before + 2);
  // Real tab visibility gate: no adapter call is allowed for a hidden tab's frame.
  browser.hide('passkeys');
  assert.deepEqual(await get(), { ok: false, name: 'NotAllowedError' });
  assert.equal(dialogCalls, before + 2);
  browser.attach(browser.tabs.get('passkeys'));
  // Same-document navigation keeps the JS promise alive while exercising the
  // production did-start-navigation abort listener and stale-choice rejection.
  let opened;
  const opening = new Promise(resolve => { opened = resolve; });
  respond = options => new Promise(resolve => {
    options.signal.addEventListener('abort', () => resolve({ response: 2 }), { once: true });
    opened();
  });
  const pending = get();
  await opening;
  await wc.executeJavaScript("location.hash = 'dismiss'; void 0");
  assert.deepEqual(await pending, { ok: false, name: 'NotAllowedError' });
  assert.equal(dialogCalls, before + 3);
  await wc.debugger.sendCommand('WebAuthn.removeVirtualAuthenticator', { authenticatorId });
  console.log('PASS WebAuthn integration', JSON.stringify({ electron: process.versions.electron,
    residentCredentials: stored.credentials.length, events, dialogCalls,
    checks: ['create', 'single-account get', 'second-account selection', 'cancel', 'hidden-tab rejection', 'navigation cancellation'],
    desktop: desktop.assertSafe() }));
}).then(() => finish()).catch(finish);
