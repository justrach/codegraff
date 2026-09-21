// Production tests persist the same dismissed flag the app writes after Skip/Done.
const path = require('node:path');
const ONBOARDING_KEY = 'graff.onboarding.dismissed';
const ONBOARDING_DISMISSED = 'true';
const PRELOAD = path.join(__dirname, 'test-onboarding-preload.cjs');

function installOnboardingSeed(win) {
  const session = win.webContents?.session;
  if (!session?.setPreloads) return;
  const current = typeof session.getPreloads === 'function' ? session.getPreloads() : [];
  if (!current.includes(PRELOAD)) session.setPreloads([...current, PRELOAD]);
}

module.exports = { ONBOARDING_KEY, ONBOARDING_DISMISSED, PRELOAD, installOnboardingSeed };
