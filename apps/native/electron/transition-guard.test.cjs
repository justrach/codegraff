const { test, expect } = require('bun:test');
const { EventEmitter } = require('node:events');
const { confirmTransition, transitionOptions, installTransitionGuard } = require('./transition-guard.cjs');

test('reload and restart preflight can cancel an active turn', async () => {
  const shown = [];
  const dialog = { showMessageBox: async (_win, options) => { shown.push(options); return { response: 1 }; } };
  expect(await confirmTransition({}, dialog, 'Reload', 2)).toBe(false);
  expect(await confirmTransition({}, dialog, 'Restart', 1)).toBe(false);
  expect(shown.map(value => value.title)).toEqual(['Reload Codegraff?', 'Restart Codegraff?']);
  expect(shown[0].detail).toMatch(/interrupt.*turn/);
  expect(shown[0].detail).toMatch(/Open chat tabs.*saved conversation checkpoints/);
  expect(shown[0].defaultId).toBe(1);
  dialog.showMessageBox = async () => ({ response: 0 });
  expect(await confirmTransition({}, dialog, 'Reload', 1)).toBe(true);
  expect(transitionOptions('Reload', 0)).toBe(null);
});

test('renderer active-turn report gates reload and the next unload', async () => {
  const ipcMain = new EventEmitter(), webContents = new EventEmitter();
  let reloads = 0, asyncResponse = 1, syncResponse = 1, prompts = 0;
  webContents.reload = () => { reloads++; };
  const dialog = {
    showMessageBox: async () => { prompts++; return { response: asyncResponse }; },
    showMessageBoxSync: () => { prompts++; return syncResponse; },
  };
  const win = { webContents, isDestroyed: () => false };
  const { preflight, reload } = installTransitionGuard({ win, ipcMain, trusted: () => {}, dialog });
  ipcMain.emit('active-turns', {}, 2);
  await reload();
  expect(reloads).toBe(0);
  expect(prompts).toBe(1);
  expect(await preflight('Restart')).toBe(false);
  asyncResponse = 0;
  await reload();
  expect(reloads).toBe(1);
  let allowed = false;
  webContents.emit('will-prevent-unload', { preventDefault: () => { allowed = true; } });
  expect(allowed).toBe(true);
  allowed = false;
  webContents.emit('will-prevent-unload', { preventDefault: () => { allowed = true; } });
  expect(allowed).toBe(false);
  syncResponse = 0;
  webContents.emit('will-prevent-unload', { preventDefault: () => { allowed = true; } });
  expect(allowed).toBe(true);
});
