const { performance } = require('node:perf_hooks');
const EVENTS = new Set(['ui-ready', 'page-navigation', 'page-loaded', 'renderer-crash', 'browser-action', 'computer-action', 'action-failed', 'renderer-long-task']);
const finite = value => Number.isFinite(value) ? Math.round(value * 100) / 100 : 0;
class Profiler {
  constructor(sample, notify = () => {}) { this.sample = sample; this.notify = notify; this.timer = null; this.samples = []; this.events = []; this.phase = 'baseline'; this.started = 0; this.busy = false; }
  async start() {
    this.stop(); this.samples = []; this.events = []; this.started = performance.now(); this.phase = 'baseline';
    this.active = true; this.notify(true); this.expected = performance.now() + 2000;
    this.timer = setInterval(() => {
      const lag = Math.max(0, performance.now() - this.expected); this.expected = performance.now() + 2000;
      void this.capture(lag); if (performance.now() - this.started >= 600000) this.stop();
    }, 2000);
    this.timer.unref(); await this.capture(0); return this.status();
  }
  stop() { clearInterval(this.timer); this.timer = null; this.active = false; this.notify(false); return this.status(); }
  status() { return { active: !!this.active, phase: this.phase, samples: this.samples.length, events: this.events.length, maxDurationSeconds: 600 }; }
  async capture(lag) {
    if (this.busy || !this.active) return;
    this.busy = true;
    try {
      const raw = await this.sample();
      if (!this.active) return;
      // Construct every field explicitly. Never serialize process names, URLs or raw metrics objects.
      this.samples.push({ elapsedMs: finite(performance.now() - this.started), phase: this.phase,
        rssMiB: finite(raw.rssMiB), cpuPercent: finite(raw.cpuPercent), processes: finite(raw.processes),
        browsers: finite(raw.browsers), mainLoopLagMs: finite(lag) });
      if (this.samples.length > 300) this.samples.shift();
    } catch { this.record('action-failed', 0); } finally { this.busy = false; }
  }
  record(name, durationMs = 0) {
    if (!this.active || !EVENTS.has(name)) return;
    this.events.push({ event: name, durationMs: Math.max(0, finite(durationMs)), elapsedMs: finite(performance.now() - this.started), phase: this.phase });
    if (this.events.length > 1000) this.events.shift();
  }
  mark(phase) { if (!['baseline', 'candidate'].includes(phase)) throw new Error('Phase must be baseline or candidate'); this.phase = phase; return this.status(); }
  report() {
    const summary = phase => {
      const rows = this.samples.filter(s => s.phase === phase);
      const mean = key => finite(rows.reduce((n, row) => n + row[key], 0) / (rows.length || 1));
      return { samples: rows.length, meanRssMiB: mean('rssMiB'), meanCpuPercent: mean('cpuPercent'), maxMainLoopLagMs: Math.max(0, ...rows.map(r => r.mainLoopLagMs)) };
    };
    const baseline = summary('baseline'), candidate = summary('candidate');
    return { schema: 'codegraff-performance-v1', privacy: 'Measurements only; no content, paths, URLs, identifiers, screenshots or free-form text.',
      measurement: 'RSS sums the app process tree and may count shared pages twice. CPU is interval process-tree CPU time; short-lived exited children can be missed and the first sample is zero. Main loop lag is timer delay; renderer long tasks are durations only.',
      status: this.status(), baseline, candidate,
      comparison: baseline.samples && candidate.samples ? { meanRssMiBDelta: finite(candidate.meanRssMiB - baseline.meanRssMiB), meanCpuPercentDelta: finite(candidate.meanCpuPercent - baseline.meanCpuPercent) } : null,
      samples: this.samples.map(row => ({ ...row })), events: this.events.map(row => ({ ...row })) };
  }
  async command(method, params = {}) {
    if (method === 'start') return this.start();
    if (method === 'stop') return this.stop();
    if (method === 'status') return this.status();
    if (method === 'mark') return this.mark(params.phase);
    if (method === 'report') return this.report();
    throw new Error('Unsupported profiler action');
  }
}
module.exports = { Profiler };
