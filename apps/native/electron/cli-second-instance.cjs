require('./test-desktop.cjs');
const { app } = require('electron');
app.setPath('userData', process.argv[2]);
const owned = require('./single-instance.cjs').claimDesktopInstance(app, () => undefined, () => {}, process.argv[3]);
app.exit(owned ? 1 : 0);
