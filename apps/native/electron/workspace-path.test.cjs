const { test } = require('node:test');
const assert = require('node:assert/strict');
const { isWorkspacePath } = require('./workspace-path.cjs');

test('workspace paths accept Linux, XDG, drive-letter, and UNC forms', () => {
  for (const value of ['/home/user/src', '/home/user/.config/Codegraff Electron', 'C:\\Users\\graff\\src', '\\\\server\\share\\repo']) {
    assert.equal(isWorkspacePath(value), true, value);
  }
  for (const value of ['', 'relative/src', '../escape', 'C:relative', 'has\0nul']) assert.equal(isWorkspacePath(value), false);
});
