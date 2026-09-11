const { test, expect, beforeEach, afterEach } = require('bun:test');
const { EventEmitter } = require('node:events');
const { testWindowMode, presentWindow, testWindowOptions, installTestWindowPolicy, foregroundCheck, visibleWindowCheck } = require('./test-window.cjs');
const keys = ['GRAFF_ELECTRON_FOREGROUND', 'GRAFF_ELECTRON_VISIBLE', 'GRAFF_TEST_FOREGROUND'];
let saved;
beforeEach(() => { saved = keys.map(key => process.env[key]); keys.forEach(key => delete process.env[key]); });
afterEach(() => keys.forEach((key, i) => { if (saved[i] === undefined) delete process.env[key]; else process.env[key] = saved[i]; }));
function fixture() {
  const calls = [];
  const win = new EventEmitter(), app = new EventEmitter();
  for (const method of ['show', 'focus', 'showInactive', 'restore', 'moveTop', 'setFullScreen', 'setSimpleFullScreen', 'setKiosk', 'setFocusable']) win[method] = (...args) => calls.push([method, ...args]);
  win.webContents = { isDestroyed: () => false, setBackgroundThrottling() {} };
  app.focus = () => calls.push(['app.focus']);
  app.setActivationPolicy = policy => calls.push(['policy', policy]);
  app.exit = code => calls.push(['exit', code]);
  return { calls, win, app };
}

test('hidden is the default and constructor overrides cannot opt in (#832)', () => {
  expect(testWindowMode()).toBe('hidden');
  expect(testWindowMode({ GRAFF_ELECTRON_FOREGROUND: 'true' })).toBe('hidden');
  const options = testWindowOptions({ show: true, focusable: true, width: 10, webPreferences: { sandbox: true, backgroundThrottling: true } });
  expect(options).toMatchObject({ show: false, focusable: false, width: 10, webPreferences: { sandbox: true, backgroundThrottling: false } });
  const { calls, win, app } = fixture();
  expect(presentWindow(win, app, { mapped: true })).toBe('hidden');
  expect(calls).toEqual([]);
  expect(foregroundCheck('native input')).toBe(false);
});

test('visible preview is non-focusable and never activates the app', () => {
  process.env.GRAFF_ELECTRON_VISIBLE = '1';
  const { calls, win, app } = fixture();
  expect(testWindowOptions().focusable).toBe(false);
  expect(presentWindow(win, app)).toBe('visible');
  expect(calls).toEqual([['showInactive']]);
  expect(foregroundCheck('native input')).toBe(false);
});

test('only explicit foreground opt-in enables activation and native input', () => {
  process.env.GRAFF_ELECTRON_FOREGROUND = '1';
  process.env.GRAFF_ELECTRON_VISIBLE = '1';
  const { calls, win, app } = fixture();
  expect(testWindowOptions().focusable).toBe(true);
  expect(presentWindow(win, app)).toBe('foreground');
  expect(calls).toEqual([['app.focus'], ['show'], ['focus']]);
  expect(foregroundCheck('native input')).toBe(true);
});

test('process policy blocks bypasses on every window, including later windows', () => {
  const { calls, win, app } = fixture();
  installTestWindowPolicy(app);
  for (const window of [win, fixture().win]) {
    app.emit('browser-window-created', {}, window);
    for (const method of ['show', 'focus', 'showInactive', 'restore', 'moveTop']) expect(() => window[method]()).toThrow('#832');
    for (const method of ['setFullScreen', 'setSimpleFullScreen', 'setKiosk']) expect(() => window[method](true)).toThrow('#832');
    window.setFullScreen(false);
  }
  expect(() => app.focus()).toThrow('#832');
  win.emit('focus'); win.emit('show');
  expect(calls.filter(call => call[0] === 'exit')).toEqual([['exit', 1], ['exit', 1]]);
});

test('packaged native pin check skips before touching browser input without opt-in', async () => {
  const forbidden = new Proxy({}, { get() { throw Error('must not touch native input'); } });
  const { smokeBrowserPin } = require('./smoke-browser-pin.cjs');
  expect(await smokeBrowserPin({ browser: forbidden, win: forbidden })).toMatch(/Skipped/);
  expect(visibleWindowCheck('browser input')).toBe(false);
  process.env.GRAFF_ELECTRON_VISIBLE = '1';
  expect(visibleWindowCheck('browser input')).toBe(true);
  expect(foregroundCheck('OS input')).toBe(false);
});


test('visible mode blocks macOS application activation as well as window focus', () => {
  process.env.GRAFF_ELECTRON_VISIBLE = '1';
  const { calls, win, app } = fixture();
  installTestWindowPolicy(app);
  app.emit('browser-window-created', {}, win);
  presentWindow(win, app);
  if (process.platform === 'darwin') expect(calls).toContainEqual(['policy', 'prohibited']);
  expect(calls).toContainEqual(['setFocusable', false]);
  expect(calls).toContainEqual(['showInactive']);
  expect(() => app.focus()).toThrow('#832');
  expect(() => win.focus()).toThrow('#832');
});
