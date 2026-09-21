const { test, expect } = require('bun:test');
const fs = require('node:fs');
const path = require('node:path');
const { ONBOARDING_DISMISSED, ONBOARDING_KEY, PAGE_SEED, PRELOAD, installOnboardingSeed } = require('./test-onboarding.cjs');

test('the production seed writes the same dismissed flag the app persists', () => {
  expect(ONBOARDING_KEY).toBe('graff.onboarding.dismissed');
  expect(ONBOARDING_DISMISSED).toBe('true');
  expect(fs.readFileSync(PRELOAD, 'utf8')).toContain(`localStorage.setItem('${ONBOARDING_KEY}', '${ONBOARDING_DISMISSED}')`);
  expect(fs.readFileSync(path.join(__dirname, 'gallery-fixture.cjs'), 'utf8'))
    .toContain(`localStorage.setItem('${ONBOARDING_KEY}', '${ONBOARDING_DISMISSED}')`);
  expect(PAGE_SEED).toContain('__GRAFF_ONBOARDED__');
  expect(fs.readFileSync(path.join(__dirname, 'gallery-fixture.cjs'), 'utf8')).toContain('__GRAFF_ONBOARDED__');
});

test('windows without a session are left alone', () => {
  expect(() => installOnboardingSeed({})).not.toThrow();
  expect(() => installOnboardingSeed({ webContents: {} })).not.toThrow();
});
