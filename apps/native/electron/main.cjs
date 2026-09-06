const { app, BrowserWindow, ipcMain, Menu, dialog } = require('electron');
const path = require('node:path');
const { randomBytes } = require('node:crypto');
const { treeSample, intervalSampler } = require('./process-metrics.cjs');
const { BrowserTabs } = require('./browser-tabs.cjs');
const { startAutomation } = require('./automation.cjs');
const { startServer } = require('./server.cjs');
const { ComputerUse } = require('./computer.cjs');
const { desktopConfig } = require('./desktop-config.cjs');
const { browserAction } = require('./browser-actions.cjs');
const { Profiler } = require('./profiler.cjs');
const fs = require('node:fs/promises');

const root = process.env.GRAFF_CWD || app.getPath('home');
const resources = process.env.GRAFF_ELECTRON_RESOURCES || process.resourcesPath;
app.setName('Codegraff');
app.setPath('userData', path.join(app.getPath('appData'), 'Codegraff Electron'));
let win, browser, backend, automation, computer, profiler;
let quitting = false;

async function metrics() {
  const { rssMiB, cpuPercent, processes } = await treeSample(process.pid);
  return { rssMiB, cpuPercent, processes, browsers: browser.liveCount };
}
async function activity() {
  const snapshot = await metrics();
  if (process.platform === 'darwin') {
    const native = require(path.join(resources, 'native/activity.node'));
    native.show(win.getNativeWindowHandle(), JSON.stringify(snapshot));
  } else await dialog.showMessageBox(win, { title: 'Activity', message: `${snapshot.rssMiB} MiB · ${snapshot.cpuPercent}% CPU`, detail: `${snapshot.browsers} browser views` });
  return snapshot;
}
function trusted(event) {
  if (event.sender !== win?.webContents || event.senderFrame !== win.webContents.mainFrame ||
      new URL(event.senderFrame.url).origin !== backend.origin) throw new Error('Untrusted IPC sender');
}
function stop() {
  if (quitting) return; quitting = true;
  profiler?.stop(); browser?.closeAll(); automation?.server.close(); backend?.stop();
}
app.on('before-quit', stop);
app.on('window-all-closed', () => app.quit());
process.on('SIGTERM', () => app.quit());
process.on('SIGINT', () => app.quit());

