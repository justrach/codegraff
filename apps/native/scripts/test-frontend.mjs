import { runElectron } from './test-electron.mjs';
import { createRequire } from 'node:module';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
const { testWindowMode } = createRequire(import.meta.url)('../electron/test-window.cjs');
if (process.env.GRAFF_FRONTEND_OS_INPUT === '1' && testWindowMode() !== 'foreground') {
  throw Error('Native front-end input requires GRAFF_ELECTRON_FOREGROUND=1 on an isolated desktop.');
}
const temp = mkdtempSync(path.join(tmpdir(), 'graff-frontend-'));
process.env.GRAFF_TEST_TIMEOUT_MS ??= '120000';
try { await runElectron('electron/frontend-runtime.cjs', [temp]); }
finally { rmSync(temp, { force: true, recursive: true }); }
