// Bundled with Bun for the packaged main process; Electron remains external.
// electron-updater parses app.getVersion() as semver, which rejects 0.0.X.Y.
// Map only that read so the UI and Info.plist can keep the graff version.
const { toSemver } = require('./update-version.cjs');
try {
  const { app } = require('electron');
  if (typeof app.getVersion === 'function' && !app.__graffVersionMapped) {
    const real = app.getVersion.bind(app);
    app.getVersion = () => {
      try { return toSemver(real()); } catch { return real(); }
    };
    app.__graffVersionMapped = true;
  }
} catch {
  // Tests and non-Electron loads still export autoUpdater.
}
module.exports = require('electron-updater').autoUpdater;
