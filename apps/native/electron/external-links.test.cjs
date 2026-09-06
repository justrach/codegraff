const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { externalURL, installExternalLinks } = require('./external-links.cjs');
test('clicked web links leave the shell; executable schemes cannot reach the OS', () => {
  const contents = new EventEmitter(); let popup; const opened = [];
  contents.setWindowOpenHandler = handler => { popup = handler; };
  installExternalLinks(contents, 'http://127.0.0.1:3788', url => opened.push(url));
  let prevented = false;
  contents.emit('will-navigate', { preventDefault() { prevented = true; } }, 'https://example.com/docs');
  assert.equal(prevented, true); assert.deepEqual(opened, ['https://example.com/docs']);
  popup({ url: 'https://example.com/help' }); popup({ url: 'file:///etc/passwd' });
  assert.equal(opened.length, 2);
  for (const url of ['javascript:alert(1)', 'data:text/html,hi', 'https://user:pass@example.com', 'not a URL']) assert.equal(externalURL(url), null);
});
