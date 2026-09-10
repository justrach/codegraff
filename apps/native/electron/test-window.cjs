/** Default GUI tests stay off the user's desktop (#832). Foreground
 * interaction is opt-in via GRAFF_ELECTRON_FOREGROUND=1. */

function testWindowMode() {
  if (process.env.GRAFF_ELECTRON_FOREGROUND === '1') return 'foreground';
  if (process.env.GRAFF_ELECTRON_VISIBLE === '1') return 'visible';
  return 'hidden';
}

function presentWindow(win, app, extra = {}) {
  // A WebContentsView host has to be mapped: the chrome measures the
  // pane with getBoundingClientRect, and sendInputEvent only reaches
  // the page when the view is visible. showInactive keeps #832 — we
  // still do not steal focus unless foreground is requested.
  const mode = extra.mapped && testWindowMode() === 'hidden' ? 'visible' : testWindowMode();
  if (win.webContents && !win.webContents.isDestroyed()) win.webContents.setBackgroundThrottling(false);
  if (mode === 'foreground') {
    app?.focus?.({ steal: true });
    win.show();
    win.focus();
  } else if (mode === 'visible') {
    win.showInactive();
  }
  return mode;
}

function testWindowOptions(extra = {}) {
  return { show: false, ...extra, webPreferences: { backgroundThrottling: false, ...(extra.webPreferences || {}) } };
}

module.exports = { testWindowMode, presentWindow, testWindowOptions };
