// Isolated-world preload: mark the shared DOM before AccountChrome hydrates.
// window.__GRAFF_ONBOARDED__ stays isolated unless copied into the page world.
// Storage is often denied at document-start; retry after the origin commits.
const PAGE_SEED = 'window.__GRAFF_ONBOARDED__=true;document.documentElement.dataset.graffOnboarded="1";try{localStorage.setItem(\'graff.onboarding.dismissed\',\'true\')}catch(e){}';
let contextBridge, webFrame;
try { ({ contextBridge, webFrame } = require('electron')); } catch { /* sandboxed preload without electron */ }
function seedIsolated() {
  window.__GRAFF_ONBOARDED__ = true;
  try { document.documentElement.dataset.graffOnboarded = '1'; } catch { /* html not ready */ }
  try { localStorage.setItem('graff.onboarding.dismissed', 'true'); } catch { /* optional storage */ }
}
seedIsolated();
try {
  if (typeof contextBridge?.executeInMainWorld === 'function') {
    contextBridge.executeInMainWorld({
      func: () => {
        const seed = () => {
          window.__GRAFF_ONBOARDED__ = true;
          try { document.documentElement.dataset.graffOnboarded = '1'; } catch { /* html not ready */ }
          try { localStorage.setItem('graff.onboarding.dismissed', 'true'); } catch { /* optional storage */ }
        };
        seed();
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', seed);
      },
    });
  } else if (webFrame) {
    webFrame.executeJavaScript(PAGE_SEED);
  }
} catch { /* page world unavailable */ }
