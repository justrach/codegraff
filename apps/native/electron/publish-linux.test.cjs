const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const script = path.join(__dirname, 'publish-linux.sh');

function stage(files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-linux-release-'));
  const src = path.join(root, 'pkg');
  const dest = path.join(root, 'staged');
  fs.mkdirSync(src);
  for (const [name, body] of Object.entries(files)) fs.writeFileSync(path.join(src, name), body);
  return { root, src, dest };
}

test('release assets take the desktop name and record their checksum', () => {
  const { root, src, dest } = stage({
    'codegraff_0.0.302.4_amd64.deb': 'deb-bytes',
    'codegraff-0.0.302.4-x86_64.AppImage': 'image-bytes',
  });
  try {
    const run = spawnSync('bash', [script, '--prepare', dest, 'v0.0.302.4', src], { encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(fs.readFileSync(path.join(dest, 'Codegraff-linux-amd64.deb'), 'utf8'), 'deb-bytes');
    assert.equal(fs.readFileSync(path.join(dest, 'Codegraff-linux-amd64.AppImage'), 'utf8'), 'image-bytes');
    const sums = fs.readFileSync(path.join(dest, 'Codegraff-linux-amd64-SHA256SUMS'), 'utf8');
    const debHash = crypto.createHash('sha256').update('deb-bytes').digest('hex');
    const imageHash = crypto.createHash('sha256').update('image-bytes').digest('hex');
    assert.match(sums, new RegExp(`${debHash}\\s+Codegraff-linux-amd64\\.deb`));
    assert.match(sums, new RegExp(`${imageHash}\\s+Codegraff-linux-amd64\\.AppImage`));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a deb for a different version is not a release asset', () => {
  const { root, src, dest } = stage({ 'codegraff_0.0.1_amd64.deb': 'deb-bytes' });
  try {
    const run = spawnSync('bash', [script, '--prepare', dest, 'v0.0.302.4', src], { encoding: 'utf8' });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /expected one codegraff_0\.0\.302\.4_/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
