const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { installMcp } = require('./mcp-install.cjs');

test('GUI setup uses the bundled engine, records success and skips repeated first launch', async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), 'graff-mcp-gui-'));
  try {
    const binary = path.join(home, 'fake graff');
    await fs.writeFile(binary, '#!/bin/sh\n[ "$1" = mcp ] && [ "$2" = install ] || exit 3\necho registered\n', {mode:0o700});
    assert.match(await installMcp(binary, home, {once:true}), /registered/);
    await fs.unlink(binary);
    assert.equal(await installMcp(binary, home, {once:true}), 'MCP already configured');
    await assert.rejects(installMcp(binary, home));
  } finally { await fs.rm(home, {recursive:true, force:true}); }
});

test('failed GUI setup leaves no success receipt', async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), 'graff-mcp-gui-'));
  try {
    await assert.rejects(installMcp(path.join(home, 'missing'), home, {once:true}));
    await assert.rejects(fs.access(path.join(home, '.graff/mcp/gui-installed')));
  } finally { await fs.rm(home, {recursive:true, force:true}); }
});
