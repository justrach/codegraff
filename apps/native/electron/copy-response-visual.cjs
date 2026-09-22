const assert = require('node:assert/strict');

exports.testCopyResponse = async function ({ win }) {
  const js = code => win.webContents.executeJavaScript(code);
  const wait = async condition => {
    for (let i = 0; i < 100; i++) {
      if (await js(condition)) return;
      await new Promise(resolve => setTimeout(resolve, 30));
    }
    throw Error(`Copy response did not settle: ${condition}`);
  };
  // Keep the user's clipboard untouched while exercising the real click handler.
  await js(`Object.defineProperty(navigator, 'clipboard', { configurable: true, value: {
    writeText: async text => { if (window.copyFails) throw Error('Denied'); window.copiedResponse = text; }
  } })`);
  await js(`document.querySelector('[data-case="done"]').click()`);
  await wait(`!!document.querySelector('[data-copy-response]')`);
  await js(`document.querySelector('[data-copy-response]').click()`);
  await wait(`document.querySelector('[data-copy-response]').textContent.includes('Copied')`);
  assert.equal(await js(`window.copiedResponse`), 'The preview is ready. The updated layout and keyboard shortcut checks passed.');
  assert.equal(await js(`document.querySelector('[data-copy-response]').getBoundingClientRect().height > 0`), true);
  await js(`window.copyFails = true; document.querySelector('[data-copy-response]').click()`);
  await wait(`document.querySelector('article').textContent.includes('Could not copy. Try again.')`);
  await js(`window.copyFails = false; document.querySelector('[data-copy-response]').click()`);
  await wait(`!document.querySelector('article').textContent.includes('Could not copy. Try again.')`);
  await js(`document.querySelector('[data-case="writing"]').click()`);
  await wait(`document.querySelector('article').getAttribute('data-turn-status') === 'streaming'`);
  await js(`document.querySelector('[data-copy-response]').click()`);
  await wait(`window.copiedResponse === 'Preparing a theme preview with readable text and a distinct accent.'`);
  await js(`document.querySelector('[data-case="thinking"]').click()`);
  await wait(`!document.querySelector('[data-copy-response]')`);
  console.log('PASS native response copy: exact text, visible control, streaming, empty, failure and retry');
};
