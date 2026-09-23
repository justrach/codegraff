function mainWindowChrome({ platform = process.platform, liveGlass = false, title = 'Codegraff' } = {}) {
  const base = { width: 1440, height: 920, minWidth: 900, minHeight: 600, title, show: false };
  if (platform === 'darwin') {
    return {
      ...base,
      titleBarStyle: 'hiddenInset',
      trafficLightPosition: { x: 14, y: 11 },
      transparent: liveGlass,
      backgroundColor: liveGlass ? '#00000000' : '#fafaf9',
    };
  }
  return { ...base, backgroundColor: '#fafaf9' };
}

function revealWindowButtons(win, platform = process.platform) {
  if (platform !== 'darwin' || typeof win.setWindowButtonVisibility !== 'function') return;
  try { win.setWindowButtonVisibility(true); } catch { /* optional native chrome must not prevent launch */ }
}

module.exports = { mainWindowChrome, revealWindowButtons };
