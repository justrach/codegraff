const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const feed = { provider: 'generic', url: 'https://github.com/justrach/codegraff/releases/latest/download/', updaterCacheDirName: 'codegraff-updater' };
function writeManifest(version, archive, output) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw Error('Only stable versions can enter the desktop update feed.');
  const url = path.basename(archive);
  if (url !== `Codegraff-${version}-macos-arm64.zip`) throw Error('Update archive name must match its version and architecture.');
  const bytes = fs.readFileSync(archive);
  const sha512 = crypto.createHash('sha512').update(bytes).digest('base64');
  const manifest = { version, files: [{ url, sha512, size: bytes.length }], path: url, sha512, releaseDate: new Date().toISOString() };
  // JSON is valid YAML, and avoids escaping release-controlled filenames by hand.
  fs.writeFileSync(output, JSON.stringify(manifest, null, 2) + '\n');
  return manifest;
}
if (require.main === module) {
  if (process.argv[2] === 'config') fs.writeFileSync(process.argv[3], JSON.stringify(feed, null, 2) + '\n');
  else writeManifest(...process.argv.slice(2));
}
module.exports = { writeManifest, feed };
