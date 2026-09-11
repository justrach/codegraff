/** GUI verification is hidden by default (#832). Native OS interaction needs
 * GRAFF_ELECTRON_FOREGROUND=1; visible windows never activate the app. */
function testWindowMode(env = process.env) {
  if (env.GRAFF_ELECTRON_FOREGROUND === '1' || env.GRAFF_TEST_FOREGROUND === '1') return 'foreground';
  if (env.GRAFF_ELECTRON_VISIBLE === '1') return 'visible';
  return 'hidden';
}

function presentWindow(win, app, _extra, env = process.env) {
  const mode = testWindowMode(env);
  if (mode !== 'foreground' && win.webContents && !win.webContents.isDestroyed()) win.webContents.setBackgroundThrottling(false);
  if (mode === 'foreground') {
    app?.focus?.({ steal: true });
    win.show();
    win.focus();
  } else if (mode === 'visible') {
    win.showInactive();
  }
  return mode;
}

function testWindowOptions(extra = {}, env = process.env) {
  return { ...extra, show: false, focusable: testWindowMode(env) === 'foreground',
    webPreferences: { ...extra.webPreferences, ...(testWindowMode(env) !== 'foreground' ? { backgroundThrottling: false } : {}) } };
}

const skippedChecks = new Set();
function foregroundCheck(name, env = process.env) {
  if (testWindowMode(env) === 'foreground') return true;
  skippedChecks.add(name);
  console.log(`SKIP: ${name} requires GRAFF_ELECTRON_FOREGROUND=1 (takes desktop focus).`);
  return false;
}

function visibleWindowCheck(name, env = process.env) {
  if (testWindowMode(env) !== 'hidden') return true;
  skippedChecks.add(name);
  console.log(`SKIP: ${name} requires GRAFF_ELECTRON_VISIBLE=1 (visible without desktop focus).`);
  return false;
}

// Install before app.whenReady(), including when the test entry point is run directly.
// OS policy prevents activation; method guards fail on accidental test bypasses.
const installed = new WeakSet();
function installTestWindowPolicy(app, env = process.env, platform = process.platform) {
  if (installed.has(app)) return;
  installed.add(app);
  const mode = testWindowMode(env);
  console.log(`Electron tests: ${mode}.`);
  if (mode === 'visible') console.log('Visible opt-in: windows keep keyboard focus elsewhere but can cover your work. Use hidden mode for no desktop overlap.');
  if (mode === 'foreground') {
    console.log('Foreground opt-in: these checks can take desktop focus and send native input.');
    return;
  }
  // Accessory policy still lets WebContents.focus() activate macOS itself,
  // even when its BrowserWindow is non-focusable. Both quiet modes prohibit it.
  if (platform === 'darwin') app.setActivationPolicy('prohibited');
  const refuse = action => () => { throw Error(`#832: ${action} requires GRAFF_ELECTRON_FOREGROUND=1 (or GRAFF_TEST_FOREGROUND=1)`); };
  app.focus = refuse('app.focus');
  app.on('browser-window-created', (_event, win) => {
    win.setFocusable?.(false);
    for (const method of ['show', 'focus', 'restore', 'moveTop', 'maximize']) win[method] = refuse(method);
    for (const method of ['setFullScreen', 'setSimpleFullScreen', 'setKiosk']) {
      const original = win[method]?.bind(win);
      win[method] = enabled => { if (enabled) refuse(method)(); return original?.(enabled); };
    }
    if (mode === 'hidden') win.showInactive = refuse('showInactive in hidden mode');
    win.on('focus', () => { console.error('#832: unexpected test window focus'); app.exit?.(1); });
    if (mode === 'hidden') win.on('show', () => { console.error('#832: unexpected visible test window'); app.exit?.(1); });
  });
}

module.exports = { testWindowMode, presentWindow, testWindowOptions, foregroundCheck, visibleWindowCheck, installTestWindowPolicy, skippedChecks };
