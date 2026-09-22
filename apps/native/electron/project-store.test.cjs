const { test, expect } = require('bun:test');
const { projectStore } = require('./project-store.cjs');
const fs = require('node:fs/promises'), os = require('node:os'), path = require('node:path');
test('project choices survive a new process/store and preserve the latest selection', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'graff-project-store-'));
  try {
    const store = projectStore(root);
    expect(await store.load()).toBeNull();
    const list = [{ path: '/projects/one', name: 'one' }, { path: '/projects/two', name: 'two', mcp: false }];
    await Promise.all([store.save({ list, active: list[0].path }), store.save({ list, active: list[1].path })]);
    expect(await projectStore(root).load()).toEqual({ list, active: '/projects/two' });
    expect(() => store.save({ list: [{ path: '../escape', name: 'bad' }] })).toThrow('Invalid project');
    const xdg = path.join(root, '.config', 'Codegraff Electron');
    const portable = projectStore(xdg);
    const windows = [{ path: 'C:\\Users\\graff\\src', name: 'drive' }, { path: '\\\\server\\share\\repo', name: 'unc' }];
    await portable.save({ list: windows, active: windows[0].path });
    expect(await projectStore(xdg).load()).toEqual({ list: windows, active: windows[0].path });
    const mode = (await fs.stat(path.join(xdg, 'projects.json'))).mode & 0o777;
    expect(mode).toBe(0o600);
  } finally { await fs.rm(root, { recursive: true }); }
});
