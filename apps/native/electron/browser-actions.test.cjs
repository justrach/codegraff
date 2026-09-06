const { test } = require('node:test');
const assert = require('node:assert/strict');
const { browserAction } = require('./browser-actions.cjs');
test('empty Find clears Chromium highlights and navigation does not need a rendered page', async () => {
  const calls = [];
  const browser = { tabs: new Map([['chat', { view: { webContents: {
    findInPage: text => calls.push(text), stopFindInPage: mode => calls.push(mode),
  } } }]]) };
  await browserAction(browser, 'chat', 'find', { text: 'word' });
  await browserAction(browser, 'chat', 'find', { text: '' });
  assert.deepEqual(calls, ['word', 'clearSelection']);
  await assert.rejects(browserAction(browser, 'closed', 'find', { text: 'word' }), /closed or suspended/);
});
