// Map graff 3/4-part versions onto semver so electron-updater can compare
// hotfix tags like 0.0.302.3. Semver has no fourth numeric segment; 0.0.X.Y
// becomes 0.X.Y (and 0.0.X becomes 0.X.0). Other 3-part versions stay as-is.
function isReleaseVersion(version) {
  return /^\d+\.\d+\.\d+(?:\.\d+)?$/.test(String(version));
}

function parts(version) {
  const m = String(version).trim().replace(/^[vV]/, '').match(/^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$/);
  if (!m) return null;
  return { a: Number(m[1]), b: Number(m[2]), c: Number(m[3]), d: m[4] == null ? 0 : Number(m[4]), hotfix: m[4] != null };
}

function toSemver(version) {
  const p = parts(version);
  if (!p) throw Error(`Not a graff release version: ${version}`);
  if (p.a === 0 && p.b === 0) return `0.${p.c}.${p.d}`;
  if (!p.hotfix) return `${p.a}.${p.b}.${p.c}`;
  return `${p.a}.${p.b * 1_000_000 + p.c}.${p.d}`;
}

function fromSemver(mapped) {
  const m = String(mapped).trim().match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!m) return String(mapped);
  const a = Number(m[1]), x = Number(m[2]), d = Number(m[3]);
  if (a === 0) return d === 0 ? `0.0.${x}` : `0.0.${x}.${d}`;
  return String(mapped);
}

function displayVersion(info) {
  if (info && typeof info.graffVersion === 'string' && info.graffVersion) return info.graffVersion;
  if (info && typeof info.version === 'string') return fromSemver(info.version);
  return info?.version;
}

module.exports = { isReleaseVersion, toSemver, fromSemver, displayVersion };
