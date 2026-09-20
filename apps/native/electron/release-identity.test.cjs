'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const {
  RELEASE_BUNDLE_ID,
  DEV_BUNDLE_ID,
  assertReleaseBundleId,
  assertReleaseApp,
} = require('./release-identity.cjs');

test('release desktop identity is com.codegraff.app, not a dev build', () => {
  assert.equal(RELEASE_BUNDLE_ID, 'com.codegraff.app');
  assert.equal(DEV_BUNDLE_ID, 'dev.codegraff.app');
  assert.notEqual(RELEASE_BUNDLE_ID, DEV_BUNDLE_ID);
  assert.ok(!RELEASE_BUNDLE_ID.startsWith('dev.'));
  assert.ok(DEV_BUNDLE_ID.startsWith('dev.'));
  assert.doesNotThrow(() => assertReleaseBundleId(RELEASE_BUNDLE_ID));
  assert.throws(() => assertReleaseBundleId('dev.codegraff.electron.local'), /dev identity/);
  assert.throws(() => assertReleaseBundleId(DEV_BUNDLE_ID), /dev identity/);
  assert.throws(() => assertReleaseBundleId('org.example.app'), /must be com\.codegraff\.app/);
});

test('build.sh stamps the release id unless GRAFF_DEV is set', () => {
  const src = fs.readFileSync(path.join(__dirname, 'build.sh'), 'utf8');
  assert.match(src, /^bundle_id="com\.codegraff\.app"$/m);
  assert.match(src, /GRAFF_DEV[\s\S]*bundle_id="dev\.codegraff\.app"/);
  assert.doesNotMatch(src, /electron\.local/);
  assert.doesNotMatch(src, /^GRAFF_DEV=1/m);
});

test('distribute and publish refuse a packaged app that is not the release identity', () => {
  const distribute = fs.readFileSync(path.join(__dirname, 'distribute.sh'), 'utf8');
  const publish = fs.readFileSync(path.join(__dirname, 'publish-updates.sh'), 'utf8');
  assert.match(distribute, /release-identity\.cjs/);
  assert.match(publish, /release-identity\.cjs/);
});

test('assertReleaseApp accepts only the release identifier', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-identity-'));
  const write = (id) => {
    const app = path.join(root, `${id.replace(/\./g, '-')}.app`);
    fs.mkdirSync(path.join(app, 'Contents'), { recursive: true });
    fs.writeFileSync(
      path.join(app, 'Contents', 'Info.plist'),
      `<?xml version="1.0"?><plist><dict><key>CFBundleIdentifier</key><string>${id}</string></dict></plist>\n`,
    );
    return app;
  };
  try {
    assert.doesNotThrow(() => assertReleaseApp(write(RELEASE_BUNDLE_ID)));
    assert.throws(() => assertReleaseApp(write('dev.codegraff.electron.local')), /dev identity/);
    const rejected = spawnSync(process.execPath, [path.join(__dirname, 'release-identity.cjs'), write(DEV_BUNDLE_ID)], {
      encoding: 'utf8',
    });
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, /dev identity/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
