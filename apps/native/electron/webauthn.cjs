const fs = require('node:fs');
const path = require('node:path');

function configureWebAuthn(app, resources, platform = process.platform) {
  if (platform !== 'darwin' || !app.isPackaged || typeof app.configureWebAuthn !== 'function') return false;
  try {
    const { keychainAccessGroup } = JSON.parse(fs.readFileSync(path.join(resources, 'webauthn.json'), 'utf8'));
    if (typeof keychainAccessGroup !== 'string' || !/^[A-Z0-9]{10}\.[A-Za-z0-9.-]+\.webauthn$/.test(keychainAccessGroup)) return false;
    app.configureWebAuthn({ touchID: { keychainAccessGroup, promptReason: 'sign in to $1' } });
    return true;
  } catch { return false; } // Development/unsigned bundles have no platform credentials.
}

const clean = text => String(text || '').replace(/[\p{Cc}\p{Cf}]/gu, '').slice(0, 160);

function installAccountSelection(session, { dialog, ownerForFrame }) {
  session.on('select-webauthn-account', (_event, details, callback) => {
    void (async () => {
      let selected, owner, cancel;
      const controller = new AbortController();
      try {
        owner = ownerForFrame(details.frame);
        if (!owner || owner.window.isDestroyed() || owner.contents.isDestroyed()) return;
        const accounts = details.accounts;
        if (!Array.isArray(accounts) || !accounts.length) return;
        cancel = () => controller.abort();
        owner.contents.on('did-start-navigation', cancel);
        owner.contents.on('destroyed', cancel);
        owner.contents.on('graff-webauthn-cancel', cancel);
        owner.window.on('closed', cancel);
        const { response } = await dialog.showMessageBox(owner.window, {
          type: 'question', title: 'Choose a passkey',
          message: `Sign in to ${clean(details.relyingPartyId)}`,
          detail: 'Choose the account to share with this site. Cancel to use another sign-in method.',
          buttons: ['Cancel', ...accounts.map((account, i) => `${i + 1}. ${clean(account.displayName || account.name) || 'Account'}${account.displayName && account.name ? ` (${clean(account.name)})` : ''}`)],
          defaultId: 0, cancelId: 0, noLink: true, signal: controller.signal,
        });
        if (!controller.signal.aborted && ownerForFrame(details.frame)?.contents === owner.contents &&
            Number.isInteger(response) && response > 0 && response <= accounts.length) selected = accounts[response - 1].credentialId;
      } catch { /* Fail closed, including a dismissed or unavailable native dialog. */ }
      finally {
        if (cancel) {
          owner.contents.removeListener('did-start-navigation', cancel);
          owner.contents.removeListener('destroyed', cancel);
          owner.contents.removeListener('graff-webauthn-cancel', cancel);
          owner.window.removeListener('closed', cancel);
        }
        callback(selected);
      }
    })();
  });
}

async function showPasskeyHelp({ window, browser, dialog, shell, configured }) {
  const contents = browser.tabs.get(browser.visible)?.view?.webContents;
  let url;
  try {
    const candidate = new URL(contents?.getURL());
    if (['http:', 'https:'].includes(candidate.protocol) && !candidate.username && !candidate.password) url = candidate.href;
  } catch { /* No active web page. */ }
  const { response } = await dialog.showMessageBox(window, {
    type: 'info', title: 'Browser passkeys', message: 'Having trouble signing in with a passkey?',
    detail: `${configured ? 'This signed app is configured for device-bound Touch ID passkeys on supported Macs.' : 'Touch ID passkeys are unavailable in this build.'} Existing iCloud Keychain passkeys are not available here. Use the site’s password or another sign-in method, or open the page in your default browser. Signing in there does not sign you in here.`,
    buttons: url ? ['Close', 'Open page in default browser'] : ['Close'], defaultId: 0, cancelId: 0, noLink: true,
  });
  if (response === 1 && url && !window.isDestroyed()) await shell.openExternal(url);
}

module.exports = { configureWebAuthn, installAccountSelection, showPasskeyHelp };
