// Only normal web links can leave the app; never hand arbitrary schemes to the OS.
function externalURL(raw) {
  try { const url = new URL(raw); return ['https:', 'http:'].includes(url.protocol) && !url.username && !url.password ? url.href : null; }
  catch { return null; }
}
function installExternalLinks(contents, origin, open = url => require('electron').shell.openExternal(url)) {
  const launch = raw => { const url = externalURL(raw); if (url) void Promise.resolve(open(url)).catch(() => {}); };
  contents.on('will-navigate', (event, url) => {
    if (new URL(url).origin === origin) return;
    event.preventDefault(); launch(url);
  });
  contents.setWindowOpenHandler(({ url }) => { launch(url); return { action: 'deny' }; });
}
module.exports = { externalURL, installExternalLinks };
