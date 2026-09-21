const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const feed = { provider: 'generic', url: 'https://github.com/justrach/codegraff/releases/latest/download/', updaterCacheDirName: 'codegraff-updater' };
// Where updates.cjs looks for its feed: <resources>/app-update.yml, i.e.
// this path under the .app. distribute.sh writes it before signing so it is
// inside the signature; the 0.0.299 bundle shipped without it and its
// updater never ran (updateAvailability reason 'config').
const bundleConfigRel = path.join('Contents', 'Resources', 'app-update.yml');
// ditto --keepParent zips Codegraff.app itself, so this is the member path.
const archiveMember = 'Codegraff.app/' + bundleConfigRel.split(path.sep).join('/');
const { isReleaseVersion, toSemver } = require('./update-version.cjs');
function writeManifest(version, archive, output) {
  // electron-updater compares feed versions as semver (no fourth numeric
  // segment). 4-part hotfixes (0.0.302.3) still ship as desktop updates:
  // the zip keeps the graff version in its name, and `version` in the feed
  // is the mapped semver (0.302.3) so 0.0.302 apps see it as newer.
  if (!isReleaseVersion(version)) throw Error('Only stable versions can enter the desktop update feed.');
  const url = path.basename(archive);
  if (url !== `Codegraff-${version}-macos-arm64.zip`) throw Error('Update archive name must match its version and architecture.');
  const bytes = fs.readFileSync(archive);
  const sha512 = crypto.createHash('sha512').update(bytes).digest('base64');
  const manifest = { version: toSemver(version), graffVersion: version, files: [{ url, sha512, size: bytes.length }], path: url, sha512, releaseDate: new Date().toISOString() };
  // JSON is valid YAML, and avoids escaping release-controlled filenames by hand.
  fs.writeFileSync(output, JSON.stringify(manifest, null, 2) + '\n');
  return manifest;
}
function writeFeedConfig(output) {
  fs.writeFileSync(output, JSON.stringify(feed, null, 2) + '\n');
  return feed;
}
// Read back a feed config and prove it points at this project's release
// feed. Anything unexpected fails closed: a missing file is the 0.0.299
// shape (no update checks at all), and a wrong URL would update from
// somewhere else, which is worse. JSON only: distribute.sh writes this
// file via writeFeedConfig, so anything unparseable was hand-tampered.
function readFeedConfig(file) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch {
    throw Error(`Distribution bundle has no update configuration (${file}); an app without it never checks for updates.`);
  }
  let config;
  try {
    config = JSON.parse(raw);
  } catch {
    throw Error(`Update configuration is not readable (${file}); refusing to ship an app that cannot check for updates.`);
  }
  for (const key of ['provider', 'url', 'updaterCacheDirName']) {
    if (!config || config[key] !== feed[key]) throw Error(`Update configuration ${key} is ${JSON.stringify(config?.[key])} (expected ${JSON.stringify(feed[key])}); refusing to ship an app pointed at the wrong feed.`);
  }
  return config;
}
// Member names out of a zip's central directory. Names only, no extraction,
// no dependencies: publish-updates.sh runs this on the release Mac against
// the exact bytes about to be uploaded. Anything malformed throws rather
// than reporting "not found" on a file we could not actually read.
function zipMembers(zipPath) {
  const bytes = fs.readFileSync(zipPath);
  const EOCD = 0x06054b50, CEN = 0x02014b50;
  if (bytes.length < 22) throw Error(`Update archive is too small to be a zip (${zipPath}).`);
  let eocd = -1;
  const lo = Math.max(0, bytes.length - 22 - 65535);
  for (let i = bytes.length - 22; i >= lo; i--) {
    if (bytes.readUInt32LE(i) === EOCD) { eocd = i; break; }
  }
  if (eocd < 0) throw Error(`Update archive has no zip end record (${zipPath}).`);
  const entries = bytes.readUInt16LE(eocd + 10);
  const cdSize = bytes.readUInt32LE(eocd + 12);
  const cdOff = bytes.readUInt32LE(eocd + 16);
  if (entries === 0xffff || cdSize === 0xffffffff || cdOff === 0xffffffff) throw Error(`Update archive needs zip64, which the pre-publish check does not read (${zipPath}).`);
  if (cdOff + cdSize > bytes.length) throw Error(`Update archive central directory runs past end of file (${zipPath}).`);
  const names = [];
  let at = cdOff;
  for (let n = 0; n < entries; n++) {
    if (at + 46 > bytes.length || bytes.readUInt32LE(at) !== CEN) throw Error(`Update archive central directory is malformed (${zipPath}).`);
    const nameLen = bytes.readUInt16LE(at + 28), extraLen = bytes.readUInt16LE(at + 30), commentLen = bytes.readUInt16LE(at + 32);
    const start = at + 46, end = start + nameLen;
    if (end > bytes.length) throw Error(`Update archive central directory is malformed (${zipPath}).`);
    names.push(bytes.subarray(start, end).toString('utf8'));
    at = end + extraLen + commentLen;
  }
  return names;
}
// The pre-publish gate publish-updates.sh and distribute.sh both run: the
// .app on disk must carry a valid feed config, and the uploadable zip must
// contain that same config at its installed path. Either half missing is
// the 0.0.299 shape. Returns the parsed feed on success; throws otherwise.
function verifyDistributionBundle(appDir, archive) {
  const config = readFeedConfig(path.join(appDir, bundleConfigRel));
  const members = zipMembers(archive);
  if (!members.includes(archiveMember)) throw Error(`Update archive ${path.basename(archive)} does not contain ${archiveMember}; it would install an app that never checks for updates.`);
  return config;
}
if (require.main === module) {
  if (process.argv[2] === 'config') writeFeedConfig(process.argv[3]);
  else if (process.argv[2] === 'verify-bundle') verifyDistributionBundle(process.argv[3], process.argv[4]);
  else writeManifest(...process.argv.slice(2));
}
module.exports = { writeManifest, writeFeedConfig, readFeedConfig, zipMembers, verifyDistributionBundle, bundleConfigRel, archiveMember, feed };
