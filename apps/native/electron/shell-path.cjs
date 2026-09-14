const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const os = require('node:os');
const path = require('node:path');

const runShell = promisify(execFile);
const fallback = ['/opt/homebrew/bin', '/opt/homebrew/sbin', '/usr/local/bin', '/usr/local/sbin',
  '/usr/bin', '/bin', '/usr/sbin', '/sbin'];

// Finder-launched apps need the user's tool search path before spawning any backend.
// Import only PATH, never replace the desktop's environment with shell output.
async function restoreShellPath({ env = process.env, platform = process.platform, run = runShell, home = os.homedir() } = {}) {
  if (platform !== 'darwin') return;
  let loginPath = '';
  try {
    const shell = env.SHELL && path.isAbsolute(env.SHELL) ? env.SHELL : '/bin/zsh';
    const { stdout } = await run(shell, ['-ilc', 'printf "\\000"; /usr/bin/printenv PATH; printf "\\000"'], {
      env: { ...env }, cwd: home, encoding: 'utf8', timeout: 3000, maxBuffer: 64 * 1024, killSignal: 'SIGKILL',
    });
    const start = stdout.indexOf('\0'), end = stdout.indexOf('\0', start + 1);
    if (start >= 0 && end > start) loginPath = stdout.slice(start + 1, end).replace(/\r?\n$/, '');
  } catch {
    // Broken or slow shell startup must not prevent the desktop from opening.
  }
  const inherited = typeof env.PATH === 'string' ? env.PATH.split(':') : [];
  env.PATH = [...new Set([...inherited, ...loginPath.split(':').filter(Boolean), ...fallback])].join(':');
}

module.exports = { restoreShellPath };
