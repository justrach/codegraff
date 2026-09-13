import { spawn } from 'node:child_process';
import { runBounded } from './process-deadline.mjs';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);
const { testWindowMode } = require('../electron/test-window.cjs');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

async function focusMonitor() {
  const source = path.join(root, 'electron/native/TestFocusMonitor.swift');
  const hash = createHash('sha256').update(readFileSync(source)).digest('hex').slice(0, 16);
  const binary = path.join(tmpdir(), `graff-test-focus-${process.arch}-${hash}`);
  if (!existsSync(binary)) {
    const result = await runBounded('xcrun', ['swiftc', source, '-o', binary],
      { stdio: ['ignore', 'ignore', 'inherit'] }, { timeoutMs: 120000 });
    if (result.code !== 0 || result.timedOut) throw Error('Could not build desktop focus observer within its deadline');
  }
  const child = spawn(binary, [], { stdio: ['pipe', 'pipe', 'inherit'] });
  const lines = createInterface({ input: child.stdout });
  let report;
  const exited = new Promise(resolve => child.once('exit', code => resolve(code)));
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(Error('Desktop focus observer did not start')), 15000);
      child.once('error', error => { clearTimeout(timer); reject(error); });
      child.once('exit', () => { clearTimeout(timer); reject(Error('Desktop focus observer exited before readiness')); });
      lines.on('line', line => {
        if (line === 'ready') { clearTimeout(timer); resolve(); }
        else { try { report = JSON.parse(line); } catch {} }
      });
    });
  } catch (error) { child.kill(); throw error; }
  return {
    watch(pid) { child.stdin.write(`${pid}\n`); },
    async stop() {
      child.stdin.end('stop\n');
      const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
      const code = await exited; clearTimeout(timer); lines.close();
      if (code !== 0 || !report?.observed || report.foregroundActivations || (testWindowMode() === 'hidden' && report.visibleWindowSamples)) {
        throw Error(`Desktop isolation failed: ${JSON.stringify(report ?? { observerExit: code })}`);
      }
      return report;
    },
  };
}

// The observer starts before Electron, so it catches launch activation as well
// as later test steps. Switching to a different user app is allowed throughout.
export async function runElectron(entry, args = []) {
  return runDesktopProcess(require('electron'), [path.resolve(root, entry), ...args]);
}

export async function runDesktopProcess(command, args = [], env = process.env) {
  const foreground = testWindowMode() === 'foreground';
  const monitor = process.platform === 'darwin' && !foreground ? await focusMonitor() : null;
  let code = 1;
  try {
    const configured = Number(process.env.GRAFF_TEST_TIMEOUT_MS ?? 300000);
    if (!Number.isFinite(configured) || configured < 1000 || configured > 900000) throw Error('GRAFF_TEST_TIMEOUT_MS must be between 1000 and 900000');
    const result = await runBounded(command, args, {
      cwd: root, stdio: 'inherit', env: { ...env, GRAFF_TEST_BUN: process.execPath, GRAFF_TEST_MANAGED_GROUP: process.platform === 'win32' ? '' : '1' },
    }, { timeoutMs: configured, onSpawn(child) { if (child.pid) monitor?.watch(child.pid); } });
    code = result.timedOut ? 1 : result.code;
  } finally {
    if (monitor) console.log('Desktop isolation:', JSON.stringify(await monitor.stop()));
    else console.log(`Desktop isolation: ${foreground ? 'foreground opt-in' : 'native window policy (OS observer is macOS-only)'}`);
  }
  process.exitCode = code;
  return code;
}
