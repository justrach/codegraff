const { test, expect } = require('bun:test');
const { isReleaseVersion, toSemver, fromSemver, displayVersion } = require('./update-version.cjs');

function semverGt(a, b) {
  const pa = String(a).split('.').map(Number);
  const pb = String(b).split('.').map(Number);
  while (pa.length < 3) pa.push(0);
  while (pb.length < 3) pb.push(0);
  for (let i = 0; i < 3; i++) if (pa[i] !== pb[i]) return pa[i] > pb[i];
  return false;
}

test('3-part and 4-part hotfix versions are both release versions', () => {
  expect(isReleaseVersion('0.0.302')).toBe(true);
  expect(isReleaseVersion('0.0.302.3')).toBe(true);
  expect(isReleaseVersion('1.2.3')).toBe(true);
  expect(isReleaseVersion('1.2.3-beta.1')).toBe(false);
  expect(isReleaseVersion('0.0.302.3.1')).toBe(false);
});

test('0.0.x.y maps onto semver that orders like graff hotfixes', () => {
  expect(toSemver('0.0.302')).toBe('0.302.0');
  expect(toSemver('0.0.302.3')).toBe('0.302.3');
  expect(toSemver('v0.0.303')).toBe('0.303.0');
  expect(toSemver('1.2.3')).toBe('1.2.3');
  expect(semverGt(toSemver('0.0.302.1'), toSemver('0.0.302'))).toBe(true);
  expect(semverGt(toSemver('0.0.302.3'), toSemver('0.0.302.2'))).toBe(true);
  expect(semverGt(toSemver('0.0.303'), toSemver('0.0.302.9'))).toBe(true);
  expect(semverGt(toSemver('0.0.302.3'), toSemver('0.0.302'))).toBe(true);
  // Installed 3-part apps still see a 4-part feed as newer.
  expect(semverGt(toSemver('0.0.302.3'), '0.0.302')).toBe(true);
});

test('mapped 0.0.x.y versions round-trip for UI copy', () => {
  expect(fromSemver(toSemver('0.0.302'))).toBe('0.0.302');
  expect(fromSemver(toSemver('0.0.302.3'))).toBe('0.0.302.3');
  expect(fromSemver('1.2.3')).toBe('1.2.3');
  expect(displayVersion({ version: '0.302.3' })).toBe('0.0.302.3');
  expect(displayVersion({ version: '0.302.3', graffVersion: '0.0.302.3' })).toBe('0.0.302.3');
});

test('hotfix feed keeps the graff zip name and a comparable semver version', () => {
  const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
  const { writeManifest } = require('./update-artifacts.cjs');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-hotfix-feed-'));
  try {
    const file = path.join(dir, 'Codegraff-0.0.302.3-macos-arm64.zip');
    fs.writeFileSync(file, 'archive fixture');
    const manifest = writeManifest('0.0.302.3', file, path.join(dir, 'latest-mac.yml'));
    expect(manifest.version).toBe('0.302.3');
    expect(manifest.graffVersion).toBe('0.0.302.3');
    expect(manifest.files[0].url).toBe('Codegraff-0.0.302.3-macos-arm64.zip');
    const onDisk = JSON.parse(fs.readFileSync(path.join(dir, 'latest-mac.yml'), 'utf8'));
    expect(onDisk.version).toBe('0.302.3');
    expect(onDisk.graffVersion).toBe('0.0.302.3');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
