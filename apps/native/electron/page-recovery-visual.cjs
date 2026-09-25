const assert = require('node:assert/strict');

async function runPageRecovery({ win, report }) {
  const wc = win.webContents;
  const read = () => wc.executeJavaScript(`(() => ({
    tabs: [...document.querySelectorAll('[data-tab-id]')].map(node => Number(node.dataset.tabId)),
    active: Number(document.querySelector('[data-tab-id] button[aria-pressed="true"]')?.closest('[data-tab-id]')?.dataset.tabId),
    record: JSON.parse(localStorage.getItem('graff.native.open-tabs.v1') || 'null'),
    ready: !!document.querySelector('[data-workspace-ready="true"]'),
  }))()`);
  const wait = async (predicate, stage) => {
    let last;
    for (let attempt = 0; attempt < 100; attempt++) {
      const state = await read();
      if (predicate(state)) return state;
      last = state;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw Error(`Tab recovery ${stage} timed out: ${JSON.stringify({ ready: last?.ready, openTabs: last?.tabs?.length, savedTabs: last?.record?.tabs?.length ?? null })}`);
  };
  const initial = await wait(state => state.ready && state.tabs.length > 0 && state.record?.tabs?.length > 0, 'page readiness');
  assert.equal(await wc.executeJavaScript(`(() => { const button = Array.from(document.querySelectorAll('button[aria-label="New chat"]')).find(node => node.checkVisibility()); button?.click(); return !!button; })()`), true, 'New chat control is visible');
  const before = await wait(state => state.tabs.length === initial.tabs.length + 1 && state.record?.tabs?.length === initial.record.tabs.length + 1,
    `new tab checkpoint after ${initial.tabs.length} visible tabs and ${initial.record.tabs.length} saved chats`);
  assert.equal(before.record.activeId, before.active);
  await wc.reload();
  const after = await wait(state => state.ready && state.tabs.length === before.tabs.length && state.active === before.active, 'reload');
  assert.deepEqual(after.tabs, before.tabs);
  assert.deepEqual(after.record.tabs.map(tab => [tab.id, tab.session, tab.cwd]),
    before.record.tabs.map(tab => [tab.id, tab.session, tab.cwd]));
  report.passed.push('reload restores open tab references, selected tab and original session workspaces');
}

module.exports = { runPageRecovery };
