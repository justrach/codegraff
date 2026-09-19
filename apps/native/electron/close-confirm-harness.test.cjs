const { test } = require('node:test');
const assert = require('node:assert/strict');
const { CLOSE_DIALOG, expectCloseDialog, confirmCloseDialog, confirmCloseDialogIfOpen } = require('./close-confirm-harness.cjs');

// The harness's in-page snippets only touch querySelector, querySelectorAll,
// textContent, getAttribute, setAttribute and click, so a small double runs
// the exact strings the renderer would run.
function button(text, attrs = {}) {
  return {
    textContent: text, attrs: { ...attrs }, clicked: false,
    getAttribute(key) { return this.attrs[key] ?? null; },
    setAttribute(key, value) { this.attrs[key] = value; },
    click() { this.clicked = true; },
  };
}

function dialog(label, buttons) {
  return {
    label, buttons,
    getAttribute(key) { return key === 'aria-label' ? this.label : key === 'role' ? 'dialog' : null; },
    querySelectorAll(selector) { assert.equal(selector, 'button'); return this.buttons; },
  };
}

function setup(label = 'Close tab', buttons = null) {
  const state = {
    dialog: dialog(label, buttons ?? [button('', { 'aria-label': 'Close' }), button('Cancel'), button(label)]),
    // Narrow viewports keep the navigation panel mounted with role="dialog"
    // while tabs close; dismissal must not wait on it.
    nav: { label: 'Navigation' },
  };
  state.document = {
    querySelector(selector) {
      if (selector === CLOSE_DIALOG) {
        return state.dialog && state.dialog.label.startsWith('Close ') ? state.dialog : null;
      }
      if (selector === '[role="dialog"]') {
        if (state.dialog && state.dialog.label.startsWith('Close ')) return state.dialog;
        return state.nav;
      }
      if (selector === '[data-close-confirm="true"]') {
        return state.dialog?.buttons.find(item => item.getAttribute('data-close-confirm') === 'true') ?? null;
      }
      throw new Error(`unexpected selector: ${selector}`);
    },
  };
  state.js = code => new Function('document', `return (${code});`)(state.document);
  state.until = async (condition, label) => {
    for (let i = 0; i < 3 && !await condition(); i++) {}
    assert.equal(await condition(), true, `timed out: ${label}`);
  };
  return state;
}

test('the handshake tags and clicks the confirm button, never Cancel or the header X', async () => {
  const state = setup();
  const buttons = state.dialog.buttons;
  let clicked = null;
  const click = async selector => {
    clicked = selector;
    const target = state.document.querySelector(selector);
    assert.equal(target, buttons[2]);
    target.click();
    state.dialog = null; // The renderer closes the dialog and the tab.
  };
  await confirmCloseDialog({ js: state.js, click, until: state.until });
  assert.equal(clicked, '[data-close-confirm="true"]');
  assert.deepEqual(buttons.map(item => item.clicked), [false, false, true]);
});

test('a plural title confirms the same way', async () => {
  const state = setup('Close 3 tabs');
  assert.equal(await expectCloseDialog(state.js, state.until), 'Close 3 tabs');
  const buttons = state.dialog.buttons;
  await confirmCloseDialog({
    js: state.js,
    click: async selector => {
      const target = state.document.querySelector(selector);
      assert.equal(target?.textContent, 'Close 3 tabs');
      target.click();
      state.dialog = null;
    },
    until: state.until,
  });
  assert.deepEqual(buttons.map(item => item.clicked), [false, false, true]);
});

test('no dialog reads as absent instead of throwing', async () => {
  const state = setup();
  state.dialog = null;
  assert.equal(await confirmCloseDialogIfOpen(state.js), false);
  await assert.rejects(() => expectCloseDialog(state.js, state.until), /close confirmation dialog/);
});

test('an unrelated dialog does not satisfy the expectation', async () => {
  const state = setup('Update settings');
  assert.equal(await confirmCloseDialogIfOpen(state.js), false);
  await assert.rejects(() => confirmCloseDialog({ js: state.js, click: () => {}, until: state.until }), /close confirmation dialog/);
});

test('a Close-prefixed dialog with an unexpected title is rejected', async () => {
  const state = setup('Close everything');
  await assert.rejects(() => expectCloseDialog(state.js, state.until), /names the tabs/);
});

test('a confirmation without a matching button fails loudly instead of clicking Cancel', async () => {
  const state = setup('Close tab', [button('', { 'aria-label': 'Close' }), button('Cancel')]);
  await assert.rejects(() => confirmCloseDialog({ js: state.js, click: () => {}, until: state.until }), /owns a confirm button/);
});
