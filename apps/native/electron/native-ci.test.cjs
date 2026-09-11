const { test, expect } = require('bun:test');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const { validateCoverage } = require('../scripts/check-native-ci.mjs');

test('the native CI launcher cannot activate a local desktop without explicit opt-in', () => {
  for (const flags of [{}, { GRAFF_ELECTRON_VISIBLE: '1' }]) {
    const env = { ...process.env, GRAFF_TEST_FOREGROUND: '', GRAFF_ELECTRON_FOREGROUND: '', ...flags };
    const result = spawnSync(process.execPath, [path.join(__dirname, '../scripts/test-native.mjs')], { env, encoding: 'utf8', timeout: 5000 });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('Native GUI tests require GRAFF_ELECTRON_FOREGROUND=1');
    expect(result.stdout).not.toContain('Electron tests:');
  }
});

test('native CI rejects missing reports, background passes and skipped fullscreen checks', () => {
  const native = { status: 'passed' }, visual = { mode: 'foreground', status: 'passed' }, stress = { fullscreen: 'passed' };
  expect(() => validateCoverage(native, visual, stress)).not.toThrow();
  for (const reports of [
    [null, visual, stress], [native, null, stress], [native, visual, null],
    [{ status: 'failed' }, visual, stress], [native, { ...visual, mode: 'hidden' }, stress],
    [native, { ...visual, status: 'passed-with-skips' }, stress], [native, visual, { fullscreen: 'not run' }],
  ]) expect(() => validateCoverage(...reports)).toThrow();
  expect(() => validateCoverage({ status: 'passed-with-skips', skipped: ['OS permission unavailable'] }, visual, stress)).not.toThrow();
});
