// Production tests persist the same dismissed flag the app writes after Skip/Done.
const path = require('node:path');
const ONBOARDING_KEY = 'graff.onboarding.dismissed';
const ONBOARDING_DISMISSED = 'true';
const PAGE_SEED = 'window.__GRAFF_ONBOARDED__=true;document.documentElement.dataset.graffOnboarded="1";try{localStorage.setItem(\'graff.onboarding.dismissed\',\'true\')}catch(e){}';
const PRELOAD = path.join(__dirname, 'test-onboarding-preload.cjs');
const PRELOAD_ID = 'graff-onboarding-seed';

function installSessionPreload(session) {
  if (typeof session.registerPreloadScript === 'function') {
    const scripts = typeof session.getPreloadScripts === 'function' ? session.getPreloadScripts() : [];
    if (scripts.some(script => script.id === PRELOAD_ID || script.filePath === PRELOAD)) return;
    session.registerPreloadScript({ type: 'frame', id: PRELOAD_ID, filePath: PRELOAD });
    return;
  }
  if (!session.setPreloads) return;
  const current = typeof session.getPreloads === 'function' ? session.getPreloads() : [];
  if (!current.includes(PRELOAD)) session.setPreloads([...current, PRELOAD]);
}

function installOnboardingSeed(win) {
  const session = win.webContents?.session;
  if (!session) return;
  // Do not attach the debugger here. Overflow/links attach later and Electron
  // throws "Debugger is already attached" — CI 6d47f20 failed on that after
  // the previous seed started attaching on every test window.
  installSessionPreload(session);
}

async function installPageWorldOnboardingSeed(wc) {
  if (!wc?.debugger) return;
  if (!wc.debugger.isAttached()) wc.debugger.attach('1.3');
  await wc.debugger.sendCommand('Page.enable');
  await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument', { source: PAGE_SEED });
}

module.exports = { ONBOARDING_KEY, ONBOARDING_DISMISSED, PAGE_SEED, PRELOAD, PRELOAD_ID, installOnboardingSeed, installPageWorldOnboardingSeed };
