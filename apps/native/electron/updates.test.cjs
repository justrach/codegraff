const { test, expect } = require('bun:test');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createUpdates, updateAvailability } = require('./updates.cjs');
function fixture(options = {}) {
  const updater = new EventEmitter(), events = [], saved = [];
  let checks = 0, installs = 0;
  updater.checkForUpdates = async () => { checks++; updater.emit('checking-for-update'); return null; };
  updater.quitAndInstall = () => { installs++; };
  const updates = createUpdates({ updater, version: '1.0.0', notify: state => events.push(state), save: value => saved.push(value), ...options });
  return { updater, updates, events, saved, checks: () => checks, installs: () => installs };
}
test('downloads in the background but never interrupts a running task automatically', async () => {
  const f = fixture();
  await f.updates.check();
  f.updater.emit('update-available', { version: '1.0.1' });
  f.updater.emit('download-progress', { percent: 34.9 });
  expect(f.updates.state().percent).toBe(34);
  f.updater.emit('update-downloaded', { version: '1.0.1' });
  await f.updates.check();
  expect(f.checks()).toBe(1);
  expect(f.installs()).toBe(0);
  expect(f.updater.autoInstallOnAppQuit).toBe(false);
  expect(f.updater.allowDowngrade).toBe(false);
  expect(f.updater.allowPrerelease).toBe(false);
  f.updates.restart();
  expect(f.installs()).toBe(1);
  expect(f.updates.state().status).toBe('installing');
});
test('development and disk-image builds do not make update requests', async () => {
  const f = fixture({ available: false });
  await f.updates.check(true);
  expect(f.checks()).toBe(0);
  expect(f.updates.state().status).toBe('unavailable');
  expect(() => f.updates.restart()).toThrow('No downloaded update');
});
test('offline checks recover and do not expose raw request details in the UI', async () => {
  const f = fixture();
  f.updater.checkForUpdates = async () => { throw Error('private request context'); };
  await f.updates.check(true);
  expect(f.updates.state().status).toBe('error');
  expect(f.updates.state().message).not.toContain('private');
  f.updater.checkForUpdates = async () => { f.updater.emit('update-not-available'); };
  await f.updates.check(true);
  expect(f.updates.state().status).toBe('current');
});
test('a failed background download is handled and never becomes installable', async () => {
  const f = fixture();
  f.updater.checkForUpdates = async () => ({ downloadPromise: Promise.reject(Error('checksum mismatch')) });
  await f.updates.check(true);
  await Promise.resolve();
  expect(f.updates.state().status).toBe('error');
  expect(() => f.updates.restart()).toThrow();
  expect(f.installs()).toBe(0);
});
test('concurrent checks are coalesced and automatic-download preference persists', async () => {
  const f = fixture(); let finish, calls = 0;
  f.updater.checkForUpdates = () => { calls++; return new Promise(resolve => { finish = resolve; }); };
  const first = f.updates.check();
  await f.updates.check(true);
  expect(calls).toBe(1);
  finish(); await first;
  f.updates.setAutomatic(false);
  expect(f.saved).toEqual([false]);
  expect(f.updates.state().automatic).toBe(false);
});
test('a signed release whose executable is still named Electron can check', async () => {
  // Regression: macOS isPackaged is basename(exe) != "electron", and the
  // distribution bundle keeps the executable named Electron — so the flag is
  // false in signed releases. The signed feed config is the signal instead.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-update-gate-'));
  try {
    const feedPath = path.join(dir, 'app-update.yml');
    fs.writeFileSync(feedPath, JSON.stringify({ provider: 'generic', url: 'https://example.com/' }));
    const gate = { platform: 'darwin', env: {}, execPath: '/Applications/Codegraff.app/Contents/MacOS/Electron', feedPath };
    expect(updateAvailability(gate)).toBe(true);
    expect(updateAvailability({ ...gate, platform: 'linux' })).toBe(false);
    expect(updateAvailability({ ...gate, env: { GRAFF_ELECTRON_SMOKE: '1' } })).toBe(false);
    expect(updateAvailability({ ...gate, execPath: '/Volumes/Codegraff/Codegraff.app/Contents/MacOS/Electron' })).toBe(false);
    expect(updateAvailability({ ...gate, feedPath: path.join(dir, 'missing.yml') })).toBe(false);
    // electron-updater also gates on isPackaged internally; a signed bundle
    // reporting false must be pointed at the signed feed explicitly.
    const configured = fixture({ feedPath });
    const seen = [];
    configured.updater.isUpdaterActive = () => seen.length > 0;
    Object.defineProperty(configured.updater, 'updateConfigPath', { set: value => seen.push(value) });
    createUpdates({ updater: configured.updater, version: '1.0.0', feedPath,
      notify: () => {}, save: () => {} });
    expect(seen).toEqual([feedPath]);
    expect(configured.updater.forceDevUpdateConfig).toBe(true);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
