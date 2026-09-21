const { test, expect } = require('bun:test');
const fs = require('node:fs');
const path = require('node:path');
const { ONBOARDING_DISMISSED, ONBOARDING_KEY, PAGE_SEED, PRELOAD, PRELOAD_ID, installOnboardingSeed } = require('./test-onboarding.cjs');

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
  expect(fs.readFileSync(PRELOAD, 'utf8')).toContain('executeInMainWorld');
});

test('windows without a session are left alone', () => {
  expect(() => installOnboardingSeed({})).not.toThrow();
  expect(() => installOnboardingSeed({ webContents: {} })).not.toThrow();
});

test('Electron 44 registers the page-world seed without replacing session preloads', () => {
  const registered = [];
  installOnboardingSeed({
    webContents: {
      session: {
        registerPreloadScript(script) { registered.push(script); return script.id; },
        getPreloadScripts() { return registered; },
      },
    },
  });
  installOnboardingSeed({
    webContents: {
      session: {
        registerPreloadScript(script) { registered.push(script); return script.id; },
        getPreloadScripts() { return registered; },
      },
    },
  });
  expect(registered).toEqual([{ type: 'frame', id: PRELOAD_ID, filePath: PRELOAD }]);
});

test('gallery fixture still answers ACP health after fetch is replaced', async () => {
  const vm = require('node:vm');
  const { installGalleryFixture } = require('./gallery-fixture.cjs');
  const native = async () => { throw new Error('native fetch must not run for /api'); };
  const store = new Map();
  const sandbox = {
    window: { fetch: native, galleryBenchmark: false },
    document: { documentElement: { dataset: {} } },
    localStorage: { setItem(key, value) { store.set(key, value); }, getItem(key) { return store.get(key) ?? null; } },
    navigator: { sendBeacon() { return false; } },
    location: { origin: 'http://127.0.0.1:1' },
    Response, Request, URL, TextEncoder, ReadableStream,
  };
  vm.createContext(sandbox);
  vm.runInContext(`(${installGalleryFixture.toString()})()`, sandbox);
  sandbox.window.fetch = native;
  const acp = await (await sandbox.window.fetch('/api/acp', { method: 'GET', cache: 'no-store' })).json();
  expect(acp).toEqual({ ok: true, cwd: '/demo/field-notes', home: '/demo' });
  const viaRequest = await (await sandbox.window.fetch(new Request('http://127.0.0.1:1/api/acp', { method: 'GET' }))).json();
  expect(viaRequest.ok).toBe(true);
  const account = await (await sandbox.window.fetch('/api/account')).json();
  expect(account.signedIn).toBe(false);
  const captured = sandbox.window.fetch;
  sandbox.window.fetch = (input, options) => captured(input, options);
  const wrapped = await (await sandbox.window.fetch('/api/acp', { method: 'GET', cache: 'no-store' })).json();
  expect(wrapped.ok).toBe(true);
  const bootstrap = await (await sandbox.window.fetch(new Request('http://127.0.0.1:1/api/acp', {
    method: 'POST',
    body: JSON.stringify({ method: 'bootstrap' }),
  }))).json();
  expect(bootstrap.sessionId).toBe('demo');
});

test('production chrome never mounts the welcome sheet once fixtures mark the page onboarded', () => {
  const chrome = fs.readFileSync(path.join(__dirname, '../components/site/AccountChrome.tsx'), 'utf8');
  expect(chrome).toContain('showOnboarding && <OnboardingDialog');
  expect(chrome).toContain('requested || autoOnboarding');
  expect(fs.readFileSync(path.join(__dirname, '../app/layout.tsx'), 'utf8')).toContain('OnboardingFixtureSeed');
  expect(fs.readFileSync(path.join(__dirname, '../components/site/OnboardingFixtureSeed.tsx'), 'utf8')).not.toContain('next/server');
  expect(fs.readFileSync(path.join(__dirname, '../components/site/OnboardingDialog.tsx'), 'utf8')).not.toContain('testAlreadyOnboarded');
  expect(fs.readFileSync(path.join(__dirname, 'frontend-runtime.cjs'), 'utf8')).not.toContain('installPageWorldOnboardingSeed');
});
