const { test, expect } = require('bun:test');
const { EventEmitter } = require('node:events');
const { claimDesktopInstance } = require('./single-instance.cjs');

test('a second copy cannot start a separate desktop against the same profile', () => {
  const app = new EventEmitter();
  app.requestSingleInstanceLock = () => false;
  expect(claimDesktopInstance(app, () => { throw Error('must not create a window'); })).toBe(false);
  expect(app.listenerCount('second-instance')).toBe(0);
});

test('reopening the desktop restores the existing window, without starting another backend', () => {
  const app = new EventEmitter(), actions = [];
  app.requestSingleInstanceLock = () => true;
  let win;
  expect(claimDesktopInstance(app, () => win)).toBe(true);
  app.emit('second-instance'); // Starting up: the first window is not ready yet.
  win = { isDestroyed: () => false, isMinimized: () => true,
    restore: () => actions.push('restore'), show: () => actions.push('show'), focus: () => actions.push('focus') };
  app.emit('second-instance');
  expect(actions).toEqual(['restore', 'show', 'focus']);
  app.emit('activate');
  expect(actions.length).toBe(6);
});
