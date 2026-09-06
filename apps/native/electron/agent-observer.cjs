const { spawn, execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { performance } = require('node:perf_hooks');
const { cpuMilliseconds } = require('./process-metrics.cjs');

// The observer exits on stdin EOF. It never starts a model, MCP or a session.
function observeAgents(binary, root, params = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, [], { cwd: root, env: { ...process.env, GRAFF_AGENT_OBSERVER: '1' }, stdio: ['pipe', 'pipe', 'ignore'] });
    let data = '', settled = false;
    const done = (error, value) => { if (settled) return; settled = true; clearTimeout(timer); if (error) child.kill(); error ? reject(error) : resolve(value); };
    const timer = setTimeout(() => done(new Error('Agent observer timed out')), 8000);
    child.on('error', () => done(new Error('Agent observer could not start')));
    child.stdin.on('error', () => done(new Error('Agent observer disconnected')));
    child.stdout.on('data', chunk => {
      data += chunk;
      if (data.length > 2 * 1024 * 1024) done(new Error('Agent snapshot exceeds limit'));
    });
    child.on('close', () => {
      if (settled) return;
      try {
        const reply = JSON.parse(data.trim());
        if (reply.error) done(new Error(reply.error.message));
        else if (!reply.result) done(new Error('Invalid agent snapshot'));
        else done(null, reply.result);
      } catch { done(new Error('Agent snapshot unavailable; rebuild the Graff binary')); }
    });
    child.stdin.end(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'graff/agents', params }) + '\n');
  });
}

function agentSampler() {
  let previous = new Map();
  return async agents => {
    if (!agents.length || process.platform !== 'darwin') { previous.clear(); return agents.map(a => ({ ...a, resources: null })); }
    // Root-process measurements: shared workers/GPU cannot be attributed safely.
    const { stdout } = await promisify(execFile)('ps', ['-axo', 'pid=,rss=,time=,lstart='], { timeout: 3000, maxBuffer: 2 * 1024 * 1024, env: { ...process.env, LC_ALL: 'C' } });
    const rows = new Map(stdout.trim().split('\n').map(line => {
      const [pid, rss, time, ...start] = line.trim().split(/\s+/);
      return [Number(pid), { rss: Number(rss), time: cpuMilliseconds(time || '0'), start: Date.parse(start.join(' ')) }];
    }));
    const at = performance.now(), next = new Map();
    const result = agents.map(agent => {
      const row = rows.get(agent.pid), key = `${agent.pid}:${agent.startId}`;
      // OS start second must still match the microsecond identity verified by Graff.
      if (!row || Math.floor(Number(agent.startId) / 1000000) !== Math.floor(row.start / 1000)) return { ...agent, resources: null };
      const last = previous.get(key);
      next.set(key, { time: row.time, at });
      return { ...agent, resources: { rssMiB: row.rss / 1024, cpuPercent: last && at > last.at ? Math.max(0, row.time - last.time) / (at - last.at) * 100 : null } };
    });
    previous = next; return result;
  };
}
module.exports = { observeAgents, agentSampler };
