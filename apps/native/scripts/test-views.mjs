import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { runDesktopProcess } from './test-electron.mjs';

const home = mkdtempSync(path.join(tmpdir(), 'graff-view-tests-'));
try {
  await runDesktopProcess(process.execPath, ['x', 'playwright', 'test', '-c', 'playwright.views.config.ts'], {
    ...process.env, HOME: home, USERPROFILE: home,
  });
} finally {
  rmSync(home, { recursive: true, force: true });
}
