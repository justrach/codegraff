const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { mainWindowChrome, revealWindowButtons } = require('./window-chrome.cjs');

test('macOS keeps the inset titlebar and Linux uses system decorations', () => {
  const mac = mainWindowChrome({ platform: 'darwin', liveGlass: true, title: 'Codegraff' });
  assert.equal(mac.titleBarStyle, 'hiddenInset');
  assert.equal(mac.transparent, true);
  assert.deepEqual(mac.trafficLightPosition, { x: 14, y: 11 });
  const linux = mainWindowChrome({ platform: 'linux', liveGlass: true, title: 'Codegraff' });
  assert.equal(linux.titleBarStyle, undefined);
  assert.equal(linux.transparent, undefined);
  assert.equal(linux.trafficLightPosition, undefined);
  assert.equal(linux.backgroundColor, '#fafaf9');
  const calls = [];
  revealWindowButtons({ setWindowButtonVisibility: () => calls.push('shown') }, 'linux');
  assert.deepEqual(calls, []);
  revealWindowButtons({ setWindowButtonVisibility: () => calls.push('shown') }, 'darwin');
  assert.deepEqual(calls, ['shown']);
});

test('the main process does not call the macOS window-button API on its own', () => {
  const source = fs.readFileSync(path.join(__dirname, 'main.cjs'), 'utf8');
  assert.match(source, /revealWindowButtons/);
  assert.equal(source.includes('setWindowButtonVisibility'), false);
  assert.match(source, /visible: process\.platform === 'darwin'/);
  assert.match(source, /process\.platform === 'linux'/);
});
