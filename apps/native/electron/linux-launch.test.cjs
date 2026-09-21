const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function layout() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-linux-launch-'));
  const binDir = path.join(root, 'bin');
  fs.mkdirSync(binDir);
  const log = path.join(root, 'args');
  fs.copyFileSync(path.join(__dirname, 'linux/codegraff.sh'), path.join(root, 'codegraff'));
  fs.chmodSync(path.join(root, 'codegraff'), 0o755);
  fs.writeFileSync(path.join(root, 'codegraff.bin'), `#!/bin/sh\nprintf '%s\\n' "$@" > ${JSON.stringify(log)}\n`, { mode: 0o755 });
  return { root, binDir, log };
}

function run(root, binDir, status) {
  fs.writeFileSync(path.join(binDir, 'unshare'), `#!/bin/sh\nexit ${status}\n`, { mode: 0o755 });
  return spawnSync(path.join(root, 'codegraff'), ['--folder'], {
    encoding: 'utf8', env: { ...process.env, PATH: `${binDir}:/usr/bin:/bin` }, timeout: 2000,
  });
}

test('user namespaces keep the sandbox and a failed probe drops it', () => {
  const { root, binDir, log } = layout();
  try {
    assert.equal(run(root, binDir, 0).status, 0);
    assert.deepEqual(fs.readFileSync(log, 'utf8').trim().split('\n'), ['--class=codegraff', '--disable-setuid-sandbox', '--folder']);
    assert.equal(run(root, binDir, 1).status, 0);
    assert.deepEqual(fs.readFileSync(log, 'utf8').trim().split('\n'), ['--class=codegraff', '--no-sandbox', '--folder']);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
