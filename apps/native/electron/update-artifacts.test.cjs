const { test, expect } = require('bun:test');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { load } = require('js-yaml');
const { writeManifest, feed } = require('./update-artifacts.cjs');
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
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
