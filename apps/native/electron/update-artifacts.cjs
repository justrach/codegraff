const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const feed = { provider: 'generic', url: 'https://github.com/justrach/codegraff/releases/latest/download/', updaterCacheDirName: 'codegraff-updater' };
function writeManifest(version, archive, output) {
  // Desktop bundles stay 3-part even though the CLI accepts 4-part hotfix
  // versions (0.0.300.1): electron-updater compares feed versions as semver,
  // which has no fourth segment, and the Apple chain (Info.plist marketing
  // version, notarization, spctl) is only verified for 3-part. Ship desktop
  // fixes as 3-part releases; 4-part tags are CLI-only and carry no desktop
  // asset, so the desktop updaters below never see one.
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
