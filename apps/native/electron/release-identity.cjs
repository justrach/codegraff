'use strict';

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

/** Packaged / notarized Codegraff.app. Never a `dev.*` identifier. */
const RELEASE_BUNDLE_ID = 'com.codegraff.app';
/** GRAFF_DEV=1 local rebuild only. */
const DEV_BUNDLE_ID = 'dev.codegraff.app';

function assertReleaseBundleId(id) {
  if (typeof id !== 'string' || id.length === 0) {
    throw new Error('Release CFBundleIdentifier is missing.');
  }
  if (id.startsWith('dev.')) {
    throw new Error(`Release CFBundleIdentifier must not be a dev identity (got ${id}).`);
  }
  if (id !== RELEASE_BUNDLE_ID) {
    throw new Error(`Release CFBundleIdentifier must be ${RELEASE_BUNDLE_ID}, got ${id}.`);
  }
}

function readBundleId(app) {
  const plist = path.join(app, 'Contents', 'Info.plist');
  try {
    return execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', plist], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).replace(/\r?\n$/, '');
  } catch {
    const text = fs.readFileSync(plist, 'utf8');
    const match = text.match(/<key>CFBundleIdentifier<\/key>\s*<string>([^<]+)<\/string>/);
    if (!match) throw new Error(`CFBundleIdentifier missing in ${plist}`);
    return match[1];
  }
}

function assertReleaseApp(app) {
  if (!app) throw new Error('Usage: release-identity.cjs /path/Codegraff.app');
  assertReleaseBundleId(readBundleId(app));
}

module.exports = { RELEASE_BUNDLE_ID, DEV_BUNDLE_ID, assertReleaseBundleId, readBundleId, assertReleaseApp };

if (require.main === module) {
  try {
    assertReleaseApp(process.argv[2]);
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  }
}
