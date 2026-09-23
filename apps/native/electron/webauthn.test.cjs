const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { configureWebAuthn, installAccountSelection, showPasskeyHelp } = require('./webauthn.cjs');

const group = 'ABCDEFGHIJ.dev.example.app.webauthn';
test('startup configures only supported packaged builds from the signed resource', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'webauthn-config-'));
  try {
    const calls = [], app = { isPackaged: true, configureWebAuthn: options => calls.push(options) };
    assert.equal(configureWebAuthn(app, dir, 'darwin'), false);
    fs.writeFileSync(path.join(dir, 'webauthn.json'), JSON.stringify({ keychainAccessGroup: group }));
    assert.equal(configureWebAuthn(app, dir, 'darwin'), true);
    assert.deepEqual(calls, [{ touchID: { keychainAccessGroup: group, promptReason: 'sign in to $1' } }]);
    for (const platform of ['linux', 'win32']) assert.equal(configureWebAuthn(app, dir, platform), false);
    assert.equal(configureWebAuthn({ ...app, isPackaged: false }, dir, 'darwin'), false);
    assert.equal(configureWebAuthn({ isPackaged: true }, dir, 'darwin'), false);
    assert.equal(configureWebAuthn({ ...app, configureWebAuthn() { throw Error('unavailable'); } }, dir, 'darwin'), false);
    for (const payload of ['{', '{}', 'null', '{"keychainAccessGroup":"invalid"}']) {
      fs.writeFileSync(path.join(dir, 'webauthn.json'), payload);
      assert.equal(configureWebAuthn(app, dir, 'darwin'), false);
    }
    assert.equal(calls.length, 1);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

function fixture(showMessageBox, owns = true) {
  const session = new EventEmitter(), frame = {};
  const contents = Object.assign(new EventEmitter(), { isDestroyed: () => false });
  const window = Object.assign(new EventEmitter(), { isDestroyed: () => false });
  const owner = { contents, window };
  installAccountSelection(session, { dialog: { showMessageBox }, ownerForFrame: f => owns && f === frame ? owner : null });
  const accounts = [{ credentialId: 'alice', displayName: 'Alice', name: 'alice@example.test' }, { credentialId: 'bob', name: 'Bob' }];
  let count = 0;
  const request = (details = {}) => new Promise(resolve => session.emit('select-webauthn-account', {}, {
    frame, relyingPartyId: 'example.test', accounts, ...details,
  }, value => { count++; resolve(value); }));
  return { request, contents, window, get count() { return count; } };
}

test('account selection requires an explicit choice and passes the credential ID', async () => {
  const f = fixture(async (parent, options) => {
    assert.equal(parent, f.window);
    assert.equal(options.message, 'Sign in to example.test');
    assert.deepEqual(options.buttons, ['Cancel', '1. Alice (alice@example.test)', '2. Bob']);
    assert.equal(options.defaultId, 0); assert.equal(options.cancelId, 0);
    return { response: 2 };
  });
  assert.equal(await f.request(), 'bob');
  assert.equal(f.count, 1);
  assert.equal(f.contents.eventNames().length, 0);
  assert.equal(f.window.eventNames().length, 0);
});

test('cancel, invalid choice, empty accounts, foreign frames and dialog failures fail closed', async () => {
  for (const response of [0, -1, 3, 1.5, undefined]) {
    const f = fixture(async () => ({ response }));
    assert.equal(await f.request(), undefined); assert.equal(f.count, 1);
  }
  const f = fixture(async () => { throw Error('dialog failed'); });
  assert.equal(await f.request(), undefined); assert.equal(f.count, 1);
  const foreign = fixture(() => assert.fail('must not prompt'), false);
  assert.equal(await foreign.request(), undefined);
  const empty = fixture(() => assert.fail('must not prompt'));
  assert.equal(await empty.request({ accounts: [] }), undefined);
});

test('navigation, tab hiding, destruction and window closure abort selection once', async () => {
  for (const event of ['did-start-navigation', 'graff-webauthn-cancel', 'destroyed', 'closed']) {
    const f = fixture((_parent, options) => new Promise(resolve => {
      options.signal.addEventListener('abort', () => resolve({ response: 1 }), { once: true });
    }));
    const pending = f.request();
    (event === 'closed' ? f.window : f.contents).emit(event);
    assert.equal(await pending, undefined); assert.equal(f.count, 1);
    assert.equal(f.contents.eventNames().length, 0);
    assert.equal(f.window.eventNames().length, 0);
  }
});

test('fallback explains credential limitations and opens only after explicit consent', async () => {
  const opened = [];
  for (const configured of [true, false]) {
    for (const response of [0, 1]) {
      await showPasskeyHelp({ window: { isDestroyed: () => false }, configured,
        browser: { visible: 'tab', tabs: new Map([['tab', { view: { webContents: { getURL: () => 'https://example.test/login' } } }]]) },
        dialog: { showMessageBox: async (_parent, options) => {
          assert.match(options.detail, /iCloud Keychain passkeys are not available/);
          assert.match(options.detail, /Signing in there does not sign you in here/);
          assert.match(options.detail, configured ? /device-bound/ : /unavailable in this build/);
          return { response };
        } }, shell: { openExternal: async url => opened.push(url) },
      });
    }
  }
  assert.deepEqual(opened, ['https://example.test/login', 'https://example.test/login']);
});

test('fallback rejects non-web URLs and embedded credentials', async () => {
  for (const url of ['file:///tmp/test', 'javascript:alert(1)', 'https://user:secret@example.test', 'about:blank']) {
    await showPasskeyHelp({ window: { isDestroyed: () => false }, configured: false,
      browser: { visible: 'tab', tabs: new Map([['tab', { view: { webContents: { getURL: () => url } } }]]) },
      dialog: { showMessageBox: async (_parent, options) => { assert.deepEqual(options.buttons, ['Close']); return { response: 1 }; } },
      shell: { openExternal: () => assert.fail('must not open') },
    });
  }
});
