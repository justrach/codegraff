const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { mainWindowChrome, revealWindowButtons } = require('./window-chrome.cjs');

test('macOS keeps the inset titlebar and Windows and Linux use system decorations', () => {
  const mac = mainWindowChrome({ platform: 'darwin', liveGlass: true, title: 'Codegraff' });
  assert.equal(mac.titleBarStyle, 'hiddenInset');
  assert.equal(mac.transparent, true);
  assert.deepEqual(mac.trafficLightPosition, { x: 14, y: 11 });
  for (const platform of ['linux', 'win32']) {
    const chrome = mainWindowChrome({ platform, liveGlass: true, title: 'Codegraff' });
    assert.equal(chrome.titleBarStyle, undefined);
    assert.equal(chrome.transparent, undefined);
    assert.equal(chrome.trafficLightPosition, undefined);
    assert.equal(chrome.frame, undefined, 'Electron keeps native minimize/maximize/close controls');
    assert.equal(chrome.backgroundColor, '#fafaf9');
  }
  const calls = [];
  revealWindowButtons({ setWindowButtonVisibility: () => calls.push('shown') }, 'linux');
  assert.deepEqual(calls, []);
  revealWindowButtons({ setWindowButtonVisibility: () => calls.push('shown') }, 'darwin');
  assert.deepEqual(calls, ['shown']);
});

test('missing or unavailable window-button APIs do not prevent launch', () => {
  for (const platform of ['darwin', 'linux', 'win32']) {
    assert.doesNotThrow(() => revealWindowButtons({}, platform));
    assert.doesNotThrow(() => revealWindowButtons({ setWindowButtonVisibility: null }, platform));
    assert.doesNotThrow(() => revealWindowButtons({ setWindowButtonVisibility() { throw Error('unsupported'); } }, platform));
  }
});

test('the main process does not call the macOS window-button API on its own', () => {
  const source = fs.readFileSync(path.join(__dirname, 'main.cjs'), 'utf8');
  assert.match(source, /revealWindowButtons/);
  assert.equal(source.includes('setWindowButtonVisibility'), false);
  assert.match(source, /visible: process\.platform === 'darwin'/);
  assert.match(source, /process\.platform === 'linux'/);
});
