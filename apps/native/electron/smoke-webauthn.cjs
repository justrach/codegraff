// Checks the production startup configuration; does not simulate biometric consent.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function run({ browser, backend, resources }) {
  const config = JSON.parse(fs.readFileSync(path.join(resources, 'webauthn.json'), 'utf8'));
  assert.match(config.keychainAccessGroup, /^[A-Z0-9]{10}\.[A-Za-z0-9.-]+\.webauthn$/);
  const chat = 'webauthn-packaging-check';
  try {
    await browser.navigate(chat, backend.origin);
    const available = await browser.tabs.get(chat).view.webContents.executeJavaScript(
      'PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()');
    assert.equal(available, true, 'Signed startup must expose the platform authenticator on supported hardware');
    assert.equal(browser.session.listenerCount('select-webauthn-account'), 1);
    return 'signed platform authenticator availability (no biometric ceremony)';
  } finally { browser.close(chat); }
}
module.exports = { run };
