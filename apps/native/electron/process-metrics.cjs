const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { performance } = require('node:perf_hooks');
function cpuMilliseconds(value) {
  const parts = value.split(':').map(Number);
  if (parts.some(n => !Number.isFinite(n))) return 0;
  return parts.reduce((n, part) => n * 60 + part, 0) * 1000;
}
async function treeSample(pid) {
  const { stdout } = await promisify(execFile)('ps', ['-axo', 'pid=,ppid=,rss=,%cpu=,time='], { timeout: 3000 });
  const rows = stdout.trim().split('\n').map(row => {
    const [id, parent, rss, cpu, time] = row.trim().split(/\s+/);
    return { id: Number(id), parent: Number(parent), rss: Number(rss), cpu: Number(cpu), time: cpuMilliseconds(time || '0') };
  });
  const ids = new Set([pid]);
  for (let i = 0; i < 12; i++) for (const row of rows) if (ids.has(row.parent)) ids.add(row.id);
  const owned = rows.filter(row => ids.has(row.id));
  return { rssMiB: Math.round(owned.reduce((n, row) => n + row.rss, 0) / 1024),
    cpuPercent: Math.round(owned.reduce((n, row) => n + row.cpu, 0) * 10) / 10,
    processes: owned.length, times: new Map(owned.map(row => [row.id, row.time])), at: performance.now() };
}
function intervalSampler(pid, browsers) {
  let previous;
  return async () => {
    const now = await treeSample(pid);
    const elapsed = previous ? now.at - previous.at : 0;
    const used = previous ? [...now.times].reduce((n, [id, time]) => n + Math.max(0, time - (previous.times.get(id) ?? time)), 0) : 0;
    previous = now;
    return { rssMiB: now.rssMiB, cpuPercent: elapsed > 0 ? used / elapsed * 100 : 0, processes: now.processes, browsers: browsers() };
  };
}
module.exports = { treeSample, intervalSampler, cpuMilliseconds };
