// Real updater HTTP/checksum path against a disposable loopback feed. This
// deliberately tests transport only: it never asks Squirrel to install an app.
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const http = require('node:http'), assert = require('node:assert/strict');
const { writeManifest } = require('./update-artifacts.cjs');
async function runUpdateTransport() {
  if (process.platform !== 'darwin') return;
  const { autoUpdater: updater } = require('electron-updater');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-update-transport-'));
  const archive = path.join(root, 'Codegraff-99.0.0-macos-arm64.zip');
  const bytes = Buffer.alloc(22); bytes.writeUInt32LE(0x06054b50); // Valid empty ZIP.
  fs.writeFileSync(archive, bytes);
  const manifest = writeManifest('99.0.0', archive, path.join(root, 'latest-mac.yml'));
  let corrupt = true, ready = 0;
  const server = http.createServer((req, res) => {
    if (req.url.split('?')[0] === '/latest-mac.yml') res.end(JSON.stringify(manifest));
    else { res.setHeader('content-length', bytes.length); res.end(corrupt ? Buffer.alloc(bytes.length, 1) : bytes); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    updater.logger = null;
    updater.autoInstallOnAppQuit = false;
    updater.disableDifferentialDownload = true;
    updater.forceDevUpdateConfig = true;
    const config = { provider: 'generic', url: `http://127.0.0.1:${server.address().port}/`, updaterCacheDirName: 'cache' };
    fs.writeFileSync(path.join(root, 'config.yml'), JSON.stringify(config));
    updater.updateConfigPath = path.join(root, 'config.yml');
    Object.defineProperty(updater.app, 'baseCachePath', { value: root });
    updater.on('update-downloaded', () => ready++);
    const first = await updater.checkForUpdates();
    await assert.rejects(first.downloadPromise, /sha512 checksum mismatch/i);
    assert.equal(ready, 0, 'corrupt bytes must never be ready to install');
    corrupt = false;
    const second = await updater.checkForUpdates();
    await second.downloadPromise;
    assert.equal(ready, 1);
    assert.equal(updater.squirrelDownloadedUpdate, false, 'transport must not start native installation');
    console.log('Updater transport passed: corrupt archive rejected, retry verified, no native installation.');
  } finally {
    updater.closeServerIfExists(); server.close();
    fs.rmSync(root, { recursive: true, force: true });
  }
}
module.exports = { runUpdateTransport };
