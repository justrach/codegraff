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
  expect(fs.readFileSync(PRELOAD, 'utf8')).toContain('DOMContentLoaded');
  const gallery = fs.readFileSync(path.join(__dirname, 'gallery-fixture.cjs'), 'utf8');
  expect(gallery).toContain('__GRAFF_GALLERY__');
  expect(gallery).not.toContain("Object.defineProperty(window, 'fetch'");
  expect(fs.readFileSync(path.join(__dirname, 'chat-overflow-visual.cjs'), 'utf8')).toContain('attachTestDebugger');
  expect(fs.readFileSync(path.join(__dirname, 'chat-overflow-visual.cjs'), 'utf8')).not.toContain("wc.debugger.attach('1.3')");
  expect(installOnboardingSeed.toString()).not.toMatch(/debugger\s*\.\s*attach/);
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

function gallerySandbox({ storage } = {}) {
  const native = async () => { throw new Error('native fetch must not run for /api'); };
  const store = new Map();
  const sandbox = {
    window: { fetch: native, galleryBenchmark: false },
    document: { documentElement: { dataset: {} }, readyState: 'complete', addEventListener() {} },
    localStorage: storage ?? {
      setItem(key, value) { store.set(key, value); },
      getItem(key) { return store.get(key) ?? null; },
    },
    navigator: { sendBeacon() { return false; } },
    location: { origin: 'http://127.0.0.1:1' },
    Response, Request, URL, TextEncoder, ReadableStream,
  };
  const vm = require('node:vm');
  vm.createContext(sandbox);
  vm.runInContext(`(${require('./gallery-fixture.cjs').installGalleryFixture.toString()})()`, sandbox);
  return sandbox;
}

test('gallery fixture installs fetch even when document-start storage throws', async () => {
  const sandbox = gallerySandbox({
    storage: {
      setItem() { throw new Error('SecurityError: Access is denied for this document.'); },
      getItem() { throw new Error('SecurityError: Access is denied for this document.'); },
    },
  });
  expect(sandbox.window.__GRAFF_GALLERY__).toBe(true);
  expect(sandbox.window.__GRAFF_ONBOARDED__).toBe(true);
  const acp = await (await sandbox.window.fetch('/api/acp', { method: 'GET', cache: 'no-store' })).json();
  expect(acp).toEqual({ ok: true, cwd: '/demo/field-notes', home: '/demo' });
  const viaRequest = await (await sandbox.window.fetch(new Request('http://127.0.0.1:1/api/acp', { method: 'GET' }))).json();
  expect(viaRequest.ok).toBe(true);
  const bootstrap = await (await sandbox.window.fetch(new Request('http://127.0.0.1:1/api/acp', {
    method: 'POST',
    body: JSON.stringify({ method: 'bootstrap' }),
  }))).json();
  expect(bootstrap.sessionId).toBe('demo');
});

test('gallery fixture assignment wraps stay visible to later suites', async () => {
  const sandbox = gallerySandbox();
  const previous = sandbox.window.fetch;
  let seen = 0;
  sandbox.window.fetch = async (input, options) => {
    seen += 1;
    return previous(input, options);
  };
  const wrapped = await (await sandbox.window.fetch('/api/acp', { method: 'GET', cache: 'no-store' })).json();
  expect(wrapped.ok).toBe(true);
  expect(seen).toBe(1);
});

test('window creation registers the preload and does not attach the debugger', () => {
  const attached = [];
  installOnboardingSeed({
    webContents: {
      debugger: {
        isAttached: () => false,
        attach() { attached.push('attach'); },
        sendCommand() { attached.push('send'); return Promise.resolve({}); },
      },
      session: {
        registerPreloadScript() { return PRELOAD_ID; },
        getPreloadScripts() { return []; },
      },
    },
  });
  expect(attached).toEqual([]);
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
