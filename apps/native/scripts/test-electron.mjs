import { spawn } from 'node:child_process';
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
  if (!existsSync(binary)) await new Promise((resolve, reject) => {
    const compiler = spawn('xcrun', ['swiftc', source, '-o', binary], { stdio: ['ignore', 'ignore', 'pipe'] });
    let errors = '';
    compiler.stderr.on('data', data => { errors += data; });
    compiler.once('error', reject);
    compiler.once('exit', code => code === 0 ? resolve() : reject(Error(`Could not build desktop focus observer: ${errors}`)));
  });
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
      const timer = setTimeout(() => child.kill(), 5000);
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
  const foreground = testWindowMode() === 'foreground';
  const monitor = process.platform === 'darwin' && !foreground ? await focusMonitor() : null;
  const child = spawn(require('electron'), [path.resolve(root, entry), ...args], {
    cwd: root, stdio: 'inherit', env: { ...process.env, GRAFF_TEST_BUN: process.execPath },
  });
  if (child.pid) monitor?.watch(child.pid);
  const interrupt = signal => { child.kill(signal); };
  const term = () => interrupt('SIGTERM'), sigint = () => interrupt('SIGINT');
  process.once('SIGTERM', term); process.once('SIGINT', sigint);
  let code = 1;
  try {
    code = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', exit => resolve(exit ?? 1));
    });
  } finally {
    process.removeListener('SIGTERM', term); process.removeListener('SIGINT', sigint);
    if (monitor) console.log('Desktop isolation:', JSON.stringify(await monitor.stop()));
    else console.log(`Desktop isolation: ${foreground ? 'foreground opt-in' : 'native window policy (OS observer is macOS-only)'}`);
  }
  process.exitCode = code;
  return code;
}
