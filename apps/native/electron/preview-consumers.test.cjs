const { test } = require('node:test');
const assert = require('node:assert/strict');
const { portOf } = require('./preview-consumers.cjs');

test('only loopback URLs count as preview consumers', () => {
  assert.equal(portOf('http://localhost:5173/'), 5173);
  assert.equal(portOf('http://127.0.0.1:3000'), 3000);
  assert.equal(portOf('https://example.com:443'), 0);
  assert.equal(portOf('about:blank'), 0);
});
