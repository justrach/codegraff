// All installed/release copies using the same profile belong to one desktop.
// Acquire this before starting Bun or Chromium sessions: a second server gets
// a different origin and therefore a different set of saved UI preferences.
function claimDesktopInstance(app, window, open = () => {}, initialPath = process.env.GRAFF_OPEN_PATH || process.env.GRAFF_CWD) {
  if (!app.requestSingleInstanceLock({ openPath: initialPath || null })) return false;
  if (initialPath) open(initialPath);
  const focus = () => {
    const win = window();
    if (!win || win.isDestroyed()) return;
    if (process.env.GRAFF_ELECTRON_SMOKE) { require('./test-window.cjs').presentWindow(win, app); return; }
    if (win.isMinimized()) win.restore();
    win.show();
    win.focus();
  };
  app.on('second-instance', (_event, _argv, _cwd, data) => { if (data?.openPath) open(data.openPath); focus(); });
  app.on('open-file', (event, file) => { event.preventDefault(); open(file); focus(); });
  app.on('activate', focus);
  return true;
}
module.exports = { claimDesktopInstance };
