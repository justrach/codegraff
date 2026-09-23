const path = require('node:path');

function isWorkspacePath(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 4096 && !value.includes('\0') &&
    (path.win32.isAbsolute(value) || path.posix.isAbsolute(value));
}

module.exports = { isWorkspacePath };
