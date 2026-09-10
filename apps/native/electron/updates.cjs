const fs = require('node:fs');
const path = require('node:path');

const FIRST_CHECK_MS = 30_000;
const POLL_MS = 6 * 60 * 60 * 1000;

function unavailableMessage(reason) {
  return {
    smoke: 'Update checks are disabled in this test build.',
    platform: 'Automatic updates are available on the macOS desktop app.',
    unpackaged: 'This build is not a packaged Codegraff app, so updates are disabled.',
    volume: 'Move Codegraff from the disk image into Applications, then check again.',
    config: 'This build has no update configuration.',
  }[reason] || 'Install a signed release in Applications to receive updates.';
}

function updateAvailability({ app, resources, env = process.env, execPath = process.execPath, platform = process.platform }) {
  if (env.GRAFF_ELECTRON_SMOKE) return { available: false, reason: 'smoke' };
  if (platform !== 'darwin') return { available: false, reason: 'platform' };
  if (!app.isPackaged) return { available: false, reason: 'unpackaged' };
  if (String(execPath).startsWith('/Volumes/')) return { available: false, reason: 'volume' };
  if (!require('node:fs').existsSync(require('node:path').join(resources, 'app-update.yml'))) return { available: false, reason: 'config' };
  return { available: true, reason: null };
}

function createUpdates({ updater, version, available = true, automatic = true, notify, save = () => {}, onReady, unavailableReason }) {
  const blocked = !available;
  const blockedMessage = blocked ? unavailableMessage(unavailableReason) : undefined;
  let state = { status: available ? 'idle' : 'unavailable', currentVersion: version, automatic: available ? automatic : false, interactive: false, message: blockedMessage };
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
    updater.on('update-downloaded', info => {
      emit({ status: 'ready', version: info.version, percent: 100 });
      if (onReady && info.version && info.version !== state.prompted) {
        state.prompted = info.version; // once per version: dismiss means Later, never a loop
        onReady(info.version);
      }
    });
    updater.on('error', () => emit({ status: 'error', message: 'Could not update. Check your connection and try again.' }));
  }
  return {
    state: () => ({ ...state }),
    async check(interactive = false) {
      if (checking || ['downloading', 'ready', 'installing'].includes(state.status)) {
        if (interactive) emit({ interactive: true });
        return;
      }
      if (!available) { emit({ interactive, message: blockedMessage }); return; }
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
  const { dialog } = require('electron');
  const prefs = path.join(app.getPath('userData'), 'updates.json');
  let automatic = true;
  try { automatic = JSON.parse(fs.readFileSync(prefs, 'utf8')).automatic !== false; } catch {}
  const gate = updateAvailability({ app, resources });
  const available = gate.available;
  let autoItem;
  const controller = createUpdates({ version: app.getVersion(), automatic, available, unavailableReason: gate.reason,
    updater: available ? require('./updater-runtime.cjs') : null,
    save: value => { fs.mkdirSync(path.dirname(prefs), { recursive: true }); fs.writeFileSync(prefs, JSON.stringify({ automatic: value })); },
    notify: state => {
      if (autoItem) autoItem.checked = state.automatic;
      if (!win.isDestroyed()) { win.webContents.send('update-state', state); win.setProgressBar(state.status === 'downloading' ? (state.percent ?? 0) / 100 : -1); }
    },
    onReady: readyVersion => {
      // The standard update modal (Sparkle/electron-updater style): pops once
      // per downloaded version, after the download — never mid-conversation.
      if (win.isDestroyed()) return;
      void dialog.showMessageBox(win, {
        type: 'info',
        title: 'Update Available',
        message: `Codegraff ${readyVersion} is ready to install.`,
        detail: 'Restart to apply the update now, or keep working — Codegraff offers the restart again at next launch.',
        buttons: ['Restart to update', 'Later'], defaultId: 0, cancelId: 1,
      }).then(({ response }) => {
        if (response === 0 && !win.isDestroyed()) { try { controller.restart(); } catch {} }
      }).catch(() => {});
    },
  });
  autoItem = { label: 'Automatically Download Updates', type: 'checkbox', checked: available && automatic,
    enabled: available, click: item => controller.setAutomatic(item.checked) };
  ipcMain.handle('updates', async (event, action, value) => {
    trusted(event);
    if (action === 'check') await controller.check(true);
    else if (action === 'restart') controller.restart();
    else if (action === 'automatic') controller.setAutomatic(!!value);
    else if (action !== 'state') throw Error('Unknown update action');
    return controller.state();
  });
  const check = () => { if (controller.state().automatic) void controller.check(); };
  const first = setTimeout(check, FIRST_CHECK_MS), repeat = setInterval(check, POLL_MS);
  first.unref(); repeat.unref();
  app.once('before-quit', () => { clearTimeout(first); clearInterval(repeat); });
  return [
    { label: 'Check for Updates…', enabled: available, click: () => void controller.check(true) },
    autoItem,
  ];
}
module.exports = { createUpdates, installUpdates, updateAvailability, unavailableMessage, FIRST_CHECK_MS, POLL_MS };
