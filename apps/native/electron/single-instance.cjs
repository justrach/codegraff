// All installed/release copies using the same profile belong to one desktop.
// Acquire this before starting Bun or Chromium sessions: a second server gets
// a different origin and therefore a different set of saved UI preferences.
function claimDesktopInstance(app, window) {
  if (!app.requestSingleInstanceLock()) return false;
  const focus = () => {
    const win = window();
    if (!win || win.isDestroyed()) return;
    if (win.isMinimized()) win.restore();
    win.show();
    win.focus();
  };
  app.on('second-instance', focus);
  app.on('activate', focus);
  return true;
}
module.exports = { claimDesktopInstance };
