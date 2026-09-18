const connected = new Set();
let port;
let queue = Promise.resolve();
const command = (tabId, method, params = {}) => chrome.debugger.sendCommand({tabId}, method, params);
const allowed = url => /^https?:\/\//i.test(url || '');

async function disconnect(tabId) {
  connected.delete(tabId);
  await chrome.action.setBadgeText({tabId, text: ''}).catch(() => {});
  await chrome.debugger.detach({tabId}).catch(() => {});
}
function connectHost() {
  if (port) return;
  const host = chrome.runtime.connectNative('dev.codegraff.chrome');
  port = host;
  host.onMessage.addListener(message => {
    queue = queue.then(async () => {
      try { host.postMessage({id: message.id, result: await execute(message)}); }
      catch (error) { try { host.postMessage({id: message.id, error: error.message}); } catch {} }
    });
  });
  host.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    port = undefined;
    for (const id of connected) void disconnect(id);
  });
}
chrome.action.onClicked.addListener(async tab => {
  if (connected.has(tab.id)) return disconnect(tab.id);
  try {
    if (!allowed(tab.url)) throw new Error('Only HTTP(S) tabs can connect');
    await chrome.debugger.attach({tabId: tab.id}, '1.3');
    connected.add(tab.id);
    connectHost();
    await chrome.action.setBadgeText({tabId: tab.id, text: 'ON'});
    await chrome.action.setBadgeBackgroundColor({tabId: tab.id, color: '#059669'});
  } catch (error) {
    await disconnect(tab.id);
    await chrome.action.setTitle({tabId: tab.id, title: `Graff: ${error.message}`});
  }
});
chrome.debugger.onDetach.addListener(({tabId}) => {
  connected.delete(tabId);
  void chrome.action.setBadgeText({tabId, text: ''}).catch(() => {});
});
chrome.tabs.onRemoved.addListener(id => connected.delete(id));
chrome.tabs.onUpdated.addListener((id, change) => {
  if (connected.has(id) && (change.status === 'loading' || change.url)) void disconnect(id);
});

export async function execute({name, arguments: args = {}}) {
  if (name === 'chrome_tabs') {
    return Promise.all([...connected].map(async id => {
      const tab = await chrome.tabs.get(id);
      return {id, title: tab.title, url: tab.url};
    }));
  }
  const id = args.tabId;
  if (!Number.isInteger(id) || !connected.has(id)) throw new Error('Tab is not connected; click the Graff extension on that tab');
  if (!allowed((await chrome.tabs.get(id)).url)) throw new Error('Unsupported page');
  switch (name) {
    case 'chrome_snapshot':
      return command(id, 'Accessibility.getFullAXTree');
    case 'chrome_screenshot':
      return command(id, 'Page.captureScreenshot', {format: 'jpeg', quality: 60});
    case 'chrome_click': {
      if (![args.x, args.y].every(v => Number.isFinite(v) && v >= 0)) throw new Error('Expected nonnegative viewport coordinates');
      await command(id, 'Input.dispatchMouseEvent', {type: 'mousePressed', x: args.x, y: args.y, button: 'left', clickCount: 1});
      return command(id, 'Input.dispatchMouseEvent', {type: 'mouseReleased', x: args.x, y: args.y, button: 'left', clickCount: 1});
    }
    case 'chrome_type':
      if (typeof args.text !== 'string' || args.text.length > 10000) throw new Error('Text must be at most 10000 characters');
      return command(id, 'Input.insertText', {text: args.text});
    case 'chrome_scroll':
      if (![args.x, args.y, args.deltaY].every(Number.isFinite) || Math.abs(args.deltaY) > 10000) throw new Error('Invalid scroll coordinates or delta');
      return command(id, 'Input.dispatchMouseEvent', {type: 'mouseWheel', x: args.x, y: args.y, deltaX: 0, deltaY: args.deltaY});
    default: throw new Error('Unknown tool');
  }
}
