import { test } from 'node:test';
import assert from 'node:assert/strict';
import { restoreOpenTabs } from './page-recovery';
import { TAB_RECOVERY_KEY } from '@/lib/tab-recovery';
import type { Chat } from './harness-types';

test('a new page restores saved tabs in their original workspaces and keeps a missing checkpoint visible', async () => {
  const previousWindow = globalThis.window;
  const previousFetch = globalThis.fetch;
  const tabs = [
    { id: 4, session: 'native-saved', cwd: '/repo/.graff/worktrees/a', title: 'Old title' },
    { id: 7, session: 'native-unsaved', cwd: '/repo/.graff/worktrees/b', title: null },
  ];
  Object.assign(globalThis, { window: { localStorage: { getItem: (key: string) => key === TAB_RECOVERY_KEY
    ? JSON.stringify({ tabs, activeId: 7, groups: [{ ids: [4, 7], direction: 'row' }] }) : null } } });
  const paths: string[] = [];
  globalThis.fetch = async (input) => {
    paths.push(String(input));
    return String(input).includes('native-unsaved') ? new Response('', { status: 404 })
      : Response.json({ name: 'native-saved', title: 'Saved title', model: 'test-model',
        presentation: 'transcript-v1', transcript: [{ role: 'user', text: 'Earlier prompt' }] });
  };
  let chats: Chat[] = [{ id: 1, title: null, messages: [] }], active = 1, groups: unknown;
  const chatsRef = { current: chats }, sessionNamesRef = { current: new Map<number, string>() };
  const chatIdRef = { current: 1 }, msgIdRef = { current: 0 };
  try {
    const id = await restoreOpenTabs({ chatsRef, sessionNamesRef, chatIdRef, msgIdRef,
      setChats: value => { chats = typeof value === 'function' ? value(chats) : value; },
      setActiveId: value => { active = typeof value === 'function' ? value(active) : value; },
      restoreGroups: value => { groups = value; } });
    assert.equal(id, 7);
    assert.equal(active, 7);
    assert.deepEqual(chats.map(chat => chat.id), [4, 7]);
    assert.equal(chats[0].title, 'Saved title');
    assert.equal(chats[0].messages[0].role, 'user');
    assert.equal(chats[0].snapshot, undefined);
    assert.equal(chats[1].messages.length, 0);
    assert.equal(chatIdRef.current, 7);
    assert.equal(sessionNamesRef.current.get(4), 'native-saved');
    assert.deepEqual(groups, [{ ids: [4, 7], direction: 'row' }]);
    assert.ok(paths.some(path => path.includes('root=%2Frepo%2F.graff%2Fworktrees%2Fa')));
  } finally {
    Object.assign(globalThis, { window: previousWindow });
    globalThis.fetch = previousFetch;
  }
});
