const { test, expect } = require('bun:test');
const { testWindowMode, presentWindow, testWindowOptions } = require('./test-window.cjs');

test('default GUI tests stay hidden and never steal focus (#832)', () => {
  const previous = process.env.GRAFF_TEST_FOREGROUND;
  const visible = process.env.GRAFF_ELECTRON_VISIBLE;
  delete process.env.GRAFF_TEST_FOREGROUND;
  delete process.env.GRAFF_ELECTRON_VISIBLE;
  expect(testWindowMode()).toBe('hidden');
  expect(testWindowOptions({ width: 10 }).show).toBe(false);
  const calls = [];
  presentWindow({ show() { calls.push('show'); }, focus() { calls.push('focus'); }, showInactive() { calls.push('inactive'); }, webContents: { isDestroyed: () => false, setBackgroundThrottling() {} } }, { focus() { calls.push('steal'); } });
  expect(calls).toEqual([]);
  process.env.GRAFF_TEST_FOREGROUND = previous;
  process.env.GRAFF_ELECTRON_VISIBLE = visible;
});

test('foreground interaction is an explicit opt-in', () => {
  const previous = process.env.GRAFF_TEST_FOREGROUND;
  process.env.GRAFF_TEST_FOREGROUND = '1';
  expect(testWindowMode()).toBe('foreground');
  const calls = [];
  presentWindow({ show() { calls.push('show'); }, focus() { calls.push('focus'); }, showInactive() { calls.push('inactive'); }, webContents: { isDestroyed: () => true } }, { focus() { calls.push('steal'); } });
  expect(calls).toEqual(['steal', 'show', 'focus']);
  process.env.GRAFF_TEST_FOREGROUND = previous;
});

test('mapped BrowserView fixtures cannot make hidden windows visible', () => {
  const previous = process.env.GRAFF_TEST_FOREGROUND;
  const visible = process.env.GRAFF_ELECTRON_VISIBLE;
  delete process.env.GRAFF_TEST_FOREGROUND;
  delete process.env.GRAFF_ELECTRON_VISIBLE;
  const calls = [];
  expect(presentWindow({ show() { calls.push('show'); }, focus() { calls.push('focus'); }, showInactive() { calls.push('inactive'); }, webContents: { isDestroyed: () => false, setBackgroundThrottling() {} } }, { focus() { calls.push('steal'); } }, { mapped: true })).toBe('hidden');
  expect(calls).toEqual([]);
  process.env.GRAFF_TEST_FOREGROUND = previous;
  process.env.GRAFF_ELECTRON_VISIBLE = visible;
});
