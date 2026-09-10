// Only normal web links can leave the app; never hand arbitrary schemes to the OS.
function externalURL(raw) {
  try { const url = new URL(raw); return ['https:', 'http:'].includes(url.protocol) && !url.username && !url.password ? url.href : null; }
  catch { return null; }
}
function installExternalLinks(contents, origin, open = url => require('electron').shell.openExternal(url)) {
  const internal = raw => { try { return new URL(raw).origin === origin; } catch { return false; } };
  const launch = raw => {
    const url = externalURL(raw);
    if (!url || internal(url)) return;
    try { void Promise.resolve(open(url)).catch(() => {}); } catch { /* A failed destination must not navigate the app. */ }
  };
  contents.on('will-navigate', (event, url) => {
    if (externalURL(url) && internal(url)) return;
    event.preventDefault(); launch(url);
  });
  contents.setWindowOpenHandler(({ url }) => { launch(url); return { action: 'deny' }; });
}
module.exports = { externalURL, installExternalLinks };
