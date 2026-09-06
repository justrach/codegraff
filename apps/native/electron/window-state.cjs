// Native fullscreen owns its title area; do not reserve the windowed drag strip.
function installWindowState(win) {
  const publish = () => {
    if (!win.isDestroyed()) win.webContents.send('window-state', { fullscreen: win.isFullScreen() });
  };
  win.on('enter-full-screen', publish);
  win.on('leave-full-screen', publish);
  win.webContents.on('did-finish-load', publish);
}
module.exports = { installWindowState };
