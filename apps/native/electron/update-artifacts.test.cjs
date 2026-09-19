const { test, expect } = require('bun:test');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { load } = require('js-yaml');
const { writeManifest, writeFeedConfig, readFeedConfig, zipMembers, verifyDistributionBundle, bundleConfigRel, archiveMember, feed } = require('./update-artifacts.cjs');
test('release metadata can be read by the updater and identifies the exact archive', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-update-metadata-'));
  try {
    const file = path.join(dir, 'Codegraff-1.2.3-macos-arm64.zip'), manifest = path.join(dir, 'latest-mac.yml');
    fs.writeFileSync(file, 'archive fixture');
    writeManifest('1.2.3', file, manifest);
    const data = load(fs.readFileSync(manifest, 'utf8'));
    expect(data.version).toBe('1.2.3');
    expect(data.files[0].url).toBe(path.basename(file));
    expect(data.files[0].size).toBe(fs.statSync(file).size);
    expect(Buffer.from(data.files[0].sha512, 'base64').length).toBe(64);
    expect(load(JSON.stringify(feed)).url).toBe('https://github.com/justrach/codegraff/releases/latest/download/');
    expect(() => writeManifest('1.2.4', file, manifest)).toThrow('archive name');
    expect(() => writeManifest('1.2.3-beta.1', file, manifest)).toThrow('stable');
    // Four-segment CLI hotfixes (0.0.300.1) never enter the desktop feed.
    expect(() => writeManifest('1.2.3.4', file, manifest)).toThrow('stable');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
// Minimal stored (uncompressed) zip writer: local headers, central
// directory, end record. Enough for the pre-publish member check without
// depending on an external zip binary in the test.
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const b of bytes) {
    crc ^= b;
    for (let k = 0; k < 8; k++) crc = (crc & 1) ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function storedZip(files) {
  const locals = [], centrals = [];
  let offset = 0;
  for (const [name, data] of files) {
    const nameBuf = Buffer.from(name, 'utf8'), payload = Buffer.isBuffer(data) ? data : Buffer.from(data);
    const head = Buffer.alloc(30);
    head.writeUInt32LE(0x04034b50, 0); head.writeUInt16LE(20, 4); head.writeUInt16LE(0, 6); head.writeUInt16LE(0, 8);
    head.writeUInt32LE(crc32(payload), 14); head.writeUInt32LE(payload.length, 18); head.writeUInt32LE(payload.length, 22);
    head.writeUInt16LE(nameBuf.length, 26); head.writeUInt16LE(0, 28);
    locals.push(head, nameBuf, payload);
    const cen = Buffer.alloc(46);
    cen.writeUInt32LE(0x02014b50, 0); cen.writeUInt16LE(20, 4); cen.writeUInt16LE(20, 6);
    cen.writeUInt32LE(crc32(payload), 16); cen.writeUInt32LE(payload.length, 20); cen.writeUInt32LE(payload.length, 24);
    cen.writeUInt16LE(nameBuf.length, 28); cen.writeUInt32LE(offset, 42);
    centrals.push(cen, nameBuf);
    offset += head.length + nameBuf.length + payload.length;
  }
  const cd = Buffer.concat(centrals), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(files.length, 8); end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(cd.length, 12); end.writeUInt32LE(offset, 16); end.writeUInt16LE(0, 20);
  return Buffer.concat([...locals, cd, end]);
}
function bundleFixture(withConfig) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-update-bundle-'));
  const app = path.join(dir, 'Codegraff.app');
  fs.mkdirSync(path.join(app, 'Contents', 'Resources'), { recursive: true });
  if (withConfig) writeFeedConfig(path.join(app, bundleConfigRel));
  return { dir, app };
}
test('the feed config distribute.sh embeds is valid and points at the release feed', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-update-config-'));
  try {
    const file = path.join(dir, 'app-update.yml');
    writeFeedConfig(file);
    // electron-updater reads YAML; our JSON must parse as YAML too.
    expect(load(fs.readFileSync(file, 'utf8')).url).toBe(feed.url);
    expect(readFeedConfig(file)).toEqual(feed);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
test('a bundle without update config is refused: the 0.0.299 shape never ships again', () => {
  const { dir, app } = bundleFixture(false);
  try {
    const zip = path.join(dir, 'Codegraff-9.9.9-macos-arm64.zip');
    fs.writeFileSync(zip, storedZip([[archiveMember, '{}']]));
    expect(() => verifyDistributionBundle(app, zip)).toThrow('no update configuration');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
test('a config pointed at the wrong feed is refused, not shipped', () => {
  const { dir, app } = bundleFixture(false);
  try {
    fs.writeFileSync(path.join(app, bundleConfigRel), JSON.stringify({ ...feed, url: 'https://example.com/evil/' }));
    const zip = path.join(dir, 'Codegraff-9.9.9-macos-arm64.zip');
    fs.writeFileSync(zip, storedZip([[archiveMember, '{}']]));
    expect(() => verifyDistributionBundle(app, zip)).toThrow('wrong feed');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
test('a zip that does not wrap the configured app is refused', () => {
  const { dir, app } = bundleFixture(true);
  try {
    // A stale or foreign zip: valid config on disk, but the upload bytes
    // would install an app that never checks for updates.
    const zip = path.join(dir, 'Codegraff-9.9.9-macos-arm64.zip');
    fs.writeFileSync(zip, storedZip([['Codegraff.app/Contents/Info.plist', 'plist']]));
    expect(zipMembers(zip)).not.toContain(archiveMember);
    expect(() => verifyDistributionBundle(app, zip)).toThrow('does not contain');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
test('a configured bundle inside its zip passes the pre-publish gate', () => {
  const { dir, app } = bundleFixture(true);
  try {
    const zip = path.join(dir, 'Codegraff-9.9.9-macos-arm64.zip');
    fs.writeFileSync(zip, storedZip([
      ['Codegraff.app/Contents/Info.plist', 'plist'],
      [archiveMember, fs.readFileSync(path.join(app, bundleConfigRel))],
      ['Codegraff.app/._Contents', 'appledouble'],
    ]));
    expect(zipMembers(zip)).toContain(archiveMember);
    expect(verifyDistributionBundle(app, zip)).toEqual(feed);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
test('unreadable archives fail closed instead of reporting no update config', () => {
  const { dir, app } = bundleFixture(true);
  try {
    const zip = path.join(dir, 'Codegraff-9.9.9-macos-arm64.zip');
    fs.writeFileSync(zip, 'not a zip at all');
    expect(() => verifyDistributionBundle(app, zip)).toThrow('zip');
    const good = storedZip([[archiveMember, '{}']]);
    fs.writeFileSync(zip, good.subarray(0, good.length - 30)); // truncated end record
    expect(() => verifyDistributionBundle(app, zip)).toThrow('zip');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
test('distribute.sh and publish-updates.sh both run the pre-publish gate', () => {
  for (const script of ['distribute.sh', 'publish-updates.sh']) {
    const src = fs.readFileSync(path.join(__dirname, script), 'utf8');
    expect(src).toContain('update-artifacts.cjs');
    expect(src).toContain('verify-bundle');
  }
});
