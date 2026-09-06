const { test } = require('node:test');
const assert = require('node:assert/strict');
const { pageURL, authorized, bounds } = require('./policy.cjs');
test('browser navigation permits web pages and local development, never executable schemes', () => {
  assert.equal(pageURL('example.com'), 'https://example.com/');
  assert.equal(pageURL('localhost:8080/demo'), 'http://localhost:8080/demo');
  for (const url of ['file:///etc/passwd', 'javascript:alert(1)', 'data:text/html,hi', 'https://name:secret@example.com']) assert.throws(() => pageURL(url));
});
test('browser automation requires its bearer token and rejects web origins', () => {
  assert.equal(authorized({ headers: { authorization: 'Bearer secret' } }, 'secret'), true);
  for (const headers of [{}, { authorization: 'Bearer wrong' }, { authorization: 'Bearer secret', origin: 'https://example.com' }]) assert.equal(authorized({ headers }, 'secret'), false);
});
test('browser geometry cannot overflow the app content or accept NaN', () => {
  assert.deepEqual(bounds({ x: -5, y: 50, width: 2000, height: 2000 }, { width: 900, height: 600 }), { x: 0, y: 50, width: 900, height: 550 });
  assert.equal(bounds({ x: NaN, y: 0, width: 3, height: 3 }, { width: 900, height: 600 }), null);
});
