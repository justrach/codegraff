const { execFileSync } = require('node:child_process');
const { createRequire } = require('node:module');
const plist = createRequire(require.resolve('@electron/osx-sign'))('plist');

function readProfile(file) {
  if (!file) throw Error('Set GRAFF_WEBAUTHN_PROFILE to a macOS provisioning profile authorizing the app and keychain group.');
  return plist.parse(execFileSync('/usr/bin/security', ['cms', '-D', '-i', file],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
}

function allows(pattern, value) {
  return typeof pattern === 'string' && (pattern === value ||
    (pattern.endsWith('*') && !pattern.slice(0, -1).includes('*') && value.startsWith(pattern.slice(0, -1))));
}

function profileEntitlements(profile, config, now = Date.now()) {
  const group = config.keychainAccessGroup;
  const team = group.slice(0, group.indexOf('.'));
  const appId = group.slice(0, -'.webauthn'.length);
  const entitlements = profile?.Entitlements;
  if (!profile?.Platform?.includes('OSX') || !profile.TeamIdentifier?.includes(team) ||
      !(new Date(profile.ExpirationDate).getTime() > now) ||
      !allows(entitlements?.['com.apple.application-identifier'], appId) ||
      !entitlements?.['keychain-access-groups']?.some(value => allows(value, group))) {
    throw Error('The provisioning profile must be unexpired and authorize this macOS app, signing team, and WebAuthn keychain group.');
  }
  return { 'com.apple.application-identifier': appId };
}

module.exports = { readProfile, profileEntitlements };
