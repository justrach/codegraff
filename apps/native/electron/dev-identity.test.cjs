const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Execute the real main entrypoint through profile selection and lock acquisition.
// Defer app.whenReady so this needs no display or running Electron instance.
function boot(development) {
  const state = {};
  const app = {
    setName(name) { state.name = name; },
    getPath(key) { return key === 'appData' ? '/app-data' : '/home'; },
    setPath(key, value) { state[key] = value; },
    on() {},
    whenReady() { return new Promise(() => {}); },
  };
  const source = fs.readFileSync(path.join(__dirname, 'main.cjs'), 'utf8');
  const load = name => {
    if (name === 'electron') return { app };
    if (name === 'node:fs') return { existsSync: file => development && file === '/resources/codegraff-development' };
    if (name.startsWith('node:')) return require(name);
    if (name === './workspace-open.cjs') return { workspaceOpen: () => ({ open() {} }) };
    if (name === './single-instance.cjs') return { claimDesktopInstance() { state.profileAtLock = state.userData; return true; } };
    return {};
  };
  const run = vm.runInNewContext(`(function(require) { ${source}\n})`, {
    process: { env: {}, resourcesPath: '/resources', on() {} }, console,
  });
  run(load);
  return state;
}

test('dev and installed startup acquire their locks under distinct profiles', () => {
  const dev = boot(true);
  const release = boot(false);
  assert.equal(dev.name, 'Codegraff Dev');
  assert.equal(dev.profileAtLock, '/app-data/Codegraff Dev');
  assert.equal(release.name, 'Codegraff');
  assert.equal(release.profileAtLock, '/app-data/Codegraff Electron');
  assert.notEqual(dev.profileAtLock, release.profileAtLock);
});
