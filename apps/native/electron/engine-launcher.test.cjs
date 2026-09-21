const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const {readFileSync} = require('node:fs');
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
    await installEngine(first, home, {extraBin: []});
    const launcher = path.join(home, '.local/bin/graff');
    assert.equal((await execFile(launcher, ['a b', '$(literal)'])).stdout, 'a b\n$(literal)\n');
    const rc = await fs.readFile(path.join(home, '.zshrc'), 'utf8');
    const profile = await fs.readFile(path.join(home, '.zprofile'), 'utf8');
    assert.match(profile, /export PATH=/);
    await installEngine(second, home, {extraBin: []});
    assert.equal((await execFile(launcher)).stdout, 'updated\n');
    assert.equal(await fs.readFile(path.join(home, '.zshrc'), 'utf8'), rc);
    assert.equal(await fs.readFile(path.join(home, '.zprofile'), 'utf8'), profile);
    const result = await execFile('/bin/zsh', ['-c', 'source "$HOME/.zprofile"; command -v graff'], {env:{HOME:home,PATH:'/usr/bin:/bin'}});
    assert.equal(result.stdout.trim(), launcher);
  } finally { await fs.rm(home, {recursive:true,force:true}); }
});

test('independent graff command is preserved', async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), 'graff-engine-'));
  try {
    const file = path.join(home,'.local/bin/graff');
    await fs.mkdir(path.dirname(file),{recursive:true});
    await fs.writeFile(file,'custom');
    assert.equal(await installEngine('/bin/echo',home,{extraBin: []}),'Existing graff command preserved');
    assert.equal(await fs.readFile(file,'utf8'),'custom');
    assert.match(await fs.readFile(path.join(home, '.zshrc'), 'utf8'), /Codegraff GUI CLI PATH/);
  } finally {await fs.rm(home,{recursive:true,force:true});}
});

test('login zsh finds graff without inheriting the app PATH', async () => {
  // macOS Terminal is a login, often non-interactive, zsh: it reads .zprofile
  // and not .zshrc. A notarized .app that only patched .zshrc leaves `graff`
  // as command-not-found. ZDOTDIR isolates this from the developer's files.
  const home = await fs.mkdtemp(path.join(os.tmpdir(), 'graff-engine-'));
  try {
    const binary = path.join(home, 'graff-bin');
    await fs.writeFile(binary, '#!/bin/sh\necho ok\n', {mode:0o700});
    await installEngine(binary, home, {extraBin: []});
    const launcher = path.join(home, '.local/bin/graff');
    const result = await execFile('/bin/zsh', ['-lc', 'command -v graff'], {
      env: {
        HOME: home, ZDOTDIR: home, SHELL: '/bin/zsh', PATH: '/usr/bin:/bin',
        TERM: 'dumb', USER: process.env.USER || 'graff',
      },
      timeout: 8000,
    });
    assert.equal(result.stdout.trim(), launcher);
  } finally { await fs.rm(home, {recursive:true, force:true}); }
});

test('packaged first launch always installs graff on PATH, including notarized builds', () => {
  const source = readFileSync(path.join(__dirname, 'main.cjs'), 'utf8');
  const ready = source.indexOf('app.whenReady()');
  assert.ok(ready >= 0);
  const engine = source.indexOf("require('./engine-launcher.cjs').installEngine", ready);
  const mcp = source.indexOf("require('./mcp-install.cjs').installMcp", ready);
  assert.ok(engine > ready, 'packaged launch must call installEngine');
  assert.ok(mcp > ready && mcp < engine, 'MCP setup is a sibling of PATH install, not its parent');
  assert.equal(source.slice(mcp, engine).includes('.then('), false, 'MCP failure must not skip PATH install');
  const call = source.slice(engine, engine + 900);
  assert.match(call, /extraBin:/);
  assert.match(call, /\/opt\/homebrew\/bin/);
  assert.match(call, /\/usr\/local\/bin/);
  assert.match(call, /['"]bin['"]/);
  const gate = source.slice(source.lastIndexOf('if (', engine), engine);
  assert.match(gate, /app\.isPackaged/);
  assert.doesNotMatch(gate, /developmentBuild/);
  assert.doesNotMatch(source.slice(ready, engine + 900), /notar/i);
  assert.doesNotMatch(source.slice(ready, engine + 900), /HARNESS_NO_PATH/);
});

test('writable extra bin dirs get a graff shim', async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), 'graff-engine-'));
  try {
    const binary = path.join(home, 'graff-bin');
    const extra = path.join(home, 'brew/bin');
    await fs.writeFile(binary, '#!/bin/sh\necho ok\n', {mode:0o700});
    await fs.mkdir(extra, {recursive: true});
    await installEngine(binary, home, {extraBin: [extra]});
    const shim = path.join(extra, 'graff');
    assert.equal((await execFile(shim)).stdout, 'ok\n');
    await fs.writeFile(shim, 'custom');
    await installEngine(binary, home, {extraBin: [extra]});
    assert.equal(await fs.readFile(shim, 'utf8'), 'custom');
  } finally { await fs.rm(home, {recursive:true, force:true}); }
});
