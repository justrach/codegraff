import { runElectron } from './test-electron.mjs';
const ready = process.env.GRAFF_TEST_FOREGROUND === '1'
  || await runElectron('electron/background-regression.cjs') === 0;
if (ready) await runElectron('electron/visual-tests.cjs');
