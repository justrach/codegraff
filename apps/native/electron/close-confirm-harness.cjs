// Closing a tab that owns a live `graff acp` worker opens CloseConfirmDialog
// ("Close tab" / "Close N tabs") instead of closing. GUI harnesses must expect
// the dialog and confirm it; asserting it appears doubles as feature coverage.
const assert = require('node:assert/strict');

// No other dialog labels itself "Close …", so this names the confirmation.
const DIALOG = '[role="dialog"][aria-label^="Close "]';

// The confirm button's text is the dialog's own title ("Close tab" or
// "Close N tabs"); Cancel reads "Cancel" and the header X has no text.
const CONFIRM_FINDER = `(dialog => {
  const confirm = Array.from(dialog.querySelectorAll('button'))
    .find(button => (button.textContent || '').trim() === dialog.getAttribute('aria-label'));
  return confirm || null;
})`;

async function expectCloseDialog(js, until) {
  await until(() => js(`!!document.querySelector(${JSON.stringify(DIALOG)})`), 'close confirmation dialog');
  const label = await js(`document.querySelector(${JSON.stringify(DIALOG)}).getAttribute('aria-label')`);
  assert.match(label, /^Close (tab|\d+ tabs)$/, 'Confirmation names the tabs it closes');
  return label;
}

// Expect the dialog, confirm it through the real pointer path, wait for dismissal.
async function confirmCloseDialog({ js, click, until }) {
  await expectCloseDialog(js, until);
  const tagged = await js(`(() => {
    const dialog = document.querySelector(${JSON.stringify(DIALOG)});
    const confirm = dialog && (${CONFIRM_FINDER})(dialog);
    if (!confirm) return false;
    confirm.setAttribute('data-close-confirm', 'true');
    return true;
  })()`);
  assert.equal(tagged, true, 'Confirmation owns a confirm button');
  await click('[data-close-confirm="true"]');
  await until(() => js(`!document.querySelector('[role="dialog"]')`), 'close confirmation dismissed');
}

// Benchmark variant: that suite has no pointer helper and already clicks in-page.
async function confirmCloseDialogIfOpen(js) {
  return js(`(() => {
    const dialog = document.querySelector(${JSON.stringify(DIALOG)});
    const confirm = dialog && (${CONFIRM_FINDER})(dialog);
    if (!confirm) return false;
    confirm.click();
    return true;
  })()`);
}

module.exports = { CLOSE_DIALOG: DIALOG, expectCloseDialog, confirmCloseDialog, confirmCloseDialogIfOpen };
