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
