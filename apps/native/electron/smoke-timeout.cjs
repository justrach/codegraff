// Fail-fast budgets + timeout forensics for the server-lifecycle smoke.
//
// `until()` used to share the outer Electron budget (180s), so the external
// watchdog SIGKILLed the process group before `until` could throw: CI showed a
// generic "Test deadline exceeded" with no GUI/backend/worker state. Every
// wait below now ends before the watchdog, and the timeout path dumps what
// the renderer, the backend, the scripted model, and the workers were doing.
const fs = require('node:fs'), path = require('node:path');

/** The outer `runBounded` budget this Electron run lives under. Lenient here:
// the spawner already validated the variable; an absent/invalid value means
// a hand run, which gets the spawner's own default. */
function outerMs(env = process.env) {
  const n = Number(env.GRAFF_TEST_TIMEOUT_MS ?? 300000);
  if (!Number.isFinite(n) || n < 1000 || n > 900000) return 300000;
  return n;
}

/** Per-phase wait bound. Long poles end early enough that the timeout dump
// and a clean `app.exit(1)` land before the watchdog SIGTERM: the scripted
// turn lands in ~3s, so outer-30s keeps 50x headroom while never racing. */
function phaseBudget(label, outer = outerMs(), elapsedMs = 0) {
  switch (label) {
    case 'composer': return 90000;
    case 'agent completion': return Math.max(30000, outer - 30000);
    case 'explicit user pin': return 60000;
    case 'production backend and worker shutdown':
      return Math.max(15000, outer - elapsedMs - 10000);
    default: return 90000;
  }
}

function slug(label) {
  return label.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 48) || 'phase';
}

function tailText(text, maxChars) {
  if (typeof text !== 'string' || text.length <= maxChars) return text ?? '';
  return text.slice(text.length - maxChars);
}

/** One line per worker trajectory: how far each `graff acp` child got. A run
// stuck post-`recipe` with no `prompt`/`turn` never received its prompt. */
function collectWorkerState(workspaceDir) {
  const trajectories = path.join(workspaceDir, '.graff', 'trajectories');
  const behavior = path.join(workspaceDir, '.graff', 'behavior');
  const runs = [];
  try {
    const files = fs.readdirSync(trajectories).filter(name => name.endsWith('.jsonl')).slice(0, 12);
    for (const name of files) {
      const lines = fs.readFileSync(path.join(trajectories, name), 'utf8').split('\n').filter(Boolean);
      let first = {}, last = {};
      try { first = JSON.parse(lines[0] ?? '{}'); } catch {}
      try { last = JSON.parse(lines[lines.length - 1] ?? '{}'); } catch {}
      let finished = null;
      try {
        const behaviorLines = fs.readFileSync(path.join(behavior, name), 'utf8').split('\n').filter(Boolean);
        const tail = JSON.parse(behaviorLines[behaviorLines.length - 1] ?? '{}');
        if (tail.kind === 'run_finished') finished = tail.status ?? true;
      } catch {}
      runs.push({ run: name.replace(/\.jsonl$/, ''), pid: first.pid ?? null, lines: lines.length,
        lastKind: last.kind ?? null, lastEv: last.ev ?? null, finished });
    }
  } catch (error) {
    return { error: error.message };
  }
  return { count: runs.length, runs };
}

/** Scripted-model and backend tails: did any request reach the model, and
// what was the backend's last word. All reads are best-effort; a missing
// file is itself evidence (no `requests.json` means no model call). */
function collectModelState(outputDir) {
  const state = {};
  try { state.modelLogTail = tailText(fs.readFileSync(path.join(outputDir, 'model.log'), 'utf8'), 2000); }
  catch (error) { state.modelLogTail = `<unreadable: ${error.message}>`; }
  try {
    const raw = fs.readFileSync(path.join(outputDir, 'requests.json'), 'utf8');
    state.requests = { bytes: raw.length, count: JSON.parse(raw).length };
  } catch (error) {
    state.requests = fs.existsSync(path.join(outputDir, 'requests.json'))
      ? { error: error.message } : { present: false };
  }
  try { state.serverLogTail = tailText(fs.readFileSync(path.join(outputDir, 'logs', 'server.log'), 'utf8'), 4000); }
  catch (error) { state.serverLogTail = `<unreadable: ${error.message}>`; }
  return state;
}

/** One compact block for the CI log; the full record goes to timeout-*.json. */
function formatTimeoutSummary({ label, elapsedMs, outerMs: outer, backend, workers, model, guiChars }) {
  const workerLine = workers.error ? `workers=<${workers.error}>`
    : `workers=${workers.count}${workers.runs.map(run => ` ${run.run.slice(0, 8)}:${run.lastKind ?? run.lastEv ?? '?'}${run.finished ? '(done)' : ''}`).join(',')}`;
  const requestLine = model.requests.present === false ? 'requests=absent'
    : model.requests.count !== undefined ? `requests=${model.requests.count}` : `requests=<${model.requests.error ?? '?'}>`;
  return [
    `Shutdown fixture timeout: ${label} (waited ${elapsedMs}ms of ${outer}ms outer)`,
    `Shutdown dump: backend=${backend} ${workerLine} ${requestLine} guiChars=${guiChars}`,
  ].join('\n');
}

module.exports = { outerMs, phaseBudget, slug, tailText, collectWorkerState, collectModelState, formatTimeoutSummary };
