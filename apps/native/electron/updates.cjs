const fs = require('node:fs');
const path = require('node:path');

function createUpdates({ updater, version, available = true, automatic = true, notify, save = () => {} }) {
  let state = { status: available ? 'idle' : 'unavailable', currentVersion: version, automatic, interactive: false };
  let checking = false;
  const emit = patch => { state = { ...state, ...patch }; notify({ ...state }); };
  if (available) {
    updater.autoDownload = true;
    updater.autoInstallOnAppQuit = false;
    updater.allowPrerelease = false;
    updater.allowDowngrade = false;
    updater.disableDifferentialDownload = true;
    updater.logger = null;
    updater.on('checking-for-update', () => emit({ status: 'checking', message: undefined }));
    updater.on('update-available', info => emit({ status: 'downloading', version: info.version, percent: 0 }));
    updater.on('download-progress', progress => {
      const percent = Math.max(0, Math.min(100, Math.floor(progress.percent || 0)));
      if (percent !== state.percent) emit({ status: 'downloading', percent });
    });
    updater.on('update-not-available', () => emit({ status: 'current', version: undefined, percent: undefined }));
    updater.on('update-downloaded', info => emit({ status: 'ready', version: info.version, percent: 100 }));
    updater.on('error', () => emit({ status: 'error', message: 'Could not update. Check your connection and try again.' }));
  }
  return {
    state: () => ({ ...state }),
    async check(interactive = false) {
      if (checking || ['downloading', 'ready', 'installing'].includes(state.status)) {
        if (interactive) emit({ interactive: true });
        return;
      }
      if (!available) { emit({ interactive, message: 'Install a signed release in Applications to receive updates.' }); return; }
      checking = true;
      emit({ status: 'checking', interactive, message: undefined });
      try {
        const result = await updater.checkForUpdates();
        // The check resolves before the background download. Always consume its
        // rejection as well as the updater's error event (offline/checksum errors).
        void result?.downloadPromise?.catch(() => emit({ status: 'error', message: 'Could not download the update. Please try again.' }));
      }
      catch { emit({ status: 'error', message: 'Could not check for updates. Check your connection and try again.' }); }
      finally { checking = false; }
    },
    setAutomatic(value) { save(value); emit({ automatic: value }); },
    restart() {
      if (state.status !== 'ready') throw Error('No downloaded update is ready.');
      emit({ status: 'installing' });
      try { updater.quitAndInstall(); }
      catch { emit({ status: 'error', message: 'Could not install the update. Try again from Applications.' }); }
    },
  };
}

function installUpdates({ app, win, ipcMain, trusted, resources }) {
  const prefs = path.join(app.getPath('userData'), 'updates.json');
  let automatic = true;
  try { automatic = JSON.parse(fs.readFileSync(prefs, 'utf8')).automatic !== false; } catch {}
  const available = app.isPackaged && process.platform === 'darwin' && !process.env.GRAFF_ELECTRON_SMOKE &&
    !process.execPath.startsWith('/Volumes/') && fs.existsSync(path.join(resources, 'app-update.yml'));
  const controller = createUpdates({ version: app.getVersion(), automatic, available,
    updater: available ? require('./updater-runtime.cjs') : null,
    save: value => { fs.mkdirSync(path.dirname(prefs), { recursive: true }); fs.writeFileSync(prefs, JSON.stringify({ automatic: value })); },
    notify: state => { if (!win.isDestroyed()) { win.webContents.send('update-state', state); win.setProgressBar(state.status === 'downloading' ? (state.percent ?? 0) / 100 : -1); } },
  });
  ipcMain.handle('updates', async (event, action) => {
    trusted(event);
    if (action === 'check') await controller.check(true);
    else if (action === 'restart') controller.restart();
    else if (action !== 'state') throw Error('Unknown update action');
    return controller.state();
  });
  const check = () => { if (controller.state().automatic) void controller.check(); };
  const first = setTimeout(check, 30000), repeat = setInterval(check, 6 * 60 * 60 * 1000);
  first.unref(); repeat.unref();
  app.once('before-quit', () => { clearTimeout(first); clearInterval(repeat); });
  return [
    { label: 'Check for Updates…', click: () => void controller.check(true) },
    { label: 'Automatically Download Updates', type: 'checkbox', checked: automatic,
      click: item => controller.setAutomatic(item.checked) },
  ];
}
module.exports = { createUpdates, installUpdates };
