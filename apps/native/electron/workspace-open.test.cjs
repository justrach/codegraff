const { test, expect } = require('bun:test');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { EventEmitter } = require('node:events');
const { workspaceOpen, workspaceTarget } = require('./workspace-open.cjs');
const { claimDesktopInstance } = require('./single-instance.cjs');

test('workspace handoff validates paths and waits for restoration, including reload', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-path-'));
  try {
    const file = path.join(root, 'hello world.txt'); fs.writeFileSync(file, 'hello');
    const canonical = fs.realpathSync(root), received = [], queue = workspaceOpen(value => received.push(value));
    expect(queue.open(root)).toBe(true); expect(received).toEqual([]);
    expect(queue.open(file)).toBe(true); queue.ready();
    expect(received).toEqual([{ cwd: canonical, file: 'hello world.txt' }]);
    queue.ready(); expect(received.length).toBe(1);
    queue.loading(); queue.open(root); expect(received.length).toBe(1);
    queue.ready(); expect(received.at(-1)).toEqual({ cwd: canonical });
    for (const bad of ['relative', '/missing/folder', null, {}, root + '\0', '/' + 'x'.repeat(4097)]) expect(workspaceTarget(bad)).toBe(null);
    fs.symlinkSync(root, path.join(root, 'alias')); expect(workspaceTarget(path.join(root, 'alias'))).toEqual({ cwd: canonical });
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('single-instance sends the exact path and delivers startup, second-launch and Finder requests', () => {
  const app = new EventEmitter(), received = []; let data;
  app.requestSingleInstanceLock = value => { data = value; return true; };
  const value = '/project with spaces/"$(literal)"';
  expect(claimDesktopInstance(app, () => undefined, target => received.push(target), value)).toBe(true);
  expect(data).toEqual({ openPath: value });
  app.emit('second-instance', {}, ['untrusted Chromium argument order'], '/wrong', { openPath: '/next' });
  let prevented = false; app.emit('open-file', { preventDefault() { prevented = true; } }, '/file');
  expect(received).toEqual([value, '/next', '/file']); expect(prevented).toBe(true);
  app.requestSingleInstanceLock = () => false;
  expect(claimDesktopInstance(app, () => undefined, () => { throw Error('secondary must not open locally'); }, value)).toBe(false);
});
