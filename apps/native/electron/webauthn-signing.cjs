const { execFileSync } = require('node:child_process');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { readProfile, profileEntitlements } = require('./webauthn-profile.cjs');

function signingConfig(identity, explicitTeam, bundleId) {
  const team = explicitTeam !== undefined
    ? explicitTeam
    : /^Developer ID Application: [^\r\n]+ \(([A-Z0-9]{10})\)$(?![\s\S])/.exec(identity)?.[1];
  if (typeof team !== 'string' || !/^[A-Z0-9]{10}$(?![\s\S])/.test(team)) {
    throw new Error('A valid signing team is required; set GRAFF_SIGN_TEAM_ID for a hash identity.');
  }
  if (typeof bundleId !== 'string' || !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$(?![\s\S])/.test(bundleId)) {
    throw new Error('The app must have a valid CFBundleIdentifier.');
  }
  return { keychainAccessGroup: `${team}.${bundleId}.webauthn` };
}

function optionsForFile(app, config, applicationEntitlements = {}) {
  app = path.resolve(app);
  return (file) => {
    file = path.resolve(file);
    const main = file === app;
    const bun = file.endsWith('/Resources/bun');
    const jit = bun || main || file.endsWith('.app') || file.includes('/Electron Framework.framework/');
    const entitlements = {};
    if (jit) entitlements['com.apple.security.cs.allow-jit'] = true;
    if (bun) entitlements['com.apple.security.cs.allow-unsigned-executable-memory'] = true;
    if (main) Object.assign(entitlements, applicationEntitlements, { 'keychain-access-groups': [config.keychainAccessGroup] });
    return { hardenedRuntime: true, entitlements };
  };
}

// osx-sign 2.7 accepts paths or arrays of boolean keys, not entitlement objects.
// Serialize our dictionary to a temporary plist to retain array-valued groups.
function entitlementsPlist(entitlements) {
  const escape = (value) => value.replace(/[<>&"']/g, (char) => ({
    '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;',
  })[char]);
  const entries = Object.entries(entitlements).map(([key, value]) => {
    const encoded = value === true ? '<true/>'
      : typeof value === 'string' ? `<string>${escape(value)}</string>`
      : Array.isArray(value) && value.every((item) => typeof item === 'string')
        ? `<array>${value.map((item) => `<string>${escape(item)}</string>`).join('')}</array>`
        : null;
    if (encoded === null) throw new Error('Unsupported signing entitlement value.');
    return `<key>${escape(key)}</key>${encoded}`;
  }).join('');
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>${entries}</dict></plist>\n`;
}

async function signBundle({ app, identity, teamId, profilePath, sign, readProvisioningProfile = readProfile, readBundleId = (bundle) =>
  execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', path.join(bundle, 'Contents', 'Info.plist')],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).replace(/\r?\n$/, '') }) {
  if (!app || !identity) throw new Error('Provide an app path and GRAFF_SIGN_IDENTITY.');
  app = path.resolve(app);
  const config = signingConfig(identity, teamId, readBundleId(app));
  const applicationEntitlements = profileEntitlements(readProvisioningProfile(profilePath), config);
  const fileOptions = optionsForFile(app, config, applicationEntitlements);
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'graff-sign-entitlements-'));
  try {
    const paths = new Map();
    // Precompute the four entitlement policies; optionsForFile must be synchronous.
    for (const file of [app, `${app}/Contents/Resources/bun`, `${app}/Contents/Frameworks/Helper.app`, `${app}/Contents/Resources/other`]) {
      const entitlements = fileOptions(file).entitlements;
      const key = JSON.stringify(entitlements);
      if (!paths.has(key)) {
        const plistPath = path.join(temporary, `${paths.size}.plist`);
        await fs.writeFile(plistPath, entitlementsPlist(entitlements));
        paths.set(key, plistPath);
      }
    }
    // osx-sign's automatic embedding keeps stale profiles; replace with the one validated above.
    await fs.copyFile(profilePath, path.join(app, 'Contents', 'embedded.provisionprofile'));
    await fs.writeFile(path.join(app, 'Contents', 'Resources', 'webauthn.json'), `${JSON.stringify(config)}\n`);
    await sign({
      app, platform: 'darwin', type: 'distribution', identity,
      preAutoEntitlements: false, preEmbedProvisioningProfile: false,
      provisioningProfile: path.resolve(profilePath),
      optionsForFile(file) {
        const options = fileOptions(file);
        return { ...options, entitlements: paths.get(JSON.stringify(options.entitlements)) };
      },
    });
  } finally {
    await fs.rm(temporary, { recursive: true, force: true });
  }
}

module.exports = { signingConfig, optionsForFile, entitlementsPlist, signBundle };
