// Observe macOS activation/window state around a real test command (#832).
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
if (process.platform !== 'darwin') throw Error('Desktop focus acceptance observer currently requires macOS.');
if (process.env.GRAFF_ELECTRON_FOREGROUND === '1' || process.env.GRAFF_TEST_FOREGROUND === '1') {
  throw Error('Focus acceptance requires a non-activating mode. Unset GRAFF_ELECTRON_FOREGROUND.');
}
const temporary = mkdtempSync(path.join(tmpdir(), 'graff-focus-observer-'));
try {
  const observer = path.join(temporary, 'observer');
  const compiled = spawnSync('xcrun', ['swiftc', path.join(root, 'scripts/check-desktop-focus.swift'), '-o', observer], { stdio: 'inherit' });
  if (compiled.error) throw compiled.error;
  if (compiled.status !== 0) throw Error('Could not build macOS focus observer.');
  const command = process.argv.slice(2);
  const child = spawnSync(observer, [root, ...(command.length ? command : [process.execPath, 'scripts/test-visual.mjs'])], { cwd: root, stdio: 'inherit' });
  if (child.error) throw child.error;
  process.exitCode = child.status ?? 1;
} finally { rmSync(temporary, { recursive: true, force: true }); }
