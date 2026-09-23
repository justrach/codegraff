import { createRequire } from 'node:module';
const { testWindowMode } = createRequire(import.meta.url)('../electron/test-window.cjs');
import { runElectron } from './test-electron.mjs';
const visualTestEntry = 'electron/visual-tests.cjs';
if (process.argv[2]) process.env.GRAFF_VISUAL_SUITE = process.argv[2];
const ready = testWindowMode() !== 'hidden'
  || await runElectron('electron/background-regression.cjs') === 0;
if (ready) await runElectron(visualTestEntry);