app.whenReady().then(async () => {
  app.setAccessibilitySupportEnabled(true);
  const token = randomBytes(32).toString('hex');
  win = new BrowserWindow({ width: 1440, height: 920, minWidth: 900, minHeight: 600,
    title: 'Codegraff', titleBarStyle: 'hiddenInset', trafficLightPosition: { x: 14, y: 11 }, backgroundColor: '#fafaf9', show: false,
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), partition: 'persist:app',
      contextIsolation: true, sandbox: true, nodeIntegration: false, backgroundThrottling: true } });
  browser = new BrowserTabs(win, message => { if (!win.isDestroyed()) win.webContents.send('browser-event', message); });
  win.on('close', () => browser.closeAll());
  win.webContents.on('did-start-navigation', (_event, _url, inPlace, mainFrame) => {
    if (mainFrame && !inPlace) browser.closeAll();
  });
  computer = new ComputerUse(resources, win);
  profiler = new Profiler(intervalSampler(process.pid, () => browser.liveCount), enabled => {
    if (win.isDestroyed()) return;
    for (const contents of [win.webContents, ...[...browser.tabs.values()].map(tab => tab.view?.webContents).filter(Boolean)]) {
      if (!contents.isDestroyed()) contents.send('profile-enabled', enabled);
    }
  });
  browser.profiler = profiler;
  win.webContents.on('render-process-gone', () => profiler.record('renderer-crash'));
  ipcMain.on('profile-longtask', (event, duration) => {
    const owned = event.sender === win.webContents || [...browser.tabs.values()].some(tab => tab.view?.webContents === event.sender);
    if (owned && Number.isFinite(duration) && duration >= 0 && duration <= 600000) profiler.record('renderer-long-task', duration);
  });
  automation = await startAutomation(browser, computer, profiler);
  const handle = automation.handle('');
  backend = await startServer(resources, root, token, app.getPath('logs'), {
    GRAFF_DESKTOP_ENDPOINT: `http://127.0.0.1:${handle.port}`, GRAFF_DESKTOP_SECRET: handle.token,
    GRAFF_MCP_CONFIG: desktopConfig(resources, app.getPath('userData')),
  });
  const uiSession = win.webContents.session;
  uiSession.webRequest.onBeforeSendHeaders({ urls: [`${backend.origin}/*`] }, (details, callback) => {
    details.requestHeaders['x-graff-desktop'] = token; callback({ requestHeaders: details.requestHeaders });
  });
  uiSession.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));

  ipcMain.handle('browser', async (event, { chat, method, params }) => {
    trusted(event);
    if (typeof chat !== 'string' || chat.length > 256) throw new Error('Invalid chat');
    if (method === 'handle') return browser.tabs.get(chat)?.view ? automation.handle(chat) : null;
    if (!['open', 'navigate', 'back', 'forward', 'reload', 'info', 'bounds', 'hide', 'close', 'stop', 'pick', 'find', 'zoom'].includes(method)) throw new Error('Unknown action');
    return ['find', 'zoom'].includes(method) ? browserAction(browser, chat, method, params) : browser.command(chat, method, params);
  });
  ipcMain.handle('activity', event => { trusted(event); return activity(); });
  ipcMain.on('browser-pin', (event, pin) => {
    const tab = [...browser.tabs.values()].find(t => t.view?.webContents === event.sender);
    if (!tab || event.senderFrame !== event.sender.mainFrame || !pin?.element || JSON.stringify(pin).length > 16000) return;
    win.webContents.send('browser-event', { chat: tab.chat, type: 'pin', pin });
  });
  win.webContents.on('will-navigate', (event, url) => { if (new URL(url).origin !== backend.origin) event.preventDefault(); });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.on('minimize', () => { if (browser.visible) browser.hide(browser.visible); });
  win.on('restore', () => win.webContents.send('browser-event', { type: 'layout' }));
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: 'Codegraff', submenu: [{ role: 'about' }, { label: 'Activity…', accelerator: 'CmdOrCtrl+,', click: () => void activity().catch(error => dialog.showErrorBox('Activity', error.message)) }, { label: 'Computer use…', click: () => void computer.configure().catch(error => dialog.showErrorBox('Computer use', error.message)) }, { type: 'separator' }, { role: 'quit' }] },
    { role: 'editMenu' }, { label: 'View', submenu: [{ role: 'reload' }, { role: 'toggleDevTools' }, { role: 'togglefullscreen' }, { label: 'Release browser pages', click: () => { browser.closeAll(); win.webContents.send('browser-event', { type: 'released' }); } }] },
    { label: 'Performance', submenu: [
      { label: 'Start recording', click: () => void profiler.start() },
      { label: 'Mark candidate phase', click: () => profiler.mark('candidate') },
      { label: 'Stop recording', click: () => profiler.stop() },
      { label: 'Export feedback report…', click: async () => {
        profiler.stop();
        const selected = await dialog.showSaveDialog(win, { title: 'Save private-content-free performance report', defaultPath: 'codegraff-performance.json', filters: [{ name: 'JSON report', extensions: ['json'] }] });
        if (!selected.canceled && selected.filePath) await fs.writeFile(selected.filePath, JSON.stringify(profiler.report(), null, 2));
      } },
    ] },
    { role: 'windowMenu' },
  ]));
  await win.loadURL(backend.origin); win.setWindowButtonVisibility(true); win.show(); profiler.record('ui-ready');
  if (process.env.GRAFF_ELECTRON_SMOKE) require('./smoke.cjs').run({ win, browser, automation, backend, metrics, activity, computer, profiler }).then(() => app.quit()).catch(error => { console.error(error); stop(); app.exit(1); });
}).catch(error => { console.error(error); stop(); app.exit(1); });
