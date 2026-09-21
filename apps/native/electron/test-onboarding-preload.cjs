// Isolated-world preload: mark the shared DOM before AccountChrome hydrates.
// window.__GRAFF_ONBOARDED__ stays isolated unless copied into the page world.
const PAGE_SEED = 'window.__GRAFF_ONBOARDED__=true;document.documentElement.dataset.graffOnboarded="1";try{localStorage.setItem(\'graff.onboarding.dismissed\',\'true\')}catch(e){}';
let contextBridge, webFrame;
try { ({ contextBridge, webFrame } = require('electron')); } catch { /* sandboxed preload without electron */ }
try {
  window.__GRAFF_ONBOARDED__ = true;
  document.documentElement.dataset.graffOnboarded = '1';
  localStorage.setItem('graff.onboarding.dismissed', 'true');
} catch { /* optional storage */ }
try {
  if (typeof contextBridge?.executeInMainWorld === 'function') {
    contextBridge.executeInMainWorld({
      func: () => {
        window.__GRAFF_ONBOARDED__ = true;
        document.documentElement.dataset.graffOnboarded = '1';
        try { localStorage.setItem('graff.onboarding.dismissed', 'true'); } catch { /* optional storage */ }
      },
    });
  } else if (webFrame) {
    webFrame.executeJavaScript(PAGE_SEED);
  }
} catch { /* page world unavailable */ }
