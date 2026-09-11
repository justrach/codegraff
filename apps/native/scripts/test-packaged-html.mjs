import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdtempSync, mkdirSync, writeFileSync, openSync, closeSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runDesktopProcess } from './test-electron.mjs';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const bundle = path.resolve(process.argv[2] || path.join(repo, 'zig-out/electron/Codegraff.app'));
const output = path.resolve(process.env.GRAFF_PACKAGED_OUTPUT || path.join(repo, 'zig-out/packaged-html'));
const temp = mkdtempSync(path.join(tmpdir(), 'graff-packaged-html-'));
const workspace = path.join(temp, 'initial project');
mkdirSync(workspace); mkdirSync(path.join(temp, 'second project')); mkdirSync(output, { recursive: true });
for (const file of ['launch-results.json', 'html-results.json', 'create-html-live.png', 'create-html-saved.png']) rmSync(path.join(output, file), { force: true });
const launcher = path.join(temp, 'codegraff');
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
// Keep application stderr for failures; all launch/path behavior stays identical.
writeFileSync(launcher, require('../electron/cli-launcher.cjs').launcherSource(bundle).replace('>/dev/null 2>&1', `>${quote(path.join(output, 'app.log'))} 2>&1`), { mode: 0o755 });
const { html, title } = require('../electron/html-tool-frontend.cjs');
const script = path.join(temp, 'replies.json');
writeFileSync(script, JSON.stringify([
  { tool: 'mcp_search_tools', arguments: { query: 'create_html' } },
  { tool: 'mcp_select_tool', arguments: { name: 'mcp__codegraff_desktop__create_html' } },
  { tool: 'mcp__codegraff_desktop__create_html', arguments: { title, html } },
  { text: 'Your inline explanation is ready.' },
]));
const mcp = path.join(temp, 'mcp.json'); writeFileSync(mcp, '{"mcpServers":{}}');
const env = Object.fromEntries(['PATH', 'TMPDIR', 'LANG', 'USER', 'LOGNAME', 'SHELL'].filter(key => process.env[key]).map(key => [key, process.env[key]]));
Object.assign(env, { HOME: temp, LMSTUDIO_API_KEY: 'local', GRAFF_NO_TELEMETRY: '1', GRAFF_FLEET: 'off', GRAFF_YOLO: '1',
  GRAFF_NO_SMOLIFY: '1', GRAFF_NO_CODEDB_GUARD: '1', NEXT_TELEMETRY_DISABLED: '1', GRAFF_MCP_CONFIG: mcp,
  GRAFF_ELECTRON_SMOKE: path.join(output, 'launch-results.json'), GRAFF_SMOKE_LAUNCH_ONLY: '1', GRAFF_SMOKE_HTML_TOOL: '1',
  GRAFF_SMOKE_PROFILE: path.join(temp, 'profile'), GRAFF_PACKAGED_OUTPUT: output });
const log = path.join(output, 'model.log'), fd = openSync(log, 'w');
const model = spawn('python3', [path.join(repo, 'scripts/eval/frontend_model.py'), '--script', script, '--requests', path.join(temp, 'requests.json')], { env, stdio: ['ignore', fd, fd] });
closeSync(fd);
let modelError; model.on('error', error => { modelError = error; });
try {
  const end = Date.now() + 10000;
  while (!readFileSync(log, 'utf8').includes('scripted model on')) {
    if (modelError || model.exitCode !== null || Date.now() > end) throw modelError || Error('Offline model did not start; port 1234 must be free');
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  process.env.GRAFF_TEST_TIMEOUT_MS = '120000';
  const code = await runDesktopProcess('/bin/sh', ['-c', 'launcher=$1; shift; . "$launcher"; wait "$!"', 'codegraff-test', launcher, workspace], env);
  if (code !== 0) console.error(readFileSync(path.join(output, 'app.log'), 'utf8').slice(-6000));
  else {
    const report = JSON.parse(readFileSync(path.join(output, 'html-results.json'), 'utf8'));
    for (const check of ['packaged cold launcher path', 'packaged running-app launcher path', 'real MCP discovery and create_html call through ACP', 'production saved-conversation replay after reload']) assert.ok(report.passed.includes(check), check);
    console.log('Packaged launcher → project → create_html → saved replay passed.');
  }
} finally { model.kill('SIGTERM'); rmSync(temp, { recursive: true, force: true }); }
