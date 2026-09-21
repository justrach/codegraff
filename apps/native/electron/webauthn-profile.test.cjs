const assert = require('node:assert/strict');
const { test } = require('node:test');
const { readProfile, profileEntitlements } = require('./webauthn-profile.cjs');

const config = { keychainAccessGroup: 'ABCDE12345.org.example.fixture.webauthn' };
const appId = 'ABCDE12345.org.example.fixture';
const now = Date.parse('2030-01-01T00:00:00Z');

function fixture() {
  return {
    Platform: ['OSX'],
    TeamIdentifier: ['ABCDE12345'],
    ExpirationDate: new Date('2099-01-01'),
    Entitlements: {
      'com.apple.application-identifier': appId,
      'keychain-access-groups': ['ABCDE12345.*'],
    },
  };
}

function authorize(profile) {
  return profileEntitlements(profile, config, now);
}

for (const [name, application, groups] of [
  ['fixture team wildcard group', appId, ['ABCDE12345.*']],
  ['exact permissions', appId, [config.keychainAccessGroup]],
  ['trailing wildcard permissions', 'ABCDE12345.org.example.*', ['ABCDE12345.org.example.fixture.*']],
  ['matching group among unrelated groups', appId, ['ABCDE12345.org.example.other', config.keychainAccessGroup]],
]) {
  test(`authorizes ${name} and returns the concrete application identifier`, () => {
    const profile = fixture();
    profile.Entitlements['com.apple.application-identifier'] = application;
    profile.Entitlements['keychain-access-groups'] = groups;
    assert.deepEqual(authorize(profile), { 'com.apple.application-identifier': appId });
  });
}

for (const [name, change] of [
  ['wrong team', p => { p.TeamIdentifier = ['ZZZZZ99999']; }],
  ['missing team', p => { delete p.TeamIdentifier; }],
  ['wrong application', p => { p.Entitlements['com.apple.application-identifier'] = 'ABCDE12345.org.example.other'; }],
  ['application wildcard with wrong prefix', p => { p.Entitlements['com.apple.application-identifier'] = 'ABCDE12345.org.example.other.*'; }],
  ['missing application', p => { delete p.Entitlements['com.apple.application-identifier']; }],
  ['wrong keychain group', p => { p.Entitlements['keychain-access-groups'] = ['ABCDE12345.org.example.other.webauthn']; }],
  ['keychain wildcard with wrong team prefix', p => { p.Entitlements['keychain-access-groups'] = ['ZZZZZ99999.*']; }],
  ['missing keychain groups', p => { delete p.Entitlements['keychain-access-groups']; }],
  ['empty keychain groups', p => { p.Entitlements['keychain-access-groups'] = []; }],
  ['missing entitlements', p => { delete p.Entitlements; }],
  ['non-mac platform', p => { p.Platform = ['iOS']; }],
  ['missing platform', p => { delete p.Platform; }],
  ['expired profile', p => { p.ExpirationDate = new Date(now - 1); }],
  ['expiration exactly now', p => { p.ExpirationDate = new Date(now); }],
  ['invalid expiration string', p => { p.ExpirationDate = 'not-a-date'; }],
  ['invalid Date object', p => { p.ExpirationDate = new Date(NaN); }],
  ['missing expiration', p => { delete p.ExpirationDate; }],
  ['interior application wildcard', p => { p.Entitlements['com.apple.application-identifier'] = 'ABCDE12345.org.*.fixture'; }],
  ['interior and trailing application wildcards', p => { p.Entitlements['com.apple.application-identifier'] = 'ABCDE12345.*.fixture*'; }],
  ['interior keychain wildcard', p => { p.Entitlements['keychain-access-groups'] = ['ABCDE12345.org.*.webauthn']; }],
  ['interior and trailing keychain wildcards', p => { p.Entitlements['keychain-access-groups'] = ['ABCDE12345.*.fixture.*']; }],
]) {
  test(`rejects ${name}`, () => {
    const profile = fixture();
    change(profile);
    assert.throws(() => authorize(profile));
  });
}

test('rejects a same-team profile for a different bundle even when TEAM.* keychain groups match', () => {
  const profile = fixture();
  profile.Entitlements['com.apple.application-identifier'] = 'ABCDE12345.com.unrelated.app';
  profile.Entitlements['keychain-access-groups'] = ['ABCDE12345.*'];
  assert.throws(() => authorize(profile), /provisioning profile/);
});

test('accepts a profile until its expiration boundary', () => {
  const profile = fixture();
  profile.ExpirationDate = new Date(now + 1);
  assert.deepEqual(authorize(profile), { 'com.apple.application-identifier': appId });
});

test('rejects missing profiles', () => {
  for (const profile of [undefined, null, {}]) {
    assert.throws(() => authorize(profile));
  }
});

test('readProfile rejects a missing path without invoking security', () => {
  for (const file of [undefined, null, '']) {
    assert.throws(() => readProfile(file), /GRAFF_WEBAUTHN_PROFILE/);
  }
});
