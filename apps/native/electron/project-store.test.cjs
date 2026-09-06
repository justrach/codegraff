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
  } finally { await fs.rm(root, { recursive: true }); }
});
