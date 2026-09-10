const { test, expect } = require('bun:test');
const { testWindowMode, presentWindow, testWindowOptions } = require('./test-window.cjs');

test('default GUI tests stay hidden and never steal focus (#832)', () => {
  const previous = process.env.GRAFF_ELECTRON_FOREGROUND;
  const visible = process.env.GRAFF_ELECTRON_VISIBLE;
  delete process.env.GRAFF_ELECTRON_FOREGROUND;
  delete process.env.GRAFF_ELECTRON_VISIBLE;
  expect(testWindowMode()).toBe('hidden');
  expect(testWindowOptions({ width: 10 }).show).toBe(false);
  const calls = [];
  presentWindow({ show() { calls.push('show'); }, focus() { calls.push('focus'); }, showInactive() { calls.push('inactive'); }, webContents: { isDestroyed: () => false, setBackgroundThrottling() {} } }, { focus() { calls.push('steal'); } });
  expect(calls).toEqual([]);
  process.env.GRAFF_ELECTRON_FOREGROUND = previous;
  process.env.GRAFF_ELECTRON_VISIBLE = visible;
});

test('foreground interaction is an explicit opt-in', () => {
  const previous = process.env.GRAFF_ELECTRON_FOREGROUND;
  process.env.GRAFF_ELECTRON_FOREGROUND = '1';
  expect(testWindowMode()).toBe('foreground');
  const calls = [];
  presentWindow({ show() { calls.push('show'); }, focus() { calls.push('focus'); }, showInactive() { calls.push('inactive'); }, webContents: { isDestroyed: () => true } }, { focus() { calls.push('steal'); } });
  expect(calls).toEqual(['steal', 'show', 'focus']);
  process.env.GRAFF_ELECTRON_FOREGROUND = previous;
});

test('mapped presentWindow shows inactive so a BrowserView host can measure', () => {
  const previous = process.env.GRAFF_ELECTRON_FOREGROUND;
  const visible = process.env.GRAFF_ELECTRON_VISIBLE;
  delete process.env.GRAFF_ELECTRON_FOREGROUND;
  delete process.env.GRAFF_ELECTRON_VISIBLE;
  const calls = [];
  expect(presentWindow({ show() { calls.push('show'); }, focus() { calls.push('focus'); }, showInactive() { calls.push('inactive'); }, webContents: { isDestroyed: () => false, setBackgroundThrottling() {} } }, { focus() { calls.push('steal'); } }, { mapped: true })).toBe('visible');
  expect(calls).toEqual(['inactive']);
  process.env.GRAFF_ELECTRON_FOREGROUND = previous;
  process.env.GRAFF_ELECTRON_VISIBLE = visible;
});
