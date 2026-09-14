const { test, expect } = require('bun:test');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { mkdtemp, writeFile, rm } = require('node:fs/promises');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { restoreShellPath } = require('./shell-path.cjs');

const fallback = ['/opt/homebrew/bin', '/opt/homebrew/sbin', '/usr/local/bin',
  '/usr/local/sbin', '/usr/bin', '/bin', '/usr/sbin', '/sbin'];
const execute = promisify(execFile);

test('preserves inherited priority, deduplicates login PATH, and ignores startup noise', async () => {
  const env = { PATH: '/inherited:/usr/bin:/inherited', SHELL: '/custom/login-shell' };
  await restoreShellPath({ env, platform: 'darwin', run: async () => ({
    stdout: 'startup /untrusted\n\0/login:/inherited:/opt/homebrew/bin:/login\n\0shutdown noise',
  }) });
  expect(env.PATH.split(':')).toEqual([
    '/inherited', '/usr/bin', '/login', '/opt/homebrew/bin', '/opt/homebrew/sbin',
    '/usr/local/bin', '/usr/local/sbin', '/bin', '/usr/sbin', '/sbin',
  ]);
});

test('uses the absolute shell and bounded execution without mutating credentials or other env', async () => {
  const env = { PATH: '/bin', SHELL: '/custom/login-shell', HOME: '/original-home',
    API_TOKEN: 'synthetic-test-token', OTHER: 'unchanged' };
  const before = { ...env };
  let calls = 0;
  await restoreShellPath({ env, platform: 'darwin', home: '/chosen-home',
    run: async (shell, args, options) => {
      calls++;
      expect(shell).toBe('/custom/login-shell');
      expect(args[0]).toBe('-ilc');
      expect(options.env).toEqual(before);
      expect(options.env).not.toBe(env);
      expect(options).toMatchObject({ cwd: '/chosen-home', encoding: 'utf8',
        timeout: 3000, maxBuffer: 64 * 1024, killSignal: 'SIGKILL' });
      return { stdout: '\0/login\n\0' };
    } });
  expect(calls).toBe(1);
  const { PATH, ...remaining } = env;
  const { PATH: originalPath, ...originalRemaining } = before;
  expect(remaining).toEqual(originalRemaining);
  expect(PATH).toContain('/login');
});

for (const shell of [undefined, 'relative-shell']) {
  test(`falls back to /bin/zsh for ${shell === undefined ? 'missing' : 'relative'} SHELL`, async () => {
    const env = { PATH: '/bin', ...(shell === undefined ? {} : { SHELL: shell }) };
    await restoreShellPath({ env, platform: 'darwin', run: async (executable) => {
      expect(executable).toBe('/bin/zsh');
      return { stdout: '\0/login\n\0' };
    } });
    expect(env.PATH.split(':')).toContain('/login');
  });
}

for (const failure of ['error', 'timeout', 'no sentinels', 'one sentinel']) {
  test(`${failure} preserves inherited PATH and adds fallback directories`, async () => {
    const env = { PATH: '/inherited:/usr/bin:/inherited' };
    await restoreShellPath({ env, platform: 'darwin', run: async () => {
      if (failure === 'error') throw new Error('synthetic shell failure');
      if (failure === 'timeout') throw Object.assign(new Error('synthetic timeout'),
        { killed: true, signal: 'SIGKILL' });
      return { stdout: failure === 'no sentinels' ? '/untrusted\n' : 'noise\0/untrusted\n' };
    } });
    expect(env.PATH.split(':')).toEqual([
      '/inherited', '/usr/bin', ...fallback.filter((dir) => dir !== '/usr/bin'),
    ]);
  });
}

test('non-darwin leaves the entire environment untouched and never spawns', async () => {
  for (const platform of ['linux', 'win32']) {
    const env = { PATH: '/inherited', SHELL: '/custom/shell', OTHER: 'unchanged' };
    const before = { ...env };
    let calls = 0;
    await restoreShellPath({ env, platform, run: async () => { calls++; return {}; } });
    expect(calls).toBe(0);
    expect(env).toEqual(before);
  }
});

test('a real child shell resolves a previously unavailable executable after PATH restoration', async () => {
  const bin = await mkdtemp(join(tmpdir(), 'shell-path-test-'));
  const name = `shell-path-probe-${bin.split('/').pop()}`;
  try {
    await writeFile(join(bin, name), '#!/bin/sh\nprintf "restored-path-ok"\n', { mode: 0o755 });
    const env = { PATH: '/usr/bin:/bin' };
    await expect(execute('/bin/sh', ['-c', name], { env })).rejects.toMatchObject({ code: 127 });
    await restoreShellPath({ env, platform: 'darwin', run: async () => ({
      stdout: `startup noise\0${bin}\n\0`,
    }) });
    const result = await execute('/bin/sh', ['-c', name], { env, encoding: 'utf8' });
    expect(result.stdout).toBe('restored-path-ok');
  } finally {
    await rm(bin, { recursive: true, force: true });
  }
});
