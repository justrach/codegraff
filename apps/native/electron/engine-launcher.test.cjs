const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {promisify} = require('node:util');
const execFile = promisify(require('node:child_process').execFile);
const {installEngine} = require('./engine-launcher.cjs');

test('bundled graff forwards arguments, updates with GUI and configures PATH once', async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), 'graff-engine-'));
  try {
    const first = path.join(home, "old ' bundle"), second = path.join(home, 'new bundle');
    await fs.writeFile(first, '#!/bin/sh\nprintf "%s\\n" "$@"\n', {mode:0o700});
    await fs.writeFile(second, '#!/bin/sh\necho updated\n', {mode:0o700});
    await installEngine(first, home, {shell:'/bin/zsh'});
    const launcher = path.join(home, '.local/bin/graff');
    assert.equal((await execFile(launcher, ['a b', '$(literal)'])).stdout, 'a b\n$(literal)\n');
    const rc = await fs.readFile(path.join(home, '.zshrc'), 'utf8');
    await installEngine(second, home, {shell:'/bin/zsh'});
    assert.equal((await execFile(launcher)).stdout, 'updated\n');
    assert.equal(await fs.readFile(path.join(home, '.zshrc'), 'utf8'), rc);
    const result = await execFile('/bin/zsh', ['-c', 'source "$HOME/.zshrc"; command -v graff'], {env:{HOME:home,PATH:'/usr/bin:/bin'}});
    assert.equal(result.stdout.trim(), launcher);
  } finally { await fs.rm(home, {recursive:true,force:true}); }
});

test('independent graff command is preserved', async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), 'graff-engine-'));
  try {
    const file = path.join(home,'.local/bin/graff');
    await fs.mkdir(path.dirname(file),{recursive:true});
    await fs.writeFile(file,'custom');
    assert.equal(await installEngine('/bin/echo',home),'Existing graff command preserved');
    assert.equal(await fs.readFile(file,'utf8'),'custom');
  } finally {await fs.rm(home,{recursive:true,force:true});}
});
