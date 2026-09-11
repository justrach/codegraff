const testDesktop = require('./test-desktop.cjs');
const assert = require('node:assert/strict');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// Matches the existing streaming-code/agents runner contract; no backend needed.
async function testTaskRows({ win, origin }) {
  const js = source => win.webContents.executeJavaScript(source);
  const wait = async source => {
    for (let i = 0; i < 160; i++) {
      if (await js(source)) return;
      await sleep(50);
    }
    throw Error(`Task rows check timed out: ${source}`);
  };
  const row = index => `document.querySelector('[data-task-rows]').firstElementChild.children[${index}]`;
  const expanded = index => `${row(index)}.querySelector('button')?.getAttribute('aria-expanded')`;
  const key = async keyCode => {
    await testDesktop.testInput(win.webContents, { type: 'keyDown', keyCode });
    // The shared Chromium driver carries Enter's character in both modes.
    if (keyCode === 'Space') {
      await testDesktop.testInput(win.webContents, { type: 'char', keyCode: ' ' });
    }
    await testDesktop.testInput(win.webContents, { type: 'keyUp', keyCode });
    await sleep(40);
  };
  let revision = 0;
  const set = async (items, variant) => {
    await js(`window.dispatchEvent(new CustomEvent('fixture-tasks',{detail:${JSON.stringify({ items, variant, revision: ++revision })}}))`);
    await wait(`document.querySelector('[data-tasks-fixture]').dataset.revision==='${revision}'`);
    // Finish finite entry/expansion animations without waiting for infinite spinners.
    await js(`Promise.all(document.getAnimations().filter(a=>a.effect?.getTiming().iterations!==Infinity).map(a=>a.finished.catch(()=>{}))).then(()=>true)`);
  };
  const inert = async index => {
    const state = await js(`(()=>{const r=${row(index)},h=r.firstElementChild;return {
      actions:r.querySelectorAll('button,[role="button"],[aria-expanded],[tabindex]').length,
      chevrons:r.querySelectorAll('path[d="M6 9l6 6 6-6"]').length,
      children:r.childElementCount,
      extraHeight:r.getBoundingClientRect().height-h.getBoundingClientRect().height
    }})()`);
    assert.equal(state.actions, 0, 'No-details row has no action or disclosure semantics');
    assert.equal(state.chevrons, 0, 'No-details row has no chevron');
    assert.equal(state.children, 1, 'No-details row has no detail container');
    assert.ok(state.extraHeight <= 2, `No detail spacing: ${JSON.stringify(state)}`);
    await js(`${row(index)}.firstElementChild.click()`);
    assert.equal(await js(expanded(index)), undefined, 'Clicking a static row stays inert');
  };
  await win.loadURL(`${origin}/visual-tests/tasks`);
  await wait(`document.querySelector('[data-tasks-fixture]')?.dataset.ready==='true'`);
  testDesktop.present(win);
  await js('document.fonts.ready.then(()=>true)');
  for (const variant of ['Capsules', 'List']) {
    const items = [
      { key: 'omitted', label: 'Omitted details', status: 'pending' },
      { key: 'empty', label: 'Empty details', status: 'pending', details: [] },
      { key: 'first', label: 'First disclosure', status: 'completed', details: [{ label: 'First detail', meta: '1' }] },
      { key: 'second', label: 'Second disclosure', status: 'failed', details: [{ label: 'Second detail' }] },
    ];
    // Each variant starts with fresh row identities, while updates within it keep keys stable.
    items.forEach(item => { item.key = `${variant}-${item.key}`; });
    for (const status of ['pending', 'in_progress', 'completed', 'failed']) {
      items[0].status = items[1].status = status;
      await set(items, variant);
      await inert(0); await inert(1);
    }
    await js(`document.querySelector('[data-focus-start]').focus()`);
    await key('Tab');
    assert.equal(await js(`document.activeElement===${row(2)}.querySelector('button')`), true, 'Tab skips both static rows');
    await key('Enter');
    await wait(`${expanded(2)}==='true'`);
    assert.equal(await js(expanded(3)), 'false', 'Keyboard expansion is independent');
    await key('Space');
    await wait(`${expanded(2)}==='false'`);
    await js(`${row(3)}.querySelector('button').click()`);
    await wait(`${expanded(3)}==='true'`);
    assert.equal(await js(expanded(2)), 'false', 'Click expansion is independent');
    await js(`${row(2)}.querySelector('button').click()`);
    await wait(`${expanded(2)}==='true'`);
    await set(items, variant);
    assert.ok(await js(`${row(2)}.getBoundingClientRect().height > ${row(2)}.firstElementChild.getBoundingClientRect().height + 5`), 'Actual details occupy visible space');
    // Remove both shapes of details while expanded; preserve keys to test live updates.
    delete items[2].details;
    items[3].details = [];
    await set(items, variant);
    await inert(2); await inert(3);
    assert.equal(await js(`document.querySelector('[data-task-rows]').textContent.includes('First detail')`), false);
    await js(`document.querySelector('[data-focus-start]').focus()`);
    await key('Tab');
    assert.equal(await js(`document.activeElement.matches('[data-focus-end]')`), true, 'All static rows leave the tab order');
    items[0].details = [{ label: 'New detail' }];
    await set(items, variant);
    assert.equal(await js(expanded(0)), 'false', 'New details provide a collapsed disclosure');
    await js(`${row(0)}.querySelector('button').click()`);
    await wait(`${expanded(0)}==='true'`);
    assert.equal(await js(`${row(0)}.textContent.includes('New detail')`), true);
    await inert(1); await inert(2); await inert(3);
  }
  console.log('Task rows checks passed: both variants, all statuses, static rows, keyboard/click disclosure, live detail removal/addition and independent mixed rows.');
}
module.exports = { testTaskRows };
