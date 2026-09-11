import { createRequire } from 'node:module';
const { testWindowMode } = createRequire(import.meta.url)('../electron/test-window.cjs');
import { runElectron } from './test-electron.mjs';
const ready = testWindowMode() !== 'hidden'
  || await runElectron('electron/background-regression.cjs') === 0;
if (ready) await runElectron('electron/visual-tests.cjs');
