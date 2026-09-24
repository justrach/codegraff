import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadTabRecovery, saveTabRecovery, tabRecovery, TAB_RECOVERY_KEY } from './tab-recovery.ts';

test('open tab references and split groups survive a new page without saving transcripts', () => {
  const store = new Map<string, string>();
  const storage = { getItem: (key: string) => store.get(key) ?? null, setItem: (key: string, value: string) => { store.set(key, value); } };
  const state = tabRecovery([
    { id: 3, session: 'native-first', cwd: '/repo/.graff/worktrees/first', project: '/repo', title: 'First', messages: [{ id: 1, role: 'user', text: 'private prompt' }] },
    { id: 8, session: 'native-second', cwd: '/repo/.graff/worktrees/second', title: 'Second', messages: [] },
  ], 8, [{ ids: [3, 8], direction: 'column' }]);
  saveTabRecovery(storage, state);
  assert.deepEqual(loadTabRecovery(storage), state);
  assert.equal(store.get(TAB_RECOVERY_KEY)?.includes('private prompt'), false);
  assert.equal(loadTabRecovery(storage)?.tabs[0].project, '/repo');
});

test('malformed or obsolete tab references do not replace the new chat', () => {
  const storage = { getItem: () => JSON.stringify({ tabs: [{ id: 1, session: '../escape' }], activeId: 1 }) };
  assert.equal(loadTabRecovery(storage), null);
  assert.equal(loadTabRecovery({ getItem: () => JSON.stringify({ tabs: [{ id: 1, session: 'valid', project: '../escape' }], activeId: 1 }) }), null);
});
