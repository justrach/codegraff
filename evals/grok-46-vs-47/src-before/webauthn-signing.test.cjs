const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createRequire } = require('node:module');
const { execFileSync } = require('node:child_process');
const { signingConfig, optionsForFile, signBundle } = require('./webauthn-signing.cjs');
const requireSigner = createRequire(require.resolve('@electron/osx-sign'));
const plist = requireSigner('plist');
const identity = 'Developer ID Application: Test Fixture (ABCDE12345)';
const bundleId = 'org.example.fixture';
const profile = appId => ({ Platform: ['OSX'], TeamIdentifier: ['ABCDE12345'], ExpirationDate: new Date('2099-01-01'),
  Entitlements: { 'com.apple.application-identifier': `ABCDE12345.${appId}`, 'keychain-access-groups': ['ABCDE12345.*'] } });

test('team derives only from an anchored Developer ID Application identity or explicit valid team', () => {
  assert.deepEqual(signingConfig(identity, undefined, bundleId), { keychainAccessGroup: 'ABCDE12345.org.example.fixture.webauthn' });
  assert.equal(signingConfig('a'.repeat(40), 'ZYXWV98765', bundleId).keychainAccessGroup, 'ZYXWV98765.org.example.fixture.webauthn');
  for (const value of [undefined, '', 'a'.repeat(40), 'Other: Fixture (ABCDE12345)', `${identity} trailing`, `${identity}\n`, 'prefix ' + identity]) {
    assert.throws(() => signingConfig(value, undefined, bundleId), /valid signing team/);
  }
  for (const team of ['', 'short', 'abcde12345', 'ABCDE12345\n', 'ABCDE1234*']) {
    assert.throws(() => signingConfig(identity, team, bundleId), /valid signing team/);
  }
  for (const bundle of ['', undefined, 'org..fixture', '.fixture', 'org.fixture.', 'org_fixture', 'org.fixture\n', 'org.*', 'org/fixture']) {
    assert.throws(() => signingConfig(identity, undefined, bundle), /CFBundleIdentifier/);
  }
});

test('only main app gets keychain access; existing JIT and Bun policies stay exact', () => {
  const app = path.resolve('Fixture.app');
  const config = signingConfig(identity, undefined, bundleId);
  const options = optionsForFile(app, config);
  const jit = { 'com.apple.security.cs.allow-jit': true };
  const cases = [
    [app, { ...jit, 'keychain-access-groups': [config.keychainAccessGroup] }],
    [app + '/', { ...jit, 'keychain-access-groups': [config.keychainAccessGroup] }],
    [`${app}/Contents/Resources/bun`, { ...jit, 'com.apple.security.cs.allow-unsigned-executable-memory': true }],
    [`${app}/Contents/Frameworks/Helper.app`, jit],
    [`${app}/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework`, jit],
    [`${app}/Contents/Resources/tool`, {}],
    [`${app}/Contents/Frameworks/library.dylib`, {}],
  ];
  for (const [file, entitlements] of cases) assert.deepEqual(options(file), { hardenedRuntime: true, entitlements });
});

for (const fails of [false, true]) test(`sign dispatch writes matching config and plist entitlements, cleans temporary files (failure=${fails})`, async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'webauthn-sign-test-'));
  const app = path.join(root, 'Fixture.app');
  const resources = path.join(app, 'Contents', 'Resources');
  const entitlementPaths = [];
  let calls = 0;
  try {
    await fs.mkdir(resources, { recursive: true });
    await fs.writeFile(path.join(resources, 'webauthn.json'), '{"stale":true}');
    const profilePath = path.join(root, 'fixture.provisionprofile');
    await fs.writeFile(profilePath, 'fixture CMS bytes');
    await fs.writeFile(path.join(app, 'Contents', 'embedded.provisionprofile'), 'stale profile');
    const applicationEntitlements = { 'com.apple.application-identifier': `ABCDE12345.${bundleId}` };
    const work = signBundle({ app, identity, profilePath, readProvisioningProfile: () => profile(bundleId), readBundleId: (actual) => {
      assert.equal(actual, app);
      return bundleId;
    }, sign: async (options) => {
      calls++;
      assert.equal(options.preAutoEntitlements, false);
      assert.equal(options.preEmbedProvisioningProfile, false);
      assert.equal(options.provisioningProfile, profilePath);
      assert.equal(await fs.readFile(path.join(app, 'Contents', 'embedded.provisionprofile'), 'utf8'), 'fixture CMS bytes');
      assert.equal(options.platform, 'darwin');
      assert.equal(options.type, 'distribution');
      const config = JSON.parse(await fs.readFile(path.join(resources, 'webauthn.json'), 'utf8'));
      assert.deepEqual(config, signingConfig(identity, undefined, bundleId));
      for (const file of [app, `${resources}/bun`, `${app}/Contents/Frameworks/Helper.app`, `${resources}/tool`]) {
        const result = options.optionsForFile(file);
        assert.equal(result.hardenedRuntime, true);
        assert.equal(typeof result.entitlements, 'string');
        entitlementPaths.push(result.entitlements);
        assert.deepEqual(plist.parse(await fs.readFile(result.entitlements, 'utf8')), optionsForFile(app, config, applicationEntitlements)(file).entitlements);
      }
      if (fails) throw new Error('fixture failure');
    } });
    if (fails) await assert.rejects(work, /fixture failure/);
    else await work;
    assert.equal(calls, 1);
    for (const file of entitlementPaths) await assert.rejects(fs.access(file), { code: 'ENOENT' });
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});

test('invalid metadata fails before writing config or invoking signer', async () => {
  let called = false;
  await assert.rejects(signBundle({ app: 'Fixture.app', identity, teamId: '', readBundleId: () => bundleId, sign: () => { called = true; } }), /valid signing team/);
  await assert.rejects(signBundle({ app: 'Fixture.app', identity, readBundleId: () => 'bad/bundle', sign: () => { called = true; } }), /CFBundleIdentifier/);
  await assert.rejects(signBundle({ app: 'Fixture.app', identity, readBundleId: () => bundleId, sign: () => { called = true; } }), /GRAFF_WEBAUTHN_PROFILE/);
  assert.equal(called, false);
});

test('default reader obtains actual bundle identifier through PlistBuddy', { skip: process.platform !== 'darwin' }, async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'webauthn-plist-test-'));
  const app = path.join(root, 'Fixture.app');
  try {
    await fs.mkdir(path.join(app, 'Contents', 'Resources'), { recursive: true });
    await fs.writeFile(path.join(app, 'Contents', 'Info.plist'), plist.build({ CFBundleIdentifier: 'org.example.actual' }));
    const profilePath = path.join(root, 'fixture.provisionprofile');
    await fs.writeFile(profilePath, 'fixture CMS bytes');
    await signBundle({ app, identity, profilePath, readProvisioningProfile: () => profile('org.example.actual'), sign: async (options) => {
      const config = JSON.parse(await fs.readFile(path.join(app, 'Contents', 'Resources', 'webauthn.json'), 'utf8'));
      assert.equal(config.keychainAccessGroup, 'ABCDE12345.org.example.actual.webauthn');
      const group = execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :keychain-access-groups:0', options.optionsForFile(app).entitlements], { encoding: 'utf8' }).trim();
      assert.equal(group, config.keychainAccessGroup);
    } });
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
