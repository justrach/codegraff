import { runElectron } from './test-electron.mjs';
await runElectron('electron/performance-benchmark.cjs', process.argv.slice(2));
