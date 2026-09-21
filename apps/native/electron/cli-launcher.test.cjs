const { test, expect } = require('bun:test');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { spawnSync } = require('node:child_process');
const { installLauncher } = require('./cli-launcher.cjs');
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";

test('terminal launcher passes literal folders/files and rejects invalid arguments without launch', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-cli-'));
  try {
    const bundle = path.join(home, "App ' $literal.app"), binary = path.join(bundle, 'Contents/MacOS/Codegraff'), capture = path.join(home, 'capture');
    fs.mkdirSync(path.dirname(binary), { recursive: true });
    fs.writeFileSync(binary, `#!/bin/sh\nprintf '%s\\n%s\\n' "\${GRAFF_OPEN_PATH-unset}" "\${GRAFF_CWD-unset}" > ${quote(capture)}\n`, { mode: 0o755 });
    const launcher = await installLauncher(bundle, home), folder = path.join(home, "folder ' $(literal) `text`"), file = path.join(folder, 'some file.txt');
    fs.mkdirSync(folder); fs.writeFileSync(file, 'example');
    const run = args => spawnSync('/bin/sh', [launcher, ...args], { cwd: home, encoding: 'utf8', timeout: 2000, env: { ...process.env, GRAFF_CWD: '/stale', GRAFF_OPEN_PATH: '/stale' } });
    for (const [args, expected] of [[[], ['unset', 'unset']], [[path.basename(folder)], [fs.realpathSync(folder), fs.realpathSync(folder)]], [[file], [fs.realpathSync(file), fs.realpathSync(folder)]], [['.'], [fs.realpathSync(home), fs.realpathSync(home)]]]) {
      fs.rmSync(capture, { force: true }); expect(run(args).status).toBe(0);
      const end = Date.now() + 1500;
      while (!fs.existsSync(capture) && Date.now() < end) await Bun.sleep(10);
      expect(fs.readFileSync(capture, 'utf8').trimEnd().split('\n')).toEqual(expected);
    }
    fs.rmSync(capture);
    for (const args of [['missing'], ['a', 'b'], ['--unknown']]) expect(run(args).status).not.toBe(0);
    expect(run(['--help']).stdout).toContain('Usage: codegraff'); expect(fs.existsSync(capture)).toBe(false);
    await installLauncher(bundle, home); // Idempotent upgrade of our launcher.
    fs.writeFileSync(launcher, '#!/bin/sh\necho custom');
    await expect(installLauncher(bundle, home)).rejects.toThrow('unrelated');
    expect(fs.readFileSync(launcher, 'utf8')).toContain('echo custom');
  } finally { fs.rmSync(home, { recursive: true, force: true }); }
});

test('linux launcher targets the sandbox wrapper and writes a desktop entry', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-cli-linux-'));
  try {
    const bundle = path.join(home, 'bundle'), capture = path.join(home, 'capture');
    fs.mkdirSync(bundle);
    fs.writeFileSync(path.join(bundle, 'codegraff.bin'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    fs.writeFileSync(path.join(bundle, 'codegraff'), '#!/bin/sh\n# Codegraff Linux desktop launcher\nexit 0\n', { mode: 0o755 });
    fs.writeFileSync(path.join(bundle, 'codegraff.png'), 'png');
    const launcher = await installLauncher(bundle, home);
    expect(fs.readFileSync(launcher, 'utf8')).toContain(path.join(bundle, 'codegraff'));
    expect(fs.readFileSync(launcher, 'utf8')).not.toContain('codegraff.bin');
    const desktop = fs.readFileSync(path.join(home, '.local/share/applications/codegraff.desktop'), 'utf8');
    expect(desktop).toContain('Codegraff GUI desktop entry');
    expect(desktop).toContain(path.join(bundle, 'codegraff.png'));
    fs.writeFileSync(path.join(bundle, 'codegraff.bin'), `#!/bin/sh\nprintf '%s\\n' "\${GRAFF_OPEN_PATH-unset}" > ${quote(capture)}\n`, { mode: 0o755 });
    fs.writeFileSync(path.join(bundle, 'codegraff'), `#!/bin/sh\n# Codegraff Linux desktop launcher\nexec ${quote(path.join(bundle, 'codegraff.bin'))} "$@"\n`, { mode: 0o755 });
    const folder = path.join(home, 'project');
    fs.mkdirSync(folder);
    expect(spawnSync('/bin/sh', [launcher, folder], { cwd: home, encoding: 'utf8', timeout: 2000 }).status).toBe(0);
    const end = Date.now() + 1500;
    while (!fs.existsSync(capture) && Date.now() < end) await Bun.sleep(10);
    expect(fs.readFileSync(capture, 'utf8').trim()).toBe(fs.realpathSync(folder));
  } finally { fs.rmSync(home, { recursive: true, force: true }); }
});
