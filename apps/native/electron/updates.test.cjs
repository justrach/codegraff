const { test, expect } = require('bun:test');
const { EventEmitter } = require('node:events');
const { createUpdates } = require('./updates.cjs');
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
