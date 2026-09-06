const { app, BrowserWindow, ipcMain, Menu, dialog } = require('electron');
const path = require('node:path');
const { randomBytes } = require('node:crypto');
const { treeSample, intervalSampler } = require('./process-metrics.cjs');
const { BrowserTabs } = require('./browser-tabs.cjs');
const { startAutomation } = require('./automation.cjs');
const { installExternalLinks } = require('./external-links.cjs');
const { startServer } = require('./server.cjs');
const { ComputerUse } = require('./computer.cjs');
const { desktopConfig } = require('./desktop-config.cjs');
const { browserAction } = require('./browser-actions.cjs');
const { Profiler } = require('./profiler.cjs');
const { rendererSample } = require('./renderer-profile.cjs');
const { observeAgents, agentSampler } = require('./agent-observer.cjs');
const { chromiumSample } = require('./hardware-profile.cjs');
const fs = require('node:fs/promises');
const { installWindowState } = require('./window-state.cjs');

const root = process.env.GRAFF_CWD || app.getPath('home');
const resources = process.env.GRAFF_ELECTRON_RESOURCES || process.resourcesPath;
app.setName('Codegraff');
app.setPath('userData', process.env.GRAFF_ELECTRON_SMOKE ? path.join(require('node:os').tmpdir(), `codegraff-smoke-${process.pid}`) : path.join(app.getPath('appData'), 'Codegraff Electron'));
if (process.env.GRAFF_ELECTRON_SMOKE) process.env.GRAFF_THEMES_DIR = path.join(app.getPath('userData'), 'themes');
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
      contextIsolation: true, sandbox: true, nodeIntegration: false, backgroundThrottling: !process.env.GRAFF_ELECTRON_SMOKE } });
  installWindowState(win);
  browser = new BrowserTabs(win, message => { if (!win.isDestroyed()) win.webContents.send('browser-event', message); });
  win.on('close', () => browser.closeAll());
  win.webContents.on('did-start-navigation', (_event, _url, inPlace, mainFrame) => {
    if (mainFrame && !inPlace) browser.closeAll();
  });
  computer = new ComputerUse(resources, win);
  const sampleTree = intervalSampler(process.pid, () => browser.liveCount);
  const sampleAgents = agentSampler();
  profiler = new Profiler(async () => {
    const [tree, renderer, agents] = await Promise.all([sampleTree(), rendererSample(win.webContents).catch(() => ({})),
      observeAgents(path.join(resources, "graff"), root, { scope: "device", history: "off" }).then(data => sampleAgents(data.agents)).catch(() => [])]);
    return { ...tree, ...renderer, agents, ...chromiumSample(app.getAppMetrics()) };
  }, enabled => {
    if (!enabled) void rendererSample(win.webContents, false).catch(() => {});
    if (win.isDestroyed()) return;
    for (const contents of [win.webContents, ...[...browser.tabs.values()].map(tab => tab.view?.webContents).filter(Boolean)]) {
      if (!contents.isDestroyed()) contents.send('profile-enabled', enabled);
    }
  }, () => app.getGPUFeatureStatus());
  browser.profiler = profiler;
  win.webContents.on('did-finish-load', () => win.webContents.send('profile-enabled', !!profiler.active));
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
  ipcMain.on('browser-overlay', (event, blocked) => { trusted(event); browser.setOverlay(blocked === true); });
  ipcMain.handle('window-control', (event, action) => {
    trusted(event);
    if (action === 'fullscreen') win.setFullScreen(!win.isFullScreen());
    else if (['zoom-in', 'zoom-out', 'reset-zoom'].includes(action)) win.webContents.setZoomLevel(action === 'reset-zoom' ? 0 : Math.max(-3, Math.min(4, win.webContents.getZoomLevel() + (action === 'zoom-in' ? 0.5 : -0.5))));
    else throw new Error('Unknown window action');
  });
  ipcMain.handle('activity', event => { trusted(event); return activity(); });
  ipcMain.on('browser-pin', (event, pin) => {
    const tab = [...browser.tabs.values()].find(t => t.view?.webContents === event.sender);
    if (!tab || event.senderFrame !== event.sender.mainFrame || !pin?.element || JSON.stringify(pin).length > 16000) return;
    win.webContents.send('browser-event', { chat: tab.chat, type: 'pin', pin });
  });
  installExternalLinks(win.webContents, backend.origin);
  win.on('minimize', () => { if (browser.visible) browser.hide(browser.visible); });
  win.on('restore', () => win.webContents.send('browser-event', { type: 'layout' }));
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: 'Codegraff', submenu: [{ role: 'about' }, { label: 'Activity…', accelerator: 'CmdOrCtrl+,', click: () => void activity().catch(error => dialog.showErrorBox('Activity', error.message)) }, { label: 'Computer use…', click: () => void computer.configure().catch(error => dialog.showErrorBox('Computer use', error.message)) }, { type: 'separator' }, { role: 'quit' }] },
    { label: 'File', submenu: [
      ['New chat', 'CmdOrCtrl+N', 'new'], ['New tab', 'CmdOrCtrl+T', 'new'],
      ['Close chat', 'CmdOrCtrl+W', 'close'], ['Reopen closed chat', 'CmdOrCtrl+Shift+T', 'reopen'],
      ['Open workspace…', 'CmdOrCtrl+O', 'workspace'], ['Split right', 'CmdOrCtrl+D', 'split-right'],
      ['Split down', 'CmdOrCtrl+Shift+D', 'split-down'], ['Zoom split', 'CmdOrCtrl+Shift+Enter', 'split-zoom'],
    ].map(([label, accelerator, action]) => ({ label, accelerator, click: () => win.webContents.send('desktop-action', action) })) },
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
