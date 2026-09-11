import {runElectron} from './test-electron.mjs';
await runElectron('electron/browser-resource-probe.cjs',process.argv.slice(2));
