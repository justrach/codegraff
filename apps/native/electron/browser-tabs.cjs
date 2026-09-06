const { WebContentsView, session } = require('electron');
const path = require('node:path');
const { pageURL, bounds } = require('./policy.cjs');

class BrowserTabs {
  constructor(window, emit) {
    this.window = window; this.emit = emit; this.tabs = new Map();
    this.visible = null; this.suspendMs = 60_000;
    // One persistent browser session shares network/cache processes, separate from the app.
    this.session = session.fromPartition('persist:browser');
    this.session.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
    this.session.setPermissionCheckHandler(() => false);
    this.session.on('will-download', (_event, item) => { item.setSaveDialogOptions({ title: 'Save download', defaultPath: item.getFilename() }); });
  }
  info(tab) {
    const wc = tab.view?.webContents;
    return { tabId: tab.chat, url: wc?.getURL() || tab.url, title: wc?.getTitle() || '',
      width: tab.rect?.width || 0, height: tab.rect?.height || 0,
      ready: wc ? (wc.isLoading() ? 'loading' : 'complete') : 'suspended', suspended: !wc,
      canGoBack: wc?.navigationHistory.canGoBack() ?? false, canGoForward: wc?.navigationHistory.canGoForward() ?? false };
  }
  notify(tab) { this.emit({ chat: tab.chat, type: 'info', info: this.info(tab) }); }
  create(chat) {
    if (typeof chat !== 'string' || chat.length > 256) throw new Error('Invalid chat');
    let tab = this.tabs.get(chat);
    if (!tab) { tab = { chat, url: 'about:blank', view: null, timer: null, rect: null }; this.tabs.set(chat, tab); }
    clearTimeout(tab.timer);
    if (tab.view) return tab;
    // Bound churn when the user rapidly switches chats; never evict the visible page.
    if (this.liveCount >= 3) {
      const victim = [...this.tabs.values()].find(t => t.view && t.chat !== this.visible);
      if (victim) { this.release(victim); this.notify(victim); }
    }
    const view = new WebContentsView({ webPreferences: { session: this.session,
      preload: path.join(__dirname, 'page-preload.cjs'), nodeIntegration: false,
      contextIsolation: true, sandbox: true, backgroundThrottling: true } });
    tab.view = view;
    const wc = view.webContents;
    let navigationStarted = 0;
    wc.on('did-start-loading', () => { navigationStarted = performance.now(); this.profiler?.record('page-navigation'); this.notify(tab); });
    wc.on('did-finish-load', () => { this.profiler?.record('page-loaded', performance.now() - navigationStarted); wc.send('profile-enabled', !!this.profiler?.active); });
    wc.setWindowOpenHandler(({ url }) => {
      void this.navigate(chat, url).catch(() => {}); return { action: 'deny' };
    });
    wc.on('will-navigate', (event, url) => { try { pageURL(url); } catch { event.preventDefault(); } });
    wc.on('will-redirect', (event, url) => { try { pageURL(url); } catch { event.preventDefault(); } });
    for (const name of ['did-navigate', 'did-navigate-in-page', 'page-title-updated', 'did-stop-loading']) {
      wc.on(name, () => { tab.url = wc.getURL() || tab.url; this.notify(tab); });
    }
    wc.on('render-process-gone', () => { this.profiler?.record('renderer-crash'); this.release(tab); this.notify(tab); });
    wc.on('before-input-event', (event, input) => {
      if ((input.meta || input.control) && input.key.toLowerCase() === 'l') {
        event.preventDefault(); this.window.webContents.focus(); this.emit({ chat, type: 'address' });
      }
    });
    this.window.contentView.addChildView(view); view.setVisible(false);
    return tab;
  }
  async navigate(chat, raw) {
    const url = pageURL(raw), tab = this.create(chat); tab.url = url;
    this.attach(tab); this.emit({ chat, type: 'show' });
    await tab.view.webContents.loadURL(url);
    this.notify(tab); return this.info(tab);
  }
  attach(tab) {
    if (this.visible && this.visible !== tab.chat) this.hide(this.visible);
    this.visible = tab.chat; clearTimeout(tab.timer);
    if (tab.view && tab.rect) { tab.view.setBounds(tab.rect); tab.view.setVisible(!this.overlay && tab.rect.width > 0 && tab.rect.height > 0); }
  }
  setOverlay(blocked) { this.overlay = blocked; const tab = this.tabs.get(this.visible); if (tab) this.attach(tab); }
  setBounds(chat, rect) {
    let tab = this.tabs.get(chat);
    const size = this.window.getContentBounds();
    const safe = bounds(rect, size);
    if (!safe || !safe.width || !safe.height) { this.hide(chat); return; }
    if (!tab) { tab = { chat, url: 'about:blank', view: null, timer: null, rect: safe }; this.tabs.set(chat, tab); }
    tab.rect = safe; this.attach(tab);
  }
  hide(chat) {
    const tab = this.tabs.get(chat); if (!tab) return;
    tab.view?.setVisible(false); if (this.visible === chat) this.visible = null;
    clearTimeout(tab.timer);
    tab.timer = setTimeout(() => { this.release(tab); this.notify(tab); }, this.suspendMs);
    tab.timer.unref();
  }
  release(tab) {
    clearTimeout(tab.timer); if (!tab.view) return;
    const view = tab.view; tab.url = view.webContents.getURL() || tab.url; tab.view = null;
    if (!this.window.isDestroyed()) this.window.contentView.removeChildView(view);
    if (!view.webContents.isDestroyed()) view.webContents.close();
  }
  close(chat) { const tab = this.tabs.get(chat); if (tab) this.release(tab); this.tabs.delete(chat); if (this.visible === chat) this.visible = null; }
  closeAll() { for (const chat of [...this.tabs.keys()]) this.close(chat); }
  async command(chat, method, params = {}) {
    if (method === 'bounds') return this.setBounds(chat, params);
    if (method === 'hide') return this.hide(chat);
    if (method === 'close') { this.close(chat); return { ok: true }; }
    if (method === 'stop') { this.closeAll(); return { ok: true }; }
    if (method === 'info') {
      const tab = this.tabs.get(chat);
      return tab && (tab.view || tab.url !== 'about:blank') ? this.info(tab) : null;
    }
    if (method === 'open' || method === 'navigate') return this.navigate(chat, params.url);
    const tab = this.tabs.get(chat);
    if (!tab?.view) throw new Error('Open the browser page first');
    const wc = tab.view.webContents;
    if (method === 'back' && wc.navigationHistory.canGoBack()) wc.navigationHistory.goBack();
    else if (method === 'forward' && wc.navigationHistory.canGoForward()) wc.navigationHistory.goForward();
    else if (method === 'reload') wc.reload();
    else if (method === 'pick') wc.send('pick-mode', !!params.enabled);
    return this.info(tab);
  }
  get liveCount() { return [...this.tabs.values()].filter(t => t.view).length; }
}
module.exports = { BrowserTabs };
