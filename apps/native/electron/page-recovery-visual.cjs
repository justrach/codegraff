const assert = require('node:assert/strict');

async function runPageRecovery({ win, report }) {
  const wc = win.webContents;
  const read = () => wc.executeJavaScript(`(() => ({
    tabs: [...document.querySelectorAll('[data-tab-id]')].map(node => Number(node.dataset.tabId)),
    active: Number(document.querySelector('[data-tab-id] button[aria-pressed="true"]')?.closest('[data-tab-id]')?.dataset.tabId),
    record: JSON.parse(localStorage.getItem('graff.native.open-tabs.v1') || 'null'),
    ready: !!document.querySelector('[data-workspace-ready="true"]'),
  }))()`);
  const wait = async predicate => {
    for (let attempt = 0; attempt < 100; attempt++) {
      const state = await read();
      if (predicate(state)) return state;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw Error('Open tabs did not recover after reload');
  };
  const initial = await wait(state => state.ready && state.tabs.length > 0 && state.record?.tabs?.length > 0);
  await wc.executeJavaScript(`window.dispatchEvent(new CustomEvent('graff-desktop-action', {detail:'new'}))`);
  const before = await wait(state => state.tabs.length === initial.tabs.length + 1 && state.record?.tabs?.length === state.tabs.length);
  assert.equal(before.record.activeId, before.active);
  await wc.reload();
  const after = await wait(state => state.ready && state.tabs.length === before.tabs.length && state.active === before.active);
  assert.deepEqual(after.tabs, before.tabs);
  assert.deepEqual(after.record.tabs.map(tab => [tab.id, tab.session, tab.cwd]),
    before.record.tabs.map(tab => [tab.id, tab.session, tab.cwd]));
  report.passed.push('reload restores open tab references, selected tab and original session workspaces');
}

module.exports = { runPageRecovery };
