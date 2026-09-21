// Production tests persist the same dismissed flag the app writes after Skip/Done.
const path = require('node:path');
const ONBOARDING_KEY = 'graff.onboarding.dismissed';
const ONBOARDING_DISMISSED = 'true';
const PAGE_SEED = "window.__GRAFF_ONBOARDED__=true;try{localStorage.setItem('graff.onboarding.dismissed','true')}catch(e){}";
const PRELOAD = path.join(__dirname, 'test-onboarding-preload.cjs');

function installOnboardingSeed(win) {
  const session = win.webContents?.session;
  if (!session?.setPreloads) return;
  const current = typeof session.getPreloads === 'function' ? session.getPreloads() : [];
  if (!current.includes(PRELOAD)) session.setPreloads([...current, PRELOAD]);
}

async function installPageWorldOnboardingSeed(wc) {
  if (!wc?.debugger) return;
  if (!wc.debugger.isAttached()) wc.debugger.attach('1.3');
  await wc.debugger.sendCommand('Page.enable');
  await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument', { source: PAGE_SEED });
}

module.exports = { ONBOARDING_KEY, ONBOARDING_DISMISSED, PAGE_SEED, PRELOAD, installOnboardingSeed, installPageWorldOnboardingSeed };
