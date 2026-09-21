const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), http = require('node:http'), os = require('node:os'), path = require('node:path');
const { outerMs, phaseBudget, slug, tailText, collectWorkerState, collectModelState, formatTimeoutSummary, dumpTimeout } = require('./smoke-timeout.cjs');

test('outer budget mirrors the spawner validation, defaulting hand runs', () => {
  assert.equal(outerMs({ GRAFF_TEST_TIMEOUT_MS: '180000' }), 180000);
  assert.equal(outerMs({}), 300000);
  assert.equal(outerMs({ GRAFF_TEST_TIMEOUT_MS: 'soon' }), 300000);
  assert.equal(outerMs({ GRAFF_TEST_TIMEOUT_MS: '500' }), 300000);
});

test('waits end before the watchdog instead of racing it', () => {
  assert.equal(phaseBudget('composer', 180000, 0), 90000);
  assert.equal(phaseBudget('agent completion', 180000, 0), 150000);
  assert.equal(phaseBudget('agent completion', 60000, 0), 30000);
  assert.equal(phaseBudget('explicit user pin', 180000, 0), 60000);
  assert.equal(phaseBudget('production backend and worker shutdown', 180000, 5000), 165000);
  assert.equal(phaseBudget('production backend and worker shutdown', 180000, 175000), 15000);
  assert.equal(phaseBudget('unknown phase', 180000, 0), 90000);
});

test('timeout artifacts get stable short names', () => {
  assert.equal(slug('agent completion'), 'agent-completion');
  assert.equal(slug('production backend and worker shutdown'), 'production-backend-and-worker-shutdown');
});

test('tails keep the end of long logs', () => {
  assert.equal(tailText('abcdef', 4), 'cdef');
  assert.equal(tailText('ab', 4), 'ab');
});

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-smoke-timeout-'));
  const trajectories = path.join(root, 'workspace', '.graff', 'trajectories');
  const behavior = path.join(root, 'workspace', '.graff', 'behavior');
  fs.mkdirSync(trajectories, { recursive: true });
  fs.mkdirSync(behavior, { recursive: true });
  // A worker stalled post-recipe, and one that finished its turn.
  fs.writeFileSync(path.join(trajectories, 'aa.jsonl'),
    '{"kind":"session","pid":11,"unix_ms":1000}\n{"kind":"playbook","t":3}\n{"kind":"recipe","t":64}\n');
  fs.writeFileSync(path.join(behavior, 'aa.jsonl'), '{"kind":"run_started","seq":1}\n');
  fs.writeFileSync(path.join(trajectories, 'bb.jsonl'),
    '{"kind":"session","pid":22,"unix_ms":1000}\n{"kind":"prompt","t":300}\n{"kind":"turn","t":350}\n');
  fs.writeFileSync(path.join(behavior, 'bb.jsonl'), '{"kind":"run_started","seq":1}\n{"kind":"run_finished","seq":2,"status":"closed"}\n');
  const output = path.join(root, 'output');
  fs.mkdirSync(path.join(output, 'logs'), { recursive: true });
  fs.writeFileSync(path.join(output, 'model.log'), 'scripted model on 127.0.0.1:1234\n');
  fs.writeFileSync(path.join(output, 'requests.json'), JSON.stringify([{ messages: [] }, { messages: [] }]));
  fs.writeFileSync(path.join(output, 'logs', 'server.log'), 'ready\n');
  return { root, workspace: path.join(root, 'workspace'), output };
}

test('worker state names how far each trajectory got', () => {
  const { root, workspace } = fixture();
  try {
    const state = collectWorkerState(workspace);
    assert.equal(state.count, 2);
    const stalled = state.runs.find(run => run.run === 'aa');
    assert.equal(stalled.lastKind, 'recipe');
    assert.equal(stalled.finished, null);
    const done = state.runs.find(run => run.run === 'bb');
    assert.equal(done.lastKind, 'turn');
    assert.equal(done.finished, 'closed');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('worker state survives a missing evidence dir', () => {
  const state = collectWorkerState(path.join(os.tmpdir(), 'graff-smoke-timeout-missing'));
  assert.match(state.error, /ENOENT/);
});

test('model state reports requests and tails', () => {
  const { root, output } = fixture();
  try {
    const state = collectModelState(output);
    assert.equal(state.requests.count, 2);
    assert.match(state.modelLogTail, /scripted model on/);
    assert.equal(state.serverLogTail, 'ready\n');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('model state marks an absent requests file', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-smoke-timeout-'));
  try {
    const state = collectModelState(root);
    assert.equal(state.requests.present, false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the timeout drill captures renderer, backend, model, and workers', async () => {
  const { root, workspace, output } = fixture();
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, sessions: 3 }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const phases = [];
  try {
    const record = await dumpTimeout({ label: 'agent completion', waitedMs: 150000, outer: 180000,
      output, workspace, js: async () => 'typed prompt, no reply yet',
      capturePage: async () => Buffer.from('png-bytes'),
      backendOrigin: `http://127.0.0.1:${server.address().port}`, writePhase: name => phases.push(name) });
    assert.equal(record.backend, 'sessions=3 ok=true');
    assert.equal(record.guiText, 'typed prompt, no reply yet');
    assert.equal(record.workers.count, 2);
    assert.equal(record.model.requests.count, 2);
    assert.deepEqual(phases, ['timed out: agent completion']);
    assert.equal(JSON.parse(fs.readFileSync(path.join(output, 'timeout-agent-completion.json'), 'utf8')).label, 'agent completion');
    assert.equal(fs.readFileSync(path.join(output, 'timeout-gui-text.txt'), 'utf8'), 'typed prompt, no reply yet');
    assert.equal(fs.readFileSync(path.join(output, 'timeout.png'), 'utf8'), 'png-bytes');
  } finally {
    server.close();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the timeout drill degrades when every capture fails', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-smoke-timeout-'));
  const output = path.join(root, 'output');
  fs.mkdirSync(output, { recursive: true });
  try {
    const record = await dumpTimeout({ label: 'agent completion', waitedMs: 150000, outer: 180000,
      output, workspace: path.join(root, 'missing'), js: async () => { throw new Error('renderer gone'); },
      capturePage: async () => { throw new Error('no frame'); },
      backendOrigin: 'http://127.0.0.1:1', writePhase: () => {} });
    assert.match(record.guiText, /renderer gone/);
    assert.match(record.backend, /unreachable/);
    assert.match(record.workers.error, /ENOENT/);
    assert.equal(record.model.requests.present, false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the console summary fits the stall on two lines', () => {
  const summary = formatTimeoutSummary({ label: 'agent completion', elapsedMs: 150000, outerMs: 180000,
    backend: 'sessions=1', workers: { count: 1, runs: [{ run: 'aabbccdd', lastKind: 'recipe', finished: null }] },
    model: { requests: { present: false } }, guiChars: 42 });
  assert.match(summary, /Shutdown fixture timeout: agent completion \(waited 150000ms of 180000ms outer\)/);
  assert.match(summary, /backend=sessions=1 workers=1 aabbccdd:recipe requests=absent guiChars=42/);
});
