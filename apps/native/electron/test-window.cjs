// Compatibility helpers; new fixtures use test-desktop.cjs.
function testWindowMode() {
  if (process.env.GRAFF_TEST_FOREGROUND === '1') return 'foreground';
  return 'hidden';
}

function presentWindow(win, app, extra = {}) {
  const mode = testWindowMode();
  if (win.webContents && !win.webContents.isDestroyed()) win.webContents.setBackgroundThrottling(false);
  if (mode === 'foreground') {
    app?.focus?.({ steal: true });
    win.show();
    win.focus();
  }
  return mode;
}

function testWindowOptions(extra = {}) {
  return { ...extra, show: false, webPreferences: { backgroundThrottling: false, ...(extra.webPreferences || {}) } };
}

module.exports = { testWindowMode, presentWindow, testWindowOptions };
