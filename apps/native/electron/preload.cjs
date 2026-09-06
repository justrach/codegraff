const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('graffDesktop', {
  browser: (chat, method, params) => ipcRenderer.invoke('browser', { chat, method, params }),
  activity: () => ipcRenderer.invoke('activity'),
  subscribe: callback => {
    const listener = (_event, message) => callback(message);
    ipcRenderer.on('browser-event', listener);
    return () => ipcRenderer.removeListener('browser-event', listener);
  },
});

let longTasks;
ipcRenderer.on('profile-enabled', (_event, enabled) => {
  longTasks?.disconnect();
  if (!enabled) return;
  longTasks = new PerformanceObserver(list => {
    for (const entry of list.getEntries()) ipcRenderer.send('profile-longtask', entry.duration);
  });
  longTasks.observe({ type: 'longtask', buffered: false });
});

// Native web views sit above HTML, so app dialogs need their page temporarily hidden.
window.addEventListener('DOMContentLoaded', () => {
  const selector = '[role="dialog"],[role="menu"],[role="listbox"]';
  const overlays = new Set(document.querySelectorAll(selector));
  let scheduled = false, previous = false;
  const update = () => {
    scheduled = false;
    for (const element of overlays) if (!element.isConnected || !element.matches(selector)) overlays.delete(element);
    const blocked = [...overlays].some(element => element.checkVisibility());
    if (blocked !== previous) { previous = blocked; ipcRenderer.send('browser-overlay', blocked); }
  };
  new MutationObserver(records => {
    for (const record of records) {
      if (record.type === 'attributes' && record.target.matches(selector)) overlays.add(record.target);
      for (const node of record.addedNodes) if (node instanceof Element) {
        if (node.matches(selector)) overlays.add(node);
        for (const element of node.querySelectorAll(selector)) overlays.add(element);
      }
    }
    // Streaming text changes never rescan the entire growing transcript.
    if (!scheduled && (overlays.size || previous)) { scheduled = true; queueMicrotask(update); }
  }).observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['hidden', 'aria-hidden', 'role'] });
  update();
});
