import { spawn } from 'node:child_process';
/** The watchdog lives outside Electron, so a blocked renderer/main loop cannot
 * disable it. Descendants inherit this private process group on POSIX. */
export function runBounded(command, args, options, { timeoutMs, graceMs = 1000, onSpawn = () => {} }) {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw Error('A positive test deadline is required');
  const grouped = process.platform !== 'win32';
  const child = spawn(command, args, { ...options, detached: grouped });
  onSpawn(child);
  return new Promise((resolve, reject) => {
    let timedOut = false, escalation;
    const signal = value => {
      try { if (grouped && child.pid) process.kill(-child.pid, value); else child.kill(value); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    };
    const stop = () => { signal('SIGTERM'); escalation ??= setTimeout(() => signal('SIGKILL'), graceMs); };
    const deadline = setTimeout(() => { timedOut = true; console.error(`Test deadline exceeded after ${timeoutMs}ms: ${args[0] ?? command}`); stop(); }, timeoutMs);
    const cleanup = () => { clearTimeout(deadline); clearTimeout(escalation); process.off('SIGTERM', stop); process.off('SIGINT', stop); if (grouped) signal('SIGKILL'); };
    process.once('SIGTERM', stop); process.once('SIGINT', stop);
    child.once('error', error => { cleanup(); reject(error); });
    child.once('exit', code => { cleanup(); resolve({ code: code ?? 1, timedOut }); });
  });
}
