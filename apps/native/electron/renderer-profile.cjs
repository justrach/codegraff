// Executes in an isolated Chromium world. Only numeric measurements leave it.
function collectRendererMetrics(enabled) {
  const key = '__graffPerformance';
  let state = globalThis[key];
  if (!enabled) {
    state?.observers.forEach(observer => observer.disconnect());
    delete globalThis[key]; return null;
  }
  if (!state) {
    state = globalThis[key] = { observers: [], lcpMs: null, fcpMs: null, interactionMaxMs: null, layoutShift: 0 };
    const observe = (type, callback, options = {}) => {
      if (!PerformanceObserver.supportedEntryTypes.includes(type)) return;
      const observer = new PerformanceObserver(list => list.getEntries().forEach(callback));
      observer.observe({ type, ...options }); state.observers.push(observer);
    };
    // Paint timings are document-relative; interaction/shift measurements start with recording.
    observe('largest-contentful-paint', entry => { state.lcpMs = entry.startTime; }, { buffered: true });
    for (const entry of performance.getEntriesByType('paint')) if (entry.name === 'first-contentful-paint') state.fcpMs = entry.startTime;
    observe('paint', entry => { if (entry.name === 'first-contentful-paint') state.fcpMs = entry.startTime; });
    observe('event', entry => { if (entry.interactionId) state.interactionMaxMs = Math.max(state.interactionMaxMs || 0, entry.duration); }, { durationThreshold: 16 });
    observe('layout-shift', entry => { if (!entry.hadRecentInput) state.layoutShift += entry.value; });
  }
  return { lcpMs: state.lcpMs, fcpMs: state.fcpMs, interactionMaxMs: state.interactionMaxMs,
    layoutShift: state.layoutShift, rendererHeapMiB: performance.memory ? performance.memory.usedJSHeapSize / 1048576 : null,
    domNodes: document.getElementsByTagName('*').length };
}
async function rendererSample(contents, enabled = true) {
  if (!contents || contents.isDestroyed()) return {};
  return contents.executeJavaScriptInIsolatedWorld(997, [{ code: `(${collectRendererMetrics.toString()})(${enabled})` }]);
}
module.exports = { collectRendererMetrics, rendererSample };
