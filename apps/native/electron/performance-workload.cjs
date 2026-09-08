// Deterministic desktop workload. All content is synthetic; no engine calls.
function installPerformanceWorkload() {
  const original = window.fetch;
  window.benchmarkCase = 'warmup';
  window.benchmarkChars = 0;
  const prose = Array.from({ length: 160 }, (_, index) =>
    `### Section ${index}\n\nA responsive workspace keeps the conversation readable while updates arrive. ` +
    'The reader can review earlier work and continue without losing their place. '.repeat(10) +
    '\n\n- Keep the controls available.\n- Preserve the reading position.\n\n').join('');
  const code = '```typescript\n' + Array.from({ length: 300 }, (_, index) =>
    `export const sample${index} = (value: number) => value + ${index}; // sample row\n`).join('') + '```';
  const json = value => new Response(JSON.stringify(value), { headers: { 'content-type': 'application/json' } });
  window.fetch = async (input, options) => {
    const url = new URL(typeof input === 'string' ? input : input.url, location.origin);
    if (url.pathname === '/api/fs') return json({ root: '/demo/field-notes', path: '', entries: [] });
    if (url.pathname === '/api/workspaces') return json({ cwd: '/demo/field-notes', home: '/demo', roots: ['/demo/field-notes'] });
    if (url.pathname === '/api/acp' && options?.body) {
      const body = JSON.parse(options.body);
      if (body.method === 'session/prompt') {
        const text = window.benchmarkCase === 'prose' ? prose : window.benchmarkCase === 'code' ? code : 'Ready to review the workspace.\n\n```typescript\nconst ready = true;\n```';
        const size = window.benchmarkCase === 'prose' ? 512 : window.benchmarkCase === 'code' ? 80 : 8;
        window.benchmarkChars = text.length;
        return new Response(new ReadableStream({ start(controller) {
          let index = 0;
          const send = value => controller.enqueue(new TextEncoder().encode(JSON.stringify(value) + '\n'));
          const timer = setInterval(() => {
            send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: 'demo', update: {
              sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: text.slice(index, index + size) }
            } } });
            index += size;
            if (index >= text.length) { clearInterval(timer); send({ jsonrpc: '2.0', id: 1, result: { stopReason: 'end_turn' } }); controller.close(); }
          }, 16);
        } }), { headers: { 'content-type': 'application/x-ndjson' } });
      }
    }
    return original(input, options);
  };
}

function frameRecorder() {
  const samples = [];
  const longTasks = [];
  let frame = 0, previous = 0;
  const started = performance.now();
  const observer = new PerformanceObserver(list => {
    for (const entry of list.getEntries()) longTasks.push(entry.duration);
  });
  observer.observe({ type: 'longtask', buffered: false });
  const tick = now => {
    if (previous && samples.length < 20000) samples.push(now - previous);
    previous = now;
    frame = requestAnimationFrame(tick);
  };
  frame = requestAnimationFrame(tick);
  window.stopBenchmarkFrames = () => {
    cancelAnimationFrame(frame); observer.disconnect();
    return { intervalsMs: samples, longTasksMs: longTasks, durationMs: performance.now() - started,
      visible: document.visibilityState === 'visible', focused: document.hasFocus() };
  };
}

function summarizeFrames(raw) {
  const sorted = [...raw.intervalsMs].sort((a, b) => a - b);
  const percentile = p => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] ?? null;
  return { frames: sorted.length, durationMs: raw.durationMs, medianMs: percentile(0.5),
    p95Ms: percentile(0.95), p99Ms: percentile(0.99), maxMs: sorted.at(-1) ?? null,
    gapsOver12_5msPercent: sorted.length ? 100 * sorted.filter(ms => ms > 12.5).length / sorted.length : null,
    longTasks: raw.longTasksMs.length, longTaskTotalMs: raw.longTasksMs.reduce((sum, value) => sum + value, 0),
    visible: raw.visible, focused: raw.focused };
}
module.exports = { installPerformanceWorkload, frameRecorder, summarizeFrames };
