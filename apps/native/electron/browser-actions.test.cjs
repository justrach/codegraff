const { test, expect } = require('bun:test');
const { browserAction } = require('./browser-actions.cjs');
test('agent open and navigation always use the background route', async () => {
  const navigations = [];
  const browser = {
    navigate: async (...args) => { navigations.push(args); return { url: args[1] }; },
    command: () => { throw Error('Foreground route must not be used by agent navigation'); },
  };
  for (const action of ['open', 'navigate']) {
    expect(await browserAction(browser, 'other-chat', action, { url: 'http://localhost/preview', background: false }))
      .toEqual({ url: 'http://localhost/preview' });
  }
  expect(navigations).toEqual(Array.from({ length: 2 }, () => ['other-chat', 'http://localhost/preview', { background: true }]));
});
test('other agent browser actions retain their existing command routing', async () => {
  const calls = [];
  const browser = { command: async (...args) => { calls.push(args); return { ok: true }; } };
  for (const method of ['back', 'forward', 'reload', 'info', 'close']) await browserAction(browser, 'other-chat', method, {});
  expect(calls.map(args => args[1])).toEqual(['back', 'forward', 'reload', 'info', 'close']);
});

test('empty Find clears Chromium highlights and rejects a closed page', async () => {
  const calls = [];
  const browser = { tabs: new Map([['chat', { view: { webContents: {
    findInPage: text => calls.push(text), stopFindInPage: mode => calls.push(mode),
  } } }]]) };
  await browserAction(browser, 'chat', 'find', { text: 'word' });
  await browserAction(browser, 'chat', 'find', { text: '' });
  expect(calls).toEqual(['word', 'clearSelection']);
  await expect(browserAction(browser, 'closed', 'find', { text: 'word' })).rejects.toThrow(/closed or suspended/);
});
