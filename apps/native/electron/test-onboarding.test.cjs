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
  expect(PAGE_SEED).toContain('dataset.graffOnboarded');
  expect(fs.readFileSync(path.join(__dirname, 'gallery-fixture.cjs'), 'utf8')).toContain('__GRAFF_ONBOARDED__');
  expect(fs.readFileSync(path.join(__dirname, 'gallery-fixture.cjs'), 'utf8')).toContain('dataset.graffOnboarded');
  expect(fs.readFileSync(PRELOAD, 'utf8')).toContain('dataset.graffOnboarded');
});

test('windows without a session are left alone', () => {
  expect(() => installOnboardingSeed({})).not.toThrow();
  expect(() => installOnboardingSeed({ webContents: {} })).not.toThrow();
});

test('production chrome never mounts the welcome sheet once fixtures mark the page onboarded', () => {
  const chrome = fs.readFileSync(path.join(__dirname, '../components/site/AccountChrome.tsx'), 'utf8');
  expect(chrome).toContain('showOnboarding && <OnboardingDialog');
  expect(chrome).toContain('requested || autoOnboarding');
  expect(fs.readFileSync(path.join(__dirname, '../app/layout.tsx'), 'utf8')).toContain('OnboardingFixtureSeed');
  expect(fs.readFileSync(path.join(__dirname, '../components/site/OnboardingDialog.tsx'), 'utf8')).not.toContain('testAlreadyOnboarded');
  expect(fs.readFileSync(path.join(__dirname, 'frontend-runtime.cjs'), 'utf8')).not.toContain('installPageWorldOnboardingSeed');
});
